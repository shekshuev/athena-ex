defmodule AthenaWeb.Plugs.FetchCurrentUserFromTokenTest do
  use AthenaWeb.ConnCase, async: true

  alias AthenaWeb.Plugs.FetchCurrentUserFromToken
  alias Athena.Identity.ApiTokens
  import Athena.Factory

  setup do
    account =
      insert(:account,
        role: insert(:role, permissions: ["mcp.tokens.create", "mcp.tokens.delete"])
      )

    {:ok, raw_token, token} = ApiTokens.generate_token(account, %{"label" => "agent"})

    %{account: account, raw_token: raw_token, token: token}
  end

  defp call_with_header(conn, header) do
    conn
    |> then(fn conn ->
      if header, do: put_req_header(conn, "authorization", header), else: conn
    end)
    |> FetchCurrentUserFromToken.call(FetchCurrentUserFromToken.init([]))
  end

  test "assigns current_user for a valid token", %{conn: conn, account: account, raw_token: raw} do
    conn = call_with_header(conn, "Bearer #{raw}")

    assert conn.assigns.current_user.id == account.id
    refute conn.halted
  end

  test "halts with 401 when the header is missing", %{conn: conn} do
    conn = call_with_header(conn, nil)

    assert conn.halted
    assert conn.status == 401
  end

  test "halts with 401 when the header has no Bearer prefix", %{conn: conn, raw_token: raw} do
    conn = call_with_header(conn, raw)

    assert conn.halted
    assert conn.status == 401
  end

  test "halts with 401 for an unknown token", %{conn: conn} do
    conn = call_with_header(conn, "Bearer athn_does-not-exist")

    assert conn.halted
    assert conn.status == 401
  end

  test "halts with 401 for a revoked token", %{
    conn: conn,
    account: account,
    raw_token: raw,
    token: token
  } do
    {:ok, _} = ApiTokens.revoke_token(account, token)
    conn = call_with_header(conn, "Bearer #{raw}")

    assert conn.halted
    assert conn.status == 401
  end
end
