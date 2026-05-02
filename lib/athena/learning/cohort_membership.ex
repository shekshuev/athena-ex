defmodule Athena.Learning.CohortMembership do
  @moduledoc """
  Represents the membership of an account within a specific cohort.

  This is a join schema that establishes which students belong to which academic groups.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Athena.Learning.Cohort

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @derive {
    Flop.Schema,
    filterable: [:inserted_at],
    sortable: [:inserted_at],
    default_limit: 20,
    default_order: %{
      order_by: [:inserted_at],
      order_directions: [:desc]
    }
  }

  schema "cohort_memberships" do
    belongs_to :cohort, Cohort
    field :account_id, :binary_id

    field :account, :any, virtual: true

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for adding a member to a cohort.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:cohort_id, :account_id])
    |> validate_required([:cohort_id, :account_id])
    |> unique_constraint([:cohort_id, :account_id])
  end
end
