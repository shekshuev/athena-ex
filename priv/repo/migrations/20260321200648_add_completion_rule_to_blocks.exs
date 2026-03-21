defmodule Athena.Repo.Migrations.AddCompletionRuleToBlocks do
  use Ecto.Migration

  def change do
    alter table(:blocks) do
      add :completion_rule, :map, default: %{"type" => "none"}
    end
  end
end
