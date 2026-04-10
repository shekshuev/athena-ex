defmodule AthenaWeb.StudioLive.GradingDetail do
  @moduledoc """
  LiveView for grading a specific student submission.
  Shows the read-only submission on the left and grading controls on the right.
  """
  use AthenaWeb, :live_view

  alias Athena.{Learning, Identity, Content}

  import AthenaWeb.BlockComponents

  on_mount {AthenaWeb.Hooks.Permission, "grading.update"}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    submission = Athena.Repo.get!(Learning.Submission, id)

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
       form: form
     )}
  end

  @impl true
  def handle_event("save_grade", %{"score" => score, "feedback" => feedback}, socket) do
    attrs = %{
      "score" => String.to_integer(score),
      "feedback" => feedback,
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
    <div class="flex flex-col lg:flex-row items-start gap-8">
      <div class="flex-1 w-full min-w-0">
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
            <div class="space-y-8">
              <.content_block block={@block} mode={:review} submission={@submission} />

              <div
                :for={{q, index} <- Enum.with_index(@submission.content["questions"] || [])}
                class="p-8 bg-base-100 border border-base-300 rounded-3xl shadow-sm relative"
              >
                <div class="absolute -top-4 -left-4 size-8 bg-base-300 text-base-content font-black rounded-full flex items-center justify-center border-4 border-base-100 shadow-sm">
                  {index + 1}
                </div>

                <div class="flex items-center justify-between mb-6 pb-6 border-b border-base-200">
                  <h2 class="text-xl font-black">{gettext("Question Content")}</h2>
                  <div class="flex items-center gap-2">
                    <span class="badge badge-ghost uppercase font-bold tracking-widest text-[10px]">
                      {q["question_type"] || q["type"]}
                    </span>
                    <%= if q["question_type"] == "open" do %>
                      <span class="badge badge-warning badge-soft font-bold text-xs">
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
            <div class="p-8 bg-base-100 border border-base-300 rounded-3xl shadow-sm">
              <div class="flex items-center justify-between mb-6 pb-6 border-b border-base-200">
                <h2 class="text-xl font-black">{gettext("Question Content")}</h2>
              </div>
              <.content_block block={@block} mode={:review} submission={@submission} />
            </div>
          <% end %>
        </div>
      </div>

      <div class="w-full lg:w-96 shrink-0 bg-base-100 rounded-3xl border border-base-300 shadow-sm sticky mt-22 flex flex-col overflow-hidden">
        <div class="flex items-center justify-between gap-3 px-6 py-5 border-b border-base-300 bg-base-200/30">
          <div>
            <div class="text-xs text-base-content/50 font-bold uppercase tracking-wider">
              {gettext("Grading Panel")}
            </div>
            <div class="text-sm font-medium">
              {gettext("Evaluation")}
            </div>
          </div>
          <.status_badge status={@submission.status} />
        </div>

        <div class="p-6 space-y-6">
          <.form for={@form} id="grading-form" phx-submit="save_grade">
            <div class="space-y-4 mb-6">
              <div class="text-xs font-semibold text-base-content/50 uppercase tracking-wider">
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
              <div class="text-xs font-semibold text-base-content/50 uppercase tracking-wider">
                {gettext("Instructor Feedback")}
              </div>

              <.input
                type="textarea"
                field={@form[:feedback]}
                rows="6"
                label={gettext("Comments")}
                placeholder={
                  gettext("Write your feedback here... It will be visible to the student.")
                }
              />
            </div>

            <%= if (@submission.content["cheat_count"] || 0) > 0 do %>
              <div class="divider my-4"></div>
              <div class="space-y-4 mb-6">
                <div class="text-xs font-semibold text-error uppercase tracking-wider">
                  {gettext("Violations")}
                </div>
                <div class="p-4 bg-error/10 text-error rounded-xl border border-error/20">
                  <div class="font-black flex items-center gap-2 mb-1">
                    <.icon name="hero-eye" class="size-4" />
                    {gettext("Cheating Detected")}
                  </div>
                  <div class="text-sm">
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

        <div class="p-6 border-t border-base-300 bg-base-200/30">
          <button
            form="grading-form"
            type="submit"
            class="btn btn-primary w-full shadow-lg shadow-primary/20"
          >
            <.icon name="hero-check-circle" class="size-5 mr-2" />
            {gettext("Save & Mark as Graded")}
          </button>
        </div>
      </div>
    </div>
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
