defmodule Athena.Repo.Migrations.AddSearchIndexesToAccountsAndInstructors do
  use Ecto.Migration

  @moduledoc """
  Mirrors `20260915201018_add_search_indexes_to_profiles.exs`: `accounts.login`
  and `instructors.title` are both matched with `ilike "%term%"` (admin Users
  search, the grading screen's "Student" search, and the "assign instructors"
  autocomplete) - a leading wildcard a plain btree index can't accelerate.
  `pg_trgm` is already enabled by that earlier migration.
  """

  def change do
    execute(
      "CREATE INDEX accounts__login_trgm__idx ON accounts USING gin (login gin_trgm_ops)",
      "DROP INDEX accounts__login_trgm__idx"
    )

    execute(
      "CREATE INDEX instructors__title_trgm__idx ON instructors USING gin (title gin_trgm_ops)",
      "DROP INDEX instructors__title_trgm__idx"
    )
  end
end
