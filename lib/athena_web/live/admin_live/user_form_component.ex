defmodule AthenaWeb.AdminLive.UserFormComponent do
  @moduledoc """
  A LiveComponent for creating and editing user accounts and profiles.

  Handles the complex state of bridging two schemas (`Account` and `Profile`)
  through a schemaless `UserForm` changeset, allowing atomic saves and
  passing the updated or created account back to the parent LiveView.
  """
  use AthenaWeb, :live_component

  alias Athena.Identity
  alias AthenaWeb.AdminLive.UserForm

  @doc """
  Initializes the component state.

  Builds the initial `UserForm` changeset from an existing account or an empty struct,
  and fetches available roles and status options for the select dropdowns.
  """
  @spec update(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  @impl true
  def update(%{account: account} = assigns, socket) do
    form_data = if account.id, do: UserForm.from_account(account), else: %UserForm{}
    changeset = UserForm.changeset(form_data, %{})

    role_options =
      Identity.list_all_roles()
      |> Enum.map(&{&1.name, &1.id})

    status_options = [
      {gettext("Active"), :active},
      {gettext("Blocked"), :blocked},
      {gettext("Temporary Blocked"), :temporary_blocked}
    ]

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:form, to_form(changeset))
     |> assign(:role_options, role_options)
     |> assign(:status_options, status_options)}
  end

  @doc """
  Handles UI events.
  """
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_event("validate", %{"user_form" => params}, socket) do
    base_form =
      if socket.assigns.account.id,
        do: UserForm.from_account(socket.assigns.account),
        else: %UserForm{}

    changeset =
      base_form
      |> UserForm.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  @impl true
  def handle_event("save", %{"user_form" => params}, socket) do
    save_user(socket, socket.assigns.action, params)
  end

  defp save_user(socket, :edit, params),
    do:
      socket.assigns.account
      |> UserForm.from_account()
      |> UserForm.changeset(params)
      |> do_save_user(socket, :edit)

  defp save_user(socket, :new, params),
    do:
      %UserForm{}
      |> UserForm.changeset(params)
      |> do_save_user(socket, :new)

  defp do_save_user(%Ecto.Changeset{valid?: true} = changeset, socket, :new) do
    {account_params, profile_params} = UserForm.to_params(changeset)

    case Identity.register_admin_user(account_params, profile_params) do
      {:ok, account} ->
        notify_parent({:saved, account})

        {:noreply,
         socket
         |> put_flash(:info, gettext("User created successfully"))
         |> push_patch(to: socket.assigns.patch)}

      {:error, _step, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp do_save_user(%Ecto.Changeset{valid?: true} = changeset, socket, :edit) do
    {account_params, profile_params} = UserForm.to_params(changeset)

    case Identity.update_admin_user(socket.assigns.account, account_params, profile_params) do
      {:ok, account} ->
        notify_parent({:saved, account})

        {:noreply,
         socket
         |> put_flash(:info, gettext("User updated successfully"))
         |> push_patch(to: socket.assigns.patch)}

      {:error, _step, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp do_save_user(%Ecto.Changeset{valid?: false} = changeset, socket, _),
    do: {:noreply, assign(socket, form: to_form(Map.put(changeset, :action, :insert)))}

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-full flex flex-col">
      <.form
        for={@form}
        id="account-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
        class="flex flex-col h-full"
      >
        <div class="flex-1 overflow-y-auto p-6 space-y-6">
          <div class="divider text-xs font-bold uppercase text-base-content/50">
            {gettext("Account Access")}
          </div>

          <.input field={@form[:login]} type="text" label={gettext("Login")} required />

          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <.input
              field={@form[:password]}
              type="password"
              label={gettext("Password")}
              required={is_nil(@account.id)}
              placeholder={if @account.id, do: gettext("Leave blank to keep current")}
            />
            <.input
              field={@form[:password_confirmation]}
              type="password"
              label={gettext("Repeat Password")}
              required={is_nil(@account.id)}
            />
          </div>

          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <.input
              field={@form[:role_id]}
              type="select"
              label={gettext("Role")}
              options={@role_options}
              required
              prompt={gettext("Select a role...")}
            />
            <.input
              field={@form[:status]}
              type="select"
              label={gettext("Status")}
              options={@status_options}
              required
            />
          </div>

          <div class="divider text-xs font-bold uppercase text-base-content/50">
            {gettext("Personal Information")}
          </div>

          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <.input field={@form[:last_name]} type="text" label={gettext("Last Name")} required />
            <.input field={@form[:first_name]} type="text" label={gettext("First Name")} required />
          </div>

          <.input field={@form[:patronymic]} type="text" label={gettext("Patronymic")} />
          <.input field={@form[:birth_date]} type="date" label={gettext("Birth Date")} />
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
end
