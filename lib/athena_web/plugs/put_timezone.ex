defmodule AthenaWeb.Plugs.PutTimezone do
  @moduledoc """
  Copies the browser timezone (the `tz` cookie written by `app.js`) into the
  session, so the very first, disconnected LiveView render already shows local
  times instead of flashing app-timezone ones until the socket connects.
  """
  import Plug.Conn

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    conn = fetch_cookies(conn)
    tz = conn.cookies["tz"]

    if Athena.TimeZones.valid?(tz) and get_session(conn, "timezone") != tz do
      put_session(conn, "timezone", tz)
    else
      conn
    end
  end
end
