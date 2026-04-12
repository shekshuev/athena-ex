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
        <div class="mt-2 p-6 bg-base-100 ring-1 ring-base-300 rounded-xl shadow-lg border-t-4 border-t-primary animate-in slide-in-from-top-2 duration-200">
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
                <div class="form-control">
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
                      class="input input-bordered flex-1 font-mono"
                      phx-debounce="500"
                    />
                  </div>
                </div>
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
                      <div class="flex-1 bg-base-100/50 p-2 rounded-lg border border-base-200/50 focus-within:border-primary focus-within:ring-1 focus-within:ring-primary space-y-2">
                        <input type="hidden" name={"options[#{index}][id]"} value={opt["id"]} />
                        <input
                          type="text"
                          name={"options[#{index}][text]"}
                          value={opt["text"]}
                          class="w-full bg-transparent border-none outline-none focus:ring-0 font-medium text-base-content"
                          placeholder={gettext("Option text")}
                          phx-debounce="500"
                        />
                        <input
                          type="text"
                          name={"options[#{index}][explanation]"}
                          value={opt["explanation"]}
                          class="w-full bg-transparent border-none outline-none focus:ring-0 text-sm text-base-content/60"
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
                <div class="text-sm text-base-content/50 italic bg-base-200/50 p-4 rounded-lg border border-dashed border-base-300">
                  {gettext("Student will see a text area to write their open answer.")}
                </div>
              <% _ -> %>
            <% end %>
          </form>
        </div>
      <% end %>

      <%= if @block.type == :attachment do %>
        <div class="mt-2 p-4 bg-base-100 ring-1 ring-base-300 rounded-xl shadow-lg animate-in slide-in-from-top-2 duration-200">
          <div class="text-xs font-bold uppercase tracking-widest text-primary mb-3">
            {gettext("Manage Files")}
          </div>
          <div class="space-y-2">
            <div
              :for={file <- @block.content["files"] || []}
              class="flex items-center justify-between p-2 bg-base-200/50 border border-base-300 rounded-lg"
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
            class="btn btn-primary btn-sm mt-3 w-full shadow-sm"
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
            class="btn btn-primary btn-sm shadow-sm"
          >
            <.icon name="hero-cloud-arrow-up" class="size-4 mr-1" />
            {if @block.content["url"], do: gettext("Replace Media"), else: gettext("Upload Media")}
          </button>
        </div>
      <% end %>
    </div>
    """
  end
end
