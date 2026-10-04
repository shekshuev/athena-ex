defmodule Athena.Engagement.RollupCursor do
  @moduledoc """
  How far `Athena.Engagement.Rollups` has folded `engagement_events` in:
  the insertion time of the newest event processed.
  """
  use Ecto.Schema

  @primary_key {:name, :string, autogenerate: false}

  schema "engagement_rollup_cursors" do
    field :last_inserted_at, :utc_datetime

    timestamps(type: :utc_datetime, inserted_at: false)
  end
end
