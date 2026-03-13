defmodule AthenaWeb.Hooks.Auth do
  @moduledoc """
  LiveView hooks for authentication and authorization.

  Provides hooks to mount the current user from the session (`:default`)
  and to restrict access to authenticated users only (`:require_authenticated_user`).
  """
  import Phoenix.LiveView
  import Phoenix.Component

  @doc """
  Main entry point for authentication hooks.

  Supports:
  - `:default` - Mounts the current user from session.
  - `:require_authenticated_user` - Redirects to login if user is missing.
  """
  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
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

  def on_mount(:require_authenticated_user, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:cont, socket}
    else
      {:halt, redirect(socket, to: "/auth/login")}
    end
  end
end
