defmodule Athena.Content.Character do
  @moduledoc """
  Represents a reusable storytelling character (name + avatar) that a teacher
  can use across dialogue blocks in any of their courses.

  References the avatar via a loose `avatar_file_id` (into `media_files`)
  rather than a hard `belongs_to`, matching the loose-coupling style used by
  `Athena.Media.File`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @derive {
    Flop.Schema,
    filterable: [:name, :owner_id],
    sortable: [:name, :inserted_at],
    default_limit: 20,
    default_order: %{
      order_by: [:name],
      order_directions: [:asc]
    }
  }

  schema "characters" do
    field :name, :string
    field :color, :string
    field :avatar_file_id, :binary_id
    field :owner_id, :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(character, attrs) do
    character
    |> cast(attrs, [:name, :color, :avatar_file_id, :owner_id])
    |> validate_required([:name, :owner_id])
    |> validate_length(:name, min: 1, max: 100)
    |> foreign_key_constraint(:avatar_file_id)
  end
end
