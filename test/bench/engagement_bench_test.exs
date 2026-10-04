defmodule Athena.Bench.EngagementBenchTest do
  @moduledoc """
  Timing/query-count benchmark for the engagement dashboards, on a synthetic
  cohort sized like a real one (30 students × 15 sections × 10 blocks, ~22k
  events). Excluded by default (see `test_helper.exs`); run with:

      mix test test/bench --only bench

  `BENCH_DENSITY=10 mix test test/bench --only bench` adds that many extra
  idle/tab-switch event pairs per student × block visit - real telemetry is
  much chattier than the default fixture, and that is where rollups pay off.

  Prints one line per function: wall time and number of SQL queries. Not an
  assertion-driven test on purpose - it is a measuring stick to compare
  before/after a performance change, not a pass/fail gate.
  """
  use Athena.DataCase, async: false

  import Athena.Factory

  alias Athena.Content.EngagementRule
  alias Athena.Engagement
  alias Athena.Engagement.Event
  alias Athena.Learning
  alias Athena.Learning.{BlockProgress, Submission}
  alias Athena.Repo

  @moduletag :bench
  @moduletag timeout: :infinity

  @students 30
  @sections 15
  @blocks_per_section 10
  @block_types [:text, :video, :quiz_question, :code, :text]

  setup do
    course = insert(:course)
    cohort = insert(:cohort)

    sections =
      for s <- 1..@sections do
        insert(:section, course: course, order: s, title: "Section #{s}")
      end

    blocks =
      for section <- sections, b <- 1..@blocks_per_section do
        insert(:block,
          section: section,
          type: Enum.at(@block_types, rem(b, length(@block_types))),
          order: b * 10,
          engagement_rule: %EngagementRule{expected_seconds: 120}
        )
      end

    students =
      for _ <- 1..@students do
        account = insert(:account, password_hash: "bench")
        insert(:cohort_membership, account_id: account.id, cohort_id: cohort.id)
        account
      end

    insert_events(students, blocks, cohort)
    insert_progress(students, blocks)
    insert_submissions(students, blocks)

    %{course: course, cohort: cohort, sections: sections}
  end

  test "engagement dashboards", %{course: course, cohort: cohort, sections: sections} do
    since = DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)
    opts = [since: since]
    section = hd(sections)

    IO.puts("\n== engagement bench (#{Repo.aggregate(Event, :count)} events) ==")

    block_ids =
      Athena.Content.Block
      |> Ecto.Query.where([b], b.section_id in ^Enum.map(sections, & &1.id))
      |> Ecto.Query.select([b], b.id)
      |> Repo.all()

    measure("raw events load", fn ->
      Engagement.list_events_for_scope(block_ids, cohort.id)
    end)

    measure("student_radar", fn -> Engagement.student_radar(cohort.id, course.id, opts) end)

    measure("cohort_flag_profile", fn ->
      Engagement.cohort_flag_profile(cohort.id, course.id, opts)
    end)

    measure("section_flag_totals", fn ->
      Engagement.section_flag_totals(cohort.id, course.id, opts)
    end)

    measure("activity_heatmap", fn -> Engagement.activity_heatmap(cohort.id, course.id, opts) end)
    measure("course_funnel", fn -> Engagement.course_funnel(cohort.id, course.id, opts) end)

    measure("active_students_trend", fn ->
      Engagement.active_students_trend(cohort.id, course.id, opts)
    end)

    measure("nudge_correction_rate", fn ->
      Engagement.nudge_correction_rate(cohort.id, course.id, opts)
    end)

    if function_exported?(Engagement, :course_overview, 3) do
      measure("course_overview (all charts)", fn ->
        apply(Engagement, :course_overview, [cohort.id, course.id, opts])
      end)
    end

    measure("gradebook (scores only)", fn -> Learning.build_gradebook(cohort, course.id) end)

    IO.puts("-- with rollups --")
    measure("rollups: initial backfill", fn -> Engagement.Rollups.process_new_events() end)
    measure("rollups: idle re-run", fn -> Engagement.Rollups.process_new_events() end)
    measure("student_radar", fn -> Engagement.student_radar(cohort.id, course.id, opts) end)

    measure("course_overview (all charts)", fn ->
      Engagement.course_overview(cohort.id, course.id, opts)
    end)

    measure("course_overview (as the screen)", fn ->
      Engagement.course_overview(cohort.id, course.id, opts ++ [include_nudges: false])
    end)

    measure("nudge_correction_rate", fn ->
      Engagement.nudge_correction_rate(cohort.id, course.id, opts)
    end)

    measure("cohort_flag_profile", fn ->
      Engagement.cohort_flag_profile(cohort.id, course.id, opts)
    end)

    measure("gradebook engagement layer", fn ->
      Engagement.gradebook_engagement(cohort.id, course.id)
    end)

    measure("get_metrics(section)", fn ->
      Engagement.get_metrics(%{
        resource_type: :section,
        resource_id: section.id,
        cohort_id: cohort.id
      })
    end)
  end

  defp measure(label, fun) do
    counter = :counters.new(1, [])
    handler_id = "bench-#{label}"

    :telemetry.attach(
      handler_id,
      [:athena, :repo, :query],
      fn _event, _measurements, _meta, ref -> :counters.add(ref, 1, 1) end,
      counter
    )

    {micros, _result} = :timer.tc(fun)
    :telemetry.detach(handler_id)

    IO.puts(
      String.pad_trailing(label, 32) <>
        String.pad_leading("#{div(micros, 1000)} ms", 10) <>
        String.pad_leading("#{:counters.get(counter, 1)} queries", 14)
    )
  end

  # Per student × block: one session with enter/exit plus a few type-specific
  # events, spread over the last 20 days, plus an occasional nudge - enough
  # for every flag rule and every chart to have something to chew on.
  defp insert_events(students, blocks, cohort) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    students
    |> Enum.with_index()
    |> Enum.flat_map(fn {student, si} ->
      blocks
      |> Enum.with_index()
      |> Enum.flat_map(fn {block, bi} ->
        start = DateTime.add(now, -rem(si * 7 + bi * 13, 20) * 86_400 - 3_600, :second)
        dwell = 20 + rem(si * 31 + bi * 17, 300)
        session = Ecto.UUID.generate()
        base = {student, block, cohort, session}

        [
          event(base, :viewport_enter, start),
          event(base, :viewport_exit, DateTime.add(start, dwell, :second))
        ] ++
          type_events(block.type, base, start, si + bi) ++
          nudge_events(base, start, si + bi) ++ noise_events(base, start)
      end)
    end)
    |> Enum.chunk_every(5_000)
    |> Enum.each(&Repo.insert_all(Event, &1))
  end

  defp type_events(:text, base, start, seed) do
    for pct <- [25, 50, 75, 100], pct <= 25 + rem(seed, 4) * 25 do
      event(base, :scroll_milestone, DateTime.add(start, pct, :second), %{"percent" => pct})
    end
  end

  defp type_events(:video, base, start, seed) do
    [
      event(base, :video_play, DateTime.add(start, 1, :second)),
      event(base, :video_seek, DateTime.add(start, 5, :second), %{
        "from_sec" => 10,
        "to_sec" => 10 + rem(seed, 120)
      }),
      event(base, :video_ended, DateTime.add(start, 60, :second), %{"duration" => 300})
    ]
  end

  defp type_events(:quiz_question, base, start, seed) do
    [
      event(base, :answer_selected, DateTime.add(start, 3, :second)),
      event(base, :paste_detected, DateTime.add(start, 4, :second), %{
        "pasted_chars" => rem(seed, 100),
        "total_chars" => 100
      })
    ] ++
      for i <- 0..rem(seed, 3), i > 0 do
        event(base, :answer_changed, DateTime.add(start, 5 + i, :second))
      end
  end

  defp type_events(:code, base, start, seed) do
    for i <- 0..rem(seed, 6) do
      event(base, :code_run_attempt, DateTime.add(start, 10 + i * (3 + rem(seed, 30)), :second))
    end
  end

  defp type_events(_type, _base, _start, _seed), do: []

  defp nudge_events(base, start, seed) when rem(seed, 9) == 0 do
    [event(base, :nudge_shown, DateTime.add(start, 2, :second), %{"reason" => "fast_dwell"})]
  end

  defp nudge_events(_base, _start, _seed), do: []

  defp noise_events(base, start) do
    density = "BENCH_DENSITY" |> System.get_env("1") |> String.to_integer()

    for i <- 1..density//1, density > 1, {type, offset} <- [idle_start: 0, idle_end: 4] do
      payload = if type == :idle_end, do: %{"duration_ms" => 4_000}, else: %{}
      event(base, type, DateTime.add(start, 6 + i * 7 + offset, :second), payload)
    end
  end

  defp event({student, block, cohort, session}, type, at, payload \\ %{}) do
    %{
      id: Ecto.UUID.generate(),
      account_id: student.id,
      block_id: block.id,
      section_id: block.section_id,
      cohort_id: cohort.id,
      session_id: session,
      event_type: type,
      payload: payload,
      occurred_at: at,
      inserted_at: at
    }
  end

  # 1-3 attempts per student on every gradable block.
  defp insert_submissions(students, blocks) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    gradable = Enum.filter(blocks, &Athena.Content.Block.gradable?/1)

    for {student, si} <- Enum.with_index(students),
        {block, bi} <- Enum.with_index(gradable),
        attempt <- 1..(1 + rem(si + bi, 3)) do
      at = DateTime.add(now, -(si * 97 + bi * 31 + attempt * 600), :second)

      %{
        id: Ecto.UUID.generate(),
        account_id: student.id,
        block_id: block.id,
        status: if(rem(si * bi + attempt, 7) == 0, do: :needs_review, else: :graded),
        score: rem(si * 13 + bi * 7 + attempt * 11, 101),
        content: %{},
        origin: :regular,
        inserted_at: at,
        updated_at: at
      }
    end
    |> Enum.chunk_every(5_000)
    |> Enum.each(&Repo.insert_all(Submission, &1))
  end

  defp insert_progress(students, blocks) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    students
    |> Enum.with_index()
    |> Enum.flat_map(fn {student, si} ->
      blocks
      |> Enum.with_index()
      |> Enum.filter(fn {_block, bi} -> rem(si + bi, 10) < 7 end)
      |> Enum.map(fn {block, _bi} ->
        %{
          id: Ecto.UUID.generate(),
          account_id: student.id,
          block_id: block.id,
          status: :completed,
          payload: %{},
          feedback: %{},
          inserted_at: now,
          updated_at: now
        }
      end)
    end)
    |> Enum.chunk_every(5_000)
    |> Enum.each(&Repo.insert_all(BlockProgress, &1))
  end
end
