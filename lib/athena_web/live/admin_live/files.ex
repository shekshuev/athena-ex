defmodule AthenaWeb.AdminLive.Files do
  use AthenaWeb, :live_view

  def render(assigns),
    do: ~H"""
    <div class="w-full">
      <.placeholder
        title={gettext("System Files")}
        description={gettext("Global storage monitoring and quotas.")}
        icon="hero-server"
      />
    </div>
    """
end
