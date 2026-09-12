defmodule Athena.Gamification.Workers.DailyChallengeCleanupTest do
  use Athena.DataCase, async: true

  alias Athena.Gamification.DailyChallenge
  alias Athena.Gamification.Workers.DailyChallengeCleanup
  alias Athena.Repo

  test "deletes daily challenges older than the retention window" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    stale =
      Repo.insert!(%DailyChallenge{
        id: Ecto.UUID.generate(),
        account_id: Ecto.UUID.generate(),
        block_id: Ecto.UUID.generate(),
        assigned_date: Date.add(Date.utc_today(), -31),
        inserted_at: now,
        updated_at: now
      })

    fresh =
      Repo.insert!(%DailyChallenge{
        id: Ecto.UUID.generate(),
        account_id: Ecto.UUID.generate(),
        block_id: Ecto.UUID.generate(),
        assigned_date: Date.utc_today(),
        inserted_at: now,
        updated_at: now
      })

    assert :ok = DailyChallengeCleanup.perform(%Oban.Job{args: %{}})

    refute Repo.get(DailyChallenge, stale.id)
    assert Repo.get(DailyChallenge, fresh.id)
  end
end
