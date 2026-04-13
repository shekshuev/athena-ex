defmodule Athena.Repo.Migrations.AddMustChangePasswordToAccounts do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add :must_change_password, :boolean, default: false, null: false
    end
  end
end
