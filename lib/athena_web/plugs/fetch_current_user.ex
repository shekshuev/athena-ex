defmodule AthenaWeb.Plugs.FetchCurrentUser do
  @moduledoc """
  Plug for reading user_id from the session and passing @current_user to conn.assigns.
  Used in the :browser pipeline for regular controllers (landing pages, static content, etc.).
  """
  import Plug.Conn
  alias Athena.Identity

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, :account_id) do
      nil ->
        assign(conn, :current_user, nil)

      user_id ->
        case Identity.get_account(user_id) do
          {:ok, account} ->
            assign(conn, :current_user, account)

          _ ->
            conn
            |> delete_session(:user_id)
            |> assign(:current_user, nil)
        end
    end
  end
end
