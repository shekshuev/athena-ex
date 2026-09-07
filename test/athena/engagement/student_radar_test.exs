defmodule Athena.Engagement.StudentRadarTest do
  use Athena.DataCase, async: true

  import Athena.Factory

  alias Athena.Content.EngagementRule
  alias Athena.Engagement
  alias Athena.Engagement.Metrics

  setup do
    course = insert(:course)
    section = insert(:section, course: course)
    cohort = insert(:cohort)

    text_block =
      insert(:block,
        section: section,
        type: :text,
        order: 10,
        engagement_rule: %EngagementRule{expected_seconds: 100}
      )

    quiz_block = insert(:block, section: section, type: :quiz_question, order: 20)

    %{
      course: course,
      section: section,
      cohort: cohort,
      text_block: text_block,
      quiz_block: quiz_block
    }
  end

  defp record(account_id, cohort_id, session_id, block, event_type, occurred_at, payload \\ %{}) do
    Engagement.record_events(account_id, cohort_id, session_id, [
      %{
        block_id: block.id,
        section_id: block.section_id,
        event_type: event_type,
        payload: payload,
        occurred_at: occurred_at
      }
    ])
  end

  defp join_cohort(account, cohort) do
    insert(:cohort_membership, account_id: account.id, cohort_id: cohort.id)
  end

  describe "student_radar/3 - status classification" do
    test "a slacking (\"Ivanov\") profile - fast dwell + heavy paste - comes back red", %{
      course: course,
      cohort: cohort,
      text_block: text_block,
      quiz_block: quiz_block
    } do
      ivanov = insert(:account)
      join_cohort(ivanov, cohort)

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      session = Ecto.UUID.generate()

      # dwell_ratio ~0.1, well under the 0.5 :fast_dwell threshold
      record(ivanov.id, cohort.id, session, text_block, :viewport_enter, now)

      record(
        ivanov.id,
        cohort.id,
        session,
        text_block,
        :viewport_exit,
        DateTime.add(now, 10, :second)
      )

      # paste_ratio 0.95, well over the 0.8 :heavy_paste threshold
      record(ivanov.id, cohort.id, Ecto.UUID.generate(), quiz_block, :paste_detected, now, %{
        "pasted_chars" => 95,
        "total_chars" => 100
      })

      [row] =
        Metrics.student_radar(cohort.id, course.id, since: DateTime.add(now, -3600, :second))

      assert row.account_id == ivanov.id
      assert row.status == :red
      assert row.slacking_index == 2
      assert row.struggling_index == 0
      assert length(row.flagged_blocks) == 2

      # `flagged_blocks` also splits each block's flags by category - the
      # aggregations built on top of this grid (cohort-wide flag rates,
      # per-section totals, nudge correction rates) need the split, not
      # just the merged `flags` list and counts.
      for flagged_block <- row.flagged_blocks do
        assert flagged_block.slacking_flags == [:fast_dwell] or
                 flagged_block.slacking_flags == [:heavy_paste]

        assert flagged_block.struggling_flags == []
        assert length(flagged_block.slacking_flags) == flagged_block.slacking_count
        assert length(flagged_block.struggling_flags) == flagged_block.struggling_count

        assert flagged_block.flags ==
                 flagged_block.slacking_flags ++ flagged_block.struggling_flags
      end
    end

    test "a struggling (\"Petrov\") profile - slow dwell + hesitation - comes back yellow", %{
      course: course,
      cohort: cohort,
      text_block: text_block,
      quiz_block: quiz_block
    } do
      petrov = insert(:account)
      join_cohort(petrov, cohort)

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      session = Ecto.UUID.generate()

      # dwell_ratio 2.5, over the 2.0 :slow_dwell threshold
      record(petrov.id, cohort.id, session, text_block, :viewport_enter, now)

      record(
        petrov.id,
        cohort.id,
        session,
        text_block,
        :viewport_exit,
        DateTime.add(now, 250, :second)
      )

      record(petrov.id, cohort.id, Ecto.UUID.generate(), quiz_block, :answer_changed, now)

      [row] =
        Metrics.student_radar(cohort.id, course.id, since: DateTime.add(now, -3600, :second))

      assert row.status == :yellow
      assert row.slacking_index == 0
      assert row.struggling_index == 2
    end

    test "a student with no flagged behavior at all comes back green", %{
      course: course,
      cohort: cohort,
      text_block: text_block
    } do
      calm = insert(:account)
      join_cohort(calm, cohort)

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      session = Ecto.UUID.generate()

      # dwell_ratio exactly 1.0 - neither fast nor slow
      record(calm.id, cohort.id, session, text_block, :viewport_enter, now)

      record(
        calm.id,
        cohort.id,
        session,
        text_block,
        :viewport_exit,
        DateTime.add(now, 100, :second)
      )

      [row] =
        Metrics.student_radar(cohort.id, course.id, since: DateTime.add(now, -3600, :second))

      assert row.status == :green
      assert row.slacking_index == 0
      assert row.struggling_index == 0
      assert row.flagged_blocks == []
    end
  end

  describe "student_radar/3 - time window" do
    test "only counts behavior at or after :since, not a lifetime total", %{
      course: course,
      cohort: cohort,
      text_block: text_block
    } do
      recently_fast = insert(:account)
      join_cohort(recently_fast, cohort)

      long_ago_fast = insert(:account)
      join_cohort(long_ago_fast, cohort)

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      since = DateTime.add(now, -7 * 86_400, :second)

      # Inside the window - should count.
      recent_session = Ecto.UUID.generate()
      record(recently_fast.id, cohort.id, recent_session, text_block, :viewport_enter, now)

      record(
        recently_fast.id,
        cohort.id,
        recent_session,
        text_block,
        :viewport_exit,
        DateTime.add(now, 10, :second)
      )

      # Outside the window (10 days ago) - same fast-dwell pattern, but must
      # not be counted.
      old_at = DateTime.add(now, -10 * 86_400, :second)
      old_session = Ecto.UUID.generate()
      record(long_ago_fast.id, cohort.id, old_session, text_block, :viewport_enter, old_at)

      record(
        long_ago_fast.id,
        cohort.id,
        old_session,
        text_block,
        :viewport_exit,
        DateTime.add(old_at, 10, :second)
      )

      rows = Metrics.student_radar(cohort.id, course.id, since: since)

      recent_row = Enum.find(rows, &(&1.account_id == recently_fast.id))
      old_row = Enum.find(rows, &(&1.account_id == long_ago_fast.id))

      assert recent_row.status == :red or recent_row.slacking_index > 0
      assert old_row.status == :green
      assert old_row.slacking_index == 0
    end

    test "defaults to the last student_radar_default_window_days when :since is omitted", %{
      course: course,
      cohort: cohort,
      text_block: text_block
    } do
      account = insert(:account)
      join_cohort(account, cohort)

      old_at =
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-30 * 86_400, :second)

      session = Ecto.UUID.generate()

      record(account.id, cohort.id, session, text_block, :viewport_enter, old_at)

      record(
        account.id,
        cohort.id,
        session,
        text_block,
        :viewport_exit,
        DateTime.add(old_at, 10, :second)
      )

      [row] = Metrics.student_radar(cohort.id, course.id)

      assert row.status == :green
      assert row.slacking_index == 0
    end
  end

  describe "student_radar/3 - section scoping" do
    test "opts[:section_id] restricts the block set to just that section", %{
      course: course,
      cohort: cohort,
      section: section,
      text_block: text_block
    } do
      other_section = insert(:section, course: course)
      other_block = insert(:block, section: other_section, type: :quiz_question, order: 10)

      account = insert(:account)
      join_cohort(account, cohort)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # A heavy-paste flag on a block outside the scoped section - if
      # section scoping were broken, this would show up in flagged_blocks.
      record(account.id, cohort.id, Ecto.UUID.generate(), other_block, :paste_detected, now, %{
        "pasted_chars" => 95,
        "total_chars" => 100
      })

      [row] =
        Metrics.student_radar(cohort.id, course.id,
          section_id: section.id,
          since: DateTime.add(now, -3600, :second)
        )

      assert row.flagged_blocks == []
      refute Enum.any?(row.flagged_blocks, &(&1.block_id == other_block.id))
      assert row.slacking_index == 0
      # in-scope block exists but produced no flags of its own here
      refute Enum.any?(row.flagged_blocks, &(&1.block_id == text_block.id))
    end
  end
end
