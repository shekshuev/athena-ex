defmodule Athena.Repo.Migrations.AddTagsColumnToLibraryBlocks do
  use Ecto.Migration

  def change do
    alter table(:library_blocks) do
      add :tags, {:array, :string}, default: []
    end

    create index(:library_blocks, [:tags], using: "GIN")
  end
end
