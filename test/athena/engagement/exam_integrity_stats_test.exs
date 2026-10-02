defmodule Athena.Engagement.ExamIntegrityStatsTest do
  # Not async: pokes global :athena, Athena.Engagement config to speed up the
  # idle-timeout test, and starts/stops named (Registry-keyed) processes that
  # would otherwise collide with a concurrently-running copy of this test.
  use ExUnit.Case, async: false

  alias Athena.Engagement.ExamIntegrityStats

  describe "baselines/3" do
    defp report(cohort_id, block_id, id, metric, value),
      do: ExamIntegrityStats.report_rate(cohort_id, block_id, id, metric, value)

    test "a metric nobody has reported has no peers" do
      baselines = ExamIntegrityStats.baselines(Ecto.UUID.generate(), Ecto.UUID.generate(), nil)

      assert baselines[:paste_ratio] == nil
    end

    test "is the median of the others, so it already works for a group of three" do
      cohort_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      report(cohort_id, block_id, "me", :paste_ratio, 0.9)
      report(cohort_id, block_id, "a", :paste_ratio, 0.1)
      report(cohort_id, block_id, "b", :paste_ratio, 0.3)

      assert %{n: 2, median: median} =
               ExamIntegrityStats.baselines(cohort_id, block_id, "me")[:paste_ratio]

      assert_in_delta median, 0.2, 1.0e-9
    end

    test "never includes the student being judged" do
      cohort_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      report(cohort_id, block_id, "me", :paste_ratio, 0.9)
      report(cohort_id, block_id, "a", :paste_ratio, 0.1)

      assert %{n: 1} = ExamIntegrityStats.baselines(cohort_id, block_id, "me")[:paste_ratio]
      assert %{n: 2} = ExamIntegrityStats.baselines(cohort_id, block_id, nil)[:paste_ratio]
    end

    test "one wild peer does not drag the typical value - that is why it is a median" do
      cohort_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      for {id, v} <- [{"a", 0.1}, {"b", 0.1}, {"c", 0.1}, {"d", 5.0}] do
        report(cohort_id, block_id, id, :answer_changed_per_minute, v)
      end

      baseline =
        ExamIntegrityStats.baselines(cohort_id, block_id, "me")[:answer_changed_per_minute]

      assert_in_delta baseline.median, 0.1, 1.0e-9
    end

    test "spread is zero for identical peers and grows with disagreement" do
      cohort_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      for id <- ["a", "b", "c"], do: report(cohort_id, block_id, id, :paste_ratio, 0.2)

      for {id, v} <- [{"a", 0.1}, {"b", 0.5}, {"c", 0.9}],
          do: report(cohort_id, block_id, id, :right_click_per_minute, v)

      baselines = ExamIntegrityStats.baselines(cohort_id, block_id, nil)

      assert baselines[:paste_ratio].spread == 0.0
      assert baselines[:right_click_per_minute].spread > 0.0
    end

    test "a submission's own later report replaces its earlier one instead of becoming a second peer" do
      cohort_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      report(cohort_id, block_id, "a", :paste_ratio, 0.9)
      report(cohort_id, block_id, "a", :paste_ratio, 0.1)

      assert %{n: 1, median: median} =
               ExamIntegrityStats.baselines(cohort_id, block_id, nil)[:paste_ratio]

      assert_in_delta median, 0.1, 1.0e-9
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

      cohort_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      {:ok, pid} = ExamIntegrityStats.get_or_start(cohort_id, block_id)
      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000

      wait_until(fn ->
        Registry.lookup(Athena.Engagement.ExamIntegrityStatsRegistry, {cohort_id, block_id}) == []
      end)

      {:ok, new_pid} = ExamIntegrityStats.get_or_start(cohort_id, block_id)
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
