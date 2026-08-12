defmodule AthenaWeb.Plugs.FetchCurrentUserTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias AthenaWeb.Plugs.FetchCurrentUser

  @session_options Plug.Session.init(
    store: :cookie,
    key: "_app",
    signing_salt: "secret_salt"
  )

  test "clears :account_id from session when account does not exist" do
    non_existent_id = -1

    conn =
      build_conn()
      |> Plug.Session.call(@session_options)
      |> fetch_session()
      |> put_session(:account_id, non_existent_id)

    conn = FetchCurrentUser.call(conn, FetchCurrentUser.init([]))

    assert conn.assigns.current_user == nil

    assert get_session(conn, :account_id) == nil
  end
end
