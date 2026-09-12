defmodule Athena.Learning.CourseProgressCache do
  @moduledoc """
  Denormalized completed/total block counts for a course, keyed either by
  account (an individually-tracked enrollment) or by cohort (a `:team`
  enrollment's shared progress — same duality as `Athena.Learning.BlockProgress`).

  Maintained incrementally by `Athena.Learning.Progress.mark_completed/3`
  rather than recomputed from the content tree on every read — that's what
  this table exists to avoid. `total_count` is only set once, when a row is
  first created; it does not follow later edits to the course's block list
  (adding/removing blocks after a student starts it is rare enough, and low
  enough stakes for a progress percentage, not to warrant invalidation
  machinery here).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "learning_course_progress_cache" do
    field :account_id, :binary_id
    field :cohort_id, :binary_id
    field :course_id, :binary_id
    field :completed_count, :integer, default: 0
    field :total_count, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(cache, attrs) do
    cast(cache, attrs, [:account_id, :cohort_id, :course_id, :completed_count, :total_count])
  end
end
