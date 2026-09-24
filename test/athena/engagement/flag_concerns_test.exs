defmodule Athena.Engagement.FlagConcernsTest do
  use ExUnit.Case, async: true

  alias Athena.Engagement.Metrics

  describe "flag_concerns/1 - empty/missing data" do
    test "returns empty lists and never crashes on a metrics map with nothing in it" do
      assert Metrics.flag_concerns(%{}) == %{
               content: [],
               slacking: [],
               struggling: [],
               integrity: []
             }
    end
  end

  describe "flag_concerns/1 - content flags" do
    test ":high_backtrack_rate fires above the threshold" do
      result = Metrics.flag_concerns(%{backtrack_rate: 0.41})
      assert :high_backtrack_rate in result.content
    end

    test ":high_backtrack_rate does not fire exactly at the threshold" do
      result = Metrics.flag_concerns(%{backtrack_rate: 0.4})
      refute :high_backtrack_rate in result.content
    end

    test ":high_hesitation_rate fires above the threshold" do
      result = Metrics.flag_concerns(%{hesitation_rate: 0.41})
      assert :high_hesitation_rate in result.content
    end

    test ":high_hesitation_rate does not fire exactly at the threshold" do
      result = Metrics.flag_concerns(%{hesitation_rate: 0.4})
      refute :high_hesitation_rate in result.content
    end
  end

  describe "flag_concerns/1 - slacking flags" do
    test ":fast_dwell fires below the threshold" do
      result = Metrics.flag_concerns(%{dwell_ratio: 0.49})
      assert :fast_dwell in result.slacking
    end

    test ":fast_dwell does not fire exactly at the threshold" do
      result = Metrics.flag_concerns(%{dwell_ratio: 0.5})
      refute :fast_dwell in result.slacking
    end

    test ":shallow_scroll fires below the threshold" do
      result = Metrics.flag_concerns(%{avg_scroll_depth_percent: 69})
      assert :shallow_scroll in result.slacking
    end

    test ":shallow_scroll does not fire exactly at the threshold" do
      result = Metrics.flag_concerns(%{avg_scroll_depth_percent: 70})
      refute :shallow_scroll in result.slacking
    end

    test ":heavy_paste fires above the threshold" do
      result = Metrics.flag_concerns(%{paste_ratio: 0.81})
      assert :heavy_paste in result.slacking
    end

    test ":heavy_paste does not fire exactly at the threshold" do
      result = Metrics.flag_concerns(%{paste_ratio: 0.8})
      refute :heavy_paste in result.slacking
    end

    test ":video_skipped fires above the threshold" do
      result = Metrics.flag_concerns(%{skip_ratio: 0.31})
      assert :video_skipped in result.slacking
    end

    test ":video_skipped does not fire exactly at the threshold" do
      result = Metrics.flag_concerns(%{skip_ratio: 0.3})
      refute :video_skipped in result.slacking
    end

    test ":no_debug_cycle fires when there was no run attempt and some paste happened" do
      result = Metrics.flag_concerns(%{debug_cycle_present?: false, paste_ratio: 0.5})
      assert :no_debug_cycle in result.slacking
    end

    test ":no_debug_cycle does not fire when a debug cycle did happen, even with heavy paste" do
      result = Metrics.flag_concerns(%{debug_cycle_present?: true, paste_ratio: 0.9})
      refute :no_debug_cycle in result.slacking
    end

    test ":no_debug_cycle does not fire when there was no paste at all" do
      result = Metrics.flag_concerns(%{debug_cycle_present?: false, paste_ratio: 0.0})
      refute :no_debug_cycle in result.slacking
    end
  end

  describe "flag_concerns/1 - struggling flags" do
    test ":slow_dwell fires above the threshold" do
      result = Metrics.flag_concerns(%{dwell_ratio: 2.01})
      assert :slow_dwell in result.struggling
    end

    test ":slow_dwell does not fire exactly at the threshold" do
      result = Metrics.flag_concerns(%{dwell_ratio: 2.0})
      refute :slow_dwell in result.struggling
    end

    test ":hesitation fires on any answer change" do
      result = Metrics.flag_concerns(%{answer_change_count: 1})
      assert :hesitation in result.struggling
    end

    test ":hesitation does not fire with zero answer changes" do
      result = Metrics.flag_concerns(%{answer_change_count: 0})
      refute :hesitation in result.struggling
    end

    test ":backtracked fires on any backtrack" do
      result = Metrics.flag_concerns(%{backtrack_count: 1})
      assert :backtracked in result.struggling
    end

    test ":backtracked does not fire with zero backtracks" do
      result = Metrics.flag_concerns(%{backtrack_count: 0})
      refute :backtracked in result.struggling
    end

    test ":panic_debugging fires when the flag is true" do
      result = Metrics.flag_concerns(%{panic_debugging?: true})
      assert :panic_debugging in result.struggling
    end

    test ":panic_debugging does not fire when the flag is false" do
      result = Metrics.flag_concerns(%{panic_debugging?: false})
      refute :panic_debugging in result.struggling
    end
  end

  describe "flag_concerns/1 - integrity flags" do
    test ":printscreen_attempted fires on any printscreen count" do
      result = Metrics.flag_concerns(%{printscreen_count: 1})
      assert :printscreen_attempted in result.integrity
    end

    test ":printscreen_attempted does not fire with zero count" do
      result = Metrics.flag_concerns(%{printscreen_count: 0})
      refute :printscreen_attempted in result.integrity
    end

    test ":copy_attempted and :cut_attempted fire independently" do
      result = Metrics.flag_concerns(%{copy_attempt_count: 1, cut_attempt_count: 0})
      assert :copy_attempted in result.integrity
      refute :cut_attempted in result.integrity
    end

    test ":multi_tab_detected fires on any count" do
      result = Metrics.flag_concerns(%{multi_tab_count: 1})
      assert :multi_tab_detected in result.integrity
    end

    test ":excessive_tab_switching fires at or above the threshold" do
      result = Metrics.flag_concerns(%{focus_loss_count: 3})
      assert :excessive_tab_switching in result.integrity
    end

    test ":excessive_tab_switching does not fire below the threshold" do
      result = Metrics.flag_concerns(%{focus_loss_count: 2})
      refute :excessive_tab_switching in result.integrity
    end

    test ":heavy_paste_on_exam fires above the exam-specific threshold" do
      result = Metrics.flag_concerns(%{exam_paste_ratio: 0.61})
      assert :heavy_paste_on_exam in result.integrity
    end

    test ":heavy_paste_on_exam does not fire exactly at the threshold" do
      result = Metrics.flag_concerns(%{exam_paste_ratio: 0.6})
      refute :heavy_paste_on_exam in result.integrity
    end

    test "a regular (non-exam) quiz_question's plain paste_ratio/answer_change_count never trips an integrity flag" do
      # `paste_ratio`/`answer_change_count` (no `exam_`/count suffix) are
      # what `quiz_question_metrics/1`/`code_metrics/1` produce for a
      # regular, non-exam block - integrity_flags/2 must only ever read the
      # exam-prefixed keys, or a normal practice quiz would get mislabeled
      # as an academic-integrity concern.
      result = Metrics.flag_concerns(%{paste_ratio: 1.0, answer_change_count: 100})
      assert result.integrity == []
    end
  end

  describe "flag_concerns/1 - backtracking never counts as slacking" do
    test "a huge backtrack_count/backtrack_rate never lands in the slacking list" do
      result =
        Metrics.flag_concerns(%{
          backtrack_count: 1000,
          backtrack_rate: 1.0,
          # nothing else here should trip any *other* slacking rule either
          dwell_ratio: 1.0,
          avg_scroll_depth_percent: 100,
          paste_ratio: 0.0
        })

      assert result.slacking == []
      assert :backtracked in result.struggling
      assert :high_backtrack_rate in result.content
    end
  end
end
