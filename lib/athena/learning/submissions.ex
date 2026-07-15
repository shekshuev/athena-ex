defmodule Athena.Learning.Submissions do
  @moduledoc """
  Internal business logic for Submission management.

  Handles creation, retrieval, and updates of student answers
  (submissions) for specific content blocks.
  """

  import Ecto.Query
  alias Athena.{Repo, Content}

  alias Athena.Learning.{
    Submission,
    Enrollment,
    Cohort,
    Instructor,
    CohortInstructor,
    Progress,
    DraftCache
  }

  alias Athena.Content.{Block, Section, TicketUsage}

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
    query =
      query
      |> where([s], s.status != :draft)
      |> where([s], is_nil(s.parent_submission_id))
      |> where([s], fragment("?->>'is_test_run' IS NULL", s.content))

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
  Excludes draft submissions.
  """
  @spec get_submission(String.t(), String.t(), String.t() | nil) :: Submission.t() | nil
  def get_submission(account_id, block_id, cohort_id \\ nil) do
    query =
      if cohort_id do
        from s in Submission,
          where: s.cohort_id == ^cohort_id and s.block_id == ^block_id and s.status != :draft
      else
        from s in Submission,
          where:
            s.account_id == ^account_id and is_nil(s.cohort_id) and
              s.block_id == ^block_id and s.status != :draft
      end

    query
    |> order_by([s], desc: s.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Creates a new submission, forces the account_id, and enqueues execution if it's a code block.
  If a draft exists for this block, updates it instead of creating a new record.
  Uses Ecto.Multi to guarantee that the job is queued ONLY if the submission is saved.
  """
  @spec create_submission(map(), map()) :: {:ok, Submission.t()} | {:error, any()}
  def create_submission(user, attrs) do
    safe_attrs = Map.put(attrs, "account_id", user.id)
    block_id = Map.get(attrs, "block_id")
    cohort_id = Map.get(attrs, "cohort_id")

    existing_draft = find_draft(user.id, block_id, cohort_id)

    Ecto.Multi.new()
    |> Ecto.Multi.run(:submission, fn _repo, _changes ->
      if existing_draft do
        existing_draft
        |> Submission.changeset(Map.put(safe_attrs, "status", :pending))
        |> Ecto.Changeset.put_change(
          :inserted_at,
          DateTime.utc_now() |> DateTime.truncate(:second)
        )
        |> Repo.update()
      else
        %Submission{}
        |> Submission.changeset(safe_attrs)
        |> Repo.insert()
      end
    end)
    |> Ecto.Multi.run(:enqueue_job, fn repo, %{submission: submission} ->
      block = repo.get(Block, submission.block_id)

      if block && block.type == :code do
        %{submission_id: submission.id}
        |> Athena.Execution.Worker.new()
        |> Oban.insert()
      else
        {:ok, :skipped_execution}
      end
    end)
    |> Ecto.Multi.run(:clear_draft_cache, fn _repo, _changes ->
      clear_draft(user.id, block_id, cohort_id)
      {:ok, :cleared}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{submission: submission}} -> {:ok, submission}
      {:error, _failed_op, changeset, _changes} -> {:error, changeset}
    end
  end

  @doc """
  Enqueues the code execution worker for a specific submission.
  Updates the status to :processing immediately.
  Works for both regular blocks and generated exam questions.
  """
  def enqueue_code_execution(%Submission{} = submission) do
    is_code_content = submission.content["type"] in [:code, "code"]

    if is_code_content do
      do_enqueue(submission)
    else
      block = Repo.get(Block, submission.block_id)

      if block && block.type == :code do
        do_enqueue(submission)
      else
        {:error, :not_a_code_block}
      end
    end
  end

  @doc false
  defp do_enqueue(submission) do
    {:ok, processing_sub} = system_update_submission(submission, %{status: :processing})

    %{submission_id: processing_sub.id}
    |> Athena.Execution.Worker.new()
    |> Oban.insert()

    {:ok, processing_sub}
  end

  @doc """
  Initiates a test run for code by updating the draft and enqueuing an Oban worker.
  Does NOT count as a formal submission attempt.
  """
  def test_code(user, block, code) do
    content = %{"type" => :code, "code" => code, "is_test_run" => true}

    case save_draft(user, block.id, content, nil) do
      {:ok, draft} ->
        %{submission_id: draft.id}
        |> Athena.Execution.TestWorker.new()
        |> Oban.insert()

        {:ok, draft}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Updates a submission manually (e.g. manual grading by an instructor).
  Enforces ACL: only users with grading.update can do this.
  """
  @spec update_submission(map(), Submission.t(), map()) ::
          {:ok, Submission.t()} | {:error, Ecto.Changeset.t() | atom()}
  def update_submission(user, %Submission{} = submission, attrs) do
    has_access? =
      Submission
      |> where([s], s.id == ^submission.id)
      |> scope_submissions(user, "grading.update")
      |> Repo.exists?()

    if has_access? do
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
  Excludes draft submissions.
  """
  @spec get_latest_submissions(String.t(), [String.t()], String.t() | nil) :: %{
          String.t() => Submission.t()
        }
  def get_latest_submissions(account_id, block_ids, cohort_id \\ nil) do
    query =
      if cohort_id do
        from s in Submission,
          where:
            s.cohort_id == ^cohort_id and s.block_id in ^block_ids and s.status != :draft and
              fragment("?->>'is_test_run' IS NULL", s.content)
      else
        from s in Submission,
          where:
            s.account_id == ^account_id and is_nil(s.cohort_id) and
              s.block_id in ^block_ids and s.status != :draft and
              fragment("?->>'is_test_run' IS NULL", s.content)
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

  @doc """
  Deletes a submission and rolls back the student's progress for this block.
  Enforces ACL: only users with grading.update can do this.
  """
  @spec delete_submission_with_rollback(map(), Submission.t()) ::
          {:ok, Submission.t()} | {:error, any()}
  def delete_submission_with_rollback(user, %Submission{} = submission) do
    has_access? =
      Submission
      |> where([s], s.id == ^submission.id)
      |> scope_submissions(user, "grading.update")
      |> Repo.exists?()

    if has_access? do
      Ecto.Multi.new()
      |> Ecto.Multi.delete(:submission, submission)
      |> Ecto.Multi.run(:revoke, fn repo, _changes ->
        {deleted_count, _} =
          Progress.revoke_completed(
            repo,
            submission.account_id,
            submission.block_id,
            submission.cohort_id
          )

        {:ok, deleted_count}
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{submission: deleted_sub}} ->
          {:ok, deleted_sub}

        {:error, _failed_op, changeset, _changes} ->
          {:error, changeset}
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Returns a map of %{block_id => attempts_count} for a given user/team and list of blocks.
  Excludes draft submissions.
  """
  def count_attempts(account_id, block_ids, cohort_id \\ nil) do
    query =
      if cohort_id do
        from s in Athena.Learning.Submission,
          where: s.cohort_id == ^cohort_id and s.block_id in ^block_ids and s.status != :draft
      else
        from s in Athena.Learning.Submission,
          where:
            s.account_id == ^account_id and is_nil(s.cohort_id) and
              s.block_id in ^block_ids and s.status != :draft
      end

    query
    |> group_by([s], s.block_id)
    |> select([s], {s.block_id, count(s.id)})
    |> Repo.all()
    |> Enum.into(%{})
  end

  @doc """
  Saves a draft submission. Creates or updates existing draft.
  Caches in Cachex for fast access, stores in DB for persistence.
  For team submissions, broadcasts update to all team members.
  """
  @spec save_draft(map(), String.t(), map(), String.t() | nil) ::
          {:ok, Submission.t()} | {:error, Ecto.Changeset.t()}
  def save_draft(user, block_id, content, cohort_id \\ nil) do
    attrs = %{
      "account_id" => user.id,
      "block_id" => block_id,
      "cohort_id" => cohort_id,
      "status" => :draft,
      "content" => content
    }

    find_draft(user.id, block_id, cohort_id)
    |> case do
      nil ->
        %Submission{}
        |> Submission.changeset(attrs)
        |> Repo.insert()

      val ->
        val
        |> Submission.changeset(attrs)
        |> Repo.update()
    end
    |> case do
      {:ok, submission} ->
        DraftCache.save_draft(user.id, cohort_id, block_id, content)

        if cohort_id do
          DraftCache.broadcast_draft_update(cohort_id, block_id, content, user.id)
        end

        {:ok, submission}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Retrieves a draft submission content.
  Checks Cachex first, falls back to DB if not found.
  """
  @spec get_draft(String.t(), String.t(), String.t() | nil) :: map() | nil
  def get_draft(user_id, block_id, cohort_id \\ nil) do
    case DraftCache.get_draft(user_id, cohort_id, block_id) do
      nil ->
        maybe_restore_draft_from_db(user_id, block_id, cohort_id)

      content ->
        content
    end
  end

  @doc """
  Clears a draft from cache (but not from DB).
  Used when submission is finalized.
  """
  @spec clear_draft(String.t(), String.t(), String.t() | nil) :: :ok
  def clear_draft(user_id, block_id, cohort_id \\ nil) do
    DraftCache.clear_draft(user_id, cohort_id, block_id)
    :ok
  end

  @doc false
  defp maybe_restore_draft_from_db(user_id, block_id, cohort_id) do
    case find_draft(user_id, block_id, cohort_id) do
      nil ->
        nil

      submission ->
        DraftCache.save_draft(user_id, cohort_id, block_id, submission.content)
        submission.content
    end
  end

  @doc false
  defp find_draft(_user_id, nil, _cohort_id), do: nil

  defp find_draft(user_id, block_id, cohort_id) do
    query =
      if cohort_id do
        from s in Submission,
          where:
            s.cohort_id == ^cohort_id and s.block_id == ^block_id and
              (s.status == :draft or fragment("?->>'is_test_run' = 'true'", s.content))
      else
        from s in Submission,
          where:
            s.account_id == ^user_id and s.block_id == ^block_id and
              (s.status == :draft or fragment("?->>'is_test_run' = 'true'", s.content)) and
              is_nil(s.cohort_id)
      end

    query
    |> order_by([s], desc: s.updated_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Starts a new exam submission attempt for a student.
  Creates a parent submission with an expiration time.
  """
  def start_exam_submission(account_id, exam_block_id, cohort_id, time_limit_seconds) do
    expires_at = DateTime.add(DateTime.utc_now(), time_limit_seconds, :second)

    %Submission{}
    |> Submission.changeset(%{
      account_id: account_id,
      block_id: exam_block_id,
      cohort_id: cohort_id,
      status: :pending,
      expires_at: expires_at,
      content: %{"started_at" => DateTime.utc_now() |> DateTime.to_iso8601()}
    })
    |> Repo.insert()
  end

  @doc """
  Saves or updates a submission for a specific question/block within an exam.
  Links it to the parent exam submission.
  """
  def save_question_submission(
        parent_submission,
        account_id,
        question_block_id,
        cohort_id,
        answer_content
      ) do
    limit_check =
      if parent_submission.expires_at do
        DateTime.compare(DateTime.utc_now(), parent_submission.expires_at)
      else
        :lt
      end

    do_save_question_submission(
      limit_check,
      parent_submission,
      account_id,
      question_block_id,
      cohort_id,
      answer_content
    )
  end

  @doc false
  defp do_save_question_submission(:gt, _, _, _, _, _), do: {:error, :time_limit_exceeded}

  defp do_save_question_submission(
         _,
         parent_submission,
         account_id,
         question_block_id,
         cohort_id,
         answer_content
       ) do
    query =
      from s in Submission,
        where: s.parent_submission_id == ^parent_submission.id,
        where: s.block_id == ^question_block_id,
        where: s.account_id == ^account_id

    case query |> limit(1) |> Repo.one() do
      nil ->
        %Submission{}
        |> Submission.changeset(%{
          parent_submission_id: parent_submission.id,
          account_id: account_id,
          block_id: question_block_id,
          cohort_id: cohort_id,
          status: :draft,
          content: answer_content
        })
        |> Repo.insert()

      existing_submission ->
        existing_submission
        |> Submission.changeset(%{
          content: Map.merge(existing_submission.content || %{}, answer_content),
          status: :draft
        })
        |> Repo.update()
    end
  end

  @doc """
  Gets the active (pending/draft) exam submission for a student, if it hasn't expired.
  """
  def get_active_exam_submission(account_id, exam_block_id) do
    query =
      from s in Submission,
        where: s.account_id == ^account_id,
        where: s.block_id == ^exam_block_id,
        where: s.status in [:pending, :draft],
        where: is_nil(s.parent_submission_id),
        order_by: [desc: s.inserted_at],
        limit: 1

    Repo.one(query)
  end

  @doc """
  Gets all child submissions for a given parent exam submission.
  Returns a map of %{block_id => %Submission{}} for efficient lookup in templates.
  """
  def get_child_submissions(parent_submission_id) do
    from(s in Submission,
      where: s.parent_submission_id == ^parent_submission_id
    )
    |> Repo.all()
    |> Map.new(&{&1.block_id, &1})
  end

  @doc """
  Gets an active exam attempt, or creates a new one with a fixed set of questions.
  Intelligently routes to either `quiz_exam` or `ticket_exam` generator logic.
  """
  def get_or_create_exam_attempt(
        course_id,
        account_id,
        exam_block_id,
        cohort_id,
        time_limit_sec,
        exam_config
      ) do
    case get_active_exam_submission(account_id, exam_block_id) do
      nil ->
        is_ticket = Map.has_key?(exam_config, "slots")

        questions =
          if is_ticket do
            usage = get_ticket_usage(exam_block_id, cohort_id)

            Athena.Content.Library.generate_ticket_questions(
              course_id,
              exam_config["slots"],
              usage
            )
          else
            Athena.Content.generate_exam_questions(course_id, exam_config)
          end

        expires_at = DateTime.add(DateTime.utc_now(), time_limit_sec, :second)

        type = if is_ticket, do: "ticket_exam", else: "quiz_exam"

        content = %{
          "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "questions" => questions,
          "type" => type,
          "cheat_count" => 0
        }

        %Submission{}
        |> Submission.changeset(%{
          account_id: account_id,
          block_id: exam_block_id,
          cohort_id: cohort_id,
          status: :pending,
          expires_at: expires_at,
          content: content
        })
        |> Repo.insert()

      submission ->
        now = DateTime.utc_now()

        if submission.expires_at && DateTime.compare(now, submission.expires_at) == :gt do
          system_update_submission(submission, %{status: :time_limit_exceeded})
        else
          {:ok, submission}
        end
    end
  end

  @doc false
  defp get_ticket_usage(exam_block_id, cohort_id) do
    query =
      from s in Submission,
        where: s.block_id == ^exam_block_id and is_nil(s.parent_submission_id)

    query =
      if cohort_id do
        where(query, [s], s.cohort_id == ^cohort_id)
      else
        query
      end

    counts =
      query
      |> select([s], s.content)
      |> Repo.all()
      |> Enum.flat_map(&Map.get(&1 || %{}, "questions", []))
      |> Enum.map(fn q ->
        get_in(q, ["content", "original_block_id"]) || Map.get(q, "original_block_id")
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()

    TicketUsage.new(counts)
  end
end
