defmodule AthenaWeb.StudioLive.Courses do
  use AthenaWeb, :live_view

  def render(assigns),
    do: ~H"""
    <div class="w-full">
      <.placeholder
        title={gettext("Course Manager")}
        description={gettext("Create and edit your course content.")}
        icon="hero-building-library"
      />
    </div>
    """
end
