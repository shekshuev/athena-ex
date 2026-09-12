defmodule Athena.Gamification.DailyChallenge do
  @moduledoc """
  One account's assigned "task of the day" — a single already-solved block
  picked for `assigned_date`, completed at most once. `account_id` and
  `block_id` are bare `:binary_id`s (soft references to `Identity.Account`
  and `Content.Block`, both outside this bounded context), not `belongs_to`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "gamification_daily_challenges" do
    field :account_id, :binary_id
    field :block_id, :binary_id
    field :assigned_date, :date
    field :completed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(challenge, attrs) do
    challenge
    |> cast(attrs, [:account_id, :block_id, :assigned_date, :completed_at])
    |> validate_required([:account_id, :block_id, :assigned_date])
    |> unique_constraint([:account_id, :assigned_date],
      name: :gamification_daily_challenges_unique_index
    )
  end
end
