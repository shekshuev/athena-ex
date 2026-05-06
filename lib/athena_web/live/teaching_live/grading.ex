defmodule AthenaWeb.TeachingLive.Grading do
  @moduledoc """
  LiveView for managing student submissions and assignments.
  Uses strict, professional table UI consistent with the studio dashboard.
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
    # <-- Ловим скрытый параметр
    block_id = Map.get(params, "block_id", "")

    flop_filters =
      build_flop_filters(status, login, cohort_id, date_from, date_to, has_cheats, block_id)

    flop_params = Map.merge(params, %{"filters" => flop_filters})

    case Learning.list_submissions(socket.assigns.current_user, flop_params) do
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
          # <-- Сохраняем в стейт
          |> assign(:block_id, block_id)
          |> assign(:accounts, accounts)
          |> assign(:blocks, blocks)
          |> assign(:has_submissions, submissions != [])
          |> stream(:submissions, submissions, reset: true)

        {:noreply, socket}

      {:error, _meta} ->
        {:noreply, push_patch(socket, to: ~p"/teaching/grading")}
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
        "has_cheats" => params["has_cheats"] || "false",
        # <-- Прокидываем дальше, если он был задан
        "block_id" => socket.assigns.block_id
      }
      |> Enum.reject(fn {_, v} -> v in ["", nil, "false"] end)
      |> Map.new()

    {:noreply, push_patch(socket, to: ~p"/teaching/grading?#{query_params}")}
  end

  @impl true
  def handle_event("reset_filters", _params, socket) do
    # При полном сбросе убиваем и скрытый block_id тоже
    {:noreply, push_patch(socket, to: ~p"/teaching/grading")}
  end

  def handle_event("clear_block_filter", _params, socket) do
    # Сброс ТОЛЬКО скрытого фильтра по блоку
    query_params =
      %{
        "status" => socket.assigns.current_status,
        "login" => socket.assigns.login,
        "cohort_id" => socket.assigns.cohort_id,
        "date_from" => socket.assigns.date_from,
        "date_to" => socket.assigns.date_to,
        "has_cheats" => socket.assigns.has_cheats
      }
      |> Enum.reject(fn {_, v} -> v in ["", nil, "false"] end)
      |> Map.new()

    {:noreply, push_patch(socket, to: ~p"/teaching/grading?#{query_params}")}
  end

  defp build_flop_filters(status, login, cohort_id, date_from, date_to, has_cheats, block_id) do
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
      if block_id != "",
        do: [%{"field" => "block_id", "op" => "==", "value" => block_id} | filters],
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
    <div class="max-w-7xl mx-auto space-y-6 pb-20">
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

      <div class="bg-base-100 border border-base-200 rounded-box p-4 shadow-sm">
        <div class="flex items-center justify-between mb-4">
          <h2 class="font-bold text-sm uppercase tracking-wider opacity-70">{gettext("Filters")}</h2>
          <button
            phx-click="reset_filters"
            type="button"
            class="btn btn-ghost btn-xs text-base-content/60 hover:text-error transition-colors"
          >
            <.icon name="hero-arrow-path" class="size-3 mr-1" />
            {gettext("Reset All")}
          </button>
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
            <div class="flex flex-col justify-end pb-2">
              <.input
                type="checkbox"
                name="has_cheats"
                value="true"
                checked={@has_cheats == "true"}
                label={gettext("Cheaters Only")}
              />
            </div>
          </div>

          <div class="grid grid-cols-1 md:grid-cols-4 gap-4 items-end hidden sm:grid">
            <.input type="date" name="date_from" value={@date_from} label={gettext("From Date")} />
            <.input type="date" name="date_to" value={@date_to} label={gettext("To Date")} />
          </div>
        </.form>
      </div>

      <%!-- Плашка, если активен невидимый фильтр по блоку --%>
      <div
        :if={@block_id != ""}
        class="alert alert-info shadow-sm bg-info/10 text-info border-info/20"
      >
        <.icon name="hero-funnel" class="size-5 shrink-0" />
        <span>
          {gettext("Showing submissions filtered by a specific assignment.")}
          <%= if @blocks[@block_id] do %>
            <strong class="ml-1 uppercase tracking-wider text-xs">
              [{Atom.to_string(@blocks[@block_id].type) |> String.replace("_", " ")}]
            </strong>
          <% end %>
        </span>
        <button phx-click="clear_block_filter" class="btn btn-sm btn-ghost">
          {gettext("Clear Filter")}
        </button>
      </div>

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

      <div :if={@has_submissions}>
        <.table id="submissions" rows={@streams.submissions}>
          <:col :let={{_id, sub}} label={gettext("Student")}>
            <% account = @accounts[sub.account_id] %>
            <div class="font-bold">
              {if account, do: account.login, else: gettext("Unknown")}
            </div>
          </:col>

          <:col :let={{_id, sub}} label={gettext("Assignment")}>
            <span class="badge badge-neutral badge-sm font-medium tracking-wide">
              <%= if @blocks[sub.block_id] do %>
                {Atom.to_string(@blocks[sub.block_id].type) |> String.replace("_", " ")}
              <% else %>
                {gettext("Deleted")}
              <% end %>
            </span>
          </:col>

          <:col :let={{_id, sub}} label={gettext("Status")}>
            <.status_badge status={sub.status} />
          </:col>

          <:col :let={{_id, sub}} label={gettext("Score")}>
            <div class={[
              "font-mono font-bold",
              sub.status == :needs_review && "text-base-content/30",
              sub.status == :rejected && "text-error"
            ]}>
              <%= if sub.status in [:graded, :rejected] do %>
                {sub.score} <span class="text-xs opacity-50 font-normal">/ 100</span>
              <% else %>
                —
              <% end %>
            </div>
          </:col>

          <:col :let={{_id, sub}} label={gettext("Submitted At")}>
            <span class="text-sm font-mono opacity-60">
              {Calendar.strftime(sub.inserted_at, "%d.%m.%Y %H:%M")}
            </span>
          </:col>

          <:action :let={{_id, sub}}>
            <div class="flex justify-end gap-2">
              <%!-- Кнопка-воронка для фильтрации --%>
              <.link
                :if={@block_id == ""}
                patch={
                  ~p"/teaching/grading?status=#{@current_status}&login=#{@login}&cohort_id=#{@cohort_id}&date_from=#{@date_from}&date_to=#{@date_to}&has_cheats=#{@has_cheats}&block_id=#{sub.block_id}"
                }
                class="btn btn-sm btn-ghost btn-square text-base-content/50 hover:text-primary"
                title={gettext("Filter by this assignment")}
              >
                <.icon name="hero-funnel" class="size-4" />
              </.link>

              <%!-- Кнопка проверки/просмотра --%>
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
            </div>
          </:action>
        </.table>
      </div>

      <div class="flex justify-end mt-4">
        <.pagination
          meta={@meta}
          path_fn={
            fn p ->
              ~p"/teaching/grading?page=#{p}&status=#{@current_status}&login=#{@login}&cohort_id=#{@cohort_id}&date_from=#{@date_from}&date_to=#{@date_to}&has_cheats=#{@has_cheats}&block_id=#{@block_id}"
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
      "badge badge-sm font-bold tracking-wide shrink-0",
      @status == :graded && "badge-success badge-soft",
      @status == :needs_review && "badge-warning badge-soft",
      @status == :rejected && "badge-error badge-soft",
      @status in [:pending, :processing] && "badge-neutral badge-soft"
    ]}>
      {Atom.to_string(@status) |> String.replace("_", " ") |> String.capitalize()}
    </span>
    """
  end
end
