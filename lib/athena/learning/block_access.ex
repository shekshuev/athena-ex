defmodule Athena.Learning.BlockAccess do
  @moduledoc "Shared block progression rules for the player and search."

  alias Athena.{Content, Learning}

  @doc """
  Returns a read-only snapshot of currently accessible block headers in a course.

  Course enrollment must be checked by the caller. Loads metadata once per
  course, never content or search text, and shares progression with the player.
  """
  def course_block_access(user, course_id) do
    {_cohort, cohort_id, team_id} = Learning.resolve_course_cohort(user.id, course_id)
    overrides = Learning.get_student_overrides(user.id, course_id, cohort_id)
    lessons = Content.list_linear_lessons(course_id, user, overrides, [])
    headers = Content.list_block_headers_by_section_ids(Enum.map(lessons, & &1.id))

    completed =
      Learning.effective_completed_block_ids(headers, user, team_id, heal_progress?: false)

    opts = [heal_progress?: false, block_headers: headers, completed_ids: completed]

    accessible =
      Learning.accessible_section_ids(user, course_id, lessons, overrides, team_id, opts)

    by_section = Enum.group_by(headers, & &1.section_id)

    lessons
    |> Enum.filter(&(&1.id in accessible))
    |> Enum.flat_map(fn section ->
      by_section
      |> Map.get(section.id, [])
      |> policy_visible_blocks(section, user, overrides, [])
      |> visible_blocks(completed)
    end)
    |> Map.new(&{&1.id, &1})
  end

  @doc "Filters block headers or full blocks through the same policy as the player."
  def policy_visible_blocks(blocks, section, user, overrides, opts) do
    opts = Keyword.put(opts, :sections, %{section.id => section})

    blocks
    |> Enum.filter(&Athena.Content.can_view?(user, &1, overrides, opts))
    |> Enum.sort_by(& &1.order)
  end

  @doc "Applies the player waterline to ordered, policy-visible blocks."
  def visible_blocks(blocks, completed_ids) do
    completed_ids = MapSet.new(completed_ids)

    {visible, _blocked?} =
      Enum.reduce(blocks, {[], false}, fn block, {acc, blocked?} ->
        reset? = block.access_rules && block.access_rules.reset_waterline
        current_blocked? = if reset?, do: false, else: blocked?

        is_completed = MapSet.member?(completed_ids, block.id)

        if current_blocked? do
          {acc, true}
        else
          new_acc = [block | acc]

          next_blocked? =
            block.completion_rule && block.completion_rule.type != :none && not is_completed

          {new_acc, next_blocked?}
        end
      end)

    Enum.reverse(visible)
  end
end
