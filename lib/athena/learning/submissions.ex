defmodule Athena.Learning.Submissions do
  @moduledoc """
  Internal business logic for Submission management.

  Handles creation, retrieval, and updates of student answers
  (submissions) for specific content blocks.
  """

  import Ecto.Query
  alias Athena.{Repo, Identity, Content}
  alias Athena.Learning.{Submission, Enrollment, Cohort, Instructor, CohortInstructor}
  alias Athena.Content.{Block, Section}

  @doc """
  Lists submissions with pagination, filtering, and sorting using Flop.
  Enforces grading.read ACL through custom scoping.
  """
  @spec list_submissions(map(), map()) ::
          {:ok, {[Submission.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_submissions(user, params \\ %{}) do
    query =
      Submission
      |> scope_submissions(user, "grading.read")

    Flop.validate_and_run(query, params, for: Submission)
  end

  @doc """
  Gets a single submission by its ID. Enforces grading.read ACL through custom scoping.
  Raises `Ecto.NoResultsError` if the Submission does not exist or access is denied.
  """
  def get_submission!(user, id) do
    Submission
    |> where([s], s.id == ^id)
    |> scope_submissions(user, "grading.read")
    |> Repo.one!()
  end

  @doc false
  defp scope_submissions(query, user, permission) do
    cond do
      "admin" in user.role.permissions ->
        query

      permission in user.role.permissions ->
        policies = Map.get(user.role.policies || %{}, permission, [])

        if "own_only" in policies do
          my_cohort_ids =
            from ci in CohortInstructor,
              join: i in Instructor,
              on: ci.instructor_id == i.id,
              where: i.owner_id == ^user.id,
              select: ci.cohort_id

          my_course_ids = Content.list_accessible_course_ids(user)

          query
          |> join(:inner, [s], b in Block, on: s.block_id == b.id)
          |> join(:inner, [s, b], sec in Section, on: b.section_id == sec.id)
          |> where(
            [s, b, sec],
            s.cohort_id in subquery(my_cohort_ids) or sec.course_id in ^my_course_ids
          )
        else
          query
        end

      true ->
        where(query, [s], false)
    end
  end

  @doc """
  Gets the latest submission for a specific block, scoped by cohort or user.
  """
  @spec get_submission(String.t(), String.t(), String.t() | nil) :: Submission.t() | nil
  def get_submission(account_id, block_id, cohort_id \\ nil) do
    query =
      if cohort_id do
        from s in Submission, where: s.cohort_id == ^cohort_id and s.block_id == ^block_id
      else
        from s in Submission,
          where: s.account_id == ^account_id and is_nil(s.cohort_id) and s.block_id == ^block_id
      end

    query
    |> order_by([s], desc: s.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Creates a new submission, forcing the account_id to the current user to prevent spoofing.
  """
  @spec create_submission(map(), map()) :: {:ok, Submission.t()} | {:error, Ecto.Changeset.t()}
  def create_submission(user, attrs) do
    safe_attrs =
      attrs
      |> Map.put("account_id", user.id)

    %Submission{}
    |> Submission.changeset(safe_attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a submission manually (e.g. manual grading by an instructor). 
  Enforces ACL: only users with grading.update can do this.
  """
  @spec update_submission(map(), Submission.t(), map()) ::
          {:ok, Submission.t()} | {:error, Ecto.Changeset.t() | atom()}
  def update_submission(user, %Submission{} = submission, attrs) do
    if Identity.can?(user, "grading.update", submission) do
      system_update_submission(submission, attrs)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Internal update function for the Player, Exam, and Auto-Evaluator.
  Bypasses ACL because it's driven by system logic, not direct user input.
  """
  def system_update_submission(%Submission{} = submission, attrs) do
    submission
    |> Submission.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Gets the best/latest submissions for a list of block ids, scoped by cohort or user.
  Prioritizes the highest score. If scores are equal, takes the latest attempt.
  """
  @spec get_latest_submissions(String.t(), [String.t()], String.t() | nil) :: %{
          String.t() => Submission.t()
        }
  def get_latest_submissions(account_id, block_ids, cohort_id \\ nil) do
    query =
      if cohort_id do
        from s in Submission, where: s.cohort_id == ^cohort_id and s.block_id in ^block_ids
      else
        from s in Submission,
          where: s.account_id == ^account_id and is_nil(s.cohort_id) and s.block_id in ^block_ids
      end

    query
    |> distinct([s], s.block_id)
    |> order_by([s], [s.block_id, desc: s.score, desc: s.inserted_at])
    |> Repo.all()
    |> Map.new(&{&1.block_id, &1})
  end

  @doc """
  Generates a leaderboard for a specific competition course.
  Calculates the sum of the max scores per block for each team.
  Ties are broken by the timestamp of the latest submission.
  Teams with any rejected submission are disqualified and moved to the bottom.
  """
  def get_team_leaderboard(course_id) do
    best_per_block =
      from s in Submission,
        join: b in Block,
        on: s.block_id == b.id,
        join: sec in Section,
        on: b.section_id == sec.id,
        where:
          not is_nil(s.cohort_id) and sec.course_id == ^course_id and
            s.status in [:graded, :needs_review],
        distinct: [s.cohort_id, s.block_id],
        order_by: [s.cohort_id, s.block_id, desc: s.score, asc: s.inserted_at],
        select: %{
          cohort_id: s.cohort_id,
          score: s.score,
          inserted_at: s.inserted_at
        }

    team_scores =
      from bpb in subquery(best_per_block),
        group_by: bpb.cohort_id,
        select: %{
          cohort_id: bpb.cohort_id,
          total_score: sum(bpb.score),
          last_activity: max(bpb.inserted_at)
        }

    team_attempts =
      from s in Submission,
        join: b in Block,
        on: s.block_id == b.id,
        join: sec in Section,
        on: b.section_id == sec.id,
        where: not is_nil(s.cohort_id) and sec.course_id == ^course_id,
        group_by: s.cohort_id,
        select: %{
          cohort_id: s.cohort_id,
          attempts_count: count(s.id),
          is_disqualified: fragment("count(case when ? = 'rejected' then 1 end) > 0", s.status)
        }

    query =
      from e in Enrollment,
        join: c in Cohort,
        on: e.cohort_id == c.id,
        left_join: ts in subquery(team_scores),
        on: ts.cohort_id == c.id,
        left_join: ta in subquery(team_attempts),
        on: ta.cohort_id == c.id,
        where: e.course_id == ^course_id and c.type == :team,
        select: %{
          team_id: c.id,
          team_name: c.name,
          total_score: type(coalesce(ts.total_score, 0), :integer),
          last_activity: ts.last_activity,
          attempts: type(coalesce(ta.attempts_count, 0), :integer),
          is_disqualified: type(coalesce(ta.is_disqualified, false), :boolean)
        },
        order_by: [
          asc: coalesce(ta.is_disqualified, false),
          desc: coalesce(ts.total_score, 0),
          asc: ts.last_activity,
          asc: coalesce(ta.attempts_count, 0)
        ]

    Repo.all(query)
  end
end
