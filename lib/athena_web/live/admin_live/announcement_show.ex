defmodule AthenaWeb.AdminLive.AnnouncementShow do
  use AthenaWeb, :live_view

  import AthenaWeb.AnnouncementComponents, only: [announcement_card: 1]

  alias Athena.{Announcements, Identity, Learning}

  on_mount {AthenaWeb.Hooks.Permission, "announcements.read"}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Announcements.get_for_admin(socket.assigns.current_user, id) do
      nil ->
        {:ok, redirect(socket, to: ~p"/admin/announcements")}

      announcement ->
        owners = Identity.get_accounts_map([announcement.author_id])
        author = Map.get(owners, announcement.author_id)

        {:ok,
         assign(socket,
           page_title: announcement.title,
           announcement: announcement,
           cohorts: Learning.get_cohorts_map(announcement.cohort_ids),
           author_name: if(author, do: Identity.display_name(author), else: "–")
         )}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_container size="standard" class="space-y-6">
      <div class="flex items-center justify-between gap-4">
        <.button id="back-to-announcements" variant="ghost" navigate={~p"/admin/announcements"}>
          <.icon name="hero-arrow-left" class="size-5" />
          {gettext("Back to Announcements")}
        </.button>
        <.button
          :if={
            Identity.can?(@current_user, "announcements.update") &&
              Announcements.can_manage?(@current_user, @announcement)
          }
          id="edit-announcement"
          navigate={~p"/admin/announcements/#{@announcement.id}/edit"}
          variant="primary"
        >
          <.icon name="hero-pencil-square" class="size-5" />
          {gettext("Edit")}
        </.button>
      </div>

      <.announcement_card id="announcement-preview" announcement={@announcement} />

      <dl
        id="announcement-details"
        class="grid gap-6 rounded-lg border border-base-300 bg-base-100 p-5 sm:grid-cols-2"
      >
        <div>
          <dt class="text-sm text-base-content/60">{gettext("Author")}</dt>
          <dd id="announcement-author" class="mt-1 font-medium">{@author_name}</dd>
        </div>
        <div>
          <dt class="text-sm text-base-content/60">{gettext("Audience")}</dt>
          <dd id="announcement-audience" class="mt-1 flex flex-wrap gap-1.5">
            <.badge :if={@announcement.scope == :global} tone="primary">{gettext("Global")}</.badge>
            <.badge :for={id <- @announcement.cohort_ids} tone="info">
              {case Map.get(@cohorts, id) do
                nil -> "–"
                cohort -> cohort.name
              end}
            </.badge>
          </dd>
        </div>
        <div>
          <dt class="text-sm text-base-content/60">{gettext("Created At")}</dt>
          <dd id="announcement-created-at" class="mt-1">
            {TimeZones.format(@announcement.inserted_at, "%d.%m.%Y %H:%M")}
          </dd>
        </div>
        <div>
          <dt class="text-sm text-base-content/60">{gettext("Updated at")}</dt>
          <dd id="announcement-updated-at" class="mt-1">
            {TimeZones.format(@announcement.updated_at, "%d.%m.%Y %H:%M")}
          </dd>
        </div>
        <div>
          <dt class="text-sm text-base-content/60">{gettext("Visible from")}</dt>
          <dd id="announcement-starts-at" class="mt-1">
            {format_date(@announcement.starts_at, gettext("Immediately"))}
          </dd>
        </div>
        <div>
          <dt class="text-sm text-base-content/60">{gettext("Visible until")}</dt>
          <dd id="announcement-ends-at" class="mt-1">
            {format_date(@announcement.ends_at, gettext("Never"))}
          </dd>
        </div>
        <div>
          <dt class="text-sm text-base-content/60">{gettext("Important")}</dt>
          <dd id="announcement-important" class="mt-1">
            {if @announcement.important, do: gettext("Yes"), else: gettext("No")}
          </dd>
        </div>
      </dl>
    </.page_container>
    """
  end

  defp format_date(nil, fallback), do: fallback
  defp format_date(date, _fallback), do: TimeZones.format(date, "%d.%m.%Y %H:%M")
end
