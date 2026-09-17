defmodule Athena.Learning.Progress do
  @moduledoc """
  Manages student progression and calculates the High Watermark (Retrograde Locks).
  """
  import Ecto.Query
  alias Athena.{Repo, Content}
  alias Athena.Learning.{BlockProgress, CohortMembership, CourseProgressCache, Submission}
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

    already_completed? = already_completed?(account_id, block_id, cohort_id)

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
        unless already_completed?, do: bump_course_progress_cache(account_id, cohort_id, block_id)
        {:ok, progress}

      error ->
        error
    end
  end

  defp already_completed?(account_id, block_id, cohort_id) do
    query =
      if cohort_id do
        from bp in BlockProgress,
          where:
            bp.cohort_id == ^cohort_id and bp.block_id == ^block_id and bp.status == :completed
      else
        from bp in BlockProgress,
          where:
            bp.account_id == ^account_id and is_nil(bp.cohort_id) and bp.block_id == ^block_id and
              bp.status == :completed
      end

    Repo.exists?(query)
  end

  @doc """
  Whether `submission` counts as "solved" for progress/XP purposes — a
  broader question than "does it pass this block's gate". A block's
  `completion_rule` governs whether it blocks the waterline (`:submit`,
  `:pass_auto_grade`); a `:none`-type block never gates anything, but an
  auto-gradable `code`/`quiz_question` block can still be genuine practice
  work a student solved, and should count even though it never blocks
  progression. Child exam-question submissions (`parent_submission_id` set)
  are excluded from that second path — they're graded as part of one exam
  completion, not as independent practice, so counting them separately
  would double-award XP on top of the exam block's own completion.
  """
  @spec block_solved?(Content.Block.t(), Submission.t()) :: boolean()
  def block_solved?(block, submission) do
    gate_passed?(block.completion_rule, submission) or
      optional_practice_solved?(block, submission)
  end

  defp gate_passed?(%{type: :submit}, _submission), do: true

  defp gate_passed?(%{type: :pass_auto_grade, min_score: min_score}, submission) do
    submission.score >= (min_score || 0)
  end

  defp gate_passed?(_rule, _submission), do: false

  defp optional_practice_solved?(block, submission) do
    is_nil(submission.parent_submission_id) and
      (is_nil(block.completion_rule) or block.completion_rule.type == :none) and
      practice_passed?(block.type, submission)
  end

  defp practice_passed?(:code, submission), do: submission.status == :accepted
  defp practice_passed?(:quiz_question, submission), do: submission.score == 100
  defp practice_passed?(_type, _submission), do: false

  @doc """
  Reacts to a submission being finalized outside the live player session
  (a teacher grading it, or an exam being auto-scored on exit) by marking
  its block completed if `block_solved?/2` now says yes and it isn't
  already. The live player handles its own synchronous case directly
  (`AthenaWeb.LearnLive.Player`); this is for the paths that don't:
  `Athena.Learning.update_submission/2` (teacher grading) and the exam
  LiveViews' `submit_and_exit/4`.
  """
  @spec maybe_complete_from_submission(Submission.t()) :: :ok
  def maybe_complete_from_submission(%Submission{parent_submission_id: nil} = submission) do
    with {:ok, block} <- Content.get_block(submission.block_id),
         true <- block_solved?(block, submission),
         false <-
           already_completed?(submission.account_id, submission.block_id, submission.cohort_id) do
      mark_completed(submission.account_id, submission.block_id, submission.cohort_id)
    end

    :ok
  end

  def maybe_complete_from_submission(_submission), do: :ok

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
    block_ids = block_ids_for_course(course_id)

    total = length(block_ids)
    completed = count_completed(account_id, cohort_id, block_ids)
    percent = if total == 0, do: 0, else: round(completed / total * 100)

    %{completed: completed, total: total, percent: percent}
  end

  defp block_ids_for_course(course_id) do
    course_id
    |> Content.list_linear_lessons()
    |> Enum.map(& &1.id)
    |> Content.list_blocks_by_section_ids()
    |> Enum.map(& &1.id)
  end

  @doc """
  Returns `cohort_id` only if it's a `:team`-type (competition) cohort —
  the only case `course_progress/3`'s `cohort_id` argument means anything
  (see the comment on `count_completed/3`). Enrolled-via-academic-cohort
  students, and self-paced ones, both get `nil` (their own individual
  progress). Mirrors the derivation `AthenaWeb.LearnLive.Player` already
  does for the same reason.
  """
  @spec team_id_for_enrollment(map()) :: String.t() | nil
  def team_id_for_enrollment(%{cohort_id: nil}), do: nil

  def team_id_for_enrollment(%{cohort: %Ecto.Association.NotLoaded{}}) do
    # Silently falling through to "individual" here would be a much worse
    # bug than crashing — it's exactly this mistake (mixing up team vs
    # individual progress) that caused the dashboard's 0%-progress bug this
    # function exists to prevent.
    raise ArgumentError,
          "team_id_for_enrollment/1 requires :cohort to be preloaded on the enrollment"
  end

  def team_id_for_enrollment(%{cohort: %{type: :team}, cohort_id: cohort_id}), do: cohort_id
  def team_id_for_enrollment(_enrollment), do: nil

  @doc """
  Batched version of `course_progress/3` for a list of enrollments — reads
  `Athena.Learning.CourseProgressCache` in at most two queries (one for
  individually-tracked enrollments, one for team-shared ones) instead of
  walking each course's content tree once per enrollment. Returns a map
  keyed by `enrollment.id`. Any enrollment without a cache row yet (never
  completed anything, or the very first completion hasn't landed) falls
  back to `course_progress/3`, which is also what populates the cache going
  forward.
  """
  @spec course_progress_batch(String.t(), [struct()]) :: %{String.t() => map()}
  def course_progress_batch(account_id, enrollments) do
    cache_by_key = fetch_progress_cache(account_id, enrollments)

    Map.new(enrollments, fn enrollment ->
      team_id = team_id_for_enrollment(enrollment)
      cache_key = {enrollment.course_id, team_id}

      progress =
        case Map.get(cache_by_key, cache_key) do
          nil -> course_progress(account_id, enrollment.course_id, team_id)
          row -> progress_from_cache(row)
        end

      {enrollment.id, progress}
    end)
  end

  defp progress_from_cache(%CourseProgressCache{completed_count: completed, total_count: total}) do
    percent = if total == 0, do: 0, else: round(completed / total * 100)
    %{completed: completed, total: total, percent: percent}
  end

  defp fetch_progress_cache(account_id, enrollments) do
    {individual_course_ids, team_pairs} =
      Enum.reduce(enrollments, {[], []}, fn enrollment, {individual, team} ->
        case team_id_for_enrollment(enrollment) do
          nil -> {[enrollment.course_id | individual], team}
          team_id -> {individual, [team_id | team]}
        end
      end)

    individual_rows =
      if individual_course_ids == [] do
        []
      else
        CourseProgressCache
        |> where(
          [c],
          c.account_id == ^account_id and is_nil(c.cohort_id) and
            c.course_id in ^individual_course_ids
        )
        |> Repo.all()
      end

    team_rows =
      case Enum.uniq(team_pairs) do
        [] -> []
        team_ids -> CourseProgressCache |> where([c], c.cohort_id in ^team_ids) |> Repo.all()
      end

    Map.new(individual_rows ++ team_rows, &{{&1.course_id, &1.cohort_id}, &1})
  end

  defp bump_course_progress_cache(account_id, cohort_id, block_id) do
    with {:ok, block} <- Content.get_block(block_id),
         {:ok, section} <- Content.get_section(block.section_id) do
      course_id = section.course_id
      total = length(block_ids_for_course(course_id))

      key_account_id = if cohort_id, do: nil, else: account_id

      conflict_target =
        if cohort_id do
          {:unsafe_fragment, "(cohort_id, course_id) WHERE cohort_id IS NOT NULL"}
        else
          {:unsafe_fragment, "(account_id, course_id) WHERE cohort_id IS NULL"}
        end

      %CourseProgressCache{}
      |> CourseProgressCache.changeset(%{
        account_id: key_account_id,
        cohort_id: cohort_id,
        course_id: course_id,
        completed_count: 1,
        total_count: total
      })
      |> Repo.insert(on_conflict: [inc: [completed_count: 1]], conflict_target: conflict_target)
    end

    :ok
  end

  @doc false
  defp count_completed(_account_id, _cohort_id, []), do: 0

  defp count_completed(account_id, cohort_id, block_ids) do
    query =
      if cohort_id do
        # `cohort_id` here means "team" (a `:team`-type competition cohort,
        # see `Athena.Learning.Cohort`), never an academic class — progress
        # for a team is deliberately shared, one `BlockProgress` row per
        # (cohort_id, block_id) regardless of which member completed it
        # (same collective model `Submissions.get_team_leaderboard/1` uses),
        # so this intentionally does NOT filter by account_id.
        from bp in BlockProgress,
          where:
            bp.cohort_id == ^cohort_id and bp.status == :completed and bp.block_id in ^block_ids
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
          String.t() | nil,
          keyword()
        ) :: [String.t()]
  def accessible_section_ids(
        user,
        _course_id,
        linear_sections,
        overrides \\ [],
        cohort_id \\ nil,
        opts \\ []
      ) do
    gate_blocks = get_gate_blocks(linear_sections, user, overrides, opts)
    completed_ids = fetch_completed_gate_ids(gate_blocks, user, cohort_id)

    uncompleted_gates_by_section =
      gate_blocks
      |> Enum.reject(&(&1.id in completed_ids))
      |> Enum.group_by(& &1.section_id)

    {accessible_reversed, _blocked?} =
      Enum.reduce(linear_sections, {[], false}, fn section, acc_state ->
        process_section(section, acc_state, user, overrides, uncompleted_gates_by_section, opts)
      end)

    Enum.reverse(accessible_reversed)
  end

  @doc """
  Returns every "gate" block (a block whose `completion_rule` blocks the
  waterline) across `linear_sections` that `user` can currently view.

  Exposed (not `defp`) so `Athena.Learning.TestRuns` can pre-seed the gate
  blocks of the sections *before* a test-run's target section as already
  completed, without duplicating this filtering logic.
  """
  @spec get_gate_blocks([Section.t()], map(), list(), keyword()) :: [Content.Block.t()]
  def get_gate_blocks(linear_sections, user, overrides \\ [], opts \\ []) do
    linear_sections
    |> Enum.map(& &1.id)
    |> Content.list_blocks_by_section_ids()
    |> Enum.filter(fn block ->
      block.completion_rule &&
        block.completion_rule.type != :none &&
        Content.can_view?(user, block, overrides, opts)
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
  defp process_section(
         section,
         {acc, blocked?},
         user,
         overrides,
         uncompleted_gates_by_section,
         opts
       ) do
    reset_waterline? = get_reset_waterline(section, overrides)
    current_blocked? = if reset_waterline?, do: false, else: blocked?

    can_view? = Content.Policy.can_view?(user, section, overrides, opts)
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
