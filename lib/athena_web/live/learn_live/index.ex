defmodule AthenaWeb.LearnLive.Index do
  use AthenaWeb, :live_view

  def render(assigns),
    do: ~H"""
    <div class="w-full">
      <.placeholder
        title={gettext("My Learning")}
        description={gettext("Your active courses and progress will be here.")}
        icon="hero-book-open"
      />
    </div>
    """
end
