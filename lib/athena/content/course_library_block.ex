defmodule Athena.Content.CourseLibraryBlock do
  @moduledoc """
  Pivot table linking courses to library blocks.
  Acts as the "Course Workspace" or "Course Bank".
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Athena.Content.{Course, LibraryBlock}

  @type t :: %__MODULE__{}

  @primary_key false
  @foreign_key_type :binary_id

  schema "course_library_blocks" do
    belongs_to :course, Course, primary_key: true
    belongs_to :library_block, LibraryBlock, primary_key: true

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:course_id, :library_block_id])
    |> validate_required([:course_id, :library_block_id])
    |> unique_constraint([:course_id, :library_block_id], name: :course_library_blocks_pkey)
  end
end
