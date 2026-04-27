defmodule AthenaWeb.StudioLive.Grading do
  @moduledoc """
  LiveView for managing student submissions and assignments.
  Uses strict, professional card UI consistent with the student dashboard.
  """
  use AthenaWeb, :live_view

  alias Athena.Learning
  alias Athena.Identity
  alias Athena.Content

  on_mount {AthenaWeb.Hooks.Permission, "grading.read"}

  @impl true
  def mount(_params, _session, socket) do
    cohort_options = Learning.get_cohort_options(socket.assigns.current_user)

    {:ok,
     socket
     |> assign(:accounts, %{})
     |> assign(:blocks, %{})
     |> assign(:has_submissions, false)
     |> assign(:cohort_options, cohort_options)
     |> stream(:submissions, [])}
  end

  @impl true
  def handle_params(params, url, socket) do
    uri = URI.parse(url)
    current_path = if uri.query, do: "#{uri.path}?#{uri.query}", else: uri.path

    status = Map.get(params, "status", "all")
    login = Map.get(params, "login", "")
    cohort_id = Map.get(params, "cohort_id", "")
    date_from = Map.get(params, "date_from", "")
    date_to = Map.get(params, "date_to", "")
    has_cheats = Map.get(params, "has_cheats", "false")

    flop_filters = build_flop_filters(status, login, cohort_id, date_from, date_to, has_cheats)
    flop_params = Map.merge(params, %{"filters" => flop_filters})

    case Learning.list_submissions(flop_params) do
      {:ok, {submissions, meta}} ->
        account_ids = Enum.map(submissions, & &1.account_id) |> Enum.uniq()
        block_ids = Enum.map(submissions, & &1.block_id) |> Enum.uniq()

        accounts = Identity.get_accounts_map(account_ids)
        blocks = Content.get_blocks_map(block_ids)

        socket =
          socket
          |> assign(:meta, meta)
          |> assign(:current_path, current_path)
          |> assign(:current_status, status)
          |> assign(:login, login)
          |> assign(:cohort_id, cohort_id)
          |> assign(:date_from, date_from)
          |> assign(:date_to, date_to)
          |> assign(:has_cheats, has_cheats)
          |> assign(:accounts, accounts)
          |> assign(:blocks, blocks)
          |> assign(:has_submissions, submissions != [])
          |> stream(:submissions, submissions, reset: true)

        {:noreply, socket}

      {:error, _meta} ->
        {:noreply, push_patch(socket, to: ~p"/studio/grading")}
    end
  end

  @impl true
  def handle_event("update_filters", params, socket) do
    query_params =
      %{
        "status" => params["status"] || "all",
        "login" => params["login"],
        "cohort_id" => params["cohort_id"],
        "date_from" => params["date_from"],
        "date_to" => params["date_to"],
        "has_cheats" => params["has_cheats"] || "false"
      }
      |> Enum.reject(fn {_, v} -> v in ["", nil, "false"] end)
      |> Map.new()

    {:noreply, push_patch(socket, to: ~p"/studio/grading?#{query_params}")}
  end

  @impl true
  def handle_event("reset_filters", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/studio/grading")}
  end

  defp build_flop_filters(status, login, cohort_id, date_from, date_to, has_cheats) do
    filters = []

    filters =
      if status in ["", "all"],
        do: filters,
        else: [%{"field" => "status", "op" => "==", "value" => status} | filters]

    filters =
      if cohort_id != "",
        do: [%{"field" => "cohort_id", "op" => "==", "value" => cohort_id} | filters],
        else: filters

    filters =
      if date_from != "",
        do: [
          %{"field" => "inserted_at", "op" => ">=", "value" => date_from <> "T00:00:00Z"}
          | filters
        ],
        else: filters

    filters =
      if date_to != "",
        do: [
          %{"field" => "inserted_at", "op" => "<=", "value" => date_to <> "T23:59:59Z"} | filters
        ],
        else: filters

    filters =
      if has_cheats == "true",
        do: [%{"field" => "has_cheats", "op" => "==", "value" => true} | filters],
        else: filters

    filters =
      if login != "" do
        ids = Identity.get_account_ids_by_login(login)

        ids = if ids == [], do: [Ecto.UUID.generate()], else: ids
        [%{"field" => "account_id", "op" => "in", "value" => ids} | filters]
      else
        filters
      end

    filters
    |> Enum.with_index(fn filter, index -> {Integer.to_string(index), filter} end)
    |> Map.new()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto space-y-8 pb-20">
      <div class="flex flex-col md:flex-row md:items-center justify-between gap-4">
        <div class="flex flex-col gap-2">
          <h1 class="text-3xl font-display font-black text-base-content tracking-tight">
            {gettext("Grading Center")}
          </h1>
          <p class="text-base-content/60 text-lg">
            {gettext("Review and grade student submissions.")}
          </p>
        </div>
      </div>

      <div class="flex items-center justify-between mb-4 pb-4 border-b border-base-100">
        <h2 class="text-lg font-bold">{gettext("Filters")}</h2>
        <button
          phx-click="reset_filters"
          type="button"
          class="btn btn-ghost btn-sm text-base-content/60 hover:text-error transition-colors"
        >
          <.icon name="hero-arrow-path" class="size-4 mr-1" />
          {gettext("Reset")}
        </button>
      </div>

      <.form
        for={%{}}
        as={:filters}
        phx-change="update_filters"
        phx-submit="update_filters"
        class="space-y-4"
      >
        <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
          <.input
            type="select"
            name="status"
            value={@current_status}
            options={[
              {gettext("All Statuses"), "all"},
              {gettext("Needs Review"), "needs_review"},
              {gettext("Graded"), "graded"},
              {gettext("Rejected"), "rejected"}
            ]}
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
            label={gettext("Student Login")}
            placeholder={gettext("Start typing...")}
          />
        </div>

        <div class="grid grid-cols-1 md:grid-cols-3 gap-4 items-end">
          <.input type="date" name="date_from" value={@date_from} label={gettext("From Date")} />
          <.input type="date" name="date_to" value={@date_to} label={gettext("To Date")} />
          <div class="pb-2">
            <.input
              type="checkbox"
              name="has_cheats"
              value="true"
              checked={@has_cheats == "true"}
              label={gettext("Cheaters Only")}
            />
          </div>
        </div>
      </.form>

      <div :if={not @has_submissions} class="text-center py-24 px-6 mt-8">
        <.icon name="hero-inbox" class="size-20 text-base-content/20 mb-6 mx-auto" />
        <h3 class="text-2xl font-display font-bold text-base-content">
          {gettext("No submissions found")}
        </h3>
        <p class="text-base-content/60 mt-3 max-w-md mx-auto text-lg">
          {gettext(
            "You're all caught up! There are no student submissions matching this filter right now."
          )}
        </p>
      </div>

      <div :if={@has_submissions} class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-8 mt-8">
        <div
          :for={{dom_id, sub} <- @streams.submissions}
          id={dom_id}
          class="card bg-base-100 border border-base-200 shadow-sm hover:shadow-xl hover:border-primary/40 transition-all duration-300 overflow-hidden group flex flex-col"
        >
          <div class={[
            "h-1.5 w-full",
            sub.status == :needs_review && "bg-warning",
            sub.status == :graded && "bg-success",
            sub.status == :rejected && "bg-error",
            sub.status in [:pending, :processing] && "bg-base-300"
          ]}>
          </div>

          <div class="card-body p-6 grow gap-4">
            <div class="flex justify-between items-start gap-4">
              <div>
                <div class="text-[10px] font-bold text-base-content/50 uppercase tracking-widest mb-1">
                  {gettext("Student")}
                </div>
                <% account = @accounts[sub.account_id] %>
                <h2
                  class="card-title text-xl font-display font-bold group-hover:text-primary transition-colors truncate"
                  title={if account, do: account.login, else: gettext("Unknown")}
                >
                  {if account, do: account.login, else: gettext("Unknown")}
                </h2>
              </div>
              <.status_badge status={sub.status} />
            </div>

            <div class="flex flex-col gap-4 mt-2">
              <div>
                <div class="text-[10px] font-bold text-base-content/50 uppercase tracking-widest mb-1.5">
                  {gettext("Assignment Type")}
                </div>
                <span class="badge badge-neutral badge-sm font-medium tracking-wide">
                  <%= if @blocks[sub.block_id] do %>
                    {Atom.to_string(@blocks[sub.block_id].type) |> String.replace("_", " ")}
                  <% else %>
                    {gettext("Deleted Block")}
                  <% end %>
                </span>
              </div>

              <div>
                <div class="text-[10px] font-bold text-base-content/50 uppercase tracking-widest mb-1">
                  {gettext("Score")}
                </div>
                <div class={[
                  "font-black text-3xl font-mono",
                  sub.status == :needs_review && "text-base-content/20",
                  sub.status == :graded && "text-base-content",
                  sub.status == :rejected && "text-error"
                ]}>
                  <%= if sub.status in [:graded, :rejected] do %>
                    {sub.score} <span class="text-lg opacity-40 font-bold">/ 100</span>
                  <% else %>
                    —
                  <% end %>
                </div>
              </div>
            </div>

            <div class="mt-auto pt-6 flex items-center justify-between border-t border-base-200/50">
              <div class="text-xs font-mono font-medium text-base-content/50">
                {Calendar.strftime(sub.inserted_at, "%d.%m.%Y %H:%M")}
              </div>

              <.link
                navigate={~p"/studio/grading/#{sub.id}?return_to=#{@current_path}"}
                class={[
                  "btn btn-sm group-hover:pr-3 transition-all",
                  sub.status == :needs_review && "btn-primary",
                  sub.status != :needs_review &&
                    "btn-outline border-base-300 text-base-content/70 hover:bg-base-200 hover:text-base-content hover:border-base-300"
                ]}
              >
                {if sub.status == :needs_review, do: gettext("Grade"), else: gettext("View")}
                <.icon
                  name="hero-arrow-right"
                  class="size-4 opacity-0 -ml-4 group-hover:opacity-100 group-hover:ml-0 transition-all duration-300"
                />
              </.link>
            </div>
          </div>
        </div>
      </div>

      <div class="flex justify-end mt-8">
        <.pagination
          meta={@meta}
          path_fn={
            fn p ->
              ~p"/studio/grading?page=#{p}&status=#{@current_status}&login=#{@login}&cohort_id=#{@cohort_id}&date_from=#{@date_from}&date_to=#{@date_to}&has_cheats=#{@has_cheats}"
            end
          }
        />
      </div>
    </div>
    """
  end

  defp status_badge(assigns) do
    ~H"""
    <span class={[
      "badge badge-sm font-bold border-0 tracking-wide shrink-0",
      @status == :graded && "bg-success/10 text-success",
      @status == :needs_review && "bg-warning/10 text-warning",
      @status == :rejected && "bg-error/10 text-error",
      @status in [:pending, :processing] && "bg-base-200 text-base-content/70"
    ]}>
      {Atom.to_string(@status) |> String.replace("_", " ") |> String.capitalize()}
    </span>
    """
  end
end
