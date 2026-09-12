defmodule Athena.Learning.Progress do
  @moduledoc """
  Manages student progression and calculates the High Watermark (Retrograde Locks).
  """
  import Ecto.Query
  alias Athena.{Repo, Content}
  alias Athena.Learning.{BlockProgress, CohortMembership}
  alias Athena.Content.Section

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

    result =
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

    case result do
      {:ok, progress} ->
        broadcast_block_completed(account_id, cohort_id, block_id)
        {:ok, progress}

      error ->
        error
    end
  end

  @doc false
  defp broadcast_block_completed(account_id, cohort_id, block_id) do
    block_type =
      case Content.get_block(block_id) do
        {:ok, block} -> block.type
        _ -> nil
      end

    Phoenix.PubSub.broadcast(
      Athena.PubSub,
      "learning_events",
      {:block_completed,
       %{account_id: account_id, cohort_id: cohort_id, block_id: block_id, block_type: block_type}}
    )
  end

  @doc """
  Removes the completion record for a block, effectively relocking it for the user/team.
  """
  def revoke_completed(repo, account_id, block_id, cohort_id \\ nil) do
    query =
      if cohort_id do
        from bp in BlockProgress, where: bp.cohort_id == ^cohort_id and bp.block_id == ^block_id
      else
        from bp in BlockProgress,
          where:
            bp.account_id == ^account_id and is_nil(bp.cohort_id) and bp.block_id == ^block_id
      end

    repo.delete_all(query)
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
  Returns the block/cohort of the account's most recent completion activity
  (personal or via any cohort they belong to). Used to power "continue
  learning" dashboard widgets.
  """
  @spec last_activity(String.t()) :: BlockProgress.t() | nil
  def last_activity(account_id) do
    cohort_ids_query =
      from cm in CohortMembership, where: cm.account_id == ^account_id, select: cm.cohort_id

    BlockProgress
    |> where([bp], bp.account_id == ^account_id or bp.cohort_id in subquery(cohort_ids_query))
    |> order_by([bp], desc: bp.updated_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Returns a plain block-completion ratio for a course, scoped to the account
  or cohort. Counts every block across all sections regardless of visibility
  or gating rules — a simple, easy-to-reason-about "% done" for dashboards,
  not the authoritative access/unlock state (see `accessible_section_ids/5`
  for that).
  """
  @spec course_progress(String.t(), String.t(), String.t() | nil) :: %{
          completed: non_neg_integer(),
          total: non_neg_integer(),
          percent: non_neg_integer()
        }
  def course_progress(account_id, course_id, cohort_id \\ nil) do
    block_ids =
      course_id
      |> Content.list_linear_lessons()
      |> Enum.map(& &1.id)
      |> Content.list_blocks_by_section_ids()
      |> Enum.map(& &1.id)

    total = length(block_ids)
    completed = count_completed(account_id, cohort_id, block_ids)
    percent = if total == 0, do: 0, else: round(completed / total * 100)

    %{completed: completed, total: total, percent: percent}
  end

  @doc false
  defp count_completed(_account_id, _cohort_id, []), do: 0

  defp count_completed(account_id, cohort_id, block_ids) do
    query =
      if cohort_id do
        from bp in BlockProgress,
          where:
            bp.account_id == ^account_id and bp.cohort_id == ^cohort_id and
              bp.status == :completed and bp.block_id in ^block_ids
      else
        from bp in BlockProgress,
          where:
            bp.account_id == ^account_id and is_nil(bp.cohort_id) and bp.status == :completed and
              bp.block_id in ^block_ids
      end

    Repo.aggregate(query, :count)
  end

  @doc """
  Returns a list of all section IDs the student is allowed to access.
  Implements Retrograde Locking: if an old section has an uncompleted gate,
  everything after it becomes locked.
  """
  @spec accessible_section_ids(
          map(),
          String.t(),
          [Section.t()],
          list(),
          String.t() | nil
        ) :: [String.t()]
  def accessible_section_ids(user, _course_id, linear_sections, overrides \\ [], cohort_id \\ nil) do
    gate_blocks = get_gate_blocks(linear_sections, user, overrides)
    completed_ids = fetch_completed_gate_ids(gate_blocks, user, cohort_id)

    uncompleted_gates_by_section =
      gate_blocks
      |> Enum.reject(&(&1.id in completed_ids))
      |> Enum.group_by(& &1.section_id)

    {accessible_reversed, _blocked?} =
      Enum.reduce(linear_sections, {[], false}, fn section, acc_state ->
        process_section(section, acc_state, user, overrides, uncompleted_gates_by_section)
      end)

    Enum.reverse(accessible_reversed)
  end

  defp get_gate_blocks(linear_sections, user, overrides) do
    linear_sections
    |> Enum.map(& &1.id)
    |> Content.list_blocks_by_section_ids()
    |> Enum.filter(fn block ->
      block.completion_rule &&
        block.completion_rule.type != :none &&
        Content.can_view?(user, block, overrides)
    end)
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

  @doc false
  defp process_section(section, {acc, blocked?}, user, overrides, uncompleted_gates_by_section) do
    reset_waterline? = get_reset_waterline(section, overrides)
    current_blocked? = if reset_waterline?, do: false, else: blocked?

    can_view? = Content.Policy.can_view?(user, section, overrides)
    has_uncompleted? = Map.has_key?(uncompleted_gates_by_section, section.id)

    new_acc =
      if can_view? and not current_blocked? do
        [section.id | acc]
      else
        acc
      end

    next_blocked? = current_blocked? or has_uncompleted?

    {new_acc, next_blocked?}
  end

  @doc false
  defp get_reset_waterline(section, overrides) do
    override =
      Enum.find(overrides, &(&1.resource_type == :section and &1.resource_id == section.id))

    cond do
      override && Map.get(override, :reset_waterline) != nil ->
        override.reset_waterline

      section.access_rules && Map.get(section.access_rules, :reset_waterline) != nil ->
        section.access_rules.reset_waterline

      true ->
        false
    end
  end
end
