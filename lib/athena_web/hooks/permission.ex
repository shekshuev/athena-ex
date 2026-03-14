defmodule AthenaWeb.Hooks.Permission do
  @moduledoc """
  A LiveView hook to enforce ACL permissions on route mount.
  """
  import Phoenix.LiveView
  import Phoenix.Component

  use Gettext, backend: AthenaWeb.Gettext

  alias Athena.Identity

  def on_mount(permission, _params, _session, socket) do
    user = socket.assigns[:current_user]

    if Identity.can?(user, permission) do
      {:cont, assign(socket, :required_permission, permission)}
    else
      {:halt,
       socket
       |> put_flash(
         :error,
         dgettext(
           "errors",
           "You don't have permission to access this page."
         )
       )
       |> redirect(to: "/dashboard")}
    end
  end
end
