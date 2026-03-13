defmodule AthenaWeb.TeachingLive.Cohorts do
  use AthenaWeb, :live_view

  def render(assigns),
    do: ~H"""
    <div class="w-full">
      <.placeholder
        title={gettext("Cohorts")}
        description={gettext("Manage student groups and enrollment.")}
        icon="hero-user-group"
      />
    </div>
    """
end
