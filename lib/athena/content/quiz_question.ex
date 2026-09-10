defmodule Athena.Content.QuizQuestion.Option do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    field :id, :binary_id
    field :text, :map
    field :is_correct, :boolean, default: false
    field :explanation, :string
  end

  @type t :: %__MODULE__{
          id: binary() | nil,
          text: map() | nil,
          is_correct: boolean(),
          explanation: String.t() | nil
        }

  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:id, :text, :is_correct, :explanation])
    |> validate_required([:id, :text])
  end
end

defmodule Athena.Content.QuizQuestion.Pair do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    field :id, :binary_id
    field :left, :map
    field :right, :map
  end

  @type t :: %__MODULE__{
          id: binary() | nil,
          left: map() | nil,
          right: map() | nil
        }

  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:id, :left, :right])
    |> validate_required([:id, :left, :right])
  end
end

defmodule Athena.Content.QuizQuestion do
  @moduledoc """
  Embedded schema for the `content` field of a `:quiz_question` block.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Athena.Content.QuizQuestion.Option
  alias Athena.Content.QuizQuestion.Pair

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    field :question_type, Ecto.Enum, values: [:single, :multiple, :exact_match, :open, :matching]
    field :answer_type, Ecto.Enum, values: [:plain_text, :rich_text]
    field :body, :map
    field :correct_answer, :string
    field :case_sensitive, :boolean, default: false
    field :max_attempts, :integer
    embeds_many :options, Option
    embeds_many :pairs, Pair

    field :general_explanation, :string
  end

  @type t :: %__MODULE__{
          question_type: :single | :multiple | :exact_match | :open | :matching | nil,
          answer_type: :plain_text | :rich_text,
          body: map() | nil,
          correct_answer: String.t() | nil,
          case_sensitive: boolean(),
          options: [Option.t()] | nil,
          pairs: [Pair.t()] | nil,
          max_attempts: integer() | nil,
          general_explanation: String.t() | nil
        }

  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [
      :question_type,
      :answer_type,
      :body,
      :correct_answer,
      :case_sensitive,
      :general_explanation,
      :max_attempts
    ])
    |> cast_embed(:options, with: &Option.changeset/2)
    |> cast_embed(:pairs, with: &Pair.changeset/2)
    |> validate_required([:question_type, :body])
    |> validate_number(:max_attempts, greater_than: 0)
    |> validate_type_logic()
  end

  defp validate_type_logic(changeset) do
    case get_field(changeset, :question_type) do
      :exact_match ->
        validate_required(changeset, [:correct_answer])

      :matching ->
        validate_min_pairs(changeset)

      _ ->
        changeset
    end
  end

  defp validate_min_pairs(changeset) do
    if length(get_field(changeset, :pairs) || []) < 2 do
      add_error(changeset, :pairs, "must have at least 2 pairs")
    else
      changeset
    end
  end
end
