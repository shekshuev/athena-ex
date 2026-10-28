defmodule Athena.Content.ScoringRulesTest do
  use ExUnit.Case, async: true

  alias Athena.Content.ScoringRules

  describe "resolve/1" do
    test "an unconfigured competition scores by the defaults" do
      assert %ScoringRules{
               mode: :static,
               tiebreakers: [:time, :attempts],
               disqualify_on_rejected: true
             } = ScoringRules.resolve(nil)
    end

    test "keeps rules that were configured" do
      rules = %ScoringRules{mode: :dynamic, decay: 5}
      assert ScoringRules.resolve(rules) == rules
    end
  end

  describe "block_value/3 in static mode" do
    setup do: %{rules: ScoringRules.resolve(nil)}

    test "an unweighted block is worth 100 however many teams solved it", %{rules: rules} do
      assert ScoringRules.block_value(rules, nil, 0) == 100
      assert ScoringRules.block_value(rules, nil, 25) == 100
    end

    test "a weighted block is worth its weight", %{rules: rules} do
      assert ScoringRules.block_value(rules, 300, 10) == 300
    end
  end

  describe "block_value/3 in dynamic mode" do
    setup do
      %{
        linear: %ScoringRules{
          mode: :dynamic,
          initial: 500,
          minimum: 100,
          decay: 20,
          curve: :linear
        },
        log: %ScoringRules{
          mode: :dynamic,
          initial: 500,
          minimum: 100,
          decay: 20,
          curve: :logarithmic
        }
      }
    end

    test "nobody has solved it yet, so it is worth full value", %{linear: rules} do
      assert ScoringRules.block_value(rules, nil, 0) == 500
    end

    test "first blood is worth full value - decay starts with the second solve", %{linear: rules} do
      assert ScoringRules.block_value(rules, nil, 1) == 500
      assert ScoringRules.block_value(rules, nil, 2) == 480
      assert ScoringRules.block_value(rules, nil, 3) == 460
    end

    test "the logarithmic curve falls away more slowly at first", %{linear: lin, log: log} do
      assert ScoringRules.block_value(log, nil, 1) == 500
      assert ScoringRules.block_value(log, nil, 3) == 496
      assert ScoringRules.block_value(log, nil, 3) > ScoringRules.block_value(lin, nil, 3)
    end

    test "never falls below the minimum", %{linear: lin, log: log} do
      assert ScoringRules.block_value(lin, nil, 500) == 100
      assert ScoringRules.block_value(log, nil, 500) == 100
    end

    test "a block's own weight is the value it decays from", %{linear: rules} do
      assert ScoringRules.block_value(rules, 300, 1) == 300
      assert ScoringRules.block_value(rules, 300, 2) == 280
    end
  end

  describe "points/4" do
    test "a partial score earns a partial share of the block" do
      rules = %ScoringRules{mode: :dynamic, initial: 300, minimum: 100, decay: 20}

      assert ScoringRules.points(rules, nil, 1, 100) == 300
      assert ScoringRules.points(rules, nil, 1, 60) == 180
      assert ScoringRules.points(rules, nil, 1, 0) == 0
    end

    test "an attempt with no score yet earns nothing" do
      assert ScoringRules.points(ScoringRules.resolve(nil), nil, 1, nil) == 0
    end

    test "static mode hands back the submission's own score" do
      rules = ScoringRules.resolve(nil)

      assert ScoringRules.points(rules, nil, 1, 73) == 73
      assert ScoringRules.points(rules, nil, 9, 73) == 73
    end
  end

  describe "solve?/2" do
    test "only complete work decays a task by default" do
      rules = ScoringRules.resolve(nil)

      assert ScoringRules.solve?(rules, 100)
      refute ScoringRules.solve?(rules, 99)
      refute ScoringRules.solve?(rules, nil)
    end

    test "the threshold is the author's to lower" do
      rules = %ScoringRules{mode: :dynamic, solve_threshold: 50}

      assert ScoringRules.solve?(rules, 50)
      refute ScoringRules.solve?(rules, 49)
    end
  end

  describe "changeset/2" do
    test "an empty tiebreaker list falls back to the default order" do
      changeset =
        ScoringRules.changeset(%ScoringRules{}, %{"mode" => "static", "tiebreakers" => []})

      assert Ecto.Changeset.get_field(changeset, :tiebreakers) == [:time, :attempts]
    end

    test "rejects a repeated tiebreaker" do
      changeset =
        ScoringRules.changeset(%ScoringRules{}, %{
          "mode" => "static",
          "tiebreakers" => ["time", "time"]
        })

      refute changeset.valid?
      assert errors_on(changeset)[:tiebreakers]
    end

    test "rejects a zero decay, which would divide by zero" do
      changeset =
        ScoringRules.changeset(%ScoringRules{}, %{"mode" => "dynamic", "decay" => 0})

      refute changeset.valid?
      assert errors_on(changeset)[:decay]
    end

    test "rejects a minimum above the initial value" do
      changeset =
        ScoringRules.changeset(%ScoringRules{}, %{
          "mode" => "dynamic",
          "initial" => 100,
          "minimum" => 500
        })

      refute changeset.valid?
      assert errors_on(changeset)[:minimum]
    end

    test "leaves the dynamic numbers alone while static is selected" do
      changeset =
        ScoringRules.changeset(%ScoringRules{}, %{
          "mode" => "static",
          "initial" => 750,
          "decay" => 7
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :initial) == 750
      assert Ecto.Changeset.get_field(changeset, :decay) == 7
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), "") |> to_string()
      end)
    end)
  end
end
