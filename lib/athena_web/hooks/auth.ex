defmodule AthenaWeb.Hooks.Auth do
  @moduledoc """
  LiveView hooks for authentication and authorization.

  Provides hooks to mount the current user from the session (`:default`)
  and to restrict access to authenticated users only (`:require_authenticated_user`).
  """
  import Phoenix.LiveView
  import Phoenix.Component

  @doc """
  Mounts the current user into the LiveView assigns.
  Does not restrict access if the user is not logged in.
  """
  @spec on_mount(:default, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, session, socket) do
    if locale = session["locale"] do
      Gettext.put_locale(AthenaWeb.Gettext, locale)
    end

    case session["account_id"] do
      nil ->
        {:cont, assign(socket, :current_user, nil)}

      account_id ->
        case Athena.Identity.get_account(account_id) do
          {:ok, account} ->
            {:cont, assign(socket, :current_user, account)}

          {:error, :not_found} ->
            {:cont, assign(socket, :current_user, nil)}
        end
    end
  end

  @doc """
  Requires the user to be authenticated.
  Must be used in combination with (and after) the `:default` hook.
  Redirects unauthenticated users to the login page.
  """
  @spec on_mount(:require_authenticated_user, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:require_authenticated_user, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:cont, socket}
    else
      {:halt, redirect(socket, to: "/auth/login")}
    end
  end
end
