defmodule Athena.Gamification.DailyChallenges do
  @moduledoc """
  A daily "task of the day" — one already-solved, auto-gradable block
  (`code` or `quiz_question` only — never `file_assignment`, an exam, or a
  passive block) re-served to the student each day, à la Hyperskill's daily
  review. Solving it again keeps XP/streak activity flowing on a slow day
  without inventing new work.

  Generated lazily on first request each day, not by a midnight cron: this
  LMS isn't reachable 24/7 (the same reason `Athena.Gamification.Streaks`
  is a weekly batch rather than a daily-login check), so a cron job would
  either miss inactive students or generate challenges nobody ever opens.

  Completion is detected reactively, off the same `{:block_completed, _}`
  fact `Athena.Learning` already broadcasts for every completion (see
  `Athena.Gamification.ActivityListener`) — not by adding anything to the
  Player LiveView's submission flow. This keeps Gamification a pure
  consumer of Learning's existing events instead of Learning needing to
  know "was this submission for a daily challenge".
  """
  import Ecto.Query
  alias Athena.Repo
  alias Athena.{Content, Learning}
  alias Athena.Learning.BlockProgress
  alias Athena.Gamification.{DailyChallenge, XpLedger}

  @eligible_block_types ~w(code quiz_question)a

  @doc """
  Returns today's challenge for the account, generating one the first time
  it's requested this (UTC) day. `nil` if the account has no eligible
  completed block yet (no enrollments, or nothing auto-gradable solved).
  """
  @spec today_for(String.t()) :: DailyChallenge.t() | nil
  def today_for(account_id) do
    today = Date.utc_today()

    case Repo.get_by(DailyChallenge, account_id: account_id, assigned_date: today) do
      nil -> generate_for(account_id, today)
      challenge -> challenge
    end
  end

  defp generate_for(account_id, today) do
    case pick_candidate_block_id(account_id) do
      nil ->
        nil

      block_id ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        attrs = %{
          id: Ecto.UUID.generate(),
          account_id: account_id,
          block_id: block_id,
          assigned_date: today,
          inserted_at: now,
          updated_at: now
        }

        # insert_all + re-fetch rather than Repo.insert/2: with a
        # client-generated binary_id, a conflicted Repo.insert/2 still
        # returns {:ok, struct} with a non-nil id, so it can't signal "someone
        # else won the race for this account/day" — re-fetching always gets
        # the actual row either way.
        Repo.insert_all(DailyChallenge, [attrs],
          on_conflict: :nothing,
          conflict_target: [:account_id, :assigned_date]
        )

        Repo.get_by(DailyChallenge, account_id: account_id, assigned_date: today)
    end
  end

  defp pick_candidate_block_id(account_id) do
    block_ids =
      account_id
      |> Learning.list_student_enrollments()
      |> Enum.map(& &1.course_id)
      |> Enum.uniq()
      |> Enum.flat_map(&eligible_block_ids_for_course/1)

    case completed_block_ids(account_id, block_ids) do
      [] -> nil
      completed_ids -> Enum.random(completed_ids)
    end
  end

  defp eligible_block_ids_for_course(course_id) do
    case Content.get_course(course_id) do
      {:ok, %{type: :standard}} ->
        course_id
        |> Content.list_linear_lessons()
        |> Enum.map(& &1.id)
        |> Content.list_blocks_by_section_ids()
        |> Enum.filter(&(&1.type in @eligible_block_types))
        |> Enum.map(& &1.id)

      # A :competition course's tasks must never leak into a daily challenge —
      # they're meant to stay exclusive to the competitive/graded context they
      # were written for.
      _ ->
        []
    end
  end

  defp completed_block_ids(_account_id, []), do: []

  defp completed_block_ids(account_id, block_ids) do
    BlockProgress
    |> where([bp], bp.account_id == ^account_id and bp.status == :completed)
    |> where([bp], bp.block_id in ^block_ids)
    |> distinct(true)
    |> select([bp], bp.block_id)
    |> Repo.all()
  end

  @doc """
  Reacts to a `:block_completed` fact: if it matches the account's
  still-open challenge for today, marks it done, awards a bonus XP event,
  and retroactively tags the submission that caused it so it's excluded
  from the default grading list (see `Athena.Learning.Submissions`).
  Anything else (no challenge today, already completed, unrelated block)
  is a no-op.
  """
  @spec handle_block_completed(map()) :: :ok
  def handle_block_completed(%{account_id: account_id, block_id: block_id} = payload) do
    today = Date.utc_today()

    DailyChallenge
    |> where(
      [c],
      c.account_id == ^account_id and c.assigned_date == ^today and c.block_id == ^block_id and
        is_nil(c.completed_at)
    )
    |> Repo.one()
    |> case do
      nil -> :ok
      challenge -> complete(challenge, payload)
    end
  end

  defp complete(challenge, payload) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    challenge
    |> DailyChallenge.changeset(%{completed_at: now})
    |> Repo.update()

    XpLedger.record_daily_challenge(%{
      account_id: challenge.account_id,
      daily_challenge_id: challenge.id,
      block_type: Map.get(payload, :block_type)
    })

    tag_submission(challenge.account_id, challenge.block_id, Map.get(payload, :cohort_id))

    :ok
  end

  defp tag_submission(account_id, block_id, cohort_id) do
    case Learning.get_latest_submissions(account_id, [block_id], cohort_id) do
      %{^block_id => submission} ->
        Learning.system_update_submission(submission, %{"origin" => "daily_challenge"})

      _ ->
        :ok
    end
  end
end
