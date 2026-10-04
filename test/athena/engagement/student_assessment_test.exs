defmodule Athena.Engagement.StudentAssessmentTest do
  use ExUnit.Case, async: true

  alias Athena.Content.Block
  alias Athena.Engagement.StudentAssessment

  @now ~U[2026-10-04 12:00:00Z]

  defp students(n), do: for(i <- 1..n, do: "s#{i}")

  defp context(overrides) do
    quiz = %Block{id: "quiz", section_id: "sec", type: :quiz_question, order: 10}
    text = %Block{id: "text", section_id: "sec", type: :text, order: 5}
    students = Map.get(overrides, :students, students(6))

    Map.merge(
      %{
        students: students,
        blocks: [text, quiz],
        flagged_blocks: %{},
        active: MapSet.new(students),
        cells: %{},
        completed: %{},
        progress: Map.new(students, &{&1, 50.0}),
        window_start: nil,
        theory: fn _account_id, _block -> [%{block_id: "text", status: :superficial}] end
      },
      overrides
    )
  end

  defp cell(score, attempts \\ 1),
    do: %{state: :scored, score: score, attempts: attempts, submitted_at: @now}

  defp keys(result, account_id), do: Enum.map(result[account_id].signals, & &1.key)

  test "everyone fine is on track" do
    result = StudentAssessment.assess_cohort(context(%{}))
    assert Enum.all?(Map.values(result), &(&1.level == :on_track))
  end

  test "no activity in the window, while others were active, is :inactive" do
    result = StudentAssessment.assess_cohort(context(%{active: MapSet.new(["s2", "s3"])}))
    assert result["s1"].level == :inactive
    assert result["s2"].level == :on_track
  end

  test "an empty week for everybody is not anyone's problem" do
    result = StudentAssessment.assess_cohort(context(%{active: MapSet.new()}))
    refute result["s1"].level == :inactive
  end

  test "a low score marks :not_mastering and carries the theory review" do
    cells = %{{"s1", "quiz"} => cell(30), {"s2", "quiz"} => cell(90)}
    result = StudentAssessment.assess_cohort(context(%{cells: cells}))

    assert result["s1"].level == :not_mastering

    assert [%{key: :low_score, value: 30, theory: [%{status: :superficial}]}] =
             result["s1"].signals

    assert result["s2"].level == :on_track
  end

  test "a score far below the group median counts even above the pass mark" do
    cells =
      Map.new(students(6), fn id -> {{id, "quiz"}, cell(if(id == "s1", do: 60, else: 95))} end)

    result = StudentAssessment.assess_cohort(context(%{cells: cells}))
    assert [%{key: :low_score, basis: :group, baseline: 95.0}] = result["s1"].signals
  end

  test "work submitted before the window doesn't count" do
    cells = %{{"s1", "quiz"} => cell(10)}

    result =
      StudentAssessment.assess_cohort(
        context(%{cells: cells, window_start: DateTime.add(@now, 60)})
      )

    assert result["s1"].level == :on_track
  end

  test "many attempts compared with the group" do
    cells =
      Map.new(students(6), fn id -> {{id, "quiz"}, cell(100, if(id == "s1", do: 4, else: 1))} end)

    result = StudentAssessment.assess_cohort(context(%{cells: cells}))
    assert keys(result, "s1") == [:many_attempts]
    assert keys(result, "s2") == []
  end

  test "behind the group's progress and missing what most have done" do
    students = students(6)

    completed =
      Map.new(students, &{&1, if(&1 == "s1", do: MapSet.new(), else: MapSet.new(["text"]))})

    progress = Map.new(students, &{&1, if(&1 == "s1", do: 0.0, else: 80.0)})

    result = StudentAssessment.assess_cohort(context(%{completed: completed, progress: progress}))

    assert result["s1"].level == :behind
    assert :behind_progress in keys(result, "s1")
    assert :missed_block in keys(result, "s1")
  end

  test "group comparisons need enough students" do
    progress = %{"s1" => 0.0, "s2" => 90.0}

    result =
      StudentAssessment.assess_cohort(context(%{students: ["s1", "s2"], progress: progress}))

    assert result["s1"].level == :on_track
  end

  test "behaviour flags become signals with their details and set the level" do
    flagged = %{
      block_id: "text",
      slacking_flags: [:fast_dwell, :shallow_scroll],
      struggling_flags: [],
      integrity_flags: [],
      details: %{fast_dwell: %{value: 10, baseline: 120, basis: :group, peers: 6}}
    }

    result = StudentAssessment.assess_cohort(context(%{flagged_blocks: %{"s1" => [flagged]}}))

    assert result["s1"].level == :superficial

    assert %{key: :fast_dwell, category: :slacking, value: 10, baseline: 120, block_id: "text"} =
             Enum.find(result["s1"].signals, &(&1.key == :fast_dwell))
  end

  test "levels are ranked: integrity beats a low score, a low score beats superficial reading" do
    integrity = %{key: :copy_attempted, category: :integrity}
    low = %{key: :low_score, category: :performance}
    slack = %{key: :fast_dwell, category: :slacking}

    assert StudentAssessment.level([low, integrity, slack, slack]) == :integrity
    assert StudentAssessment.level([low, slack, slack]) == :not_mastering
    assert StudentAssessment.level([slack, slack]) == :superficial
  end
end
