defmodule Athena.Content do
  @moduledoc """
  Public API for the Content context.

  Delegates operations to specialized internal modules:
  - `Courses`: Course CRUD and pagination.
  - `Sections`: Ltree hierarchy and structural management.
  - `Blocks`: Course content blocks with ordering logic.
  - `Library`: Reusable content templates and quiz generators.
  """

  alias Athena.Content.{Courses, Sections, Blocks, Library}

  defdelegate list_courses(params \\ %{}), to: Courses
  defdelegate get_course(id), to: Courses
  defdelegate create_course(attrs), to: Courses
  defdelegate update_course(course, attrs), to: Courses
  defdelegate soft_delete_course(course), to: Courses

  defdelegate get_section(id), to: Sections
  defdelegate create_section(attrs), to: Sections
  defdelegate update_section(section, attrs), to: Sections
  defdelegate delete_section(section), to: Sections
  defdelegate get_course_tree(course_id), to: Sections
  defdelegate reorder_section(section, new_index), to: Sections

  defdelegate list_blocks_by_section(section_id), to: Blocks
  defdelegate get_block(id), to: Blocks
  defdelegate create_block(attrs), to: Blocks
  defdelegate update_block(block, attrs), to: Blocks
  defdelegate reorder_block(block, new_order), to: Blocks
  defdelegate delete_block(block), to: Blocks

  defdelegate list_library_blocks(params, owner_id), to: Library
  defdelegate get_library_block(id), to: Library
  defdelegate create_library_block(attrs), to: Library
  defdelegate update_library_block(block, attrs), to: Library
  defdelegate delete_library_block(block), to: Library
  defdelegate generate_exam_questions(params), to: Library
end
