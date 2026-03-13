defmodule AthenaWeb.StudioLive.Grading do
  use AthenaWeb, :live_view

  def render(assigns),
    do: ~H"""
    <div class="w-full">
      <.placeholder
        title={gettext("Assignments")}
        description={gettext("Grade student submissions and manage homework.")}
        icon="hero-academic-cap"
      />
    </div>
    """
end
