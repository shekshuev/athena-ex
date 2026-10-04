defmodule Athena.Engagement.RollupsTest do
  use Athena.DataCase, async: false

  import Athena.Factory

  alias Athena.Content.EngagementRule
  alias Athena.Engagement
  alias Athena.Engagement.{Metrics, Rollup, Rollups}
  alias Athena.Engagement.Workers.RollupWorker
  alias Athena.Repo

  setup do
    course = insert(:course)
    intro = insert(:section, course: course, title: "Intro", order: 10)
    practice = insert(:section, course: course, title: "Practice", order: 20)

    text =
      insert(:block,
        section: intro,
        type: :text,
        order: 10,
        engagement_rule: %EngagementRule{expected_seconds: 100}
      )

    video = insert(:block, section: intro, type: :video, order: 20)
    quiz = insert(:block, section: intro, type: :quiz_question, order: 30)
    code = insert(:block, section: practice, type: :code, order: 10)
    exam = insert(:block, section: practice, type: :quiz_exam, order: 20)

    cohort = insert(:cohort)
    students = for _ <- 1..3, do: insert(:account)
    Enum.each(students, &insert(:cohort_membership, account_id: &1.id, cohort_id: cohort.id))

    %{
      course: course,
      cohort: cohort,
      students: students,
      blocks: %{text: text, video: video, quiz: quiz, code: code, exam: exam}
    }
  end

  defp at(days_ago, seconds) do
    Athena.TimeZones.today()
    |> Date.add(-days_ago)
    |> Athena.TimeZones.start_of_day()
    |> DateTime.add(9 * 3600 + seconds, :second)
  end

  defp record(student, cohort, session, block, type, occurred_at, payload \\ %{}) do
    Engagement.record_events(student.id, cohort.id, session, [
      %{
        block_id: block.id,
        section_id: block.section_id,
        event_type: type,
        payload: payload,
        occurred_at: occurred_at
      }
    ])
  end

  # A varied day of activity: short and long dwells, backtracking, shallow
  # scroll, video skipping, pasting, answer changes, rapid code runs, an
  # exam integrity hit and a nudge - something for every flag.
  defp activity_day(ctx, student, days_ago, variant) do
    %{cohort: cohort, blocks: b} = ctx
    s = Ecto.UUID.generate()
    t = &at(days_ago, &1)

    record(student, cohort, s, b.text, :viewport_enter, t.(0))

    record(student, cohort, s, b.text, :scroll_milestone, t.(3), %{"percent" => 25 + variant * 25})

    record(student, cohort, s, b.text, :viewport_exit, t.(5 + variant * 200))
    record(student, cohort, s, b.video, :viewport_enter, t.(300))
    record(student, cohort, s, b.video, :video_play, t.(301))

    record(student, cohort, s, b.video, :video_seek, t.(305), %{"from_sec" => 10, "to_sec" => 130})

    record(student, cohort, s, b.video, :video_ended, t.(400), %{"duration" => 300})
    record(student, cohort, s, b.text, :viewport_enter, t.(450))
    record(student, cohort, s, b.text, :nudge_shown, t.(451), %{"reason" => "shallow_scroll"})
    record(student, cohort, s, b.quiz, :viewport_enter, t.(500))
    record(student, cohort, s, b.quiz, :first_interaction, t.(510))
    record(student, cohort, s, b.quiz, :answer_changed, t.(520))

    record(student, cohort, s, b.quiz, :paste_detected, t.(530), %{
      "pasted_chars" => 90,
      "total_chars" => 100
    })

    for i <- 0..(2 + variant),
        do: record(student, cohort, s, b.code, :code_run_attempt, t.(600 + i * 3))

    record(student, cohort, s, b.exam, :tab_hidden, t.(700))
    record(student, cohort, s, b.exam, :tab_visible, t.(730), %{"duration_ms" => 30_000})
    if variant == 1, do: record(student, cohort, s, b.exam, :copy_attempt, t.(740))
  end

  defp seed(ctx) do
    [a, b, c] = ctx.students
    activity_day(ctx, a, 3, 0)
    activity_day(ctx, a, 1, 1)
    activity_day(ctx, b, 2, 1)
    activity_day(ctx, b, 0, 0)
    activity_day(ctx, c, 0, 1)
  end

  defp both_ways(fun) do
    raw = fun.(source: :raw)
    Rollups.process_new_events()
    assert Rollups.ready?()
    {raw, fun.([])}
  end

  test "dashboards read the same numbers from rollups as from raw events", ctx do
    seed(ctx)
    since = at(5, 0)

    {raw, rolled} =
      both_ways(fn opts ->
        opts = [since: since] ++ opts

        %{
          radar: Metrics.student_radar(ctx.cohort.id, ctx.course.id, opts),
          profile: Metrics.cohort_flag_profile(ctx.cohort.id, ctx.course.id, opts),
          overview: Metrics.course_overview(ctx.cohort.id, ctx.course.id, opts)
        }
      end)

    assert rolled.radar == raw.radar
    assert rolled.profile == raw.profile
    assert rolled.overview == raw.overview

    # The fixture really does exercise the flags, not just zeros.
    assert Enum.any?(raw.radar, &(&1.status != :green))
    assert Enum.any?(raw.overview.active_students_trend)
    assert [%{nudged_count: 5}] = raw.overview.nudge_correction_rate
  end

  test "rollups only store past days' buckets per student, block and day", ctx do
    seed(ctx)
    Rollups.process_new_events()

    rows = Repo.all(Rollup)
    assert Enum.all?(rows, &(&1.cohort_id == ctx.cohort.id))

    assert rows |> Enum.map(&{&1.account_id, &1.block_id, &1.day}) |> Enum.uniq() |> length() ==
             length(rows)

    assert Enum.any?(rows, &(&1.backtracks > 0))
    assert Enum.any?(rows, &(&1.fast_run_gaps > 0))
  end

  test "a late event for a past day is folded into that day on the next run", ctx do
    [student | _] = ctx.students
    activity_day(ctx, student, 2, 0)
    Rollups.process_new_events()

    copy_count = fn ->
      Rollup
      |> Repo.all()
      |> Enum.filter(&(&1.block_id == ctx.blocks.exam.id))
      |> Enum.map(& &1.copy_attempt)
      |> Enum.sum()
    end

    assert copy_count.() == 0

    record(student, ctx.cohort, Ecto.UUID.generate(), ctx.blocks.exam, :copy_attempt, at(2, 999))
    # Recorded in the same second as the cursor - must still be picked up.
    Rollups.process_new_events()
    assert copy_count.() == 1
  end

  test "small batches walk the cursor through every event exactly once", ctx do
    seed(ctx)
    processed = Rollups.process_new_events(batch_size: 7, max_batches: 1_000)

    assert processed == Repo.aggregate(Athena.Engagement.Event, :count)
    assert Rollups.process_new_events() == 0

    raw = Metrics.student_radar(ctx.cohort.id, ctx.course.id, since: at(5, 0), source: :raw)
    assert Metrics.student_radar(ctx.cohort.id, ctx.course.id, since: at(5, 0)) == raw
  end

  test "not ready before the first run, ready after, and reset starts over", ctx do
    refute Rollups.ready?()
    seed(ctx)
    assert :ok = perform_job(RollupWorker, %{})
    assert Rollups.ready?()

    assert :ok = Rollups.reset()
    refute Rollups.ready?()
    assert Repo.aggregate(Rollup, :count) == 0
  end
end
