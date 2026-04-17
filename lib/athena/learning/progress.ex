defmodule Athena.Learning.Progress do
  @moduledoc """
  Manages student progression and calculates the High Watermark (Retrograde Locks).
  """
  import Ecto.Query
  alias Athena.Repo
  alias Athena.Learning.BlockProgress
  alias Athena.Content

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
    section_id
    |> Content.list_blocks_by_section()
    |> Enum.map(& &1.id)
    |> case do
      [] ->
        []

      block_ids ->
        Repo.all(
          from bp in BlockProgress,
            where:
              bp.account_id == ^account_id and bp.status == :completed and
                bp.block_id in ^block_ids,
            select: bp.block_id
        )
    end
  end

  @doc """
  Returns a list of all section IDs the student is allowed to access.
  Implements Retrograde Locking: if an old section has an uncompleted gate, 
  everything after it becomes locked.
  """
  @spec accessible_section_ids(map(), String.t(), [Athena.Content.Section.t()], list()) :: [
          String.t()
        ]
  def accessible_section_ids(user, _course_id, linear_sections, overrides \\ []) do
    gate_blocks =
      linear_sections
      |> Enum.map(& &1.id)
      |> Content.list_blocks_by_section_ids()
      |> Enum.filter(fn b ->
        b.completion_rule && b.completion_rule.type != :none
      end)

    completed_ids =
      gate_blocks
      |> Enum.map(& &1.id)
      |> case do
        [] ->
          []

        gate_block_ids ->
          Repo.all(
            from bp in BlockProgress,
              where:
                bp.account_id == ^user.id and bp.status == :completed and
                  bp.block_id in ^gate_block_ids,
              select: bp.block_id
          )
      end

    uncompleted_gates_by_section =
      gate_blocks
      |> Enum.reject(&(&1.id in completed_ids))
      |> Enum.group_by(& &1.section_id)

    {accessible, _locked} =
      Enum.reduce_while(linear_sections, {[], false}, fn section, {acc, _} ->
        can_view? = Content.Policy.can_view?(user, section, overrides)
        has_uncompleted_gates? = Map.has_key?(uncompleted_gates_by_section, section.id)

        cond do
          not can_view? ->
            {:halt, {acc, true}}

          has_uncompleted_gates? ->
            {:halt, {acc ++ [section.id], true}}

          true ->
            {:cont, {acc ++ [section.id], false}}
        end
      end)

    accessible
  end
end
