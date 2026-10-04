defmodule AthenaWeb.TeachingLive.CohortComparisonTest do
  use ExUnit.Case, async: true

  alias AthenaWeb.TeachingLive.CohortComparison, as: Comparison

  defp summary(overrides) do
    Map.merge(
      %{
        students: 10,
        progress_sum: 500,
        levels: %{},
        slacking_students: 0,
        struggling_students: 0,
        integrity_students: 0,
        scored: 10,
        score_sum: 700,
        attempted: 10,
        first_try: 5,
        flagged_attempts: 0,
        sections: %{}
      },
      overrides
    )
  end

  defp indicator(key), do: Enum.find(Comparison.indicators(), &(&1.key == key))

  test "values are percents or scores, nil when there is nothing to measure" do
    s = summary(%{levels: %{inactive: 2}})
    assert Comparison.value(s, :progress) == 50.0
    assert Comparison.value(s, :inactive) == 20.0
    assert Comparison.value(s, :score) == 70.0
    assert Comparison.value(s, :first_try) == 50.0
    assert Comparison.value(summary(%{scored: 0}), :score) == nil
    assert Comparison.value(summary(%{students: 0}), :progress) == nil
  end

  test "the course average adds groups up rather than averaging their averages" do
    merged =
      Comparison.merge([
        summary(%{students: 2, progress_sum: 200}),
        summary(%{students: 8, progress_sum: 0})
      ])

    assert Comparison.value(merged, :progress) == 20.0
  end

  test "deviation knows which direction is better" do
    assert %{level: 2, good?: false} = Comparison.deviation(40, 70, indicator(:progress))
    assert %{level: 2, good?: true} = Comparison.deviation(0, 25, indicator(:inactive))
    assert %{level: 1, good?: true} = Comparison.deviation(80, 70, indicator(:score))
    assert %{level: 0} = Comparison.deviation(72, 70, indicator(:score))
    assert %{level: 0} = Comparison.deviation(nil, 70, indicator(:score))
  end

  test "insights name the weaker group, hard topics and lagging sections" do
    section = %{id: "s1", title: "Recursion"}

    weak =
      {%{name: "Group 3"},
       summary(%{
         progress_sum: 100,
         sections: %{"s1" => %{scored: 4, score_sum: 160, done: 1, total: 10}}
       })}

    strong =
      {%{name: "Group 1"},
       summary(%{
         progress_sum: 900,
         sections: %{"s1" => %{scored: 4, score_sum: 200, done: 9, total: 10}}
       })}

    insights = Comparison.insights([weak, strong], [section])

    assert Enum.any?(insights, &(&1 =~ "Group 3" and &1 =~ "10% against 50%"))
    assert Enum.any?(insights, &(&1 =~ "Recursion" and &1 =~ "hard for every group"))
    assert Enum.any?(insights, &(&1 =~ "Group 3 is behind in “Recursion”"))
    refute Enum.any?(insights, &(&1 =~ "Group 1:"))
  end
end
