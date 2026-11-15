defmodule Athena.Repo.Migrations.AddInteractionModeToSectionsAndBlocks do
  use Ecto.Migration

  def change do
    for table <- [:sections, :blocks] do
      alter table(table) do
        add :interaction_mode, :string, null: false, default: "inherit"
      end

      create constraint(table, "#{table}_interaction_mode_check",
               check: "interaction_mode IN ('inherit', 'interactive', 'readonly')"
             )
    end
  end
end
