defmodule AthenaWeb.Presence do
  @moduledoc """
  Tracks which accounts are currently online, on a single shared
  `"presence:lobby"` topic (online-ness is an account-wide fact, not
  conversation-scoped — see the Messenger plan for why one shared topic is
  used instead of one per conversation).

  When an account's presence list becomes fully empty (all their tabs
  disconnected), records `last_seen_at` on their account.
  """
  use Phoenix.Presence, otp_app: :athena, pubsub_server: Athena.PubSub

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_metas("presence:lobby", %{leaves: leaves}, presences, state) do
    for {account_id, _metas} <- leaves do
      if Map.get(presences, account_id, []) == [] do
        safe_touch_last_seen(account_id)
        Phoenix.PubSub.broadcast(Athena.PubSub, "presence:lobby", {:went_offline, account_id})
      end
    end

    {:ok, state}
  end

  def handle_metas(_topic, _diff, _presences, state), do: {:ok, state}

  # `handle_metas/4` runs in the shared Presence tracker process, not the
  # caller's — a transient DB error here (e.g. a test's Ecto sandbox
  # connection no longer being checked out to this process) must not crash
  # this process, since it's shared by every connected user.
  defp safe_touch_last_seen(account_id) do
    Athena.Identity.touch_last_seen(account_id)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
