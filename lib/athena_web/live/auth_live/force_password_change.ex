defmodule AthenaWeb.AuthLive.ForcePasswordChange do
  @moduledoc """
  LiveView for forcing users to change their password upon first login or
  when flagged by an administrator.
  """

  use AthenaWeb, :live_view

  defmodule PasswordForm do
    @moduledoc """
    Embedded schema for validating the new password and its confirmation.
    """
    use Ecto.Schema
    import Ecto.Changeset
    use Gettext, backend: AthenaWeb.Gettext
    alias Athena.Identity

    @primary_key false
    embedded_schema do
      field :password, :string
      field :password_confirmation, :string
    end

    @doc """
    Builds a changeset for the password change form.
    """
    def changeset(data \\ %__MODULE__{}, attrs) do
      data
      |> cast(attrs, [:password, :password_confirmation])
      |> validate_required([:password, :password_confirmation],
        message: dgettext_noop("errors", "is required")
      )
      |> validate_format(:password, Identity.password_regex(),
        message:
          dgettext_noop(
            "errors",
            "must be at least 8 characters long and contain at least one uppercase letter, one lowercase letter, one number, and one special character"
          )
      )
      |> validate_confirmation(:password,
        message: dgettext_noop("errors", "does not match password")
      )
    end
  end

  def mount(
        _params,
        _session,
        %{assigns: %{current_user: %{must_change_password: false}}} = socket
      ),
      do: {:ok, redirect(socket, to: "/dashboard")}

  def mount(
        _params,
        _session,
        %{assigns: %{current_user: %{must_change_password: true}}} = socket
      ) do
    changeset = PasswordForm.changeset(%{})
    {:ok, assign(socket, form: to_form(changeset, as: "user"))}
  end

  def handle_event("validate", %{"user" => params}, socket) do
    changeset =
      %PasswordForm{}
      |> PasswordForm.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset, as: "user"))}
  end

  def handle_event("save", %{"user" => params}, socket) do
    changeset =
      %PasswordForm{}
      |> PasswordForm.changeset(params)
      |> Map.put(:action, :insert)

    if changeset.valid? do
      password = Ecto.Changeset.get_field(changeset, :password)
      user = socket.assigns.current_user

      case Identity.force_change_password(user, %{password: password}) do
        {:ok, _updated_user} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Password successfully updated. Welcome!"))
           |> push_navigate(to: "/dashboard")}

        {:error, _db_changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, gettext("An error occurred while updating the password."))}
      end
    else
      {:noreply, assign(socket, form: to_form(changeset, as: "user"))}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="flex-1 flex flex-col items-center justify-center p-4 sm:p-6">
      <div class="card w-full max-w-md bg-base-100 border border-base-300 rounded-sm">
        <div class="card-body gap-4 p-6 sm:p-8">
          <div class="text-center">
            <div class="inline-flex items-center justify-center w-14 h-14 bg-warning/10 border border-warning/20 rounded-sm mb-4">
              <.icon name="hero-shield-exclamation" class="size-7 text-warning" />
            </div>
            <h2 class="text-2xl font-display font-bold uppercase">
              {gettext("Security Update Required")}
            </h2>
            <p class="text-base-content/60 text-sm mt-2">
              {gettext("Please set a new secure password to continue accessing your account.")}
            </p>
          </div>

          <.form
            id="password_change_form"
            for={@form}
            phx-change="validate"
            phx-submit="save"
            class="flex flex-col gap-2"
          >
            <.input
              field={@form[:password]}
              type="password"
              label={gettext("New Password")}
              placeholder="••••••••"
              required
            />

            <.input
              field={@form[:password_confirmation]}
              type="password"
              label={gettext("Confirm New Password")}
              placeholder="••••••••"
              required
            />

            <button class="btn btn-warning w-full mt-4 phx-submit-loading:opacity-70">
              {gettext("Save and continue")}
              <.icon name="hero-arrow-right" class="size-5 ml-2" />
            </button>
          </.form>
        </div>
      </div>
    </div>
    """
  end
end
