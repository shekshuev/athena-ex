defmodule AthenaWeb.SessionController do
  @moduledoc """
  Handles user authentication sessions.

  Responsible for creating the session cookie upon successful login
  (verifying both login and password) and clearing it upon logout.
  """

  use AthenaWeb, :controller

  @doc """
  Creates a new session for the user if credentials are valid.
  """
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"user" => %{"login" => login, "password" => password}}) do
    case Athena.Identity.authenticate(login, password) do
      {:ok, account} ->
        conn
        |> put_session(:account_id, account.id)
        |> put_flash(:info, gettext("Successfully logged in!"))
        |> redirect(to: "/dashboard")

      {:error, :invalid_credentials} ->
        conn
        |> put_flash(:error, gettext("Authentication failed."))
        |> redirect(to: "/auth/login")
    end
  end

  @doc """
  Deletes the current user session (logout).
  """
  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, _params) do
    conn
    |> clear_session()
    |> put_flash(:info, gettext("Logged out successfully."))
    |> redirect(to: "/")
  end
end
