defmodule Athena.Learning.BlockProgress do
  @moduledoc """
  Unified schema for tracking student progress and storing submission results.

  Handles everything from simple button clicks to auto-graded code execution,
  storing scores, student payloads, and instructor feedback.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "block_progresses" do
    field :status, Ecto.Enum,
      values: ~w(completed processing pending_review failed)a,
      default: :completed

    field :score, :integer
    field :payload, :map, default: %{}
    field :feedback, :map, default: %{}

    field :account_id, :binary_id
    field :block_id, :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for tracking progress or storing a submission result.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(progress, attrs) do
    progress
    |> cast(attrs, [:status, :score, :payload, :feedback, :account_id, :block_id])
    |> validate_required([:status, :account_id, :block_id])
    |> validate_number(:score, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> unique_constraint([:account_id, :block_id])
  end
end
