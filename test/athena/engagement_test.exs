defmodule Athena.EngagementTest do
  use Athena.DataCase, async: true

  import Athena.Factory

  alias Athena.Engagement
  alias Athena.Engagement.Event

  setup do
    account = insert(:account)
    cohort = insert(:cohort)
    block = insert(:block)
    session_id = Ecto.UUID.generate()

    %{account: account, cohort: cohort, block: block, session_id: session_id}
  end

  describe "record_events/4" do
    test "inserts a batch of events and returns the count", %{
      account: account,
      cohort: cohort,
      block: block,
      session_id: session_id
    } do
      events = [
        %{
          block_id: block.id,
          section_id: block.section_id,
          event_type: :viewport_enter,
          occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        %{
          block_id: block.id,
          section_id: block.section_id,
          event_type: :viewport_exit,
          payload: %{"dwell_ms" => 4200},
          occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
        }
      ]

      assert {:ok, 2} = Engagement.record_events(account.id, cohort.id, session_id, events)

      stored = Repo.all(Event)
      assert length(stored) == 2
      assert Enum.all?(stored, &(&1.account_id == account.id))
      assert Enum.all?(stored, &(&1.cohort_id == cohort.id))
      assert Enum.all?(stored, &(&1.session_id == session_id))
    end

    test "returns an error for an empty batch", %{account: account, cohort: cohort} do
      assert {:error, :empty} = Engagement.record_events(account.id, cohort.id, "sess", [])
    end

    test "broadcasts each event on the cohort/block and session topics", %{
      account: account,
      cohort: cohort,
      block: block,
      session_id: session_id
    } do
      Phoenix.PubSub.subscribe(Athena.PubSub, "engagement:#{cohort.id}:#{block.id}")
      Phoenix.PubSub.subscribe(Athena.PubSub, "engagement_session:#{account.id}:#{session_id}")

      events = [
        %{
          block_id: block.id,
          section_id: block.section_id,
          event_type: :paste_detected,
          payload: %{"pasted_chars" => 40, "total_chars" => 42},
          occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
        }
      ]

      assert {:ok, 1} = Engagement.record_events(account.id, cohort.id, session_id, events)

      assert_received {:engagement_event, %{event_type: :paste_detected, block_id: block_id}}
      assert block_id == block.id

      assert_received {:engagement_event, %{event_type: :paste_detected, session_id: ^session_id}}
    end
  end

  describe "get_session_timeline/2" do
    test "returns events for a session in occurred_at order", %{
      account: account,
      cohort: cohort,
      block: block,
      session_id: session_id
    } do
      later = DateTime.utc_now() |> DateTime.truncate(:second)
      earlier = DateTime.add(later, -60, :second)

      Engagement.record_events(account.id, cohort.id, session_id, [
        %{
          block_id: block.id,
          section_id: block.section_id,
          event_type: :viewport_exit,
          occurred_at: later
        },
        %{
          block_id: block.id,
          section_id: block.section_id,
          event_type: :viewport_enter,
          occurred_at: earlier
        }
      ])

      [first, second] = Engagement.get_session_timeline(account.id, session_id)
      assert first.event_type == :viewport_enter
      assert second.event_type == :viewport_exit
    end
  end
end
