defmodule Athena.Engagement.GradebookEngagementTest do
  use Athena.DataCase, async: true

  import Athena.Factory

  alias Athena.Content.EngagementRule
  alias Athena.Engagement

  test "levels, theory per task and how each student went through it" do
    course = insert(:course)
    loops = insert(:section, course: course, title: "Loops", order: 10)
    funcs = insert(:section, course: course, title: "Functions", order: 20)

    text =
      insert(:block,
        section: loops,
        type: :text,
        order: 5,
        engagement_rule: %EngagementRule{expected_seconds: 100}
      )

    quiz = insert(:block, section: loops, type: :quiz_question, order: 10)
    exam = insert(:block, section: funcs, type: :quiz_exam, order: 10)

    cohort = insert(:cohort)
    reader = insert(:account)
    skimmer = insert(:account)

    Enum.each(
      [reader, skimmer],
      &insert(:cohort_membership, account_id: &1.id, cohort_id: cohort.id)
    )

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    visit = fn account, seconds ->
      session = Ecto.UUID.generate()

      Engagement.record_events(account.id, cohort.id, session, [
        %{block_id: text.id, section_id: loops.id, event_type: :viewport_enter, occurred_at: now},
        %{
          block_id: text.id,
          section_id: loops.id,
          event_type: :viewport_exit,
          occurred_at: DateTime.add(now, seconds)
        }
      ])
    end

    visit.(reader, 120)
    visit.(skimmer, 5)
    insert(:submission, account_id: skimmer.id, block_id: quiz.id, status: :graded, score: 10)

    layer = Engagement.gradebook_engagement(cohort.id, course.id)

    assert layer.theory_by_task[quiz.id] == [text.id]
    assert layer.theory_by_task[exam.id] == [text.id]
    assert %{status: :ok} = layer.reviews[{reader.id, text.id}]
    assert %{status: :superficial, flags: %{fast_dwell: _}} = layer.reviews[{skimmer.id, text.id}]
    assert layer.levels[skimmer.id] == :not_mastering
    assert layer.content_blocks[loops.id] |> Enum.map(& &1.id) == [text.id]
    assert layer.content_blocks[funcs.id] == []
  end
end
