defmodule Athena.Engagement.ProctoringTest do
  # Not async: `evaluate/3` reads live `ExamIntegrityStats` processes keyed
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
    right_click_attempt: 0,
    large_paste: 0,
    bulk_insert: 0,
    split_screen: 0
  }

  defp reading(counts \\ %{}, extra \\ %{}) do
    Map.merge(%{counts: Map.merge(@base_counts, counts), elapsed_minutes: 10.0}, extra)
  end

  defp evaluate(reading),
    do: Proctoring.evaluate(reading, Ecto.UUID.generate(), Ecto.UUID.generate())

  defp seed_peers(cohort_id, block_id, metric, value, n \\ 20) do
    for i <- 1..n do
      ExamIntegrityStats.report_rate(cohort_id, block_id, "peer-#{i}", metric, value)
    end
  end

  describe "risk_level/1" do
    test "points below the yellow threshold are green" do
      assert Proctoring.risk_level(0) == :green
      assert Proctoring.risk_level(1) == :green
    end

    test "points at the yellow threshold are yellow" do
      assert Proctoring.risk_level(2) == :yellow
      assert Proctoring.risk_level(3) == :yellow
    end

    test "points at or above the red threshold are red" do
      assert Proctoring.risk_level(4) == :red
      assert Proctoring.risk_level(10) == :red
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

    test "an old submission saved before this breakdown existed still reads without crashing" do
      content = %{"risk_level" => "green", "hard_evidence_count" => 0, "outlier_metrics" => %{}}

      assert Proctoring.detail(content) == %{
               risk_level: :green,
               points: nil,
               hard_evidence_count: 0,
               outlier_metrics: %{},
               signals: [],
               event_counts: %{},
               rates: %{},
               metric_percentiles: %{},
               elapsed_minutes: nil,
               heartbeat_silence_seconds: 0,
               away_incidents: 0,
               away_total_seconds: 0,
               mouse_away_seconds: 0,
               max_paste_chars: 0,
               typing: %{},
               incidents: [],
               review: nil
             }
    end

    test "round-trips what evaluate/3 stores" do
      fields = evaluate(reading(%{copy_attempt: 1}))
      detail = Proctoring.detail(fields)

      assert detail.risk_level == :yellow
      assert detail.points == 2
      assert [%{"key" => "copy_attempt", "points" => 2}] = detail.signals
      assert detail.event_counts["copy_attempt"] == 1
    end
  end

  describe "evaluate/3 - direct violations" do
    test "nothing observed is green with no signals" do
      fields = evaluate(reading())

      assert fields["risk_level"] == "green"
      assert fields["points"] == 0
      assert fields["signals"] == []
    end

    test "one direct violation is yellow, two are red - no cohort data needed" do
      assert evaluate(reading(%{printscreen_attempt: 1}))["risk_level"] == "yellow"

      fields = evaluate(reading(%{printscreen_attempt: 2}))
      assert fields["hard_evidence_count"] == 2
      assert fields["risk_level"] == "red"
      assert fields["outlier_metrics"] == %{}
    end

    test "a large paste and a bulk insert are direct violations too" do
      fields = evaluate(reading(%{large_paste: 1, bulk_insert: 1}))

      assert fields["hard_evidence_count"] == 2
      assert fields["risk_level"] == "red"
    end
  end

  describe "evaluate/3 - time away" do
    test "no absence long enough to matter is green, however many tiny tab switches" do
      fields =
        evaluate(
          reading(%{tab_hidden: 3, window_blur: 3}, %{away_incidents: 0, away_total_seconds: 6})
        )

      assert fields["risk_level"] == "green"
    end

    test "one absence of the minimum length is yellow" do
      fields = evaluate(reading(%{}, %{away_incidents: 1, away_total_seconds: 15}))

      assert fields["risk_level"] == "yellow"
      assert [%{"key" => "away", "incidents" => 1}] = fields["signals"]
    end

    test "three absences are red" do
      assert evaluate(reading(%{}, %{away_incidents: 3, away_total_seconds: 40}))["risk_level"] ==
               "red"
    end

    test "a long total is red even without a single long absence" do
      assert evaluate(reading(%{}, %{away_incidents: 0, away_total_seconds: 90}))["risk_level"] ==
               "red"
    end
  end

  describe "evaluate/3 - telemetry silence" do
    test "a gap below the yellow threshold has no effect" do
      assert evaluate(reading(%{}, %{max_silence_seconds: 10}))["risk_level"] == "green"
    end

    test "a gap at the yellow threshold is yellow on its own" do
      assert evaluate(reading(%{}, %{max_silence_seconds: 45}))["risk_level"] == "yellow"
    end

    test "a gap at the red threshold is red on its own" do
      fields = evaluate(reading(%{}, %{max_silence_seconds: 200}))

      assert fields["heartbeat_silence_seconds"] == 200
      assert fields["risk_level"] == "red"
    end

    test "an offline period counts the same as a silent gap" do
      assert evaluate(reading(%{}, %{max_offline_seconds: 130}))["risk_level"] == "red"
    end

    test "incidents recorded by the monitor are stored with the submission" do
      incident = %{"type" => "silence", "at" => "2026-01-01T00:00:00Z", "seconds" => 80}

      assert evaluate(reading(%{}, %{incidents: [incident]}))["incidents"] == [incident]
    end
  end

  describe "evaluate/3 - behavior compared to the group" do
    test "a value that matches the rest of the cohort is never flagged" do
      cohort_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()
      seed_peers(cohort_id, block_id, :answer_changed_per_minute, 1.0)

      fields = Proctoring.evaluate(reading(%{answer_changed: 10}), cohort_id, block_id)

      assert fields["outlier_metrics"] == %{}
      assert fields["risk_level"] == "green"
    end

    test "a strong outlier above its floor is flagged and worth two points" do
      cohort_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()
      seed_peers(cohort_id, block_id, :paste_ratio, 0.1)

      fields = Proctoring.evaluate(reading(%{paste_ratio: 0.9}), cohort_id, block_id)

      assert Map.has_key?(fields["outlier_metrics"], "paste_ratio")
      assert fields["points"] == 2
      assert fields["risk_level"] == "yellow"
    end

    test "a soft metric alone is not enough for yellow - the anxious-student case" do
      cohort_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()
      seed_peers(cohort_id, block_id, :answer_changed_per_minute, 0.2)

      fields = Proctoring.evaluate(reading(%{answer_changed: 100}), cohort_id, block_id)

      assert Map.has_key?(fields["outlier_metrics"], "answer_changed_per_minute")
      assert fields["points"] == 1
      assert fields["risk_level"] == "green"
    end

    test "a cohort of zeros does not make a tiny value an outlier - the absolute floor holds" do
      cohort_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()
      seed_peers(cohort_id, block_id, :right_click_per_minute, 0.0)

      # One right-click in ten minutes = 0.1/min: "100th percentile" among
      # peers who never right-click, but nowhere near worth flagging.
      fields = Proctoring.evaluate(reading(%{right_click_attempt: 1}), cohort_id, block_id)

      assert fields["outlier_metrics"] == %{}
      assert fields["risk_level"] == "green"
    end

    test "per-minute rates are not judged while the attempt is still young" do
      cohort_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()
      seed_peers(cohort_id, block_id, :tab_hidden_per_minute, 0.0)

      young = %{counts: Map.put(@base_counts, :tab_hidden, 3), elapsed_minutes: 1.0}
      fields = Proctoring.evaluate(young, cohort_id, block_id)

      assert fields["outlier_metrics"] == %{}
      # ...but the rate is still stored for display.
      assert fields["rates"]["tab_hidden_per_minute"] == 3.0
      assert fields["metric_percentiles"]["tab_hidden_per_minute"] == nil
    end

    test "with too few peers, a fixed upper limit is used instead of silently doing nothing" do
      fields = evaluate(reading(%{paste_ratio: 0.95}))

      assert fields["outlier_metrics"] == %{"paste_ratio" => nil}
      assert [%{"key" => "paste_ratio", "basis" => "fallback"}] = fields["signals"]
    end

    test "with too few peers, a value below the fixed limit is not flagged" do
      assert evaluate(reading(%{paste_ratio: 0.3}))["outlier_metrics"] == %{}
    end

    test "window_blur folds into the same rate as tab_hidden" do
      fields = evaluate(reading(%{tab_hidden: 3, window_blur: 3}))

      assert fields["rates"]["tab_hidden_per_minute"] == 0.6
    end

    test "time with the pointer outside the window is a per-minute rate" do
      fields = evaluate(reading(%{}, %{mouse_away_seconds: 100}))

      assert fields["rates"]["mouse_away_seconds_per_minute"] == 10.0
    end
  end

  describe "evaluate/3 - typing patterns" do
    test "keystrokes held for almost no time look like a macro" do
      typing = %{
        keys: 80,
        dwell_sum: 80 * 1.0,
        cv_sum: 0.0,
        pauses: 0,
        max_clean_run: 80,
        chars_typed: 80,
        chars_deleted: 0
      }

      fields = evaluate(reading(%{}, %{typing: typing}))

      assert [%{"key" => "machine_typing", "points" => 2}] = fields["signals"]
    end

    test "normal key-hold times are not flagged" do
      typing = %{
        keys: 80,
        dwell_sum: 80 * 95.0,
        cv_sum: 80 * 0.5,
        pauses: 4,
        max_clean_run: 20,
        chars_typed: 70,
        chars_deleted: 10
      }

      assert evaluate(reading(%{}, %{typing: typing}))["signals"] == []
    end

    test "a long answer typed with no corrections at all is a soft signal" do
      typing = %{
        keys: 600,
        dwell_sum: 600 * 90.0,
        cv_sum: 600 * 0.6,
        pauses: 3,
        max_clean_run: 600,
        chars_typed: 600,
        chars_deleted: 0
      }

      fields = evaluate(reading(%{}, %{typing: typing}))

      assert [%{"key" => "clean_typing", "points" => 1}] = fields["signals"]
      assert fields["risk_level"] == "green"
    end

    test "a short clean answer is never flagged" do
      typing = %{
        keys: 30,
        dwell_sum: 30 * 90.0,
        cv_sum: 0.0,
        pauses: 0,
        max_clean_run: 30,
        chars_typed: 30,
        chars_deleted: 0
      }

      assert evaluate(reading(%{}, %{typing: typing}))["signals"] == []
    end
  end

  describe "evaluate/3 - stored breakdown" do
    test "stores every count and rate for the detail modal, whether or not flagged" do
      fields = evaluate(reading(%{copy_attempt: 1, right_click_attempt: 4}))

      assert fields["event_counts"]["copy_attempt"] == 1
      assert fields["event_counts"]["right_click_attempt"] == 4
      refute Map.has_key?(fields["event_counts"], "paste_ratio")
      assert fields["rates"]["right_click_per_minute"] == 0.4
      assert fields["elapsed_minutes"] == 10.0
      assert Map.has_key?(fields["metric_percentiles"], "right_click_per_minute")
    end

    test "two split-screen reports are worth more than one" do
      assert evaluate(reading(%{split_screen: 1}))["points"] == 1
      assert evaluate(reading(%{split_screen: 2}))["points"] == 2
    end
  end
end
