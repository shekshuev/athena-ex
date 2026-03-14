defmodule Athena.Identity.Profile do
  @moduledoc """
  Represents the personal information of a user.

  Linked 1-to-1 with the `Account` entity via `owner_id`.
  Core fields like names are explicit columns, while flexible 
  attributes are stored in the `metadata` JSONB field.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @derive {
    Flop.Schema,
    filterable: [:first_name, :last_name],
    sortable: [:first_name, :last_name, :inserted_at],
    default_limit: 10,
    default_order: %{
      order_by: [:last_name],
      order_directions: [:asc]
    }
  }

  schema "profiles" do
    field :first_name, :string
    field :last_name, :string
    field :patronymic, :string
    field :avatar_url, :string
    field :birth_date, :date
    field :metadata, :map, default: %{}

    belongs_to :owner, Athena.Identity.Account

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for profile creation or update.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [
      :first_name,
      :last_name,
      :patronymic,
      :avatar_url,
      :birth_date,
      :metadata,
      :owner_id
    ])
    |> validate_required([:first_name, :last_name, :owner_id])
    |> validate_length(:first_name, max: 100)
    |> validate_length(:last_name, max: 100)
    |> validate_length(:patronymic, max: 100)
    |> unique_constraint(:owner_id, name: :profiles__owner_id__uk)
    |> foreign_key_constraint(:owner_id, name: :profiles__owner_id__fk, message: "does not exist")
  end

  @doc """
  Dynamically computes the full name from a Profile struct.
  """
  @spec full_name(t()) :: String.t()
  def full_name(%__MODULE__{} = profile) do
    [profile.last_name, profile.first_name, profile.patronymic]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end
end
