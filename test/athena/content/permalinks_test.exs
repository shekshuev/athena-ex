defmodule Athena.Content.PermalinksTest do
  use Athena.DataCase, async: true

  import Athena.Factory
  alias Athena.Content.Permalinks
  alias Athena.Content.CompletionRule

  # The factory's default role grants "courses.update" unconditionally (no
  # `own_only` policy) - fine for the many tests elsewhere that don't care,
  # but it would make every plain `insert(:account)` resolve as an editor
  # here. A "student" in these tests needs a role with no editing rights at
  # all, so the enrollment-based checks are actually exercised.
  defp insert_student(), do: insert(:account, role: insert(:role, permissions: []))

  describe "resolve_block/2 and resolve_section/2 - not found" do
    test "unknown block id" do
      assert Permalinks.resolve_block(insert_student(), Ecto.UUID.generate()) ==
               {:error, :not_found}
    end

    test "unknown section id" do
      assert Permalinks.resolve_section(insert_student(), Ecto.UUID.generate()) ==
               {:error, :not_found}
    end

    test "block whose course was soft-deleted" do
      course = insert(:course, owner_id: Ecto.UUID.generate())

      course
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now(:second))
      |> Athena.Repo.update!()

      section = insert(:section, course: course)
      block = insert(:block, section: section)

      assert Permalinks.resolve_block(insert_student(), block.id) == {:error, :not_found}
    end
  end

  describe "resolve_block/2 and resolve_section/2 - editor resolves to the Builder" do
    test "regular course" do
      editor = insert(:account)
      course = insert(:course, owner_id: editor.id)
      section = insert(:section, course: course)
      block = insert(:block, section: section)

      assert {:ok, :builder, result_course, result_section, nil} =
               Permalinks.resolve_section(editor, section.id)

      assert result_course.id == course.id
      assert result_section.id == section.id

      assert {:ok, :builder, _course, _section, block_id} =
               Permalinks.resolve_block(editor, block.id)

      assert block_id == block.id
    end

    test "competition" do
      editor = insert(:account, role: insert(:role, permissions: ["competitions.update"]))
      course = insert(:course, owner_id: editor.id, type: :competition)
      section = insert(:section, course: course)
      block = insert(:block, section: section)

      assert {:ok, :builder, result_course, result_section, nil} =
               Permalinks.resolve_section(editor, section.id)

      assert result_course.id == course.id
      assert result_section.id == section.id

      assert {:ok, :builder, _course, _section, _block_id} =
               Permalinks.resolve_block(editor, block.id)
    end
  end

  describe "resolve_block/2 and resolve_section/2 - student" do
    test "enrolled, unlocked section resolves to the Player" do
      student = insert_student()
      course = insert(:course, owner_id: Ecto.UUID.generate())
      insert(:enrollment, account_id: student.id, course_id: course.id)
      section = insert(:section, course: course)
      block = insert(:block, section: section)

      assert {:ok, :player, result_course, result_section, nil} =
               Permalinks.resolve_section(student, section.id)

      assert result_course.id == course.id
      assert result_section.id == section.id

      assert {:ok, :player, _course, _section, block_id} =
               Permalinks.resolve_block(student, block.id)

      assert block_id == block.id
    end

    test "enrolled, but the section is locked behind an earlier incomplete gate -> not_found" do
      student = insert_student()
      course = insert(:course, owner_id: Ecto.UUID.generate())
      insert(:enrollment, account_id: student.id, course_id: course.id)

      first = insert(:section, course: course, order: 0)
      locked = insert(:section, course: course, order: 1)

      insert(:block,
        section: first,
        type: :text,
        completion_rule: %CompletionRule{type: :submit}
      )

      block = insert(:block, section: locked)

      assert Permalinks.resolve_section(student, locked.id) == {:error, :not_found}
      assert Permalinks.resolve_block(student, block.id) == {:error, :not_found}
    end

    test "not enrolled at all -> forbidden" do
      student = insert_student()
      course = insert(:course, owner_id: Ecto.UUID.generate())
      section = insert(:section, course: course)

      assert Permalinks.resolve_section(student, section.id) == {:error, :forbidden}
    end

    test "dropped enrollment -> forbidden" do
      student = insert_student()
      course = insert(:course, owner_id: Ecto.UUID.generate())
      insert(:enrollment, account_id: student.id, course_id: course.id, status: :dropped)
      section = insert(:section, course: course)

      assert Permalinks.resolve_section(student, section.id) == {:error, :forbidden}
    end

    test "unpublished course -> forbidden" do
      student = insert_student()
      course = insert(:course, owner_id: Ecto.UUID.generate(), status: :draft)
      insert(:enrollment, account_id: student.id, course_id: course.id)
      section = insert(:section, course: course)

      assert Permalinks.resolve_section(student, section.id) == {:error, :forbidden}
    end
  end
end
