defmodule Athena.Learning.Submission do
  @moduledoc """
  Represents a student's answer to a specific content block.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @derive {
    Flop.Schema,
    filterable: [:status, :score, :account_id, :cohort_id, :inserted_at, :has_cheats],
    sortable: [:inserted_at, :status, :score],
    default_order: %{order_by: [:inserted_at], order_directions: [:desc]},
    custom_fields: [
      has_cheats: [
        filter: {__MODULE__, :filter_has_cheats, []},
        ecto_type: :boolean
      ]
    ]
  }

  schema "submissions" do
    field :content, :map, default: %{}

    field :status, Ecto.Enum,
      values: [:pending, :processing, :graded, :needs_review],
      default: :pending

    field :score, :integer, default: 0
    field :feedback, :string

    field :account_id, :binary_id
    field :block_id, :binary_id
    field :cohort_id, :binary_id

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          id: binary() | nil,
          content: map(),
          status: :pending | :processing | :graded | :needs_review,
          score: integer(),
          feedback: String.t() | nil,
          account_id: binary() | nil,
          cohort_id: binary() | nil,
          block_id: binary() | nil,
          inserted_at: DateTime.t() | NaiveDateTime.t() | nil,
          updated_at: DateTime.t() | NaiveDateTime.t() | nil
        }

  @doc false
  def changeset(submission, attrs) do
    submission
    |> cast(attrs, [:content, :status, :score, :feedback, :account_id, :block_id, :cohort_id])
    |> validate_required([:status, :account_id, :block_id])
    |> validate_number(:score, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
  end

  @doc false
  def filter_has_cheats(query, %Flop.Filter{value: value}, _opts) do
    if value in [true, "true"] do
      import Ecto.Query
      where(query, [s], fragment("(?.content->>'cheat_count')::int > 0", s))
    else
      query
    end
  end
end
