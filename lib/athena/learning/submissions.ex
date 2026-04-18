defmodule Athena.Learning.Submissions do
  @moduledoc """
  Internal business logic for Submission management.

  Handles creation, retrieval, and updates of student answers
  (submissions) for specific content blocks.
  """

  import Ecto.Query
  alias Athena.Repo
  alias Athena.Learning.Submission

  @doc """
  Lists submissions with pagination, filtering, and sorting using Flop.
  """
  @spec list_submissions(map()) ::
          {:ok, {[Submission.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_submissions(params \\ %{}) do
    Flop.validate_and_run(Submission, params, for: Submission)
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
  Creates a new submission.
  """
  @spec create_submission(map()) :: {:ok, Submission.t()} | {:error, Ecto.Changeset.t()}
  def create_submission(attrs) do
    %Submission{}
    |> Submission.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an existing submission.
  """
  @spec update_submission(Submission.t(), map()) ::
          {:ok, Submission.t()} | {:error, Ecto.Changeset.t()}
  def update_submission(%Submission{} = submission, attrs) do
    submission
    |> Submission.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Gets the latest submissions for a list of block ids, scoped by cohort or user.
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
    |> order_by([s], [s.block_id, desc: s.inserted_at])
    |> Repo.all()
    |> Map.new(&{&1.block_id, &1})
  end

  @doc """
  Gets a single submission by its ID.
  Raises `Ecto.NoResultsError` if the Submission does not exist.
  """
  def get_submission!(id), do: Repo.get!(Submission, id)

  alias Athena.Content.{Block, Section}
  alias Athena.Learning.Cohort

  @doc """
  Generates a leaderboard for a specific competition course.
  Calculates the sum of the max scores per block for each team.
  Ties are broken by the timestamp of the latest submission.
  """
  def get_team_leaderboard(course_id) do
    best_scores =
      from s in Submission,
        where: not is_nil(s.cohort_id) and s.status in [:graded, :needs_review],
        group_by: [s.cohort_id, s.block_id],
        select: %{
          cohort_id: s.cohort_id,
          block_id: s.block_id,
          score: max(s.score),
          last_activity: max(s.inserted_at)
        }

    query =
      from bs in subquery(best_scores),
        join: b in Block,
        on: bs.block_id == b.id,
        join: sec in Section,
        on: b.section_id == sec.id,
        join: c in Cohort,
        on: bs.cohort_id == c.id,
        where: sec.course_id == ^course_id,
        group_by: [c.id, c.name],
        select: %{
          team_id: c.id,
          team_name: c.name,
          total_score: type(sum(bs.score), :integer),
          last_activity: max(bs.last_activity)
        },
        order_by: [
          desc: sum(bs.score),
          asc: max(bs.last_activity)
        ]

    Repo.all(query)
  end
end
