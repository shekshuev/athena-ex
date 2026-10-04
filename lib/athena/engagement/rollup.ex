defmodule Athena.Engagement.Rollup do
  @moduledoc """
  One pre-aggregated day of one student's engagement on one block - the
  stored form of an `Athena.Engagement.Accumulator` (same field names, one
  column each). Written only by `Athena.Engagement.Rollups`.
  """
  use Ecto.Schema

  alias Athena.Engagement.Accumulator

  @primary_key {:id, :binary_id, autogenerate: true}

  @sums ~w(dwell_sum window_sum offtask_sum idle_sum scroll_sum paste_sum skip_sum ttfa_sum)a

  schema "engagement_rollups" do
    field :cohort_id, :binary_id
    field :account_id, :binary_id
    field :block_id, :binary_id
    field :day, :date

    for name <- Accumulator.fields() do
      if name in @sums,
        do: field(name, :float, default: 0.0),
        else: field(name, :integer, default: 0)
    end

    field :hour_counts, {:array, :integer}, default: []

    timestamps(type: :utc_datetime, inserted_at: false)
  end
end
