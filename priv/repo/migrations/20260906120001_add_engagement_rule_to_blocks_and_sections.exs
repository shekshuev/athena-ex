defmodule Athena.Repo.Migrations.AddEngagementRuleToBlocksAndSections do
  use Ecto.Migration

  def change do
    alter table(:blocks) do
      add :engagement_rule, :map, default: %{}
    end

    alter table(:sections) do
      add :engagement_rule, :map, default: %{}
    end
  end
end
