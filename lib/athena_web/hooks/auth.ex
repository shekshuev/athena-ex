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
    default_locale = Application.get_env(:athena, AthenaWeb.Gettext)[:default_locale] || "ru"

    locale = session["locale"] || default_locale
    Gettext.put_locale(AthenaWeb.Gettext, locale)

    case session["account_id"] do
      nil ->
        {:cont, assign(socket, :current_user, nil)}

      account_id ->
        case Athena.Identity.get_account(account_id, preload: [:role]) do
          {:ok, %{status: :active} = account} ->
            maybe_connect_auth_events(socket, account)

            socket =
              socket
              |> assign(:current_user, account)
              |> attach_hook(:current_user_reloader, :handle_info, &reload_user_on_event/2)

            {:cont, socket}

          _ ->
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

  def on_mount(:ensure_password_changed, _params, _session, socket) do
    if socket.assigns.current_user && socket.assigns.current_user.must_change_password do
      {:halt, Phoenix.LiveView.redirect(socket, to: "/force-password-change")}
    else
      {:cont, socket}
    end
  end

  defp maybe_connect_auth_events(socket, account) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Athena.PubSub, "role_updates:#{account.role_id}")
      Phoenix.PubSub.subscribe(Athena.PubSub, "account_updates:#{account.id}")
    end
  end

  defp reload_user_on_event(event, socket) when event in [:role_updated, :account_updated] do
    case Athena.Identity.get_account(socket.assigns.current_user.id, preload: [:role]) do
      {:ok, %{status: :active} = fresh_account} ->
        socket = assign(socket, :current_user, fresh_account)

        required_perm = socket.assigns[:required_permission]

        if required_perm && not Athena.Identity.can?(fresh_account, required_perm) do
          {:halt,
           socket
           |> put_flash(
             :error,
             Gettext.dgettext(
               AthenaWeb.Gettext,
               "errors",
               "You don't have permission to access this page."
             )
           )
           |> redirect(to: "/dashboard")}
        else
          {:halt, socket}
        end

      {:ok, _} ->
        {:halt, push_event(socket, "force_logout", %{})}

      {:error, :not_found} ->
        {:halt, push_event(socket, "force_logout", %{})}
    end
  end

  defp reload_user_on_event(_message, socket), do: {:cont, socket}
end
