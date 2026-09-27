defmodule AthenaWeb.Hooks.Timezone do
  @moduledoc """
  Resolves the user's timezone for the LiveView process: the browser-reported
  one from the socket connect params, else the one the `tz` cookie put in the
  session, else the app timezone. See `Athena.TimeZones`.
  """
  import Phoenix.LiveView
  import Phoenix.Component

  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, session, socket) do
    browser_tz = if connected?(socket), do: get_connect_params(socket)["timezone"]
    tz = Athena.TimeZones.put_user_timezone(browser_tz || session["timezone"])

    {:cont, assign(socket, :timezone, tz)}
  end
end
