defmodule AthenaWeb.Hooks.ACL do
  @moduledoc """
  LiveView on_mount hook to enforce permissions and extract policies.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  use Gettext, backend: AthenaWeb.Gettext

  def on_mount({:require_permission, required_perm}, _params, _session, socket) do
    user = socket.assigns[:current_user]

    if user do
      role = user.role
      permissions = role.permissions || []

      if "admin" in permissions or required_perm in permissions do
        applied_policies = Map.get(role.policies, required_perm, [])
        {:cont, assign(socket, :applied_policies, applied_policies)}
      else
        error_msg = gettext("Missing permission: %{permission}", permission: required_perm)

        socket =
          socket
          |> put_flash(:error, error_msg)
          |> redirect(to: "/")

        {:halt, socket}
      end
    else
      {:halt, redirect(socket, to: "/login")}
    end
  end
end
