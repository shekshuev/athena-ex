defmodule AthenaWeb.BlockComponents do
  @moduledoc """
  Universal components for rendering course blocks across the application.
  Supports three modes:
  - :edit (Builder/Library) - Shows borders, highlighting on hover.
  - :play (Player) - Clean content with interactive inputs.
  - :review (Grading) - Clean content with disabled inputs and correct answers highlighted.
  """
  use Phoenix.Component
  use AthenaWeb, :html

  @doc """
    Main entry point for rendering any block.
    Routes to specific renderers based on block type.
  """
  attr :block, :map, required: true
  attr :mode, :atom, required: true, values: [:edit, :play, :review, :preview]
  attr :answers, :map, default: %{}
  attr :submission, :map, default: nil
  attr :active, :boolean, default: false
  attr :attempts_count, :integer, default: 0
  attr :pending_file_urls, :map, default: %{}
  attr :draft, :map, default: nil
  attr :hide_submit, :boolean, default: false

  def content_block(assigns) do
    ~H"""
    <div class={wrapper_classes(@mode, @active)}>
      <%= case @block.type do %>
        <% :text -> %>
          <.render_text block={@block} mode={@mode} />
        <% :image -> %>
          <.render_image block={@block} mode={@mode} />
        <% :video -> %>
          <.render_video block={@block} mode={@mode} />
        <% :attachment -> %>
          <.render_attachment block={@block} mode={@mode} />
        <% :code -> %>
          <.render_code
            block={@block}
            mode={@mode}
            answers={@answers}
            submission={@submission}
            attempts_count={@attempts_count}
            draft={@draft}
            hide_submit={@hide_submit}
          />
        <% :quiz_question -> %>
          <.render_quiz_question
            block={@block}
            mode={@mode}
            answers={@answers}
            submission={@submission}
            attempts_count={@attempts_count}
            draft={@draft}
          />
        <% type when type in [:quiz_exam, :ticket_exam] -> %>
          <.render_any_exam
            block={@block}
            mode={@mode}
            submission={@submission}
            hide_submit={@hide_submit}
          />
        <% :file_assignment -> %>
          <.render_file_assignment
            block={@block}
            mode={@mode}
            submission={@submission}
            pending_file_urls={@pending_file_urls}
            draft={@draft}
          />
        <% _ -> %>
          <div class="p-4 text-warning italic border border-warning/20 bg-warning/5 rounded-sm">
            {gettext("Unknown block type: %{type}", type: @block.type)}
          </div>
      <% end %>
    </div>
    """
  end

  defp wrapper_classes(:edit, true),
    do: "p-5 rounded-sm border-2 border-primary bg-base-100 transition-all"

  defp wrapper_classes(:edit, false),
    do:
      "p-5 rounded-sm border border-base-300 hover:border-primary/50 bg-base-100 transition-all cursor-pointer opacity-80 hover:opacity-100"

  defp wrapper_classes(:play, _), do: "mb-10 last:mb-0 w-full"
  defp wrapper_classes(:review, _), do: "mb-10 last:mb-0 w-full"

  defp wrapper_classes(:preview, true),
    do: "p-5 rounded-sm border-2 border-base-300 bg-base-100 transition-all cursor-default"

  defp wrapper_classes(:preview, false),
    do:
      "p-5 rounded-sm border border-base-200 bg-base-100 transition-all opacity-80 cursor-default"

  defp render_text(assigns) do
    ~H"""
    <div class="editor-wrapper group/tiptap relative outline-none" tabindex="-1">
      <.tiptap_toolbar mode={@mode} />
      <div
        id={"tiptap-#{@mode}-#{@block.id}-#{if @mode != :edit, do: :erlang.phash2(@block.content), else: "static"}"}
        phx-hook="TiptapEditor"
        data-id={@block.id}
        data-readonly={to_string(@mode != :edit)}
        phx-update="ignore"
        data-on-change="update_content"
        data-content={Jason.encode!(@block.content)}
        class="prose prose-base md:prose-lg max-w-none text-base-content/80 leading-relaxed"
      >
      </div>
    </div>
    """
  end

  defp render_image(assigns) do
    ~H"""
    <%= if @block.content["url"] do %>
      <figure class="m-0">
        <img
          src={@block.content["url"]}
          alt={@block.content["alt"]}
          class="rounded-sm w-full object-cover border border-base-200"
        />
      </figure>
    <% else %>
      <div class="p-8 border-2 border-dashed border-base-300 rounded-sm text-center text-base-content/40 bg-base-200/50">
        <.icon name="hero-photo" class="size-8 mb-2 opacity-50" />
        <div>{gettext("Image not uploaded yet")}</div>
      </div>
    <% end %>
    """
  end

  defp render_video(assigns) do
    ~H"""
    <%= if @block.content["url"] do %>
      <video
        src={@block.content["url"]}
        poster={@block.content["poster_url"]}
        controls={@block.content["controls"] not in [false, "false"]}
        class="rounded-sm w-full bg-black aspect-video"
      />
    <% else %>
      <div class="p-10 border-2 border-dashed border-base-300 rounded-sm text-center text-base-content/40 bg-base-200/50">
        <.icon name="hero-video-camera" class="size-8 mb-2 opacity-50" />
        <div>{gettext("Video not uploaded yet")}</div>
      </div>
    <% end %>
    """
  end

  defp render_attachment(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="editor-wrapper group/tiptap relative outline-none" tabindex="-1">
        <.tiptap_toolbar mode={@mode} />
        <div
          :if={@block.content["description"]}
          id={"tiptap-desc-#{@mode}-#{@block.id}-#{if @mode != :edit, do: :erlang.phash2(@block.content["description"]), else: "static"}"}
          phx-hook="TiptapEditor"
          data-on-change="update_content"
          data-id={@block.id}
          data-readonly={to_string(@mode != :edit)}
          phx-update="ignore"
          data-content={Jason.encode!(@block.content["description"])}
          class="prose prose-base md:prose-lg max-w-none text-base-content/80 leading-relaxed mb-4"
        >
        </div>
      </div>
      <div class="space-y-3">
        <a
          :for={file <- @block.content["files"] || []}
          href={file["url"]}
          target="_blank"
          rel="noopener noreferrer"
          class="flex items-center gap-4 p-4 bg-base-100 rounded-sm border border-base-200 hover:border-primary/40 transition-all group"
        >
          <div class="p-3 bg-primary/10 rounded-sm text-primary shrink-0 group-hover:scale-110 transition-transform">
            <.icon name="hero-document-arrow-down" class="size-6" />
          </div>
          <div class="flex-1 min-w-0">
            <div class="font-bold text-base-content truncate group-hover:text-primary transition-colors">
              {file["name"]}
            </div>
          </div>
        </a>
      </div>
    </div>
    """
  end

  defp render_code(assigns) do
    code =
      compute_code_for_mode(
        assigns.mode,
        assigns.block,
        assigns.draft,
        assigns[:answers],
        assigns[:submission]
      )

    lang = assigns.block.content["language"] || "python3"
    is_processing = !!(assigns.submission && assigns.submission.status in [:pending, :processing])
    readonly = !!(assigns.mode not in [:edit, :play] or is_processing)
    execution_results = resolve_execution_results(assigns.draft, assigns.submission)

    assigns =
      assigns
      |> assign(:code, code)
      |> assign(:cm_lang, map_cm_lang(lang))
      |> assign(:readonly, readonly)
      |> assign(:execution_results, execution_results)
      |> assign(:is_processing, is_processing)

    ~H"""
    <div class="relative w-full">
      <div class="editor-wrapper group/tiptap relative outline-none mb-6" tabindex="-1">
        <.tiptap_toolbar mode={@mode} />
        <div
          id={"tiptap-code-#{@mode}-#{@block.id}"}
          phx-hook="TiptapEditor"
          data-on-change="update_content"
          data-id={@block.id}
          data-readonly={to_string(@mode != :edit)}
          phx-update="ignore"
          data-content={Jason.encode!(@block.content["body"] || %{})}
          class="prose prose-base md:prose-lg max-w-none text-base-content/80 leading-relaxed"
        >
        </div>
      </div>

      <label class="label flex justify-between">
        <span class="label-text font-bold text-xs uppercase text-base-content/70">
          {@block.content["language"] || "python3"}
        </span>
        <span :if={@mode == :edit} class="label-text font-bold text-xs uppercase text-base-content/70">
          {gettext("Initial Code (Template)")}
        </span>
      </label>

      <div class="overflow-hidden rounded-sm border border-base-300 bg-base-200 dark:bg-[#282c34]">
        <div class="relative w-full">
          <form
            :if={@mode == :edit}
            id={"code-form-#{@block.id}"}
            phx-change="update_block_meta"
            phx-target={assigns[:target]}
          >
            <input type="hidden" name="block[id]" value={@block.id} />
            <input
              type="hidden"
              id={"code-input-#{@block.id}"}
              name="block[content][initial_code]"
              value={@code}
            />
          </form>

          <%= if @mode == :play do %>
            <input
              type="hidden"
              id={"code-input-#{@block.id}"}
              name="answer[code]"
              value={@code}
              phx-change="save_draft"
              phx-value-block_id={@block.id}
              phx-debounce="500"
            />
          <% end %>

          <div
            id={"code-editor-#{@mode}-#{@block.id}-#{if @mode == :review, do: :erlang.phash2(@code), else: "static"}"}
            phx-hook="CodeEditor"
            data-language={@cm_lang}
            data-readonly={to_string(@readonly)}
            data-code={@code}
            data-input-id={"code-input-#{@block.id}"}
            phx-update="ignore"
            class="w-full text-sm font-mono outline-none"
          >
          </div>
        </div>
      </div>

      <%= if @execution_results != [] do %>
        <div class="mt-2 bg-base-300/20 rounded-sm border border-base-300 overflow-hidden">
          <table class="table table-xs w-full font-mono">
            <thead class="bg-base-300/50 uppercase tracking-widest text-[10px]">
              <tr>
                <th class="w-12">#</th>
                <th class="w-32">{gettext("Result")}</th>
                <th>{gettext("Details")}</th>
                <th class="text-right">{gettext("Time")}</th>
              </tr>
            </thead>
            <tbody>
              <%= for {res, idx} <- Enum.with_index(@execution_results) do %>
                <tr class="border-base-300">
                  <td class="opacity-40">{idx + 1}</td>
                  <td class={
                    if res["status"] == "accepted",
                      do: "text-success font-bold",
                      else: "text-error font-bold"
                  }>
                    {String.upcase(res["status"])}
                  </td>
                  <td>
                    <%= if res["is_hidden"] do %>
                      <span class="opacity-30 italic flex items-center gap-1 text-[10px]">
                        <.icon name="hero-eye-slash" class="size-3" />
                        {gettext("Hidden Test")}
                      </span>
                    <% else %>
                      <%= if res["status"] != "accepted" do %>
                        <div class="text-[10px] space-y-1">
                          <div class="flex gap-1">
                            <span class="font-bold opacity-40">IN:</span><span>{res["input"]}</span>
                          </div>
                          <div class="flex gap-1">
                            <span class="font-bold text-error/60">GOT:</span><span class="text-error">{res["stdout"]}</span>
                          </div>
                          <div class="flex gap-1 border-t border-base-300 pt-1">
                            <span class="font-bold text-success/60">EXP:</span><span class="text-success">{res["expected"]}</span>
                          </div>
                        </div>
                      <% else %>
                        <span class="opacity-20 text-[10px]">---</span>
                      <% end %>
                    <% end %>
                  </td>
                  <td class="text-right opacity-50 text-[10px]">{res["time"]}s</td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>

      <%= if @mode in [:play, :review] do %>
        <div class="mt-6 space-y-4">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-3">
              <button
                type="button"
                phx-click="run_code"
                phx-value-block_id={@block.id}
                class="btn btn-outline btn-sm"
                disabled={@readonly}
              >
                <.icon name="hero-play" class="size-4 mr-1" /> {gettext("Run")}
              </button>

              <button
                :if={not @hide_submit}
                type="submit"
                class="btn btn-primary btn-sm"
                disabled={@readonly || @is_processing}
              >
                <%= cond do %>
                  <% @is_processing -> %>
                    <span class="loading loading-spinner loading-xs"></span> {gettext("Checking...")}
                  <% @readonly -> %>
                    {gettext("Locked")}
                  <% @submission != nil -> %>
                    {gettext("Resubmit")}
                  <% true -> %>
                    {gettext("Submit")}
                <% end %>
              </button>
            </div>

            <span :if={@block.content["max_attempts"]} class="text-xs text-base-content/50">
              {gettext("Attempts:")} {@attempts_count} / {@block.content["max_attempts"]}
            </span>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp resolve_execution_results(draft, submission) do
    draft_results = if draft, do: Map.get(draft, "execution_results") || [], else: []

    if draft_results != [] do
      draft_results
    else
      extract_execution_results(submission)
    end
  end

  defp extract_execution_results(nil), do: []

  defp extract_execution_results(submission) do
    content_map =
      if is_struct(submission.content),
        do: Map.from_struct(submission.content),
        else: submission.content || %{}

    Map.get(content_map, "execution_results") || Map.get(content_map, :execution_results) || []
  end

  defp compute_code_for_mode(:edit, block, _draft, _answers, _submission),
    do: block.content["initial_code"] || ""

  defp compute_code_for_mode(:play, block, draft, answers, submission) do
    extract_code_answer(block.id, answers, submission, draft) ||
      block.content["initial_code"] || ""
  end

  defp compute_code_for_mode(_other_mode, block, _draft, answers, submission) do
    extract_code_answer(block.id, answers, submission, nil) ||
      block.content["initial_code"] || ""
  end

  defp extract_code_answer(block_id, answers, submission, draft) do
    live_answer = Map.get(answers || %{}, block_id)

    cond do
      present?(live_answer) ->
        do_extract_code(live_answer)

      present?(submission) and present?(do_extract_code(submission)) ->
        do_extract_code(submission)

      present?(draft) ->
        do_extract_code(draft)

      true ->
        nil
    end
  end

  defp do_extract_code(%Athena.Learning.Submission{content: content}),
    do: do_extract_code(content)

  defp do_extract_code(%Athena.Learning.SubmissionContent{} = content) do
    Map.get(content, :code) || Map.get(content, :text_answer)
  end

  defp do_extract_code(%{content: content}) when is_map(content), do: do_extract_code(content)
  defp do_extract_code(%{"content" => content}) when is_map(content), do: do_extract_code(content)

  defp do_extract_code(%{} = map) when not is_struct(map) do
    map["code"] || map[:code] || map["text_answer"] || map[:text_answer]
  end

  defp do_extract_code(val) when is_binary(val) and val != "", do: val
  defp do_extract_code(_), do: nil

  defp map_cm_lang("cpp"), do: "cpp"
  defp map_cm_lang("sql"), do: "sql"
  defp map_cm_lang(_), do: "python"

  defp render_quiz_question(assigns) do
    q_type = assigns.block.content["question_type"] || "open"
    opts = assigns.block.content["options"] || []

    assigns =
      assigns
      |> assign(:q_type, q_type)
      |> assign(:options, opts)
      |> assign(:answer, extract_quiz_answer(assigns, q_type))

    ~H"""
    <div class="relative">
      <div class="editor-wrapper group/tiptap relative outline-none" tabindex="-1">
        <.tiptap_toolbar mode={@mode} />
        <div
          id={"tiptap-quiz-#{@mode}-#{@block.id}-#{if @mode != :edit, do: :erlang.phash2(@block.content["body"]), else: "static"}"}
          phx-hook="TiptapEditor"
          data-on-change="update_content"
          data-id={@block.id}
          data-readonly={to_string(@mode != :edit)}
          phx-update="ignore"
          data-content={Jason.encode!(@block.content["body"] || %{})}
          class="prose prose-base md:prose-lg max-w-none text-base-content/80 leading-relaxed mb-6"
        >
        </div>

        <%= if @mode == :review && @block.content["general_explanation"] not in [nil, ""] do %>
          <div class="text-sm mb-2 text-base-content/70">
            {@block.content["general_explanation"]}
          </div>
        <% end %>
      </div>

      <div>
        <.render_quiz_inputs
          block={@block}
          mode={@mode}
          q_type={@q_type}
          options={@options}
          answer={@answer}
          submission={@submission}
          draft={@draft}
        />
      </div>
    </div>
    """
  end

  defp extract_quiz_answer(assigns, q_type) do
    answer_type = assigns.block.content["answer_type"] || "plain_text"

    live_answer = Map.get(assigns.answers || %{}, assigns.block.id)

    if present?(live_answer) do
      if is_struct(live_answer, Athena.Learning.Submission) do
        extract_from_submission(live_answer, q_type, answer_type)
      else
        live_answer
      end
    else
      sub_answer = extract_from_submission(assigns[:submission], q_type, answer_type)

      if present?(sub_answer) do
        sub_answer
      else
        extract_from_draft(assigns[:draft], q_type, answer_type)
      end
    end
  end

  defp extract_from_submission(nil, _q_type, _answer_type), do: nil

  defp extract_from_submission(submission, q_type, answer_type)
       when q_type in ["exact_match", "open"] do
    content =
      if is_struct(submission) do
        if is_struct(submission.content),
          do: Map.from_struct(submission.content),
          else: submission.content || %{}
      else
        Map.get(submission, :content) || Map.get(submission, "content") || %{}
      end

    if answer_type == "rich_text" do
      Map.get(content, "rich_answer") || Map.get(content, :rich_answer)
    else
      Map.get(content, "text_answer") || Map.get(content, :text_answer)
    end
  end

  defp extract_from_submission(submission, _q_type, _answer_type) do
    content =
      if is_struct(submission) do
        if is_struct(submission.content),
          do: Map.from_struct(submission.content),
          else: submission.content || %{}
      else
        Map.get(submission, :content) || Map.get(submission, "content") || %{}
      end

    Map.get(content, "selected_choices") || Map.get(content, :selected_choices)
  end

  defp present?(val), do: not is_nil(val) and val != "" and val != []

  defp extract_from_draft(nil, _q_type, _answer_type), do: nil

  defp extract_from_draft(draft, q_type, answer_type) when q_type in ["exact_match", "open"] do
    if answer_type == "rich_text" do
      draft["rich_answer"] || draft[:rich_answer]
    else
      draft["text_answer"] || draft[:text_answer]
    end
  end

  defp extract_from_draft(draft, _q_type, _answer_type) do
    draft["selected_choices"] || draft[:selected_choices]
  end

  defp render_quiz_inputs(%{q_type: "exact_match"} = assigns) do
    answer_content = assigns.answer || extract_draft_text_answer(assigns.draft)
    assigns = assign(assigns, :answer_content, answer_content)

    ~H"""
    <div class="flex flex-col gap-2 max-w-md">
      <input
        type="text"
        name="answer"
        value={@answer_content}
        placeholder={if @mode == :play, do: gettext("Type your answer..."), else: ""}
        class="input w-full font-mono text-lg bg-base-100 disabled:opacity-70 disabled:text-base-content"
        disabled={@mode != :play}
        phx-change={if @mode == :play, do: "save_draft", else: nil}
        phx-value-block_id={@block.id}
        phx-debounce="500"
      />
      <%= if @mode == :review do %>
        <div class="text-sm mt-2 flex items-center gap-2">
          <span class="font-bold text-success">
            <.icon name="hero-check-circle" class="size-4 inline" /> {gettext("Correct:")}
          </span>
          <span class="font-mono bg-base-300 px-2 py-0.5 rounded-sm">
            {@block.content["correct_answer"]}
          </span>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_quiz_inputs(%{q_type: "open"} = assigns) do
    answer_type = assigns.block.content["answer_type"] || "plain_text"
    answer_content = fetch_open_answer_content(assigns.answer, assigns.draft, answer_type)
    assigns = assign(assigns, :answer_content, answer_content)

    case answer_type do
      "rich_text" -> render_open_rich(assigns)
      _ -> render_open_plain(assigns)
    end
  end

  defp render_quiz_inputs(%{q_type: q_type} = assigns) when q_type in ["single", "multiple"] do
    ~H"""
    <div class="space-y-3">
      <%= for opt <- @options do %>
        <% is_selected = opt["id"] in List.wrap(@answer) %>
        <% is_correct = opt["is_correct"] in [true, "true"] %>

        <label class={[
          "flex items-start gap-4 p-4 rounded-sm transition-all",
          @mode == :play &&
            "hover:bg-base-200/50 cursor-pointer has-checked:bg-primary/5 has-checked:border-primary",
          @mode == :review && is_selected && is_correct &&
            "bg-success/10 border-success/30",
          @mode == :review && is_selected && not is_correct &&
            "bg-error/10 border-error/30",
          @mode == :review && not is_selected && is_correct &&
            "bg-base-100 border-2 border-success/30",
          @mode == :review && (not is_selected and not is_correct) &&
            "bg-base-100 border-base-300 opacity-60",
          @mode in [:edit, :preview] && "bg-base-100 border-base-200 opacity-60 pointer-events-none"
        ]}>
          <input
            type={if @q_type == "single", do: "radio", else: "checkbox"}
            name={if @q_type == "single", do: "answer", else: "answer[]"}
            value={opt["id"]}
            checked={is_selected}
            class={
              if @q_type == "single",
                do: "radio radio-primary mt-0.5",
                else: "checkbox checkbox-primary mt-0.5"
            }
            disabled={@mode != :play}
            phx-change={if @mode == :play, do: "save_draft", else: nil}
            phx-value-block_id={@block.id}
            phx-debounce="300"
          />
          <div class="flex-1 min-w-0 pt-0.5">
            <div
              id={"tiptap-player-opt-#{@block.id}-#{opt["id"]}-#{if @mode != :edit, do: :erlang.phash2(opt["text"]), else: "static"}"}
              phx-hook="TiptapEditor"
              data-id={@block.id}
              data-readonly="true"
              phx-update="ignore"
              data-content={
                if is_map(opt["text"]),
                  do: Jason.encode!(opt["text"]),
                  else: Jason.encode!(wrap_text_in_paragraph(opt["text"]))
              }
              class="prose prose-base max-w-none text-base-content pointer-events-none [&_p]:my-0"
            >
            </div>
            <%= if @mode == :review do %>
              <div
                :if={opt["explanation"] not in [nil, ""]}
                class="text-sm mt-2 text-base-content/70"
              >
                {opt["explanation"]}
              </div>
            <% end %>
          </div>
        </label>
      <% end %>
    </div>
    """
  end

  @doc false
  defp fetch_open_answer_content(answer, draft, "rich_text"),
    do: answer || extract_draft_rich_answer(draft)

  defp fetch_open_answer_content(answer, draft, _), do: answer || extract_draft_text_answer(draft)

  @doc false
  defp render_open_rich(assigns) do
    initial_content = build_initial_tip_tap_content(assigns.answer_content)
    assigns = assign(assigns, :initial_content, initial_content)

    ~H"""
    <div class="relative">
      <input
        type="hidden"
        name="answer"
        id={"open-answer-#{@block.id}"}
        value={
          if is_map(@answer_content), do: Jason.encode!(@answer_content), else: @answer_content || ""
        }
        phx-change={if @mode == :play, do: "save_draft", else: nil}
        phx-value-block_id={@block.id}
        phx-debounce="500"
      />
      <div class="editor-wrapper group/tiptap relative outline-none" tabindex="-1">
        <.tiptap_toolbar mode={:edit} />
        <div
          id={"tiptap-open-answer-#{@mode}-#{@block.id}-#{if @mode == :review, do: :erlang.phash2(@initial_content), else: "static"}"}
          phx-hook="TiptapEditor"
          data-id={@block.id}
          data-input-id={"open-answer-#{@block.id}"}
          data-readonly={to_string(@mode != :play)}
          phx-update="ignore"
          data-content={Jason.encode!(@initial_content)}
          class={[
            "prose prose-base md:prose-lg max-w-none text-base-content/80 leading-relaxed",
            @mode != :play && "opacity-70 cursor-not-allowed"
          ]}
        >
        </div>
      </div>
    </div>
    """
  end

  @doc false
  defp render_open_plain(assigns) do
    ~H"""
    <textarea
      name="answer"
      rows="5"
      placeholder={if @mode == :play, do: gettext("Write your detailed answer here..."), else: ""}
      class="textarea w-full text-base leading-relaxed bg-base-100 disabled:opacity-70 disabled:text-base-content"
      disabled={@mode != :play}
      phx-change={if @mode == :play, do: "save_draft", else: nil}
      phx-value-block_id={@block.id}
      phx-debounce="500"
    ><%= @answer_content %></textarea>
    """
  end

  @doc false
  defp build_initial_tip_tap_content(nil), do: empty_tip_tap_doc()
  defp build_initial_tip_tap_content(""), do: empty_tip_tap_doc()

  defp build_initial_tip_tap_content(content) when is_binary(content) do
    if String.starts_with?(content, "{") do
      case Jason.decode(content) do
        {:ok, decoded} -> decoded
        _ -> wrap_text_in_paragraph(content)
      end
    else
      wrap_text_in_paragraph(content)
    end
  end

  @doc false
  defp build_initial_tip_tap_content(content) when is_map(content), do: content
  defp build_initial_tip_tap_content(content), do: wrap_text_in_paragraph(to_string(content))

  @doc false
  defp empty_tip_tap_doc(), do: %{"type" => "doc", "content" => [%{"type" => "paragraph"}]}

  @doc false
  defp wrap_text_in_paragraph(text),
    do: %{
      "type" => "doc",
      "content" => [%{"type" => "paragraph", "content" => [%{"type" => "text", "text" => text}]}]
    }

  @doc false
  defp extract_draft_rich_answer(nil), do: nil

  defp extract_draft_rich_answer(draft) when is_map(draft) do
    draft["rich_answer"] || draft[:rich_answer] || draft["text_answer"] || draft[:text_answer]
  end

  @doc false
  defp extract_draft_text_answer(nil), do: nil

  defp extract_draft_text_answer(draft) when is_map(draft) do
    draft["text_answer"] || draft[:text_answer] || draft["selected_choices"] ||
      draft[:selected_choices]
  end

  defp render_any_exam(assigns) do
    is_ticket = assigns.block.type == :ticket_exam

    q_count =
      if is_ticket do
        length(assigns.block.content["slots"] || [])
      else
        assigns.block.content["count"] || 10
      end

    title = if is_ticket, do: gettext("Ticket Assessment"), else: gettext("Assessment Session")
    icon = if is_ticket, do: "hero-document-duplicate-solid", else: "hero-academic-cap-solid"

    assigns =
      assigns
      |> assign(:q_count, q_count)
      |> assign(:exam_title, title)
      |> assign(:exam_icon, icon)
      |> assign_new(:hide_submit, fn -> false end)

    ~H"""
    <div class="p-8 bg-base-100 rounded-sm border border-base-300 text-center">
      <div class="size-16 bg-primary/10 text-primary rounded-sm flex items-center justify-center mx-auto mb-4">
        <.icon name={@exam_icon} class="size-8" />
      </div>
      <h3 class="text-2xl font-black mb-2">{@exam_title}</h3>
      <div class="flex items-center justify-center gap-4 text-sm font-bold text-base-content/60 uppercase tracking-widest">
        <span>{@q_count} {gettext("Questions")}</span>
        <span :if={@block.content["time_limit"]}>
          • {@block.content["time_limit"]} {gettext("Min")}
        </span>
      </div>

      <div class="mt-8">
        <%= if @submission do %>
          <%= cond do %>
            <% @submission.status == :graded && (@submission.content["cheat_count"] || 0) >= (@block.content["allowed_blur_attempts"] || 3) -> %>
              <div class="inline-flex items-center gap-2 text-xl font-black text-error bg-error/10 border border-error/30 px-6 py-3 rounded-sm">
                <.icon name="hero-x-circle-solid" class="size-6" />
                {gettext("Assessment Failed (Violations)")}
              </div>
            <% @submission.status in [:graded, :needs_review, :rejected] -> %>
              <div class="inline-flex flex-col items-center gap-2">
                <div class={[
                  "inline-flex items-center gap-3 font-black px-4 py-2 rounded-sm",
                  @submission.status == :graded && "text-success",
                  @submission.status == :needs_review &&
                    "text-warning",
                  @submission.status == :rejected && "text-error"
                ]}>
                  <.icon
                    name={
                      case @submission.status do
                        :graded -> "hero-check-circle-solid"
                        :needs_review -> "hero-clock-solid"
                        :rejected -> "hero-x-circle-solid"
                        _ -> "hero-information-circle-solid"
                      end
                    }
                    class="size-5"
                  />
                  {gettext("Assessment Completed")}
                  <span class="opacity-30">|</span>
                  <span>{@submission.score || 0} / 100</span>
                </div>
                <%= if @submission.status == :needs_review do %>
                  <span class="text-xs font-bold uppercase tracking-widest mt-2">
                    {gettext("Pending Instructor Review")}
                  </span>
                <% end %>
              </div>
            <% @submission.status in [:pending, :draft, :processing] and @mode == :play and not @hide_submit -> %>
              <button
                phx-click="continue_exam"
                phx-value-block_id={@block.id}
                class="btn btn-primary px-12"
              >
                {gettext("Continue Assessment")}
                <.icon name="hero-arrow-right" class="size-5 ml-2" />
              </button>
            <% true -> %>
          <% end %>
        <% else %>
          <%= if @mode == :play do %>
            <button
              phx-click="start_exam"
              phx-value-block_id={@block.id}
              class="btn btn-primary px-10"
            >
              {gettext("Start Assessment")} <.icon name="hero-play-solid" class="size-4 ml-2" />
            </button>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_file_assignment(assigns) do
    body_content = assigns.block.content["body"] || %{}
    max_files = assigns.block.content["max_files"] || 1

    pending_urls = Map.get(assigns.pending_file_urls, assigns.block.id, [])
    pending_count = length(pending_urls)
    remaining = max(0, max_files - pending_count)

    assigns =
      assigns
      |> assign(:body_content, body_content)
      |> assign(:max_files, max_files)
      |> assign(:file_urls, extract_file_urls(assigns))
      |> assign(:has_submitted, !is_nil(assigns.submission))
      |> assign(:pending_urls, pending_urls)
      |> assign(:remaining, remaining)

    ~H"""
    <div class="space-y-6">
      <div class="editor-wrapper group/tiptap relative outline-none">
        <.tiptap_toolbar mode={@mode} />
        <div
          id={"tiptap-body-#{@mode}-#{@block.id}-#{if @mode != :edit, do: :erlang.phash2(@body_content), else: "static"}"}
          phx-hook="TiptapEditor"
          data-on-change="update_content"
          data-id={@block.id}
          data-readonly={to_string(@mode != :edit)}
          phx-update="ignore"
          data-content={Jason.encode!(@body_content)}
          class="prose prose-base md:prose-lg max-w-none text-base-content/80 leading-relaxed"
        >
        </div>
      </div>

      <%= if @mode == :edit do %>
        <div class="text-sm text-base-content/50 italic bg-base-200/50 p-4 rounded-sm border border-dashed border-base-300">
          {gettext("Student will be able to upload up to %{max} file(s).", max: @max_files)}
        </div>
      <% end %>

      <div :if={@mode == :play} class="space-y-4">
        <div
          :if={@remaining > 0}
          class="border-2 border-dashed border-base-300 rounded-sm p-8 text-center bg-base-200/30"
        >
          <.icon name="hero-cloud-arrow-up" class="size-12 mx-auto text-base-content/40 mb-4" />
          <p class="text-base-content/70 mb-2">
            {gettext("You can upload %{count} more file(s)", count: @remaining)}
          </p>
          <p class="text-xs text-base-content/50 mb-4">
            {Athena.Media.Config.format_extensions("file_assignment")}
          </p>
          <button
            type="button"
            phx-click="request_media_upload"
            phx-value-block_id={@block.id}
            phx-value-media_type="file_assignment"
            class="btn btn-primary"
          >
            <.icon name="hero-document-plus" class="size-4 mr-2" />
            {gettext("Select Files")}
          </button>
        </div>

        <div
          :if={@remaining == 0}
          class="p-4 bg-base-200/50 rounded-sm border border-base-300 text-center"
        >
          <.icon name="hero-lock-closed" class="size-6 mx-auto text-base-content/40 mb-2" />
          <p class="text-sm font-medium text-base-content/70">
            {gettext("Maximum file limit reached.")}
          </p>
        </div>

        <div :if={@pending_urls != []} class="space-y-2">
          <div
            :for={url <- @pending_urls}
            class="flex items-center justify-between gap-3 p-3 bg-base-100 border border-base-200 rounded-sm"
          >
            <div class="flex items-center gap-2 min-w-0">
              <.icon name="hero-document-check" class="size-4 text-success shrink-0" />
              <span class="text-sm truncate flex-1 font-medium">{clean_filename(url)}</span>
            </div>
            <button
              type="button"
              phx-click="remove_pending_file"
              phx-value-block_id={@block.id}
              phx-value-url={url}
              class="btn btn-ghost btn-sm btn-square min-h-9 h-9 w-9 text-error shrink-0"
              title={gettext("Remove")}
            >
              <.icon name="hero-trash" class="size-4" />
            </button>
          </div>
        </div>
      </div>

      <div :if={@has_submitted && @mode != :play} class="space-y-4">
        <div :if={@file_urls != []} class="space-y-3">
          <a
            :for={url <- @file_urls}
            href={url}
            target="_blank"
            rel="noopener noreferrer"
            class="flex items-center gap-4 p-4 bg-base-100 rounded-sm border border-base-200 hover:border-primary/40 transition-all group"
          >
            <div class="p-3 bg-primary/10 rounded-sm text-primary shrink-0 group-hover:scale-110 transition-transform">
              <.icon name="hero-document-arrow-down" class="size-6" />
            </div>
            <div class="flex-1 min-w-0">
              <div class="font-bold text-base-content truncate group-hover:text-primary transition-colors">
                {clean_filename(url)}
              </div>
            </div>
          </a>
        </div>
      </div>
    </div>
    """
  end

  @doc false
  defp extract_file_urls(assigns) do
    cond do
      assigns.submission && assigns.submission.content["file_urls"] ->
        assigns.submission.content["file_urls"]

      assigns.submission && assigns.submission.content[:file_urls] ->
        assigns.submission.content[:file_urls]

      true ->
        []
    end
  end

  @doc """
  Contextual editor panels for specific block types (Quiz options, File manager).
  Used in both Builder Canvas and Library Editor.
  """
  attr :block, :map, required: true
  attr :target, :any, default: nil

  def block_editor(assigns) do
    ~H"""
    <div>
      <%= if @block.type == :quiz_question do %>
        <div class="mt-2 p-6 bg-base-100 border-l border-r border-b border-base-300 rounded-sm border-t-4 border-t-primary animate-in slide-in-from-top-2 duration-200">
          <div class="text-xs font-bold uppercase tracking-widest text-primary mb-4 border-b border-base-200 pb-2">
            {gettext("Answer Editor")}
          </div>
          <form
            phx-change="update_quiz_content"
            phx-submit="ignore"
            phx-target={@target}
            id={"quiz-form-#{@block.id}"}
          >
            <input type="hidden" name="block_id" value={@block.id} />

            <%= case @block.content["question_type"] do %>
              <% "exact_match" -> %>
                <fieldset class="fieldset">
                  <label class="label">
                    <span class="label-text font-bold text-xs uppercase text-base-content/70">
                      {gettext("Correct Answer (Flag)")}
                    </span>
                  </label>
                  <div class="flex items-center gap-3">
                    <.icon name="hero-flag" class="size-5 text-primary" />
                    <input
                      type="text"
                      name="correct_answer"
                      value={@block.content["correct_answer"]}
                      class="input flex-1 font-mono"
                      phx-debounce="500"
                    />
                  </div>
                </fieldset>
              <% type when type in ["single", "multiple"] -> %>
                <div class="space-y-3">
                  <%= for {opt, index} <- Enum.with_index(@block.content["options"] || []) do %>
                    <div class="flex items-start gap-3 group relative">
                      <div class="pt-3 cursor-pointer">
                        <%= if type == "single" do %>
                          <input
                            type="radio"
                            name="correct_option_id"
                            value={opt["id"]}
                            checked={opt["is_correct"] in [true, "true"]}
                            class="radio radio-primary radio-sm"
                          />
                          <input type="hidden" name={"options[#{index}][is_correct]"} value="false" />
                        <% else %>
                          <input type="hidden" name={"options[#{index}][is_correct]"} value="false" />
                          <input
                            type="checkbox"
                            name={"options[#{index}][is_correct]"}
                            value="true"
                            checked={opt["is_correct"] in [true, "true"]}
                            class="checkbox checkbox-primary checkbox-sm"
                          />
                        <% end %>
                      </div>
                      <div class="flex-1 bg-base-100/50 p-2 rounded-sm border border-base-200/50 focus-within:border-2 focus-within:border-primary space-y-2">
                        <input type="hidden" name={"options[#{index}][id]"} value={opt["id"]} />

                        <div
                          class="editor-wrapper group/tiptap relative outline-none w-full"
                          tabindex="-1"
                        >
                          <.tiptap_toolbar mode={:edit} />
                          <input
                            type="hidden"
                            id={"option-text-#{@block.id}-#{opt["id"]}"}
                            name={"options[#{index}][text]"}
                            value={
                              if is_map(opt["text"]),
                                do: Jason.encode!(opt["text"]),
                                else: Jason.encode!(wrap_text_in_paragraph(opt["text"]))
                            }
                          />
                          <div
                            id={"tiptap-option-#{@block.id}-#{opt["id"]}"}
                            phx-hook="TiptapEditor"
                            data-id={@block.id}
                            data-input-id={"option-text-#{@block.id}-#{opt["id"]}"}
                            data-readonly="false"
                            phx-update="ignore"
                            data-content={
                              if is_map(opt["text"]),
                                do: Jason.encode!(opt["text"]),
                                else: Jason.encode!(wrap_text_in_paragraph(opt["text"]))
                            }
                            class="prose prose-sm max-w-none text-base-content/80 leading-relaxed min-h-10 px-3 py-2 bg-base-100 rounded-sm cursor-text [&_p]:my-1"
                          >
                          </div>
                        </div>

                        <input
                          type="text"
                          name={"options[#{index}][explanation]"}
                          value={opt["explanation"]}
                          class="w-full bg-transparent border-none outline-none focus:ring-0 text-sm text-base-content/60 px-3"
                          placeholder={gettext("Explanation (optional)")}
                          phx-debounce="500"
                        />
                      </div>
                      <div class="pt-2 opacity-0 group-hover:opacity-100">
                        <button
                          type="button"
                          phx-click="remove_quiz_option"
                          phx-value-id={@block.id}
                          phx-value-option_id={opt["id"]}
                          phx-target={@target}
                          class="btn btn-ghost btn-sm btn-square text-error"
                        >
                          <.icon name="hero-x-mark" class="size-5" />
                        </button>
                      </div>
                    </div>
                  <% end %>
                </div>
                <button
                  type="button"
                  phx-click="add_quiz_option"
                  phx-value-id={@block.id}
                  phx-target={@target}
                  class="btn btn-ghost btn-sm mt-4 text-primary font-bold"
                >
                  <.icon name="hero-plus" class="size-4 mr-1" /> {gettext("Add Option")}
                </button>
              <% "open" -> %>
                <div class="text-sm text-base-content/50 italic bg-base-200/50 p-4 rounded-sm border border-dashed border-base-300">
                  {gettext("Student will see a text area to write their open answer.")}
                </div>
              <% _ -> %>
            <% end %>
          </form>
        </div>
      <% end %>

      <%= if @block.type == :attachment do %>
        <div class="mt-2 p-4 bg-base-100 border border-base-300 rounded-sm animate-in slide-in-from-top-2 duration-200">
          <div class="text-xs font-bold uppercase tracking-widest text-primary mb-3">
            {gettext("Manage Files")}
          </div>
          <div class="space-y-2">
            <div
              :for={file <- @block.content["files"] || []}
              class="flex items-center justify-between p-2 bg-base-200/50 border border-base-300 rounded-sm"
            >
              <div class="flex items-center gap-2 min-w-0">
                <.icon name="hero-document" class="size-4 text-base-content/50 shrink-0" />
                <span class="text-sm truncate flex-1 font-medium">{file["name"]}</span>
              </div>
              <button
                phx-click="delete_attachment"
                phx-value-block_id={@block.id}
                phx-value-url={file["url"]}
                phx-target={@target}
                class="btn btn-ghost btn-xs btn-square text-error shrink-0"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </div>
          </div>
          <button
            phx-click="request_media_upload"
            phx-value-block_id={@block.id}
            phx-value-media_type="attachment"
            phx-target={@target}
            class="btn btn-primary btn-sm mt-3 w-full"
          >
            <.icon name="hero-cloud-arrow-up" class="size-4 mr-1" /> {gettext("Upload File")}
          </button>
        </div>
      <% end %>

      <%= if @block.type in [:image, :video] do %>
        <div class="mt-2 flex justify-end animate-in fade-in duration-200">
          <button
            phx-click="request_media_upload"
            phx-value-block_id={@block.id}
            phx-value-media_type={@block.type}
            phx-target={@target}
            class="btn btn-primary btn-sm"
          >
            <.icon name="hero-cloud-arrow-up" class="size-4 mr-1" />
            {if @block.content["url"], do: gettext("Replace Media"), else: gettext("Upload Media")}
          </button>
        </div>
      <% end %>

      <%= if @block.type == :code do %>
        <div class="mt-2 p-6 bg-base-100 border-l border-r border-b border-base-300 rounded-sm border-t-4 border-t-primary animate-in slide-in-from-top-2 duration-200">
          <div class="flex items-center justify-between mb-6 border-b border-base-200 pb-2">
            <div class="text-xs font-bold uppercase tracking-widest text-primary">
              {gettext("Sandbox Configuration")}
            </div>
            <button
              type="button"
              phx-click="run_instructor_test"
              phx-value-id={@block.id}
              phx-target={assigns[:target]}
              class="btn btn-sm btn-primary"
            >
              <.icon name="hero-play" class="size-4 mr-1" /> {gettext("Test Solution")}
            </button>
          </div>

          <form
            phx-change="update_block_meta"
            phx-target={assigns[:target]}
            id={"code-config-form-#{@block.id}"}
          >
            <input type="hidden" name="block[id]" value={@block.id} />

            <div class="mb-6 relative">
              <label class="label">
                <span class="label-text font-bold text-xs uppercase text-base-content/70">
                  {gettext("Reference Solution (Hidden from students)")}
                </span>
              </label>

              <input
                type="hidden"
                id={"solution-input-#{@block.id}"}
                name="block[content][solution_code]"
                value={@block.content["solution_code"]}
              />

              <div class="overflow-hidden rounded-sm border border-base-300 bg-base-200 dark:bg-[#282c34]">
                <div
                  id={"solution-editor-#{@block.id}"}
                  phx-hook="CodeEditor"
                  data-language={map_cm_lang(@block.content["language"])}
                  data-readonly="false"
                  data-code={@block.content["solution_code"] || ""}
                  data-input-id={"solution-input-#{@block.id}"}
                  phx-update="ignore"
                  class="w-full text-sm font-mono outline-none"
                >
                </div>
              </div>
            </div>

            <div class="flex items-center justify-between mb-2 mt-8">
              <label class="label">
                <span class="label-text font-bold text-xs uppercase text-base-content/70">
                  {gettext("Test Cases")}
                </span>
              </label>
              <button
                type="button"
                phx-click="add_test_case"
                phx-value-id={@block.id}
                phx-target={assigns[:target]}
                class="btn btn-xs btn-ghost text-primary"
              >
                <.icon name="hero-plus" class="size-3 mr-1" /> {gettext("Add Case")}
              </button>
            </div>

            <div class="space-y-3">
              <% raw_cases = @block.content["test_cases"] || []

              test_cases =
                if is_map(raw_cases) do
                  raw_cases
                  |> Enum.sort_by(fn {k, _} -> String.to_integer(k) end)
                  |> Enum.map(fn {_, v} -> v end)
                else
                  raw_cases
                end %>

              <%= for {tc, index} <- Enum.with_index(test_cases) do %>
                <div class="flex gap-2 items-start bg-base-200/50 p-2 rounded-sm border border-base-300 relative group">
                  <input
                    type="hidden"
                    name={"block[content][test_cases][#{index}][id]"}
                    value={tc["id"]}
                  />

                  <div class="flex-1">
                    <textarea
                      name={"block[content][test_cases][#{index}][input]"}
                      class="textarea w-full font-mono text-xs h-16 resize-none"
                      placeholder="stdin"
                    >{tc["input"]}</textarea>
                  </div>
                  <div class="flex-1">
                    <textarea
                      name={"block[content][test_cases][#{index}][expected_output]"}
                      class="textarea w-full font-mono text-xs h-16 resize-none"
                      placeholder="stdout"
                    >{tc["expected_output"]}</textarea>
                  </div>
                  <div class="w-20">
                    <input
                      type="number"
                      name={"block[content][test_cases][#{index}][weight]"}
                      value={tc["weight"]}
                      class="input input-sm w-full text-center"
                      placeholder="Weight %"
                    />

                    <div class="mt-2 text-center" title="Hide test data from students">
                      <label class="cursor-pointer flex items-center justify-center gap-1 text-[10px]">
                        <input
                          type="hidden"
                          name={"block[content][test_cases][#{index}][is_hidden]"}
                          value="false"
                        />
                        <input
                          type="checkbox"
                          name={"block[content][test_cases][#{index}][is_hidden]"}
                          value="true"
                          checked={tc["is_hidden"] in [true, "true"]}
                          class="checkbox checkbox-xs"
                        />
                        <.icon name="hero-eye-slash" class="size-3 text-base-content/60" />
                      </label>
                    </div>
                  </div>

                  <button
                    type="button"
                    phx-click="remove_test_case"
                    phx-value-block_id={@block.id}
                    phx-value-tc_id={tc["id"]}
                    phx-target={assigns[:target]}
                    class="btn btn-ghost btn-xs text-error absolute -right-2 -top-2 bg-base-100 rounded-sm border border-base-200"
                  >
                    <.icon name="hero-x-mark" class="size-3" />
                  </button>
                </div>
              <% end %>
            </div>
          </form>
        </div>
      <% end %>
    </div>
    """
  end

  @doc false
  defp tiptap_toolbar(%{mode: :edit} = assigns) do
    ~H"""
    <div class="fixed-toolbar hidden group-focus-within/tiptap:flex flex-wrap gap-2 bg-base-100 border border-base-300 rounded-sm p-1.5 mb-3 sticky top-2 z-10 items-center">
      <div class="join flex-wrap">
        <button
          type="button"
          class="join-item btn btn-sm btn-ghost rounded-sm px-3 text-base"
          data-action="bold"
          data-tippy-content={"#{gettext("Bold")} ($mod+B)"}
        >
          <.icon name="hero-bold" class="size-5" />
        </button>
        <button
          type="button"
          class="join-item btn btn-sm btn-ghost rounded-sm px-3 text-base"
          data-action="italic"
          data-tippy-content={"#{gettext("Italic")} ($mod+I)"}
        >
          <.icon name="hero-italic" class="size-5" />
        </button>
        <button
          type="button"
          class="join-item btn btn-sm btn-ghost rounded-sm px-3 text-base"
          data-action="underline"
          data-tippy-content={"#{gettext("Underline")} ($mod+U)"}
        >
          <.icon name="hero-underline" class="size-5" />
        </button>
        <button
          type="button"
          class="join-item btn btn-sm btn-ghost rounded-sm px-2 text-sm font-serif"
          data-action="subscript"
          data-tippy-content={"#{gettext("Subscript")} ($mod+,)"}
        >
          X₂
        </button>
        <button
          type="button"
          class="join-item btn btn-sm btn-ghost rounded-sm px-2 text-sm font-serif"
          data-action="superscript"
          data-tippy-content={"#{gettext("Superscript")} ($mod+.)"}
        >
          X²
        </button>
        <button
          type="button"
          class="join-item btn btn-sm btn-ghost rounded-sm px-3"
          data-action="inline-code"
          data-tippy-content={"#{gettext("Inline Code")} ($mod+E)"}
        >
          <.icon name="hero-code-bracket" class="size-5" />
        </button>

        <button
          type="button"
          class="join-item btn btn-sm btn-ghost rounded-sm px-3"
          data-action="highlight"
          data-tippy-content={"#{gettext("Highlight")} ($mod+$shift+H)"}
        >
          <.icon name="hero-paint-brush" class="size-5" />
        </button>

        <button
          type="button"
          class="join-item btn btn-sm btn-ghost rounded-sm px-3"
          data-action="clear-format"
          data-tippy-content={"#{gettext("Clear Formatting")} ($mod+\\)"}
        >
          <div class="flex items-center">
            <span class="font-bold text-sm">T</span>
            <.icon name="hero-no-symbol" class="size-5" />
          </div>
        </button>

        <button
          type="button"
          class="join-item btn btn-sm btn-ghost rounded-sm px-3"
          data-action="insert-before"
          data-tippy-content={gettext("Insert paragraph above")}
        >
          <.icon name="hero-bars-arrow-up" class="size-5" />
        </button>
        <button
          type="button"
          class="join-item btn btn-sm btn-ghost rounded-sm px-3"
          data-action="insert-after"
          data-tippy-content={gettext("Insert paragraph below")}
        >
          <.icon name="hero-bars-arrow-down" class="size-5" />
        </button>

        <button
          type="button"
          class="join-item btn btn-sm btn-ghost rounded-sm px-3 font-bold text-base"
          data-action="paragraph"
          data-tippy-content={"#{gettext("Paragraph")} ($mod+$alt+0)"}
        >
          ¶
        </button>
        <button
          type="button"
          class="join-item btn btn-sm btn-ghost rounded-sm font-bold text-base"
          data-action="h1"
          data-tippy-content={"#{gettext("Heading 1")} ($mod+$alt+1)"}
        >
          <.icon name="hero-h1" class="size-5" />
        </button>
        <button
          type="button"
          class="join-item btn btn-sm btn-ghost rounded-sm font-bold text-base"
          data-action="h2"
          data-tippy-content={"#{gettext("Heading 2")} ($mod+$alt+2)"}
        >
          <.icon name="hero-h2" class="size-5" />
        </button>
        <button
          type="button"
          class="join-item btn btn-sm btn-ghost rounded-sm font-bold text-base"
          data-action="h3"
          data-tippy-content={"#{gettext("Heading 3")} ($mod+$alt+3)"}
        >
          <.icon name="hero-h3" class="size-5" />
        </button>

        <button
          type="button"
          class="join-item btn btn-sm btn-ghost rounded-sm px-2"
          data-action="align-left"
          data-tippy-content={"#{gettext("Align Left")} ($mod+$shift+L)"}
        >
          <.icon name="hero-bars-3-bottom-left" class="size-5" />
        </button>
        <button
          type="button"
          class="join-item btn btn-sm btn-ghost rounded-sm px-2"
          data-action="align-center"
          data-tippy-content={"#{gettext("Align Center")} ($mod+$shift+E)"}
        >
          <.icon name="hero-bars-2" class="size-5" />
        </button>
        <button
          type="button"
          class="join-item btn btn-sm btn-ghost rounded-sm px-2"
          data-action="align-right"
          data-tippy-content={"#{gettext("Align Right")} ($mod+$shift+R)"}
        >
          <.icon name="hero-bars-3-bottom-right" class="size-5" />
        </button>

        <button
          type="button"
          class="join-item btn btn-sm btn-ghost rounded-sm px-2"
          data-action="align-justify"
          data-tippy-content={"#{gettext("Justify")} ($mod+$shift+J)"}
        >
          <.icon name="hero-bars-4" class="size-5" />
        </button>

        <button
          type="button"
          class="join-item btn btn-sm btn-ghost rounded-sm px-3"
          data-action="bullet"
          data-tippy-content={"#{gettext("Bullet List")} ($mod+$shift+8)"}
        >
          <.icon name="hero-list-bullet" class="size-5" />
        </button>
        <button
          type="button"
          class="join-item btn btn-sm btn-ghost rounded-sm px-3 font-bold font-serif text-base"
          data-action="ordered"
          data-tippy-content={"#{gettext("Ordered List")} ($mod+$shift+7)"}
        >
          <.icon name="hero-numbered-list" class="size-5" />
        </button>
        <button
          type="button"
          class="join-item btn btn-sm btn-ghost rounded-sm px-3"
          data-action="quote"
          data-tippy-content={"#{gettext("Blockquote")} ($mod+$shift+B)"}
        >
          <.icon name="hero-chat-bubble-bottom-center-text" class="size-5" />
        </button>
        <button
          type="button"
          class="join-item btn btn-sm btn-ghost rounded-sm px-3"
          data-action="code-block"
          data-tippy-content={"#{gettext("Code Block")} ($mod+$alt+C)"}
        >
          <.icon name="hero-command-line" class="size-5" />
        </button>
        <button
          type="button"
          class="join-item btn btn-sm btn-ghost rounded-sm px-3 font-bold"
          data-action="divider"
          data-tippy-content={"#{gettext("Divider")} ($mod+Enter)"}
        >
          —
        </button>
        <button
          type="button"
          class="join-item btn btn-sm btn-ghost rounded-sm px-3"
          data-action="details"
          data-tippy-content={"#{gettext("Spoiler / Details")} ($mod+$shift+D)"}
        >
          <.icon name="hero-chevron-down" class="size-5" />
        </button>
        <button
          type="button"
          class="join-item btn btn-sm btn-ghost rounded-sm px-3"
          data-action="link"
          data-tippy-content={"#{gettext("Link")} ($mod+K)"}
        >
          <.icon name="hero-link" class="size-5" />
        </button>
        <button
          type="button"
          class="join-item btn btn-sm btn-ghost rounded-sm px-3"
          data-action="image"
          data-tippy-content={"#{gettext("Image")} ($mod+$shift+I)"}
        >
          <.icon name="hero-photo" class="size-5" />
        </button>
        <button
          type="button"
          class="join-item btn btn-sm btn-ghost rounded-sm px-3"
          data-action="table"
          data-tippy-content={"#{gettext("Insert Table")} ($mod+$alt+T)"}
        >
          <.icon name="hero-table-cells" class="size-5" />
        </button>

        <button
          type="button"
          class="join-item btn btn-sm btn-ghost rounded-sm px-2 text-xs font-bold tracking-wider hidden tiptap-table-control"
          data-action="add-row"
          data-tippy-content={gettext("Add Row")}
        >
          + Row
        </button>
        <button
          type="button"
          class="join-item btn btn-sm btn-ghost rounded-sm px-2 text-xs font-bold tracking-wider hidden tiptap-table-control"
          data-action="add-col"
          data-tippy-content={gettext("Add Column")}
        >
          + Col
        </button>
        <button
          type="button"
          class="join-item btn btn-sm btn-ghost rounded-sm px-2 text-xs font-bold tracking-wider hidden tiptap-table-control"
          data-action="del-row"
          data-tippy-content={gettext("Delete Row")}
        >
          - Row
        </button>
        <button
          type="button"
          class="join-item btn btn-sm btn-ghost rounded-sm px-2 text-xs font-bold tracking-wider hidden tiptap-table-control"
          data-action="del-col"
          data-tippy-content={gettext("Delete Column")}
        >
          - Col
        </button>
        <button
          type="button"
          class="join-item btn btn-sm btn-ghost rounded-sm px-2 hidden tiptap-table-control text-error hover:bg-error/10"
          data-action="del-table"
          data-tippy-content={gettext("Delete Table")}
        >
          <.icon name="hero-trash" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  defp tiptap_toolbar(assigns), do: ~H""

  @doc false
  defp clean_filename(url) do
    url
    |> Path.basename()
    |> String.replace(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}-/i, "")
  end
end
