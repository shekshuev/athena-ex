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

    with {:ok, account} <- Identity.get_account(submission.account_id),
         {:ok, block} <- Content.get_block(submission.block_id) do
      setup_grading_state(socket, submission, account, block, return_to)
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Submission data is no longer available."))
         |> push_navigate(to: return_to)}
    end
  end

  defp setup_grading_state(socket, submission, account, block, return_to) do
    form = to_form(%{"score" => submission.score, "feedback" => submission.feedback || ""})
    is_exam = block.type in [:quiz_exam, :ticket_exam]

    child_subs = if is_exam, do: Learning.get_child_submissions(submission.id), else: %{}
    questions = if is_exam, do: hydrate_questions(submission.content["questions"] || []), else: []

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Athena.PubSub, "submission:#{account.id}:#{block.id}")

      Enum.each(questions, fn q ->
        Phoenix.PubSub.subscribe(Athena.PubSub, "submission:#{account.id}:#{q.id}")
      end)
    end

    {:ok,
     socket
     |> assign(
       page_title: gettext("Grade Submission"),
       submission: submission,
       account: account,
       block: block,
       form: form,
       return_to: return_to,
       show_delete_modal: false,
       child_submissions: child_subs,
       questions: questions,
       manual_score_override: false,
       child_grades_params: %{},
       running_tests: %{}
     )}
  end

  @impl true
  def handle_event(
        "save_grade",
        %{"action" => action, "score" => score, "feedback" => feedback} = params,
        socket
      ) do
    status = if action == "reject", do: "rejected", else: "graded"

    final_score =
      if action == "reject" do
        0
      else
        case Integer.parse(to_string(score)) do
          {val, _} -> val
          :error -> 0
        end
      end

    attrs = %{"score" => final_score, "feedback" => feedback, "status" => status}

    case Learning.update_submission(socket.assigns.current_user, socket.assigns.submission, attrs) do
      {:ok, _updated_sub} ->
        update_all_child_grades(socket, params["child_grades"] || %{}, status)

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
  def handle_event("validate_grade", params, socket) do
    target = params["_target"] || []

    manual_override =
      case target do
        ["score"] -> true
        ["child_grades" | _rest] -> false
        _ -> socket.assigns.manual_score_override
      end

    child_grades = params["child_grades"] || %{}

    new_score =
      if not manual_override and socket.assigns.block.type in [:quiz_exam, :ticket_exam] do
        recalculate_overall_score(
          socket.assigns.questions,
          socket.assigns.child_submissions,
          child_grades
        )
      else
        params["score"]
      end

    form = to_form(%{"score" => new_score, "feedback" => params["feedback"]})

    {:noreply,
     socket
     |> assign(form: form)
     |> assign(child_grades_params: child_grades)
     |> assign(manual_score_override: manual_override)}
  end

  def handle_event("open_delete_modal", _, socket) do
    {:noreply, assign(socket, show_delete_modal: true)}
  end

  def handle_event("close_delete_modal", _, socket) do
    {:noreply, assign(socket, show_delete_modal: false)}
  end

  def handle_event("confirm_delete_submission", _params, socket) do
    sub = socket.assigns.submission

    case Learning.delete_submission_with_rollback(socket.assigns.current_user, sub) do
      {:ok, _deleted_sub} ->
        if sub.cohort_id do
          Phoenix.PubSub.broadcast(
            Athena.PubSub,
            "team_progress:#{sub.cohort_id}",
            :team_progress_updated
          )
        else
          Phoenix.PubSub.broadcast(
            Athena.PubSub,
            "user_progress:#{sub.account_id}",
            :user_progress_updated
          )
        end

        {:noreply,
         socket
         |> put_flash(:info, gettext("Submission deleted and progress rolled back!"))
         |> push_navigate(to: socket.assigns.return_to)}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(show_delete_modal: false)
         |> put_flash(:error, gettext("Failed to delete submission."))}
    end
  end

  @impl true
  def handle_event("run_code", %{"block_id" => block_id}, socket) do
    block =
      if socket.assigns.block.id == block_id do
        socket.assigns.block
      else
        Enum.find(socket.assigns.questions, &(&1.id == block_id))
      end

    sub =
      if socket.assigns.submission.block_id == block_id do
        socket.assigns.submission
      else
        Map.get(socket.assigns.child_submissions, block_id)
      end

    if block && sub do
      content =
        if is_struct(sub.content), do: Map.from_struct(sub.content), else: sub.content || %{}

      code =
        content["code"] || content[:code] || content["text_answer"] || content[:text_answer] || ""

      if code == "" do
        {:noreply, put_flash(socket, :error, gettext("Student submission is empty."))}
      else
        challenge =
          Ecto.Changeset.apply_changes(
            Athena.Content.CodeChallenge.changeset(%Athena.Content.CodeChallenge{}, block.content)
          )

        runner = {:via, :global, :code_runner}

        if :global.whereis_name(:code_runner) != :undefined do
          task =
            Task.Supervisor.async(runner, fn ->
              box_id = System.unique_integer([:positive, :monotonic]) |> rem(10_000)
              Athena.Execution.verify(code, challenge, box_id)
            end)

          running_tests = Map.put(socket.assigns[:running_tests] || %{}, task.ref, block.id)

          {:noreply,
           socket
           |> assign(:running_tests, running_tests)
           |> put_flash(:info, gettext("Running student's code... Please wait."))}
        else
          {:noreply, put_flash(socket, :error, gettext("Runner node is not connected!"))}
        end
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Could not find submission data."))}
    end
  end

  defp update_all_child_grades(socket, child_grades, status) do
    Enum.each(child_grades, fn {child_block_id, grade_data} ->
      child_sub = Map.get(socket.assigns.child_submissions, child_block_id)
      update_single_child_grade(socket.assigns.current_user, child_sub, grade_data, status)
    end)
  end

  defp update_single_child_grade(_user, nil, _grade_data, _status), do: :ok

  defp update_single_child_grade(user, child_sub, grade_data, status) do
    child_score =
      case Integer.parse(to_string(grade_data["score"])) do
        {val, _} -> val
        :error -> child_sub.score || 0
      end

    child_attrs = %{
      "score" => child_score,
      "feedback" => grade_data["feedback"],
      "status" => status
    }

    Learning.update_submission(user, child_sub, child_attrs)
  end

  @impl true
  def handle_info({:submission_updated, updated_sub}, socket) do
    if updated_sub.id == socket.assigns.submission.id do
      new_score =
        if socket.assigns.manual_score_override do
          socket.assigns.form.params["score"] || updated_sub.score
        else
          updated_sub.score || 0
        end

      form =
        to_form(%{
          "score" => new_score,
          "feedback" => socket.assigns.form.params["feedback"] || ""
        })

      {:noreply, assign(socket, submission: updated_sub, form: form)}
    else
      new_subs = Map.put(socket.assigns.child_submissions, updated_sub.block_id, updated_sub)

      new_score =
        if socket.assigns.manual_score_override do
          socket.assigns.form.params["score"] || socket.assigns.submission.score
        else
          recalculate_overall_score(
            socket.assigns.questions,
            new_subs,
            socket.assigns.child_grades_params
          )
        end

      form =
        to_form(%{
          "score" => new_score,
          "feedback" => socket.assigns.form.params["feedback"] || ""
        })

      {:noreply, assign(socket, child_submissions: new_subs, form: form)}
    end
  end

  @impl true
  def handle_info({ref, result}, socket) when is_map_key(socket.assigns.running_tests, ref) do
    {_block_id, updated_tests} = Map.pop(socket.assigns.running_tests, ref)
    Process.demonitor(ref, [:flush])

    socket =
      if result.status == :accepted do
        put_flash(
          socket,
          :info,
          gettext("Success! Code passed tests (Score: %{score})", score: result.score)
        )
      else
        put_flash(
          socket,
          :error,
          gettext("Code Failed! Status: %{status}.", status: result.status)
        )
      end

    {:noreply, assign(socket, :running_tests, updated_tests)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, socket) do
    if socket.assigns[:running_tests] && is_map_key(socket.assigns.running_tests, ref) do
      {_block_id, updated_tests} = Map.pop(socket.assigns.running_tests, ref)

      {:noreply,
       socket
       |> put_flash(:error, gettext("Test execution failed or runner disconnected."))
       |> assign(:running_tests, updated_tests)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto pb-20">
      <div class="flex items-center gap-4 mb-8 border-b border-base-200 pb-6">
        <.link
          navigate={@return_to}
          class="btn btn-ghost btn-sm btn-square rounded-sm hover:bg-base-200"
        >
          <.icon name="hero-arrow-left" class="size-5" />
        </.link>
        <div>
          <h1 class="text-2xl font-black font-display tracking-tight">
            {gettext("Submission from %{name}", name: @account.login)}
          </h1>
          <div class="text-xs font-bold text-base-content/50 uppercase tracking-widest mt-1 flex items-center gap-2">
            <span>
              {gettext("Block Type:")}
              <%= cond do %>
                <% @block.type == :quiz_exam -> %>
                  {gettext("Assessment Session")} {gettext("Block")}
                <% @block.type == :ticket_exam -> %>
                  {gettext("Ticket Assessment")} {gettext("Block")}
                <% true -> %>
                  {Atom.to_string(@block.type) |> String.replace("_", " ")} {gettext("Block")}
              <% end %>
            </span>
            <span
              :if={manual_review_required?(@block)}
              class="badge badge-sm rounded-sm font-bold bg-warning/10 text-warning border border-warning/30 uppercase tracking-widest text-[10px]"
            >
              {gettext("Manual Review")}
            </span>
          </div>
        </div>
      </div>

      <div class="flex flex-col lg:flex-row items-start gap-8">
        <div class="flex-1 w-full min-w-0 space-y-6 ">
          <%= if @block.type in [:quiz_exam, :ticket_exam] do %>
            <div class="space-y-6">
              <.content_block
                block={@block}
                mode={:review}
                submission={@submission}
                hide_submit={true}
              />

              <div
                :for={{q_block, index} <- Enum.with_index(@questions)}
                class="p-6 bg-base-100 border border-base-300 rounded-sm relative group hover:border-primary/30 transition-all"
              >
                <div class="absolute -top-3 -left-3 size-7 bg-base-200 text-base-content/70 font-bold rounded-sm flex items-center justify-center border border-base-300 text-xs group-hover:bg-primary group-hover:text-primary-content group-hover:border-primary transition-colors">
                  {index + 1}
                </div>

                <div class="flex items-center justify-between mb-6 pb-4 border-b border-base-300">
                  <h2 class="text-lg font-bold">{gettext("Question Content")}</h2>
                  <div class="flex items-center gap-2">
                    <span class="badge badge-sm rounded-sm font-bold bg-base-200 border border-base-300 text-base-content/70 uppercase tracking-widest text-[10px]">
                      {q_block.content["question_type"] || q_block.type}
                    </span>
                    <span
                      :if={manual_review_required?(q_block)}
                      class="badge badge-sm rounded-sm font-bold bg-warning/10 text-warning border border-warning/30 uppercase tracking-widest text-[10px]"
                    >
                      {gettext("Manual Review")}
                    </span>
                  </div>
                </div>

                <% child_sub = Map.get(@child_submissions, q_block.id) %>
                <% grade_params = Map.get(@child_grades_params, q_block.id) || %{} %>

                <.content_block
                  block={q_block}
                  mode={:review}
                  submission={child_sub}
                  hide_submit={true}
                />
                <div class="mt-4">
                  <div class="text-xs font-bold uppercase tracking-wider mb-3">
                    {gettext("Instructor Feedback for this answer")}
                  </div>
                  <div class="flex flex-col sm:flex-row gap-4">
                    <div class="w-full sm:w-24 shrink-0">
                      <label class="label text-xs font-bold text-base-content/70 pb-1 px-0">
                        {gettext("Score")}
                      </label>
                      <input
                        type="number"
                        form="grading-form"
                        name={"child_grades[#{q_block.id}][score]"}
                        value={
                          Map.get(grade_params, "score") || if child_sub, do: child_sub.score, else: 0
                        }
                        class="input input-sm w-full"
                        min="0"
                        max="100"
                      />
                    </div>
                    <div class="flex-1">
                      <label class="label text-xs font-bold text-base-content/70 pb-1 px-0">
                        {gettext("Comment")}
                      </label>
                      <textarea
                        form="grading-form"
                        name={"child_grades[#{q_block.id}][feedback]"}
                        class="textarea textarea-sm w-full resize-none"
                        rows="2"
                        placeholder={gettext("Specific feedback for this answer...")}
                      ><%= Map.get(grade_params, "feedback") || (if child_sub, do: child_sub.feedback, else: "") %></textarea>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          <% else %>
            <div class="p-6 bg-base-100 border border-base-300 rounded-sm">
              <div class="flex items-center justify-between mb-6 pb-4 border-b border-base-300">
                <h2 class="text-lg font-bold">{gettext("Question Content")}</h2>
              </div>
              <.content_block block={@block} mode={:review} submission={@submission} />
            </div>
          <% end %>
        </div>

        <div class="w-full lg:w-100 shrink-0 bg-base-100 rounded-sm border border-base-300 sticky top-8 flex flex-col overflow-hidden">
          <div class="flex items-center justify-between gap-3 px-6 py-5 border-b border-base-300">
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
            <.form for={@form} id="grading-form" phx-change="validate_grade" phx-submit="save_grade">
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
                  <div class="p-4 bg-error/10 text-error rounded-sm border border-error/30">
                    <div class="font-bold flex items-center gap-2 mb-1">
                      <.icon name="hero-eye" class="size-4" />
                      {gettext("Cheating Detected")}
                    </div>
                    <div class="text-sm font-medium">
                      {gettext(
                        "The student triggered %{count} violations during this session.",
                        count: @submission.content["cheat_count"]
                      )}
                    </div>
                  </div>
                </div>
              <% end %>
            </.form>
          </div>

          <div class="p-6 border-t border-base-300 flex flex-col gap-4">
            <div class="flex gap-4">
              <button
                form="grading-form"
                type="submit"
                name="action"
                value="reject"
                class="btn btn-outline btn-error"
              >
                <.icon name="hero-x-mark" class="size-5 mr-1" />
                {gettext("Reject")}
              </button>

              <button
                form="grading-form"
                type="submit"
                name="action"
                value="grade"
                class="btn btn-primary"
              >
                <.icon name="hero-check-circle" class="size-5 mr-2" />
                {gettext("Save & Grade")}
              </button>
            </div>

            <div class="divider my-0"></div>

            <button
              type="button"
              phx-click="open_delete_modal"
              class="btn btn-outline btn-error w-full"
            >
              <.icon name="hero-trash" class="size-4 mr-1" />
              {gettext("Delete Submission")}
            </button>
          </div>
        </div>
      </div>
      <.modal
        :if={@show_delete_modal}
        id="delete-submission-modal"
        show={true}
        title={gettext("Delete Submission")}
        description={
          gettext(
            "Are you sure? This will delete the submission and may lock the next lesson part for the student."
          )
        }
        confirm_label={gettext("Delete & Rollback")}
        danger={true}
        on_cancel={JS.push("close_delete_modal")}
        on_confirm={JS.push("confirm_delete_submission")}
      />
    </div>
    """
  end

  defp status_badge(assigns) do
    ~H"""
    <span class={[
      "badge font-bold border tracking-wide rounded-sm",
      @status in [:graded, :accepted] && "bg-success/10 text-success border-success/30",
      @status == :needs_review && "bg-warning/10 text-warning border-warning/30",
      @status in [:pending, :processing] && "bg-base-200 text-base-content/70 border-base-300",
      @status in [
        :rejected,
        :wrong_answer,
        :compilation_error,
        :runtime_error,
        :time_limit_exceeded,
        :memory_limit_exceeded,
        :system_error
      ] && "bg-error/10 text-error border-error/30"
    ]}>
      {Atom.to_string(@status) |> String.replace("_", " ") |> String.capitalize()}
    </span>
    """
  end

  @doc false
  defp hydrate_questions(questions) when is_list(questions),
    do:
      Enum.map(questions, fn q ->
        q_map = if is_struct(q), do: Map.from_struct(q), else: q
        type_raw = Map.get(q_map, "type") || Map.get(q_map, :type)
        type = if is_binary(type_raw), do: String.to_atom(type_raw), else: type_raw
        content = Map.get(q_map, "content") || Map.get(q_map, :content) || %{}
        id = Map.get(q_map, "id") || Map.get(q_map, :id)

        %{id: id, type: type, content: content}
      end)

  defp hydrate_questions(_), do: []

  @doc false
  defp recalculate_overall_score(questions, child_submissions, child_grades_params) do
    total_earned =
      Enum.reduce(questions, 0, fn q, acc ->
        score_str = get_in(child_grades_params, [q.id, "score"])

        score =
          case Integer.parse(to_string(score_str)) do
            {val, _} ->
              val

            :error ->
              sub = Map.get(child_submissions, q.id)
              (sub && sub.score) || 0
          end

        acc + score
      end)

    total_questions = length(questions)
    if total_questions > 0, do: round(total_earned / total_questions), else: 0
  end

  # Helper to identify if a block requires manual review
  defp manual_review_required?(%{type: type, content: content}) do
    type in [:code, :file_assignment, "code", "file_assignment"] or
      (type in [:quiz_question, "quiz_question"] and is_map(content) and
         content["question_type"] == "open")
  end

  defp manual_review_required?(_), do: false
end
