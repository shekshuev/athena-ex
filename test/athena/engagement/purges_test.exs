defmodule Athena.Engagement.PurgesTest do
  # The rollup cursor is a single global row, as in RollupsTest.
  use Athena.DataCase, async: false

  import Athena.Factory

  alias Athena.Engagement
  alias Athena.Engagement.{Event, Purge, Purges, Rollup, Rollups}
  alias Athena.Engagement.Workers.PurgeRawEvents

  setup do
    section = insert(:section)
    block = insert(:block, section: section, type: :text)
    cohort = insert(:cohort)
    [kept, purged] = for _ <- 1..2, do: insert(:account)
    admin = insert(:account, role: insert(:role, permissions: ["admin"]))

    %{block: block, cohort: cohort, kept: kept, purged: purged, admin: admin}
  end

  defp visit(ctx, account, days_ago) do
    start =
      Athena.TimeZones.today()
      |> Date.add(-days_ago)
      |> Athena.TimeZones.start_of_day()
      |> DateTime.add(10 * 3600, :second)

    Engagement.record_events(account.id, ctx.cohort.id, Ecto.UUID.generate(), [
      %{
        block_id: ctx.block.id,
        section_id: ctx.block.section_id,
        event_type: :viewport_enter,
        occurred_at: start
      },
      %{
        block_id: ctx.block.id,
        section_id: ctx.block.section_id,
        event_type: :viewport_exit,
        occurred_at: DateTime.add(start, 90, :second)
      }
    ])
  end

  defp rollups_of(account), do: Repo.all(from r in Rollup, where: r.account_id == ^account.id)

  defp events_of(account), do: Repo.all(from e in Event, where: e.account_id == ^account.id)

  test "only someone allowed to delete engagement data can request a purge", ctx do
    student = insert(:account, role: insert(:role, permissions: []))

    assert {:error, :forbidden} = Engagement.purge_raw_events(student, :account, ctx.purged.id)

    assert {:ok, %Purge{status: :pending}} =
             Engagement.purge_raw_events(ctx.admin, :account, ctx.purged.id)

    assert_enqueued(worker: PurgeRawEvents)
  end

  test "deletes the account's raw events once they're in the rollups, keeping the rollups", ctx do
    visit(ctx, ctx.purged, 2)
    visit(ctx, ctx.kept, 2)

    {:ok, purge} = Engagement.purge_raw_events(ctx.admin, :account, ctx.purged.id)

    # Nothing folded into rollups yet: the job waits.
    assert {:snooze, _} = perform_job(PurgeRawEvents, %{"purge_id" => purge.id})
    assert length(events_of(ctx.purged)) == 2

    Rollups.process_new_events()
    rollups_before = rollups_of(ctx.purged)
    assert [%Rollup{dwell_n: 1}] = rollups_before

    assert :ok = perform_job(PurgeRawEvents, %{"purge_id" => purge.id})

    assert events_of(ctx.purged) == []
    assert length(events_of(ctx.kept)) == 2
    assert rollups_of(ctx.purged) == rollups_before
    assert %Purge{status: :done, deleted_count: 2} = Repo.reload!(purge)
  end

  test "a later event on a purged day never rebuilds that day from what's left", ctx do
    visit(ctx, ctx.purged, 2)
    visit(ctx, ctx.kept, 2)
    Rollups.process_new_events()

    {:ok, purge} = Engagement.purge_raw_events(ctx.admin, :cohort, ctx.cohort.id)
    :ok = Purges.run(purge)

    rollups_before = Repo.all(Rollup) |> Enum.sort_by(& &1.id)

    # A late (offline) batch for the purged day arrives afterwards.
    visit(ctx, ctx.kept, 2)
    Rollups.process_new_events()

    assert Repo.all(Rollup) |> Enum.sort_by(& &1.id) == rollups_before
  end

  test "days after the purge day are still rolled up", ctx do
    {:ok, purge} = Engagement.purge_raw_events(ctx.admin, :account, ctx.purged.id)
    :ok = Purges.run(purge)

    tomorrow =
      Athena.TimeZones.today() |> Date.add(1) |> Athena.TimeZones.start_of_day()

    Engagement.record_events(ctx.purged.id, ctx.cohort.id, Ecto.UUID.generate(), [
      %{
        block_id: ctx.block.id,
        section_id: ctx.block.section_id,
        event_type: :viewport_enter,
        occurred_at: tomorrow
      }
    ])

    Rollups.process_new_events()
    assert [%Rollup{enter_count: 1}] = rollups_of(ctx.purged)
  end

  test "rollups can't be reset once raw events were purged", ctx do
    {:ok, _purge} = Engagement.purge_raw_events(ctx.admin, :account, ctx.purged.id)
    assert {:error, :raw_events_purged} = Rollups.reset()
  end
end
