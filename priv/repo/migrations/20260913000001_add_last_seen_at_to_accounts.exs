defmodule Athena.Repo.Migrations.AddLastSeenAtToAccounts do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add :last_seen_at, :utc_datetime
    end
  end
end
