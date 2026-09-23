defmodule Athena.Engagement.ProctoringMonitorTest do
  # Not async: pokes global :athena, Athena.Engagement config to speed up the
  # idle-timeout test, and starts/stops named (Registry-keyed) processes that
  # would otherwise collide with a concurrently-running copy of this test.
  use ExUnit.Case, async: false

  alias Athena.Engagement.ProctoringMonitor

  describe "get_or_start/1" do
    test "starts a process on first call and reuses it on the next" do
      submission_id = Ecto.UUID.generate()

      {:ok, pid1} = ProctoringMonitor.get_or_start(submission_id)
      {:ok, pid2} = ProctoringMonitor.get_or_start(submission_id)

      assert pid1 == pid2
      assert Process.alive?(pid1)
    end
  end

  describe "report_events/2 and snapshot/1" do
    test "returns all-zero counts for a submission with no process (nothing reported yet)" do
      assert ProctoringMonitor.snapshot(Ecto.UUID.generate()) == %{
               tab_hidden: 0,
               printscreen_attempt: 0,
               copy_attempt: 0,
               cut_attempt: 0
             }
    end

    test "accumulates only tracked event types, incrementally, across multiple batches" do
      submission_id = Ecto.UUID.generate()

      ProctoringMonitor.report_events(submission_id, [
        %{event_type: :tab_hidden},
        %{event_type: :printscreen_attempt},
        # Not a tracked type - must be silently ignored, not crash.
        %{event_type: :viewport_enter}
      ])

      ProctoringMonitor.report_events(submission_id, [%{event_type: :tab_hidden}])

      snapshot = ProctoringMonitor.snapshot(submission_id)
      assert snapshot.tab_hidden == 2
      assert snapshot.printscreen_attempt == 1
      assert snapshot.copy_attempt == 0
      assert snapshot.cut_attempt == 0
    end

    test "an empty event list is a no-op and never starts a process" do
      submission_id = Ecto.UUID.generate()

      assert ProctoringMonitor.report_events(submission_id, []) == :ok
      assert Registry.lookup(Athena.Engagement.ProctoringMonitorRegistry, submission_id) == []
    end

    test "broadcasts the running counts on the submission's own proctoring topic" do
      submission_id = Ecto.UUID.generate()
      Phoenix.PubSub.subscribe(Athena.PubSub, "proctoring:#{submission_id}")

      ProctoringMonitor.report_events(submission_id, [%{event_type: :copy_attempt}])

      assert_receive {:proctoring_updated, ^submission_id, %{copy_attempt: 1}}
    end
  end

  describe "finalize/1" do
    test "returns the final counts and stops the process" do
      submission_id = Ecto.UUID.generate()
      ProctoringMonitor.report_events(submission_id, [%{event_type: :cut_attempt}])

      {:ok, pid} = ProctoringMonitor.get_or_start(submission_id)
      ref = Process.monitor(pid)

      counts = ProctoringMonitor.finalize(submission_id)
      assert counts.cut_attempt == 1

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    end

    test "is idempotent - safe to call on a submission with no running process" do
      assert ProctoringMonitor.finalize(Ecto.UUID.generate()) == %{
               tab_hidden: 0,
               printscreen_attempt: 0,
               copy_attempt: 0,
               cut_attempt: 0
             }
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
      {:ok, pid} = ProctoringMonitor.get_or_start(submission_id)
      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000

      wait_until(fn ->
        Registry.lookup(Athena.Engagement.ProctoringMonitorRegistry, submission_id) == []
      end)

      {:ok, new_pid} = ProctoringMonitor.get_or_start(submission_id)
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
