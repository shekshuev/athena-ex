defmodule Athena.Learning.Progress do
  @moduledoc """
  Manages student progression and calculates the High Watermark (Retrograde Locks).
  """
  import Ecto.Query
  alias Athena.Repo
  alias Athena.Learning.BlockProgress
  alias Athena.Content

  @doc """
  Marks an interactive block as completed for a user or a team.
  """
  @spec mark_completed(String.t(), String.t(), String.t() | nil) ::
          {:ok, BlockProgress.t()} | {:error, any()}
  def mark_completed(account_id, block_id, cohort_id \\ nil) do
    conflict_target =
      if cohort_id do
        {:unsafe_fragment, "(cohort_id, block_id) WHERE cohort_id IS NOT NULL"}
      else
        {:unsafe_fragment, "(account_id, block_id) WHERE cohort_id IS NULL"}
      end

    %BlockProgress{}
    |> BlockProgress.changeset(%{
      account_id: account_id,
      block_id: block_id,
      cohort_id: cohort_id,
      status: :completed
    })
    |> Repo.insert(
      on_conflict: [set: [status: :completed, updated_at: DateTime.utc_now()]],
      conflict_target: conflict_target
    )
  end

  @doc """
  Returns a list of completed block IDs scoped to the team or user.
  """
  @spec completed_block_ids(String.t(), String.t(), String.t() | nil) :: [String.t()]
  def completed_block_ids(account_id, section_id, cohort_id \\ nil) do
    section_id
    |> Content.list_blocks_by_section()
    |> Enum.map(& &1.id)
    |> case do
      [] ->
        []

      block_ids ->
        query =
          if cohort_id do
            from bp in BlockProgress,
              where:
                bp.cohort_id == ^cohort_id and bp.status == :completed and
                  bp.block_id in ^block_ids
          else
            from bp in BlockProgress,
              where:
                bp.account_id == ^account_id and is_nil(bp.cohort_id) and bp.status == :completed and
                  bp.block_id in ^block_ids
          end

        Repo.all(from q in query, select: q.block_id)
    end
  end

  @doc """
  Returns a list of all section IDs the student is allowed to access.
  Implements Retrograde Locking: if an old section has an uncompleted gate, 
  everything after it becomes locked.
  """
  @spec accessible_section_ids(
          map(),
          String.t(),
          [Athena.Content.Section.t()],
          list(),
          String.t() | nil
        ) :: [String.t()]
  def accessible_section_ids(user, _course_id, linear_sections, overrides \\ [], cohort_id \\ nil) do
    gate_blocks = get_gate_blocks(linear_sections)
    completed_ids = fetch_completed_gate_ids(gate_blocks, user, cohort_id)

    uncompleted_gates_by_section =
      gate_blocks
      |> Enum.reject(&(&1.id in completed_ids))
      |> Enum.group_by(& &1.section_id)

    {accessible, _locked} =
      Enum.reduce_while(linear_sections, {[], false}, fn section, {acc, _} ->
        evaluate_section_access(section, acc, user, overrides, uncompleted_gates_by_section)
      end)

    accessible
  end

  defp get_gate_blocks(linear_sections) do
    linear_sections
    |> Enum.map(& &1.id)
    |> Content.list_blocks_by_section_ids()
    |> Enum.filter(&(&1.completion_rule && &1.completion_rule.type != :none))
  end

  defp fetch_completed_gate_ids([], _user, _cohort_id), do: []

  defp fetch_completed_gate_ids(gate_blocks, user, cohort_id) do
    gate_block_ids = Enum.map(gate_blocks, & &1.id)

    query =
      if cohort_id do
        from bp in BlockProgress,
          where:
            bp.cohort_id == ^cohort_id and bp.status == :completed and
              bp.block_id in ^gate_block_ids
      else
        from bp in BlockProgress,
          where:
            bp.account_id == ^user.id and is_nil(bp.cohort_id) and bp.status == :completed and
              bp.block_id in ^gate_block_ids
      end

    Repo.all(from q in query, select: q.block_id)
  end

  defp evaluate_section_access(section, acc, user, overrides, uncompleted) do
    can_view? = Content.Policy.can_view?(user, section, overrides)
    has_uncompleted? = Map.has_key?(uncompleted, section.id)

    cond do
      not can_view? -> {:halt, {acc, true}}
      has_uncompleted? -> {:halt, {acc ++ [section.id], true}}
      true -> {:cont, {acc ++ [section.id], false}}
    end
  end
end
