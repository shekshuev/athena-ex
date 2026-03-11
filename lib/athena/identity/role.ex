defmodule Athena.Identity.Role do
  @moduledoc """
  Represents an access-control role within the Athena LMS authorization system.

  This schema defines the role name, a list of assigned permissions (stored as a JSONB array),
  and specific policies (stored as a JSONB object) that impose object-level constraints.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @derive {
    Flop.Schema,
    filterable: [:name],
    sortable: [:name, :inserted_at],
    default_limit: 20,
    default_order: %{
      order_by: [:name],
      order_directions: [:asc]
    }
  }

  schema "roles" do
    field :name, :string
    field :permissions, {:array, :string}, default: []
    field :policies, :map, default: %{}

    has_many :accounts, Athena.Identity.Account

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for role creation or update.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(role, attrs) do
    role
    |> cast(attrs, [:name, :permissions, :policies])
    |> validate_required([:name])
    |> validate_length(:name, min: 2, max: 50)
    |> unique_constraint(:name, name: :roles__name__uk)
  end
end
