defmodule Athena.Engagement.MetricsTest do
  use Athena.DataCase, async: true

  import Athena.Factory

  alias Athena.Content.EngagementRule
  alias Athena.Engagement
  alias Athena.Engagement.Metrics

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
end
