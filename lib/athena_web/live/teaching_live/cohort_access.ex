defmodule AthenaWeb.TeachingLive.CohortAccess do
  @moduledoc """
  Studio-like interface for managing cohort-specific access schedules.
  Allows instructors to visually browse course content and set granular
  time-based overrides for both Sections and specific Blocks.
  """
  use AthenaWeb, :live_view

  alias Athena.Content
  alias Athena.Learning
  import AthenaWeb.BlockComponents
  import AthenaWeb.TeachingLive.CourseTreeComponents, only: [course_tree_nav: 1]

  @impl true
  def mount(%{"id" => cohort_id, "course_id" => course_id}, _session, socket) do
    user = socket.assigns.current_user

    with {:ok, cohort} <- Learning.get_cohort(user, cohort_id),
         {:ok, course} <- Content.get_course(course_id) do
      tree = Content.get_course_tree(course.id, :all)
      overrides = Learning.list_cohort_course_overrides(cohort.id, course.id)

      {:ok,
       socket
       |> assign(:cohort, cohort)
       |> assign(:course, course)
       |> assign(:tree, tree)
       |> assign(:overrides, overrides)
       |> assign(:active_section, nil)
       |> assign(:blocks, [])
       |> assign(:active_block, nil)
       |> assign(:form_visibility, nil)
       |> assign(:page_title, gettext("Access: %{course}", course: course.title))}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Access denied or course not found."))
         |> push_navigate(to: denied_redirect_path(cohort_id))}
    end
  end

  # An ACL failure still routes back to the cohort/team's own detail page
  # (not the list) when we can at least tell which one it is - an unscoped
  # lookup (mirrors `Athena.Learning.Cohorts.get_cohorts_map/1`'s own
  # "unscoped by design" reasoning) is fine here since only the `type`
  # (which side of the split to redirect to) is read, never the record
  # itself.
  defp denied_redirect_path(cohort_id) do
    case Learning.get_cohorts_map([cohort_id]) do
      %{^cohort_id => %{type: :team}} -> ~p"/teaching/teams/#{cohort_id}"
      %{^cohort_id => _cohort} -> ~p"/teaching/cohorts/#{cohort_id}"
      _ -> ~p"/teaching/cohorts"
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    section_id = params["section_id"] || get_first_section_id(socket.assigns.tree)

    if section_id do
      {:ok, section} = Content.get_section(section_id)
      blocks = Content.list_blocks_by_section(section_id, :all) |> Enum.sort_by(& &1.order)

      active_block =
        if params["block_id"], do: Enum.find(blocks, &(&1.id == params["block_id"])), else: nil

      {:noreply,
       socket
       |> assign(:active_section, section)
       |> assign(:blocks, blocks)
       |> assign(:form_visibility, nil)
       |> assign(:active_block, active_block)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event(
        "save_override",
        %{"resource_type" => type, "resource_id" => id} = params,
        socket
      ) do
    attrs = build_override_attrs(params, socket.assigns, type, id)

    case Learning.set_override(
           socket.assigns.current_user,
           socket.assigns.cohort,
           socket.assigns.course,
           attrs
         ) do
      {:ok, _schedule} ->
        overrides = Learning.list_cohort_course_overrides(attrs.cohort_id, attrs.course_id)

        {:noreply,
         socket
         |> assign(:overrides, overrides)
         |> assign(:form_visibility, nil)
         |> put_flash(:info, gettext("Access override saved successfully."))}

      {:error, %Ecto.Changeset{} = changeset} ->
        error_msg =
          changeset.errors |> Keyword.values() |> Enum.map_join(", ", fn {msg, _} -> msg end)

        {:noreply, put_flash(socket, :error, error_msg)}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, gettext("Permission denied."))}
    end
  end

  @impl true
  def handle_event("change_visibility", params, socket) do
    {:noreply, assign(socket, :form_visibility, params["visibility"] || "")}
  end

  @impl true
  def handle_event("clear_override", %{"resource_type" => type, "resource_id" => id}, socket) do
    case Learning.clear_override(
           socket.assigns.current_user,
           socket.assigns.cohort,
           socket.assigns.course,
           type,
           id
         ) do
      {:ok, _} ->
        overrides =
          Learning.list_cohort_course_overrides(
            socket.assigns.cohort.id,
            socket.assigns.course.id
          )

        {:noreply,
         socket
         |> assign(:overrides, overrides)
         |> put_flash(:info, gettext("Override removed. Inheriting global rules."))}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, gettext("Permission denied."))}
    end
  end

  defp build_override_attrs(params, assigns, type, id) do
    params = TimeZones.localize_params(params, ~w(unlock_at lock_at))

    visibility =
      if params["visibility"] in [nil, ""], do: nil, else: String.to_atom(params["visibility"])

    is_restricted = visibility == :restricted

    unlock_at =
      if not is_restricted or params["unlock_at"] in [nil, ""], do: nil, else: params["unlock_at"]

    lock_at =
      if not is_restricted or params["lock_at"] in [nil, ""], do: nil, else: params["lock_at"]

    %{
      cohort_id: assigns.cohort.id,
      course_id: assigns.course.id,
      resource_type: String.to_atom(type),
      resource_id: id,
      unlock_at: unlock_at,
      lock_at: lock_at,
      visibility: visibility
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-[calc(100vh)] lg:h-screen -m-4 sm:-m-6 lg:-m-8 bg-base-100 overflow-hidden">
      <div class="w-80 shrink-0 border-r border-base-200 flex flex-col bg-base-100 overflow-y-auto">
        <div class="p-4 border-b border-base-200 bg-base-50 shrink-0">
          <.link
            navigate={cohort_show_path(@cohort)}
            class="inline-flex items-center gap-2 text-xs font-bold uppercase tracking-widest text-base-content/50 hover:text-primary transition-colors mb-2"
          >
            <.icon name="hero-arrow-left" class="size-4" />
            {if @cohort.type == :team, do: gettext("Back to Team"), else: gettext("Back to Cohort")}
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
            node_path={fn section -> access_path(@cohort, @course.id, section_id: section.id) end}
            has_badge={fn section -> get_override(@overrides, :section, section.id) != nil end}
            badge_title={gettext("Has Override")}
          />
        </div>
      </div>

      <div class="flex-1 overflow-y-auto bg-base-200 p-8 relative">
        <%= if @active_block do %>
          <.page_container size="narrow">
            <.link
              patch={access_path(@cohort, @course.id, section_id: @active_section.id)}
              class="btn btn-ghost rounded-sm btn-sm mb-6"
            >
              <.icon name="hero-arrow-left" class="size-4" /> {gettext("Back to Section")}
            </.link>

            <div class="mb-8 opacity-80 pointer-events-none">
              <.content_block block={@active_block} mode={:edit} />
            </div>

            <.override_form
              resource_type="block"
              form_visibility={@form_visibility}
              resource_id={@active_block.id}
              override={get_override(@overrides, :block, @active_block.id)}
              global_rules={@active_block.access_rules}
            />
          </.page_container>
        <% else %>
          <%= if @active_section do %>
            <.page_container size="narrow">
              <h1 class="text-3xl font-black mb-8">{@active_section.title}</h1>

              <.override_form
                resource_type="section"
                form_visibility={@form_visibility}
                resource_id={@active_section.id}
                override={get_override(@overrides, :section, @active_section.id)}
                global_rules={@active_section.access_rules}
              />

              <div class="mt-12">
                <h3 class="text-xl font-bold mb-6 flex items-center gap-2">
                  <.icon name="hero-cube" class="size-6 text-primary" />
                  {gettext("Blocks in this Section")}
                </h3>

                <div class="space-y-8">
                  <%= for block <- @blocks do %>
                    <% block_override = get_override(@overrides, :block, block.id) %>
                    <div class={"transition-all relative #{if block_override, do: "bg-primary/5 border-l-2 border-primary pl-4 py-2 -ml-4", else: ""}"}>
                      <div class="opacity-80 pointer-events-none max-h-40 overflow-hidden relative p-1 -m-1">
                        <.content_block block={block} mode={:edit} />
                        <div class="absolute bottom-0 left-0 right-0 h-16 bg-linear-to-t from-base-50/80 to-transparent p-1">
                        </div>
                      </div>

                      <div class="mt-2 flex items-center justify-between">
                        <div class="text-sm font-medium">
                          <%= if block_override do %>
                            <span class="text-primary flex items-center gap-1">
                              <.icon name="hero-adjustments-horizontal" class="size-4" />
                              {gettext("Custom rules")}
                            </span>
                          <% else %>
                            <span class="text-base-content/40 flex items-center gap-1">
                              <.icon name="hero-globe-americas" class="size-4" />
                              {gettext("Inheriting global")}
                            </span>
                          <% end %>
                        </div>
                        <.link
                          patch={
                            access_path(@cohort, @course.id,
                              section_id: @active_section.id,
                              block_id: block.id
                            )
                          }
                          class="btn btn-ghost btn-xs text-primary"
                        >
                          <.icon name="hero-cog-8-tooth" class="size-4" />
                          {gettext("Configure")}
                        </.link>
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>
            </.page_container>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  defp override_form(assigns) do
    current_vis =
      assigns.form_visibility ||
        if assigns.override, do: to_string(assigns.override.visibility), else: ""

    assigns = assign(assigns, :current_vis, current_vis)

    ~H"""
    <div class="bg-base-100 border border-base-200 rounded-sm p-6">
      <div class="flex items-start justify-between mb-6">
        <div>
          <h3 class="text-xl font-bold flex items-center gap-2">
            <.icon name="hero-clock" class="size-6 text-primary" />
            {gettext("Access Schedule")}
          </h3>
          <p class="text-sm text-base-content/60 mt-1">
            {gettext("Override the global access rules specifically for this cohort.")}
          </p>
        </div>

        <div :if={@override} class="badge badge-primary rounded-sm gap-1 p-3 font-bold">
          <.icon name="hero-check-badge-solid" class="size-4" /> {gettext("Active Override")}
        </div>
      </div>

      <form phx-submit="save_override" phx-change="change_visibility">
        <input type="hidden" name="resource_type" value={@resource_type} />
        <input type="hidden" name="resource_id" value={@resource_id} />

        <div class="mb-6">
          <label class="block text-xs font-bold text-base-content/70 mb-2">
            {gettext("Visibility Override")}
          </label>
          <div class="flex gap-2">
            <%= for {label, val} <- [{gettext("Inherit"), ""}, {gettext("Visible"), "enrolled"}, {gettext("Restricted"), "restricted"}, {gettext("Hidden"), "hidden"}] do %>
              <label class="cursor-pointer flex-1">
                <input
                  type="radio"
                  name="visibility"
                  value={val}
                  class="peer hidden"
                  checked={@current_vis == val}
                />
                <div class="border rounded-sm p-2 text-center text-xs transition-all bg-base-100 border-base-200 hover:border-primary/50 peer-checked:bg-primary/10 peer-checked:border-primary peer-checked:text-primary peer-checked:font-bold">
                  {label}
                </div>
              </label>
            <% end %>
          </div>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-8">
          <div class="bg-base-200/50 p-4 rounded-sm border border-base-200">
            <h4 class="text-xs uppercase tracking-widest font-black text-base-content/50 mb-4">
              {gettext("Global Rules (Course Builder)")}
            </h4>
            <div class="space-y-4 text-sm">
              <div>
                <span class="block text-base-content/50 font-bold mb-1">
                  {gettext("Unlocks At:")}
                </span>
                <span class="font-mono bg-base-100 px-2 py-1 rounded-sm">
                  {if @global_rules && @global_rules.unlock_at,
                    do: format_dt(@global_rules.unlock_at),
                    else: gettext("Immediately")}
                </span>
              </div>
              <div>
                <span class="block text-base-content/50 font-bold mb-1">{gettext("Locks At:")}</span>
                <span class="font-mono bg-base-100 px-2 py-1 rounded-sm">
                  {if @global_rules && @global_rules.lock_at,
                    do: format_dt(@global_rules.lock_at),
                    else: gettext("Never")}
                </span>
              </div>
            </div>
          </div>

          <div>
            <h4 class="text-xs uppercase tracking-widest font-black text-primary mb-4">
              {gettext("Cohort Exception")}
            </h4>
            <div class="space-y-4">
              <div class={["space-y-4 mb-4", @current_vis != "restricted" && "hidden"]}>
                <.input
                  type="datetime-local"
                  id="override-unlock-at"
                  name="unlock_at"
                  value={@override && @override.unlock_at}
                  label={gettext("Unlock Time")}
                  class="input input-sm rounded-sm w-full font-mono"
                />

                <.input
                  type="datetime-local"
                  id="override-lock-at"
                  name="lock_at"
                  value={@override && @override.lock_at}
                  label={gettext("Lock Time")}
                  class="input input-sm rounded-sm w-full font-mono"
                />
              </div>

              <div class="pt-2 flex gap-2">
                <button type="submit" class="btn btn-primary rounded-sm btn-sm flex-1">
                  {gettext("Save Override")}
                </button>

                <button
                  :if={@override}
                  type="button"
                  phx-click="clear_override"
                  phx-value-resource_type={@resource_type}
                  phx-value-resource_id={@resource_id}
                  class="btn btn-error rounded-sm btn-outline btn-sm"
                  title={gettext("Clear Exception")}
                >
                  <.icon name="hero-trash" class="size-4" />
                </button>
              </div>
            </div>
          </div>
        </div>
      </form>
    </div>
    """
  end

  # `CohortAccess` is mounted from both `/teaching/cohorts/:id/access/...`
  # (academic) and `/teaching/teams/:id/access/...` (team) routes, so every
  # link must stay on whichever side the loaded `@cohort.type` belongs to.
  defp cohort_show_path(%{type: :team, id: id}), do: ~p"/teaching/teams/#{id}"
  defp cohort_show_path(%{id: id}), do: ~p"/teaching/cohorts/#{id}"

  defp access_path(%{type: :team, id: id}, course_id, query),
    do: ~p"/teaching/teams/#{id}/access/#{course_id}?#{query}"

  defp access_path(%{id: id}, course_id, query),
    do: ~p"/teaching/cohorts/#{id}/access/#{course_id}?#{query}"

  defp get_first_section_id([]), do: nil
  defp get_first_section_id([first | _]), do: first.id

  defp get_override(overrides, type, id) do
    Enum.find(overrides, &(&1.resource_type == type and &1.resource_id == id))
  end

  defp format_dt(nil), do: ""
  defp format_dt(dt), do: TimeZones.format(dt, "%d.%m.%Y %H:%M")
end
