defmodule Athena.Engagement.Purge do
  @moduledoc """
  One request to delete the raw engagement events of a student
  (`scope: :account`) or of a cohort (`scope: :cohort`) recorded up to
  `purged_through`. See `Athena.Engagement.Purges`.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "engagement_purges" do
    field :scope, Ecto.Enum, values: [:account, :cohort]
    field :scope_id, :binary_id
    field :purged_through, :utc_datetime
    field :requested_by, :binary_id
    field :status, Ecto.Enum, values: [:pending, :deleting, :done], default: :pending
    field :deleted_count, :integer, default: 0
    field :completed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end
end
