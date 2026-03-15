defmodule Athena.Content.Course do
  @moduledoc """
  Represents a course container.

  This schema is the root aggregate for the Content context. It holds metadata
  about the course and establishes a relationship with its hierarchical sections.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @derive {
    Flop.Schema,
    filterable: [:title, :status, :owner_id],
    sortable: [:title, :status, :inserted_at],
    default_limit: 20,
    default_order: %{
      order_by: [:inserted_at],
      order_directions: [:desc]
    }
  }

  schema "courses" do
    field :title, :string
    field :description, :string
    field :status, Ecto.Enum, values: [:draft, :published, :archived], default: :draft

    field :owner_id, :binary_id

    has_many :sections, Athena.Content.Section

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for course creation or update based on the `attrs`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(course, attrs) do
    course
    |> cast(attrs, [:title, :description, :status, :owner_id])
    |> validate_required([:title, :status, :owner_id])
    |> validate_length(:title, min: 3, max: 255)
    |> unique_constraint(:title, name: :courses_title_index)
  end
end
