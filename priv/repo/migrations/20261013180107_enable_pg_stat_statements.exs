defmodule Athena.Repo.Migrations.EnablePgStatStatements do
  @moduledoc """
  Enables `pg_stat_statements` for query diagnostics (see
  `scripts/db_diagnostics.sql`). The view only collects data when the server
  preloads the library (`shared_preload_libraries`, set for the prod
  Postgres in `docker-compose.prod.yml`). Skipped where the extension isn't
  installed, so local databases without contrib still migrate.
  """
  use Ecto.Migration

  def up do
    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_stat_statements') THEN
        CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
      END IF;
    END
    $$
    """
  end

  def down do
    execute "DROP EXTENSION IF EXISTS pg_stat_statements"
  end
end
