# Parses a "test bank" .docx (АСТ-style export) into an import bundle.
#
#     mix run scripts/quiz_import/parse.exs <file.docx> --set ikg-1sem --label "ИКГ-1" [--out DIR]
#
# Output (default `tmp/quiz_bundle/<set>/`):
#   questions.json  - questions with tiptap content, tags and image references
#   images/         - only the PNGs the questions actually use
#   report.txt      - anomalies (fail the run) and inferences worth a human look
#
# Image nodes carry a placeholder `src` of `@img:<file name>`; import.exs swaps
# it for the real `/media/<key>` after uploading the file.
#
# The documents mark no correct answers, so every option is imported with
# `is_correct: false` (matching pairs keep their order, which *is* the key).

Code.require_file("docx_reader.exs", __DIR__)

defmodule QuizImport.Parser do
  alias QuizImport.DocxReader

  @header ~r/^Задание\s*\{\{\s*(\d+)\s*\}{0,2}\s*([\d.]*)/u
  @theme ~r/^\d+\.\s*Тема\s*(.+)$/u
  @subtheme ~r/^\d+\.\d+\.\s*\d+\.\d+\.?\s*(.+)$/u
  @content_marker ~r/^СОДЕРЖАНИЕ БАНКА/u
  # "Отметьте правильный ответ" and its typos ("Отметить", "ответр", ...).
  @generic_instruction ~r/^Отмет\S*\s+правильн/iu
  # "Установить соответствие ...", "Определить соответсвие ...", "Найдите соответствие ..." (typos included).
  @matching ~r/^((Установ|Определ|Найд)\S*\s+соответс|Совмест\S*\s)/iu
  # A one-word topic label ("Blender:") sitting in its own paragraph above the question.
  @label ~r/^[\p{L}\d-]{3,15}:?$/u
  @stray_number ~r/^\d+$/u
  # A leftover sentence with a blank ("... называют_") pasted in from another task.
  @stray_sentence ~r/_{2,}|_\s*$/u
  # With an odd item count a long leading sentence cannot be a name/symbol.
  @stray_long 45

  # Source defects fixed by hand, keyed by {set, task number}:
  # the listed item texts are dropped from the matching list.
  @overrides %{
    {"ikg-2sem", 141} =>
      {["запоминающее устройство с прямым доступом"],
       "source has 5 names but only 4 pictures; dropped the name without a picture"}
  }

  def run(docx, set, label, out_dir) do
    %{paragraphs: paragraphs, media: media} = DocxReader.read!(docx)
    dims = Map.new(media, fn {name, bin} -> {name, png_dims(bin)} end)

    tasks = split_tasks(paragraphs)

    results = Enum.map(tasks, &classify(&1, dims, set))

    questions =
      for {:ok, q} <- results do
        build_question(q, set, label)
      end
      |> disambiguate_titles()

    anomalies = for {:error, n, code, why, _} <- results, do: {n, code, why}
    notes = for {:ok, %{note: note} = q} when note != nil <- results, do: {q.n, q.code, note}

    used = questions |> Enum.flat_map(& &1["images"]) |> Enum.uniq() |> Enum.sort()

    File.rm_rf!(out_dir)
    File.mkdir_p!(Path.join(out_dir, "images"))

    for name <- used,
        do: File.write!(Path.join([out_dir, "images", name]), Map.fetch!(media, name))

    File.write!(
      Path.join(out_dir, "questions.json"),
      Jason.encode!(%{"set" => set, "label" => label, "questions" => questions}, pretty: true)
    )

    report(out_dir, set, tasks, questions, anomalies, notes)
    {length(questions), anomalies}
  end

  # -- segmentation ---------------------------------------------------------

  defp split_tasks(paragraphs) do
    {_, _, _, tasks} =
      Enum.reduce(paragraphs, {false, {nil, nil}, nil, []}, fn p,
                                                               {in_content?, theme, cur, acc} ->
        text = p.text

        cond do
          Regex.match?(@content_marker, text) ->
            {true, {nil, nil}, nil, acc}

          not in_content? ->
            {false, theme, nil, acc}

          Regex.match?(@header, text) ->
            [_, n, code] = Regex.run(@header, text)

            task = %{
              n: String.to_integer(n),
              code: String.trim(code, "."),
              theme: theme,
              body: []
            }

            {true, theme, task, [task | acc]}

          m = Regex.run(@theme, text) ->
            {true, {Enum.at(m, 1), nil}, nil, acc}

          m = Regex.run(@subtheme, text) ->
            {theme_name, _} = theme
            {true, {theme_name, Enum.at(m, 1)}, nil, acc}

          cur == nil ->
            {true, theme, cur, acc}

          true ->
            updated = %{cur | body: [p | cur.body]}
            [_ | rest] = acc
            {true, theme, updated, [updated | rest]}
        end
      end)

    tasks
    |> Enum.reverse()
    |> Enum.map(fn t ->
      body = t.body |> Enum.reverse() |> Enum.reject(&(&1.text == "" and &1.images == []))
      %{t | body: body}
    end)
  end

  # -- classification -------------------------------------------------------

  defp classify(%{body: []} = t, _dims, _set), do: {:error, t.n, t.code, "empty body", t}

  defp classify(t, dims, set) do
    {instruction, body} =
      case t.body do
        [%{images: [], text: text} | rest] = all ->
          if Regex.match?(@generic_instruction, text), do: {text, rest}, else: {nil, all}

        all ->
          {nil, all}
      end

    {body, label_note} = merge_label(body)

    cond do
      body == [] ->
        {:error, t.n, t.code, "only an instruction line", t}

      Regex.match?(@matching, hd(body).text) ->
        matching(t, instruction, body, Map.get(@overrides, {set, t.n}))

      true ->
        choice_or_open(t, instruction, body, dims, label_note)
    end
  end

  # "Blender:" + "С помощью какой клавиши ...?" -> "Blender: С помощью какой клавиши ...?"
  defp merge_label(
         [%{images: [], text: label} = first, %{images: [], text: next} = second | rest] = body
       ) do
    if Regex.match?(@label, label) and (String.length(next) > 25 or String.ends_with?(next, "?")) do
      merged = String.trim_trailing(label, ":") <> ": " <> next

      {[%{second | text: merged} | rest],
       "merged the label #{inspect(first.text)} into the prompt"}
    else
      {body, nil}
    end
  end

  defp merge_label(body), do: {body, nil}

  defp matching(t, instruction, [prompt | rest], override) do
    {noise, rest} =
      Enum.split_while(rest, fn p ->
        p.images == [] and
          (Regex.match?(@stray_number, p.text) or Regex.match?(@stray_sentence, p.text))
      end)

    {override_notes, rest} =
      case override do
        {drop, why} ->
          {["manual fix: " <> why], Enum.reject(rest, &(&1.text in drop and &1.images == []))}

        nil ->
          {[], rest}
      end

    # Odd item count with a leading text-only paragraph: a pasted-in sentence.
    # Obvious when the right column is pictures (one more name than pictures)
    # or when the sentence is too long to be a name/symbol.
    {noise, rest} =
      case rest do
        [%{images: [], text: text} = first | tail] ->
          pictures = Enum.count(tail, &(&1.images != [] and &1.text == ""))
          names = Enum.count(tail, &(&1.images == []))

          stray? =
            rem(length(rest), 2) == 1 and
              (String.length(text) > @stray_long or (pictures > 0 and names == pictures))

          if stray?, do: {noise ++ [first], tail}, else: {noise, rest}

        _ ->
          {noise, rest}
      end

    n = length(rest)

    cond do
      n < 4 or rem(n, 2) == 1 ->
        {:error, t.n, t.code, "matching: #{n} items after the prompt (need an even number >= 4)",
         t}

      true ->
        {left, right} = Enum.split(rest, div(n, 2))

        note =
          Enum.join(
            override_notes ++
              if(noise != [],
                do: [
                  "dropped stray paragraph(s) #{inspect(Enum.map(noise, &String.slice(&1.text, 0, 60)))}"
                ],
                else: []
              ),
            "; "
          )

        note = if note == "", do: nil, else: note

        {:ok,
         %{
           kind: :matching,
           t: t,
           n: t.n,
           code: t.code,
           prompt: [prompt],
           pairs: Enum.zip(left, right),
           instruction: instruction,
           note: note
         }}
    end
  end

  defp choice_or_open(t, instruction, body, dims, label_note) do
    kinds = Enum.map(body, &kind/1)

    case split_options(body, kinds, dims) |> absorb_question_tail() do
      {:options, prompt, options, split_note} when length(options) >= 2 ->
        {:ok,
         %{
           kind: :single,
           t: t,
           n: t.n,
           code: t.code,
           prompt: prompt,
           options: options,
           instruction: instruction,
           note: join_notes([label_note, split_note])
         }}

      {:open, prompt, _} ->
        {:ok,
         %{
           kind: :open,
           t: t,
           n: t.n,
           code: t.code,
           prompt: prompt,
           instruction: instruction,
           note:
             Enum.join(
               Enum.reject(
                 [label_note, "no options in the source, imported as an open question"],
                 &is_nil/1
               ),
               "; "
             )
         }}

      _ ->
        {:error, t.n, t.code,
         "cannot split into prompt/options (kinds: #{Enum.join(kinds, " ")})", t}
    end
  end

  defp join_notes(notes) do
    case Enum.reject(notes, &is_nil/1) do
      [] -> nil
      list -> Enum.join(list, "; ")
    end
  end

  # A prompt broken over two paragraphs ("... (видов, разрезов, сечений)" /
  # "должно быть на чертеже?"): an "option" that ends in "?" is the prompt's tail.
  defp absorb_question_tail({:options, prompt, options}),
    do: absorb_question_tail({:options, prompt, options, nil})

  defp absorb_question_tail({:options, prompt, [%{images: [], text: tail} = opt | rest], note})
       when length(rest) >= 2 do
    last = List.last(prompt)

    if String.ends_with?(tail, "?") and last.images == [] and last.text != "" do
      merged = %{last | text: last.text <> " " <> tail}

      absorb_question_tail(
        {:options, List.replace_at(prompt, -1, merged), rest,
         "joined the prompt tail #{inspect(String.slice(opt.text, 0, 40))}"}
      )
    else
      {:options, prompt, [opt | rest], note}
    end
  end

  defp absorb_question_tail({:options, prompt, options, note}),
    do: {:options, prompt, options, note}

  defp absorb_question_tail({:open, prompt}), do: {:open, prompt, nil}
  defp absorb_question_tail(other), do: other

  # Options are the longest trailing run of uniform paragraphs (all text or
  # all image-only). Everything before it is the prompt.
  defp split_options(body, kinds, dims) do
    rev = Enum.reverse(kinds)
    last = hd(rev)

    run_len =
      if last in [:text, :image], do: Enum.count(Enum.take_while(rev, &(&1 == last))), else: 0

    total = length(body)

    cond do
      # Prompt + a single picture (or text) and nothing that looks like options.
      total <= 2 and run_len <= 1 ->
        {:open, body}

      run_len < 2 ->
        :error

      # All text: the first paragraph is the prompt, the rest are options.
      last == :text and run_len == total ->
        {:options, [hd(body)], tl(body)}

      last == :image and run_len == total ->
        # Instruction-less, image-only body: first picture is the prompt.
        {:options, [hd(body)], tl(body)}

      true ->
        {prompt, options} = Enum.split(body, total - run_len)
        move_big_first_image(prompt, options, last, dims)
    end
  end

  # [text, DRAWING, small, small, ...]: the first picture of an image-only run
  # that is much bigger than the others is the prompt's drawing.
  defp move_big_first_image(prompt, [first | others] = options, :image, dims) when others != [] do
    area = fn p -> dims |> Map.fetch!(hd(p.images)) |> then(fn {w, h} -> w * h end) end
    areas = others |> Enum.map(area) |> Enum.sort()
    median = Enum.at(areas, div(length(areas), 2))

    if area.(first) >= 2.5 * median and length(others) >= 2 do
      {:options, prompt ++ [first], others}
    else
      {:options, prompt, options}
    end
  end

  defp move_big_first_image(prompt, options, _, _), do: {:options, prompt, options}

  defp kind(%{images: [], text: _}), do: :text
  defp kind(%{images: [_ | _], text: ""}), do: :image
  defp kind(_), do: :mixed

  # -- tiptap ---------------------------------------------------------------

  defp doc(paragraphs) do
    %{"type" => "doc", "content" => Enum.flat_map(paragraphs, &nodes/1)}
  end

  defp nodes(%{text: text, images: images}) do
    para =
      if text == "",
        do: [],
        else: [%{"type" => "paragraph", "content" => [%{"type" => "text", "text" => text}]}]

    para ++ Enum.map(images, &image_node/1)
  end

  defp image_node(name),
    do: %{"type" => "image", "attrs" => %{"src" => "@img:" <> name, "alt" => ""}}

  defp build_question(q, set, label) do
    t = q.t
    {theme, sub} = t.theme || {nil, nil}

    tags =
      Enum.reject([theme && "тема:" <> tag(theme), sub && "подтема:" <> tag(sub)], &is_nil/1)

    all_paragraphs =
      q.prompt ++
        case q.kind do
          :single -> q.options
          :matching -> Enum.flat_map(q.pairs, fn {l, r} -> [l, r] end)
          :open -> []
        end

    content =
      case q.kind do
        :single ->
          %{
            "question_type" => "single",
            "body" => doc(q.prompt),
            "options" =>
              Enum.map(q.options, fn o ->
                %{"text" => doc([o]), "is_correct" => false}
              end)
          }

        :matching ->
          %{
            "question_type" => "matching",
            "body" => doc(q.prompt),
            "pairs" =>
              Enum.map(q.pairs, fn {l, r} -> %{"left" => doc([l]), "right" => doc([r])} end)
          }

        :open ->
          %{"question_type" => "open", "answer_type" => "plain_text", "body" => doc(q.prompt)}
      end

    %{
      "n" => q.n,
      "code" => q.code,
      "title" => title(label, q),
      "tags" => tags,
      "content" => content,
      "images" => all_paragraphs |> Enum.flat_map(& &1.images) |> Enum.uniq()
    }
  end

  # The comma separates tags in the editor, so it cannot appear inside one.
  defp tag(text),
    do: text |> String.replace(",", " ") |> String.replace(~r/\s+/u, " ") |> String.trim()

  # The importer finds its blocks again by title (there are no marker tags), so
  # titles must be unique within a set; a repeated one gets the task number.
  defp disambiguate_titles(questions) do
    repeated =
      questions
      |> Enum.frequencies_by(& &1["title"])
      |> Enum.filter(&(elem(&1, 1) > 1))
      |> Map.new()

    Enum.map(questions, fn q ->
      if Map.has_key?(repeated, q["title"]),
        do: %{q | "title" => q["title"] <> " (№#{q["n"]})"},
        else: q
    end)
  end

  defp title(label, q) do
    text = q.prompt |> Enum.map(& &1.text) |> Enum.reject(&(&1 == "")) |> Enum.join(" ")
    text = if text == "", do: "(рисунок)", else: String.slice(text, 0, 80)
    code = if q.code == "", do: "№#{q.n}", else: q.code
    "[#{label}] #{code} — #{text}"
  end

  # -- png ------------------------------------------------------------------

  defp png_dims(<<137, 80, 78, 71, 13, 10, 26, 10, _len::32, "IHDR", w::32, h::32, _::binary>>),
    do: {w, h}

  defp png_dims(_), do: {1, 1}

  # -- report ---------------------------------------------------------------

  defp report(out_dir, set, tasks, questions, anomalies, notes) do
    by_type = questions |> Enum.frequencies_by(& &1["content"]["question_type"]) |> Enum.sort()

    lines =
      [
        "set: #{set}",
        "tasks in document: #{length(tasks)}",
        "questions parsed: #{length(questions)}  #{inspect(by_type)}",
        "images used: #{questions |> Enum.flat_map(& &1["images"]) |> Enum.uniq() |> length()}",
        "",
        "ANOMALIES (#{length(anomalies)}) - these tasks are NOT in questions.json:"
      ] ++
        Enum.map(anomalies, fn {n, code, why} -> "  #{n} (#{code}): #{why}" end) ++
        ["", "NOTES (#{length(notes)}) - inferred, worth a look:"] ++
        Enum.map(notes, fn {n, code, note} -> "  #{n} (#{code}): #{note}" end)

    File.write!(Path.join(out_dir, "report.txt"), Enum.join(lines, "\n") <> "\n")
    IO.puts(Enum.join(Enum.take(lines, 4), "\n"))

    IO.puts(
      "anomalies: #{length(anomalies)}, notes: #{length(notes)} (see #{out_dir}/report.txt)"
    )
  end
end

{opts, args, _} =
  OptionParser.parse(System.argv(), strict: [set: :string, label: :string, out: :string])

with [docx] <- args,
     set when is_binary(set) <- opts[:set] do
  label = opts[:label] || String.upcase(set)
  out = opts[:out] || Path.join(["tmp", "quiz_bundle", set])
  {_count, anomalies} = QuizImport.Parser.run(docx, set, label, out)
  if anomalies != [], do: System.halt(2)
else
  _ ->
    IO.puts(
      :stderr,
      "usage: mix run scripts/quiz_import/parse.exs <file.docx> --set NAME [--label L] [--out DIR]"
    )

    System.halt(1)
end
