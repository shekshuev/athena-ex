defmodule AthenaWeb.Plugs.Trace do
  @moduledoc """
  The HTTP counterpart to `AthenaWeb.Hooks.Trace`: puts the request's
  identity into the `Logger` metadata so every line emitted while serving it
  - including `Ecto` query logs and anything a context logs - is attributable
  to one request and one user.

  `Plug.RequestId` (already in the endpoint) supplies `request_id`; this adds
  `user` and the route, and logs the request's parameters at `:debug`.

  Placed after `AthenaWeb.Plugs.FetchCurrentUser` in the pipeline, since it
  reads `conn.assigns.current_user`.
  """

  require Logger

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    Logger.metadata(user: user(conn), route: "#{conn.method} #{conn.request_path}")

    Logger.debug(fn ->
      [
        "[trace] request ",
        inspect(%{params: Phoenix.Logger.filter_values(conn.params)},
          limit: 20,
          printable_limit: 400
        )
      ]
    end)

    conn
  end

  defp user(%{assigns: %{current_user: %{login: login}}}), do: login
  defp user(_conn), do: nil
end
