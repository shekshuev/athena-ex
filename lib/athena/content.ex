defmodule Athena.Content do
  @moduledoc """
  Public API for the Content context.

  Delegates read operations to specialized internal modules and wraps
  mutating operations to broadcast real-time updates via PubSub.
  """

  alias Athena.Content.{Courses, Sections, Blocks, Library}
  alias Athena.Content.{Course, Section, Block}

  defdelegate list_courses(params \\ %{}), to: Courses
  defdelegate get_course(id), to: Courses
  defdelegate get_courses_map(ids), to: Courses
  defdelegate search_courses_by_title(query, limit \\ 10), to: Courses

  def create_course(attrs), do: Courses.create_course(attrs) |> notify_subscribers()

  def update_course(course, attrs),
    do: Courses.update_course(course, attrs) |> notify_subscribers()

  def soft_delete_course(course), do: Courses.soft_delete_course(course) |> notify_subscribers()

  defdelegate get_section(id), to: Sections
  defdelegate get_course_tree(course_id, user_or_mode \\ :all), to: Sections
  defdelegate list_linear_lessons(course_id, user_or_mode \\ :all), to: Sections

  def create_section(attrs), do: Sections.create_section(attrs) |> notify_subscribers()

  def update_section(section, attrs),
    do: Sections.update_section(section, attrs) |> notify_subscribers()

  def delete_section(section), do: Sections.delete_section(section) |> notify_subscribers()

  def reorder_section(section, new_index),
    do: Sections.reorder_section(section, new_index) |> notify_subscribers()

  defdelegate list_blocks_by_section(section_id, user_or_mode \\ :all), to: Blocks
  defdelegate get_block(id), to: Blocks
  defdelegate prepare_media_upload(course_id, filename), to: Blocks
  defdelegate get_blocks_map(ids), to: Blocks

  def create_block(attrs), do: Blocks.create_block(attrs) |> notify_subscribers()
  def update_block(block, attrs), do: Blocks.update_block(block, attrs) |> notify_subscribers()

  def reorder_block(block, new_order),
    do: Blocks.reorder_block(block, new_order) |> notify_subscribers()

  def delete_block(block), do: Blocks.delete_block(block) |> notify_subscribers()

  def attach_media_to_block(block, user_id, meta, file_info) do
    Blocks.attach_media_to_block(block, user_id, meta, file_info) |> notify_subscribers()
  end

  defdelegate list_library_blocks(params, owner_id), to: Library
  defdelegate get_library_block(id), to: Library
  defdelegate create_library_block(attrs), to: Library
  defdelegate update_library_block(block, attrs), to: Library
  defdelegate delete_library_block(block), to: Library
  defdelegate generate_exam_questions(params), to: Library

  @doc "Manually trigger a content refresh event for a specific course."
  def broadcast_course_update(course_id) do
    Phoenix.PubSub.broadcast(Athena.PubSub, "course_content:#{course_id}", :refresh_content)
  end

  defp notify_subscribers({:ok, %Course{} = course} = result) do
    broadcast_course_update(course.id)
    result
  end

  defp notify_subscribers({:ok, %Section{} = section} = result) do
    broadcast_course_update(section.course_id)
    result
  end

  defp notify_subscribers({:ok, %Block{} = block} = result) do
    case Sections.get_section(block.section_id) do
      {:ok, section} -> broadcast_course_update(section.course_id)
      _ -> :ok
    end

    result
  end

  defp notify_subscribers(result), do: result
end
