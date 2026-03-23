defmodule Athena.Learning.Cohort do
  @moduledoc """
  Represents a student cohort or academic group.
  Cohorts are independent of courses and can be enrolled in multiple courses over time.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @derive {
    Flop.Schema,
    filterable: [:name, :description],
    sortable: [:name, :inserted_at],
    default_limit: 10,
    default_order: %{
      order_by: [:inserted_at],
      order_directions: [:desc]
    }
  }

  schema "cohorts" do
    field :name, :string
    field :description, :string

    field :instructor_ids, {:array, :binary_id}, virtual: true

    has_many :memberships, Athena.Learning.CohortMembership

    many_to_many :instructors, Athena.Learning.Instructor,
      join_through: Athena.Learning.CohortInstructor,
      on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(cohort, attrs) do
    cohort
    |> cast(attrs, [:name, :description, :instructor_ids])
    |> validate_required([:name])
  end
end
