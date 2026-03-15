defmodule Athena.Content.LibraryBlock do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}

  schema "library_blocks" do
    field :title, :string
    field :type, Ecto.Enum, values: [:text, :code]
    field :content, :map, default: %{}
    field :tags, {:array, :string}, default: []
    field :owner_id, :binary_id

    timestamps(type: :utc_datetime)
  end

  def changeset(library_block, attrs) do
    library_block
    |> cast(attrs, [:title, :type, :content, :tags, :owner_id])
    |> validate_required([:title, :type, :content, :owner_id])
  end
end
