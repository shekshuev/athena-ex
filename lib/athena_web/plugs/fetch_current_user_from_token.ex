defmodule AthenaWeb.Plugs.FetchCurrentUserFromToken do
  @moduledoc """
  Plug for the `:mcp` pipeline. Reads `Authorization: Bearer <token>`,
  resolves it via `Identity.authenticate_token/1`, and assigns
  `@current_user`.

  Unlike `AthenaWeb.Plugs.FetchCurrentUser` (session-based, allows
  `current_user: nil` for anonymous browsing), every MCP request must be
  authenticated — any missing/malformed/unknown/revoked/expired token halts
  the connection with 401.
  """
  import Plug.Conn
  alias Athena.Identity

  def init(opts), do: opts

  def call(conn, _opts) do
    with [header] <- get_req_header(conn, "authorization"),
         "Bearer " <> raw_token <- header,
         {:ok, account} <- Identity.authenticate_token(raw_token) do
      assign(conn, :current_user, account)
    else
      _ -> unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
    |> halt()
  end
end
