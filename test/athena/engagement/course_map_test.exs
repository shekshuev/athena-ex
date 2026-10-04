defmodule Athena.Engagement.CourseMapTest do
  use Athena.DataCase, async: true

  import Athena.Factory

  alias Athena.Content.EngagementRule
  alias Athena.Engagement
  alias Athena.Engagement.CourseMap

  defp stats(overrides) do
    Map.merge(
      %{
        opened: 0,
        skimmed: 0,
        stuck: 0,
        scored: 0,
        passed: 0,
        attempted: 0,
        attempts_avg: nil,
        content_flags: [],
        backtrack_rate: nil,
        hesitation_rate: nil
      },
      overrides
    )
  end

  describe "cohort_issues/2 and severity/1" do
    test "a quiet block has no issues" do
      assert CourseMap.cohort_issues(stats(%{opened: 10, scored: 10, passed: 10})) == []
      assert CourseMap.severity([]) == nil
    end

    test "low pass share is an issue, critical when very low" do
      assert [%{key: :low_scores, critical?: false}] =
               CourseMap.cohort_issues(stats(%{scored: 10, passed: 5}))

      issues = CourseMap.cohort_issues(stats(%{scored: 10, passed: 2}))
      assert [%{key: :low_scores, critical?: true}] = issues
      assert CourseMap.severity(issues) == :high
    end

    test "behaviour shares and attempts need enough students" do
      assert CourseMap.cohort_issues(stats(%{opened: 2, skimmed: 2})) == []

      keys =
        stats(%{opened: 5, skimmed: 3, stuck: 2, attempted: 4, attempts_avg: 3.0})
        |> CourseMap.cohort_issues()
        |> Enum.map(& &1.key)

      assert keys == [:many_attempts, :skimmed, :stuck]
    end

    test "content flags become issues with their rate" do
      assert [%{key: :high_backtrack_rate, value: 0.7}] =
               CourseMap.cohort_issues(
                 stats(%{content_flags: [:high_backtrack_rate], backtrack_rate: 0.7})
               )
    end
  end

  test "rank/2 puts critical blocks first, then by issue count, then course order" do
    entries = [{0, "a", :medium, 1}, {1, "b", nil, 0}, {2, "c", :high, 1}, {3, "d", :medium, 2}]
    assert CourseMap.rank(entries, 2) == ["c", "d"]
  end

  test "course_map/3 gathers the cohort's numbers and one student's view per block" do
    course = insert(:course)
    section = insert(:section, course: course, title: "Loops")

    text =
      insert(:block,
        section: section,
        type: :text,
        order: 1,
        engagement_rule: %EngagementRule{expected_seconds: 100}
      )

    quiz = insert(:block, section: section, type: :quiz_question, order: 2)
    cohort = insert(:cohort)
    students = for _ <- 1..3, do: insert(:account)
    Enum.each(students, &insert(:cohort_membership, account_id: &1.id, cohort_id: cohort.id))
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for student <- students do
      session = Ecto.UUID.generate()

      Engagement.record_events(student.id, cohort.id, session, [
        %{
          block_id: text.id,
          section_id: section.id,
          event_type: :viewport_enter,
          occurred_at: now
        },
        %{
          block_id: text.id,
          section_id: section.id,
          event_type: :viewport_exit,
          occurred_at: DateTime.add(now, 5)
        }
      ])

      insert(:submission, account_id: student.id, block_id: quiz.id, status: :graded, score: 20)
    end

    [first | _] = students
    map = Engagement.course_map(cohort.id, course.id, account_id: first.id)

    assert [%{section: %{id: section_id}, block_ids: block_ids}] = map.sections
    assert section_id == section.id
    assert block_ids == [text.id, quiz.id]
    assert map.students_count == 3

    text_entry = map.entries[text.id]
    assert %{opened: 3, skimmed: 3} = text_entry.stats
    assert [%{key: :skimmed}] = text_entry.issues
    assert text_entry.student.opened?
    assert Enum.any?(text_entry.student.signals, &(&1.key == :fast_dwell))

    quiz_entry = map.entries[quiz.id]
    assert %{scored: 3, passed: 0, score_avg: 20.0} = quiz_entry.stats
    assert quiz_entry.severity == :high
    assert quiz_entry.student.severity == :high
    assert %{state: :scored, score: 20} = quiz_entry.student.cell
  end

  test "cohort_summary/3 adds up a cohort's progress, levels, scores and sections" do
    course = insert(:course)
    section = insert(:section, course: course)
    quiz = insert(:block, section: section, type: :quiz_question, order: 1)
    cohort = insert(:cohort)
    [a, b] = for _ <- 1..2, do: insert(:account)
    Enum.each([a, b], &insert(:cohort_membership, account_id: &1.id, cohort_id: cohort.id))

    insert(:submission, account_id: a.id, block_id: quiz.id, status: :graded, score: 80)
    insert(:submission, account_id: b.id, block_id: quiz.id, status: :graded, score: 20)
    insert(:submission, account_id: b.id, block_id: quiz.id, status: :graded, score: 40)
    Athena.Learning.mark_completed(a.id, quiz.id)

    summary = Engagement.cohort_summary(cohort.id, course.id, since: nil)

    assert summary.students == 2
    assert summary.progress_sum == 100.0
    assert %{scored: 2, score_sum: 120, attempted: 2, first_try: 1} = summary
    assert %{scored: 2, score_sum: 120, done: 1, total: 2} = summary.sections[section.id]
  end
end
