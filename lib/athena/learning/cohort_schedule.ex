defmodule Athena.Learning.CohortSchedule do
  @moduledoc """
  Represents time-based overrides for specific cohorts accessing content.
  Links a Cohort to a Section or Block in the Content context.
  """
  use Ecto.Schema
  import Ecto.Changeset
  use Gettext, backend: AthenaWeb.Gettext

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cohort_schedules" do
    belongs_to :cohort, Athena.Learning.Cohort

    field :course_id, :binary_id
    field :resource_type, Ecto.Enum, values: ~w(block section)a
    field :resource_id, :binary_id

    field :unlock_at, :utc_datetime
    field :lock_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(schedule, attrs) do
    schedule
    |> cast(attrs, [:cohort_id, :course_id, :resource_type, :resource_id, :unlock_at, :lock_at])
    |> validate_required([:cohort_id, :course_id, :resource_type, :resource_id])
    |> unique_constraint([:cohort_id, :resource_id, :resource_type],
      name: :cohort_resource_unique_index
    )
    |> validate_dates()
  end

  @doc false
  defp validate_dates(changeset) do
    unlock_at = get_field(changeset, :unlock_at)
    lock_at = get_field(changeset, :lock_at)

    if unlock_at != nil and lock_at != nil do
      case DateTime.compare(unlock_at, lock_at) do
        :gt ->
          add_error(changeset, :lock_at, dgettext_noop("errors", "must be after the unlock time"))

        :eq ->
          add_error(
            changeset,
            :lock_at,
            dgettext_noop("errors", "cannot be exactly the same as unlock time")
          )

        _lt ->
          changeset
      end
    else
      changeset
    end
  end
end
