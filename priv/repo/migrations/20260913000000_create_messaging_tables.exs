defmodule Athena.Repo.Migrations.CreateMessagingTables do
  use Ecto.Migration

  def change do
    create table(:conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # "direct" | "cohort"
      add :kind, :string, null: false
      # soft ref to Learning.Cohort; null for :direct
      add :cohort_id, :binary_id
      # canonical "min_id:max_id" for :direct; null for :cohort
      add :direct_key, :string
      # denormalized, for list ordering (usec precision: compared against
      # message.inserted_at, which is also usec-precision)
      add :last_message_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:conversations, [:direct_key],
             where: "kind = 'direct'",
             name: :conversations__direct_key__uk
           )

    create unique_index(:conversations, [:cohort_id],
             where: "kind = 'cohort'",
             name: :conversations__cohort_id__uk
           )

    create index(:conversations, [:kind])

    create table(:conversation_participants, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id, references(:conversations, on_delete: :delete_all, type: :binary_id),
        null: false

      # soft ref to Identity.Account
      add :account_id, :binary_id, null: false
      # null = never read; usec precision, compared against message.inserted_at
      add :last_read_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:conversation_participants, [:conversation_id, :account_id],
             name: :conversation_participants__conversation_id_account_id__uk
           )

    create index(:conversation_participants, [:account_id])

    create table(:messages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id, references(:conversations, on_delete: :delete_all, type: :binary_id),
        null: false

      # soft ref to Identity.Account (sender)
      add :account_id, :binary_id, null: false
      # discriminator for future attachment/object types
      add :kind, :string, null: false, default: "text"
      add :body, :text, null: false
      add :edited_at, :utc_datetime_usec
      add :deleted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:messages, [:conversation_id, :inserted_at])
    create index(:messages, [:account_id])

    create table(:message_mentions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :message_id, references(:messages, on_delete: :delete_all, type: :binary_id),
        null: false

      # soft ref to Identity.Account (mentioned user)
      add :account_id, :binary_id, null: false
      # e.g. "@Jane Doe" — for render-time highlighting
      add :matched_text, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:message_mentions, [:message_id, :account_id],
             name: :message_mentions__message_id_account_id__uk
           )

    create index(:message_mentions, [:account_id])
  end
end
