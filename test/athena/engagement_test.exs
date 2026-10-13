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

    test "broadcasts each block's events once per batch on its cohort/block topic", %{
      account: account,
      cohort: cohort,
      block: block,
      session_id: session_id
    } do
      Phoenix.PubSub.subscribe(Athena.PubSub, "engagement:#{cohort.id}:#{block.id}")
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      events =
        for type <- [:paste_detected, :answer_changed] do
          %{
            block_id: block.id,
            section_id: block.section_id,
            event_type: type,
            payload: %{"pasted_chars" => 40, "total_chars" => 42},
            occurred_at: now
          }
        end

      assert {:ok, 2} = Engagement.record_events(account.id, cohort.id, session_id, events)

      assert_received {:engagement_events, [first, second]}
      assert first.event_type == :paste_detected
      assert first.session_id == session_id
      assert second.event_type == :answer_changed
      refute_received {:engagement_events, _}
    end

    test "normalize_event/2 keeps a client clock that is far off within a day of the server's" do
      far_past = DateTime.add(DateTime.utc_now(), -10, :day) |> DateTime.to_iso8601()

      normalized =
        Engagement.normalize_event(
          %{"block_id" => "b", "event_type" => "viewport_enter", "occurred_at" => far_past},
          "s"
        )

      assert DateTime.diff(DateTime.utc_now(), normalized.occurred_at, :hour) == 24
    end
  end
end
