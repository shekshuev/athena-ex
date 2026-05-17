defmodule Athena.Content.CodeChallenge do
  @moduledoc """
  Embedded schema for blocks of type `:code`.
  Stores language settings, execution limits, and test cases.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Athena.Content.TestCase

  @derive {Jason.Encoder,
           only: [
             :language,
             :time_limit,
             :memory_limit,
             :initial_code,
             :solution_code,
             :test_cases,
             :body,
             :max_attempts
           ]}

  @type t :: %__MODULE__{
          language: String.t(),
          time_limit: float(),
          memory_limit: integer(),
          max_attempts: integer() | nil,
          initial_code: String.t(),
          solution_code: String.t(),
          body: map(),
          test_cases: [TestCase.t()]
        }

  @primary_key false
  embedded_schema do
    field :language, :string, default: "python3"
    field :time_limit, :float, default: 1.0
    field :memory_limit, :integer, default: 65_536
    field :max_attempts, :integer

    field :initial_code, :string, default: ""
    field :solution_code, :string, default: ""
    field :body, :map, default: %{}

    embeds_many :test_cases, TestCase, on_replace: :delete
  end

  @doc """
  Validates and applies changes to a `CodeChallenge` struct.
  Enforces presence and safe boundaries for execution limits.
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [
      :language,
      :time_limit,
      :memory_limit,
      :initial_code,
      :solution_code,
      :body,
      :max_attempts
    ])
    |> cast_embed(:test_cases, with: &TestCase.changeset/2)
    |> validate_required([:language, :time_limit, :memory_limit])
    |> validate_number(:time_limit, greater_than: 0.0, less_than_or_equal_to: 15.0)
    |> validate_number(:memory_limit, greater_than: 16_384, less_than_or_equal_to: 524_288)
    |> validate_number(:max_attempts, greater_than: 0)
  end
end
