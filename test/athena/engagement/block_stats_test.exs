defmodule Athena.Engagement.BlockStatsTest do
  # Not async: pokes global :athena, Athena.Engagement config to speed up the
  # idle-timeout test, and starts/stops named (Registry-keyed) processes that
  # would otherwise collide with a concurrently-running copy of this test.
  use Athena.DataCase, async: false

  import Athena.Factory

  alias Athena.Engagement
  alias Athena.Engagement.BlockStats

  setup do
    cohort = insert(:cohort)
    block = insert(:block)
    %{cohort: cohort, block: block}
  end

  describe "get_or_start/2" do
    test "starts a process on first call and reuses it on the next", %{
      cohort: cohort,
      block: block
    } do
      {:ok, pid1} = BlockStats.get_or_start(cohort.id, block.id)
      {:ok, pid2} = BlockStats.get_or_start(cohort.id, block.id)
      assert pid1 == pid2
      assert Process.alive?(pid1)
    end
  end

  describe "snapshot/2 and percentile_rank/3" do
    test "reflects dwell pairs bootstrapped from existing events", %{
      cohort: cohort,
      block: block
    } do
      session_a = Ecto.UUID.generate()
      session_b = Ecto.UUID.generate()
      account = insert(:account)

      # 60s dwell, then 180s dwell, bootstrapped from the database before the
      # process is ever started.
      write_dwell(account.id, cohort.id, block, session_a, 0, 60)
      write_dwell(account.id, cohort.id, block, session_b, 0, 180)

      snapshot = BlockStats.snapshot(cohort.id, block.id)
      assert snapshot.n == 2
      assert_in_delta snapshot.mean, 120.0, 0.01

      # A dwell shorter than both bootstrapped samples should rank low.
      assert BlockStats.percentile_rank(cohort.id, block.id, 10) < 50.0
    end

    test "returns nil percentile and n: 0 with no data at all", %{cohort: cohort, block: block} do
      snapshot = BlockStats.snapshot(cohort.id, block.id)
      assert snapshot.n == 0
      assert BlockStats.percentile_rank(cohort.id, block.id, 30) == nil
    end

    test "updates incrementally from live PubSub events, not just bootstrap", %{
      cohort: cohort,
      block: block
    } do
      {:ok, _pid} = BlockStats.get_or_start(cohort.id, block.id)
      account = insert(:account)
      session_id = Ecto.UUID.generate()

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      later = DateTime.add(now, 45, :second)

      Engagement.record_events(account.id, cohort.id, session_id, [
        %{
          block_id: block.id,
          section_id: block.section_id,
          event_type: :viewport_enter,
          occurred_at: now
        },
        %{
          block_id: block.id,
          section_id: block.section_id,
          event_type: :viewport_exit,
          occurred_at: later
        }
      ])

      # The GenServer processes PubSub messages async - wait for it to settle.
      wait_until(fn -> BlockStats.snapshot(cohort.id, block.id).n == 1 end)

      snapshot = BlockStats.snapshot(cohort.id, block.id)
      assert snapshot.n == 1
      assert_in_delta snapshot.mean, 45.0, 0.01
    end

    test "ignores a viewport_exit with no matching pending viewport_enter", %{
      cohort: cohort,
      block: block
    } do
      {:ok, _pid} = BlockStats.get_or_start(cohort.id, block.id)
      account = insert(:account)

      Engagement.record_events(account.id, cohort.id, Ecto.UUID.generate(), [
        %{
          block_id: block.id,
          section_id: block.section_id,
          event_type: :viewport_exit,
          occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
        }
      ])

      Process.sleep(50)
      assert BlockStats.snapshot(cohort.id, block.id).n == 0
    end
  end

  describe "histogram/2" do
    test "a dwell lands in the bucket matching its own seconds, bucket_width and n populated", %{
      cohort: cohort,
      block: block
    } do
      account = insert(:account)
      write_dwell(account.id, cohort.id, block, Ecto.UUID.generate(), 0, 60)

      histogram = BlockStats.histogram(cohort.id, block.id)

      assert histogram.n == 1
      assert_in_delta histogram.bucket_width, 1200 / 10, 0.001
      assert histogram.buckets == %{0 => 1}
    end

    test "returns an empty buckets map and n: 0 with no data at all", %{
      cohort: cohort,
      block: block
    } do
      histogram = BlockStats.histogram(cohort.id, block.id)

      assert histogram.n == 0
      assert histogram.buckets == %{}
    end

    test "dwells far apart in duration land in different buckets, tallied separately", %{
      cohort: cohort,
      block: block
    } do
      account = insert(:account)
      # Default bucket_width is 1200/10 = 120s - 60s lands in bucket 0,
      # 200s lands in bucket 1.
      write_dwell(account.id, cohort.id, block, Ecto.UUID.generate(), 0, 60)
      write_dwell(account.id, cohort.id, block, Ecto.UUID.generate(), 0, 200)

      histogram = BlockStats.histogram(cohort.id, block.id)

      assert histogram.n == 2
      assert histogram.buckets == %{0 => 1, 1 => 1}
    end

    test "reflects dwells recorded live via PubSub, not just the bootstrap read", %{
      cohort: cohort,
      block: block
    } do
      {:ok, _pid} = BlockStats.get_or_start(cohort.id, block.id)
      account = insert(:account)
      session_id = Ecto.UUID.generate()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Engagement.record_events(account.id, cohort.id, session_id, [
        %{
          block_id: block.id,
          section_id: block.section_id,
          event_type: :viewport_enter,
          occurred_at: now
        },
        %{
          block_id: block.id,
          section_id: block.section_id,
          event_type: :viewport_exit,
          occurred_at: DateTime.add(now, 45, :second)
        }
      ])

      wait_until(fn -> BlockStats.histogram(cohort.id, block.id).n == 1 end)

      histogram = BlockStats.histogram(cohort.id, block.id)
      assert histogram.n == 1
      assert histogram.buckets == %{0 => 1}
    end
  end

  describe "idle timeout" do
    test "stops after being idle, and is transparently recreated on next use", %{
      cohort: cohort,
      block: block
    } do
      original = Application.get_env(:athena, Athena.Engagement, [])

      Application.put_env(
        :athena,
        Athena.Engagement,
        Keyword.put(original, :block_stats_idle_timeout_minutes, 0.002)
      )

      on_exit(fn -> Application.put_env(:athena, Athena.Engagement, original) end)

      {:ok, pid} = BlockStats.get_or_start(cohort.id, block.id)
      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000

      # `Registry` unregisters the dead pid via its own internal monitor,
      # which resolves independently of (and not necessarily before) our
      # own monitor's :DOWN message - give it a moment to catch up before
      # asserting that a fresh process gets started.
      wait_until(fn ->
        Registry.lookup(Athena.Engagement.BlockStatsRegistry, {cohort.id, block.id}) == []
      end)

      {:ok, new_pid} = BlockStats.get_or_start(cohort.id, block.id)
      assert new_pid != pid
      assert Process.alive?(new_pid)
    end
  end

  defp write_dwell(account_id, cohort_id, block, session_id, enter_offset, exit_offset) do
    base = DateTime.utc_now() |> DateTime.truncate(:second)

    Engagement.record_events(account_id, cohort_id, session_id, [
      %{
        block_id: block.id,
        section_id: block.section_id,
        event_type: :viewport_enter,
        occurred_at: DateTime.add(base, enter_offset, :second)
      },
      %{
        block_id: block.id,
        section_id: block.section_id,
        event_type: :viewport_exit,
        occurred_at: DateTime.add(base, exit_offset, :second)
      }
    ])
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
