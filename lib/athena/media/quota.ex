defmodule Athena.Media.Quota do
  @moduledoc """
  Defines storage limits for different roles.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:role_id, :binary_id, autogenerate: false}

  schema "media_quotas" do
    field :limit_bytes, :integer, default: 0
    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(quota, attrs) do
    quota
    |> cast(attrs, [:role_id, :limit_bytes])
    |> validate_required([:role_id, :limit_bytes])
    |> validate_number(:limit_bytes, greater_than_or_equal_to: 0)
  end
end
