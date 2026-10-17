defmodule Athena.Engagement.PartitionsTest do
  # Creating a partition locks the parent table; kept out of the async pool
  # so it never waits on (or holds up) other tests writing events.
  use Athena.DataCase, async: false

  import Athena.Factory

  alias Athena.Engagement
  alias Athena.Engagement.Partitions
  alias Athena.Engagement.Workers.{EnsurePartitions, MoveLegacyEvents}

  defp partition_of(event_id) do
    %{rows: [[name]]} =
      Repo.query!("SELECT tableoid::regclass::text FROM engagement_events WHERE id = $1", [
        Ecto.UUID.dump!(event_id)
      ])

    name
  end

  test "ensure/1 creates the coming months, and events land in their month" do
    far = Date.utc_today() |> Date.beginning_of_month() |> Date.shift(month: 5)

    assert Partitions.name_for(far) in Partitions.ensure(5)
    assert Partitions.ensure(5) == []

    id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO engagement_events
        (id, account_id, block_id, section_id, session_id, event_type, occurred_at, inserted_at)
      VALUES ($1, $2, $2, $2, $2, 'viewport_enter', $3, $3)
      """,
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        NaiveDateTime.new!(far, ~T[12:00:00])
      ]
    )

    assert partition_of(id) == Partitions.name_for(far)
    assert :ok = perform_job(EnsurePartitions, %{})
  end

  test "new events go to the current month's partition" do
    block = insert(:block)
    account = insert(:account)

    Engagement.record_events(account.id, nil, Ecto.UUID.generate(), [
      %{block_id: block.id, section_id: block.section_id, event_type: :viewport_enter}
    ])

    [event] = Repo.all(Athena.Engagement.Event)
    assert partition_of(event.id) == Partitions.name_for(Date.utc_today())
  end

  describe "moving events recorded before partitioning" do
    setup do
      Repo.query!("""
      CREATE TABLE IF NOT EXISTS engagement_events_legacy (
        id uuid PRIMARY KEY, account_id uuid NOT NULL, block_id uuid NOT NULL,
        section_id uuid NOT NULL, cohort_id uuid, session_id uuid NOT NULL,
        event_type varchar(255) NOT NULL, payload jsonb DEFAULT '{}'::jsonb,
        occurred_at timestamp(0) NOT NULL, inserted_at timestamp(0) NOT NULL
      )
      """)

      Repo.query!("DELETE FROM engagement_events_legacy")

      for days_ago <- 1..7 do
        at = NaiveDateTime.add(NaiveDateTime.utc_now(), -days_ago * 86_400, :second)

        Repo.query!(
          """
          INSERT INTO engagement_events_legacy
            (id, account_id, block_id, section_id, session_id, event_type, payload, occurred_at, inserted_at)
          VALUES (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
                  gen_random_uuid(), 'viewport_enter', '{"n": 1}', $1, $1)
          """,
          [NaiveDateTime.truncate(at, :second)]
        )
      end

      :ok
    end

    test "batches move the newest rows first, each row exactly once" do
      assert Partitions.move_legacy_batch(3) == 3

      %{rows: [[newest_moved]]} = Repo.query!("SELECT min(inserted_at) FROM engagement_events")

      %{rows: [[newest_left]]} =
        Repo.query!("SELECT max(inserted_at) FROM engagement_events_legacy")

      assert NaiveDateTime.compare(newest_left, newest_moved) == :lt

      assert Partitions.move_legacy_batch(100) == 4
      assert Partitions.move_legacy_batch(100) == 0
      assert Repo.aggregate(Athena.Engagement.Event, :count) == 7
    end

    test "the worker moves everything and drops the emptied table" do
      assert :ok = perform_job(MoveLegacyEvents, %{})

      assert Repo.aggregate(Athena.Engagement.Event, :count) == 7
      assert Partitions.move_legacy_batch(100) == :done
    end
  end
end
