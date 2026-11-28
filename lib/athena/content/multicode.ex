defmodule Athena.Content.Multicode do
  @moduledoc "A collection of ordinary code challenges sharing one prompt."
  use Ecto.Schema
  import Ecto.Changeset

  alias Athena.Content.CodeChallenge
  alias Athena.Execution.LanguageConfig

  @primary_key false
  @derive {Jason.Encoder, only: [:body, :render_prompt_as_image, :active_language, :languages]}
  embedded_schema do
    field :body, :map, default: %{}
    field :render_prompt_as_image, :boolean, default: false
    field :active_language, :string, default: "python3"
    field :languages, :map, default: %{}
  end

  @variant_fields ~w(initial_code solution_code test_cases time_limit memory_limit)

  def changeset(schema, attrs) do
    attrs = normalize_editor(attrs)

    schema
    |> cast(attrs, [:body, :render_prompt_as_image, :active_language, :languages])
    |> validate_inclusion(:active_language, language_ids())
    |> validate_variants()
  end

  defp normalize_editor(attrs) do
    language = attrs["active_language"] || "python3"
    variants = attrs["languages"] || %{}
    updates = Map.take(attrs, @variant_fields)

    variants =
      if is_map(variants) and map_size(updates) > 0 do
        Map.update(variants, language, updates, fn
          variant when is_map(variant) -> Map.merge(variant, updates)
          other -> other
        end)
      else
        variants
      end

    Map.put(attrs, "languages", variants)
  end

  defp validate_variants(changeset) do
    variants = get_field(changeset, :languages) || %{}

    Enum.reduce(variants, changeset, fn {language, attrs}, changeset ->
      cond do
        language not in language_ids() or not is_map(attrs) ->
          add_error(changeset, :languages, "contains an unsupported programming language")

        true ->
          cases = editor_test_cases(attrs["test_cases"] || [])

          validation_attrs =
            Map.put(
              attrs,
              "test_cases",
              Enum.map(cases, fn tc ->
                if is_map(tc) and tc["expected_output"] in [nil, ""],
                  do: Map.put(tc, "expected_output", "__unfinished__"),
                  else: tc
              end)
            )

          cs =
            CodeChallenge.changeset(
              %CodeChallenge{},
              Map.put(Map.take(validation_attrs, @variant_fields), "language", language)
            )

          if cs.valid? do
            normalized =
              cs
              |> apply_changes()
              |> Jason.encode!()
              |> Jason.decode!()
              |> Map.take(@variant_fields)

            normalized_cases =
              Enum.zip_with(normalized["test_cases"], cases, fn tc, raw ->
                tc
                |> Map.put("id", raw["id"] || Ecto.UUID.generate())
                |> Map.put("expected_output", raw["expected_output"] || "")
              end)

            update_change_or_put(
              changeset,
              language,
              Map.put(normalized, "test_cases", normalized_cases)
            )
          else
            add_error(changeset, :languages, "#{language}: invalid code settings or test cases")
          end
      end
    end)
  end

  # Empty rows are authoring drafts; readiness uses the unmodified CodeChallenge
  # changeset, so they cannot expose a language or reach execution.
  defp editor_test_cases(cases) when is_list(cases), do: cases

  defp editor_test_cases(cases) when is_map(cases) do
    cases |> Enum.sort_by(fn {key, _} -> Integer.parse(key) end) |> Enum.map(&elem(&1, 1))
  end

  defp editor_test_cases(_), do: [%{"expected_output" => 42}]

  defp update_change_or_put(changeset, language, attrs) do
    put_change(
      changeset,
      :languages,
      Map.put(get_field(changeset, :languages) || %{}, language, attrs)
    )
  end

  def language_ids,
    do: LanguageConfig.options() |> Enum.map(&elem(&1, 1)) |> Enum.reject(&(&1 == "sql"))

  def options(content, author? \\ false) do
    variants = content["languages"] || %{}

    Enum.filter(LanguageConfig.options(), fn {_label, language} ->
      language != "sql" and
        if author?,
          do: Map.has_key?(variants, language),
          else: ready?(language, variants[language])
    end)
  end

  def ready?(language, attrs) when is_map(attrs) do
    solution = attrs["solution_code"] || ""
    cases = attrs["test_cases"] || []

    cs =
      CodeChallenge.changeset(
        %CodeChallenge{},
        Map.put(Map.take(attrs, @variant_fields), "language", language)
      )

    language in language_ids() and is_binary(solution) and String.trim(solution) != "" and
      is_list(cases) and cases != [] and cs.valid?
  end

  def ready?(_, _), do: false

  def selected(content, answer \\ nil, author? \\ false) do
    requested = if author?, do: content["active_language"], else: answer_language(answer)
    ids = Enum.map(options(content, author?), &elem(&1, 1))
    if requested in ids, do: requested, else: List.first(ids)
  end

  defp answer_language(%{content: content}), do: answer_language(content)
  defp answer_language(%{} = answer), do: answer["language"]
  defp answer_language(_), do: nil

  def variant(content, language) do
    defaults =
      %CodeChallenge{language: language || "python3"} |> Jason.encode!() |> Jason.decode!()

    defaults
    |> Map.merge(Map.get(content["languages"] || %{}, language, %{}))
    |> Map.merge(Map.take(content, ~w(body render_prompt_as_image)))
    |> Map.put("language", language || "python3")
  end

  def editor_content(%{"languages" => _} = content) do
    language = selected(content, nil, true) || content["active_language"] || "python3"
    Map.merge(content, variant(content, language))
  end

  def editor_content(content), do: content

  def project(%{type: :multicode} = block, answer, author?) do
    language = selected(block.content, answer, author?)
    %{block | type: :code, content: variant(block.content, language)}
  end

  def project(block, _, _), do: block

  def answer(block, params, existing, select? \\ false) do
    existing = existing || %{}
    existing = if is_struct(existing), do: existing.content || %{}, else: existing

    language =
      get_in(params, ["answer", "language"]) || params["language"] || existing["language"] ||
        selected(block.content)

    code = get_in(params, ["answer", "code"]) || params["code"] || ""
    drafts = existing["language_drafts"] || %{}

    drafts =
      if existing["language"],
        do: Map.put(drafts, existing["language"], existing["code"] || ""),
        else: drafts

    drafts =
      if select? do
        previous = existing["language"] || selected(block.content)
        if previous, do: Map.put(drafts, previous, code), else: drafts
      else
        Map.put(drafts, language, code)
      end

    active = if select?, do: language, else: existing["language"] || language
    code = Map.get(drafts, active, variant(block.content, active)["initial_code"] || "")
    %{"type" => "multicode", "language" => active, "code" => code, "language_drafts" => drafts}
  end

  def challenge(content, language) do
    if ready?(language, get_in(content, ["languages", language])) do
      {:ok,
       Ecto.Changeset.apply_changes(
         CodeChallenge.changeset(%CodeChallenge{}, variant(content, language))
       )}
    else
      {:error, :unavailable_language}
    end
  end
end
