defmodule Athena.Content.CourseShare do
  @moduledoc "Pivot table connecting Courses to Identity.Accounts softly (no hard FK)."

  use Ecto.Schema
  import Ecto.Changeset
  alias Athena.Content.Course

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "course_shares" do
    belongs_to :course, Course
    field :account_id, Ecto.UUID
    field :role, Ecto.Enum, values: [:reader, :writer], default: :reader

    timestamps(type: :utc_datetime)
  end

  def changeset(course_share, attrs) do
    course_share
    |> cast(attrs, [:course_id, :account_id, :role])
    |> validate_required([:course_id, :account_id])
    |> unique_constraint([:course_id, :account_id])
  end
end
