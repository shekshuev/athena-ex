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
        visited: Map.new(students, &{&1, 10}),
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

  test "low scores mark :not_mastering and carry the theory review" do
    quiz2 = %Block{id: "quiz2", section_id: "sec", type: :quiz_question, order: 20}
    text = %Block{id: "text", section_id: "sec", type: :text, order: 5}
    quiz = %Block{id: "quiz", section_id: "sec", type: :quiz_question, order: 10}

    cells = %{
      {"s1", "quiz"} => cell(30),
      {"s1", "quiz2"} => cell(40),
      {"s2", "quiz"} => cell(90),
      {"s2", "quiz2"} => cell(30)
    }

    result =
      StudentAssessment.assess_cohort(context(%{cells: cells, blocks: [text, quiz, quiz2]}))

    assert result["s1"].level == :not_mastering

    assert [%{key: :low_score, value: 30, theory: [%{status: :superficial}]}, %{value: 40}] =
             result["s1"].signals

    # One bad task among good ones is shown, but doesn't make a status.
    assert [%{key: :low_score}] = result["s2"].signals
    assert result["s2"].level == :on_track
  end

  test "many attempts only count when the task still ended below the pass mark" do
    quiz2 = %Block{id: "quiz2", section_id: "sec", type: :quiz_question, order: 20}
    text = %Block{id: "text", section_id: "sec", type: :text, order: 5}
    quiz = %Block{id: "quiz", section_id: "sec", type: :quiz_question, order: 10}
    blocks = [text, quiz, quiz2]

    solved = Map.new(students(6), &{{&1, "quiz"}, cell(100, if(&1 == "s1", do: 4, else: 1))})

    solved =
      Map.merge(
        solved,
        Map.new(students(6), &{{&1, "quiz2"}, cell(100, if(&1 == "s1", do: 5, else: 1))})
      )

    result = StudentAssessment.assess_cohort(context(%{cells: solved, blocks: blocks}))
    assert keys(result, "s1") == [:many_attempts, :many_attempts]
    assert result["s1"].level == :on_track

    failed = %{solved | {"s1", "quiz"} => cell(45, 4), {"s1", "quiz2"} => cell(45, 5)}
    result = StudentAssessment.assess_cohort(context(%{cells: failed, blocks: blocks}))
    assert result["s1"].level == :not_mastering
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
    texts = for i <- 1..10, do: %Block{id: "t#{i}", section_id: "sec", type: :text, order: i}
    all_ids = MapSet.new(texts, & &1.id)
    completed = Map.new(students, &{&1, if(&1 == "s1", do: MapSet.new(), else: all_ids)})
    progress = Map.new(students, &{&1, if(&1 == "s1", do: 0.0, else: 80.0)})

    result =
      StudentAssessment.assess_cohort(
        context(%{blocks: texts, completed: completed, progress: progress})
      )

    assert result["s1"].level == :behind
    assert :behind_progress in keys(result, "s1")
    assert :missed_block in keys(result, "s1")
  end

  test "a few missed blocks of many are not 'behind'" do
    students = students(6)
    texts = for i <- 1..60, do: %Block{id: "t#{i}", section_id: "sec", type: :text, order: i}
    all_ids = MapSet.new(texts, & &1.id)
    # s1 skipped 5 of 60 blocks the group has done: under 10%.
    s1_done = MapSet.difference(all_ids, MapSet.new(["t1", "t2", "t3", "t4", "t5"]))
    completed = Map.new(students, &{&1, if(&1 == "s1", do: s1_done, else: all_ids)})

    result = StudentAssessment.assess_cohort(context(%{blocks: texts, completed: completed}))

    assert length(Enum.filter(result["s1"].signals, &(&1.key == :missed_block))) == 5
    assert result["s1"].level == :on_track
  end

  test "group comparisons need enough students" do
    progress = %{"s1" => 0.0, "s2" => 90.0}

    result =
      StudentAssessment.assess_cohort(context(%{students: ["s1", "s2"], progress: progress}))

    assert result["s1"].level == :on_track
  end

  defp rushed(block_id, details \\ %{}) do
    %{
      block_id: block_id,
      slacking_flags: [:fast_dwell],
      struggling_flags: [],
      integrity_flags: [],
      details: details
    }
  end

  test "behaviour flags become signals with their details" do
    flagged = rushed("text", %{fast_dwell: %{value: 10, baseline: 120, basis: :group, peers: 6}})
    result = StudentAssessment.assess_cohort(context(%{flagged_blocks: %{"s1" => [flagged]}}))

    assert %{key: :fast_dwell, category: :slacking, value: 10, baseline: 120, block_id: "text"} =
             Enum.find(result["s1"].signals, &(&1.key == :fast_dwell))

    # One rushed block out of ten is not a pattern.
    assert result["s1"].level == :on_track
    assert %{blocks: 1, fires?: false} = result["s1"].pattern.slacking
  end

  test "rushing is a pattern only on enough blocks and clearly more than the group" do
    s1 = for i <- 1..4, do: rushed("b#{i}")
    others = Map.new(students(6) -- ["s1"], &{&1, [rushed("b1")]})

    result =
      StudentAssessment.assess_cohort(context(%{flagged_blocks: Map.put(others, "s1", s1)}))

    # 4 of 10 visited blocks, the group's median is 1 of 10.
    assert result["s1"].level == :superficial
    assert %{share: 0.4, group_share: 0.1, fires?: true} = result["s1"].pattern.slacking
    assert result["s2"].level == :on_track

    # Everybody rushing just as much is the group's normal, not a student problem.
    everyone = Map.new(students(6), &{&1, s1})
    result = StudentAssessment.assess_cohort(context(%{flagged_blocks: everyone}))
    assert Enum.all?(Map.values(result), &(&1.level == :on_track))
  end

  test "a task most of the group fails doesn't count against a student" do
    cells = Map.new(students(6), &{{&1, "quiz"}, cell(if(&1 == "s6", do: 90, else: 20))})
    result = StudentAssessment.assess_cohort(context(%{cells: cells}))

    assert result["s1"].level == :on_track
    refute :low_score in keys(result, "s1")
  end

  test "levels are ranked: integrity beats a low score, a low score beats superficial reading" do
    integrity = %{key: :copy_attempted, category: :integrity}
    low = %{key: :low_score, category: :performance}
    slack = %{key: :fast_dwell, category: :slacking}

    rushing = %{slacking: %{fires?: true}}

    assert StudentAssessment.level([low, low, integrity, slack], rushing) == :integrity
    assert StudentAssessment.level([low, low, slack], rushing) == :not_mastering
    assert StudentAssessment.level([low, slack], rushing) == :superficial
    assert StudentAssessment.level([slack], rushing) == :superficial
    assert StudentAssessment.level([slack, slack, slack]) == :on_track
  end
end
