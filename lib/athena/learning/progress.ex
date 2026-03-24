defmodule Athena.Learning.Progress do
  @moduledoc """
  Manages student progression and calculates the High Watermark (Retrograde Locks).
  """
  import Ecto.Query
  alias Athena.Repo
  alias Athena.Learning.BlockProgress
  alias Athena.Content.Block

  @doc """
  Marks an interactive block as completed.
  """
  @spec mark_completed(String.t(), String.t()) :: {:ok, BlockProgress.t()} | {:error, any()}
  def mark_completed(account_id, block_id) do
    %BlockProgress{}
    |> BlockProgress.changeset(%{
      account_id: account_id,
      block_id: block_id,
      status: :completed
    })
    |> Repo.insert(
      on_conflict: [set: [status: :completed, updated_at: DateTime.utc_now()]],
      conflict_target: [:account_id, :block_id]
    )
  end

  @doc """
  Returns a list of completed block IDs for a specific user and section.
  """
  @spec completed_block_ids(String.t(), String.t()) :: [String.t()]
  def completed_block_ids(account_id, section_id) do
    from(bp in BlockProgress,
      join: b in Block,
      on: bp.block_id == b.id,
      where:
        bp.account_id == ^account_id and b.section_id == ^section_id and bp.status == :completed,
      select: bp.block_id
    )
    |> Repo.all()
  end

  @doc """
  Returns a list of all section IDs the student is allowed to access.
  Implements Retrograde Locking: if an old section has an uncompleted gate, 
  everything after it becomes locked.
  """
  @spec accessible_section_ids(String.t(), String.t(), [Athena.Content.Section.t()]) :: [
          String.t()
        ]
  def accessible_section_ids(account_id, course_id, linear_sections) do
    gate_blocks =
      from(b in Block,
        join: s in Athena.Content.Section,
        on: b.section_id == s.id,
        where: s.course_id == ^course_id and fragment("?->>'type' != 'none'", b.completion_rule),
        select: %{id: b.id, section_id: b.section_id}
      )
      |> Repo.all()

    completed_ids =
      from(bp in BlockProgress,
        join: b in Block,
        on: bp.block_id == b.id,
        join: s in Athena.Content.Section,
        on: b.section_id == s.id,
        where:
          s.course_id == ^course_id and bp.account_id == ^account_id and bp.status == :completed,
        select: bp.block_id
      )
      |> Repo.all()

    uncompleted_gates_by_section =
      gate_blocks
      |> Enum.reject(&(&1.id in completed_ids))
      |> Enum.group_by(& &1.section_id)

    {accessible, _locked} =
      Enum.reduce_while(linear_sections, {[], false}, fn section, {acc, _} ->
        has_uncompleted_gates? = Map.has_key?(uncompleted_gates_by_section, section.id)

        if has_uncompleted_gates? do
          {:halt, {acc ++ [section.id], true}}
        else
          {:cont, {acc ++ [section.id], false}}
        end
      end)

    accessible
  end
end
