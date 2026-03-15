defmodule Athena.Media.File do
  @moduledoc """
  Represents metadata for a file stored in S3/MinIO.

  This schema belongs strictly to the Media context. It references the owner
  via a simple `owner_id` value object to maintain loose coupling.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @derive {
    Flop.Schema,
    filterable: [:original_name, :mime_type, :context, :owner_id],
    sortable: [:original_name, :size, :inserted_at],
    default_limit: 20,
    default_order: %{
      order_by: [:inserted_at],
      order_directions: [:desc]
    }
  }

  schema "media_files" do
    field :bucket, :string
    field :key, :string
    field :original_name, :string
    field :mime_type, :string
    field :size, :integer

    field :context, Ecto.Enum, values: [:personal, :avatar, :course_material, :submission]

    field :owner_id, :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(file, attrs) do
    file
    |> cast(attrs, [:bucket, :key, :original_name, :mime_type, :size, :context, :owner_id])
    |> validate_required([:bucket, :key, :original_name, :mime_type, :size, :context, :owner_id])
    |> validate_number(:size, greater_than: 0)
    |> unique_constraint([:bucket, :key])
  end
end
