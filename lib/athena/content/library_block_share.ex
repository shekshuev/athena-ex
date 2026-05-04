defmodule Athena.Content.LibraryBlockShare do
  @moduledoc "Pivot table connecting LibraryBlocks to Identity.Accounts softly (no hard FK)."

  use Ecto.Schema
  import Ecto.Changeset
  alias Athena.Content.LibraryBlock

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "library_block_shares" do
    belongs_to :library_block, LibraryBlock
    field :account_id, Ecto.UUID
    field :role, Ecto.Enum, values: [:reader, :writer], default: :reader

    timestamps(type: :utc_datetime)
  end

  def changeset(share, attrs) do
    share
    |> cast(attrs, [:library_block_id, :account_id, :role])
    |> validate_required([:library_block_id, :account_id])
    |> unique_constraint([:library_block_id, :account_id])
  end
end
