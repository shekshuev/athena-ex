defmodule AthenaWeb.AdminLive.Users do
  use AthenaWeb, :live_view

  def render(assigns),
    do: ~H"""
    <div class="w-full">
      <.placeholder
        title={gettext("Users")}
        description={gettext("System-wide user management.")}
        icon="hero-users"
      />
    </div>
    """
end
