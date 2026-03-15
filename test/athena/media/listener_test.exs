defmodule Athena.Media.EventListenerTest do
  use Athena.DataCase, async: true

  alias Athena.Media.EventListener
  alias Athena.Media.Quota
  import Athena.Factory

  test "handle_info/2 with :role_deleted event deletes the quota" do
    quota = insert(:media_quota)

    assert Athena.Repo.get(Quota, quota.role_id) != nil

    assert {:noreply, _state} = EventListener.handle_info({:role_deleted, quota.role_id}, %{})

    assert Athena.Repo.get(Quota, quota.role_id) == nil
  end

  test "handle_info/2 ignores unknown events" do
    assert {:noreply, %{}} = EventListener.handle_info({:some_random_event, "data"}, %{})
  end
end
