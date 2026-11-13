defmodule Athena.Repo.Migrations.AddBlockSearchIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:blocks, [:search_due_at],
             name: :blocks__search_due_at__idx,
             where: "search_due_at IS NOT NULL",
             concurrently: true
           )

    create index(:blocks, ["search_text gin_trgm_ops"],
             name: :blocks__search_text_trgm__idx,
             using: :gin,
             concurrently: true
           )
  end
end
