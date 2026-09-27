defmodule AthenaWeb.AdminLive.AnnouncementForm do
  @moduledoc """
  Full-page create/edit form for announcements.

  A rich-text (TipTap) body doesn't fit comfortably in the narrow
  `<.slide_over>` used by other admin CRUD pages (Users/Roles/Files) — this
  is a standalone page instead, mirroring the layout convention already
  used by `StudioLive.LibraryEditor` (back-link + title header, wide
  `<.page_container>`) rather than `AdminLive.Announcements`'s own list
  page.

  The "Global" scope option is only offered to accounts holding the
  "admin" bypass permission; everyone else may only search/pick from the
  cohorts they instruct (`Athena.Learning.search_postable_cohorts/2`, an
  autocomplete search box mirroring `TeachingLive.MembershipFormComponent`'s
  "search student by login" pattern — a school can have many cohorts, so a
  plain dropdown doesn't scale). Authorization is ultimately enforced by
  `Athena.Announcements`, not by this LiveView — hiding options here is a
  UX convenience, not a security boundary.
  """
  use AthenaWeb, :live_view

  import AthenaWeb.BlockComponents, only: [tiptap_toolbar: 1]

  alias Athena.{Announcements, Identity, Learning}
  alias Athena.Announcements.Announcement

  on_mount {AthenaWeb.Hooks.Permission, ["announcements.create", "announcements.update"]}

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(cohort_search_query: "", cohort_search_results: [], selected_cohort: nil)
     |> load_announcement(socket.assigns.live_action, params)}
  end

  defp load_announcement(socket, :new, _params) do
    current_user = socket.assigns.current_user

    if Identity.can?(current_user, "announcements.create") do
      assign_form(socket, %Announcement{body: %{}}, gettext("Create Announcement"))
    else
      redirect_forbidden(socket, gettext("You don't have permission to create announcements."))
    end
  end

  defp load_announcement(socket, :edit, %{"id" => id}) do
    current_user = socket.assigns.current_user

    case Announcements.get_announcement(id) do
      %Announcement{} = announcement ->
        if Identity.can?(current_user, "announcements.update") and
             Announcements.can_manage?(current_user, announcement) do
          socket
          |> assign(:selected_cohort, preload_selected_cohort(announcement))
          |> assign_form(announcement, gettext("Edit Announcement"))
        else
          redirect_forbidden(
            socket,
            gettext("You don't have permission to edit this announcement.")
          )
        end

      nil ->
        redirect(socket, to: ~p"/admin/announcements")
    end
  end

  defp preload_selected_cohort(%Announcement{scope: :cohort, cohort_id: cohort_id})
       when not is_nil(cohort_id) do
    case Learning.get_cohorts_map([cohort_id]) do
      %{^cohort_id => cohort} -> %{id: cohort.id, name: cohort.name, type: cohort.type}
      _ -> nil
    end
  end

  defp preload_selected_cohort(_announcement), do: nil

  defp assign_form(socket, %Announcement{} = announcement, page_title) do
    changeset = Announcement.changeset(announcement, %{})

    socket
    |> assign(:announcement, announcement)
    |> assign(:page_title, page_title)
    |> assign(:show_global_option?, Identity.can?(socket.assigns.current_user, "admin"))
    |> assign(:form, to_form(changeset))
  end

  defp redirect_forbidden(socket, message) do
    socket
    |> put_flash(:error, message)
    |> redirect(to: ~p"/admin/announcements")
  end

  @impl true
  def handle_event("validate", %{"announcement" => params}, socket) do
    params = TimeZones.localize_params(params, ~w(starts_at ends_at))

    changeset =
      socket.assigns.announcement
      |> Announcement.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("search_cohorts", %{"value" => query}, socket) do
    if String.length(query) >= 2 do
      cohorts = Learning.search_postable_cohorts(socket.assigns.current_user, query)
      {:noreply, assign(socket, cohort_search_query: query, cohort_search_results: cohorts)}
    else
      {:noreply, assign(socket, cohort_search_query: query, cohort_search_results: [])}
    end
  end

  def handle_event("select_cohort", %{"id" => id, "name" => name, "type" => type}, socket) do
    {:noreply,
     socket
     |> assign(:selected_cohort, %{id: id, name: name, type: String.to_existing_atom(type)})
     |> assign(cohort_search_query: "", cohort_search_results: [])}
  end

  def handle_event("clear_cohort", _params, socket) do
    {:noreply, assign(socket, :selected_cohort, nil)}
  end

  def handle_event("save", %{"announcement" => params}, socket) do
    params = TimeZones.localize_params(params, ~w(starts_at ends_at))
    cohort_id = socket.assigns.selected_cohort && socket.assigns.selected_cohort.id
    params = Map.put(params, "cohort_id", cohort_id)

    save_announcement(socket, socket.assigns.live_action, params)
  end

  defp save_announcement(socket, :new, params) do
    case Announcements.create_announcement(socket.assigns.current_user, params) do
      {:ok, _announcement} ->
        {:noreply,
         socket
         |> put_flash(:success, gettext("Announcement created successfully"))
         |> redirect(to: ~p"/admin/announcements")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}

      {:error, :forbidden} ->
        {:noreply,
         redirect_forbidden(socket, gettext("You don't have permission to post to this cohort."))}
    end
  end

  defp save_announcement(socket, :edit, params) do
    case Announcements.update_announcement(
           socket.assigns.current_user,
           socket.assigns.announcement,
           params
         ) do
      {:ok, _announcement} ->
        {:noreply,
         socket
         |> put_flash(:success, gettext("Announcement updated successfully"))
         |> redirect(to: ~p"/admin/announcements")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}

      {:error, :forbidden} ->
        {:noreply,
         redirect_forbidden(socket, gettext("You don't have permission to post to this cohort."))}
    end
  end

  defp scope_options(show_global_option?) do
    cohort_option = {gettext("Cohort"), "cohort"}

    if show_global_option?,
      do: [{gettext("Global"), "global"}, cohort_option],
      else: [cohort_option]
  end

  defp cohort_type_label(:team), do: gettext("Team")
  defp cohort_type_label(_academic), do: gettext("Cohort")

  @impl true
  def render(assigns) do
    ~H"""
    <.page_container size="wide" class="pb-20 pt-4">
      <div class="flex items-center gap-4 mb-8 border-b border-base-300 pb-6">
        <.link
          navigate={~p"/admin/announcements"}
          class="btn btn-ghost btn-sm btn-square rounded-sm hover:bg-base-200"
          title={gettext("Back to Announcements")}
        >
          <.icon name="hero-arrow-left" class="size-5" />
        </.link>
        <h1 class="text-2xl font-black font-display tracking-tight">{@page_title}</h1>
      </div>

      <.form for={@form} id="announcement-form" phx-change="validate" phx-submit="save">
        <div class="max-w-3xl space-y-6">
          <.input field={@form[:title]} type="text" label={gettext("Title")} required autofocus />

          <fieldset class="fieldset mb-2 w-full">
            <label class="label">
              <span class="label-text font-bold">{gettext("Body")}</span>
            </label>

            <input
              type="hidden"
              name="announcement[body]"
              id="announcement-body-input"
              value={Jason.encode!(@form[:body].value || %{})}
            />

            <div class="editor-wrapper group/tiptap relative outline-none" tabindex="-1">
              <.tiptap_toolbar mode={:edit} />
              <div
                id={"tiptap-announcement-#{@announcement.id || "new"}"}
                phx-hook="TiptapEditor"
                data-id="announcement-body"
                data-input-id="announcement-body-input"
                data-readonly="false"
                phx-update="ignore"
                data-content={Jason.encode!(@form[:body].value || %{})}
                class="prose prose-base max-w-none min-h-75 border border-base-300 rounded-sm p-4 focus:outline-none"
              >
              </div>
            </div>
          </fieldset>

          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <.input
              field={@form[:scope]}
              type="select"
              label={gettext("Audience")}
              options={scope_options(@show_global_option?)}
              prompt={gettext("Select audience")}
            />

            <div :if={to_string(@form[:scope].value) == "cohort"} class="form-control relative">
              <label class="label">
                <span class="label-text font-bold">{gettext("Cohort or team")}</span>
              </label>

              <input
                type="hidden"
                name="announcement[cohort_id]"
                value={@selected_cohort && @selected_cohort.id}
              />

              <div
                :if={@selected_cohort}
                class="flex items-center justify-between p-3 border border-success/30 bg-success/10 rounded-sm"
              >
                <div class="flex items-center gap-2">
                  <.icon name="hero-check-circle" class="size-5 text-success" />
                  <span class="font-bold">{@selected_cohort.name}</span>
                  <.badge tone="neutral">{cohort_type_label(@selected_cohort.type)}</.badge>
                </div>
                <.icon_button
                  type="button"
                  phx-click="clear_cohort"
                  icon="hero-x-mark"
                  label={gettext("Clear")}
                  variant="danger"
                />
              </div>

              <div :if={!@selected_cohort} class="relative">
                <input
                  type="text"
                  value={@cohort_search_query}
                  phx-keyup="search_cohorts"
                  class="input input-bordered w-full"
                  placeholder={gettext("Search by cohort or team name...")}
                  autocomplete="off"
                  phx-debounce="300"
                />
                <.icon
                  name="hero-magnifying-glass"
                  class="absolute right-3 top-3.5 size-5 text-base-content/40"
                />

                <ul
                  :if={@cohort_search_results != []}
                  class="absolute top-full mt-1 left-0 w-full bg-base-100 border border-base-200 rounded-lg z-50 max-h-60 overflow-y-auto shadow-lg"
                >
                  <li
                    :for={cohort <- @cohort_search_results}
                    phx-click="select_cohort"
                    phx-value-id={cohort.id}
                    phx-value-name={cohort.name}
                    phx-value-type={cohort.type}
                    class="p-3 hover:bg-primary/10 hover:text-primary cursor-pointer border-b border-base-100 last:border-0 transition-colors flex items-center justify-between gap-2"
                  >
                    <span class="font-medium">{cohort.name}</span>
                    <.badge tone="neutral">{cohort_type_label(cohort.type)}</.badge>
                  </li>
                </ul>
              </div>
            </div>
          </div>

          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <.input
              field={@form[:starts_at]}
              type="datetime-local"
              label={gettext("Visible from (optional)")}
            />
            <.input
              field={@form[:ends_at]}
              type="datetime-local"
              label={gettext("Visible until (optional)")}
            />
          </div>

          <.input field={@form[:important]} type="checkbox" label={gettext("Mark as important")} />

          <div class="flex justify-end gap-3 pt-4 border-t border-base-200">
            <.button variant="ghost" navigate={~p"/admin/announcements"}>
              {gettext("Cancel")}
            </.button>
            <.button type="submit" variant="primary" phx-disable-with={gettext("Saving...")}>
              {gettext("Save")}
            </.button>
          </div>
        </div>
      </.form>
    </.page_container>
    """
  end
end
