defmodule Athena.Content.QuizQuestion.Option do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    field :id, :binary_id
    field :text, :string
    field :is_correct, :boolean, default: false
    field :explanation, :string
  end

  @type t :: %__MODULE__{
          id: binary() | nil,
          text: String.t() | nil,
          is_correct: boolean(),
          explanation: String.t() | nil
        }

  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:id, :text, :is_correct, :explanation])
    |> validate_required([:id, :text])
  end
end

defmodule Athena.Content.QuizQuestion do
  @moduledoc """
  Embedded schema for the `content` field of a `:quiz_question` block.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Athena.Content.QuizQuestion.Option

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    field :question_type, Ecto.Enum, values: [:single, :multiple, :exact_match, :open]
    field :body, :map
    field :correct_answer, :string
    field :case_sensitive, :boolean, default: false

    embeds_many :options, Option

    field :general_explanation, :string
  end

  @type t :: %__MODULE__{
          question_type: :single | :multiple | :exact_match | :open | nil,
          body: map() | nil,
          correct_answer: String.t() | nil,
          case_sensitive: boolean(),
          options: [Option.t()] | nil,
          general_explanation: String.t() | nil
        }

  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:question_type, :body, :correct_answer, :case_sensitive, :general_explanation])
    |> cast_embed(:options, with: &Option.changeset/2)
    |> validate_required([:question_type, :body])
    |> validate_type_logic()
  end

  defp validate_type_logic(changeset) do
    case get_field(changeset, :question_type) do
      :exact_match ->
        validate_required(changeset, [:correct_answer])

      _ ->
        changeset
    end
  end
end
