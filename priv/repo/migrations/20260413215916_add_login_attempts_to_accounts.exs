defmodule Athena.Repo.Migrations.AddLoginAttemptsToAccounts do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add :failed_login_attempts, :integer, default: 0, null: false
      add :last_failed_at, :utc_datetime
    end
  end
end
