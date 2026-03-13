defmodule AthenaWeb.AdminLive.Settings do
  use AthenaWeb, :live_view

  def render(assigns),
    do: ~H"""
    <div class="w-full">
      <.placeholder
        title={gettext("System Settings")}
        description={gettext("Global configurations and environment toggles.")}
        icon="hero-cog-8-tooth"
      />
    </div>
    """
end
