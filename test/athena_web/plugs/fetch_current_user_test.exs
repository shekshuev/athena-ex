defmodule AthenaWeb.Plugs.FetchCurrentUserTest do
  use AthenaWeb.ConnCase, async: true

  import Plug.Conn

  alias AthenaWeb.Plugs.FetchCurrentUser

  @session_options Plug.Session.init(
                     store: :cookie,
                     key: "_app",
                     signing_salt: "secret_salt"
                   )

  test "clears :account_id from session when account does not exist", %{conn: conn} do
    non_existent_id = Ecto.UUID.generate()

    conn =
      conn
      |> Plug.Session.call(@session_options)
      |> fetch_session()
      |> put_session(:account_id, non_existent_id)

    conn = FetchCurrentUser.call(conn, FetchCurrentUser.init([]))

    assert conn.assigns.current_user == nil
    assert get_session(conn, :account_id) == nil
  end
end
