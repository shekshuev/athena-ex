defmodule Athena.Gamification.BadgeAward do
  @moduledoc """
  Records that an account earned a badge. Unique on `(account_id, badge_id)`
  — badges are "first achievement" style and not re-awarded; a repeatable
  idea (e.g. "combo x5" vs "combo x10") is modeled as separate `Badge` rows,
  not repeated awards of the same one.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Athena.Gamification.Badge

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "gamification_badge_awards" do
    field :account_id, :binary_id
    field :context, :map, default: %{}
    field :awarded_at, :utc_datetime

    belongs_to :badge, Badge

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for awarding a badge to an account.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(award, attrs) do
    award
    |> cast(attrs, [:account_id, :badge_id, :context, :awarded_at])
    |> validate_required([:account_id, :badge_id, :awarded_at])
    |> unique_constraint([:account_id, :badge_id])
    |> foreign_key_constraint(:badge_id)
  end
end
