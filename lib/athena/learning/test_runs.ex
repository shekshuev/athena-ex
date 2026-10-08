defmodule Athena.Learning.TestRuns do
  @moduledoc """
  Lets an instructor "test run" a section of their course as a throwaway
  student, from inside the builder, without a real enrollment or fake
  progress through the entire preceding course.

  `start/3` seeds real `BlockProgress` "completed" rows for every gate block
  in the sections *before* the target section – the same fact
  `Athena.Learning.Progress.accessible_section_ids/6` already reads to decide
  what's unlocked – so the target section becomes reachable with zero new
  gating logic and zero changes to the course's real `access_rules`. Unlike
  `Progress.mark_completed/3`, this seeding step does not broadcast
  `:block_completed`, so it doesn't trigger gamification (XP/badges/streaks)
  for history that was never actually earned; the target section itself is
  then played for real (via `AthenaWeb.LearnLive.Player`), so anything the
  instructor actually completes there *does* run the full production path,
  gamification included – that's the point of the feature.

  The resulting ephemeral `Account` gets no `Enrollment`/`CohortMembership`
  of its own, so it structurally cannot appear in rosters or leaderboards
  (both are enrollment/membership-anchored) while a test run is live.

  Because `enrollments`, `block_progresses`, `submissions`, and every
  gamification table store `account_id` as a bare `:binary_id` with no FK to
  `accounts`, deleting the ephemeral account cascades nothing.
  `test_run_sessions` is therefore the authoritative index of what
  `cleanup/1` must purge – used both by the builder's modal-close handler and
  by `Athena.Learning.Workers.TestRunCleanup`, the cron backstop for crashed
  or abandoned sessions.
  """

  import Ecto.Query

  alias Athena.{Repo, Content, Identity}
  alias Athena.Content.{Course, Section, Block, CourseLibraryBlock}
  alias Athena.Identity.{Account, Role}
  alias Athena.Learning.{TestRunSession, Enrollment, BlockProgress, Submission, Progress}
  alias Athena.Learning.CourseProgressCache
  alias Athena.Gamification.{XpEvent, BadgeAward, DailyChallenge, LeagueResult, AccountStats}

  @session_ttl_minutes 30
  @role_name "Test Run Student"

  @doc """
  Starts a test-run session for `section_id` inside `course_id`, acting as
  `instructor`. Returns the created session (already backed by a live
  ephemeral account with every earlier gate block marked completed).
  """
  @spec start(Account.t(), String.t(), String.t()) ::
          {:ok, TestRunSession.t()} | {:error, :forbidden | :not_found | :section_not_playable}
  def start(instructor, course_id, section_id) do
    with {:ok, course} <- Content.get_course(instructor, course_id),
         true <- Content.can_edit_course?(instructor, course),
         linear_sections <- Content.list_linear_lessons(course_id, :all),
         {:ok, target_section_id} <-
           resolve_playable_section(course_id, section_id, linear_sections) do
      do_start(instructor, course, target_section_id, linear_sections)
    else
      false -> {:error, :forbidden}
      {:error, reason} -> {:error, reason}
    end
  end

  # A "folder" section (subsections but no blocks of its own, shown collapsed
  # in the builder canvas behind a Subsections grid) never appears in
  # `linear_sections` itself. Rather than reject it outright, resolve it to
  # the first playable descendant so "Test run" works from a collapsed
  # section too.
  @doc false
  defp resolve_playable_section(course_id, section_id, linear_sections) do
    if Enum.any?(linear_sections, &(&1.id == section_id)) do
      {:ok, section_id}
    else
      resolve_playable_descendant(course_id, section_id, linear_sections)
    end
  end

  @doc false
  defp resolve_playable_descendant(course_id, section_id, linear_sections) do
    course_id
    |> Content.get_course_tree(:all)
    |> find_section_node(section_id)
    |> case do
      nil -> {:error, :forbidden}
      node -> find_playable_descendant(node, linear_sections)
    end
  end

  @doc false
  defp find_playable_descendant(node, linear_sections) do
    descendant_ids = MapSet.new(collect_section_ids(node))

    case Enum.find(linear_sections, &MapSet.member?(descendant_ids, &1.id)) do
      nil -> {:error, :section_not_playable}
      playable -> {:ok, playable.id}
    end
  end

  @doc false
  defp find_section_node(nodes, section_id) do
    Enum.find_value(nodes, fn node ->
      if node.id == section_id, do: node, else: find_section_node(node.children || [], section_id)
    end)
  end

  @doc false
  defp collect_section_ids(node) do
    Enum.reduce(node.children || [], [node.id], fn child, acc ->
      acc ++ collect_section_ids(child)
    end)
  end

  @doc """
  Starts a test-run session that plays a single library block, for the
  "Test run" button on the library block page.

  A library block belongs to no course, so there is no section to play. Rather
  than teach `AthenaWeb.LearnLive.Player` (and the exam LiveViews) a second
  way of rendering blocks, this builds a throwaway `:library_preview` course
  with one section holding a copy of the block and plays that through the
  same path `start/3` uses. `cleanup/1` deletes the wrapper course again.

  Exam blocks draw their questions from the course's pinned library blocks,
  so for those the wrapper course is pinned the same questions the
  instructor could use: the source course's bank when `:course_id` is given,
  otherwise every question block the instructor can read.
  """
  @spec start_library_block(Account.t(), String.t(), keyword()) ::
          {:ok, TestRunSession.t()} | {:error, :forbidden | :not_found | any()}
  def start_library_block(instructor, library_block_id, opts \\ []) do
    with true <- Identity.can?(instructor, "library.read") || {:error, :forbidden},
         {:ok, library_block} <- Content.get_library_block(library_block_id) do
      do_start_library_block(instructor, library_block, opts[:course_id])
    end
  end

  @doc false
  defp do_start_library_block(instructor, library_block, source_course_id) do
    course_id = Ecto.UUID.generate()
    section_id = Ecto.UUID.generate()
    expires_at = DateTime.utc_now() |> DateTime.add(@session_ttl_minutes * 60, :second)

    Ecto.Multi.new()
    |> Ecto.Multi.run(:role, fn _repo, _changes -> ensure_test_run_role() end)
    |> Ecto.Multi.insert(:account, fn %{role: role} -> ephemeral_account_changeset(role) end)
    |> Ecto.Multi.insert(:course, preview_course_changeset(course_id, instructor))
    |> Ecto.Multi.insert(:section, preview_section_changeset(course_id, section_id))
    |> Ecto.Multi.insert(:block, preview_block_changeset(section_id, library_block))
    |> Ecto.Multi.run(:pins, fn _repo, _changes ->
      pin_exam_question_pool(library_block, course_id, instructor, source_course_id)
    end)
    |> Ecto.Multi.insert(:session, fn %{account: account} ->
      TestRunSession.changeset(%TestRunSession{}, %{
        course_id: course_id,
        section_id: section_id,
        instructor_account_id: instructor.id,
        ephemeral_account_id: account.id,
        expires_at: DateTime.truncate(expires_at, :second)
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{session: session}} -> {:ok, session}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc false
  defp preview_course_changeset(course_id, instructor) do
    Course.changeset(%Course{id: course_id}, %{
      "title" => "Library preview " <> course_id,
      "type" => :library_preview,
      "status" => :published,
      "owner_id" => instructor.id
    })
  end

  @doc false
  defp preview_section_changeset(course_id, section_id) do
    Section.changeset(%Section{id: section_id}, %{
      "id" => section_id,
      "title" => "Library preview",
      "course_id" => course_id,
      "path" => Section.build_path(section_id, nil)
    })
  end

  @doc false
  defp preview_block_changeset(section_id, library_block) do
    Block.changeset(%Block{}, %{
      "type" => library_block.type,
      "content" => library_block.content,
      "section_id" => section_id,
      "order" => 0
    })
  end

  @exam_types [:quiz_exam, :ticket_exam]

  @doc false
  defp pin_exam_question_pool(%{type: type}, course_id, instructor, source_course_id)
       when type in @exam_types do
    pool_ids =
      if source_course_id do
        Repo.all(
          from clb in CourseLibraryBlock,
            where: clb.course_id == ^source_course_id,
            select: clb.library_block_id
        )
      else
        Content.list_readable_question_block_ids(instructor)
      end

    now = DateTime.utc_now(:second)

    rows =
      Enum.map(pool_ids, fn id ->
        %{course_id: course_id, library_block_id: id, inserted_at: now, updated_at: now}
      end)

    {count, _} = Repo.insert_all(CourseLibraryBlock, rows)
    {:ok, count}
  end

  defp pin_exam_question_pool(_library_block, _course_id, _instructor, _source_course_id),
    do: {:ok, 0}

  @doc false
  defp do_start(instructor, course, section_id, linear_sections) do
    prior_sections = Enum.take_while(linear_sections, &(&1.id != section_id))
    expires_at = DateTime.utc_now() |> DateTime.add(@session_ttl_minutes * 60, :second)

    Ecto.Multi.new()
    |> Ecto.Multi.run(:role, fn _repo, _changes -> ensure_test_run_role() end)
    |> Ecto.Multi.insert(:account, fn %{role: role} -> ephemeral_account_changeset(role) end)
    |> Ecto.Multi.run(:seed_progress, fn _repo, %{account: account} ->
      seed_prior_gate_completions(account, prior_sections)
    end)
    |> Ecto.Multi.insert(:session, fn %{account: account} ->
      TestRunSession.changeset(%TestRunSession{}, %{
        course_id: course.id,
        section_id: section_id,
        instructor_account_id: instructor.id,
        ephemeral_account_id: account.id,
        expires_at: DateTime.truncate(expires_at, :second)
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{session: session}} -> {:ok, session}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc false
  defp ensure_test_run_role do
    case Repo.get_by(Role, name: @role_name) do
      nil ->
        %Role{}
        |> Role.changeset(%{name: @role_name, permissions: [], policies: %{}})
        |> Repo.insert(on_conflict: :nothing, conflict_target: :name)

        {:ok, Repo.get_by!(Role, name: @role_name)}

      role ->
        {:ok, role}
    end
  end

  @doc false
  defp ephemeral_account_changeset(role) do
    Account.changeset(%Account{}, %{
      "login" => "__test_run_" <> Ecto.UUID.generate(),
      "password" => Ecto.UUID.generate() <> "Aa1!",
      "role_id" => role.id
    })
  end

  @doc false
  defp seed_prior_gate_completions(_account, []), do: {:ok, :no_prior_sections}

  defp seed_prior_gate_completions(account, prior_sections) do
    prior_sections
    |> Progress.get_gate_blocks(account, [], ignore_schedule?: true, ignore_visibility?: true)
    |> Enum.each(fn block ->
      %BlockProgress{}
      |> BlockProgress.changeset(%{
        account_id: account.id,
        block_id: block.id,
        status: :completed
      })
      |> Repo.insert(
        on_conflict: [set: [status: :completed, updated_at: DateTime.utc_now()]],
        conflict_target: {:unsafe_fragment, "(account_id, block_id) WHERE cohort_id IS NULL"}
      )
    end)

    {:ok, :seeded}
  end

  @doc """
  Purges every trace of a test-run session's ephemeral account and marks the
  session `:cleaned_up`, along with the wrapper course of a
  `start_library_block/3` run. Safe to call more than once (e.g. once from the
  builder's modal-close handler, and again from the cron sweep if that race
  loses) – every delete is a no-op once the rows are already gone.
  """
  @spec cleanup(TestRunSession.t()) :: :ok | {:error, any()}
  def cleanup(%TestRunSession{ephemeral_account_id: account_id} = session) do
    Ecto.Multi.new()
    |> Ecto.Multi.delete_all(
      :submissions,
      from(s in Submission, where: s.account_id == ^account_id)
    )
    |> Ecto.Multi.delete_all(
      :block_progresses,
      from(bp in BlockProgress, where: bp.account_id == ^account_id)
    )
    |> Ecto.Multi.delete_all(
      :enrollments,
      from(e in Enrollment, where: e.account_id == ^account_id)
    )
    |> Ecto.Multi.delete_all(
      :progress_cache,
      from(c in CourseProgressCache, where: c.account_id == ^account_id)
    )
    |> Ecto.Multi.delete_all(:xp_events, from(x in XpEvent, where: x.account_id == ^account_id))
    |> Ecto.Multi.delete_all(
      :badge_awards,
      from(b in BadgeAward, where: b.account_id == ^account_id)
    )
    |> Ecto.Multi.delete_all(
      :daily_challenges,
      from(d in DailyChallenge, where: d.account_id == ^account_id)
    )
    |> Ecto.Multi.delete_all(
      :league_results,
      from(l in LeagueResult, where: l.account_id == ^account_id)
    )
    |> Ecto.Multi.delete_all(
      :account_stats,
      from(a in AccountStats, where: a.account_id == ^account_id)
    )
    |> Ecto.Multi.delete_all(
      :preview_course,
      from(c in Course, where: c.id == ^session.course_id and c.type == :library_preview)
    )
    |> Ecto.Multi.delete_all(:account, from(a in Account, where: a.id == ^account_id))
    |> Ecto.Multi.update(:session, TestRunSession.changeset(session, %{status: :cleaned_up}))
    |> Repo.transaction()
    |> case do
      {:ok, _changes} -> :ok
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  Sweeps every expired-but-still-active test run session and cleans it up.
  Called on a cron schedule by `Athena.Learning.Workers.TestRunCleanup` – the
  backstop for a crashed browser, dropped connection, or any other path that
  skipped the builder's normal modal-close cleanup.
  """
  @spec sweep_expired() :: non_neg_integer()
  def sweep_expired do
    now = DateTime.utc_now()

    TestRunSession
    |> where([s], s.status == :active and s.expires_at < ^now)
    |> Repo.all()
    |> Enum.count(&(cleanup(&1) == :ok))
  end
end
