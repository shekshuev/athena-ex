defmodule AthenaWeb.TeachingLive.Instructors do
  use AthenaWeb, :live_view

  def render(assigns),
    do: ~H"""
    <div class="w-full">
      <.placeholder
        title={gettext("Instructors")}
        description={gettext("Teaching staff and access control.")}
        icon="hero-users"
      />
    </div>
    """
end
