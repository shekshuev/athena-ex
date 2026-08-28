defmodule Athena.Content.Course do
  @moduledoc """
  Represents a course container.

  This schema is the root aggregate for the Content context. It holds metadata
  about the course and establishes a relationship with its hierarchical sections.
  """

  use Ecto.Schema
  import Ecto.Changeset
  alias Athena.Content.Section

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @derive {
    Flop.Schema,
    filterable: [:title, :status, :owner_id, :code],
    sortable: [:title, :status, :code, :inserted_at],
    default_limit: 10,
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
    field :deleted_at, :utc_datetime
    field :type, Ecto.Enum, values: [:standard, :competition], default: :standard
    field :is_public, :boolean, default: false
    field :code, :string

    has_many :sections, Section
    has_many :shares, Athena.Content.CourseShare, on_delete: :delete_all

    many_to_many :library_blocks, Athena.Content.LibraryBlock,
      join_through: Athena.Content.CourseLibraryBlock

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for course creation or update based on the `attrs`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(course, attrs) do
    course
    |> cast(attrs, [
      :title,
      :description,
      :status,
      :type,
      :owner_id,
      :deleted_at,
      :is_public,
      :code
    ])
    |> validate_required([:title, :status, :type, :owner_id])
    |> validate_length(:title, min: 3, max: 255)
    |> unique_constraint(:title, name: :courses_title_index)
    |> validate_code()
  end

  defp validate_code(changeset) do
    code = get_field(changeset, :code)

    case code do
      nil ->
        changeset

      "" ->
        put_change(changeset, :code, nil)

      value ->
        if Regex.match?(~r/^[a-zA-Z0-9_\-\.\/+]+$/, value) and byte_size(value) <= 50 do
          changeset
          |> unique_constraint(:code, name: :courses_code_index)
        else
          put_change(changeset, :code, nil)

          add_error(
            changeset,
            :code,
            "must contain only letters, digits, hyphens, underscores, dots, slashes, or plus signs (max 50 characters)"
          )
        end
    end
  end
end
