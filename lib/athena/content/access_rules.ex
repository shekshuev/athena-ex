defmodule Athena.Content.AccessRules do
  @moduledoc """
  Embedded schema for granular access controls in Sections and Blocks.
  """
  use Ecto.Schema
  import Ecto.Changeset

  use Gettext, backend: AthenaWeb.Gettext

  @primary_key false
  embedded_schema do
    field :unlock_at, :utc_datetime
    field :lock_at, :utc_datetime
  end

  @doc false
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:unlock_at, :lock_at])
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
