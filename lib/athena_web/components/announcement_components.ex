defmodule AthenaWeb.AnnouncementComponents do
  @moduledoc "Shared announcement cards for the personal feed and administrative preview."

  use AthenaWeb, :html

  attr :id, :string, required: true
  attr :announcement, Athena.Announcements.Announcement, required: true

  def announcement_card(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "bg-base-100 border rounded-lg p-5 space-y-2",
        if(@announcement.important, do: "border-2 border-warning", else: "border-base-300")
      ]}
    >
      <div class="flex items-start justify-between gap-4">
        <h3 class="font-display font-bold text-lg text-base-content flex items-center gap-2">
          <.icon
            :if={@announcement.important}
            name="hero-exclamation-triangle-solid"
            class="size-5 text-warning shrink-0"
          />
          {@announcement.title}
        </h3>
      </div>
      <p class="text-sm text-base-content/50">
        {TimeZones.format(@announcement.inserted_at, "%d.%m.%Y")}
      </p>
      <div
        id={"tiptap-view-#{@announcement.id}"}
        phx-hook="TiptapEditor"
        data-id={@announcement.id}
        data-readonly="true"
        phx-update="ignore"
        data-content={Jason.encode!(@announcement.body)}
        class="prose prose-sm sm:prose-base max-w-none text-base-content/80"
      >
      </div>
    </div>
    """
  end
end
