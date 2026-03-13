defmodule AthenaWeb.StudioLive.Index do
  use AthenaWeb, :live_view

  def render(assigns),
    do: ~H"""
    <div class="w-full">
      <.placeholder
        title={gettext("Studio Overview")}
        description={gettext("Analytics and quick actions for instructors.")}
        icon="hero-presentation-chart-bar"
      />
    </div>
    """
end
