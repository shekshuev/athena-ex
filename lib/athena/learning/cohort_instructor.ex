defmodule Athena.Learning.CohortInstructor do
  @moduledoc """
  Represents the assignment of an instructor to a specific cohort.
  Resolves the N-to-M relationship between Cohorts and Instructors.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cohort_instructors" do
    belongs_to :cohort, Athena.Learning.Cohort
    belongs_to :instructor, Athena.Learning.Instructor

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(link, attrs) do
    link
    |> cast(attrs, [:cohort_id, :instructor_id])
    |> validate_required([:cohort_id, :instructor_id])
    |> unique_constraint([:cohort_id, :instructor_id])
  end
end
