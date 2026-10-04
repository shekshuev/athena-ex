defmodule AthenaWeb.TeachingLive.EngagementExplanationsTest do
  use ExUnit.Case, async: true

  alias AthenaWeb.TeachingLive.EngagementExplanations, as: Explanations

  @names %{"text" => "Loops · 1. Text", "quiz" => "Loops · 2. Question"}

  test "every level has a label, tone, icon and a rule" do
    for {level, rule} <- Explanations.level_rules() do
      assert is_binary(Explanations.level_label(level))
      assert Explanations.level_tone(level) in ~w(error warning info success)
      assert "hero-" <> _ = Explanations.level_icon(level)
      assert rule != ""
    end

    assert {:inactive, _} = hd(Explanations.level_rules())
  end

  test "a group-relative signal names the block and both numbers" do
    signal = %{
      key: :fast_dwell,
      category: :slacking,
      block_id: "text",
      value: 40,
      baseline: 540,
      basis: :group,
      peers: 12
    }

    explained = Explanations.explain(signal, @names)

    assert explained.title =~ "Loops · 1. Text"
    assert explained.note =~ "40 s"
    assert explained.note =~ "9 min"
    assert explained.note =~ "12"
  end

  test "a low score lists how the theory in front of it went" do
    signal = %{
      key: :low_score,
      category: :performance,
      block_id: "quiz",
      value: 30,
      baseline: 80,
      basis: :absolute,
      threshold: 50,
      peers: 10,
      theory: [%{block_id: "text", status: :superficial, flags: %{shallow_scroll: %{}}}]
    }

    explained = Explanations.explain(signal, @names)

    assert explained.title =~ "30"
    assert explained.note =~ "50"
    assert [line] = explained.lines
    assert line =~ "Loops · 1. Text"
    assert line =~ "not read to the end"
  end

  test "recommendations point at skimmed theory, or at the topic when theory was fine" do
    skimmed = %{
      key: :low_score,
      category: :performance,
      block_id: "quiz",
      theory: [%{block_id: "text", status: :skipped}]
    }

    [advice] = Explanations.recommendations([skimmed], @names)
    assert advice =~ "go back to “Loops · 1. Text”"

    studied = %{skimmed | theory: [%{block_id: "text", status: :ok}]}
    [advice] = Explanations.recommendations([studied], @names)
    assert advice =~ "“Loops · 2. Question”"
    assert advice =~ "topic itself"
  end

  test "recommendations are ordered by urgency, one per kind, capped" do
    signals = [
      %{key: :fast_dwell, category: :slacking, block_id: "text"},
      %{key: :fast_dwell, category: :slacking, block_id: "quiz"},
      %{key: :inactive, category: :activity},
      %{key: :copy_attempted, category: :integrity, block_id: "quiz"}
    ]

    advice = Explanations.recommendations(signals, @names)
    assert length(advice) == 3
    assert hd(advice) =~ "Reach out"
    assert Enum.at(advice, 1) =~ "cheating monitor"
    assert Explanations.recommendations(signals, @names, 1) == [hd(advice)]
  end

  test "durations read naturally" do
    assert Explanations.duration(45) == "45 s"
    assert Explanations.duration(240) == "4 min"
    assert Explanations.duration(3900) == "1 h 5 min"
    assert Explanations.duration(nil) == "—"
  end
end
