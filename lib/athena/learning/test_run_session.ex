defmodule Athena.Learning.TestRunSession do
  @moduledoc """
  Tracks one instructor "test run" preview session (see `Athena.Learning.TestRuns`).

  Authoritative index of what `TestRuns.cleanup/1` must purge for a given
  ephemeral account: `enrollments`, `block_progresses`, `submissions`, and
  the gamification tables all store `account_id` as a bare `:binary_id` with
  no FK to `accounts`, so nothing cascades automatically when the ephemeral
  account is deleted.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "test_run_sessions" do
    field :course_id, :binary_id
    field :section_id, :binary_id
    field :instructor_account_id, :binary_id
    field :ephemeral_account_id, :binary_id
    field :status, Ecto.Enum, values: [:active, :cleaned_up], default: :active
    field :expires_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :course_id,
      :section_id,
      :instructor_account_id,
      :ephemeral_account_id,
      :status,
      :expires_at
    ])
    |> validate_required([
      :course_id,
      :section_id,
      :instructor_account_id,
      :ephemeral_account_id,
      :expires_at
    ])
    |> unique_constraint(:ephemeral_account_id)
  end
end
