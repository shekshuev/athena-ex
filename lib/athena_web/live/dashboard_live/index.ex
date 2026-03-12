defmodule AthenaWeb.DashboardLive.Index do
  @moduledoc """
  Main dashboard landing page.
  """
  use AthenaWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-full">
      <.placeholder
        title={gettext("Dashboard Overview")}
        description={
          gettext(
            "Welcome to your personal learning space. We are working on adding insightful widgets and analytics here."
          )
        }
        icon="hero-squares-2x2"
      />
    </div>
    """
  end
end
