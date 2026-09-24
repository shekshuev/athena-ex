defmodule Athena.Engagement.ExamIntegrityStatsTest do
  # Not async: pokes global :athena, Athena.Engagement config to speed up the
  # idle-timeout test, and starts/stops named (Registry-keyed) processes that
  # would otherwise collide with a concurrently-running copy of this test.
  use ExUnit.Case, async: false

  alias Athena.Engagement.ExamIntegrityStats

  describe "percentile_rank/4" do
    test "nil when there are fewer peers than the minimum sample size" do
      cohort_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      for i <- 1..5 do
        ExamIntegrityStats.report_rate(cohort_id, block_id, "peer-#{i}", :paste_ratio, 0.5)
      end

      assert ExamIntegrityStats.percentile_rank(cohort_id, block_id, :paste_ratio, 0.9) == nil
    end

    test "a value at the mean lands around the 50th percentile once there's enough peer data" do
      cohort_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      for i <- 1..30 do
        rate = 1.0 + :rand.normal() * 0.1

        ExamIntegrityStats.report_rate(
          cohort_id,
          block_id,
          "peer-#{i}",
          :tab_hidden_per_minute,
          rate
        )
      end

      percentile =
        ExamIntegrityStats.percentile_rank(cohort_id, block_id, :tab_hidden_per_minute, 1.0)

      assert_in_delta percentile, 50.0, 20.0
    end

    test "a far-above-average value lands near the top of the distribution" do
      cohort_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      for i <- 1..30 do
        ExamIntegrityStats.report_rate(
          cohort_id,
          block_id,
          "peer-#{i}",
          :answer_changed_per_minute,
          0.2
        )
      end

      percentile =
        ExamIntegrityStats.percentile_rank(cohort_id, block_id, :answer_changed_per_minute, 10.0)

      assert percentile > 95.0
    end

    test "a submission's own later report replaces its earlier one instead of accumulating as a new peer" do
      cohort_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      for i <- 1..20 do
        ExamIntegrityStats.report_rate(cohort_id, block_id, "peer-#{i}", :paste_ratio, 0.1)
      end

      submission_id = "the-student"
      ExamIntegrityStats.report_rate(cohort_id, block_id, submission_id, :paste_ratio, 0.9)
      ExamIntegrityStats.report_rate(cohort_id, block_id, submission_id, :paste_ratio, 0.1)

      # If the earlier 0.9 report had lingered as a second "peer" instead of
      # being replaced, the mean/variance (and thus this student's own
      # percentile at 0.1) would be measurably different from a cohort
      # where every value, including this student's own, is 0.1.
      percentile = ExamIntegrityStats.percentile_rank(cohort_id, block_id, :paste_ratio, 0.1)
      assert_in_delta percentile, 50.0, 5.0
    end
  end

  describe "forget/3" do
    test "removes a submission's contribution, shrinking the effective sample size" do
      cohort_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      # Exactly at the minimum sample size - removing even one submission
      # must drop the effective count below the threshold.
      for i <- 1..15 do
        ExamIntegrityStats.report_rate(cohort_id, block_id, "peer-#{i}", :paste_ratio, 0.1)
      end

      assert ExamIntegrityStats.percentile_rank(cohort_id, block_id, :paste_ratio, 0.9) != nil

      ExamIntegrityStats.forget(cohort_id, block_id, "peer-1")

      # `forget` is a cast - round-trip a synchronous call on the same
      # process first, so this assertion only runs after it's processed.
      _ = ExamIntegrityStats.percentile_rank(cohort_id, block_id, :paste_ratio, 0.9)

      assert ExamIntegrityStats.percentile_rank(cohort_id, block_id, :paste_ratio, 0.9) == nil
    end

    test "is a no-op when no process is running for that exam" do
      assert ExamIntegrityStats.forget(Ecto.UUID.generate(), Ecto.UUID.generate(), "nobody") ==
               :ok
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
