defmodule Athena.Identity.Account do
  @moduledoc """
  Represents a user account in the system.

  This schema is responsible for authentication, maintaining the account status,
  and establishing relationships with the user's profile and RBAC roles.
  """

  use Ecto.Schema
  import Ecto.Changeset

  use Gettext, backend: AthenaWeb.Gettext

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @derive {
    Flop.Schema,
    filterable: [:login, :status],
    sortable: [:login, :status, :inserted_at],
    default_limit: 10,
    default_order: %{
      order_by: [:inserted_at],
      order_directions: [:desc]
    }
  }

  schema "accounts" do
    field :login, :string
    field :password_hash, :string
    field :status, Ecto.Enum, values: [:active, :blocked, :temporary_blocked], default: :active

    # Virtual field for password validation, not persisted to the database
    field :password, :string, virtual: true

    belongs_to :role, Athena.Identity.Role
    has_one :profile, Athena.Identity.Profile, foreign_key: :owner_id

    field :deleted_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for account creation or update based on the `attrs`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(account, attrs) do
    account
    |> cast(attrs, [:login, :password, :role_id, :status, :deleted_at])
    |> validate_required([:login, :password, :role_id])
    |> validate_length(:login, min: 3, max: 50)
    |> validate_format(:login, login_regex(),
      message:
        dgettext_noop(
          "errors",
          "can only contain letters, numbers, dots, dashes, and underscores"
        )
    )
    |> validate_format(:password, password_regex(),
      message:
        dgettext_noop(
          "errors",
          "must be at least 8 characters long and contain at least one uppercase letter, one lowercase letter, one number, and one special character"
        )
    )
    |> unique_constraint(:login, name: :accounts__login__uk)
    |> foreign_key_constraint(:role_id,
      name: :accounts__role_id__fk,
      message: dgettext_noop("errors", "does not exist")
    )
    |> hash_password()
  end

  @doc "Regular expression for validating login format"
  def login_regex, do: ~r/^[a-zA-Z0-9_.-]+$/

  @doc "Regular expression for validating strong passwords"
  def password_regex, do: ~r/^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[\W_]).{8,}$/

  @doc false
  @spec hash_password(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp hash_password(changeset) do
    case get_change(changeset, :password) do
      nil ->
        changeset

      password ->
        put_change(changeset, :password_hash, Argon2.hash_pwd_salt(password))
    end
  end
end
