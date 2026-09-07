defmodule AthenaWeb.TeachingLive.CohortEngagement do
  @moduledoc """
  Live engagement dashboard for teachers.

  Mirrors `AthenaWeb.TeachingLive.CohortAccess`'s navigation (cohort → course
  → tree, same shared `CourseTreeComponents.course_tree_nav/1`), but the
  right-hand panel shows `Athena.Engagement.Metrics` numbers instead of an
  access-override form, with a student filter above it (default: whole
  cohort).

  Metrics recompute is debounced (at most once every `@refresh_debounce_ms`)
  rather than run on every incoming PubSub event - `Athena.Engagement.
  Metrics` scans raw events on demand with no cache, so recomputing per
  event would query the database once per event. Only a single selected
  block subscribes to live updates at all; the section-level summary table
  is computed once per navigation, same as the plan's "не проектируется как
  живой, агрегаты по секции пересчитываются при смене узла" call.
  """
  use AthenaWeb, :live_view

  alias Athena.{Content, Engagement, Learning}
  import AthenaWeb.TeachingLive.CourseTreeComponents, only: [course_tree_nav: 1]

  on_mount {AthenaWeb.Hooks.Permission, "engagement.read"}

  @refresh_debounce_ms 2_000

  @impl true
  def mount(%{"id" => cohort_id, "course_id" => course_id}, _session, socket) do
    user = socket.assigns.current_user

    with {:ok, cohort} <- Learning.get_cohort(user, cohort_id),
         {:ok, course} <- Content.get_course(course_id) do
      tree = Content.get_course_tree(course.id, :all)

      {:ok,
       socket
       |> assign(:cohort, cohort)
       |> assign(:course, course)
       |> assign(:tree, tree)
       |> assign(:students, list_students(cohort.id))
       |> assign(:active_section, nil)
       |> assign(:blocks, [])
       |> assign(:active_block, nil)
       |> assign(:active_account_id, nil)
       |> assign(:metrics, %{})
       |> assign(:subscribed_topic, nil)
       |> assign(:refresh_scheduled, false)
       |> assign(:page_title, gettext("Engagement: %{course}", course: course.title))}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Access denied or course not found."))
         |> push_navigate(to: ~p"/teaching/cohorts/#{cohort_id}")}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    section_id = params["section_id"] || get_first_section_id(socket.assigns.tree)
    account_id = params["account_id"] || nil
    account_id = if account_id in [nil, ""], do: nil, else: account_id

    if section_id do
      {:ok, section} = Content.get_section(section_id)
      blocks = section_id |> Content.list_blocks_by_section(:all) |> Enum.sort_by(& &1.order)

      active_block =
        if params["block_id"], do: Enum.find(blocks, &(&1.id == params["block_id"])), else: nil

      socket =
        socket
        |> assign(:active_section, section)
        |> assign(:blocks, blocks)
        |> assign(:active_block, active_block)
        |> assign(:active_account_id, account_id)
        |> resubscribe(active_block)
        |> refresh_metrics()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("change_student", %{"account_id" => account_id}, socket) do
    account_id = if account_id == "", do: nil, else: account_id
    {:noreply, push_patch(socket, to: build_path(socket, account_id: account_id))}
  end

  @impl true
  def handle_info({:engagement_event, _event}, socket) do
    if socket.assigns.refresh_scheduled do
      {:noreply, socket}
    else
      Process.send_after(self(), :refresh_metrics, @refresh_debounce_ms)
      {:noreply, assign(socket, :refresh_scheduled, true)}
    end
  end

  def handle_info(:refresh_metrics, socket) do
    {:noreply, socket |> assign(:refresh_scheduled, false) |> refresh_metrics()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-[calc(100vh)] lg:h-screen -m-4 sm:-m-6 lg:-m-8 bg-base-100 overflow-hidden">
      <div class="w-80 shrink-0 border-r border-base-200 flex flex-col bg-base-100 overflow-y-auto">
        <div class="p-4 border-b border-base-200 bg-base-50 shrink-0">
          <.link
            navigate={~p"/teaching/cohorts/#{@cohort.id}"}
            class="inline-flex items-center gap-2 text-xs font-bold uppercase tracking-widest text-base-content/50 hover:text-primary transition-colors mb-2"
          >
            <.icon name="hero-arrow-left" class="size-4" />
            {gettext("Back to Cohort")}
          </.link>
          <h2 class="font-black text-lg truncate">{@course.title}</h2>
          <div class="badge badge-primary rounded-sm badge-outline mt-1 font-bold">
            {@cohort.name}
          </div>
        </div>

        <div class="p-4 space-y-1">
          <.course_tree_nav
            sections={@tree}
            active_section_id={if @active_section, do: @active_section.id, else: nil}
            node_path={fn section -> build_path(assigns, section_id: section.id, block_id: nil) end}
            has_badge={fn _section -> false end}
          />
        </div>
      </div>

      <div class="flex-1 overflow-y-auto bg-base-200 p-8 relative">
        <div class="max-w-4xl mx-auto">
          <div class="mb-6 flex items-center justify-between gap-4">
            <h1 class="text-2xl font-black truncate">
              {if @active_block,
                do: @active_block.type,
                else: @active_section && @active_section.title}
            </h1>

            <form phx-change="change_student">
              <select name="account_id" class="select select-bordered select-sm rounded-sm">
                <option value="" selected={is_nil(@active_account_id)}>
                  {gettext("Whole cohort")}
                </option>
                <option
                  :for={student <- @students}
                  value={student && student.id}
                  selected={@active_account_id == (student && student.id)}
                >
                  {student && student.login}
                </option>
              </select>
            </form>

            <.link
              href={~p"/teaching/cohorts/#{@cohort.id}/engagement/#{@course.id}/export.csv"}
              class="btn btn-ghost btn-sm rounded-sm"
            >
              <.icon name="hero-arrow-down-tray" class="size-4" /> {gettext("Export CSV")}
            </.link>
          </div>

          <%= if @active_block do %>
            <.link
              patch={build_path(assigns, block_id: nil)}
              class="btn btn-ghost rounded-sm btn-sm mb-6"
            >
              <.icon name="hero-arrow-left" class="size-4" /> {gettext("Back to Section")}
            </.link>

            <.metrics_table metrics={@metrics} />
          <% else %>
            <div class="space-y-4">
              <div :for={block <- @blocks} class="bg-base-100 border border-base-200 rounded-sm p-4">
                <div class="flex items-center justify-between mb-2">
                  <div class="text-sm font-bold">{block.type}</div>
                  <.link
                    patch={build_path(assigns, block_id: block.id)}
                    class="btn btn-ghost btn-xs text-primary"
                  >
                    {gettext("View metrics")}
                    <.icon name="hero-arrow-right" class="size-4" />
                  </.link>
                </div>
                <.metrics_table metrics={Map.get(@metrics, block.id, %{})} compact={true} />
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp metrics_table(assigns) do
    assigns = assign_new(assigns, :compact, fn -> false end)

    ~H"""
    <div class={["grid gap-2", (@compact && "grid-cols-3") || "grid-cols-2 md:grid-cols-3"]}>
      <div :for={{key, value} <- Enum.sort(@metrics)} class="bg-base-200/50 rounded-sm p-2">
        <div class="text-[10px] uppercase tracking-widest font-black text-base-content/50">
          {humanize_key(key)}
        </div>
        <div class="font-mono text-sm">{format_value(value)}</div>
      </div>
      <div :if={@metrics == %{}} class="text-sm text-base-content/40 col-span-full">
        {gettext("No activity recorded yet.")}
      </div>
    </div>
    """
  end

  defp humanize_key(key), do: key |> to_string() |> String.replace("_", " ")

  defp format_value(nil), do: "—"
  defp format_value(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format_value(value), do: to_string(value)

  defp get_first_section_id([]), do: nil
  defp get_first_section_id([first | _]), do: first.id

  defp list_students(cohort_id) do
    case Learning.list_cohort_memberships(cohort_id, %{limit: 500}) do
      {:ok, {memberships, _meta}} -> Enum.map(memberships, & &1.account)
      _ -> []
    end
  end

  defp build_path(assigns_or_socket, overrides) do
    {cohort, course, current_section, current_block, current_account} =
      path_context(assigns_or_socket)

    section_id = Keyword.get(overrides, :section_id, current_section) || ""
    block_id = Keyword.get(overrides, :block_id, current_block) || ""
    account_id = Keyword.get(overrides, :account_id, current_account) || ""

    ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section_id}&block_id=#{block_id}&account_id=#{account_id}"
  end

  defp path_context(%{assigns: assigns}), do: path_context(assigns)

  defp path_context(assigns) do
    {
      assigns.cohort,
      assigns.course,
      assigns.active_section && assigns.active_section.id,
      assigns.active_block && assigns.active_block.id,
      assigns.active_account_id
    }
  end

  defp resubscribe(socket, nil) do
    unsubscribe_current(socket)
    assign(socket, :subscribed_topic, nil)
  end

  defp resubscribe(socket, block) do
    topic = "engagement:#{socket.assigns.cohort.id}:#{block.id}"

    if socket.assigns.subscribed_topic == topic do
      socket
    else
      unsubscribe_current(socket)
      if connected?(socket), do: Phoenix.PubSub.subscribe(Athena.PubSub, topic)
      assign(socket, :subscribed_topic, topic)
    end
  end

  defp unsubscribe_current(%{assigns: %{subscribed_topic: nil}}), do: :ok

  defp unsubscribe_current(%{assigns: %{subscribed_topic: topic}}),
    do: Phoenix.PubSub.unsubscribe(Athena.PubSub, topic)

  defp refresh_metrics(socket) do
    scope = %{cohort_id: socket.assigns.cohort.id, account_id: socket.assigns.active_account_id}

    metrics =
      cond do
        socket.assigns.active_block ->
          Engagement.get_metrics(
            Map.merge(scope, %{resource_type: :block, resource_id: socket.assigns.active_block.id})
          )

        socket.assigns.active_section ->
          Engagement.get_metrics(
            Map.merge(scope, %{
              resource_type: :section,
              resource_id: socket.assigns.active_section.id
            })
          )

        true ->
          %{}
      end

    assign(socket, :metrics, metrics)
  end
end
