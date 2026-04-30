defmodule AthenaWeb.AdminLive.RoleFormComponent do
  @moduledoc """
  A LiveComponent for creating and editing roles.

  Handles the complex state of permissions and policies selection,
  including grouping permissions, normalizing array inputs, and safely
  passing the updated or created role back to the parent LiveView.
  """
  use AthenaWeb, :live_component

  alias Athena.Identity.{Roles, Role}
  alias Athena.Identity.Definitions

  use Gettext, backend: AthenaWeb.Gettext

  @doc """
  Initializes the component state.

  Builds the initial changeset, groups available permissions, and translates
  policy options for the select inputs.
  """
  @spec update(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  @impl true
  def update(%{role: role} = assigns, socket) do
    changeset = Role.changeset(role, %{})

    grouped_permissions =
      Definitions.permissions()
      |> Enum.group_by(fn perm ->
        parts = String.split(perm, ".")
        if length(parts) == 1, do: "system", else: hd(parts)
      end)

    policy_options =
      Definitions.policies()
      |> Enum.map(&{Gettext.dgettext(AthenaWeb.Gettext, "permissions", &1), &1})

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:form, to_form(changeset))
     |> assign(:grouped_permissions, grouped_permissions)
     |> assign(:policy_options, policy_options)}
  end

  @doc """
  Handles UI events.
  """
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
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
      {:ok, role} ->
        notify_parent({:saved, role})

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
      {:ok, role} ->
        notify_parent({:saved, role})

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
    permissions =
      params
      |> Map.get("permissions", [])
      |> List.wrap()
      |> Enum.reject(&(&1 == ""))

    raw_policies = Map.get(params, "policies", %{})

    clean_policies =
      raw_policies
      |> Enum.map(fn {perm, pols} ->
        {perm, List.wrap(pols) |> Enum.reject(&(&1 == ""))}
      end)
      |> Enum.filter(fn {perm, pols} -> perm in permissions and pols != [] end)
      |> Enum.into(%{})

    params
    |> Map.put("permissions", permissions)
    |> Map.put("policies", clean_policies)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-full flex flex-col">
      <.form
        for={@form}
        id="role-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
        class="flex flex-col h-full"
      >
        <div class="flex-1 overflow-y-auto p-6 space-y-6">
          <.input
            field={@form[:name]}
            type="text"
            label={gettext("Role Name")}
            required
            autofocus
          />

          <div class="divider text-xs font-bold uppercase text-base-content/50">
            {gettext("Permissions & Policies")}
          </div>

          <div class="space-y-6">
            <input type="hidden" name="role[permissions][]" value="" />

            <div :for={{group, perms} <- @grouped_permissions} class="bg-base-200/50 p-4 rounded-lg">
              <div class="text-xs font-bold text-base-content/50 uppercase mb-3">
                {Gettext.dgettext(AthenaWeb.Gettext, "permissions", group)}
              </div>

              <div class="grid grid-cols-1 gap-3">
                <div :for={perm <- perms} class="flex items-center justify-between p-1 rounded-md">
                  <label class="label cursor-pointer justify-start gap-3">
                    <input
                      type="checkbox"
                      id={"checkbox-#{perm}"}
                      name="role[permissions][]"
                      value={perm}
                      checked={perm in (@form[:permissions].value || [])}
                      class="checkbox checkbox-sm checkbox-primary"
                    />
                    <span class="label-text font-bold">
                      {perm_label(perm)}
                    </span>
                  </label>

                  <div
                    :if={perm in (@form[:permissions].value || []) and supports_policies?(perm)}
                    class="w-full sm:w-1/2 flex items-center justify-end"
                  >
                    <input type="hidden" name={"role[policies][#{perm}][]"} value="" />

                    <div class="flex flex-wrap justify-end gap-2">
                      <label
                        :for={{pol_label, pol_value} <- @policy_options}
                        class="cursor-pointer inline-flex items-center gap-1.5 bg-base-100 border border-base-300 px-2 py-1 rounded-md hover:border-secondary transition-colors"
                      >
                        <input
                          type="checkbox"
                          name={"role[policies][#{perm}][]"}
                          value={pol_value}
                          checked={pol_value in Map.get(@form[:policies].value || %{}, perm, [])}
                          class="checkbox checkbox-xs checkbox-secondary rounded-sm"
                        />
                        <span class="text-[10px] font-bold uppercase text-base-content/80">
                          {pol_label}
                        </span>
                      </label>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>

        <div class="shrink-0 p-6 border-t border-base-200 bg-base-100 flex justify-end gap-3">
          <.link patch={@patch} class="btn btn-ghost">{gettext("Cancel")}</.link>
          <button type="submit" class="btn btn-primary" phx-disable-with={gettext("Saving...")}>
            {gettext("Save")}
          </button>
        </div>
      </.form>
    </div>
    """
  end

  defp perm_label(perm) do
    action = perm |> String.split(".") |> List.last()
    Gettext.dgettext(AthenaWeb.Gettext, "permissions", action)
  end

  @doc false
  defp supports_policies?("instructors.read"), do: false

  defp supports_policies?("enrollments.create"), do: true

  defp supports_policies?("admin"), do: false

  defp supports_policies?(perm) do
    parts = String.split(perm, ".")

    if List.last(parts) == "create" do
      false
    else
      List.first(parts) in ~w(users courses library grading enrollments instructors cohorts files)
    end
  end
end
