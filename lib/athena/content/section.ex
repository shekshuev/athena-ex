defmodule Athena.Content.Section do
  @moduledoc """
  Represents a section or folder in a course hierarchy.

  Sections are built using PostgreSQL's `ltree` extension to support infinite 
  nesting and rapid querying of entire course sub-trees. A section can act as 
  a module, a chapter, or an individual lesson containing content blocks.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @derive {
    Flop.Schema,
    filterable: [:title, :course_id, :parent_id, :owner_id],
    sortable: [:title, :order, :inserted_at],
    default_limit: 50,
    default_order: %{
      order_by: [:order, :inserted_at],
      order_directions: [:asc, :desc]
    }
  }

  schema "sections" do
    field :title, :string
    field :order, :integer, default: 0

    field :path, EctoLtree.LabelTree

    field :owner_id, :binary_id

    belongs_to :course, Athena.Content.Course
    belongs_to :parent, Athena.Content.Section
    has_many :blocks, Athena.Content.Block

    field :children, {:array, :any}, virtual: true, default: []

    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(section, attrs) do
    section
    |> cast(attrs, [:id, :title, :order, :path, :course_id, :parent_id, :owner_id])
    |> validate_required([:id, :title, :path, :course_id, :owner_id])
    |> validate_length(:title, min: 1, max: 255)
    |> foreign_key_constraint(:course_id)
    |> foreign_key_constraint(:parent_id)
  end

  @doc """
  Converts a standard UUID into an ltree-compatible format (replacing dashes with underscores).
  """
  @spec uuid_to_ltree(String.t()) :: String.t()
  def uuid_to_ltree(uuid) when is_binary(uuid) do
    String.replace(uuid, "-", "_")
  end

  @doc """
  Generates the ltree path for the section.
  """
  @spec build_path(String.t(), EctoLtree.LabelTree.t() | String.t() | nil) :: String.t()
  def build_path(section_id, nil = _parent_path) do
    uuid_to_ltree(section_id)
  end

  def build_path(section_id, %EctoLtree.LabelTree{labels: parent_labels}) do
    parent_path_str = Enum.join(parent_labels, ".")
    "#{parent_path_str}.#{uuid_to_ltree(section_id)}"
  end

  def build_path(section_id, parent_path_str) when is_binary(parent_path_str) do
    "#{parent_path_str}.#{uuid_to_ltree(section_id)}"
  end
end
