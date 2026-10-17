defmodule Athena.Surveys.QuestionTypes.OpenText do
  @moduledoc """
  Config for an `:open_text` question - free-text answer.

  `multiline` only picks the widget (textarea vs single-line input);
  `max_length` is enforced when the answer is saved, not just in the browser.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    field :multiline, :boolean, default: true
    field :max_length, :integer, default: 2000
  end

  @type t :: %__MODULE__{multiline: boolean(), max_length: integer()}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:multiline, :max_length])
    |> validate_required([:max_length])
    |> validate_number(:max_length, greater_than: 0, less_than_or_equal_to: 10_000)
  end
end
