defmodule AthenaWeb.StudioLive.Grading do
  @moduledoc """
  LiveView for managing student submissions and assignments.
  """
  use AthenaWeb, :live_view

  alias Athena.Learning.Submissions
  alias Athena.Identity
  alias Athena.Content

  on_mount {AthenaWeb.Hooks.Permission, "grading.read"}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:accounts, %{})
     |> assign(:blocks, %{})
     |> stream(:submissions, [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    # Читаем статус из URL (или ставим дефолтный)
    status = Map.get(params, "status", "needs_review")

    # Конвертируем красивый параметр в то, что понимает Flop
    flop_params =
      if status != "" do
        Map.put(params, "filters", %{
          "0" => %{"field" => "status", "op" => "==", "value" => status}
        })
      else
        params
      end

    case Submissions.list_submissions(flop_params) do
      {:ok, {submissions, meta}} ->
        account_ids = Enum.map(submissions, & &1.account_id) |> Enum.uniq()
        block_ids = Enum.map(submissions, & &1.block_id) |> Enum.uniq()

        accounts = Identity.get_accounts_map(account_ids)
        blocks = Content.get_blocks_map(block_ids)

        socket =
          socket
          |> assign(:meta, meta)
          |> assign(:current_status, status)
          |> assign(:accounts, Map.merge(socket.assigns.accounts, accounts))
          |> assign(:blocks, Map.merge(socket.assigns.blocks, blocks))
          |> stream(:submissions, submissions, reset: true)

        {:noreply, socket}

      {:error, meta} ->
        {:noreply, assign(socket, meta: meta, current_status: status)}
    end
  end

  @impl true
  def handle_event("update_filter", %{"status" => status}, socket) do
    # Просто пушим новый параметр status в URL
    {:noreply, push_patch(socket, to: ~p"/studio/grading?status=#{status}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex justify-between items-center">
        <div>
          <h1 class="text-2xl font-display font-bold text-base-content">{gettext("Assignments")}</h1>
          <p class="text-base-content/60">
            {gettext("Review and grade student submissions.")}
          </p>
        </div>
      </div>

      <div class="flex gap-4 items-center bg-base-200/50 p-4 rounded-xl border border-base-300">
        <.form for={nil} phx-change="update_filter" class="flex gap-4 w-full">
          <div class="w-64">
            <.input
              type="select"
              name="status"
              value={@current_status}
              label={gettext("Filter by Status")}
              prompt={gettext("All Submissions")}
              options={[
                {gettext("Needs Review"), "needs_review"},
                {gettext("Graded"), "graded"},
                {gettext("Pending (In Progress)"), "pending"}
              ]}
            />
          </div>
        </.form>
      </div>

      <.table id="submissions" rows={@streams.submissions}>
        <:col :let={{_id, sub}} label={gettext("Student")}>
          <div class="font-bold">
            {if acc = @accounts[sub.account_id], do: acc.login, else: "Unknown"}
          </div>
        </:col>
        <:col :let={{_id, sub}} label={gettext("Type")}>
          <span class="text-sm font-mono uppercase tracking-widest opacity-70">
            {if blk = @blocks[sub.block_id], do: blk.type, else: "Unknown"}
          </span>
        </:col>
        <:col :let={{_id, sub}} label={gettext("Status")}>
          <.status_badge status={sub.status} />
        </:col>
        <:col :let={{_id, sub}} label={gettext("Score")}>
          <span class="font-bold">{sub.score} / 100</span>
        </:col>
        <:col :let={{_id, sub}} label={gettext("Submitted At")}>
          <span class="text-sm opacity-60">
            {Calendar.strftime(sub.inserted_at, "%d.%m.%Y %H:%M")}
          </span>
        </:col>
        <:action :let={{_id, sub}}>
          <div class="flex justify-end gap-2">
            <.button
              navigate={~p"/studio/grading/#{sub.id}"}
              class="btn btn-primary btn-sm btn-soft"
            >
              <%= if sub.status == :needs_review do %>
                <.icon name="hero-pencil-square" class="size-4 mr-1" /> {gettext("Grade")}
              <% else %>
                <.icon name="hero-eye" class="size-4 mr-1" /> {gettext("View")}
              <% end %>
            </.button>
          </div>
        </:action>
      </.table>

      <div class="flex justify-end mt-4">
        <.pagination
          meta={@meta}
          path_fn={fn p -> ~p"/studio/grading?page=#{p}&status=#{@current_status}" end}
        />
      </div>
    </div>
    """
  end

  defp status_badge(assigns) do
    ~H"""
    <span class={[
      "badge badge-sm font-bold",
      @status == :graded && "badge-success badge-soft",
      @status == :needs_review && "badge-warning badge-soft",
      @status in [:pending, :processing] && "badge-ghost"
    ]}>
      {Atom.to_string(@status) |> String.replace("_", " ") |> String.capitalize()}
    </span>
    """
  end
end
