defmodule Athena.Media.FileShare do
  @moduledoc """
  Pivot table connecting a personal `Athena.Media.File` to an
  `Identity.Account` it has been explicitly shared with — mirrors
  `Athena.Content.CourseShare`/`LibraryBlockShare`. `account_id` is a soft
  reference (no belongs_to/FK to `accounts`), same as those two, to keep
  the Media context decoupled from Identity.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Athena.Media.File

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "media_file_shares" do
    belongs_to :media_file, File
    field :account_id, Ecto.UUID

    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(file_share, attrs) do
    file_share
    |> cast(attrs, [:media_file_id, :account_id])
    |> validate_required([:media_file_id, :account_id])
    |> unique_constraint([:media_file_id, :account_id])
  end
end
