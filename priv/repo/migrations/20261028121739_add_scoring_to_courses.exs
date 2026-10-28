defmodule Athena.Repo.Migrations.AddScoringToCourses do
  use Ecto.Migration

  # No default on purpose: NULL has to stay NULL so
  # `Athena.Content.ScoringRules.resolve/1` is the single place that says
  # what an unconfigured competition scores like. Writing defaults into
  # every existing course would turn silence into an explicit choice, and
  # standard courses have no ranking at all.
  def change do
    alter table(:courses) do
      add :scoring, :map
    end
  end
end
