defmodule AthenaWeb.TeachingLive.GradingMonitor do
  @moduledoc """
  Live, group-wide cheating monitor for one exam block (`quiz_exam` /
  `ticket_exam`). Reached from `AthenaWeb.TeachingLive.Grading` by
  clicking a submission's monitor button - resolves the clicked
  submission's academic group, then shows every member's live risk
  indicator for that same block, updating in real time as students take
  the assessment.
  """
  use AthenaWeb, :live_view

  alias Athena.{Content, Engagement, Identity, Learning}
  import AthenaWeb.ProctoringComponents

  on_mount {AthenaWeb.Hooks.Permission, "grading.update"}

  @impl true
  def mount(%{"id" => submission_id}, _session, socket) do
    submission = Learning.get_submission!(socket.assigns.current_user, submission_id)

    with {:ok, block} <- Content.get_block(submission.block_id),
         {:ok, section} <- Content.get_section(block.section_id),
         %{} = cohort <-
           Learning.get_academic_cohort_for_course(submission.account_id, section.course_id) do
      setup_monitor_state(socket, block, cohort)
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Could not resolve this submission's group."))
         |> push_navigate(to: ~p"/teaching/grading")}
    end
  end

  defp setup_monitor_state(socket, block, cohort) do
    submissions_by_account = Learning.list_group_submissions_for_block(cohort.id, block.id)
    accounts = Identity.get_accounts_map(Map.keys(submissions_by_account))

    # Every cohort member gets a "submission:" subscription up front, even
    # the ones who haven't started yet (`sub` is nil) - `list_group_
    # submissions_for_block/2` returns one entry per member for exactly this
    # reason. What's tracked here is *which of them are also already
    # subscribed to their own "proctoring:" channel*, so a student who
    # starts after this mount gets picked up by `:submission_updated` below
    # instead of staying badge-less until their first blur/proctoring ping.
    proctoring_subscribed_ids =
      if connected?(socket) do
        submissions_by_account
        |> Enum.map(&subscribe_to_member(&1, block))
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()
      else
        MapSet.new()
      end

    {:ok,
     socket
     |> assign(
       page_title: gettext("Cheating Monitor"),
       block: block,
       cohort: cohort,
       accounts: accounts,
       submissions: submissions_by_account,
       proctoring_subscribed_ids: proctoring_subscribed_ids,
       live_results: %{}
     )
     |> refresh_live_results(submissions_by_account)}
  end

  defp subscribe_to_member({account_id, sub}, block) do
    Phoenix.PubSub.subscribe(Athena.PubSub, "submission:#{account_id}:#{block.id}")

    if sub && sub.status == :pending do
      Phoenix.PubSub.subscribe(Athena.PubSub, "proctoring:#{sub.id}")
      sub.id
    end
  end

  defp refresh_live_results(socket, submissions_by_account) do
    allowed_blur_attempts = socket.assigns.block.content["allowed_blur_attempts"] || 3

    live_results =
      submissions_by_account
      |> Enum.filter(fn {_account_id, sub} -> sub && sub.status == :pending end)
      |> Map.new(fn {_account_id, sub} ->
        {sub.id,
         Engagement.evaluate_live_proctoring(
           sub.id,
           socket.assigns.cohort.id,
           socket.assigns.block.id,
           allowed_blur_attempts
         )}
      end)

    assign(socket, :live_results, live_results)
  end

  @impl true
  def handle_info({:proctoring_updated, submission_id}, socket) do
    {:noreply, put_live_result(socket, submission_id)}
  end

  def handle_info({:submission_updated, updated_sub}, socket) do
    socket =
      assign(
        socket,
        :submissions,
        Map.put(socket.assigns.submissions, updated_sub.account_id, updated_sub)
      )

    cond do
      updated_sub.status == :pending and
          updated_sub.id not in socket.assigns.proctoring_subscribed_ids ->
        # First we're hearing of this attempt (it started, or a resit
        # created a new one, after this monitor mounted) - start tracking it
        # live right away instead of waiting for its first proctoring ping.
        Phoenix.PubSub.subscribe(Athena.PubSub, "proctoring:#{updated_sub.id}")

        socket =
          assign(
            socket,
            :proctoring_subscribed_ids,
            MapSet.put(socket.assigns.proctoring_subscribed_ids, updated_sub.id)
          )

        {:noreply, put_live_result(socket, updated_sub.id)}

      updated_sub.status != :pending ->
        Phoenix.PubSub.unsubscribe(Athena.PubSub, "proctoring:#{updated_sub.id}")

        {:noreply,
         socket
         |> assign(
           :proctoring_subscribed_ids,
           MapSet.delete(socket.assigns.proctoring_subscribed_ids, updated_sub.id)
         )
         |> assign(:live_results, Map.delete(socket.assigns.live_results, updated_sub.id))}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp put_live_result(socket, submission_id) do
    allowed_blur_attempts = socket.assigns.block.content["allowed_blur_attempts"] || 3

    fields =
      Engagement.evaluate_live_proctoring(
        submission_id,
        socket.assigns.cohort.id,
        socket.assigns.block.id,
        allowed_blur_attempts
      )

    assign(socket, :live_results, Map.put(socket.assigns.live_results, submission_id, fields))
  end

  # The badge always needs a `content` map shaped like `Submission.content`
  # (see `Athena.Engagement.Proctoring.summary/1`). For a finalized attempt
  # that's simply `sub.content` (already written at submit time - see
  # `submit_and_exit/4` in the exam LiveViews). For an attempt still in
  # progress, `sub.content` has no `risk_level` yet, so the live evaluation
  # cached in `@live_results` (refreshed on every `:proctoring_updated`
  # ping) is used instead - the indicator updates live without ever
  # round-tripping through the database.
  defp indicator_content(nil, _live_results), do: nil

  defp indicator_content(%{status: :pending} = sub, live_results),
    do: Map.get(live_results, sub.id, %{})

  defp indicator_content(sub, _live_results), do: sub.content

  defp status_label(nil), do: gettext("Not started")

  defp status_label(sub),
    do: Atom.to_string(sub.status) |> String.replace("_", " ") |> String.capitalize()

  defp status_tone(nil), do: "neutral"
  defp status_tone(%{status: status}) when status in [:graded, :accepted], do: "success"
  defp status_tone(%{status: :needs_review}), do: "warning"
  defp status_tone(%{status: status}) when status in [:pending, :processing], do: "neutral"

  defp status_tone(%{status: status})
       when status in [
              :rejected,
              :wrong_answer,
              :compilation_error,
              :runtime_error,
              :time_limit_exceeded,
              :memory_limit_exceeded,
              :system_error
            ],
       do: "error"

  @impl true
  def render(assigns) do
    ~H"""
    <.page_container size="wide" class="space-y-6 pb-20">
      <div class="flex items-center gap-4">
        <.link
          navigate={~p"/teaching/grading?block_id=#{@block.id}"}
          class="btn btn-ghost btn-sm btn-square rounded-sm hover:bg-base-200"
        >
          <.icon name="hero-arrow-left" class="size-5" />
        </.link>
        <div>
          <h1 class="text-2xl font-black font-display tracking-tight">
            {gettext("Cheating Monitor")}
          </h1>
          <p class="text-base-content/60 text-sm">
            {gettext("Group %{cohort} - live risk for this assessment.", cohort: @cohort.name)}
          </p>
        </div>
      </div>

      <.risk_explanation />

      <div class="bg-base-100 border border-base-200 rounded-box overflow-hidden">
        <table class="table">
          <thead>
            <tr>
              <th>{gettext("Student")}</th>
              <th>{gettext("Risk")}</th>
              <th>{gettext("Status")}</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={
              {account_id, sub} <-
                Enum.sort_by(@submissions, fn {account_id, _sub} ->
                  account = @accounts[account_id]
                  if account, do: Identity.display_name(account), else: ""
                end)
            }>
              <td>
                <% account = @accounts[account_id] %>
                <% name = account && Identity.display_name(account) %>
                <div class="font-bold">{name || gettext("Unknown")}</div>
                <div :if={account && name != account.login} class="text-xs text-base-content/50">
                  {account.login}
                </div>
              </td>
              <td>
                <.risk_badge content={indicator_content(sub, @live_results)} />
              </td>
              <td>
                <.badge tone={status_tone(sub)} class="tracking-wide">
                  {status_label(sub)}
                </.badge>
              </td>
              <td class="text-right">
                <.link
                  :if={sub}
                  navigate={~p"/teaching/grading/#{sub.id}"}
                  class="btn btn-sm btn-ghost"
                >
                  {gettext("Open")} <.icon name="hero-arrow-right" class="size-4 ml-1" />
                </.link>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </.page_container>
    """
  end
end
