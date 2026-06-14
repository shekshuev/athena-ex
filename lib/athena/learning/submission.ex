defmodule Athena.Learning.Submission do
  @moduledoc """
  Represents a student's answer to a specific content block.
  Expanded to support real-time code execution results.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @execution_statuses ~w(
    draft pending processing graded needs_review rejected
    accepted wrong_answer time_limit_exceeded
    memory_limit_exceeded runtime_error compilation_error system_error
  )a

  @derive {
    Flop.Schema,
    filterable: ~w(status score account_id cohort_id inserted_at has_cheats block_id)a,
    sortable: ~w(inserted_at status score)a,
    default_limit: 10,
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

    field :status, Ecto.Enum, values: @execution_statuses, default: :pending

    field :score, :integer, default: 0
    field :feedback, :string

    field :expires_at, :utc_datetime

    field :account_id, :binary_id
    field :block_id, :binary_id
    field :cohort_id, :binary_id

    belongs_to :parent_submission, Athena.Learning.Submission
    has_many :child_submissions, Athena.Learning.Submission, foreign_key: :parent_submission_id
    timestamps(type: :utc_datetime)
  end

  @type status ::
          :draft
          | :pending
          | :processing
          | :graded
          | :needs_review
          | :rejected
          | :accepted
          | :wrong_answer
          | :time_limit_exceeded
          | :memory_limit_exceeded
          | :runtime_error
          | :compilation_error
          | :system_error

  @type t :: %__MODULE__{
          id: binary() | nil,
          content: map(),
          status: status(),
          score: integer(),
          feedback: String.t() | nil,
          expires_at: DateTime.t() | NaiveDateTime.t() | nil,
          account_id: binary() | nil,
          cohort_id: binary() | nil,
          block_id: binary() | nil,
          parent_submission: t(),
          child_submissions: [t()],
          inserted_at: DateTime.t() | NaiveDateTime.t() | nil,
          updated_at: DateTime.t() | NaiveDateTime.t() | nil
        }

  @doc false
  def changeset(submission, attrs) do
    submission
    |> cast(attrs, [
      :content,
      :status,
      :score,
      :feedback,
      :account_id,
      :block_id,
      :cohort_id,
      :parent_submission_id,
      :expires_at
    ])
    |> validate_required([:status, :account_id, :block_id])
    |> validate_number(:score, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_expires_at()
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

  @doc false
  defp validate_expires_at(changeset) do
    parent_id = get_field(changeset, :parent_submission_id)
    expires_at = get_field(changeset, :expires_at)

    changeset =
      if parent_id && expires_at do
        add_error(changeset, :expires_at, "Child submissions cannot have their own expires_at")
      else
        changeset
      end

    validate_required_if_parent_missing(changeset)
  end

  @doc false
  defp validate_required_if_parent_missing(changeset), do: changeset
end
