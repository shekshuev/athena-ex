defmodule AthenaWeb.StudioLive.Library do
  use AthenaWeb, :live_view

  def render(assigns),
    do: ~H"""
    <div class="w-full">
      <.placeholder
        title={gettext("Library")}
        description={gettext("Reusable assets, questions, and materials.")}
        icon="hero-bookmark-square"
      />
    </div>
    """
end
