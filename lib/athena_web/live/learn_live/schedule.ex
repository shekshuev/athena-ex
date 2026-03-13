defmodule AthenaWeb.LearnLive.Schedule do
  use AthenaWeb, :live_view

  def render(assigns),
    do: ~H"""
    <div class="w-full">
      <.placeholder
        title={gettext("Schedule")}
        description={gettext("Upcoming classes, deadlines, and events.")}
        icon="hero-calendar"
      />
    </div>
    """
end
