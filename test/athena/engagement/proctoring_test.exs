defmodule Athena.Engagement.ProctoringTest do
  # Not async: `evaluate/4` reads live `ExamIntegrityStats` processes keyed
  # by {cohort_id, block_id} - using fresh UUIDs per test avoids collisions
  # even under async, but idle-timeout config pokes global app env, so kept
  # in line with `ProctoringMonitorTest`'s same reasoning.
  use ExUnit.Case, async: false

  alias Athena.Engagement.{ExamIntegrityStats, Proctoring}

  @base_counts %{
    tab_hidden: 0,
    window_blur: 0,
    answer_changed: 0,
    paste_ratio: 0.0,
    printscreen_attempt: 0,
    copy_attempt: 0,
    cut_attempt: 0,
    multi_tab_detected: 0,
    right_click_attempt: 0
  }

  describe "risk_level/3" do
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

    test "silence defaults to zero and has no effect when omitted" do
      assert Proctoring.risk_level(0, 0) == Proctoring.risk_level(0, 0, 0)
    end

    test "a silence gap below the yellow threshold has no effect" do
      assert Proctoring.risk_level(0, 0, 10) == :green
    end

    test "a silence gap at or above the yellow threshold is yellow, even with no other evidence" do
      assert Proctoring.risk_level(0, 0, 45) == :yellow
    end

    test "a silence gap at or above the red threshold is red, even with no other evidence" do
      assert Proctoring.risk_level(0, 0, 120) == :red
    end

    test "hard evidence still wins over a sub-red silence gap" do
      assert Proctoring.risk_level(2, 0, 45) == :red
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

  describe "detail/1" do
    test "nil when the submission has no risk_level at all" do
      assert Proctoring.detail(%{}) == nil
      assert Proctoring.detail(nil) == nil
    end

    test "reads back the full breakdown, defaulting missing fields gracefully" do
      content = %{
        "risk_level" => "red",
        "hard_evidence_count" => 3,
        "outlier_metrics" => %{"paste_ratio" => 92.0},
        "event_counts" => %{"copy_attempt" => 1},
        "rates" => %{"paste_ratio" => 0.5},
        "metric_percentiles" => %{"paste_ratio" => 92.0, "answer_changed_per_minute" => nil},
        "elapsed_minutes" => 12.5,
        "allowed_blur_attempts" => 3,
        "blur_overage_count" => 2,
        "heartbeat_silence_seconds" => 5
      }

      assert Proctoring.detail(content) == %{
               risk_level: :red,
               hard_evidence_count: 3,
               outlier_metrics: %{"paste_ratio" => 92.0},
               event_counts: %{"copy_attempt" => 1},
               rates: %{"paste_ratio" => 0.5},
               metric_percentiles: %{"paste_ratio" => 92.0, "answer_changed_per_minute" => nil},
               elapsed_minutes: 12.5,
               allowed_blur_attempts: 3,
               blur_overage_count: 2,
               heartbeat_silence_seconds: 5
             }
    end

    test "an old submission saved before this breakdown existed still reads without crashing" do
      content = %{"risk_level" => "green", "hard_evidence_count" => 0, "outlier_metrics" => %{}}

      assert Proctoring.detail(content) == %{
               risk_level: :green,
               hard_evidence_count: 0,
               outlier_metrics: %{},
               event_counts: %{},
               rates: %{},
               metric_percentiles: %{},
               elapsed_minutes: nil,
               allowed_blur_attempts: nil,
               blur_overage_count: 0,
               heartbeat_silence_seconds: 0
             }
    end
  end

  describe "evaluate/4" do
    test "hard evidence alone is enough to reach red, with no cohort data at all" do
      cohort_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      reading = %{
        counts: %{@base_counts | printscreen_attempt: 2},
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
        counts: %{@base_counts | answer_changed: 10},
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
        counts: %{@base_counts | answer_changed: 100},
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
        counts: %{@base_counts | paste_ratio: 1.0},
        elapsed_minutes: 10.0
      }

      fields = Proctoring.evaluate(reading, cohort_id, block_id, 3)

      assert fields["outlier_metrics"] == %{}
      assert fields["risk_level"] == "green"
    end

    test "tab-hides beyond the configured allowance count as hard evidence" do
      cohort_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      reading = %{
        counts: %{@base_counts | tab_hidden: 5},
        elapsed_minutes: 10.0
      }

      # Allowance of 3 - 5 tab-hides is 2 over, which alone reaches the
      # default red threshold of 2.
      fields = Proctoring.evaluate(reading, cohort_id, block_id, 3)

      assert fields["blur_overage_count"] == 2
      assert fields["hard_evidence_count"] == 2
      assert fields["risk_level"] == "red"
    end

    test "staying within the configured blur allowance contributes no hard evidence" do
      cohort_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      reading = %{
        counts: %{@base_counts | tab_hidden: 2},
        elapsed_minutes: 10.0
      }

      fields = Proctoring.evaluate(reading, cohort_id, block_id, 3)

      assert fields["blur_overage_count"] == 0
      assert fields["hard_evidence_count"] == 0
    end

    test "window_blur folds into the same cohort-relative rate as tab_hidden" do
      cohort_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      reading = %{
        counts: %{@base_counts | tab_hidden: 3, window_blur: 3},
        elapsed_minutes: 10.0
      }

      fields = Proctoring.evaluate(reading, cohort_id, block_id, 100)

      assert fields["rates"]["tab_hidden_per_minute"] == 0.6
    end

    test "a telemetry-silence gap at or above the red threshold reaches red on its own" do
      cohort_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      reading = %{
        counts: @base_counts,
        elapsed_minutes: 10.0,
        max_silence_seconds: 200
      }

      fields = Proctoring.evaluate(reading, cohort_id, block_id, 3)

      assert fields["hard_evidence_count"] == 0
      assert fields["outlier_metrics"] == %{}
      assert fields["heartbeat_silence_seconds"] == 200
      assert fields["risk_level"] == "red"
    end

    test "a reading with no silence field at all defaults to no silence signal" do
      cohort_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      reading = %{counts: @base_counts, elapsed_minutes: 10.0}

      fields = Proctoring.evaluate(reading, cohort_id, block_id, 3)

      assert fields["heartbeat_silence_seconds"] == 0
      assert fields["risk_level"] == "green"
    end

    test "stores the full event-count and rate breakdown for the detail modal" do
      cohort_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      reading = %{
        counts: %{@base_counts | copy_attempt: 1, right_click_attempt: 4},
        elapsed_minutes: 10.0
      }

      fields = Proctoring.evaluate(reading, cohort_id, block_id, 3)

      assert fields["event_counts"]["copy_attempt"] == 1
      assert fields["event_counts"]["right_click_attempt"] == 4
      refute Map.has_key?(fields["event_counts"], "paste_ratio")
      assert fields["rates"]["right_click_per_minute"] == 0.4
      assert fields["elapsed_minutes"] == 10.0
      assert Map.has_key?(fields["metric_percentiles"], "right_click_per_minute")
    end
  end
end
