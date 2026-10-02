defmodule Athena.Engagement.ProctoringMonitorTest do
  # Not async: pokes global :athena, Athena.Engagement config to speed up the
  # idle-timeout test, and starts/stops named (Registry-keyed) processes that
  # would otherwise collide with a concurrently-running copy of this test.
  use ExUnit.Case, async: false

  alias Athena.Engagement.ProctoringMonitor

  describe "get_or_start/3" do
    test "starts a process on first call and reuses it on the next" do
      submission_id = Ecto.UUID.generate()
      cohort_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      {:ok, pid1} = ProctoringMonitor.get_or_start(submission_id, cohort_id, block_id)
      {:ok, pid2} = ProctoringMonitor.get_or_start(submission_id, cohort_id, block_id)

      assert pid1 == pid2
      assert Process.alive?(pid1)
    end
  end

  describe "report_events/4 and snapshot/1" do
    test "returns an all-zero reading for a submission with no process (nothing reported yet)" do
      reading = ProctoringMonitor.snapshot(Ecto.UUID.generate())

      # Floored, never exactly zero - it's a division denominator in
      # `Athena.Engagement.Proctoring.evaluate/4`.
      assert reading.elapsed_minutes > 0.0

      assert reading.counts == %{
               tab_hidden: 0,
               window_blur: 0,
               printscreen_attempt: 0,
               copy_attempt: 0,
               cut_attempt: 0,
               multi_tab_detected: 0,
               answer_changed: 0,
               code_run_attempt: 0,
               right_click_attempt: 0,
               bulk_insert: 0,
               offline_period: 0,
               mouse_left: 0,
               fullscreen_exit: 0,
               large_paste: 0,
               split_screen: 0,
               paste_ratio: 0.0
             }

      assert reading.silence_seconds == 0
      assert reading.max_silence_seconds == 0
      assert reading.away_incidents == 0
      assert reading.away_total_seconds == 0
      assert reading.incidents == []
    end

    test "accumulates only tracked event types, incrementally, across multiple batches" do
      submission_id = Ecto.UUID.generate()
      cohort_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      ProctoringMonitor.report_events(submission_id, cohort_id, block_id, [
        %{event_type: :tab_hidden},
        %{event_type: :printscreen_attempt},
        # Not a tracked type - must be silently ignored, not crash.
        %{event_type: :viewport_enter}
      ])

      ProctoringMonitor.report_events(submission_id, cohort_id, block_id, [
        %{event_type: :tab_hidden}
      ])

      reading = ProctoringMonitor.snapshot(submission_id)
      assert reading.counts.tab_hidden == 2
      assert reading.counts.printscreen_attempt == 1
      assert reading.counts.copy_attempt == 0
      assert reading.elapsed_minutes > 0
    end

    test "right_click_attempt is tracked like any other hard-evidence-style count" do
      submission_id = Ecto.UUID.generate()

      ProctoringMonitor.report_events(submission_id, Ecto.UUID.generate(), "block", [
        %{event_type: :right_click_attempt},
        %{event_type: :right_click_attempt}
      ])

      assert ProctoringMonitor.snapshot(submission_id).counts.right_click_attempt == 2
    end

    test "paste_detected accumulates into a running ratio, not a plain count" do
      submission_id = Ecto.UUID.generate()
      cohort_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      ProctoringMonitor.report_events(submission_id, cohort_id, block_id, [
        %{event_type: :paste_detected, payload: %{"pasted_chars" => 50, "total_chars" => 100}}
      ])

      ProctoringMonitor.report_events(submission_id, cohort_id, block_id, [
        %{event_type: :paste_detected, payload: %{"pasted_chars" => 50, "total_chars" => 100}}
      ])

      reading = ProctoringMonitor.snapshot(submission_id)
      # 100 pasted / 200 total across both events.
      assert_in_delta reading.counts.paste_ratio, 0.5, 0.001
    end

    test "an empty event list is a no-op and never starts a process" do
      submission_id = Ecto.UUID.generate()

      assert ProctoringMonitor.report_events(submission_id, nil, "block", []) == :ok
      assert Registry.lookup(Athena.Engagement.ProctoringMonitorRegistry, submission_id) == []
    end

    test "broadcasts a ping on the submission's own proctoring topic" do
      submission_id = Ecto.UUID.generate()
      Phoenix.PubSub.subscribe(Athena.PubSub, "proctoring:#{submission_id}")

      ProctoringMonitor.report_events(submission_id, Ecto.UUID.generate(), Ecto.UUID.generate(), [
        %{event_type: :copy_attempt}
      ])

      assert_receive {:proctoring_updated, ^submission_id}
    end
  end

  describe "heartbeat/3" do
    test "starts a fresh process even with nothing to report - unlike an empty report_events/4 batch" do
      submission_id = Ecto.UUID.generate()

      :ok = ProctoringMonitor.heartbeat(submission_id, Ecto.UUID.generate(), "block")

      assert [{pid, _}] =
               Registry.lookup(Athena.Engagement.ProctoringMonitorRegistry, submission_id)

      assert Process.alive?(pid)
      assert ProctoringMonitor.snapshot(submission_id).counts.tab_hidden == 0
    end

    test "broadcasts a ping on the submission's own proctoring topic" do
      submission_id = Ecto.UUID.generate()
      Phoenix.PubSub.subscribe(Athena.PubSub, "proctoring:#{submission_id}")

      ProctoringMonitor.heartbeat(submission_id, Ecto.UUID.generate(), "block")

      assert_receive {:proctoring_updated, ^submission_id}
    end
  end

  describe "telemetry silence" do
    test "a live gap since the last activity shows up in silence_seconds without another event" do
      submission_id = Ecto.UUID.generate()

      ProctoringMonitor.heartbeat(submission_id, Ecto.UUID.generate(), "block")
      Process.sleep(1100)

      reading = ProctoringMonitor.snapshot(submission_id)
      assert reading.silence_seconds >= 1
    end

    test "closing a gap with new activity folds it into max_silence_seconds and resets the live gap" do
      submission_id = Ecto.UUID.generate()
      cohort_id = Ecto.UUID.generate()

      ProctoringMonitor.heartbeat(submission_id, cohort_id, "block")
      Process.sleep(1100)
      ProctoringMonitor.heartbeat(submission_id, cohort_id, "block")

      reading = ProctoringMonitor.snapshot(submission_id)
      assert reading.max_silence_seconds >= 1
      assert reading.silence_seconds == 0
    end

    test "a gap while the tab is legitimately hidden does not count as silence" do
      submission_id = Ecto.UUID.generate()
      cohort_id = Ecto.UUID.generate()

      ProctoringMonitor.report_events(submission_id, cohort_id, "block", [
        %{event_type: :tab_hidden}
      ])

      Process.sleep(1100)

      reading = ProctoringMonitor.snapshot(submission_id)
      assert reading.silence_seconds == 0
      assert reading.max_silence_seconds == 0
    end
  end

  describe "away time" do
    defp back_event(type, duration_ms) do
      %{
        event_type: type,
        payload: %{"duration_ms" => duration_ms},
        occurred_at: DateTime.utc_now()
      }
    end

    test "a long enough absence counts as an incident and adds to the total" do
      submission_id = Ecto.UUID.generate()

      ProctoringMonitor.report_events(submission_id, Ecto.UUID.generate(), "block", [
        back_event(:window_focus, 15_000)
      ])

      reading = ProctoringMonitor.snapshot(submission_id)
      assert reading.away_incidents == 1
      assert reading.away_total_seconds == 15
    end

    test "a very short absence is in the total but is not an incident" do
      submission_id = Ecto.UUID.generate()

      ProctoringMonitor.report_events(submission_id, Ecto.UUID.generate(), "block", [
        back_event(:tab_visible, 3_000)
      ])

      reading = ProctoringMonitor.snapshot(submission_id)
      assert reading.away_incidents == 0
      assert reading.away_total_seconds == 3
    end

    test "the same absence seen by two signals (blur and hidden tab) is counted once" do
      submission_id = Ecto.UUID.generate()

      ProctoringMonitor.report_events(submission_id, Ecto.UUID.generate(), "block", [
        back_event(:window_focus, 20_000),
        back_event(:tab_visible, 18_000)
      ])

      reading = ProctoringMonitor.snapshot(submission_id)
      assert reading.away_incidents == 1
      assert reading.away_total_seconds == 20
    end

    test "leaving fullscreen counts as time away and as its own event" do
      submission_id = Ecto.UUID.generate()

      ProctoringMonitor.report_events(submission_id, Ecto.UUID.generate(), "block", [
        back_event(:fullscreen_exit, 30_000)
      ])

      reading = ProctoringMonitor.snapshot(submission_id)
      assert reading.counts.fullscreen_exit == 1
      assert reading.away_incidents == 1
    end
  end

  describe "environment and input signals" do
    test "an offline period is remembered as the longest one" do
      submission_id = Ecto.UUID.generate()

      ProctoringMonitor.report_events(submission_id, Ecto.UUID.generate(), "block", [
        %{event_type: :offline_period, payload: %{"duration_ms" => 70_000}},
        %{event_type: :offline_period, payload: %{"duration_ms" => 20_000}}
      ])

      reading = ProctoringMonitor.snapshot(submission_id)
      assert reading.counts.offline_period == 2
      assert reading.max_offline_seconds == 70
    end

    test "pointer-outside time accumulates" do
      submission_id = Ecto.UUID.generate()

      ProctoringMonitor.report_events(submission_id, Ecto.UUID.generate(), "block", [
        %{event_type: :mouse_left, payload: %{"duration_ms" => 12_000}},
        %{event_type: :mouse_left, payload: %{"duration_ms" => 8_000}}
      ])

      assert ProctoringMonitor.snapshot(submission_id).mouse_away_seconds == 20
    end

    test "only a window reported as split counts as split screen" do
      submission_id = Ecto.UUID.generate()

      ProctoringMonitor.report_events(submission_id, Ecto.UUID.generate(), "block", [
        %{event_type: :window_geometry_changed, payload: %{"split" => true}},
        %{event_type: :window_geometry_changed, payload: %{"split" => false}}
      ])

      assert ProctoringMonitor.snapshot(submission_id).counts.split_screen == 1
    end

    test "a large paste is counted separately from the paste ratio, and the longest is kept" do
      submission_id = Ecto.UUID.generate()

      ProctoringMonitor.report_events(submission_id, Ecto.UUID.generate(), "block", [
        %{event_type: :paste_detected, payload: %{"pasted_chars" => 20, "total_chars" => 100}},
        %{event_type: :paste_detected, payload: %{"pasted_chars" => 400, "total_chars" => 500}}
      ])

      reading = ProctoringMonitor.snapshot(submission_id)
      assert reading.counts.large_paste == 1
      assert reading.max_paste_chars == 400
    end

    test "typing summaries are totalled, never stored per keystroke" do
      submission_id = Ecto.UUID.generate()

      summary = %{
        "n" => 40,
        "median_dwell_ms" => 90,
        "flight_cv" => 0.5,
        "pauses" => 2,
        "max_clean_run" => 25,
        "chars_typed" => 35,
        "chars_deleted" => 5
      }

      ProctoringMonitor.report_events(submission_id, Ecto.UUID.generate(), "block", [
        %{event_type: :typing_summary, payload: summary},
        %{event_type: :typing_summary, payload: %{summary | "max_clean_run" => 12}}
      ])

      typing = ProctoringMonitor.snapshot(submission_id).typing
      assert typing.keys == 80
      assert typing.chars_typed == 70
      assert typing.chars_deleted == 10
      assert typing.max_clean_run == 25
      assert_in_delta typing.dwell_sum / typing.keys, 90.0, 0.001
    end
  end

  describe "finalize/1" do
    test "returns the final reading and stops the process" do
      submission_id = Ecto.UUID.generate()

      ProctoringMonitor.report_events(submission_id, Ecto.UUID.generate(), Ecto.UUID.generate(), [
        %{event_type: :cut_attempt}
      ])

      {:ok, pid} = ProctoringMonitor.get_or_start(submission_id, nil, "block")
      ref = Process.monitor(pid)

      reading = ProctoringMonitor.finalize(submission_id)
      assert reading.counts.cut_attempt == 1

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    end

    test "is idempotent - safe to call on a submission with no running process" do
      reading = ProctoringMonitor.finalize(Ecto.UUID.generate())
      assert reading.counts.tab_hidden == 0
      assert reading.elapsed_minutes > 0.0
    end
  end

  describe "idle timeout" do
    test "stops after being idle, and is transparently recreated on next use" do
      original = Application.get_env(:athena, Athena.Engagement, [])

      Application.put_env(
        :athena,
        Athena.Engagement,
        Keyword.put(original, :proctoring_monitor_idle_timeout_minutes, 0.002)
      )

      on_exit(fn -> Application.put_env(:athena, Athena.Engagement, original) end)

      submission_id = Ecto.UUID.generate()
      {:ok, pid} = ProctoringMonitor.get_or_start(submission_id, nil, "block")
      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000

      wait_until(fn ->
        Registry.lookup(Athena.Engagement.ProctoringMonitorRegistry, submission_id) == []
      end)

      {:ok, new_pid} = ProctoringMonitor.get_or_start(submission_id, nil, "block")
      assert new_pid != pid
      assert Process.alive?(new_pid)
    end
  end

  defp wait_until(fun, attempts \\ 20)
  defp wait_until(_fun, 0), do: flunk("condition not met in time")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end
end
