defmodule Athena.Content.Block do
  @moduledoc """
  Represents a piece of content inside a section.

  Blocks are the smallest unit of learning material (e.g., text, code snippet, video).
  They use a JSONB `content` field to flexibly store data specific to their `type`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Athena.Content.{
    QuizQuestion,
    QuizExam,
    TicketExam,
    Section,
    AccessRules,
    CompletionRule,
    CodeChallenge,
    FileAssignment
  }

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @derive {
    Flop.Schema,
    filterable: [:type, :section_id],
    sortable: [:order, :inserted_at],
    default_limit: 10,
    default_order: %{
      order_by: [:order],
      order_directions: [:asc]
    }
  }

  @derive {Jason.Encoder, only: [:id, :type, :content]}

  schema "blocks" do
    field :type, Ecto.Enum,
      values:
        ~w(text code quiz_question quiz_exam ticket_exam video image attachment file_assignment)a

    field :content, :map, default: %{}
    field :order, :integer, default: 0

    field :visibility, Ecto.Enum,
      values: ~w(enrolled restricted hidden inherit)a,
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
    |> build_embed_changeset(content_map)
    |> apply_embed_changes(changeset)
  end

  @doc false
  defp build_embed_changeset(:quiz_question, content_map),
    do: QuizQuestion.changeset(%QuizQuestion{}, content_map)

  defp build_embed_changeset(:quiz_exam, content_map),
    do: QuizExam.changeset(%QuizExam{}, content_map)

  defp build_embed_changeset(:ticket_exam, content_map),
    do: TicketExam.changeset(%TicketExam{}, content_map)

  defp build_embed_changeset(:code, content_map),
    do: CodeChallenge.changeset(struct(CodeChallenge), content_map)

  defp build_embed_changeset(:file_assignment, content_map),
    do: FileAssignment.changeset(%FileAssignment{}, content_map)

  defp build_embed_changeset(_, _), do: nil

  @doc false
  defp apply_embed_changes(nil, changeset), do: changeset

  defp apply_embed_changes(%Ecto.Changeset{valid?: true} = embed_cs, changeset) do
    pure_string_map =
      embed_cs
      |> Ecto.Changeset.apply_changes()
      |> Jason.encode!()
      |> Jason.decode!()

    put_change(changeset, :content, pure_string_map)
  end

  defp apply_embed_changes(%Ecto.Changeset{valid?: false} = embed_cs, changeset) do
    Enum.reduce(embed_cs.errors, changeset, fn {field, {msg, opts}}, acc ->
      add_error(acc, :content, "#{field}: #{msg}", opts)
    end)
  end
end
