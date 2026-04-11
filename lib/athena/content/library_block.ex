defmodule Athena.Content.LibraryBlock do
  @moduledoc """
  Represents a reusable content template in the library.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Athena.Content.{QuizQuestion, QuizExam}

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}

  @derive {
    Flop.Schema,
    filterable: [:title, :type, :tags, :owner_id],
    sortable: [:title, :type, :inserted_at],
    default_limit: 20,
    default_order: %{
      order_by: [:inserted_at],
      order_directions: [:desc]
    }
  }

  schema "library_blocks" do
    field :title, :string

    field :type, Ecto.Enum,
      values: [:text, :code, :quiz_question, :quiz_exam, :video, :image, :attachment]

    field :content, :map, default: %{}
    field :tags, {:array, :string}, default: []
    field :owner_id, :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for library block creation or update.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(library_block, attrs) do
    library_block
    |> cast(attrs, [:title, :type, :content, :tags, :owner_id])
    |> validate_required([:title, :type, :content, :owner_id])
    |> validate_length(:title, min: 3, max: 255)
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
