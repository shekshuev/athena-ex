defmodule AthenaWeb.CommunityLive.Index do
  use AthenaWeb, :live_view

  def render(assigns),
    do: ~H"""
    <div class="w-full">
      <.placeholder
        title={gettext("Community")}
        description={gettext("Discussions, forums, and peer communication.")}
        icon="hero-chat-bubble-left-right"
      />
    </div>
    """
end
