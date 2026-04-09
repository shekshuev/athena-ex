defmodule AthenaWeb.StudioLive.GradingDetail do
  @moduledoc """
  LiveView for grading a specific student submission.
  Shows the read-only submission on the left and grading controls on the right.
  """
  use AthenaWeb, :live_view

  alias Athena.Learning
  alias Athena.Identity
  alias Athena.Content

  on_mount {AthenaWeb.Hooks.Permission, "grading.update"}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    # Достаем сабмишен, чтобы не плодить 100 мелких функций, дернем Repo прямо тут (или вынеси в контекст)
    submission = Athena.Repo.get!(Learning.Submission, id)

    # Подтягиваем студента и блок
    {:ok, account} = Identity.get_account(submission.account_id)
    {:ok, block} = Content.get_block(submission.block_id)

    # Собираем форму для оценки
    form = to_form(%{"score" => submission.score, "feedback" => submission.feedback || ""})

    {:ok,
     socket
     |> assign(
       page_title: gettext("Grade Submission"),
       submission: submission,
       account: account,
       block: block,
       form: form
     )}
  end

  @impl true
  def handle_event("save_grade", %{"score" => score, "feedback" => feedback}, socket) do
    attrs = %{
      "score" => String.to_integer(score),
      "feedback" => feedback,
      # Как только препод сохранил, статус меняем на проверено
      "status" => "graded"
    }

    case Learning.update_submission(socket.assigns.submission, attrs) do
      {:ok, _updated_sub} ->
        {:noreply,
         socket
         |> put_flash(:success, gettext("Submission graded successfully!"))
         |> push_navigate(to: ~p"/studio/grading")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to save grade."))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="-m-4 sm:-m-8 flex flex-col lg:flex-row h-[calc(100vh-4rem)] lg:h-screen bg-base-200">
      <div class="flex-1 overflow-y-auto p-6 lg:p-10">
        <div class="max-w-3xl mx-auto">
          <div class="flex items-center gap-4 mb-8">
            <.link navigate={~p"/studio/grading"} class="btn btn-ghost btn-sm btn-square">
              <.icon name="hero-arrow-left" class="size-5" />
            </.link>
            <div>
              <h1 class="text-2xl font-black font-display tracking-tight">
                {gettext("Submission from %{name}", name: @account.login)}
              </h1>
              <div class="text-sm font-mono text-base-content/50 uppercase tracking-widest mt-1">
                {gettext("Block Type:")} {@block.type}
              </div>
            </div>
          </div>

          <div class="space-y-8">
            <%= if @block.type == :quiz_exam do %>
              <.render_exam_submission submission={@submission} block={@block} />
            <% else %>
              <.render_single_question submission={@submission} block={@block} />
            <% end %>
          </div>

          <div class="h-20"></div>
        </div>
      </div>

      <div class="w-full lg:w-96 bg-base-100 border-t lg:border-t-0 lg:border-l border-base-300 flex flex-col shrink-0 z-10 shadow-xl lg:shadow-none">
        <div class="p-6 border-b border-base-300 bg-base-200/50">
          <div class="text-xs font-bold uppercase tracking-widest text-base-content/50 mb-1">
            {gettext("Grading Panel")}
          </div>
          <div class="flex items-center justify-between">
            <h2 class="text-lg font-bold">{gettext("Evaluation")}</h2>
            <.status_badge status={@submission.status} />
          </div>
        </div>

        <div class="flex-1 overflow-y-auto p-6">
          <.form for={@form} id="grading-form" phx-submit="save_grade" class="space-y-6">
            <div class="space-y-2">
              <label class="text-sm font-bold uppercase tracking-widest text-base-content/70">
                {gettext("Final Score (0-100)")}
              </label>
              <.input
                type="number"
                field={@form[:score]}
                min="0"
                max="100"
                class="input input-bordered input-lg w-full font-black text-2xl"
              />
              <div class="text-xs text-base-content/50 leading-relaxed">
                {gettext("Current automated score. You can override it manually.")}
              </div>
            </div>

            <div class="divider"></div>

            <div class="space-y-2">
              <label class="text-sm font-bold uppercase tracking-widest text-base-content/70">
                {gettext("Instructor Feedback")}
              </label>
              <.input
                type="textarea"
                field={@form[:feedback]}
                rows="6"
                placeholder={
                  gettext("Write your feedback here... It will be visible to the student.")
                }
                class="textarea textarea-bordered w-full leading-relaxed"
              />
            </div>

            <%= if (@submission.content["cheat_count"] || 0) > 0 do %>
              <div class="p-4 bg-error/10 text-error rounded-xl border border-error/20 mt-4">
                <div class="font-black flex items-center gap-2 mb-1">
                  <.icon name="hero-eye" class="size-5" />
                  {gettext("Cheating Detected")}
                </div>
                <div class="text-sm">
                  {gettext("The student triggered %{count} window blur violations during this exam.",
                    count: @submission.content["cheat_count"]
                  )}
                </div>
              </div>
            <% end %>

            <div class="pt-6 mt-auto">
              <button type="submit" class="btn btn-primary w-full btn-lg shadow-lg shadow-primary/20">
                <.icon name="hero-check-circle" class="size-6 mr-2" />
                {gettext("Save & Mark as Graded")}
              </button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  # --- КОМПОНЕНТЫ РЕНДЕРА (РОУТЕРЫ) ---

  defp render_exam_submission(assigns) do
    questions = assigns.submission.content["questions"] || []
    answers = assigns.submission.content["answers"] || %{}

    assigns = assign(assigns, :questions, questions)
    assigns = assign(assigns, :answers, answers)

    ~H"""
    <div class="space-y-12">
      <div class="text-center pb-6 border-b border-base-300">
        <div class="inline-flex items-center justify-center p-4 bg-primary/10 text-primary rounded-full mb-4">
          <.icon name="hero-academic-cap" class="size-10" />
        </div>
        <h2 class="text-2xl font-black">{gettext("Exam Review")}</h2>
        <p class="text-base-content/60">{length(@questions)} {gettext("Questions total")}</p>
      </div>

      <div
        :for={{q, index} <- Enum.with_index(@questions)}
        class="p-6 bg-base-100 border border-base-300 rounded-2xl shadow-sm relative"
      >
        <div class="absolute -top-4 -left-4 size-8 bg-base-300 text-base-content font-black rounded-full flex items-center justify-center border-4 border-base-100 shadow-sm">
          {index + 1}
        </div>

        <div class="flex items-center justify-between mb-4">
          <span class="badge badge-ghost uppercase font-bold tracking-widest text-[10px]">
            {q["question_type"] || q["type"]}
          </span>
          <%= if q["question_type"] == "open" do %>
            <span class="badge badge-warning badge-soft font-bold text-xs">
              <.icon name="hero-hand-raised" class="size-3 mr-1" /> {gettext("Manual Review")}
            </span>
          <% end %>
        </div>

        <div
          id={"exam-q-tiptap-#{q["id"]}"}
          phx-hook="TiptapEditor"
          data-id={q["id"]}
          data-readonly="true"
          phx-update="ignore"
          data-content={Jason.encode!(q["question"] || q["body"] || %{})}
          class="prose prose-sm max-w-none mb-6 text-base-content/80"
        >
        </div>

        <div class="bg-base-200/50 p-4 rounded-xl border border-base-200">
          <div class="text-xs font-bold uppercase tracking-widest text-base-content/50 mb-3">
            {gettext("Student's Answer:")}
          </div>
          <.render_answer_readonly
            q_type={q["question_type"] || q["type"]}
            options={q["options"] || []}
            answer={@answers[q["id"]]}
            correct_answer={q["correct_answer"]}
          />
        </div>
      </div>
    </div>
    """
  end

  defp render_single_question(assigns) do
    q_type = assigns.block.content["question_type"]
    opts = assigns.block.content["options"] || []

    # Для одиночного блока ответ лежит по-разному в зависимости от типа
    answer =
      case q_type do
        "exact_match" -> assigns.submission.content["text_answer"]
        "open" -> assigns.submission.content["text_answer"]
        _ -> assigns.submission.content["selected_choices"]
      end

    assigns = assign(assigns, q_type: q_type, options: opts, answer: answer)

    ~H"""
    <div class="p-8 bg-base-100 border border-base-300 rounded-3xl shadow-sm">
      <div class="flex items-center justify-between mb-6 pb-6 border-b border-base-200">
        <h2 class="text-xl font-black">{gettext("Question Content")}</h2>
        <span class="badge badge-ghost uppercase font-bold tracking-widest text-[10px]">
          {@q_type}
        </span>
      </div>

      <div
        id={"single-q-tiptap-#{@block.id}"}
        phx-hook="TiptapEditor"
        data-id={@block.id}
        data-readonly="true"
        phx-update="ignore"
        data-content={Jason.encode!(@block.content["body"] || %{})}
        class="prose max-w-none mb-8 text-base-content/80"
      >
      </div>

      <div class="bg-base-200/50 p-6 rounded-2xl border border-base-200">
        <div class="text-xs font-bold uppercase tracking-widest text-base-content/50 mb-4">
          {gettext("Student's Answer:")}
        </div>
        <.render_answer_readonly
          q_type={@q_type}
          options={@options}
          answer={@answer}
          correct_answer={@block.content["correct_answer"]}
        />
      </div>
    </div>
    """
  end

  # --- КОМПОНЕНТЫ ОТВЕТОВ ---

  defp render_answer_readonly(%{q_type: "exact_match"} = assigns) do
    ~H"""
    <div class="flex flex-col gap-2">
      <input
        type="text"
        value={@answer}
        class="input input-bordered w-full font-mono text-lg bg-base-100"
        disabled
      />
      <div class="text-sm mt-2 flex items-center gap-2">
        <span class="font-bold text-success">
          <.icon name="hero-check-circle" class="size-4 inline" /> {gettext("Correct Answer:")}
        </span>
        <span class="font-mono bg-base-300 px-2 py-0.5 rounded">{@correct_answer}</span>
      </div>
    </div>
    """
  end

  defp render_answer_readonly(%{q_type: "open"} = assigns) do
    ~H"""
    <textarea
      rows="5"
      class="textarea textarea-bordered w-full text-base leading-relaxed bg-base-100"
      disabled
    ><%= @answer %></textarea>
    """
  end

  defp render_answer_readonly(%{q_type: q_type} = assigns)
       when q_type in ["single", "multiple"] do
    ~H"""
    <div class="space-y-3">
      <%= for opt <- @options do %>
        <% is_selected = opt["id"] in List.wrap(@answer) %>
        <% is_correct = opt["is_correct"] in [true, "true"] %>

        <div class={[
          "flex items-start gap-4 p-4 rounded-xl border transition-all",
          is_selected && is_correct && "bg-success/10 border-success/30",
          is_selected && not is_correct && "bg-error/10 border-error/30",
          not is_selected && is_correct && "bg-base-100 border-success/30 ring-2 ring-success/20",
          not is_selected && not is_correct && "bg-base-100 border-base-300 opacity-60"
        ]}>
          <input
            type={if @q_type == "single", do: "radio", else: "checkbox"}
            checked={is_selected}
            class={
              if @q_type == "single",
                do: "radio radio-primary mt-0.5",
                else: "checkbox checkbox-primary mt-0.5"
            }
            disabled
          />
          <div class="flex-1">
            <span class="text-base font-medium">{opt["text"]}</span>
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
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_answer_readonly(assigns) do
    ~H"""
    <div class="text-warning italic">{gettext("No answer recorded or unknown type.")}</div>
    """
  end

  defp status_badge(assigns) do
    ~H"""
    <span class={[
      "badge font-bold px-3 py-3 rounded-lg",
      @status == :graded && "bg-success/20 text-success border-success/30",
      @status == :needs_review && "bg-warning/20 text-warning border-warning/30",
      @status in [:pending, :processing] && "bg-base-300 text-base-content"
    ]}>
      {Atom.to_string(@status) |> String.replace("_", " ") |> String.capitalize()}
    </span>
    """
  end
end
