defmodule Athena.Content.Permalinks do
  @moduledoc """
  Resolves player permalinks and explicit `/edit` permalinks. Permissions
  authorize the requested destination; they never select another destination.
  Returns course/section structs so route building stays in AthenaWeb.
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
  @spec resolve_block(map(), String.t(), :player | :builder) :: target()
  def resolve_block(user, block_id, mode \\ :player) do
    case Content.get_block_header(block_id) do
      {:ok, block} -> resolve(user, block.section_id, block.id, mode)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc "Resolves a permalink to a whole section (no block anchor)."
  @spec resolve_section(map(), String.t(), :player | :builder) :: target()
  def resolve_section(user, section_id, mode \\ :player),
    do: resolve(user, section_id, nil, mode)

  @doc false
  defp resolve(user, section_id, block_id, mode) do
    with {:ok, section} <- Content.get_section(section_id),
         {:ok, course} <- Content.get_course(section.course_id) do
      cond do
        mode == :builder and Content.can_edit_course?(user, course) ->
          {:ok, :builder, course, section, block_id}

        mode == :builder ->
          {:error, :forbidden}

        not Learning.has_access?(user.id, course.id) ->
          {:error, :forbidden}

        not destination_unlocked?(user, course, section, block_id) ->
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

  defp destination_unlocked?(user, course, section, nil) do
    {_cohort, cohort_id, team_id} = Learning.resolve_course_cohort(user.id, course.id)
    overrides = Learning.get_student_overrides(user.id, course.id, cohort_id)
    lessons = Content.list_linear_lessons(course.id, user, overrides, [])

    section.id in Learning.accessible_section_ids(
      user,
      course.id,
      lessons,
      overrides,
      team_id,
      []
    )
  end

  defp destination_unlocked?(user, course, _section, block_id) do
    user |> Learning.course_block_access(course.id) |> Map.has_key?(block_id)
  end
end
