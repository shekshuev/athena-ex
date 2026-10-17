defmodule Athena.Identity.Account do
  @moduledoc """
  Represents a user account in the system.

  This schema is responsible for authentication, maintaining the account status,
  and establishing relationships with the user's profile and RBAC roles.
  """

  use Ecto.Schema
  import Ecto.Changeset
  alias Athena.Identity.{Role, Profile}

  use Gettext, backend: AthenaWeb.Gettext

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @derive {
    Flop.Schema,
    filterable: [:id, :login, :status],
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
    field :must_change_password, :boolean, default: false
    field :failed_login_attempts, :integer, default: 0
    field :last_failed_at, :utc_datetime
    # When a `:temporary_blocked` status expires; nil for every other status.
    field :blocked_until, :utc_datetime
    field :last_seen_at, :utc_datetime

    belongs_to :role, Role
    has_one :profile, Profile, foreign_key: :owner_id

    field :deleted_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for account creation or update based on the `attrs`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(account, attrs) do
    account
    |> cast(attrs, [
      :login,
      :password,
      :role_id,
      :status,
      :deleted_at,
      :must_change_password,
      :failed_login_attempts,
      :last_failed_at
    ])
    |> put_block_window()
    |> validate_required([:login, :role_id])
    |> validate_password_required()
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

  def force_password_changeset(account, attrs) do
    account
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_format(:password, password_regex(),
      message:
        dgettext_noop(
          "errors",
          "must be at least 8 characters long and contain at least one uppercase letter, one lowercase letter, one number, and one special character"
        )
    )
    |> put_change(:must_change_password, false)
    |> hash_password()
  end

  @doc "How long a temporary block lasts, in seconds."
  @spec temporary_block_seconds() :: pos_integer()
  def temporary_block_seconds, do: 30 * 60

  # Keeps `blocked_until` consistent with a status change made through any
  # path (the login lockout, the admin form, the unblock sweeper):
  #   * entering `:temporary_blocked` starts the standard window, so a block
  #     set by hand also lifts itself;
  #   * leaving it clears the expiry;
  #   * becoming `:active` also forgets past failed logins, otherwise the
  #     next typo would re-block an account an admin just released.
  @doc false
  defp put_block_window(changeset) do
    case get_change(changeset, :status) do
      :temporary_blocked ->
        put_change(changeset, :blocked_until, default_blocked_until())

      :active ->
        changeset
        |> put_change(:blocked_until, nil)
        |> put_change(:failed_login_attempts, 0)
        |> put_change(:last_failed_at, nil)

      :blocked ->
        put_change(changeset, :blocked_until, nil)

      nil ->
        changeset
    end
  end

  defp default_blocked_until do
    DateTime.add(DateTime.utc_now(:second), temporary_block_seconds(), :second)
  end

  @doc false
  defp validate_password_required(changeset) do
    if is_nil(changeset.data.id) do
      validate_required(changeset, [:password])
    else
      changeset
    end
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
