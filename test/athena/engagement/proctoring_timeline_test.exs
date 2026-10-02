defmodule Athena.Engagement.ProctoringTimelineTest do
  use Athena.DataCase, async: true

  import Athena.Factory

  alias Athena.Engagement
  alias Athena.Engagement.ProctoringTimeline

  @started_at ~U[2026-03-01 10:00:00Z]

  setup do
    student = insert(:account)
    section = insert(:section)
    block = insert(:block, section: section, type: :quiz_exam)
    question = insert(:block, section: section, type: :quiz_question)

    submission =
      insert(:submission,
        account_id: student.id,
        block_id: block.id,
        content: %{
          "started_at" => DateTime.to_iso8601(@started_at),
          "questions" => [%{"id" => question.id}]
        }
      )

    %{
      student: student,
      section: section,
      block: block,
      question: question,
      submission: submission
    }
  end

  defp record(ctx, block_id, type, seconds_in, payload \\ %{}) do
    Engagement.record_events(ctx.student.id, nil, Ecto.UUID.generate(), [
      %{
        block_id: block_id,
        section_id: ctx.section.id,
        event_type: type,
        payload: payload,
        occurred_at: DateTime.add(@started_at, seconds_in, :second)
      }
    ])
  end

  test "an absence is placed at the moment it began, using the duration the return event carries",
       ctx do
    record(ctx, ctx.question.id, :tab_visible, 100, %{"duration_ms" => 30_000})

    assert [%{type: :tab_away, offset: 70, duration_ms: 30_000}] =
             ProctoringTimeline.build(ctx.submission)
  end

  test "events from the exam block and from its questions are both included, in order", ctx do
    record(ctx, ctx.question.id, :copy_attempt, 50)
    record(ctx, ctx.block.id, :printscreen_attempt, 20)

    assert [%{type: :printscreen_attempt, offset: 20}, %{type: :copy_attempt, offset: 50}] =
             ProctoringTimeline.build(ctx.submission)
  end

  test "another student's events and unrelated event types are left out", ctx do
    other = insert(:account)

    Engagement.record_events(other.id, nil, Ecto.UUID.generate(), [
      %{
        block_id: ctx.block.id,
        section_id: ctx.section.id,
        event_type: :copy_attempt,
        payload: %{},
        occurred_at: DateTime.add(@started_at, 10, :second)
      }
    ])

    record(ctx, ctx.block.id, :viewport_enter, 5)

    assert ProctoringTimeline.build(ctx.submission) == []
  end

  test "repeated right-clicks within a few seconds read as one burst", ctx do
    for second <- [40, 41, 43], do: record(ctx, ctx.question.id, :right_click_attempt, second)
    record(ctx, ctx.question.id, :right_click_attempt, 120)

    assert [%{offset: 40, count: 3}, %{offset: 120, count: 1}] =
             ProctoringTimeline.build(ctx.submission)
  end

  test "tiny pointer excursions and tiny pastes are noise and are dropped", ctx do
    record(ctx, ctx.question.id, :mouse_left, 30, %{"duration_ms" => 2_500})
    record(ctx, ctx.question.id, :paste_detected, 31, %{"pasted_chars" => 3, "total_chars" => 50})

    record(ctx, ctx.question.id, :paste_detected, 60, %{
      "pasted_chars" => 300,
      "total_chars" => 320
    })

    assert [%{type: :paste_detected, chars: 300, offset: 60}] =
             ProctoringTimeline.build(ctx.submission)
  end

  test "silence incidents stamped into the submission appear on the timeline", ctx do
    incident = %{
      "type" => "silence",
      "at" => DateTime.to_iso8601(DateTime.add(@started_at, 200, :second)),
      "seconds" => 75
    }

    submission = %{
      ctx.submission
      | content: Map.put(ctx.submission.content, "incidents", [incident])
    }

    assert [%{type: :silence, offset: 200, duration_ms: 75_000}] =
             ProctoringTimeline.build(submission)
  end

  describe "one absence is one line" do
    test "an Alt-Tab that fired both tab_visible and window_focus is a single entry", ctx do
      record(ctx, ctx.block.id, :window_focus, 100, %{"duration_ms" => 20_000})
      record(ctx, ctx.block.id, :tab_visible, 99, %{"duration_ms" => 18_000})

      assert [%{type: :tab_away, offset: 80, duration_ms: 20_000, kinds: kinds}] =
               ProctoringTimeline.build(ctx.submission)

      assert Enum.sort(kinds) == [:tab_away, :window_away]
    end

    test "separate absences stay separate", ctx do
      record(ctx, ctx.block.id, :tab_visible, 100, %{"duration_ms" => 10_000})
      record(ctx, ctx.block.id, :window_focus, 200, %{"duration_ms" => 10_000})

      assert [%{offset: 90, type: :tab_away}, %{offset: 190, type: :window_away}] =
               ProctoringTimeline.build(ctx.submission)
    end

    test "a window that merely lost focus is a window entry, not a tab entry", ctx do
      record(ctx, ctx.block.id, :window_focus, 100, %{"duration_ms" => 10_000})

      assert [%{type: :window_away}] = ProctoringTimeline.build(ctx.submission)
    end

    test "leaving fullscreen while already away is folded into that absence", ctx do
      record(ctx, ctx.block.id, :tab_visible, 100, %{"duration_ms" => 30_000})
      record(ctx, ctx.block.id, :fullscreen_exit, 101, %{"duration_ms" => 31_000})

      assert [%{type: :tab_away, offset: 70, duration_ms: 31_000, kinds: kinds}] =
               ProctoringTimeline.build(ctx.submission)

      assert :fullscreen_exit in kinds
    end

    test "the pointer being outside the window during an absence adds nothing", ctx do
      record(ctx, ctx.block.id, :tab_visible, 100, %{"duration_ms" => 30_000})
      record(ctx, ctx.block.id, :mouse_left, 98, %{"duration_ms" => 20_000})

      assert [%{type: :tab_away}] = ProctoringTimeline.build(ctx.submission)
    end

    test "a pointer excursion outside any absence is still listed", ctx do
      record(ctx, ctx.block.id, :tab_visible, 100, %{"duration_ms" => 10_000})
      record(ctx, ctx.block.id, :mouse_left, 300, %{"duration_ms" => 20_000})

      assert [%{type: :tab_away}, %{type: :mouse_left, offset: 280}] =
               ProctoringTimeline.build(ctx.submission)
    end

    test "the timeline and the verdict agree on how many absences there were", ctx do
      # Same three raw events the monitor merges into two absences.
      record(ctx, ctx.block.id, :tab_visible, 100, %{"duration_ms" => 20_000})
      record(ctx, ctx.block.id, :window_focus, 101, %{"duration_ms" => 21_000})
      record(ctx, ctx.block.id, :window_focus, 500, %{"duration_ms" => 12_000})

      assert length(ProctoringTimeline.build(ctx.submission)) == 2
    end
  end
end
