defmodule Athena.Content do
  @moduledoc """
  Public API for the Content context.

  Delegates read operations to specialized internal modules and wraps
  mutating operations to broadcast real-time updates via PubSub.
  """

  alias Athena.Content.{Courses, Sections, Blocks, Library, Policy}
  alias Athena.Content.{Course, Section, Block}

  defdelegate list_courses(user, params \\ %{}), to: Courses
  defdelegate get_course(id), to: Courses
  defdelegate get_course(user, id), to: Courses
  defdelegate get_courses_map(ids), to: Courses
  defdelegate search_courses_by_title(user, query, limit \\ 10), to: Courses
  defdelegate list_accessible_course_ids(user), to: Courses

  def create_course(user, attrs), do: Courses.create_course(user, attrs) |> notify_subscribers()

  def update_course(user, course, attrs),
    do: Courses.update_course(user, course, attrs) |> notify_subscribers()

  def soft_delete_course(user, course),
    do: Courses.soft_delete_course(user, course) |> notify_subscribers()

  def share_course(user, course, account_id, role) do
    case Courses.share_course(user, course, account_id, role) do
      {:ok, _share} = result ->
        Phoenix.PubSub.broadcast(Athena.PubSub, "user_courses:#{account_id}", :refresh_courses)
        result

      error ->
        error
    end
  end

  def revoke_course_share(user, course, account_id) do
    case Courses.revoke_course_share(user, course, account_id) do
      {:ok, :revoked} = result ->
        Phoenix.PubSub.broadcast(Athena.PubSub, "user_courses:#{account_id}", :refresh_courses)
        result

      error ->
        error
    end
  end

  def toggle_course_public(user, course, is_public) do
    case Courses.toggle_course_public(user, course, is_public) do
      {:ok, _course} = result ->
        Phoenix.PubSub.broadcast(Athena.PubSub, "public_courses", :refresh_courses)
        result

      error ->
        error
    end
  end

  defdelegate list_course_shares(course), to: Courses

  defdelegate get_section(user, id), to: Sections
  defdelegate get_section(id), to: Sections
  defdelegate get_course_tree(course_id, user_or_mode \\ :all), to: Sections
  defdelegate list_linear_lessons(course_id, user_or_mode \\ :all), to: Sections

  def create_section(user, attrs),
    do: Sections.create_section(user, attrs) |> notify_subscribers()

  def update_section(user, section, attrs),
    do: Sections.update_section(user, section, attrs) |> notify_subscribers()

  def delete_section(user, section),
    do: Sections.delete_section(user, section) |> notify_subscribers()

  def reorder_section(user, section, new_index),
    do: Sections.reorder_section(user, section, new_index) |> notify_subscribers()

  defdelegate list_blocks_by_section(section_id, user_or_mode \\ :all), to: Blocks
  defdelegate list_blocks_by_section_ids(ids), to: Blocks
  defdelegate get_block(user, id), to: Blocks
  defdelegate get_block(id), to: Blocks
  defdelegate prepare_media_upload(user, course_id, filename), to: Blocks
  defdelegate get_blocks_map(ids), to: Blocks
  defdelegate count_blocks_by_course(course_id), to: Blocks

  def create_block(user, attrs), do: Blocks.create_block(user, attrs) |> notify_subscribers()

  def update_block(user, block, attrs),
    do: Blocks.update_block(user, block, attrs) |> notify_subscribers()

  def reorder_block(user, block, new_order),
    do: Blocks.reorder_block(user, block, new_order) |> notify_subscribers()

  def delete_block(user, block), do: Blocks.delete_block(user, block) |> notify_subscribers()

  def attach_media_to_block(user, block, meta, file_info),
    do: Blocks.attach_media_to_block(user, block, meta, file_info) |> notify_subscribers()

  defdelegate list_library_blocks(user, params), to: Library
  defdelegate get_library_block(user, id), to: Library
  defdelegate get_library_block(id), to: Library
  defdelegate create_library_block(user, attrs), to: Library
  defdelegate update_library_block(user, block, attrs), to: Library
  defdelegate delete_library_block(user, block), to: Library
  defdelegate generate_exam_questions(params), to: Library

  defdelegate can_view?(user_or_mode, item, overrides), to: Policy

  @doc "Manually trigger a content refresh event for a specific course."
  def broadcast_course_update(course_id),
    do: Phoenix.PubSub.broadcast(Athena.PubSub, "course_content:#{course_id}", :refresh_content)

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
