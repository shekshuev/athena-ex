defmodule AthenaWeb.FileLive.Index do
  use AthenaWeb, :live_view

  def render(assigns),
    do: ~H"""
    <div class="w-full">
      <.placeholder
        title={gettext("My Files")}
        description={gettext("Your personal storage space.")}
        icon="hero-folder-open"
      />
    </div>
    """
end
