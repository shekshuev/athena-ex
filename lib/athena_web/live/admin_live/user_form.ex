defmodule AthenaWeb.AdminLive.UserForm do
  @moduledoc """
  A form object that bridges Account and Profile data for the admin UI.

  This schemaless changeset allows us to handle fields from both tables 
  in a single flat form, making LiveView templates much cleaner.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Athena.{Identity, Repo}
  alias Athena.Identity.Account

  use Gettext, backend: AthenaWeb.Gettext

  @primary_key false
  embedded_schema do
    field :id, :binary_id

    # Account fields
    field :login, :string
    field :password, :string
    field :password_confirmation, :string
    field :role_id, :binary_id
    field :must_change_password, :boolean, default: true

    field :status, Ecto.Enum,
      values: [:active, :blocked, :temporary_blocked],
      default: :active

    # Profile fields
    field :first_name, :string
    field :last_name, :string
    field :patronymic, :string
    field :birth_date, :date
  end

  @doc """
  Builds a changeset for the combined user form.
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(form, attrs) do
    form
    |> cast(attrs, [
      :id,
      :login,
      :password,
      :password_confirmation,
      :role_id,
      :must_change_password,
      :status,
      :first_name,
      :last_name,
      :patronymic,
      :birth_date
    ])
    |> validate_required([:login, :role_id, :status, :first_name, :last_name])
    |> validate_password_required()
    |> validate_format(:login, Identity.login_regex())
    |> validate_password_format()
    |> validate_confirmation(:password, message: dgettext("errors", "does not match password"))
    |> validate_length(:first_name, max: 100)
    |> validate_length(:last_name, max: 100)
    |> maybe_validate_login_taken()
  end

  @doc """
  Prepares form data from existing Account and Profile structs.
  Safely handles cases where a profile might be missing.
  """
  @spec from_account(Account.t()) :: %__MODULE__{}
  def from_account(account) do
    account = Repo.preload(account, :profile)
    profile = account.profile || %{}

    %__MODULE__{
      id: account.id,
      login: account.login,
      role_id: account.role_id,
      must_change_password: account.must_change_password,
      status: account.status,
      first_name: Map.get(profile, :first_name),
      last_name: Map.get(profile, :last_name),
      patronymic: Map.get(profile, :patronymic),
      birth_date: Map.get(profile, :birth_date)
    }
  end

  @doc """
  Splits form data into separate maps for Account and Profile updates.
  """
  @spec to_params(Ecto.Changeset.t()) :: {map(), map()}
  def to_params(changeset) do
    data = apply_changes(changeset)

    account_params =
      data
      |> Map.take([:login, :password, :role_id, :status, :must_change_password])
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)

    profile_params =
      data
      |> Map.take([:first_name, :last_name, :patronymic, :birth_date])
      |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)

    {account_params, profile_params}
  end

  @doc false
  defp validate_password_required(changeset) do
    if is_nil(get_field(changeset, :id)) do
      validate_required(changeset, [:password])
    else
      changeset
    end
  end

  @doc false
  defp validate_password_format(changeset) do
    if get_change(changeset, :password) do
      validate_format(changeset, :password, Identity.password_regex())
    else
      changeset
    end
  end

  # Live (and submit-time) uniqueness check against the real `accounts`
  # table - `UserForm` is schemaless, so a DB-level `unique_constraint`
  # can't run against it. Only queries when `:login` actually changed (so
  # editing a user without touching their login never re-checks it against
  # itself), and excludes the account being edited from the match.
  @doc false
  defp maybe_validate_login_taken(changeset) do
    case get_change(changeset, :login) do
      nil ->
        changeset

      login ->
        case Identity.get_account_by_login(login) do
          {:ok, %{id: other_id}} ->
            if other_id == get_field(changeset, :id) do
              changeset
            else
              add_error(changeset, :login, dgettext("errors", "is already taken"))
            end

          {:error, :not_found} ->
            changeset
        end
    end
  end
end
