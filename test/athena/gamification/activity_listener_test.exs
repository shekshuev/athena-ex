defmodule Athena.Gamification.ActivityListenerTest do
  use Athena.DataCase, async: true

  alias Athena.Gamification.{ActivityListener, XpLedger}
  import Athena.Factory

  # Exercises the handler logic directly (as a plain function call, in the
  # test's own process) rather than through the live supervised GenServer —
  # going through the real PubSub-delivered message would run the handler in
  # the singleton listener process, which isn't allowed onto this test's
  # sandboxed DB connection.
  describe "handle_info/2" do
    test "awards XP for a :block_completed fact" do
      account = insert(:account)
      block = insert(:block, type: :code)

      payload = %{account_id: account.id, block_id: block.id, block_type: :code, cohort_id: nil}

      assert {:noreply, %{}} = ActivityListener.handle_info({:block_completed, payload}, %{})
      assert XpLedger.total_xp(account.id) == 15
    end

    test "ignores unrelated messages" do
      assert {:noreply, %{}} = ActivityListener.handle_info(:some_other_message, %{})
    end
  end
end
