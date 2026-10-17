defmodule Athena.Repo.Migrations.AddHotPathIndexes do
  @moduledoc """
  Indexes for the lookups that were sequential scans (see the DB audit in
  the `optimization` branch):

    * memberships, enrollments and shares looked up by account, while their
      unique indexes lead with the other column;
    * "latest activity" / "latest attempt" top-1 queries;
    * the grading list's default `ORDER BY inserted_at DESC LIMIT n`;
    * weekly XP sums, upcoming deadlines, media keys, unread messages,
      expired test runs and name searches.

  Also drops indexes made redundant: two that duplicate the leading column
  of a unique/primary key, and `xp_events(account_id)`, superseded by
  `(account_id, inserted_at)`.

  Built `CONCURRENTLY` so a deploy doesn't lock the tables while they build.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @indexes [
    {:cohort_memberships, [:account_id],
     name: :cohort_memberships__account_id__idx, include: [:cohort_id]},
    {:enrollments, [:cohort_id],
     name: :enrollments__cohort_id__idx, where: "cohort_id IS NOT NULL"},
    {:enrollments, [:account_id],
     name: :enrollments__account_id__idx, where: "account_id IS NOT NULL"},
    {:block_progresses, ["account_id", "updated_at DESC"],
     name: :block_progresses__account_id_updated_at__idx},
    {:block_progresses, ["cohort_id", "updated_at DESC"],
     name: :block_progresses__cohort_id_updated_at__idx, where: "cohort_id IS NOT NULL"},
    {:gamification_xp_events, [:account_id, :inserted_at],
     name: :gamification_xp_events__account_id_inserted_at__idx, include: [:amount]},
    {:gamification_xp_events, [:inserted_at],
     name: :gamification_xp_events__inserted_at__brin, using: :brin},
    # The grading list (`Submissions.list_submissions/2`): every query carries
    # exactly these three conditions and sorts newest first.
    {:submissions, ["inserted_at DESC"],
     name: :submissions__grading_list__idx,
     where:
       "status <> 'draft' AND parent_submission_id IS NULL AND (content ->> 'is_test_run') IS NULL"},
    {:submissions, ["account_id", "block_id", "inserted_at DESC"],
     name: :submissions__latest_attempt__idx, where: "parent_submission_id IS NULL"},
    {:submissions, [:cohort_id],
     name: :submissions__cohort_id__idx, where: "cohort_id IS NOT NULL"},
    {:cohort_instructors, [:instructor_id], name: :cohort_instructors__instructor_id__idx},
    {:course_shares, [:account_id], name: :course_shares__account_id__idx},
    {:library_block_shares, [:account_id], name: :library_block_shares__account_id__idx},
    {:media_file_shares, [:account_id], name: :media_file_shares__account_id__idx},
    {:cohort_schedules, [:cohort_id, :lock_at],
     name: :cohort_schedules__cohort_id_lock_at__idx, where: "lock_at IS NOT NULL"},
    {:media_files, ["key text_pattern_ops"], name: :media_files__key__idx},
    {:media_files, [:owner_id, :context],
     name: :media_files__owner_id_context__idx, include: [:size]},
    {:messages, [:conversation_id, :inserted_at],
     name: :messages__live_conversation_inserted_at__idx, where: "deleted_at IS NULL"},
    {:test_run_sessions, [:expires_at],
     name: :test_run_sessions__active_expires_at__idx, where: "status = 'active'"},
    {:cohorts, ["name gin_trgm_ops"], name: :cohorts__name_trgm__idx, using: :gin},
    {:courses, ["title gin_trgm_ops"], name: :courses__title_trgm__idx, using: :gin},
    {:characters, [:avatar_file_id], name: :characters__avatar_file_id__idx}
  ]

  @redundant [
    # Leading column of the primary key (course_id, library_block_id).
    {:course_library_blocks, [:course_id], name: :course_library_blocks_course_id_index},
    # Leading column of cohort_resource_unique_index.
    {:cohort_schedules, [:cohort_id], name: :cohort_schedules_cohort_id_index},
    # Superseded by gamification_xp_events__account_id_inserted_at__idx.
    {:gamification_xp_events, [:account_id], name: :gamification_xp_events_account_id_index}
  ]

  def up do
    for {table, columns, opts} <- @indexes do
      create_if_not_exists index(table, columns, [concurrently: true] ++ opts)
    end

    for {table, columns, opts} <- @redundant do
      drop_if_exists index(table, columns, [concurrently: true] ++ opts)
    end
  end

  def down do
    for {table, columns, opts} <- @redundant do
      create_if_not_exists index(table, columns, [concurrently: true] ++ opts)
    end

    for {table, columns, opts} <- @indexes do
      drop_if_exists index(table, columns, [concurrently: true] ++ opts)
    end
  end
end
