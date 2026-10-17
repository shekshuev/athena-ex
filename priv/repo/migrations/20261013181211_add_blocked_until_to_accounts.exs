defmodule Athena.Repo.Migrations.AddBlockedUntilToAccounts do
  @moduledoc """
  A temporary block now carries its own expiry instead of relying on a
  one-off Oban job to lift it.

  Accounts already stuck in `temporary_blocked` get an expiry 30 minutes
  after their last failed login (or right away when there is none, e.g. an
  admin set the status by hand), so the sweeper releases them after deploy.
  """
  use Ecto.Migration

  def up do
    alter table(:accounts) do
      add :blocked_until, :utc_datetime
    end

    execute """
    UPDATE accounts
    SET blocked_until = COALESCE(last_failed_at + interval '30 minutes', now())
    WHERE status = 'temporary_blocked'
    """

    create index(:accounts, [:blocked_until],
             where: "status = 'temporary_blocked'",
             name: :accounts__temporary_blocked_until__idx
           )
  end

  def down do
    drop index(:accounts, [:blocked_until], name: :accounts__temporary_blocked_until__idx)

    alter table(:accounts) do
      remove :blocked_until
    end
  end
end
