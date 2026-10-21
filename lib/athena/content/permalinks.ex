defmodule Athena.Content.Permalinks do
  @moduledoc """
  Resolves a shareable `/go/blocks/:id` or `/go/sections/:id` link: is the
  given viewer someone who can edit the course (→ `:builder`), an enrolled
  student with that section currently unlocked (→ `:player`), or neither?

  This lets a teacher paste one durable link into an assignment (e.g. "see
  literature blocks #2 and #3") that resolves differently for themselves
  (back into the Builder) than for a student (into the Player, scrolled to
  that block). Deliberately returns the resolved `Course`/`Section`
  structs rather than a built path - path-building needs `AthenaWeb`
  (route helpers, `~p`), which this context boundary may not depend on; see
  `AthenaWeb.PermalinkLive` for where the actual redirect path gets built.
  """

  alias Athena.{Content, Learning}

  @type target ::
          {:ok, :builder | :player, Content.Course.t(), Content.Section.t(),
           block_id :: String.t() | nil}
          | {:error, :not_found | :forbidden}

  @doc """
  Resolves a permalink to a single block - the block's id is carried
  through on success so the caller can anchor the Player to it.
  """
  @spec resolve_block(map(), String.t()) :: target()
  def resolve_block(user, block_id) do
    case Content.get_block(block_id) do
      {:ok, block} -> resolve(user, block.section_id, block.id)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc "Resolves a permalink to a whole section (no block anchor)."
  @spec resolve_section(map(), String.t()) :: target()
  def resolve_section(user, section_id), do: resolve(user, section_id, nil)

  @doc false
  defp resolve(user, section_id, block_id) do
    with {:ok, section} <- Content.get_section(section_id),
         {:ok, course} <- Content.get_course(section.course_id) do
      cond do
        Content.can_edit_course?(user, course) ->
          {:ok, :builder, course, section, block_id}

        not Learning.has_access?(user.id, course.id) ->
          {:error, :forbidden}

        not section_unlocked?(user, course, section) ->
          # Exists, but not yet reachable by this student's progression -
          # deliberately the same outcome as "doesn't exist", not a
          # separate "not unlocked yet" message.
          {:error, :not_found}

        true ->
          {:ok, :player, course, section, block_id}
      end
    else
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  # A small, local duplicate of `Player`'s own private `resolve_cohort_info/2`
  # - not worth exporting from `Player` for this one caller.
  defp section_unlocked?(user, course, section) do
    cohort = Learning.get_user_cohort_for_course(user.id, course.id)
    cohort_id = cohort && cohort.id
    team_id = if cohort && cohort.type == :team, do: cohort.id

    overrides = Learning.get_student_overrides(user.id, course.id, cohort_id)
    linear_lessons = Content.list_linear_lessons(course.id, user, overrides, [])

    accessible_ids =
      Learning.accessible_section_ids(user, course.id, linear_lessons, overrides, team_id, [])

    section.id in accessible_ids
  end
end
