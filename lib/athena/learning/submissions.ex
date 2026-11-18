defmodule Athena.Learning.Submissions do
  @moduledoc """
  Internal business logic for Submission management.

  Handles creation, retrieval, and updates of student answers
  (submissions) for specific content blocks.
  """

  import Ecto.Query
  use Gettext, backend: AthenaWeb.Gettext
  alias Athena.{Repo, Content}
  alias Athena.Audit
  alias Athena.Content.{InteractionPolicy, ScoringRules}

  alias Athena.Learning.{
    Submission,
    Enrollment,
    Cohort,
    CohortMembership,
    Instructor,
    CohortInstructor,
    Progress,
    DraftCache,
    TestRunSession
  }

  alias Athena.Content.{Block, Section, TicketUsage}

  @doc """
  Lists submissions with pagination, filtering, and sorting using Flop.
  Enforces grading.read ACL through custom scoping.

  Omits `content`, which may contain large execution results or exam snapshots.
  Load an individual submission to retrieve its full content.
  """
  @spec list_submissions(map(), map()) ::
          {:ok, {[Submission.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_submissions(user, params \\ %{}) do
    query =
      Submission
      |> scope_submissions(user, "grading.read")
      |> maybe_exclude_daily_challenge(params)
      |> select([s], struct(s, ^(Submission.__schema__(:fields) -- [:content])))

    Flop.validate_and_run(query, params, for: Submission)
  end

  # Daily-challenge re-attempts (see Athena.Gamification.DailyChallenges) are
  # hidden from the default grading list so they don't clutter review of
  # first-time work – visible only when a caller explicitly filters on
  # `origin` (e.g. a teacher who wants to see them).
  defp maybe_exclude_daily_challenge(query, params) do
    if filters_on_origin?(params) do
      query
    else
      where(query, [s], s.origin != :daily_challenge)
    end
  end

  defp filters_on_origin?(%{"filters" => filters}) when is_list(filters) do
    Enum.any?(filters, &(Map.get(&1, "field") == "origin"))
  end

  defp filters_on_origin?(_params), do: false

  @doc """
  Flop custom filter (`in_cohort`): the submissions that belong to a cohort,
  which means two different things depending on its type -

    * a **team** shares one progress: a submission is the whole team's, and
      carries the team's id in `Submission.cohort_id`;
    * an academic **group** is just a set of students working on their own:
      their submissions have no `cohort_id` (see
      `list_group_submissions_for_block/2`), so the group's work is its
      members' individual submissions. A member's work for some team they
      are also on is not the group's.

  An unknown cohort id matches nothing.
  """
  def filter_in_cohort(query, %Flop.Filter{value: cohort_id}, _opts) when is_binary(cohort_id) do
    case Repo.get(Cohort, cohort_id) do
      %Cohort{type: :team} ->
        where(query, [s], s.cohort_id == ^cohort_id)

      %Cohort{} ->
        members =
          from(cm in CohortMembership, where: cm.cohort_id == ^cohort_id, select: cm.account_id)

        where(query, [s], s.account_id in subquery(members) and is_nil(s.cohort_id))

      nil ->
        where(query, [s], false)
    end
  end

  def filter_in_cohort(query, _filter, _opts), do: query

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
    test_run_account_ids = from(t in TestRunSession, select: t.ephemeral_account_id)

    base_query =
      query
      |> where([s], s.status != :draft)
      |> where([s], is_nil(s.parent_submission_id))
      |> where([s], fragment("?->>'is_test_run' IS NULL", s.content))
      # Instructor "test run" sessions (`Athena.Learning.TestRuns`) submit as a
      # throwaway account that gets purged shortly after – no point surfacing
      # that scratch data in the grading list before it's cleaned up.
      |> where([s], s.account_id not in subquery(test_run_account_ids))

    cond do
      "admin" in user.role.permissions ->
        base_query

      permission in user.role.permissions ->
        apply_permission_filter(base_query, user, permission)

      true ->
        where(base_query, [s], false)
    end
  end

  defp apply_permission_filter(query, user, permission) do
    policies = Map.get(user.role.policies || %{}, permission, [])

    if "own_only" in policies do
      scoped_own_only(query, user)
    else
      query
    end
  end

  defp scoped_own_only(query, user) do
    instructor_cohort_ids =
      from ci in CohortInstructor,
        join: i in Instructor,
        on: ci.instructor_id == i.id,
        where: i.owner_id == ^user.id,
        select: ci.cohort_id

    # "Mine" means the same as for reading cohorts: owned, or instructed.
    my_cohort_ids =
      from c in Cohort,
        where: c.owner_id == ^user.id or c.id in subquery(instructor_cohort_ids),
        select: c.id

    # An academic group's submissions carry no cohort_id (only a team's
    # shared work does), so a group's work is found through its members:
    # their own submissions, on the courses the group is enrolled in -
    # not whatever else those students do in other teachers' courses.
    my_group_students_work =
      from cm in CohortMembership,
        join: c in Cohort,
        on: c.id == cm.cohort_id,
        join: e in Enrollment,
        on: e.cohort_id == cm.cohort_id,
        where: c.type == :academic and c.id in subquery(my_cohort_ids),
        where:
          cm.account_id == parent_as(:submission).account_id and
            e.course_id == parent_as(:submission_section).course_id,
        select: 1

    my_course_ids = Content.list_accessible_course_ids(user)

    from(s in query, as: :submission)
    |> join(:inner, [s], b in Block, on: s.block_id == b.id)
    |> join(:inner, [s, b], sec in Section,
      on: b.section_id == sec.id,
      as: :submission_section
    )
    |> where(
      [s, b, sec],
      s.cohort_id in subquery(my_cohort_ids) or sec.course_id in ^my_course_ids or
        (is_nil(s.cohort_id) and exists(my_group_students_work))
    )
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
    |> order_by([s], desc: s.inserted_at, desc: s.id)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Creates a new submission, forces the account_id, and enqueues execution if it's a code block.
  If a draft exists for this block, updates it instead of creating a new record.
  Uses Ecto.Multi to guarantee that the job is queued ONLY if the submission is saved.
  Rejects a new attempt if this user/team already has a real, completed
  top-level attempt on this block graded at 100 points.
  """
  @spec create_submission(map(), map()) :: {:ok, Submission.t()} | {:error, any()}
  def create_submission(user, attrs) do
    changeset = Submission.changeset(%Submission{}, Map.put(attrs, "account_id", user.id))
    lock = submission_lock(changeset)

    cond do
      InteractionPolicy.block_readonly?(Map.get(attrs, "block_id")) ->
        {:error, :readonly}

      lock == :rejected ->
        {:error,
         Ecto.Changeset.add_error(
           changeset,
           :base,
           dgettext(
             "errors",
             "New submissions are blocked because an earlier submission was rejected."
           ),
           validation: :submission_rejected
         )}

      lock == :passed ->
        {:error,
         Ecto.Changeset.add_error(
           changeset,
           :base,
           dgettext("errors", "This block has already been solved with 100 points."),
           validation: :already_solved
         )}

      true ->
        do_create_submission(user, attrs)
    end
  end

  defp submission_lock(%{valid?: false}), do: nil

  defp submission_lock(changeset) do
    block_id = Ecto.Changeset.get_field(changeset, :block_id)
    account_id = Ecto.Changeset.get_field(changeset, :account_id)
    cohort_id = Ecto.Changeset.get_field(changeset, :cohort_id)

    Map.get(submission_locks(account_id, [block_id], cohort_id), block_id)
  end

  @doc "Submission restrictions, separate from which attempt is shown. Loads no content."
  def submission_locks(account_id, block_ids, cohort_id \\ nil) do
    from(s in Submission,
      where:
        s.block_id in ^block_ids and is_nil(s.parent_submission_id) and s.origin == :regular and
          (s.status == :rejected or (s.score == 100 and s.status in [:graded, :accepted])),
      where: fragment("?->>'is_test_run' IS NULL", s.content),
      order_by: [asc: s.block_id, desc: fragment("? = 'rejected'", s.status)],
      distinct: s.block_id,
      select: {s.block_id, s.status}
    )
    |> where_owner(account_id, cohort_id)
    |> Repo.all()
    |> Map.new(fn {id, status} -> {id, if(status == :rejected, do: :rejected, else: :passed)} end)
  end

  defp do_create_submission(user, attrs) do
    safe_attrs = Map.put(attrs, "account_id", user.id)
    block_id = Map.get(attrs, "block_id")
    cohort_id = Map.get(attrs, "cohort_id")

    Ecto.Multi.new()
    |> Ecto.Multi.run(:draft, fn _repo, _changes ->
      lock_draft(user.id, cohort_id, block_id)
      {:ok, find_draft(user.id, block_id, cohort_id)}
    end)
    |> Ecto.Multi.run(:submission, fn _repo, %{draft: existing_draft} ->
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
      {:ok, %{submission: submission, draft: draft}} ->
        {:ok, submission}
        |> Audit.on_ok(
          "submission.submitted",
          &[
            submission_id: &1.id,
            block_id: &1.block_id,
            cohort_id: &1.cohort_id,
            account_id: &1.account_id,
            status: &1.status,
            resubmit: not is_nil(draft)
          ]
        )

      {:error, _failed_op, changeset, _changes} ->
        {:error, changeset}
    end
  end

  @doc """
  Enqueues the code execution worker for a specific submission.
  Updates the status to :processing immediately.
  Works for both regular blocks and generated exam questions.
  """
  def enqueue_code_execution(%Submission{} = submission) do
    block_id =
      if submission.parent_submission_id do
        Repo.one(
          from(s in Submission,
            where: s.id == ^submission.parent_submission_id,
            select: s.block_id
          )
        )
      else
        submission.block_id
      end

    if InteractionPolicy.block_readonly?(block_id) do
      {:error, :readonly}
    else
      enqueue_writable_code(submission)
    end
  end

  defp enqueue_writable_code(submission) do
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
  def test_code(user, block, code, opts \\ []) do
    content = %{"type" => :code, "code" => code, "is_test_run" => true}

    case save_draft(user, block.id, content, Keyword.get(opts, :cohort_id), opts) do
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
    # `scope_submissions/3` only ever matches top-level submissions, so an
    # exam question's child submission is authorized through its parent -
    # the instructor who may grade the exam may grade its questions.
    root_id = submission.parent_submission_id || submission.id

    has_access? =
      Submission
      |> where([s], s.id == ^root_id)
      |> scope_submissions(user, "grading.update")
      |> Repo.exists?()

    if has_access? do
      submission
      |> system_update_submission(attrs)
      |> Audit.on_ok(
        "submission.graded_by_instructor",
        &[
          submission_id: &1.id,
          block_id: &1.block_id,
          account_id: &1.account_id,
          status: &1.status,
          score: &1.score,
          by: user.id
        ]
      )
    else
      Audit.warning("submission.grade_refused", submission_id: submission.id, by: user.id)
      {:error, :forbidden}
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
  Finalizes an exam/ticket attempt whose time limit has run out.

  Auto-grades it exactly as a voluntary submit would (correct/incorrect
  questions scored, essays and file/code answers flagged for review), then
  stamps the final status as `:time_limit_exceeded` instead of
  `:graded`/`:needs_review` - so the student sees *why* it ended, while
  their score is still computed and visible instead of hidden behind a bare
  "time's up". An instructor can still open it from the grading queue
  (unfiltered, since it's no longer `:needs_review`) and grade it by hand;
  that later update overwrites this one same as any other regrade.

  Idempotent: called both here (when a student returns to an exam whose
  clock already ran out) and by the Exam/Ticket LiveViews (when the clock
  hits zero while they're on the page) - by the second call the submission
  is no longer `:pending`, so it's returned unchanged.
  """
  def finalize_expired_exam(%Submission{status: :pending} = submission) do
    eval_results = Athena.Learning.Evaluator.evaluate_sync(submission)
    system_update_submission(submission, Map.put(eval_results, :status, :time_limit_exceeded))
  end

  def finalize_expired_exam(%Submission{} = submission), do: {:ok, submission}

  @doc """
  Gets the attempt that counts for each of `block_ids`, scoped by cohort or
  user. Excludes draft submissions.

  The most recent real submission wins, ordered by submission time and id.
  Grades and later instructor edits never change an attempt's precedence.
  """
  @spec get_latest_submissions(String.t(), [String.t()], String.t() | nil) :: %{
          String.t() => Submission.t()
        }
  def get_latest_submissions(account_id, block_ids, cohort_id \\ nil, opts \\ []) do
    from(s in Submission,
      where: s.block_id in ^block_ids and s.status != :draft,
      where: is_nil(s.parent_submission_id) and s.origin == :regular,
      where: fragment("?->>'is_test_run' IS NULL", s.content)
    )
    |> where_owner(account_id, cohort_id)
    |> project_readonly_code(Keyword.get(opts, :readonly_code_ids, []))
    |> distinct([s], s.block_id)
    |> order_by([s], ^attempt_precedence())
    |> Repo.all()
    |> Map.new(&{&1.block_id, &1})
  end

  # Extract only the submitted code inside PostgreSQL. Removing results after
  # Repo.all/1 would already have decoded the oversized JSON into BEAM memory.
  defp project_readonly_code(query, []), do: query

  defp project_readonly_code(query, ids) do
    select_merge(query, [s], %{
      content:
        fragment(
          "CASE WHEN ? THEN jsonb_build_object('type', ?->'type', 'code', ?->'code', 'text_answer', ?->'text_answer') ELSE ? END",
          s.block_id in ^ids,
          s.content,
          s.content,
          s.content,
          s.content
        )
    })
  end

  # Shared by the player and its feedback, so both always refer to one attempt.
  defp attempt_precedence do
    [asc: dynamic([s], s.block_id), desc: dynamic([s], s.inserted_at), desc: dynamic([s], s.id)]
  end

  @doc """
  Collects instructor feedback per block for the student-facing player.

  Picks the **same** attempt `get_latest_submissions/3` does (see
  `attempt_precedence/0`), because that is the attempt whose score the
  player shows. Choosing independently - this used to take the most
  recently updated attempt carrying a comment - meant a regrade that
  lowered a score left the student reading the new comment above the old,
  higher number, with no way to tell they described different attempts.

  An exam's per-question breakdown comes with the attempt once it is
  finished, whether or not the instructor wrote anything: correcting a
  single question's score is a grading act the student has to be able to
  see, and it carries no comment of its own.

  Returns `%{block_id => %{feedback: String.t() | nil, status: atom(),
  questions: [%{number: pos_integer() | nil, feedback: String.t() | nil,
  score: integer() | nil}]}}`, with only the blocks that have something to
  show - so `Map.has_key?/2` is the test for "render the feedback card".
  """
  @spec get_feedback_map(String.t(), [String.t()], String.t() | nil) :: %{String.t() => map()}
  def get_feedback_map(account_id, block_ids, cohort_id \\ nil)

  def get_feedback_map(_account_id, [], _cohort_id), do: %{}

  def get_feedback_map(account_id, block_ids, cohort_id) do
    parents =
      from(s in Submission)
      |> where([s], s.block_id in ^block_ids and s.status != :draft)
      |> where([s], is_nil(s.parent_submission_id))
      |> where([s], s.origin == :regular)
      |> where([s], fragment("?->>'is_test_run' IS NULL", s.content))
      |> where_owner(account_id, cohort_id)
      |> distinct([s], s.block_id)
      |> order_by([s], ^attempt_precedence())
      |> select([s], %Submission{
        id: s.id,
        block_id: s.block_id,
        status: s.status,
        feedback: s.feedback,
        content: fragment("jsonb_build_object('questions', ?->'questions')", s.content)
      })
      |> Repo.all()

    children_by_parent =
      from(c in Submission,
        where: c.parent_submission_id in ^Enum.map(parents, & &1.id),
        select: struct(c, [:id, :parent_submission_id, :block_id, :score, :feedback])
      )
      |> Repo.all()
      |> Enum.group_by(& &1.parent_submission_id)

    parents
    |> Enum.map(fn parent ->
      children = Map.get(children_by_parent, parent.id, [])

      {parent.block_id,
       %{
         feedback: if(parent.feedback in [nil, ""], do: nil, else: parent.feedback),
         status: parent.status,
         questions: question_feedback(parent, children)
       }}
    end)
    |> Enum.reject(fn {_block_id, entry} ->
      is_nil(entry.feedback) and entry.questions == []
    end)
    |> Map.new()
  end

  defp where_owner(query, _account_id, cohort_id) when not is_nil(cohort_id),
    do: where(query, [s], s.cohort_id == ^cohort_id)

  defp where_owner(query, account_id, nil),
    do: where(query, [s], s.account_id == ^account_id and is_nil(s.cohort_id))

  # Orders child feedback by the question's position in the attempt, so the
  # student can match "Question 3" to what they saw in the exam.
  #
  # An unfinished attempt reports nothing: mid-exam, every unanswered
  # question still sits at the schema's default score of 0, and a column of
  # zeroes is not a result. Once it is finished the breakdown is complete -
  # every question, scored, commented or not - which is what makes a
  # score-only correction by the instructor visible at all.
  @finished_statuses [:graded, :needs_review, :rejected, :time_limit_exceeded]

  defp question_feedback(_parent, []), do: []

  defp question_feedback(%{status: status}, _children) when status not in @finished_statuses,
    do: []

  defp question_feedback(parent, children) do
    order =
      (parent.content["questions"] || [])
      |> Enum.map(fn q -> q["id"] || q[:id] end)
      |> Enum.with_index(1)
      |> Map.new()

    children
    |> Enum.map(fn c ->
      %{
        number: Map.get(order, c.block_id),
        feedback: if(c.feedback in [nil, ""], do: nil, else: c.feedback),
        score: c.score
      }
    end)
    |> Enum.sort_by(&(&1.number || 999_999))
  end

  @doc """
  Ranks a competition's teams.

  Each team's score is the sum of what their best attempt at every block
  earned them; `Athena.Content.ScoringRules` decides what a block is worth
  and how equal totals are settled, with the course's `scoring` (or `nil`,
  meaning the defaults) as the rulebook. Teams with any rejected
  submission are disqualified and sink to the bottom, unless the rules say
  otherwise.

  The rows are shaped for direct rendering - see
  `AthenaWeb.LeaderboardComponents.board_table/1`.
  """
  @spec get_team_leaderboard(String.t()) :: [map()]
  def get_team_leaderboard(course_id) do
    scoring =
      from(c in Athena.Content.Course, where: c.id == ^course_id, select: c.scoring)
      |> Repo.one()

    get_team_leaderboard(course_id, scoring)
  end

  @doc """
  `get_team_leaderboard/1` against an explicit rulebook.

  The arithmetic and the ordering happen here rather than in SQL. A
  dynamic block value is a course-wide aggregate that then multiplies
  every team's row, which in SQL means writing the decay formula a second
  time (and a configurable ORDER BY over a computed sum); in Elixir it is
  `ScoringRules.points/4`, testable on its own. The cost is already
  settled by `Athena.Learning.LeaderboardCache` - the board is computed at
  most once per cache window per course, over at most `teams × blocks`
  rows.
  """
  @spec get_team_leaderboard(String.t(), ScoringRules.t() | nil) :: [map()]
  def get_team_leaderboard(course_id, scoring) do
    rules = ScoringRules.resolve(scoring)

    latest_rows = latest_attempt_per_block(course_id)
    solves = solves_per_block(latest_rows, rules)
    first_bloods = first_bloods_per_team(latest_rows, rules)
    attempts = team_attempt_counts(course_id)

    course_id
    |> competing_teams()
    |> Enum.map(&build_team_row(&1, latest_rows, solves, first_bloods, attempts, rules))
    |> order_teams(rules)
  end

  # Choose the latest submission before interpreting its status/score. A
  # pending latest attempt must not fall back to an earlier, graded score.
  defp latest_attempt_per_block(course_id) do
    from(s in Submission,
      join: b in Block,
      on: s.block_id == b.id,
      join: sec in Section,
      on: b.section_id == sec.id,
      where:
        not is_nil(s.cohort_id) and sec.course_id == ^course_id and
          s.status != :draft and is_nil(s.parent_submission_id) and s.origin == :regular,
      where: fragment("?->>'is_test_run' IS NULL", s.content),
      distinct: [s.cohort_id, s.block_id],
      order_by: [s.cohort_id, s.block_id, desc: s.inserted_at, desc: s.id],
      select: %{
        cohort_id: s.cohort_id,
        block_id: s.block_id,
        block_points: b.points,
        status: s.status,
        score: s.score,
        inserted_at: s.inserted_at
      }
    )
    |> Repo.all()
    |> Enum.map(fn row ->
      scored? =
        row.status in [
          :graded,
          :accepted,
          :wrong_answer,
          :time_limit_exceeded,
          :memory_limit_exceeded,
          :runtime_error,
          :compilation_error
        ] and is_integer(row.score)

      row |> Map.put(:score, if(scored?, do: row.score, else: 0)) |> Map.put(:scored?, scored?)
    end)
  end

  # How many teams have solved each block, from the same rows the points
  # are computed from - so the threshold lives in one place and the two can
  # never disagree.
  defp solves_per_block(latest_rows, rules) do
    latest_rows
    |> Enum.filter(&(&1.scored? and ScoringRules.solve?(rules, &1.score)))
    |> Enum.frequencies_by(& &1.block_id)
  end

  # First solves among the same latest attempts used for points.
  defp first_bloods_per_team(latest_rows, rules) do
    latest_rows
    |> Enum.filter(&(&1.scored? and ScoringRules.solve?(rules, &1.score)))
    |> Enum.group_by(& &1.block_id)
    |> Enum.map(fn {_block_id, rows} ->
      rows
      |> Enum.min_by(&{DateTime.to_unix(&1.inserted_at), &1.cohort_id})
      |> Map.fetch!(:cohort_id)
    end)
    |> Enum.frequencies()
  end

  defp team_attempt_counts(course_id) do
    from(s in Submission,
      join: b in Block,
      on: s.block_id == b.id,
      join: sec in Section,
      on: b.section_id == sec.id,
      where:
        not is_nil(s.cohort_id) and sec.course_id == ^course_id and s.status != :draft and
          is_nil(s.parent_submission_id) and s.origin == :regular,
      where: fragment("?->>'is_test_run' IS NULL", s.content),
      group_by: s.cohort_id,
      select:
        {s.cohort_id,
         %{
           attempts: count(s.id),
           rejected?: fragment("count(case when ? = 'rejected' then 1 end) > 0", s.status)
         }}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp competing_teams(course_id) do
    from(e in Enrollment,
      join: c in Cohort,
      on: e.cohort_id == c.id,
      where: e.course_id == ^course_id and c.type == :team,
      select: %{team_id: c.id, team_name: c.name}
    )
    |> Repo.all()
  end

  defp build_team_row(team, latest_rows, solves, first_bloods, attempts, rules) do
    rows = Enum.filter(latest_rows, &(&1.cohort_id == team.team_id))

    block_points =
      Map.new(rows, fn row ->
        {row.block_id,
         ScoringRules.points(
           rules,
           row.block_points,
           Map.get(solves, row.block_id, 0),
           row.score
         )}
      end)

    counts = Map.get(attempts, team.team_id, %{attempts: 0, rejected?: false})

    %{
      team_id: team.team_id,
      team_name: team.team_name,
      total_score: block_points |> Map.values() |> Enum.sum(),
      block_points: block_points,
      last_activity: rows |> Enum.map(& &1.inserted_at) |> latest(),
      attempts: counts.attempts,
      first_bloods: Map.get(first_bloods, team.team_id, 0),
      is_disqualified: rules.disqualify_on_rejected and counts.rejected?
    }
  end

  defp latest([]), do: nil
  defp latest(timestamps), do: Enum.max_by(timestamps, &DateTime.to_unix/1)

  # Disqualified last, then by score, then by the author's chosen
  # tiebreakers in their chosen order. With the default `[:time,
  # :attempts]` the key is term-for-term the ORDER BY this replaced.
  defp order_teams(rows, rules) do
    Enum.sort_by(rows, fn row ->
      List.to_tuple([
        if(row.is_disqualified, do: 1, else: 0),
        -row.total_score | Enum.map(rules.tiebreakers, &tiebreaker_key(&1, row))
      ])
    end)
  end

  # `{1, 0}` for a missing timestamp keeps teams who have never submitted
  # at the back, the way Postgres' `ASC NULLS LAST` did.
  defp tiebreaker_key(:time, %{last_activity: nil}), do: {1, 0}
  defp tiebreaker_key(:time, row), do: {0, DateTime.to_unix(row.last_activity)}
  defp tiebreaker_key(:attempts, row), do: row.attempts
  defp tiebreaker_key(:first_blood, row), do: -row.first_bloods

  @doc """
  For every member of an academic cohort, returns their most recent
  top-level (non-child) submission for a given block, keyed by
  `account_id` - `nil` for members who haven't started yet. Used by
  `AthenaWeb.TeachingLive.GradingMonitor` to build its group-wide
  cheating-monitor table.

  Deliberately does not filter on `s.cohort_id` - see the note on
  `Athena.Learning.Enrollments.get_academic_cohort_for_course/2`:
  `Submission.cohort_id` is only ever populated for `:team` cohorts, so
  "this group's submissions" has to be found by joining the group's
  members (`CohortMembership`) to their submissions directly.
  """
  @spec list_group_submissions_for_block(binary(), binary()) :: %{
          binary() => Submission.t() | nil
        }
  def list_group_submissions_for_block(cohort_id, block_id) do
    member_ids_query =
      from cm in CohortMembership, where: cm.cohort_id == ^cohort_id, select: cm.account_id

    submissions_by_account =
      from(s in Submission,
        where:
          s.block_id == ^block_id and s.account_id in subquery(member_ids_query) and
            is_nil(s.parent_submission_id),
        distinct: s.account_id,
        order_by: [asc: s.account_id, desc: s.inserted_at]
      )
      |> Repo.all()
      |> Map.new(&{&1.account_id, &1})

    member_ids_query
    |> Repo.all()
    |> Map.new(&{&1, Map.get(submissions_by_account, &1)})
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
      {:error, :forbidden}
    end
  end

  @doc """
  Saves a draft submission. Creates or updates existing draft.
  Caches in Cachex for fast access, stores in DB for persistence.
  For team submissions, broadcasts update to all team members.
  """
  @spec save_draft(map(), String.t(), map(), String.t() | nil) ::
          {:ok, Submission.t()} | {:error, Ecto.Changeset.t() | :readonly}
  def save_draft(user, block_id, content, cohort_id \\ nil, opts \\ []) do
    if InteractionPolicy.block_readonly?(block_id) do
      {:error, :readonly}
    else
      with_draft_lock(user.id, cohort_id, block_id, fn ->
        save_current_draft(user, block_id, content, cohort_id, Keyword.get(opts, :revision))
      end)
    end
  end

  defp save_current_draft(user, block_id, content, cohort_id, revision) do
    if current_draft_revision?(user.id, cohort_id, block_id, revision) do
      do_save_draft(user, block_id, content, cohort_id)
    else
      {:error, :stale_draft}
    end
  end

  @doc "Deletes only the caller's draft, leaving all submitted attempts and progress intact."
  def discard_draft(user, block_id, cohort_id \\ nil, opts \\ []) do
    with {:ok, block} <- Content.get_block_header(block_id),
         {:ok, section} <- Content.get_section(block.section_id),
         true <- draft_access?(user.id, section),
         true <- draft_owner?(user.id, cohort_id),
         false <- InteractionPolicy.block_readonly?(block_id) do
      result =
        with_draft_lock(user.id, cohort_id, block_id, fn ->
          discard_locked_draft(user, block_id, cohort_id, Keyword.get(opts, :revision))
        end)

      case result do
        {:ok, revision} ->
          DraftCache.broadcast_reset(user.id, cohort_id, block_id, revision)
          {:ok, revision}

        error ->
          error
      end
    else
      _ -> {:error, :forbidden}
    end
  end

  defp draft_access?(account_id, section) do
    Athena.Learning.has_access?(account_id, section.course_id) or
      Repo.exists?(
        from(t in TestRunSession,
          where:
            t.ephemeral_account_id == ^account_id and t.course_id == ^section.course_id and
              t.section_id == ^section.id and t.status == :active and
              t.expires_at > ^DateTime.utc_now()
        )
      )
  end

  defp discard_locked_draft(user, block_id, cohort_id, revision) do
    attempts =
      from(s in Submission,
        where:
          s.block_id == ^block_id and s.status != :draft and s.origin == :regular and
            is_nil(s.parent_submission_id),
        where: fragment("?->>'is_test_run' IS NULL", s.content)
      )
      |> where_owner(user.id, cohort_id)

    drafts =
      draft_query([block_id], user.id, cohort_id)
      |> where([s], is_nil(s.parent_submission_id))

    ids = drafts |> select([s], s.id) |> Repo.all()

    active_jobs =
      from(j in Oban.Job,
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        where: fragment("?->>'submission_id'", j.args) in ^ids
      )

    cond do
      not current_draft_revision?(user.id, cohort_id, block_id, revision) ->
        {:error, :stale_draft}

      not Repo.exists?(attempts) ->
        {:error, :no_submission}

      Repo.exists?(active_jobs) ->
        {:error, :processing}

      true ->
        Repo.delete_all(drafts)
        DraftCache.clear_draft(user.id, cohort_id, block_id)
        {:ok, DraftCache.rotate_revision(user.id, cohort_id, block_id)}
    end
  end

  defp draft_owner?(_account_id, nil), do: true

  defp draft_owner?(account_id, cohort_id),
    do:
      Repo.exists?(
        from(m in CohortMembership,
          where: m.account_id == ^account_id and m.cohort_id == ^cohort_id
        )
      )

  defp current_draft_revision?(_account_id, _cohort_id, _block_id, nil), do: true

  defp current_draft_revision?(account_id, cohort_id, block_id, revision),
    do: DraftCache.revision(account_id, cohort_id, block_id) == revision

  defp lock_draft(account_id, cohort_id, block_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "draft:#{cohort_id || account_id}:#{block_id}"
    ])
  end

  defp with_draft_lock(account_id, cohort_id, block_id, fun) do
    Repo.transaction(fn ->
      lock_draft(account_id, cohort_id, block_id)
      fun.()
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_save_draft(user, block_id, content, cohort_id) do
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
  Batch form of `get_draft/3`: the draft content of every block in
  `block_ids` that has one, as `%{block_id => content}`. Cache hits are
  served from Cachex; all misses are read in a single query (and cached).
  """
  @spec get_drafts(String.t(), [String.t()], String.t() | nil) :: %{String.t() => map()}
  def get_drafts(user_id, block_ids, cohort_id \\ nil) do
    {cached, missing} =
      Enum.reduce(block_ids, {%{}, []}, fn block_id, {cached, missing} ->
        case DraftCache.get_draft(user_id, cohort_id, block_id) do
          nil -> {cached, [block_id | missing]}
          content -> {Map.put(cached, block_id, content), missing}
        end
      end)

    missing
    |> find_drafts(user_id, cohort_id)
    |> Enum.reduce(cached, fn submission, acc ->
      DraftCache.save_draft(user_id, cohort_id, submission.block_id, submission.content)
      Map.put(acc, submission.block_id, submission.content)
    end)
  end

  defp find_drafts([], _user_id, _cohort_id), do: []

  defp find_drafts(block_ids, user_id, cohort_id) do
    block_ids
    |> draft_query(user_id, cohort_id)
    |> distinct([s], s.block_id)
    |> order_by([s], asc: s.block_id, desc: s.updated_at)
    |> Repo.all()
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

  @doc "Whether a test-run broadcast still belongs to a persisted draft."
  def current_draft?(user_id, block_id, cohort_id, id) do
    draft_query([block_id], user_id, cohort_id) |> where([s], s.id == ^id) |> Repo.exists?()
  end

  @doc false
  defp find_draft(_user_id, nil, _cohort_id), do: nil

  defp find_draft(user_id, block_id, cohort_id) do
    [block_id]
    |> draft_query(user_id, cohort_id)
    |> order_by([s], desc: s.updated_at)
    |> limit(1)
    |> Repo.one()
  end

  defp draft_query(block_ids, user_id, cohort_id) do
    if cohort_id do
      from s in Submission,
        where:
          s.cohort_id == ^cohort_id and s.block_id in ^block_ids and
            (s.status == :draft or fragment("?->>'is_test_run' = 'true'", s.content))
    else
      from s in Submission,
        where:
          s.account_id == ^user_id and s.block_id in ^block_ids and
            (s.status == :draft or fragment("?->>'is_test_run' = 'true'", s.content)) and
            is_nil(s.cohort_id)
    end
  end

  @doc """
  Starts a new exam submission attempt for a student.
  Creates a parent submission with an expiration time.
  """
  def start_exam_submission(account_id, exam_block_id, cohort_id, time_limit_seconds) do
    if InteractionPolicy.block_readonly?(exam_block_id) do
      {:error, :readonly}
    else
      start_writable_exam_submission(account_id, exam_block_id, cohort_id, time_limit_seconds)
    end
  end

  defp start_writable_exam_submission(account_id, exam_block_id, cohort_id, time_limit_seconds) do
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
    |> Audit.on_ok(
      "exam.started",
      &[
        submission_id: &1.id,
        block_id: &1.block_id,
        cohort_id: &1.cohort_id,
        account_id: &1.account_id,
        expires_at: &1.expires_at
      ]
    )
  end

  @doc """
  Saves or updates a submission for a specific question/block within an exam.
  Links it to the parent exam submission. Rejects writes once the parent's
  time limit has passed - use `system_save_question_submission/5` for
  system-driven writes (e.g. auto-filling blanks while finalizing a timed-out
  exam) that must go through even though the clock has run out.
  """
  def save_question_submission(
        parent_submission,
        account_id,
        question_block_id,
        cohort_id,
        answer_content
      ) do
    if InteractionPolicy.block_readonly?(parent_submission.block_id) do
      {:error, :readonly}
    else
      save_writable_question(
        parent_submission,
        account_id,
        question_block_id,
        cohort_id,
        answer_content
      )
    end
  end

  defp save_writable_question(
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

    if limit_check == :gt do
      Audit.warning("exam.answer_rejected",
        submission_id: parent_submission.id,
        block_id: question_block_id,
        account_id: account_id,
        reason: :time_limit_exceeded
      )

      {:error, :time_limit_exceeded}
    else
      system_save_question_submission(
        parent_submission,
        account_id,
        question_block_id,
        cohort_id,
        answer_content
      )
    end
  end

  @doc """
  Same as `save_question_submission/5`, but bypasses the exam's time-limit
  check. For system-driven writes only - e.g. `Evaluator` auto-filling blank
  answers for unanswered questions while finalizing a timed-out exam, after
  the deadline has already passed.
  """
  def system_save_question_submission(
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
  Routes to either `quiz_exam` or `ticket_exam` generator logic based on `block_type`
  (both may carry a `"slots"` config, so the block's own type is the source of truth).

  Returns `{:already_completed, submission}` instead of creating a fresh attempt
  when the student's last one is already finished (graded, rejected, needs
  review, or timed out) - exams are one attempt per student by design, and
  without this check, simply pressing "back" in the browser
  after finishing would `mount/3` this LiveView again and silently hand out
  a brand new attempt with a fresh set of questions. A real retake already
  has a path: an instructor deletes the finished submission from the
  grading screen (`delete_submission_with_rollback/2`), which removes the
  row entirely, so the next mount finds nothing and starts clean.
  """
  @spec get_or_create_exam_attempt(
          String.t(),
          String.t(),
          String.t(),
          atom(),
          String.t() | nil,
          integer(),
          map()
        ) ::
          {:ok, Submission.t()}
          | {:already_completed, Submission.t()}
          | {:taken_by_teammate, Submission.t()}
          | {:error, any()}
  def get_or_create_exam_attempt(
        course_id,
        account_id,
        exam_block_id,
        block_type,
        cohort_id,
        time_limit_sec,
        exam_config
      ) do
    case fetch_or_create_exam_attempt(
           course_id,
           account_id,
           exam_block_id,
           block_type,
           cohort_id,
           time_limit_sec,
           exam_config
         ) do
      {change, submission} when change in [:created, :existing, :finalized] -> {:ok, submission}
      other -> other
    end
  end

  @doc """
  Like `get_or_create_exam_attempt/7`, but says what happened to the
  attempt: `{:created, sub}` (new attempt), `{:existing, sub}` (an attempt
  in progress, now this member's to continue) or `{:finalized, sub}` (an
  expired attempt just scored). Lets the caller announce only real
  changes.

  `{:taken_by_teammate, sub}` is the team case: a competition team sits
  one attempt between them, so while the member who started it is still
  there, the rest get this instead of a paper of their own.
  """
  @spec fetch_or_create_exam_attempt(
          String.t(),
          String.t(),
          String.t(),
          atom(),
          String.t() | nil,
          integer(),
          map()
        ) ::
          {:created | :existing | :finalized | :already_completed | :taken_by_teammate,
           Submission.t()}
          | {:error, any()}
  def fetch_or_create_exam_attempt(
        course_id,
        account_id,
        exam_block_id,
        block_type,
        cohort_id,
        time_limit_sec,
        exam_config
      )

  # Individual attempts cannot collide with anyone, so they stay on the
  # plain path. A team's single attempt can: two members pressing Start in
  # the same instant would each find nothing and each create one. An
  # advisory lock on (team, block) serializes exactly that pair; a partial
  # unique index could not be used instead, because several top-level rows
  # per (cohort_id, block_id) is the normal, required shape for every
  # other block type - that is what resubmits are.
  def fetch_or_create_exam_attempt(course_id, account_id, block_id, type, nil, limit, config),
    do: do_fetch_or_create_exam_attempt(course_id, account_id, block_id, type, nil, limit, config)

  def fetch_or_create_exam_attempt(
        course_id,
        account_id,
        block_id,
        type,
        cohort_id,
        limit,
        config
      ) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "exam_attempt:#{cohort_id}:#{block_id}"
      ])

      do_fetch_or_create_exam_attempt(
        course_id,
        account_id,
        block_id,
        type,
        cohort_id,
        limit,
        config
      )
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_fetch_or_create_exam_attempt(
         course_id,
         account_id,
         exam_block_id,
         block_type,
         cohort_id,
         time_limit_sec,
         exam_config
       ) do
    if InteractionPolicy.block_readonly?(exam_block_id) do
      {:error, :readonly}
    else
      fetch_writable_exam_attempt(
        course_id,
        account_id,
        exam_block_id,
        block_type,
        cohort_id,
        time_limit_sec,
        exam_config
      )
    end
  end

  defp fetch_writable_exam_attempt(
         course_id,
         account_id,
         exam_block_id,
         block_type,
         cohort_id,
         time_limit_sec,
         exam_config
       ) do
    case get_last_exam_submission(account_id, exam_block_id, cohort_id) do
      nil ->
        is_ticket = block_type == :ticket_exam

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
          "type" => type
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
        |> reload_attempt()
        |> heartbeat_attempt()
        |> tag_ok(:created)

      %{status: status} = submission when status in [:pending, :draft] ->
        resume_exam_attempt(submission, account_id, cohort_id)

      finished_submission ->
        {:already_completed, finished_submission}
    end
  end

  # Reopening an attempt in progress. For a team that is the moment the
  # exam is either someone else's to finish or free to take over: one
  # paper, one timer, one result for everyone.
  defp resume_exam_attempt(submission, account_id, cohort_id) do
    now = DateTime.utc_now()

    cond do
      submission.expires_at && DateTime.compare(now, submission.expires_at) == :gt ->
        # An expired attempt is closed by whoever turns up - including a
        # teammate, so a holder who vanished mid-exam cannot leave the
        # team with a result nobody can collect.
        submission |> finalize_expired_exam() |> tag_ok(:finalized)

      is_nil(cohort_id) or submission.account_id == account_id ->
        touch_exam_heartbeat(submission.id)
        {:existing, submission}

      exam_lock_held?(submission, now) ->
        {:taken_by_teammate, submission}

      true ->
        hand_over_exam_attempt(submission, account_id)
    end
  end

  # The holder went away (their page closed, or their heartbeat went
  # stale) and a teammate picked the exam up. The row stays the team's;
  # `account_id` only ever meant "who is driving", so moving it keeps the
  # lock label, the grading screen and the audit trail honest about who
  # actually sat the rest of it.
  defp hand_over_exam_attempt(submission, account_id) do
    previous_holder = submission.account_id

    submission
    |> Ecto.Changeset.change(%{
      account_id: account_id,
      heartbeat_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        Audit.event("exam_attempt.handover",
          submission_id: updated.id,
          block_id: updated.block_id,
          cohort_id: updated.cohort_id,
          from: previous_holder,
          to: account_id
        )

        {:existing, updated}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp heartbeat_attempt({:ok, submission}) do
    touch_exam_heartbeat(submission.id)
    {:ok, %{submission | heartbeat_at: DateTime.utc_now() |> DateTime.truncate(:second)}}
  end

  defp heartbeat_attempt(error), do: error

  # The generated questions are `%Block{}` structs, and `Repo.insert/1`
  # hands back the value it was given rather than what the database now
  # holds - so without this the attempt's `content["questions"]` stays a
  # list of structs in memory while every later reader (and the evaluator,
  # which does `q["id"]`) expects the plain maps JSON round-tripping
  # produces. Normally the exam page is reached through the player, which
  # re-reads the row and hid this; opening the exam URL directly did not.
  defp reload_attempt({:ok, submission}), do: {:ok, Repo.reload!(submission)}
  defp reload_attempt(error), do: error

  defp tag_ok({:ok, submission}, tag), do: {tag, submission}
  defp tag_ok(error, _tag), do: error

  # A team's exam attempt belongs to the team, not to whoever started it,
  # so with a `cohort_id` the author is deliberately not part of the
  # lookup - the same rule as `where_owner/3` and `Progress`.
  #
  # Legacy teams can have multiple attempts. Resume/show the same latest
  # attempt as the player, independently of its score.
  @doc false
  defp get_last_exam_submission(account_id, exam_block_id, cohort_id) do
    from(s in Submission,
      where: s.block_id == ^exam_block_id,
      where: is_nil(s.parent_submission_id)
    )
    |> exam_attempt_owner(account_id, cohort_id)
    |> order_by([s], desc: s.inserted_at, desc: s.id)
    |> limit(1)
    |> Repo.one()
  end

  # Not `where_owner/3`: an academic-cohort student's row carries a
  # `cohort_id` while the callers pass `team_id` (nil for them), so
  # demanding `cohort_id IS NULL` would hand them a brand new attempt on
  # every page load.
  defp exam_attempt_owner(query, _account_id, cohort_id) when is_binary(cohort_id),
    do: where(query, [s], s.cohort_id == ^cohort_id)

  defp exam_attempt_owner(query, account_id, nil),
    do: where(query, [s], s.account_id == ^account_id)

  @default_exam_lock_idle_ms 120_000

  @doc """
  How long a team's exam attempt stays locked to the member sitting it
  after their last heartbeat, in ms.

  The holder's page normally releases the lock the moment it closes; this
  is the fallback for the cases that never get to run that - a crashed
  browser, a dead node, a connection that simply stopped. Read at runtime
  so it can differ per environment.
  """
  @spec exam_lock_idle_ms() :: non_neg_integer()
  def exam_lock_idle_ms do
    :athena
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:exam_lock_idle_ms, @default_exam_lock_idle_ms)
  end

  @doc """
  Whether `submission`'s exam lock is still held by the member sitting it.

  A released (`heartbeat_at: nil`) or stale attempt is free for any
  teammate to take over.
  """
  @spec exam_lock_held?(Submission.t(), DateTime.t()) :: boolean()
  def exam_lock_held?(%Submission{heartbeat_at: nil}, _now), do: false

  def exam_lock_held?(%Submission{heartbeat_at: beat}, now),
    do: DateTime.diff(now, beat, :millisecond) < exam_lock_idle_ms()

  @doc """
  Records that the member sitting `submission_id` is still there.

  Deliberately an `update_all`: no changeset, no `updated_at` bump and no
  broadcast, so an exam page can call it on a timer without waking every
  teammate's player.
  """
  @spec touch_exam_heartbeat(String.t()) :: :ok
  def touch_exam_heartbeat(submission_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Submission
    |> where([s], s.id == ^submission_id)
    |> Repo.update_all(set: [heartbeat_at: now])

    :ok
  end

  @doc """
  Releases the exam lock on `submission_id` so a teammate can take the
  attempt over - what the holder's page does when it closes without
  finishing.
  """
  @spec release_exam_attempt(String.t()) :: :ok
  def release_exam_attempt(submission_id) do
    Submission
    |> where([s], s.id == ^submission_id)
    |> Repo.update_all(set: [heartbeat_at: nil])

    :ok
  end

  @doc false
  def get_ticket_usage(exam_block_id, cohort_id) do
    query =
      from s in Submission,
        where: s.block_id == ^exam_block_id and is_nil(s.parent_submission_id)

    query =
      if cohort_id do
        where(query, [s], s.cohort_id == ^cohort_id)
      else
        query
      end

    # Counted in the database: each attempt's `content` holds a full snapshot
    # of its questions, far too heavy to load just to count block ids.
    counts =
      from([s] in query,
        inner_lateral_join:
          q in fragment(
            "jsonb_array_elements(CASE WHEN jsonb_typeof(?->'questions') = 'array' THEN ?->'questions' ELSE '[]'::jsonb END)",
            s.content,
            s.content
          ),
        on: true,
        where:
          not is_nil(
            fragment(
              "COALESCE(?->'content'->>'original_block_id', ?->>'original_block_id')",
              q.value,
              q.value
            )
          ),
        group_by:
          fragment(
            "COALESCE(?->'content'->>'original_block_id', ?->>'original_block_id')",
            q.value,
            q.value
          ),
        select:
          {fragment(
             "COALESCE(?->'content'->>'original_block_id', ?->>'original_block_id')",
             q.value,
             q.value
           ), count()}
      )
      |> Repo.all()
      |> Map.new()

    TicketUsage.new(counts)
  end
end
