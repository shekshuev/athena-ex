defmodule Athena.Gamification.Sprint do
  @moduledoc """
  A time-boxed XP multiplier for one cohort, created by the instructor who
  owns it — they know the real course calendar (an upcoming exam, a
  deadline crunch) better than a central admin would. Doesn't introduce a
  separate leaderboard: it just boosts XP earned during the window, which
  then shows up in the existing weekly league and badges.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @allowed_multipliers [Decimal.new("1.5"), Decimal.new("2"), Decimal.new("3")]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "gamification_sprints" do
    field :cohort_id, :binary_id
    field :title, :string
    field :starts_at, :utc_datetime
    field :ends_at, :utc_datetime
    field :xp_multiplier, :decimal, default: Decimal.new("1.5")
    field :created_by, :binary_id
    field :is_active, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for creating or editing a sprint. Deliberately keeps
  the multiplier to a fixed pick-list (x1.5/x2/x3) rather than free
  numeric input — one less way to fat-finger a course's XP economy.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(sprint, attrs) do
    sprint
    |> cast(attrs, [
      :cohort_id,
      :title,
      :starts_at,
      :ends_at,
      :xp_multiplier,
      :created_by,
      :is_active
    ])
    |> validate_required([:cohort_id, :title, :starts_at, :ends_at, :xp_multiplier, :created_by])
    |> validate_inclusion(:xp_multiplier, @allowed_multipliers,
      message: "must be one of 1.5, 2, or 3"
    )
    |> validate_dates()
  end

  defp validate_dates(changeset) do
    starts_at = get_field(changeset, :starts_at)
    ends_at = get_field(changeset, :ends_at)

    if starts_at && ends_at && DateTime.compare(starts_at, ends_at) != :lt do
      add_error(changeset, :ends_at, "must be after the start time")
    else
      changeset
    end
  end
end
