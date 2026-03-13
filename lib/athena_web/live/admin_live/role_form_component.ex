defmodule AthenaWeb.AdminLive.RoleFormComponent do
  use AthenaWeb, :live_component

  alias Athena.Identity.{Roles, Role}
  alias Athena.Identity.Definitions

  use Gettext, backend: AthenaWeb.Gettext

  @impl true
  def update(%{role: role} = assigns, socket) do
    changeset = Role.changeset(role, %{})

    grouped_permissions =
      Definitions.permissions()
      |> Enum.group_by(&(String.split(&1, ".") |> List.first()))

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:form, to_form(changeset))
     |> assign(:grouped_permissions, grouped_permissions)
     |> assign(:available_policies, Definitions.policies())}
  end

  @impl true
  def handle_event("validate", %{"role" => role_params}, socket) do
    role_params = normalize_params(role_params)

    changeset =
      socket.assigns.role
      |> Role.changeset(role_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"role" => role_params}, socket) do
    role_params = normalize_params(role_params)
    save_role(socket, socket.assigns.action, role_params)
  end

  defp save_role(socket, :edit, role_params) do
    case Roles.update_role(socket.assigns.role, role_params) do
      {:ok, _role} ->
        notify_parent({:saved, socket.assigns.role})

        {:noreply,
         socket
         |> put_flash(:info, gettext("Role updated successfully"))
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_role(socket, :new, role_params) do
    case Roles.create_role(role_params) do
      {:ok, _role} ->
        notify_parent({:saved, socket.assigns.role})

        {:noreply,
         socket
         |> put_flash(:info, gettext("Role created successfully"))
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})

  defp normalize_params(params) do
    permissions = Map.get(params, "permissions", [])
    policies = Map.get(params, "policies", %{})

    clean_policies =
      policies
      |> Enum.filter(fn {perm, _} -> perm in permissions end)
      |> Enum.into(%{})

    params
    |> Map.put("permissions", permissions)
    |> Map.put("policies", clean_policies)
  end

  @impl true
  def render(assigns) do
    selected_perms =
      Phoenix.HTML.Form.normalize_value("checkbox", assigns.form[:permissions].value) || []

    ~H"""
    <div>
      <.form
        for={@form}
        id="role-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
        class="flex flex-col gap-6 h-full"
      >
        <.input
          field={@form[:name]}
          type="text"
          label={dgettext("permissions", "Role Name")}
          required
          autofocus
        />

        <div class="divider text-xs font-bold uppercase text-base-content/50">
          {dgettext("permissions", "Permissions & Policies")}
        </div>

        <div class="space-y-6 pb-20">
          <div :for={{group, perms} <- @grouped_permissions} class="bg-base-200/50 p-4 rounded-lg">
            <div class="text-xs font-bold text-base-content/50 uppercase mb-3">{group}</div>

            <div class="grid grid-cols-1 gap-3">
              <div :for={perm <- perms} class="flex items-center justify-between p-1 rounded-md">
                <label class="label cursor-pointer justify-start gap-3">
                  <input
                    type="checkbox"
                    name={@form[:permissions].name <> "[]"}
                    value={perm}
                    checked={perm in selected_perms}
                    class="checkbox checkbox-sm checkbox-primary"
                  />
                  <span class="label-text font-bold">
                    {Gettext.dgettext(AthenaWeb.Gettext, "permissions", perm)}
                  </span>
                </label>

                <div :if={perm in selected_perms} class="w-1/2">
                  <select
                    multiple
                    name={"role[policies][#{perm}][]"}
                    class="select select-bordered select-sm w-full font-medium"
                  >
                    <option
                      :for={pol <- @available_policies}
                      value={pol}
                      selected={pol in Map.get(@form[:policies].value || %{}, perm, [])}
                    >
                      {Gettext.dgettext(AthenaWeb.Gettext, "permissions", pol)}
                    </option>
                  </select>
                </div>
              </div>
            </div>
          </div>
        </div>

        <div class="fixed bottom-0 right-0 w-full max-w-md p-6 bg-base-100 border-t border-base-300 flex justify-end gap-3 z-50">
          <.link patch={@patch} class="btn btn-ghost">{gettext("Cancel")}</.link>
          <button type="submit" class="btn btn-primary" phx-disable-with={gettext("Saving...")}>
            {gettext("Save")}
          </button>
        </div>
      </.form>
    </div>
    """
  end
end
