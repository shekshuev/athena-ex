defmodule AthenaWeb.TeachingLive.Grading do
  @moduledoc """
  LiveView for managing student submissions and assignments.
  Uses strict, professional table UI consistent with the studio dashboard.
  """
  use AthenaWeb, :live_view

  alias AthenaWeb.TeachingLive.SubmissionLabels

  alias Athena.Learning
  alias Athena.Identity
  alias Athena.Content

  on_mount {AthenaWeb.Hooks.Permission, "grading.read"}

  @impl true
  def mount(_params, _session, socket) do
    cohort_options = Learning.get_cohort_options(socket.assigns.current_user)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Athena.PubSub, "grading:updates")
    end

    {:ok,
     socket
     |> assign(:accounts, %{})
     |> assign(:blocks, %{})
     |> assign(:has_submissions, false)
     |> assign(:cohort_options, cohort_options)
     |> assign(:delete_target, nil)
     |> stream(:submissions, [])}
  end

  @impl true
  def handle_params(params, url, socket) do
    uri = URI.parse(url)
    current_path = if uri.query, do: "#{uri.path}?#{uri.query}", else: uri.path

    socket = assign(socket, :current_path, current_path)

    {:noreply, load_submissions(socket, params)}
  end

  @impl true
  def handle_info({:submission_changed, _sub}, socket) do
    params = build_query_params(socket.assigns, %{})

    {:noreply, load_submissions(socket, params)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_submissions(socket, params) do
    status = Map.get(params, "status", "all")
    login = Map.get(params, "login", "")
    cohort_id = Map.get(params, "cohort_id", "")
    date_from = Map.get(params, "date_from", "")
    date_to = Map.get(params, "date_to", "")
    block_id = Map.get(params, "block_id", "")

    flop_filters =
      build_flop_filters(status, login, cohort_id, date_from, date_to, block_id)

    flop_params = Map.merge(params, %{"filters" => flop_filters})

    case Learning.list_submissions(socket.assigns.current_user, flop_params) do
      {:ok, {submissions, meta}} ->
        account_ids = Enum.map(submissions, & &1.account_id) |> Enum.uniq()
        block_ids = Enum.map(submissions, & &1.block_id) |> Enum.uniq()

        accounts = Identity.get_accounts_map(account_ids)
        blocks = Content.get_blocks_map(block_ids)

        socket
        |> assign(:meta, meta)
        |> assign(:current_status, status)
        |> assign(:login, login)
        |> assign(:cohort_id, cohort_id)
        |> assign(:date_from, date_from)
        |> assign(:date_to, date_to)
        |> assign(:block_id, block_id)
        |> assign(:accounts, accounts)
        |> assign(:blocks, blocks)
        |> assign(:has_submissions, submissions != [])
        |> stream(:submissions, submissions, reset: true)

      {:error, _meta} ->
        push_patch(socket, to: ~p"/teaching/grading")
    end
  end

  @impl true
  def handle_event("update_filters", params, socket) do
    overrides = %{
      "status" => params["status"] || "all",
      "login" => params["login"],
      "cohort_id" => params["cohort_id"],
      "date_from" => params["date_from"],
      "date_to" => params["date_to"],
      "page" => 1
    }

    query_params = build_query_params(socket.assigns, overrides)
    {:noreply, push_patch(socket, to: ~p"/teaching/grading?#{query_params}")}
  end

  def handle_event("update_page_size", %{"page_size" => size}, socket) do
    query_params = build_query_params(socket.assigns, %{"page_size" => size, "page" => 1})
    {:noreply, push_patch(socket, to: ~p"/teaching/grading?#{query_params}")}
  end

  @impl true
  def handle_event("reset_filters", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/teaching/grading")}
  end

  # One filter at a time, from its chip (`AthenaWeb.FilterComponents`).
  def handle_event("clear_filter", %{"key" => key}, socket)
      when key in ~w(status cohort_id login date_from date_to block_id) do
    cleared = if key == "status", do: "all", else: ""
    query_params = build_query_params(socket.assigns, %{key => cleared, "page" => 1})
    {:noreply, push_patch(socket, to: ~p"/teaching/grading?#{query_params}")}
  end

  def handle_event("clear_filter", _params, socket), do: {:noreply, socket}

  def handle_event("open_delete_modal", %{"id" => id}, socket) do
    submission = Learning.get_submission!(socket.assigns.current_user, id)
    {:noreply, assign(socket, :delete_target, submission)}
  end

  def handle_event("close_delete_modal", _, socket) do
    {:noreply, assign(socket, :delete_target, nil)}
  end

  def handle_event("confirm_delete_submission", _params, socket) do
    sub = socket.assigns.delete_target

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

        query_params = build_query_params(socket.assigns, %{})

        {:noreply,
         socket
         |> assign(:delete_target, nil)
         |> load_submissions(query_params)
         |> put_flash(:info, gettext("Submission deleted and progress rolled back!"))}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:delete_target, nil)
         |> put_flash(:error, gettext("Failed to delete submission."))}
    end
  end

  defp status_options do
    [
      {gettext("All Statuses"), "all"},
      {gettext("Needs Review"), "needs_review"},
      {gettext("Graded"), "graded"},
      {gettext("Rejected"), "rejected"}
    ]
  end

  # Chips for every filter currently narrowing the list.
  defp filter_chips(assigns) do
    [
      assigns.current_status not in ["", "all"] &&
        %{
          key: "status",
          label: gettext("Status"),
          value: option_label(status_options(), assigns.current_status)
        },
      assigns.cohort_id != "" &&
        %{
          key: "cohort_id",
          label: gettext("Cohort"),
          value: option_label(assigns.cohort_options, assigns.cohort_id)
        },
      assigns.login not in [nil, ""] &&
        %{key: "login", label: gettext("Student"), value: assigns.login},
      assigns.date_from != "" &&
        %{key: "date_from", label: gettext("From Date"), value: format_date(assigns.date_from)},
      assigns.date_to != "" &&
        %{key: "date_to", label: gettext("To Date"), value: format_date(assigns.date_to)},
      assigns.block_id != "" &&
        %{
          key: "block_id",
          label: gettext("Assignment"),
          value: assignment_label(assigns.blocks[assigns.block_id])
        }
    ]
    |> Enum.filter(& &1)
  end

  defp option_label(options, value) do
    Enum.find_value(options, value, fn {label, option} -> option == value && label end)
  end

  defp format_date(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> Calendar.strftime(date, "%d.%m.%Y")
      _ -> iso
    end
  end

  defp assignment_label(nil), do: gettext("Deleted")

  defp assignment_label(%{type: :quiz_exam}),
    do: gettext("Assessment Session") <> " " <> gettext("Block")

  defp assignment_label(%{type: :ticket_exam}),
    do: gettext("Ticket Assessment") <> " " <> gettext("Block")

  defp assignment_label(%{type: type}),
    do: (type |> Atom.to_string() |> String.replace("_", " ")) <> " " <> gettext("Block")

  defp build_flop_filters(status, login, cohort_id, date_from, date_to, block_id) do
    filters = []

    filters =
      if status in ["", "all"],
        do: filters,
        else: [%{"field" => "status", "op" => "==", "value" => status} | filters]

    filters =
      if cohort_id != "",
        do: [%{"field" => "in_cohort", "op" => "==", "value" => cohort_id} | filters],
        else: filters

    filters =
      if block_id != "",
        do: [%{"field" => "block_id", "op" => "==", "value" => block_id} | filters],
        else: filters

    # Picked dates are calendar days in the user's timezone.
    filters = add_date_bound_filter(filters, date_from, 0, ">=")
    filters = add_date_bound_filter(filters, date_to, 1, "<")

    filters =
      if login != "" do
        ids = Identity.get_account_ids_by_login_or_name(login)

        ids = if ids == [], do: [Ecto.UUID.generate()], else: ids
        [%{"field" => "account_id", "op" => "in", "value" => ids} | filters]
      else
        filters
      end

    filters
    |> Enum.with_index(fn filter, index -> {Integer.to_string(index), filter} end)
    |> Map.new()
  end

  defp add_date_bound_filter(filters, date_string, offset_days, op) do
    case TimeZones.local_day_start(date_string, offset_days) do
      {:ok, bound} -> [%{"field" => "inserted_at", "op" => op, "value" => bound} | filters]
      :error -> filters
    end
  end

  @doc false
  defp build_query_params(assigns, overrides) do
    meta = assigns.meta

    order_by =
      meta.flop.order_by
      |> List.wrap()
      |> Enum.map(&to_string/1)

    order_directions =
      meta.flop.order_directions
      |> List.wrap()
      |> Enum.map(&to_string/1)

    %{
      "status" => assigns.current_status,
      "login" => assigns.login,
      "cohort_id" => assigns.cohort_id,
      "date_from" => assigns.date_from,
      "date_to" => assigns.date_to,
      "block_id" => assigns.block_id,
      "page" => meta.current_page,
      "page_size" => meta.page_size,
      "order_by" => order_by,
      "order_directions" => order_directions
    }
    |> Map.merge(overrides)
    |> Enum.reject(fn
      {_, v} when is_list(v) -> v == []
      {_, v} -> v in [nil, "", "all", "false"]
    end)
    |> Map.new()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_container size="wide" class="space-y-6 pb-20">
      <div class="flex flex-col md:flex-row md:items-center justify-between gap-4">
        <div>
          <h1 class="text-2xl font-display font-bold text-base-content">
            {gettext("Grading Center")}
          </h1>
          <p class="text-base-content/60">
            {gettext("Review and grade student submissions.")}
          </p>
        </div>
      </div>

      <div class="bg-base-100 border border-base-200 rounded-box p-4">
        <div class="flex items-center justify-between mb-4">
          <h2 class="font-bold text-sm uppercase tracking-wider opacity-70">{gettext("Filters")}</h2>
        </div>

        <.form
          for={%{}}
          as={:filters}
          phx-change="update_filters"
          phx-submit="update_filters"
          class="space-y-4"
        >
          <div class="grid grid-cols-1 md:grid-cols-4 gap-4">
            <.input
              type="select"
              name="status"
              value={@current_status}
              options={status_options()}
              label={gettext("Status")}
            />
            <.input
              type="select"
              name="cohort_id"
              value={@cohort_id}
              options={@cohort_options}
              prompt={gettext("All Cohorts")}
              label={gettext("Cohort")}
            />
            <.input
              type="text"
              name="login"
              value={@login}
              label={gettext("Student (login or name)")}
              placeholder={gettext("Start typing...")}
            />
          </div>

          <div class="grid grid-cols-1 md:grid-cols-4 gap-4 items-end sm:grid">
            <.input type="date" name="date_from" value={@date_from} label={gettext("From Date")} />
            <.input type="date" name="date_to" value={@date_to} label={gettext("To Date")} />
          </div>
        </.form>
      </div>

      <.active_filters id="grading-active-filters" filters={filter_chips(assigns)} />

      <div
        :if={not @has_submissions}
        class="text-center py-24 px-6 border border-dashed border-base-300 rounded-box mt-4"
      >
        <.icon name="hero-inbox" class="size-16 text-base-content/20 mb-4 mx-auto" />
        <h3 class="text-xl font-bold text-base-content">
          {gettext("No submissions found")}
        </h3>
        <p class="text-base-content/60 mt-2 max-w-sm mx-auto text-sm">
          {gettext("You're all caught up! There are no student submissions matching your criteria.")}
        </p>
      </div>

      <% path_fn = fn overrides -> ~p"/teaching/grading?#{build_query_params(assigns, overrides)}" end %>

      <div :if={@has_submissions}>
        <.table id="submissions" rows={@streams.submissions} meta={@meta} path_fn={path_fn}>
          <:col :let={{_id, sub}} label={gettext("Student")}>
            <% account = @accounts[sub.account_id] %>
            <div class="font-bold">
              {if account, do: account.login, else: gettext("Unknown")}
            </div>
          </:col>

          <:col :let={{_id, sub}} label={gettext("Assignment")}>
            <span class="badge badge-neutral badge-sm font-medium tracking-wide">
              {assignment_label(@blocks[sub.block_id])}
            </span>
          </:col>

          <:col :let={{_id, sub}} label={gettext("Status")} sort="status">
            <.badge tone={status_tone(sub.status)} class="tracking-wide shrink-0">
              {SubmissionLabels.status_label(sub.status)}
            </.badge>
          </:col>

          <:col :let={{_id, sub}} label={gettext("Score")} sort="score">
            <div class={[
              "font-mono font-bold",
              sub.status == :needs_review && "text-base-content/50",
              sub.status in [
                :rejected,
                :wrong_answer,
                :compilation_error,
                :runtime_error,
                :time_limit_exceeded,
                :memory_limit_exceeded,
                :system_error
              ] && "text-error"
            ]}>
              <%= cond do %>
                <% sub.status == :needs_review -> %>
                  <span title={
                    gettext("Preliminary score - the answer still needs a teacher's review")
                  }>
                    {sub.score} <span class="text-xs opacity-50 font-normal">/ 100</span>
                    <.icon name="hero-clock-mini" class="size-3.5 align-text-bottom" />
                  </span>
                <% sub.status in [:pending, :processing, :draft] -> %>
                  —
                <% true -> %>
                  {sub.score} <span class="text-xs opacity-50 font-normal">/ 100</span>
              <% end %>
            </div>
          </:col>

          <:col :let={{_id, sub}} label={gettext("Submitted At")} sort="inserted_at">
            <span class="text-sm font-mono opacity-60">
              {TimeZones.format(sub.inserted_at, "%d.%m.%Y %H:%M")}
            </span>
          </:col>

          <:action :let={{_id, sub}}>
            <div class="flex justify-end gap-2">
              <.link
                :if={@block_id == ""}
                patch={
                  ~p"/teaching/grading?#{build_query_params(assigns, %{"block_id" => sub.block_id, "page" => 1})}"
                }
                class="btn btn-sm btn-ghost btn-square text-base-content/50 hover:text-primary"
                title={gettext("Filter by this assignment")}
              >
                <.icon name="hero-funnel" class="size-4" />
              </.link>

              <.link
                :if={
                  @blocks[sub.block_id] && @blocks[sub.block_id].type in [:quiz_exam, :ticket_exam]
                }
                navigate={~p"/teaching/grading/#{sub.id}/monitor"}
                class="btn btn-sm btn-ghost btn-square text-base-content/50 hover:text-warning"
                title={gettext("Monitor this group for cheating")}
              >
                <.icon name="hero-shield-exclamation" class="size-4" />
              </.link>

              <.link
                navigate={~p"/teaching/grading/#{sub.id}?return_to=#{@current_path}"}
                class={[
                  "btn btn-sm btn-square",
                  sub.status == :needs_review && "btn-primary",
                  sub.status != :needs_review && "btn-ghost"
                ]}
                title={if sub.status == :needs_review, do: gettext("Grade"), else: gettext("View")}
              >
                <.icon
                  name={if sub.status == :needs_review, do: "hero-pencil-square", else: "hero-eye"}
                  class="size-4"
                />
              </.link>

              <button
                type="button"
                phx-click="open_delete_modal"
                phx-value-id={sub.id}
                class="btn btn-sm btn-ghost btn-square text-base-content/50 hover:text-error"
                title={gettext("Delete Submission")}
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </div>
          </:action>
        </.table>
      </div>

      <div class="flex justify-end mt-4">
        <.pagination :if={@has_submissions} meta={@meta} path_fn={path_fn} />
      </div>

      <.modal
        :if={@delete_target}
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
    </.page_container>
    """
  end

  defp status_tone(status) when status in [:graded, :accepted], do: "success"
  defp status_tone(:needs_review), do: "warning"

  defp status_tone(status)
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

  defp status_tone(status) when status in [:pending, :processing], do: "neutral"
end
