defmodule Athena.Learning.Enrollment do
  @moduledoc """
  Manages course access for students.

  Supports both individual student enrollments and cohort-based enrollments
  using a polymorphic association pattern.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Athena.Learning.Cohort

  @type t :: %__MODULE__{}

  use Gettext, backend: AthenaWeb.Gettext

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @derive {
    Flop.Schema,
    filterable: [:status, :inserted_at],
    sortable: [:status, :inserted_at],
    default_limit: 10,
    default_order: %{
      order_by: [:inserted_at],
      order_directions: [:desc]
    }
  }

  schema "enrollments" do
    field :status, Ecto.Enum, values: [:active, :completed, :dropped], default: :active

    field :course_id, :binary_id
    field :account_id, :binary_id
    belongs_to :cohort, Cohort

    field :course, :any, virtual: true
    field :account, :any, virtual: true

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for course enrollment.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(enrollment, attrs) do
    enrollment
    |> cast(attrs, [:status, :course_id, :account_id, :cohort_id])
    |> validate_required([:status, :course_id])
    |> validate_target()
    |> unique_constraint([:course_id, :account_id])
    |> unique_constraint([:course_id, :cohort_id])
    |> check_constraint(:enrollments, name: :enrollment_target_check)
  end

  @doc false
  defp validate_target(changeset) do
    account_id = get_field(changeset, :account_id)
    cohort_id = get_field(changeset, :cohort_id)

    cond do
      is_nil(account_id) and is_nil(cohort_id) ->
        add_error(
          changeset,
          :account_id,
          dgettext_noop("errors", "must have either account_id or cohort_id")
        )

      not is_nil(account_id) and not is_nil(cohort_id) ->
        add_error(
          changeset,
          :account_id,
          dgettext_noop("errors", "cannot have both account_id and cohort_id")
        )

      true ->
        changeset
    end
  end
end
