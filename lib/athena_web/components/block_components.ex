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
  attr :mode, :atom, required: true, values: [:edit, :play, :review]
  attr :answers, :map, default: %{}
  attr :submission, :map, default: nil
  attr :active, :boolean, default: false

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
          <.render_code block={@block} mode={@mode} />
        <% :quiz_question -> %>
          <.render_quiz_question
            block={@block}
            mode={@mode}
            answers={@answers}
            submission={@submission}
          />
        <% :quiz_exam -> %>
          <.render_quiz_exam block={@block} mode={@mode} submission={@submission} />
        <% _ -> %>
          <div class="p-4 text-warning italic border border-warning/20 bg-warning/5 rounded-xl">
            {gettext("Unknown block type: %{type}", type: @block.type)}
          </div>
      <% end %>
    </div>
    """
  end

  defp wrapper_classes(:edit, true),
    do: "p-5 rounded-2xl ring-2 ring-primary bg-base-100 transition-all shadow-sm"

  defp wrapper_classes(:edit, false),
    do:
      "p-5 rounded-2xl ring-1 ring-base-300 hover:ring-primary/50 bg-base-100 transition-all cursor-pointer opacity-80 hover:opacity-100"

  defp wrapper_classes(:play, _), do: "mb-10 last:mb-0 w-full"
  defp wrapper_classes(:review, _), do: "mb-10 last:mb-0 w-full"

  defp render_text(assigns) do
    ~H"""
    <div
      id={"tiptap-#{@mode}-#{@block.id}"}
      phx-hook="TiptapEditor"
      data-id={@block.id}
      data-readonly={to_string(@mode != :edit)}
      phx-update="ignore"
      data-content={Jason.encode!(@block.content)}
      class="prose prose-base md:prose-lg max-w-none text-base-content/80 leading-relaxed"
    >
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
          class="rounded-xl w-full object-cover border border-base-200 shadow-sm"
        />
      </figure>
    <% else %>
      <div class="p-8 border-2 border-dashed border-base-300 rounded-xl text-center text-base-content/40 bg-base-200/50">
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
        class="rounded-xl w-full bg-black aspect-video shadow-md"
      />
    <% else %>
      <div class="p-10 border-2 border-dashed border-base-300 rounded-xl text-center text-base-content/40 bg-base-200/50">
        <.icon name="hero-video-camera" class="size-8 mb-2 opacity-50" />
        <div>{gettext("Video not uploaded yet")}</div>
      </div>
    <% end %>
    """
  end

  defp render_attachment(assigns) do
    ~H"""
    <div class="p-6 bg-base-200/50 rounded-xl border border-base-300">
      <div
        :if={@block.content["description"]}
        id={"tiptap-desc-#{@mode}-#{@block.id}"}
        phx-hook="TiptapEditor"
        data-id={@block.id}
        data-readonly={to_string(@mode != :edit)}
        phx-update="ignore"
        data-content={Jason.encode!(@block.content["description"])}
        class="prose prose-sm max-w-none text-base-content/70 mb-4"
      >
      </div>
      <div class="space-y-3">
        <a
          :for={file <- @block.content["files"] || []}
          href={file["url"]}
          target="_blank"
          rel="noopener noreferrer"
          class="flex items-center gap-4 p-4 bg-base-100 rounded-lg border border-base-200 shadow-sm hover:border-primary/40 hover:shadow-md transition-all group"
        >
          <div class="p-3 bg-primary/10 rounded-lg text-primary shrink-0 group-hover:scale-110 transition-transform">
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
    ~H"""
    <div class="overflow-hidden rounded-xl border border-base-300 bg-base-300/20">
      <div class="bg-base-300 px-4 py-2 flex items-center justify-between">
        <div class="flex items-center gap-2">
          <div class="size-3 rounded-full bg-error"></div>
          <div class="size-3 rounded-full bg-warning"></div>
          <div class="size-3 rounded-full bg-success"></div>
        </div>
        <span class="text-xs font-mono text-base-content/50 uppercase">
          {@block.content["language"] || "code"}
        </span>
      </div>
      <pre class="p-4 text-sm font-mono overflow-x-auto text-base-content/80">{@block.content["code"]}</pre>
    </div>
    """
  end

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
      <div
        id={"tiptap-quiz-#{@mode}-#{@block.id}"}
        phx-hook="TiptapEditor"
        data-id={@block.id}
        data-readonly={to_string(@mode != :edit)}
        phx-update="ignore"
        data-content={Jason.encode!(@block.content["body"] || %{})}
        class="prose prose-base md:prose-lg max-w-none text-base-content/80 leading-relaxed mb-6"
      >
      </div>

      <div class="pl-4 border-l-4 border-primary/20">
        <%= if @mode == :review do %>
          <div class="text-[10px] font-black uppercase tracking-widest text-base-content/40 mb-3">
            {gettext("Student's Answer:")}
          </div>
        <% end %>
        <.render_quiz_inputs
          block={@block}
          mode={@mode}
          q_type={@q_type}
          options={@options}
          answer={@answer}
        />
      </div>
    </div>
    """
  end

  defp extract_quiz_answer(%{mode: :play} = assigns, _q_type) do
    Map.get(assigns.answers || %{}, assigns.block.id)
  end

  defp extract_quiz_answer(%{mode: :review, submission: %{content: content}}, "exact_match"),
    do: content["text_answer"]

  defp extract_quiz_answer(%{mode: :review, submission: %{content: content}}, "open"),
    do: content["text_answer"]

  defp extract_quiz_answer(%{mode: :review, submission: %{content: content}}, _q_type),
    do: content["selected_choices"]

  defp extract_quiz_answer(_assigns, _q_type), do: nil

  defp render_quiz_exam(assigns) do
    ~H"""
    <div class="p-8 bg-base-100 rounded-3xl border border-base-200 shadow-sm text-center relative overflow-hidden">
      <div class="absolute top-0 left-0 w-full h-1 bg-primary"></div>
      <div class="size-16 bg-primary/10 text-primary rounded-full flex items-center justify-center mx-auto mb-4">
        <.icon name="hero-academic-cap-solid" class="size-8" />
      </div>
      <h3 class="text-2xl font-black mb-2">{gettext("Final Exam")}</h3>
      <div class="flex items-center justify-center gap-4 text-sm font-bold text-base-content/60 uppercase tracking-widest">
        <span>{@block.content["count"] || 10} {gettext("Questions")}</span>
        <span :if={@block.content["time_limit"]}>
          • {@block.content["time_limit"]} {gettext("Min")}
        </span>
      </div>

      <%= if @mode == :play do %>
        <div class="mt-8">
          <button
            phx-click="start_exam"
            phx-value-block_id={@block.id}
            class="btn btn-primary px-10 shadow-lg shadow-primary/20"
          >
            {gettext("Start Exam")} <.icon name="hero-play-solid" class="size-4 ml-2" />
          </button>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_quiz_inputs(%{q_type: "exact_match"} = assigns) do
    ~H"""
    <div class="flex flex-col gap-2 max-w-md">
      <input
        type="text"
        name="answer"
        value={@answer}
        placeholder={if @mode == :play, do: gettext("Type your answer..."), else: ""}
        class="input input-bordered w-full font-mono text-lg bg-base-100 disabled:opacity-70 disabled:text-base-content"
        disabled={@mode != :play}
        phx-debounce="500"
      />
      <%= if @mode == :review do %>
        <div class="text-sm mt-2 flex items-center gap-2">
          <span class="font-bold text-success">
            <.icon name="hero-check-circle" class="size-4 inline" /> {gettext("Correct:")}
          </span>
          <span class="font-mono bg-base-300 px-2 py-0.5 rounded">
            {@block.content["correct_answer"]}
          </span>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_quiz_inputs(%{q_type: "open"} = assigns) do
    ~H"""
    <textarea
      name="answer"
      rows="5"
      placeholder={if @mode == :play, do: gettext("Write your detailed answer here..."), else: ""}
      class="textarea textarea-bordered w-full text-base leading-relaxed bg-base-100 disabled:opacity-70 disabled:text-base-content"
      disabled={@mode != :play}
      phx-debounce="1000"
    >{@answer}</textarea>
    """
  end

  defp render_quiz_inputs(%{q_type: q_type} = assigns) when q_type in ["single", "multiple"] do
    ~H"""
    <div class="space-y-3">
      <%= for opt <- @options do %>
        <% is_selected = opt["id"] in List.wrap(@answer) %>
        <% is_correct = opt["is_correct"] in [true, "true"] %>

        <label class={[
          "flex items-start gap-4 p-4 rounded-xl border transition-all",
          @mode == :play &&
            "hover:bg-base-200/50 cursor-pointer has-checked:bg-primary/5 has-checked:border-primary",
          @mode == :review && is_selected && is_correct && "bg-success/10 border-success/30",
          @mode == :review && is_selected && not is_correct && "bg-error/10 border-error/30",
          @mode == :review && not is_selected && is_correct &&
            "bg-base-100 border-success/30 ring-2 ring-success/20",
          @mode == :review && not is_selected && not is_correct &&
            "bg-base-100 border-base-300 opacity-60",
          @mode == :edit && "bg-base-100 border-base-200 opacity-60 pointer-events-none"
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
          />
          <div class="flex-1">
            <span class="text-base font-medium">{opt["text"]}</span>
            <%= if @mode == :review do %>
              <div
                :if={is_correct}
                class="text-xs font-bold text-success uppercase tracking-widest mt-1"
              >
                {gettext("Correct Option")}
              </div>
              <div
                :if={is_selected && not is_correct}
                class="text-xs font-bold text-error uppercase tracking-widest mt-1"
              >
                {gettext("Student's Choice")}
              </div>
            <% end %>
          </div>
        </label>
      <% end %>
    </div>
    """
  end
end
