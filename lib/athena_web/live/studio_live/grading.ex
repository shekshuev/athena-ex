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
    {:ok,
     socket
     |> assign(:accounts, %{})
     |> assign(:blocks, %{})
     |> assign(:has_submissions, false)
     |> stream(:submissions, [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    status = Map.get(params, "status", "needs_review")

    flop_params =
      if status != "" and status != "all" do
        Map.put(params, "filters", %{
          "0" => %{"field" => "status", "op" => "==", "value" => status}
        })
      else
        params
      end

    case Learning.list_submissions(flop_params) do
      {:ok, {submissions, meta}} ->
        account_ids = Enum.map(submissions, & &1.account_id) |> Enum.uniq()
        block_ids = Enum.map(submissions, & &1.block_id) |> Enum.uniq()

        accounts = Identity.get_accounts_map(account_ids)
        blocks = Content.get_blocks_map(block_ids)

        socket =
          socket
          |> assign(:meta, meta)
          |> assign(:current_status, status)
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
  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto space-y-8">
      <div class="flex flex-col md:flex-row md:items-center justify-between gap-4">
        <div class="flex flex-col gap-2">
          <h1 class="text-3xl font-display font-black text-base-content tracking-tight">
            {gettext("Grading Center")}
          </h1>
          <p class="text-base-content/60 text-lg">
            {gettext("Review and grade student submissions.")}
          </p>
        </div>

        <div class="join border border-base-200 rounded-sm bg-base-100 shadow-sm">
          <.link
            patch={~p"/studio/grading?status=needs_review"}
            class={[
              "join-item btn btn-sm border-0 font-bold rounded-sm",
              @current_status == "needs_review" &&
                "btn-active bg-primary/10 text-primary hover:bg-primary/20",
              @current_status != "needs_review" &&
                "bg-transparent text-base-content/60 hover:bg-base-200"
            ]}
          >
            {gettext("Needs Review")}
          </.link>
          <.link
            patch={~p"/studio/grading?status=graded"}
            class={[
              "join-item btn btn-sm border-0 font-bold rounded-sm",
              @current_status == "graded" &&
                "btn-active bg-primary/10 text-primary hover:bg-primary/20",
              @current_status != "graded" && "bg-transparent text-base-content/60 hover:bg-base-200"
            ]}
          >
            {gettext("Graded")}
          </.link>
          <.link
            patch={~p"/studio/grading?status=all"}
            class={[
              "join-item btn btn-sm border-0 font-bold rounded-sm",
              @current_status == "all" && "btn-active bg-primary/10 text-primary hover:bg-primary/20",
              @current_status != "all" && "bg-transparent text-base-content/60 hover:bg-base-200"
            ]}
          >
            {gettext("All")}
          </.link>
        </div>
      </div>

      <div
        :if={not @has_submissions}
        class="text-center py-24 px-6 mt-8"
      >
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
                  sub.status == :graded && "text-base-content"
                ]}>
                  <%= if sub.status == :graded do %>
                    {sub.score} <span class="text-lg text-base-content/40 font-bold">/ 100</span>
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
                navigate={~p"/studio/grading/#{sub.id}"}
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
          path_fn={fn p -> ~p"/studio/grading?page=#{p}&status=#{@current_status}" end}
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
      @status in [:pending, :processing] && "bg-base-200 text-base-content/70"
    ]}>
      {Atom.to_string(@status) |> String.replace("_", " ") |> String.capitalize()}
    </span>
    """
  end
end
