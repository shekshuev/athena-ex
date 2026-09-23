defmodule Athena.Engagement.ProctoringTest do
  use ExUnit.Case, async: true

  alias Athena.Engagement.Proctoring

  describe "risk_level/2" do
    test "zero violations is always green, regardless of threshold" do
      assert Proctoring.risk_level(0, 3) == :green
      assert Proctoring.risk_level(0, 0) == :green
    end

    test "violations at or above the threshold are red" do
      assert Proctoring.risk_level(3, 3) == :red
      assert Proctoring.risk_level(5, 3) == :red
    end

    test "violations below the threshold (but nonzero) are yellow" do
      assert Proctoring.risk_level(1, 3) == :yellow
      assert Proctoring.risk_level(2, 3) == :yellow
    end
  end

  describe "build_content_fields/2" do
    test "sums the counts into cheat_count and classifies risk_level using the given threshold" do
      counts = %{tab_hidden: 1, printscreen_attempt: 1, copy_attempt: 0, cut_attempt: 0}

      fields = Proctoring.build_content_fields(counts, 3)

      assert fields["cheat_count"] == 2
      assert fields["proctoring"]["tab_hidden"] == 1
      assert fields["proctoring"]["printscreen_attempt"] == 1
      assert fields["proctoring"]["allowed_blur_attempts"] == 3
      assert fields["proctoring"]["risk_level"] == "yellow"
    end

    test "an all-zero counts map yields cheat_count 0 and risk_level green" do
      counts = %{tab_hidden: 0, printscreen_attempt: 0, copy_attempt: 0, cut_attempt: 0}

      fields = Proctoring.build_content_fields(counts, 3)

      assert fields["cheat_count"] == 0
      assert fields["proctoring"]["risk_level"] == "green"
    end
  end

  describe "summary/1" do
    test "returns nil when the submission content has no cheat_count at all" do
      assert Proctoring.summary(%{}) == nil
      assert Proctoring.summary(%{"text_answer" => "hi"}) == nil
    end

    test "returns nil for non-map content (e.g. a submission with no content yet)" do
      assert Proctoring.summary(nil) == nil
    end

    test "returns a summary even when cheat_count is 0 - a confirmed-clean attempt is still data" do
      assert %{cheat_count: 0, risk_level: :green} = Proctoring.summary(%{"cheat_count" => 0})
    end

    test "derives risk_level from the embedded proctoring.allowed_blur_attempts threshold" do
      content = %{
        "cheat_count" => 4,
        "proctoring" => %{"allowed_blur_attempts" => 5}
      }

      assert %{cheat_count: 4, risk_level: :yellow} = Proctoring.summary(content)
    end

    test "falls back to a default threshold of 3 when no proctoring breakdown is present" do
      assert %{risk_level: :red} = Proctoring.summary(%{"cheat_count" => 3})
      assert %{risk_level: :yellow} = Proctoring.summary(%{"cheat_count" => 2})
    end
  end
end
