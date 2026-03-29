defmodule Athena.Content.Block do
  @moduledoc """
  Represents a piece of content inside a section.

  Blocks are the smallest unit of learning material (e.g., text, code snippet, video).
  They use a JSONB `content` field to flexibly store data specific to their `type`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Athena.Content.{QuizQuestion, QuizExam, Section, AccessRules, CompletionRule}

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

    embeds_one :access_rules, AccessRules, on_replace: :update

    embeds_one :completion_rule, CompletionRule, on_replace: :update

    belongs_to :section, Section

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for block creation or update.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(block, attrs) do
    block
    |> cast(attrs, [:type, :content, :order, :section_id, :visibility])
    |> cast_embed(:access_rules, with: &AccessRules.changeset/2)
    |> cast_embed(:completion_rule, with: &CompletionRule.changeset/2)
    |> validate_required([:type, :content, :section_id, :visibility])
    |> foreign_key_constraint(:section_id)
    |> validate_content_by_type()
  end

  @doc false
  defp validate_content_by_type(changeset) do
    type = get_field(changeset, :type)
    content_map = get_field(changeset, :content) || %{}

    type
    |> case do
      :quiz_question -> QuizQuestion.changeset(%QuizQuestion{}, content_map)
      :quiz_exam -> QuizExam.changeset(%QuizExam{}, content_map)
      _ -> nil
    end
    |> case do
      nil ->
        changeset

      %Ecto.Changeset{valid?: true} = embed_cs ->
        put_change(
          changeset,
          :content,
          Ecto.Changeset.apply_changes(embed_cs) |> Map.from_struct()
        )

      %Ecto.Changeset{valid?: false} = embed_cs ->
        Enum.reduce(embed_cs.errors, changeset, fn {field, {msg, opts}}, acc ->
          add_error(acc, :content, "#{field}: #{msg}", opts)
        end)
    end
  end
end
