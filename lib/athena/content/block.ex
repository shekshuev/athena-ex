defmodule Athena.Content.Block do
  @moduledoc """
  Represents a piece of content inside a section.

  Blocks are the smallest unit of learning material (e.g., text, code snippet, video).
  They use a JSONB `content` field to flexibly store data specific to their `type`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @derive {
    Flop.Schema,
    filterable: [:type, :section_id],
    sortable: [:order, :inserted_at],
    default_limit: 50,
    default_order: %{
      order_by: [:order],
      order_directions: [:asc]
    }
  }

  schema "blocks" do
    field :type, Ecto.Enum, values: ~w(text code quiz_question quiz_exam video image attachment)a

    field :content, :map, default: %{}
    field :order, :integer, default: 0

    field :visibility, Ecto.Enum,
      values: ~w(public enrolled restricted hidden inherit)a,
      default: :enrolled

    embeds_one :access_rules, Athena.Content.AccessRules, on_replace: :update

    belongs_to :section, Athena.Content.Section

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for block creation or update.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(block, attrs) do
    block
    |> cast(attrs, [:type, :content, :order, :section_id, :visibility])
    |> cast_embed(:access_rules, with: &Athena.Content.AccessRules.changeset/2)
    |> validate_required([:type, :content, :section_id, :visibility])
    |> foreign_key_constraint(:section_id)
  end
end
