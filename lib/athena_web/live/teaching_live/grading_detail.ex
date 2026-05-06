defmodule AthenaWeb.TeachingLive.GradingDetail do
  @moduledoc """
  LiveView for grading a specific student submission.
  Shows the read-only submission on the left and grading controls on the right
  using a strict, professional card UI.
  """
  use AthenaWeb, :live_view

  alias Athena.{Learning, Identity, Content}
  import AthenaWeb.BlockComponents

  on_mount {AthenaWeb.Hooks.Permission, "grading.update"}

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    return_to = Map.get(params, "return_to", ~p"/teaching/grading")

    submission = Learning.get_submission!(socket.assigns.current_user, id)

    {:ok, account} = Identity.get_account(submission.account_id)
    {:ok, block} = Content.get_block(submission.block_id)

    form = to_form(%{"score" => submission.score, "feedback" => submission.feedback || ""})

    {:ok,
     socket
     |> assign(
       page_title: gettext("Grade Submission"),
       submission: submission,
       account: account,
       block: block,
       form: form,
       return_to: return_to
     )}
  end

  @impl true
  def handle_event(
        "save_grade",
        %{"action" => action, "score" => score, "feedback" => feedback},
        socket
      ) do
    status = if action == "reject", do: "rejected", else: "graded"
    final_score = if action == "reject", do: 0, else: String.to_integer(score)

    attrs = %{
      "score" => final_score,
      "feedback" => feedback,
      "status" => status
    }

    case Learning.update_submission(socket.assigns.current_user, socket.assigns.submission, attrs) do
      {:ok, _updated_sub} ->
        msg =
          if action == "reject",
            do: gettext("Submission rejected!"),
            else: gettext("Submission graded successfully!")

        {:noreply,
         socket
         |> put_flash(:success, msg)
         |> push_navigate(to: socket.assigns.return_to)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to save grade."))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto pb-20">
      <div class="flex items-center gap-4 mb-8 border-b border-base-200 pb-6">
        <.link
          navigate={@return_to}
          class="btn btn-ghost btn-sm btn-square rounded-md hover:bg-base-200"
        >
          <.icon name="hero-arrow-left" class="size-5" />
        </.link>
        <div>
          <h1 class="text-2xl font-black font-display tracking-tight">
            {gettext("Submission from %{name}", name: @account.login)}
          </h1>
          <div class="text-xs font-bold text-base-content/50 uppercase tracking-widest mt-1">
            {gettext("Block Type:")} {Atom.to_string(@block.type) |> String.replace("_", " ")}
          </div>
        </div>
      </div>

      <div class="flex flex-col lg:flex-row items-start gap-8">
        <div class="flex-1 w-full min-w-0 space-y-6 ">
          <%= if @block.type == :quiz_exam do %>
            <div class="space-y-6">
              <.content_block block={@block} mode={:review} submission={@submission} />

              <div
                :for={{q, index} <- Enum.with_index(@submission.content["questions"] || [])}
                class="p-6 bg-base-100 border border-base-200  shadow-sm relative group hover:border-primary/30 transition-all"
              >
                <div class="absolute -top-3 -left-3 size-7 bg-base-200 text-base-content/70 font-bold rounded-sm flex items-center justify-center border border-base-300 shadow-sm text-xs group-hover:bg-primary group-hover:text-primary-content group-hover:border-primary transition-colors">
                  {index + 1}
                </div>

                <div class="flex items-center justify-between mb-6 pb-4 border-b border-base-100">
                  <h2 class="text-lg font-bold">{gettext("Question Content")}</h2>
                  <div class="flex items-center gap-2">
                    <span class="badge badge-sm rounded-sm font-bold bg-base-200 border-0 text-base-content/70 uppercase tracking-widest text-[10px]">
                      {q["question_type"] || q["type"]}
                    </span>
                    <%= if q["question_type"] == "open" do %>
                      <span class="badge badge-warning badge-soft badge-sm rounded-sm font-bold uppercase tracking-widest text-[10px]">
                        <.icon name="hero-hand-raised" class="size-3 mr-1" /> {gettext(
                          "Manual Review"
                        )}
                      </span>
                    <% end %>
                  </div>
                </div>

                <% fake_block = %{id: q["id"], type: :quiz_question, content: q}

                ans = (@submission.content["answers"] || %{})[q["id"]]

                fake_sub_content =
                  case q["question_type"] do
                    "exact_match" -> %{"text_answer" => ans}
                    "open" -> %{"text_answer" => ans}
                    _ -> %{"selected_choices" => ans}
                  end

                fake_submission = %{content: fake_sub_content} %>

                <.content_block block={fake_block} mode={:review} submission={fake_submission} />
              </div>
            </div>
          <% else %>
            <div class="p-6 bg-base-100 border border-base-200 rounded-xl shadow-sm">
              <div class="flex items-center justify-between mb-6 pb-4 border-b border-base-100">
                <h2 class="text-lg font-bold">{gettext("Question Content")}</h2>
              </div>
              <.content_block block={@block} mode={:review} submission={@submission} />
            </div>
          <% end %>
        </div>

        <div class="w-full lg:w-[400px] shrink-0 bg-base-100 rounded-sm border border-base-300 shadow-sm sticky top-8 flex flex-col overflow-hidden">
          <div class="flex items-center justify-between gap-3 px-6 py-5 border-b border-base-200 bg-base-200/30">
            <div>
              <div class="text-[10px] font-bold text-base-content/50 uppercase tracking-widest mb-0.5">
                {gettext("Grading Panel")}
              </div>
              <div class="text-sm font-bold">
                {gettext("Evaluation")}
              </div>
            </div>
            <.status_badge status={@submission.status} />
          </div>

          <div class="p-6 space-y-6">
            <.form for={@form} id="grading-form" phx-submit="save_grade">
              <div class="space-y-4 mb-6">
                <div class="text-xs font-bold text-base-content/50 uppercase tracking-wider">
                  {gettext("Score Settings")}
                </div>

                <.input
                  type="number"
                  field={@form[:score]}
                  label={gettext("Final Score (0-100)")}
                  min="0"
                  max="100"
                />
                <div class="text-xs text-base-content/50 leading-relaxed -mt-2">
                  {gettext("Current automated score. You can override it manually.")}
                </div>
              </div>

              <div class="divider my-4"></div>

              <div class="space-y-4 mb-6">
                <div class="text-xs font-bold text-base-content/50 uppercase tracking-wider">
                  {gettext("Instructor Feedback")}
                </div>

                <.input
                  type="textarea"
                  field={@form[:feedback]}
                  rows="5"
                  label={gettext("Comments")}
                  placeholder={
                    gettext("Write your feedback here... It will be visible to the student.")
                  }
                />
              </div>

              <%= if (@submission.content["cheat_count"] || 0) > 0 do %>
                <div class="divider my-4"></div>
                <div class="space-y-4 mb-6">
                  <div class="text-xs font-bold text-error uppercase tracking-wider">
                    {gettext("Violations")}
                  </div>
                  <div class="p-4 bg-error/10 text-error rounded-md border border-error/20">
                    <div class="font-bold flex items-center gap-2 mb-1">
                      <.icon name="hero-eye" class="size-4" />
                      {gettext("Cheating Detected")}
                    </div>
                    <div class="text-sm font-medium">
                      {gettext(
                        "The student triggered %{count} window blur violations during this exam.",
                        count: @submission.content["cheat_count"]
                      )}
                    </div>
                  </div>
                </div>
              <% end %>
            </.form>
          </div>

          <div class="p-6 border-t border-base-200 bg-base-200/20 flex gap-4">
            <button
              form="grading-form"
              type="submit"
              name="action"
              value="reject"
              class="btn btn-outline btn-error w-1/3 shadow-sm"
            >
              <.icon name="hero-x-mark" class="size-5 mr-1" />
              {gettext("Reject")}
            </button>

            <button
              form="grading-form"
              type="submit"
              name="action"
              value="grade"
              class="btn btn-primary w-2/3 shadow-sm"
            >
              <.icon name="hero-check-circle" class="size-5 mr-2" />
              {gettext("Save & Grade")}
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp status_badge(assigns) do
    ~H"""
    <span class={[
      "badge font-bold border-0 tracking-wide rounded-md",
      @status == :graded && "bg-success/10 text-success",
      @status == :needs_review && "bg-warning/10 text-warning",
      @status in [:pending, :processing] && "bg-base-200 text-base-content/70",
      @status == :rejected && "bg-error/10 text-error"
    ]}>
      {Atom.to_string(@status) |> String.replace("_", " ") |> String.capitalize()}
    </span>
    """
  end
end
