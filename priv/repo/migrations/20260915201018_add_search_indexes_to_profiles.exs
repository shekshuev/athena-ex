defmodule Athena.Repo.Migrations.AddSearchIndexesToProfiles do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm", "DROP EXTENSION IF EXISTS pg_trgm"

    execute(
      "CREATE INDEX profiles__first_name_trgm__idx ON profiles USING gin (first_name gin_trgm_ops)",
      "DROP INDEX profiles__first_name_trgm__idx"
    )

    execute(
      "CREATE INDEX profiles__last_name_trgm__idx ON profiles USING gin (last_name gin_trgm_ops)",
      "DROP INDEX profiles__last_name_trgm__idx"
    )

    execute(
      "CREATE INDEX profiles__patronymic_trgm__idx ON profiles USING gin (patronymic gin_trgm_ops)",
      "DROP INDEX profiles__patronymic_trgm__idx"
    )
  end
end
