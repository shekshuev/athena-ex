defmodule Athena.Engagement.ProctoringTest do
  # Not async: `evaluate/4` reads live `ExamIntegrityStats` processes keyed
  # by {cohort_id, block_id} - using fresh UUIDs per test avoids collisions
  # even under async, but idle-timeout config pokes global app env, so kept
  # in line with `ProctoringMonitorTest`'s same reasoning.
  use ExUnit.Case, async: false

  alias Athena.Engagement.{ExamIntegrityStats, Proctoring}

  describe "risk_level/2" do
    test "no evidence at all is green" do
      assert Proctoring.risk_level(0, 0) == :green
    end

    test "hard evidence below the red threshold is yellow" do
      assert Proctoring.risk_level(1, 0) == :yellow
    end

    test "hard evidence at or above the red threshold is red" do
      assert Proctoring.risk_level(2, 0) == :red
      assert Proctoring.risk_level(5, 0) == :red
    end

    test "behavioral outliers below the red threshold are yellow" do
      assert Proctoring.risk_level(0, 1) == :yellow
    end

    test "behavioral outliers at or above the red threshold are red, even with zero hard evidence" do
      assert Proctoring.risk_level(0, 2) == :red
    end
  end

  describe "summary/1" do
    test "nil when the submission has no risk_level at all" do
      assert Proctoring.summary(%{}) == nil
      assert Proctoring.summary(%{"text_answer" => "hi"}) == nil
    end

    test "nil for non-map content" do
      assert Proctoring.summary(nil) == nil
    end

    test "reads back the persisted fields" do
      content = %{
        "risk_level" => "yellow",
        "hard_evidence_count" => 1,
        "outlier_metrics" => %{"paste_ratio" => 92.0}
      }

      assert Proctoring.summary(content) == %{
               risk_level: :yellow,
               hard_evidence_count: 1,
               outlier_metrics: %{"paste_ratio" => 92.0}
             }
    end
  end

  describe "evaluate/4" do
    test "hard evidence alone is enough to reach red, with no cohort data at all" do
      cohort_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      reading = %{
        counts: %{
          tab_hidden: 0,
          answer_changed: 0,
          paste_ratio: 0.0,
          printscreen_attempt: 2,
          copy_attempt: 0,
          cut_attempt: 0,
          multi_tab_detected: 0
        },
        elapsed_minutes: 10.0
      }

      fields = Proctoring.evaluate(reading, cohort_id, block_id, 3)

      assert fields["hard_evidence_count"] == 2
      assert fields["risk_level"] == "red"
      assert fields["outlier_metrics"] == %{}
    end

    test "a behavioral rate that matches the rest of the cohort is never flagged as an outlier" do
      cohort_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      # Seed enough peers, all with the same answer-change rate as the
      # student under test - nobody should stand out.
      for i <- 1..20 do
        ExamIntegrityStats.report_rate(
          cohort_id,
          block_id,
          "peer-#{i}",
          :answer_changed_per_minute,
          1.0
        )
      end

      reading = %{
        counts: %{
          tab_hidden: 0,
          answer_changed: 10,
          paste_ratio: 0.0,
          printscreen_attempt: 0,
          copy_attempt: 0,
          cut_attempt: 0,
          multi_tab_detected: 0
        },
        elapsed_minutes: 10.0
      }

      fields = Proctoring.evaluate(reading, cohort_id, block_id, 3)

      assert fields["hard_evidence_count"] == 0
      assert fields["outlier_metrics"] == %{}
      assert fields["risk_level"] == "green"
    end

    test "a genuine outlier relative to the cohort gets flagged - the anxious-student case is NOT enough alone" do
      cohort_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      # 20 peers with a calm, low answer-change rate.
      for i <- 1..20 do
        ExamIntegrityStats.report_rate(
          cohort_id,
          block_id,
          "peer-#{i}",
          :answer_changed_per_minute,
          0.2
        )
      end

      # This student changes their answer far more often than anyone else.
      reading = %{
        counts: %{
          tab_hidden: 0,
          answer_changed: 100,
          paste_ratio: 0.0,
          printscreen_attempt: 0,
          copy_attempt: 0,
          cut_attempt: 0,
          multi_tab_detected: 0
        },
        elapsed_minutes: 10.0
      }

      fields = Proctoring.evaluate(reading, cohort_id, block_id, 3)

      assert fields["hard_evidence_count"] == 0
      assert Map.has_key?(fields["outlier_metrics"], "answer_changed_per_minute")
      # A single outlier metric alone is only "worth a look", not an
      # automatic red - matches the two-tier design (needs 2+ independent
      # outliers, or hard evidence, to reach red).
      assert fields["risk_level"] == "yellow"
    end

    test "too few peers to say anything meaningful - no outlier flag even for an extreme value" do
      cohort_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      ExamIntegrityStats.report_rate(cohort_id, block_id, "peer-1", :paste_ratio, 0.1)

      reading = %{
        counts: %{
          tab_hidden: 0,
          answer_changed: 0,
          paste_ratio: 1.0,
          printscreen_attempt: 0,
          copy_attempt: 0,
          cut_attempt: 0,
          multi_tab_detected: 0
        },
        elapsed_minutes: 10.0
      }

      fields = Proctoring.evaluate(reading, cohort_id, block_id, 3)

      assert fields["outlier_metrics"] == %{}
      assert fields["risk_level"] == "green"
    end
  end
end
