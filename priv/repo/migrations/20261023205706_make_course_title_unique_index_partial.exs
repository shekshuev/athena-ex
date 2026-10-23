defmodule Athena.Repo.Migrations.MakeCourseTitleUniqueIndexPartial do
  @moduledoc """
  Makes `courses_title_index` ignore soft-deleted rows.

  Courses (and competitions - same table, split by `type`) are soft-deleted by
  stamping `deleted_at`, so the row sticks around. With a plain
  `unique_index(:courses, [:title])` that meant deleting a course reserved its
  title forever: creating another one with the same name failed a uniqueness
  check against a row nobody can see any more.

  The index keeps its name, so `unique_constraint(:title, name:
  :courses_title_index)` in `Athena.Content.Course` keeps matching it.

  If two soft-deleted courses already share a title with a live one this is a
  no-op either way - the condition only ever removes rows from the index.
  """
  use Ecto.Migration

  def up do
    drop_if_exists index(:courses, [:title], name: :courses_title_index)

    create unique_index(:courses, [:title],
             name: :courses_title_index,
             where: "deleted_at IS NULL"
           )
  end

  def down do
    drop_if_exists index(:courses, [:title], name: :courses_title_index)

    # Recreating the unconditional index can fail if soft-deleted rows now
    # collide, which is exactly the situation `up/0` exists to allow.
    create unique_index(:courses, [:title], name: :courses_title_index)
  end
end
