defmodule Athena.Content.LibraryBlock do
  @moduledoc """
  Represents a reusable content template in the library.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Athena.Content.{QuizQuestion, QuizExam, TicketExam, CodeChallenge, FileAssignment}

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}

  @derive {
    Flop.Schema,
    filterable: [:title, :type, :tags, :owner_id],
    sortable: [:title, :type, :inserted_at],
    default_limit: 10,
    default_order: %{
      order_by: [:inserted_at],
      order_directions: [:desc]
    }
  }

  schema "library_blocks" do
    field :title, :string

    field :type, Ecto.Enum,
      values:
        ~w(text code quiz_question quiz_exam ticket_exam video image attachment file_assignment)a

    field :content, :map, default: %{}
    field :tags, {:array, :string}, default: []
    field :owner_id, :binary_id
    field :is_public, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for library block creation or update.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(library_block, attrs) do
    library_block
    |> cast(attrs, [:title, :type, :content, :tags, :owner_id, :is_public])
    |> validate_required([:title, :type, :content, :owner_id])
    |> validate_length(:title, min: 3, max: 255)
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
    do: QuizQuestion.changeset(struct(QuizQuestion), content_map)

  defp build_embed_changeset(:quiz_exam, content_map),
    do: QuizExam.changeset(struct(QuizExam), content_map)

  defp build_embed_changeset(:ticket_exam, content_map),
    do: TicketExam.changeset(%TicketExam{}, content_map)

  defp build_embed_changeset(:code, content_map),
    do: CodeChallenge.changeset(struct(CodeChallenge), content_map)

  defp build_embed_changeset(:file_assignment, content_map),
    do: FileAssignment.changeset(struct(FileAssignment), content_map)

  defp build_embed_changeset(_, _), do: nil

  @doc false
  defp apply_embed_changes(nil, changeset), do: changeset

  defp apply_embed_changes(%Ecto.Changeset{valid?: true} = embed_cs, changeset) do
    put_change(
      changeset,
      :content,
      Ecto.Changeset.apply_changes(embed_cs) |> Map.from_struct()
    )
  end

  defp apply_embed_changes(%Ecto.Changeset{valid?: false} = embed_cs, changeset) do
    Enum.reduce(embed_cs.errors, changeset, fn {field, {msg, opts}}, acc ->
      add_error(acc, :content, "#{field}: #{msg}", opts)
    end)
  end
end
