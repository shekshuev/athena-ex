defmodule Athena.Learning.Instructor do
  @moduledoc """
  Represents a teacher profile linked to a system account.
  Stores academic information, titles, and biography.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @derive {
    Flop.Schema,
    filterable: [:title, :bio],
    sortable: [:title, :inserted_at],
    default_limit: 10,
    default_order: %{
      order_by: [:inserted_at],
      order_directions: [:desc]
    }
  }

  schema "instructors" do
    field :title, :string
    field :bio, :string
    field :owner_id, :binary_id

    field :account, :any, virtual: true

    has_many :cohort_links, Athena.Learning.CohortInstructor
    has_many :cohorts, through: [:cohort_links, :cohort]

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for instructor creation or update.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(instructor, attrs) do
    instructor
    |> cast(attrs, [:title, :bio, :owner_id])
    |> validate_required([:title, :owner_id])
    |> unique_constraint(:owner_id)
  end
end
