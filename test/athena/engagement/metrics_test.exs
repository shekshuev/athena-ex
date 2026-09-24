defmodule Athena.Engagement.MetricsTest do
  use Athena.DataCase, async: true

  import Athena.Factory

  alias Athena.Content.EngagementRule
  alias Athena.Engagement
  alias Athena.Engagement.Metrics
  alias Athena.Learning

  setup do
    course = insert(:course)
    section = insert(:section, course: course)
    %{course: course, section: section}
  end

  defp record(
         account_id,
         cohort_id,
         session_id,
         block,
         event_type,
         offset_seconds,
         payload \\ %{}
       ) do
    base = ~U[2026-01-05 12:00:00Z]

    Engagement.record_events(account_id, cohort_id, session_id, [
      %{
        block_id: block.id,
        section_id: block.section_id,
        event_type: event_type,
        payload: payload,
        occurred_at: DateTime.add(base, offset_seconds, :second)
      }
    ])
  end

  describe "get_metrics/1 for a text block" do
    test "computes dwell ratio, scroll depth, and shared metrics", %{section: section} do
      block =
        insert(:block,
          section: section,
          type: :text,
          order: 10,
          engagement_rule: %EngagementRule{expected_seconds: 60}
        )

      account = insert(:account)
      session = Ecto.UUID.generate()

      record(account.id, nil, session, block, :viewport_enter, 0)
      record(account.id, nil, session, block, :scroll_milestone, 5, %{"percent" => 50})
      record(account.id, nil, session, block, :scroll_milestone, 10, %{"percent" => 100})
      record(account.id, nil, session, block, :viewport_exit, 30)

      metrics = Metrics.get_metrics(%{resource_type: :block, resource_id: block.id})

      assert_in_delta metrics.dwell_ratio, 0.5, 0.01
      assert metrics.avg_scroll_depth_percent == 100
      assert metrics.sample_size == 1
      assert_in_delta metrics.avg_dwell_seconds, 30.0, 0.01
      assert metrics.students_observed == 1
    end

    test "dwell_ratio is nil when the block has no configured expected_seconds", %{
      section: section
    } do
      block = insert(:block, section: section, type: :text, order: 10, engagement_rule: nil)
      account = insert(:account)
      session = Ecto.UUID.generate()

      record(account.id, nil, session, block, :viewport_enter, 0)
      record(account.id, nil, session, block, :viewport_exit, 30)

      metrics = Metrics.get_metrics(%{resource_type: :block, resource_id: block.id})
      assert metrics.dwell_ratio == nil
    end
  end

  describe "get_metrics/1 for a code block" do
    test "computes an average paste ratio across paste_detected events", %{section: section} do
      block = insert(:block, section: section, type: :code, order: 10)
      account = insert(:account)
      session = Ecto.UUID.generate()

      record(account.id, nil, session, block, :paste_detected, 0, %{
        "pasted_chars" => 80,
        "total_chars" => 100
      })

      metrics = Metrics.get_metrics(%{resource_type: :block, resource_id: block.id})
      assert_in_delta metrics.paste_ratio, 0.8, 0.001
    end

    test "computes dwell_ratio too - not just text blocks", %{section: section} do
      block =
        insert(:block,
          section: section,
          type: :code,
          order: 10,
          engagement_rule: %EngagementRule{expected_seconds: 100}
        )

      account = insert(:account)
      session = Ecto.UUID.generate()

      record(account.id, nil, session, block, :viewport_enter, 0)
      record(account.id, nil, session, block, :viewport_exit, 50)

      metrics = Metrics.get_metrics(%{resource_type: :block, resource_id: block.id})
      assert_in_delta metrics.dwell_ratio, 0.5, 0.01
    end

    test "counts run attempts and flags whether a debug cycle happened", %{section: section} do
      block = insert(:block, section: section, type: :code, order: 10)
      account = insert(:account)

      record(account.id, nil, Ecto.UUID.generate(), block, :code_run_attempt, 0)
      record(account.id, nil, Ecto.UUID.generate(), block, :code_run_attempt, 5)

      metrics = Metrics.get_metrics(%{resource_type: :block, resource_id: block.id})
      assert metrics.run_attempt_count == 2
      assert metrics.debug_cycle_present? == true
    end

    test "panic_debugging? is true for three or more fast consecutive run attempts", %{
      section: section
    } do
      block = insert(:block, section: section, type: :code, order: 10)
      account = insert(:account)
      session = Ecto.UUID.generate()

      # gaps: 3s, 3s, 3s - all under the 10s threshold, three of them
      record(account.id, nil, session, block, :code_run_attempt, 0)
      record(account.id, nil, session, block, :code_run_attempt, 3)
      record(account.id, nil, session, block, :code_run_attempt, 6)
      record(account.id, nil, session, block, :code_run_attempt, 9)

      metrics = Metrics.get_metrics(%{resource_type: :block, resource_id: block.id})
      assert metrics.panic_debugging? == true
    end

    test "panic_debugging? is false for a single run attempt (no gaps at all)", %{
      section: section
    } do
      block = insert(:block, section: section, type: :code, order: 10)
      account = insert(:account)

      record(account.id, nil, Ecto.UUID.generate(), block, :code_run_attempt, 0)

      metrics = Metrics.get_metrics(%{resource_type: :block, resource_id: block.id})
      assert metrics.panic_debugging? == false
    end

    test "panic_debugging? is false when attempts are exactly on the threshold, not under it", %{
      section: section
    } do
      block = insert(:block, section: section, type: :code, order: 10)
      account = insert(:account)
      session = Ecto.UUID.generate()

      # gaps of exactly 10s - the rule is strictly "< 10s", so none of these count
      record(account.id, nil, session, block, :code_run_attempt, 0)
      record(account.id, nil, session, block, :code_run_attempt, 10)
      record(account.id, nil, session, block, :code_run_attempt, 20)
      record(account.id, nil, session, block, :code_run_attempt, 30)

      metrics = Metrics.get_metrics(%{resource_type: :block, resource_id: block.id})
      assert metrics.panic_debugging? == false
    end

    test "panic_debugging? counts fast gaps by the formula even when they're spread across widely-separated bursts",
         %{section: section} do
      block = insert(:block, section: section, type: :code, order: 10)
      account = insert(:account)
      session = Ecto.UUID.generate()

      # Three separate, calm-looking sessions of debugging, each containing
      # exactly one fast (3s) pair, far apart from each other. Intuitively
      # this doesn't look like one panic burst - but the rule is defined as
      # "count of fast gaps >= 3", not "3 fast gaps in a row", so this is
      # still expected to flag. Pinning this down explicitly rather than
      # leaving it to guesswork.
      record(account.id, nil, session, block, :code_run_attempt, 0)
      record(account.id, nil, session, block, :code_run_attempt, 3)
      record(account.id, nil, session, block, :code_run_attempt, 1000)
      record(account.id, nil, session, block, :code_run_attempt, 1003)
      record(account.id, nil, session, block, :code_run_attempt, 2000)
      record(account.id, nil, session, block, :code_run_attempt, 2003)

      metrics = Metrics.get_metrics(%{resource_type: :block, resource_id: block.id})
      assert metrics.panic_debugging? == true
    end

    test "debug_cycle_present? is false when the student never clicked Run", %{section: section} do
      block = insert(:block, section: section, type: :code, order: 10)
      account = insert(:account)

      record(account.id, nil, Ecto.UUID.generate(), block, :paste_detected, 0, %{
        "pasted_chars" => 100,
        "total_chars" => 100
      })

      metrics = Metrics.get_metrics(%{resource_type: :block, resource_id: block.id})
      assert metrics.run_attempt_count == 0
      assert metrics.debug_cycle_present? == false
    end
  end

  describe "get_metrics/1 for a quiz_question block" do
    test "counts answer changes", %{section: section} do
      block = insert(:block, section: section, type: :quiz_question, order: 10)
      account = insert(:account)
      session = Ecto.UUID.generate()

      record(account.id, nil, session, block, :answer_selected, 0)
      record(account.id, nil, session, block, :answer_changed, 5)
      record(account.id, nil, session, block, :answer_changed, 10)

      metrics = Metrics.get_metrics(%{resource_type: :block, resource_id: block.id})
      assert metrics.answer_change_count == 2
    end
  end

  describe "get_metrics/1 - avg_time_to_first_action (TTFA)" do
    test "measures the gap between viewport_enter and first_interaction", %{section: section} do
      block = insert(:block, section: section, type: :quiz_question, order: 10)
      account = insert(:account)
      session = Ecto.UUID.generate()

      record(account.id, nil, session, block, :viewport_enter, 0)
      record(account.id, nil, session, block, :first_interaction, 7)

      metrics = Metrics.get_metrics(%{resource_type: :block, resource_id: block.id})
      assert_in_delta metrics.avg_time_to_first_action, 7.0, 0.01
    end

    test "is nil when there is no first_interaction at all", %{section: section} do
      block = insert(:block, section: section, type: :quiz_question, order: 10)
      account = insert(:account)
      session = Ecto.UUID.generate()

      record(account.id, nil, session, block, :viewport_enter, 0)

      metrics = Metrics.get_metrics(%{resource_type: :block, resource_id: block.id})
      assert metrics.avg_time_to_first_action == nil
    end
  end

  describe "get_metrics/1 - dwell_ratio cascade (block -> section -> config default)" do
    test "falls back to the section's expected_seconds when the block sets none", %{
      course: course
    } do
      section =
        insert(:section, course: course, engagement_rule: %EngagementRule{expected_seconds: 40})

      block = insert(:block, section: section, type: :code, order: 10, engagement_rule: nil)
      account = insert(:account)
      session = Ecto.UUID.generate()

      record(account.id, nil, session, block, :viewport_enter, 0)
      record(account.id, nil, session, block, :viewport_exit, 20)

      metrics = Metrics.get_metrics(%{resource_type: :block, resource_id: block.id})
      assert_in_delta metrics.dwell_ratio, 0.5, 0.01
    end
  end

  describe "get_metrics/1 for a video block" do
    test "counts play/pause/seek/ended events", %{section: section} do
      block = insert(:block, section: section, type: :video, order: 10)
      account = insert(:account)
      session = Ecto.UUID.generate()

      record(account.id, nil, session, block, :video_play, 0)
      record(account.id, nil, session, block, :video_seek, 5)
      record(account.id, nil, session, block, :video_seek, 10)
      record(account.id, nil, session, block, :video_pause, 15)
      record(account.id, nil, session, block, :video_ended, 20)

      metrics = Metrics.get_metrics(%{resource_type: :block, resource_id: block.id})
      assert metrics.play_count == 1
      assert metrics.pause_count == 1
      assert metrics.seek_count == 2
      assert metrics.completion_count == 1
    end
  end

  describe "get_metrics/1 for a whole section" do
    test "returns a metrics map keyed by block id", %{section: section} do
      text_block = insert(:block, section: section, type: :text, order: 10)
      code_block = insert(:block, section: section, type: :code, order: 20)

      result = Metrics.get_metrics(%{resource_type: :section, resource_id: section.id})

      assert Map.has_key?(result, text_block.id)
      assert Map.has_key?(result, code_block.id)
      assert result[text_block.id].sample_size == 0
    end
  end

  describe "backtrack_count (via get_metrics/1)" do
    test "counts a session that viewed a later block and then returned to an earlier one", %{
      section: section
    } do
      theory = insert(:block, section: section, type: :text, order: 10)
      question = insert(:block, section: section, type: :quiz_question, order: 20)

      account = insert(:account)
      session = Ecto.UUID.generate()

      record(account.id, nil, session, theory, :viewport_enter, 0)
      record(account.id, nil, session, question, :viewport_enter, 10)
      # backtrack: returns to the earlier block after having reached the later one
      record(account.id, nil, session, theory, :viewport_enter, 20)

      metrics = Metrics.get_metrics(%{resource_type: :block, resource_id: theory.id})
      assert metrics.backtrack_count == 1
    end

    test "does not count a session that only ever moves forward", %{section: section} do
      theory = insert(:block, section: section, type: :text, order: 10)
      question = insert(:block, section: section, type: :quiz_question, order: 20)

      account = insert(:account)
      session = Ecto.UUID.generate()

      record(account.id, nil, session, theory, :viewport_enter, 0)
      record(account.id, nil, session, question, :viewport_enter, 10)

      metrics = Metrics.get_metrics(%{resource_type: :block, resource_id: theory.id})
      assert metrics.backtrack_count == 0
    end

    test "backtrack_rate normalizes the count by how many students were observed", %{
      section: section
    } do
      theory = insert(:block, section: section, type: :text, order: 10)
      question = insert(:block, section: section, type: :quiz_question, order: 20)

      backtracker = insert(:account)
      forward_only = insert(:account)

      backtracker_session = Ecto.UUID.generate()
      record(backtracker.id, nil, backtracker_session, theory, :viewport_enter, 0)
      record(backtracker.id, nil, backtracker_session, question, :viewport_enter, 10)
      record(backtracker.id, nil, backtracker_session, theory, :viewport_enter, 20)

      forward_session = Ecto.UUID.generate()
      record(forward_only.id, nil, forward_session, theory, :viewport_enter, 0)
      record(forward_only.id, nil, forward_session, question, :viewport_enter, 10)

      metrics = Metrics.get_metrics(%{resource_type: :block, resource_id: theory.id})
      assert metrics.backtrack_count == 1
      assert metrics.students_observed == 2
      assert_in_delta metrics.backtrack_rate, 0.5, 0.001
    end
  end

  describe "get_metrics/1 - hesitation_rate" do
    test "is the share of observed students who changed an answer at least once", %{
      section: section
    } do
      block = insert(:block, section: section, type: :quiz_question, order: 10)
      hesitant = insert(:account)
      confident = insert(:account)

      record(hesitant.id, nil, Ecto.UUID.generate(), block, :answer_selected, 0)
      record(hesitant.id, nil, Ecto.UUID.generate(), block, :answer_changed, 1)
      record(confident.id, nil, Ecto.UUID.generate(), block, :answer_selected, 0)

      metrics = Metrics.get_metrics(%{resource_type: :block, resource_id: block.id})
      assert metrics.students_observed == 2
      assert_in_delta metrics.hesitation_rate, 0.5, 0.001
    end
  end

  describe "get_metrics/1 for a video block - skip_ratio" do
    test "averages forward-skip ratio across sessions that finished the video", %{
      section: section
    } do
      block = insert(:block, section: section, type: :video, order: 10)
      account = insert(:account)
      session = Ecto.UUID.generate()

      record(account.id, nil, session, block, :video_seek, 0, %{"from_sec" => 0, "to_sec" => 30})
      record(account.id, nil, session, block, :video_ended, 1, %{"duration" => 100})

      metrics = Metrics.get_metrics(%{resource_type: :block, resource_id: block.id})
      assert_in_delta metrics.skip_ratio, 0.3, 0.001
    end

    test "is nil when no session ever reported a video_ended duration", %{section: section} do
      block = insert(:block, section: section, type: :video, order: 10)
      account = insert(:account)

      record(account.id, nil, Ecto.UUID.generate(), block, :video_seek, 0, %{
        "from_sec" => 0,
        "to_sec" => 30
      })

      metrics = Metrics.get_metrics(%{resource_type: :block, resource_id: block.id})
      assert metrics.skip_ratio == nil
    end
  end

  describe "get_metrics/1 with an account_id filter" do
    test "scopes metrics to just that student", %{section: section} do
      block = insert(:block, section: section, type: :text, order: 10)
      account_a = insert(:account)
      account_b = insert(:account)

      session_a = Ecto.UUID.generate()
      session_b = Ecto.UUID.generate()

      record(account_a.id, nil, session_a, block, :viewport_enter, 0)
      record(account_a.id, nil, session_a, block, :viewport_exit, 10)
      record(account_b.id, nil, session_b, block, :viewport_enter, 0)
      record(account_b.id, nil, session_b, block, :viewport_exit, 100)

      metrics =
        Metrics.get_metrics(%{
          resource_type: :block,
          resource_id: block.id,
          account_id: account_a.id
        })

      assert metrics.sample_size == 1
      assert_in_delta metrics.avg_dwell_seconds, 10.0, 0.01
    end
  end

  describe "funnel/2" do
    test "counts distinct accounts that opened vs. interacted with a block", %{section: section} do
      block = insert(:block, section: section, type: :text, order: 10)
      opener_only = insert(:account)
      interactor = insert(:account)

      record(opener_only.id, nil, Ecto.UUID.generate(), block, :viewport_enter, 0)
      record(interactor.id, nil, Ecto.UUID.generate(), block, :viewport_enter, 0)
      record(interactor.id, nil, Ecto.UUID.generate(), block, :viewport_exit, 10)

      [opened, interacted] = Metrics.funnel(block.id)
      assert opened == %{stage: "opened", accounts: 2}
      assert interacted == %{stage: "interacted", accounts: 1}
    end
  end

  describe "correlate/2" do
    test "returns 1.0 for a perfectly linear relationship" do
      a = %{"acc1" => 1.0, "acc2" => 2.0, "acc3" => 3.0}
      b = %{"acc1" => 10.0, "acc2" => 20.0, "acc3" => 30.0}

      assert_in_delta Metrics.correlate(a, b), 1.0, 0.0001
    end

    test "returns nil when fewer than 2 accounts overlap" do
      assert Metrics.correlate(%{"acc1" => 1.0}, %{"acc1" => 2.0}) == nil
      assert Metrics.correlate(%{"acc1" => 1.0}, %{"acc2" => 2.0}) == nil
    end

    test "returns nil when one side has zero variance" do
      a = %{"acc1" => 5.0, "acc2" => 5.0, "acc3" => 5.0}
      b = %{"acc1" => 1.0, "acc2" => 2.0, "acc3" => 3.0}

      assert Metrics.correlate(a, b) == nil
    end
  end

  describe "time_series/3" do
    test "buckets events by week and computes the requested metric", %{section: section} do
      block = insert(:block, section: section, type: :text, order: 10)
      account = insert(:account)

      week_1_session = Ecto.UUID.generate()
      week_2_session = Ecto.UUID.generate()

      # Week of 2026-01-05 (Monday)
      record(account.id, nil, week_1_session, block, :viewport_enter, 0)
      record(account.id, nil, week_1_session, block, :viewport_exit, 10)

      # A week later
      record(account.id, nil, week_2_session, block, :viewport_enter, 7 * 24 * 60 * 60)
      record(account.id, nil, week_2_session, block, :viewport_exit, 7 * 24 * 60 * 60 + 40)

      series = Metrics.time_series(block.id, nil, :sample_size)
      assert length(series) == 2
      assert Enum.all?(series, &(&1.value == 1))
      assert [%{week: first_week}, %{week: second_week}] = series
      assert Date.compare(first_week, second_week) == :lt
    end
  end

  describe "export_wide_table/2" do
    test "produces one row per student per block, tagged with cohort/block ids", %{
      course: course,
      section: section
    } do
      block_a = insert(:block, section: section, type: :text, order: 10)
      block_b = insert(:block, section: section, type: :code, order: 20)

      cohort = insert(:cohort)
      student_a = insert(:account)
      student_b = insert(:account)
      insert(:cohort_membership, account_id: student_a.id, cohort_id: cohort.id)
      insert(:cohort_membership, account_id: student_b.id, cohort_id: cohort.id)

      session = Ecto.UUID.generate()
      record(student_a.id, cohort.id, session, block_a, :viewport_enter, 0)
      record(student_a.id, cohort.id, session, block_a, :viewport_exit, 20)

      rows = Metrics.export_wide_table(course.id, [cohort.id])

      # 2 blocks x 2 students = 4 rows
      assert length(rows) == 4

      assert Enum.all?(rows, &(&1.cohort_id == cohort.id))
      assert Enum.all?(rows, &(&1.account_id in [student_a.id, student_b.id]))
      assert Enum.all?(rows, &(&1.block_id in [block_a.id, block_b.id]))

      row =
        Enum.find(rows, &(&1.block_id == block_a.id and &1.account_id == student_a.id))

      assert row.block_type == :text
      assert row.sample_size == 1
    end

    test "returns an empty list when the cohort has no members", %{
      course: course,
      section: section
    } do
      insert(:block, section: section, type: :text, order: 10)
      cohort = insert(:cohort)

      assert Metrics.export_wide_table(course.id, [cohort.id]) == []
    end
  end

  describe "get_metrics/1 - offtask_ratio" do
    test "is the share of raw window time spent tabbed away", %{section: section} do
      block = insert(:block, section: section, type: :text, order: 10)
      account = insert(:account)
      session = Ecto.UUID.generate()

      record(account.id, nil, session, block, :viewport_enter, 0)
      record(account.id, nil, session, block, :tab_hidden, 10)
      record(account.id, nil, session, block, :tab_visible, 30, %{"duration_ms" => 20_000})
      record(account.id, nil, session, block, :viewport_exit, 100)

      metrics = Metrics.get_metrics(%{resource_type: :block, resource_id: block.id})
      # 20s off-task out of a 100s raw window
      assert_in_delta metrics.offtask_ratio, 0.2, 0.001
    end

    test "is nil when the block was never opened", %{section: section} do
      block = insert(:block, section: section, type: :text, order: 10)
      metrics = Metrics.get_metrics(%{resource_type: :block, resource_id: block.id})
      assert metrics.offtask_ratio == nil
    end

    test "is 0.0 when the student never left the tab", %{section: section} do
      block = insert(:block, section: section, type: :text, order: 10)
      account = insert(:account)
      session = Ecto.UUID.generate()

      record(account.id, nil, session, block, :viewport_enter, 0)
      record(account.id, nil, session, block, :viewport_exit, 30)

      metrics = Metrics.get_metrics(%{resource_type: :block, resource_id: block.id})
      assert metrics.offtask_ratio == 0.0
    end
  end

  describe "cohort_flag_profile/3" do
    test "one flag firing on the only student x block observation gives that axis a rate of 1.0, others 0.0",
         %{section: section, course: course} do
      cohort = insert(:cohort)

      block =
        insert(:block,
          section: section,
          type: :text,
          order: 10,
          engagement_rule: %EngagementRule{expected_seconds: 100}
        )

      account = insert(:account)
      insert(:cohort_membership, account_id: account.id, cohort_id: cohort.id)
      session = Ecto.UUID.generate()

      # fast_dwell: 5s against a 100s expectation, well under the 0.5 ratio
      # threshold, and the only event in scope.
      record(account.id, cohort.id, session, block, :viewport_enter, 0)
      record(account.id, cohort.id, session, block, :viewport_exit, 5)

      profile = Metrics.cohort_flag_profile(cohort.id, course.id, since: ~U[2020-01-01 00:00:00Z])

      assert profile.fast_dwell == 1.0
      assert profile.heavy_paste == 0.0
      assert profile.backtracked == 0.0
      assert profile.panic_debugging == 0.0
    end

    test "an empty cohort yields 0.0 on every axis, not a crash", %{course: course} do
      cohort = insert(:cohort)

      profile = Metrics.cohort_flag_profile(cohort.id, course.id)

      assert Enum.all?(Map.values(profile), &(&1 == 0.0))
      assert Map.has_key?(profile, :fast_dwell)
      assert Map.has_key?(profile, :panic_debugging)
    end

    test "the rate is the fraction of student x block observations where the flag fired", %{
      section: section,
      course: course
    } do
      cohort = insert(:cohort)
      block = insert(:block, section: section, type: :quiz_question, order: 10)
      pasty = insert(:account)
      clean = insert(:account)
      insert(:cohort_membership, account_id: pasty.id, cohort_id: cohort.id)
      insert(:cohort_membership, account_id: clean.id, cohort_id: cohort.id)

      record(pasty.id, cohort.id, Ecto.UUID.generate(), block, :paste_detected, 0, %{
        "pasted_chars" => 95,
        "total_chars" => 100
      })

      profile = Metrics.cohort_flag_profile(cohort.id, course.id, since: ~U[2020-01-01 00:00:00Z])

      # 2 students x 1 block = 2 observations, only 1 fired heavy_paste.
      assert profile.heavy_paste == 0.5
    end

    test "events before :since are not counted", %{section: section, course: course} do
      cohort = insert(:cohort)

      block =
        insert(:block,
          section: section,
          type: :text,
          order: 10,
          engagement_rule: %EngagementRule{expected_seconds: 100}
        )

      account = insert(:account)
      insert(:cohort_membership, account_id: account.id, cohort_id: cohort.id)
      session = Ecto.UUID.generate()

      record(account.id, cohort.id, session, block, :viewport_enter, 0)
      record(account.id, cohort.id, session, block, :viewport_exit, 5)

      # `since` is set to a minute after the events above (offsets are
      # relative to the fixed 2026-01-05 12:00:00Z base `record/7` uses).
      profile = Metrics.cohort_flag_profile(cohort.id, course.id, since: ~U[2026-01-05 12:01:00Z])

      assert profile.fast_dwell == 0.0
    end

    test "a struggling-only student's flags don't leak into slacking axes", %{
      section: section,
      course: course
    } do
      cohort = insert(:cohort)

      block =
        insert(:block,
          section: section,
          type: :text,
          order: 10,
          engagement_rule: %EngagementRule{expected_seconds: 100}
        )

      account = insert(:account)
      insert(:cohort_membership, account_id: account.id, cohort_id: cohort.id)
      session = Ecto.UUID.generate()

      # slow_dwell: 250s against a 100s expectation, over the 2.0 ratio
      # threshold.
      record(account.id, cohort.id, session, block, :viewport_enter, 0)
      record(account.id, cohort.id, session, block, :viewport_exit, 250)

      profile = Metrics.cohort_flag_profile(cohort.id, course.id, since: ~U[2020-01-01 00:00:00Z])

      assert profile.slow_dwell == 1.0
      assert profile.fast_dwell == 0.0
      assert profile.heavy_paste == 0.0
    end
  end

  describe "section_flag_totals/3" do
    test "counts are attributed to the section a flag's block belongs to, in course order" do
      course = insert(:course)
      cohort = insert(:cohort)

      section_a = insert(:section, course: course, title: "Intro", order: 10)
      section_b = insert(:section, course: course, title: "Advanced", order: 20)

      block_a =
        insert(:block,
          section: section_a,
          type: :text,
          order: 10,
          engagement_rule: %EngagementRule{expected_seconds: 100}
        )

      block_b = insert(:block, section: section_b, type: :quiz_question, order: 10)

      account = insert(:account)
      insert(:cohort_membership, account_id: account.id, cohort_id: cohort.id)
      session = Ecto.UUID.generate()

      # fast_dwell on section_a's block.
      record(account.id, cohort.id, session, block_a, :viewport_enter, 0)
      record(account.id, cohort.id, session, block_a, :viewport_exit, 5)

      # heavy_paste on section_b's block.
      record(account.id, cohort.id, Ecto.UUID.generate(), block_b, :paste_detected, 0, %{
        "pasted_chars" => 95,
        "total_chars" => 100
      })

      totals =
        Metrics.section_flag_totals(cohort.id, course.id, since: ~U[2020-01-01 00:00:00Z])

      assert [row_a, row_b] = totals
      assert row_a.section_id == section_a.id
      assert row_a.section_title == "Intro"
      assert row_a.slacking_count == 1
      assert row_a.struggling_count == 0

      assert row_b.section_id == section_b.id
      assert row_b.section_title == "Advanced"
      assert row_b.slacking_count == 1
      assert row_b.struggling_count == 0
    end

    test "a section with no flagged behavior reports 0/0, not a crash" do
      course = insert(:course)
      cohort = insert(:cohort)
      section = insert(:section, course: course, title: "Quiet", order: 10)
      insert(:block, section: section, type: :text, order: 10)

      totals = Metrics.section_flag_totals(cohort.id, course.id)

      assert [%{slacking_count: 0, struggling_count: 0}] = totals
    end

    test "counts are summed across every student in the cohort, not just one" do
      course = insert(:course)
      cohort = insert(:cohort)
      section = insert(:section, course: course, title: "Shared", order: 10)
      block = insert(:block, section: section, type: :quiz_question, order: 10)

      student_a = insert(:account)
      student_b = insert(:account)
      insert(:cohort_membership, account_id: student_a.id, cohort_id: cohort.id)
      insert(:cohort_membership, account_id: student_b.id, cohort_id: cohort.id)

      for student <- [student_a, student_b] do
        record(student.id, cohort.id, Ecto.UUID.generate(), block, :paste_detected, 0, %{
          "pasted_chars" => 95,
          "total_chars" => 100
        })
      end

      [row] = Metrics.section_flag_totals(cohort.id, course.id, since: ~U[2020-01-01 00:00:00Z])

      assert row.slacking_count == 2
    end

    test "events before :since are not counted" do
      course = insert(:course)
      cohort = insert(:cohort)
      section = insert(:section, course: course, title: "Windowed", order: 10)

      block =
        insert(:block,
          section: section,
          type: :text,
          order: 10,
          engagement_rule: %EngagementRule{expected_seconds: 100}
        )

      account = insert(:account)
      insert(:cohort_membership, account_id: account.id, cohort_id: cohort.id)
      session = Ecto.UUID.generate()

      record(account.id, cohort.id, session, block, :viewport_enter, 0)
      record(account.id, cohort.id, session, block, :viewport_exit, 5)

      [row] =
        Metrics.section_flag_totals(cohort.id, course.id, since: ~U[2026-01-05 12:01:00Z])

      assert row.slacking_count == 0
    end
  end

  describe "activity_heatmap/3" do
    test "always returns the full 168-cell (7 day x 24 hour) grid, zeros included", %{
      course: course
    } do
      cells = Metrics.activity_heatmap(nil, course.id)

      assert length(cells) == 168
      assert Enum.all?(cells, &(&1.count == 0))
      assert Enum.all?(cells, &(&1.day_of_week in 1..7))
      assert Enum.all?(cells, &(&1.hour in 0..23))
    end

    test "an event lands in the cell matching its own day of week and UTC hour", %{
      section: section,
      course: course
    } do
      block = insert(:block, section: section, type: :text, order: 10)
      account = insert(:account)
      session = Ecto.UUID.generate()

      # The fixed base `record/7` uses, ~U[2026-01-05 12:00:00Z].
      expected_day = Date.day_of_week(~D[2026-01-05])
      record(account.id, nil, session, block, :viewport_enter, 0)

      cells = Metrics.activity_heatmap(nil, course.id, since: ~U[2020-01-01 00:00:00Z])
      cell = Enum.find(cells, &(&1.day_of_week == expected_day and &1.hour == 12))

      assert cell.count == 1
      assert Enum.filter(cells, &(&1.count > 0)) == [cell]
    end

    test "multiple events in the same slot are summed", %{section: section, course: course} do
      block = insert(:block, section: section, type: :text, order: 10)
      account = insert(:account)

      record(account.id, nil, Ecto.UUID.generate(), block, :viewport_enter, 0)
      record(account.id, nil, Ecto.UUID.generate(), block, :viewport_enter, 60)
      record(account.id, nil, Ecto.UUID.generate(), block, :viewport_enter, 120)

      expected_day = Date.day_of_week(~D[2026-01-05])
      cells = Metrics.activity_heatmap(nil, course.id, since: ~U[2020-01-01 00:00:00Z])
      cell = Enum.find(cells, &(&1.day_of_week == expected_day and &1.hour == 12))

      assert cell.count == 3
    end

    test "counts every event type, not just viewport dwell", %{section: section, course: course} do
      block = insert(:block, section: section, type: :quiz_question, order: 10)
      account = insert(:account)

      record(account.id, nil, Ecto.UUID.generate(), block, :paste_detected, 0, %{
        "pasted_chars" => 10,
        "total_chars" => 10
      })

      expected_day = Date.day_of_week(~D[2026-01-05])
      cells = Metrics.activity_heatmap(nil, course.id, since: ~U[2020-01-01 00:00:00Z])
      cell = Enum.find(cells, &(&1.day_of_week == expected_day and &1.hour == 12))

      assert cell.count == 1
    end

    test "events before :since are not counted", %{section: section, course: course} do
      block = insert(:block, section: section, type: :text, order: 10)
      account = insert(:account)

      record(account.id, nil, Ecto.UUID.generate(), block, :viewport_enter, 0)

      cells = Metrics.activity_heatmap(nil, course.id, since: ~U[2026-01-05 12:01:00Z])

      assert Enum.all?(cells, &(&1.count == 0))
    end
  end

  describe "course_funnel/3" do
    test "opened counts distinct accounts who entered any block in the section", %{
      course: course,
      section: section
    } do
      block = insert(:block, section: section, type: :text, order: 10)
      account_a = insert(:account)
      account_b = insert(:account)

      record(account_a.id, nil, Ecto.UUID.generate(), block, :viewport_enter, 0)
      record(account_b.id, nil, Ecto.UUID.generate(), block, :viewport_enter, 0)

      [row] = Metrics.course_funnel(nil, course.id, since: ~U[2020-01-01 00:00:00Z])

      assert row.section_id == section.id
      assert row.opened == 2
      assert row.interacted == 0
      assert row.completed == 0
    end

    test "interacted only counts students who also opened, not interaction alone", %{
      course: course,
      section: section
    } do
      block = insert(:block, section: section, type: :text, order: 10)
      session = Ecto.UUID.generate()
      account = insert(:account)

      record(account.id, nil, session, block, :viewport_enter, 0)
      record(account.id, nil, session, block, :viewport_exit, 30)

      [row] = Metrics.course_funnel(nil, course.id, since: ~U[2020-01-01 00:00:00Z])

      assert row.opened == 1
      assert row.interacted == 1
    end

    test "completed counts only students who finished every block in the section", %{
      course: course,
      section: section
    } do
      block_a = insert(:block, section: section, type: :text, order: 10)
      block_b = insert(:block, section: section, type: :text, order: 20)

      finisher = insert(:account)
      partial = insert(:account)

      for account <- [finisher, partial] do
        record(account.id, nil, Ecto.UUID.generate(), block_a, :viewport_enter, 0)
      end

      Learning.mark_completed(finisher.id, block_a.id)
      Learning.mark_completed(finisher.id, block_b.id)
      Learning.mark_completed(partial.id, block_a.id)

      [row] = Metrics.course_funnel(nil, course.id, since: ~U[2020-01-01 00:00:00Z])

      assert row.opened == 2
      assert row.completed == 1
    end

    test "attributes each section's counts independently, in course order" do
      course = insert(:course)
      section_a = insert(:section, course: course, title: "Intro", order: 10)
      section_b = insert(:section, course: course, title: "Advanced", order: 20)
      block_a = insert(:block, section: section_a, type: :text, order: 10)
      _block_b = insert(:block, section: section_b, type: :text, order: 10)

      account = insert(:account)
      record(account.id, nil, Ecto.UUID.generate(), block_a, :viewport_enter, 0)

      rows = Metrics.course_funnel(nil, course.id, since: ~U[2020-01-01 00:00:00Z])

      assert [row_a, row_b] = rows
      assert row_a.section_id == section_a.id
      assert row_a.opened == 1
      # `block_b`'s section never got an event, confirming the count truly
      # belongs to `section_a` and wasn't just summed across the course.
      assert row_b.section_id == section_b.id
      assert row_b.opened == 0
    end

    test "events before :since don't count toward opened/interacted", %{
      course: course,
      section: section
    } do
      block = insert(:block, section: section, type: :text, order: 10)
      account = insert(:account)

      record(account.id, nil, Ecto.UUID.generate(), block, :viewport_enter, 0)

      [row] = Metrics.course_funnel(nil, course.id, since: ~U[2026-01-05 12:01:00Z])

      assert row.opened == 0
    end

    test "a section with no blocks at all reports all zeros, not a crash" do
      course = insert(:course)
      insert(:section, course: course, title: "Empty", order: 10)

      [row] = Metrics.course_funnel(nil, course.id)

      assert row == %{
               section_id: row.section_id,
               section_title: "Empty",
               opened: 0,
               interacted: 0,
               completed: 0
             }
    end
  end

  describe "active_students_trend/3" do
    test "one row per distinct day with activity, sorted ascending", %{
      course: course,
      section: section
    } do
      block = insert(:block, section: section, type: :text, order: 10)
      account = insert(:account)

      # Base is ~U[2026-01-05 12:00:00Z] - one event that day, one three
      # days later.
      record(account.id, nil, Ecto.UUID.generate(), block, :viewport_enter, 0)
      record(account.id, nil, Ecto.UUID.generate(), block, :viewport_enter, 3 * 86_400)

      trend = Metrics.active_students_trend(nil, course.id, since: ~U[2020-01-01 00:00:00Z])

      assert trend == [
               %{date: ~D[2026-01-05], active_count: 1},
               %{date: ~D[2026-01-08], active_count: 1}
             ]
    end

    test "the same student active twice in one day is still counted once", %{
      course: course,
      section: section
    } do
      block = insert(:block, section: section, type: :text, order: 10)
      account = insert(:account)

      record(account.id, nil, Ecto.UUID.generate(), block, :viewport_enter, 0)
      record(account.id, nil, Ecto.UUID.generate(), block, :viewport_enter, 3600)

      [row] = Metrics.active_students_trend(nil, course.id, since: ~U[2020-01-01 00:00:00Z])

      assert row.active_count == 1
    end

    test "two distinct students active the same day both count", %{
      course: course,
      section: section
    } do
      block = insert(:block, section: section, type: :text, order: 10)
      account_a = insert(:account)
      account_b = insert(:account)

      record(account_a.id, nil, Ecto.UUID.generate(), block, :viewport_enter, 0)
      record(account_b.id, nil, Ecto.UUID.generate(), block, :viewport_enter, 60)

      [row] = Metrics.active_students_trend(nil, course.id, since: ~U[2020-01-01 00:00:00Z])

      assert row.active_count == 2
    end

    test "events before :since are excluded", %{course: course, section: section} do
      block = insert(:block, section: section, type: :text, order: 10)
      account = insert(:account)

      record(account.id, nil, Ecto.UUID.generate(), block, :viewport_enter, 0)

      trend = Metrics.active_students_trend(nil, course.id, since: ~U[2026-01-05 12:01:00Z])

      assert trend == []
    end

    test "a course with no activity at all returns an empty list, not a crash", %{
      course: course
    } do
      assert Metrics.active_students_trend(nil, course.id) == []
    end
  end

  describe "nudge_correction_rate/3" do
    test "a student whose next dwell is no longer fast counts as corrected", %{
      course: course,
      section: section
    } do
      block =
        insert(:block,
          section: section,
          type: :text,
          order: 10,
          engagement_rule: %EngagementRule{expected_seconds: 100}
        )

      account = insert(:account)

      record(account.id, nil, Ecto.UUID.generate(), block, :nudge_shown, 500, %{
        "reason" => "fast_dwell"
      })

      # After the nudge: a dwell right at the expected duration - no
      # fast_dwell flag on the block's own state anymore.
      session = Ecto.UUID.generate()
      record(account.id, nil, session, block, :viewport_enter, 600)
      record(account.id, nil, session, block, :viewport_exit, 700)

      [row] = Metrics.nudge_correction_rate(nil, course.id, since: ~U[2020-01-01 00:00:00Z])

      assert row.reason == :fast_dwell
      assert row.nudged_count == 1
      assert row.corrected_count == 1
      assert row.correction_rate == 1.0
    end

    test "a student who fast-dwells again afterward counts as not corrected", %{
      course: course,
      section: section
    } do
      block =
        insert(:block,
          section: section,
          type: :text,
          order: 10,
          engagement_rule: %EngagementRule{expected_seconds: 100}
        )

      account = insert(:account)

      record(account.id, nil, Ecto.UUID.generate(), block, :nudge_shown, 500, %{
        "reason" => "fast_dwell"
      })

      # After the nudge: still a fast dwell.
      session = Ecto.UUID.generate()
      record(account.id, nil, session, block, :viewport_enter, 600)
      record(account.id, nil, session, block, :viewport_exit, 605)

      [row] = Metrics.nudge_correction_rate(nil, course.id, since: ~U[2020-01-01 00:00:00Z])

      assert row.nudged_count == 1
      assert row.corrected_count == 0
      assert row.correction_rate == 0.0
    end

    test "different reasons are tallied as separate rows", %{course: course, section: section} do
      block = insert(:block, section: section, type: :quiz_question, order: 10)
      account = insert(:account)

      record(account.id, nil, Ecto.UUID.generate(), block, :nudge_shown, 0, %{
        "reason" => "fast_dwell"
      })

      record(account.id, nil, Ecto.UUID.generate(), block, :nudge_shown, 60, %{
        "reason" => "heavy_paste"
      })

      rows = Metrics.nudge_correction_rate(nil, course.id, since: ~U[2020-01-01 00:00:00Z])
      reasons = Enum.map(rows, & &1.reason)

      assert :fast_dwell in reasons
      assert :heavy_paste in reasons
      assert length(rows) == 2
    end

    test "nudged_count and corrected_count aggregate across multiple students for one reason", %{
      course: course,
      section: section
    } do
      block =
        insert(:block,
          section: section,
          type: :text,
          order: 10,
          engagement_rule: %EngagementRule{expected_seconds: 100}
        )

      corrected_student = insert(:account)
      uncorrected_student = insert(:account)

      record(corrected_student.id, nil, Ecto.UUID.generate(), block, :nudge_shown, 0, %{
        "reason" => "fast_dwell"
      })

      record(uncorrected_student.id, nil, Ecto.UUID.generate(), block, :nudge_shown, 0, %{
        "reason" => "fast_dwell"
      })

      corrected_session = Ecto.UUID.generate()
      record(corrected_student.id, nil, corrected_session, block, :viewport_enter, 100)
      record(corrected_student.id, nil, corrected_session, block, :viewport_exit, 200)

      uncorrected_session = Ecto.UUID.generate()
      record(uncorrected_student.id, nil, uncorrected_session, block, :viewport_enter, 100)
      record(uncorrected_student.id, nil, uncorrected_session, block, :viewport_exit, 105)

      [row] = Metrics.nudge_correction_rate(nil, course.id, since: ~U[2020-01-01 00:00:00Z])

      assert row.nudged_count == 2
      assert row.corrected_count == 1
      assert row.correction_rate == 0.5
    end

    test "a nudge before :since is not counted at all", %{course: course, section: section} do
      block = insert(:block, section: section, type: :quiz_question, order: 10)
      account = insert(:account)

      record(account.id, nil, Ecto.UUID.generate(), block, :nudge_shown, 0, %{
        "reason" => "heavy_paste"
      })

      rows = Metrics.nudge_correction_rate(nil, course.id, since: ~U[2026-01-05 12:01:00Z])

      assert rows == []
    end

    test "an unrecognized reason string is ignored, not a crash", %{
      course: course,
      section: section
    } do
      block = insert(:block, section: section, type: :quiz_question, order: 10)
      account = insert(:account)

      record(account.id, nil, Ecto.UUID.generate(), block, :nudge_shown, 0, %{
        "reason" => "not_a_real_flag"
      })

      record(account.id, nil, Ecto.UUID.generate(), block, :nudge_shown, 60, %{
        "reason" => "heavy_paste"
      })

      rows = Metrics.nudge_correction_rate(nil, course.id, since: ~U[2020-01-01 00:00:00Z])

      assert [%{reason: :heavy_paste}] = rows
    end

    test "a course with no nudges at all returns an empty list, not a crash", %{course: course} do
      assert Metrics.nudge_correction_rate(nil, course.id) == []
    end
  end

  # Regression coverage for the N+1 query storm fixed alongside this test:
  # `section_flag_totals/3` and `nudge_correction_rate/3` used to re-query
  # a block's section, its sibling blocks, and its events once per (block,
  # student) or (nudge, block) pair, so their DB round-trip count scaled
  # with the size of the course/cohort. `build_scope_index/3` now fetches
  # the whole course's sections/blocks/events once and does the rest in
  # memory, so the query count should stay flat as the grid grows - these
  # tests seed a "small" and a "larger" grid and assert equal (and small)
  # counts rather than pinning an exact number, so the assertion survives
  # incidental query-shape changes without becoming a magic-number trap.
  describe "query count does not scale with grid size" do
    # `:telemetry.attach/4` is process-global - with `async: true`, other
    # tests' queries fire this same event concurrently in their own
    # processes. The query telemetry event is emitted synchronously from
    # whichever process issued the query, so guarding on `self() == test_pid`
    # inside the handler (which runs in the *emitting* process, not
    # necessarily this test's) keeps the count scoped to this test only.
    defp count_queries(fun) do
      ref = make_ref()
      test_pid = self()

      handler = fn _event, _measurements, _metadata, _config ->
        if self() == test_pid, do: send(test_pid, {:query_counted, ref})
      end

      :telemetry.attach({:query_counter, ref}, [:athena, :repo, :query], handler, nil)

      try do
        fun.()
      after
        :telemetry.detach({:query_counter, ref})
      end

      drain_query_count(ref, 0)
    end

    defp drain_query_count(ref, acc) do
      receive do
        {:query_counted, ^ref} -> drain_query_count(ref, acc + 1)
      after
        0 -> acc
      end
    end

    defp seed_grid(section_count, blocks_per_section, student_count) do
      course = insert(:course)
      cohort = insert(:cohort)

      students = for _ <- 1..student_count, do: insert(:account)
      Enum.each(students, &insert(:cohort_membership, account_id: &1.id, cohort_id: cohort.id))

      for s <- 1..section_count do
        section = insert(:section, course: course, order: s * 10)

        for b <- 1..blocks_per_section do
          block = insert(:block, section: section, type: :quiz_question, order: b * 10)

          for student <- students do
            record(student.id, cohort.id, Ecto.UUID.generate(), block, :nudge_shown, 0, %{
              "reason" => "heavy_paste"
            })
          end
        end
      end

      {cohort, course}
    end

    test "section_flag_totals/3 issues the same query count for a small and a larger course/cohort" do
      {small_cohort, small_course} = seed_grid(1, 2, 2)
      {large_cohort, large_course} = seed_grid(3, 4, 5)

      small_count =
        count_queries(fn ->
          Metrics.section_flag_totals(small_cohort.id, small_course.id,
            since: ~U[2020-01-01 00:00:00Z]
          )
        end)

      large_count =
        count_queries(fn ->
          Metrics.section_flag_totals(large_cohort.id, large_course.id,
            since: ~U[2020-01-01 00:00:00Z]
          )
        end)

      assert small_count == large_count
      assert small_count <= 10
    end

    test "nudge_correction_rate/3 issues the same query count regardless of nudge/block count" do
      {small_cohort, small_course} = seed_grid(1, 2, 2)
      {large_cohort, large_course} = seed_grid(3, 4, 5)

      small_count =
        count_queries(fn ->
          Metrics.nudge_correction_rate(small_cohort.id, small_course.id,
            since: ~U[2020-01-01 00:00:00Z]
          )
        end)

      large_count =
        count_queries(fn ->
          Metrics.nudge_correction_rate(large_cohort.id, large_course.id,
            since: ~U[2020-01-01 00:00:00Z]
          )
        end)

      assert small_count == large_count
      assert small_count <= 10
    end
  end
end
