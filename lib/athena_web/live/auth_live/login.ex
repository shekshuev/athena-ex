defmodule AthenaWeb.AuthLive.Login do
  @moduledoc """
  LiveView for handling user authentication.

  Renders the login form, provides real-time validation via an embedded schema,
  and handles form submission. Upon successful validation, it triggers a standard
  POST request to complete the login process via `AthenaWeb.SessionController`.
  """

  use AthenaWeb, :live_view

  defmodule LoginForm do
    @moduledoc """
    Embedded schema for validating login credentials before submission.

    Uses `Athena.Identity.Account` regex patterns to ensure validation parity
    between the frontend form and the database schema.
    """

    use Ecto.Schema
    import Ecto.Changeset
    use Gettext, backend: AthenaWeb.Gettext

    @type t :: %__MODULE__{}

    @primary_key false
    embedded_schema do
      field :login, :string
      field :password, :string
    end

    @doc """
    Builds a changeset for the login form based on the `attrs`.
    """
    @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
    def changeset(data \\ %__MODULE__{}, attrs) do
      data
      |> cast(attrs, [:login, :password])
      |> validate_required([:login, :password], message: dgettext_noop("errors", "is required"))
      |> validate_length(:login,
        min: 3,
        max: 50,
        message: dgettext_noop("errors", "should be between 3 and 50 characters")
      )
      |> validate_format(:login, Athena.Identity.login_regex(),
        message:
          dgettext_noop(
            "errors",
            "can only contain letters, numbers, dots, dashes, and underscores"
          )
      )
      |> validate_format(:password, Athena.Identity.password_regex(),
        message:
          dgettext_noop(
            "errors",
            "must be at least 8 characters long and contain at least one uppercase letter, one lowercase letter, one number, and one special character"
          )
      )
    end
  end

  def mount(_params, _session, socket) do
    if socket.assigns[:current_user] do
      {:ok, redirect(socket, to: "/dashboard")}
    else
      changeset = LoginForm.changeset(%{})

      {:ok,
       assign(socket,
         form: to_form(changeset, as: "user"),
         error_message: nil,
         trigger_action: false
       )}
    end
  end

  def handle_event("validate", %{"user" => params}, socket) do
    changeset =
      %LoginForm{}
      |> LoginForm.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset, as: "user"), error_message: nil)}
  end

  def handle_event("submit", %{"user" => params}, socket) do
    changeset =
      %LoginForm{}
      |> LoginForm.changeset(params)
      |> Map.put(:action, :insert)

    if changeset.valid? do
      login = Ecto.Changeset.get_field(changeset, :login)

      case Athena.Identity.get_account_by_login(login) do
        {:ok, _account} ->
          {:noreply, assign(socket, form: to_form(changeset, as: "user"), trigger_action: true)}

        {:error, :not_found} ->
          {:noreply,
           assign(socket,
             form: to_form(changeset, as: "user"),
             error_message: gettext("Invalid login or password")
           )}
      end
    else
      {:noreply, assign(socket, form: to_form(changeset, as: "user"))}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="w-full h-[calc(100vh-100px)] flex flex-col items-center justify-center p-4">
      <div class="card w-full max-w-md bg-base-100 shadow-xl border border-base-300">
        <div class="card-body gap-6">
          <div class="text-center">
            <div class="inline-flex items-center justify-center p-3 bg-primary/10 rounded-full mb-4">
              <.icon name="hero-user" class="w-8 h-8 text-primary" />
            </div>
            <h2 class="text-2xl font-display font-bold uppercase">{gettext("Welcome Back")}</h2>
            <p class="text-base-content/60 text-sm">
              {gettext("Sign in to your account to continue")}
            </p>
          </div>

          <%= if @error_message do %>
            <div role="alert" class="alert alert-error text-sm font-bold shadow-none rounded-md">
              <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
              <span>{@error_message}</span>
            </div>
          <% end %>

          <.form
            id="user"
            for={@form}
            action={~p"/auth/log_in"}
            phx-change="validate"
            phx-submit="submit"
            phx-trigger-action={assigns[:trigger_action]}
            class="flex flex-col gap-4"
          >
            <.input
              field={@form[:login]}
              type="text"
              label={gettext("Login")}
              placeholder={gettext("Enter your login")}
            />

            <.input
              field={@form[:password]}
              type="password"
              label={gettext("Password")}
              placeholder="••••••••"
            />

            <button class="btn btn-primary w-full mt-2">
              {gettext("Log in")}
              <.icon name="hero-arrow-right-end-on-rectangle" class="w-5 h-5" />
            </button>
          </.form>
        </div>
      </div>
    </div>
    """
  end
end
