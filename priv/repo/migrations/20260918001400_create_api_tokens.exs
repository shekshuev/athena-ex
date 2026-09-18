defmodule Athena.Repo.Migrations.CreateApiTokens do
  use Ecto.Migration

  def change do
    create table(:api_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :owner_id, references(:accounts, type: :binary_id, on_delete: :delete_all), null: false

      add :label, :string, null: false
      add :token_hash, :binary, null: false
      add :token_prefix, :string, null: false
      add :last_used_at, :utc_datetime
      add :expires_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:api_tokens, [:token_hash], name: :api_tokens__token_hash__uk)
    create index(:api_tokens, [:owner_id])
  end
end
