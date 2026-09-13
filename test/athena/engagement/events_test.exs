defmodule Athena.Engagement.EventsTest do
  use ExUnit.Case, async: true

  alias Athena.Engagement.Events

  @account_id "acc-1"
  @block_id "block-1"
  @session_id "sess-1"

  defp event(type, occurred_at, opts \\ []) do
    %{
      account_id: Keyword.get(opts, :account_id, @account_id),
      block_id: Keyword.get(opts, :block_id, @block_id),
      session_id: Keyword.get(opts, :session_id, @session_id),
      event_type: type,
      occurred_at: occurred_at
    }
  end

  defp at(seconds_offset) do
    DateTime.add(~U[2026-01-01 12:00:00Z], seconds_offset, :second)
  end

  describe "pair_viewport_dwells/1 - no idle events (regression)" do
    test "pairs one enter/exit into its raw dwell, unchanged from before idle support" do
      events = [event(:viewport_enter, at(0)), event(:viewport_exit, at(30))]

      assert Events.pair_viewport_dwells(events) == [{@session_id, @account_id, 30}]
    end

    test "pairs multiple enter/exit windows within one session" do
      events = [
        event(:viewport_enter, at(0)),
        event(:viewport_exit, at(10)),
        event(:viewport_enter, at(20)),
        event(:viewport_exit, at(50))
      ]

      assert Events.pair_viewport_dwells(events) == [
               {@session_id, @account_id, 10},
               {@session_id, @account_id, 30}
             ]
    end

    test "ignores an unmatched trailing enter" do
      events = [
        event(:viewport_enter, at(0)),
        event(:viewport_exit, at(10)),
        event(:viewport_enter, at(20))
      ]

      assert Events.pair_viewport_dwells(events) == [{@session_id, @account_id, 10}]
    end

    test "keeps dwells from different sessions separate" do
      events = [
        event(:viewport_enter, at(0), session_id: "sess-a"),
        event(:viewport_exit, at(10), session_id: "sess-a"),
        event(:viewport_enter, at(0), session_id: "sess-b"),
        event(:viewport_exit, at(100), session_id: "sess-b")
      ]

      result = Events.pair_viewport_dwells(events)
      assert {"sess-a", @account_id, 10} in result
      assert {"sess-b", @account_id, 100} in result
      assert length(result) == 2
    end
  end

  describe "pair_viewport_dwells/1 - idle subtraction" do
    test "subtracts an idle window entirely inside the dwell window" do
      events = [
        event(:viewport_enter, at(0)),
        event(:idle_start, at(10)),
        event(:idle_end, at(40)),
        event(:viewport_exit, at(60))
      ]

      # raw 60s, minus 30s idle = 30s
      assert Events.pair_viewport_dwells(events) == [{@session_id, @account_id, 30}]
    end

    test "clips an idle window that started before viewport_enter" do
      events = [
        # idle_start happened "before" the block was entered (e.g. carried
        # over from idle detection racing the enter event)
        event(:idle_start, at(-20)),
        event(:viewport_enter, at(0)),
        event(:idle_end, at(10)),
        event(:viewport_exit, at(30))
      ]

      # only the [0,10] slice of the idle window (10s) falls inside [0,30]
      assert Events.pair_viewport_dwells(events) == [{@session_id, @account_id, 20}]
    end

    test "clips an idle window that had not ended by viewport_exit" do
      events = [
        event(:viewport_enter, at(0)),
        event(:idle_start, at(20)),
        event(:viewport_exit, at(30)),
        event(:idle_end, at(50))
      ]

      # only the [20,30] slice of the idle window (10s) falls inside [0,30]
      assert Events.pair_viewport_dwells(events) == [{@session_id, @account_id, 20}]
    end

    test "sums multiple idle windows inside one dwell window" do
      events = [
        event(:viewport_enter, at(0)),
        event(:idle_start, at(10)),
        event(:idle_end, at(20)),
        event(:idle_start, at(40)),
        event(:idle_end, at(50)),
        event(:viewport_exit, at(100))
      ]

      # raw 100s, minus (10 + 10) = 20s idle = 80s
      assert Events.pair_viewport_dwells(events) == [{@session_id, @account_id, 80}]
    end

    test "floors dwell at zero rather than going negative on clock skew" do
      events = [
        event(:viewport_enter, at(0)),
        event(:idle_start, at(0)),
        event(:idle_end, at(999)),
        event(:viewport_exit, at(5))
      ]

      assert Events.pair_viewport_dwells(events) == [{@session_id, @account_id, 0}]
    end

    test "an idle window does not affect a different session's dwell" do
      events = [
        event(:viewport_enter, at(0), session_id: "sess-a"),
        event(:idle_start, at(10), session_id: "sess-a"),
        event(:idle_end, at(20), session_id: "sess-a"),
        event(:viewport_exit, at(30), session_id: "sess-a"),
        event(:viewport_enter, at(0), session_id: "sess-b"),
        event(:viewport_exit, at(30), session_id: "sess-b")
      ]

      result = Events.pair_viewport_dwells(events)
      assert {"sess-a", @account_id, 20} in result
      assert {"sess-b", @account_id, 30} in result
    end

    test "an unmatched idle_start with no idle_end is ignored, not treated as open-ended" do
      events = [
        event(:viewport_enter, at(0)),
        event(:idle_start, at(10)),
        event(:viewport_exit, at(30))
      ]

      assert Events.pair_viewport_dwells(events) == [{@session_id, @account_id, 30}]
    end
  end

  describe "raw_viewport_window_seconds/1" do
    test "returns the raw window length, unaffected by idle time" do
      events = [
        event(:viewport_enter, at(0)),
        event(:idle_start, at(10)),
        event(:idle_end, at(40)),
        event(:viewport_exit, at(60))
      ]

      # raw, not the idle-adjusted 30s that pair_viewport_dwells/1 would give
      assert Events.raw_viewport_window_seconds(events) == [60]
    end

    test "sums multiple windows across sessions" do
      events = [
        event(:viewport_enter, at(0), session_id: "sess-a"),
        event(:viewport_exit, at(10), session_id: "sess-a"),
        event(:viewport_enter, at(0), session_id: "sess-b"),
        event(:viewport_exit, at(20), session_id: "sess-b")
      ]

      assert Enum.sort(Events.raw_viewport_window_seconds(events)) == [10, 20]
    end
  end
end
