defmodule AthenaWeb.AdminLive.Roles do
  use AthenaWeb, :live_view

  def render(assigns),
    do: ~H"""
    <div class="w-full">
      <.placeholder
        title={gettext("Roles & Policies")}
        description={gettext("RBAC management and permission scopes.")}
        icon="hero-shield-check"
      />
    </div>
    """
end
