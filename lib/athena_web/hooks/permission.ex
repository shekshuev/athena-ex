defmodule AthenaWeb.Hooks.Permission do
  @moduledoc """
  A LiveView hook to enforce ACL permissions on route mount.
  """
  import Phoenix.LiveView
  import Phoenix.Component

  use Gettext, backend: AthenaWeb.Gettext

  alias Athena.Identity

  @doc """
  Gates a `live_session`/route on one permission string, or - when a
  cohort/course-backed screen is shared between a "regular" and a "team"/
  "competition" variant of the same entity - on any of a list of
  permission strings (e.g. `["cohorts.read", "teams.read"]`). The list form
  only proves the user can view *some* variant of the screen; the LiveView
  itself must still check the specific permission matching the record it
  actually loads (see `Athena.Learning.Cohorts.can_view_cohort_processes?/2`
  and its `Content.Courses` equivalent).
  """
  def on_mount(permission, _params, _session, socket) do
    user = socket.assigns[:current_user]

    if authorized?(user, permission) do
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

  defp authorized?(user, permissions) when is_list(permissions),
    do: Identity.can_any?(user, permissions)

  defp authorized?(user, permission), do: Identity.can?(user, permission)
end
