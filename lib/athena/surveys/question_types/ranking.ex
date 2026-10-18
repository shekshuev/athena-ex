defmodule Athena.Surveys.QuestionTypes.Ranking do
  @moduledoc """
  Config for a `:ranking` question - order the `items` by preference.

  The answer stores the item ids in the chosen order in `value_choice_ids`,
  so the array *position* carries the rank. `max_ranked` (optional) asks for
  a top-N instead of a full ordering, which is the usual way to keep a long
  list answerable.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Athena.Surveys.QuestionTypes.Option

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    embeds_many :items, Option
    field :max_ranked, :integer
  end

  @type t :: %__MODULE__{items: [Option.t()], max_ranked: integer() | nil}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    changeset =
      schema
      |> cast(attrs, [:max_ranked])
      |> cast_embed(:items, with: &Option.changeset/2)
      |> validate_number(:max_ranked, greater_than: 1)

    items = length(get_field(changeset, :items) || [])

    changeset
    |> validate_min_items(items)
    |> validate_max_ranked(items)
  end

  defp validate_min_items(changeset, count) when count < 2,
    do: add_error(changeset, :items, "must have at least 2 items")

  defp validate_min_items(changeset, _count), do: changeset

  defp validate_max_ranked(changeset, count) do
    max_ranked = get_field(changeset, :max_ranked)

    if is_integer(max_ranked) and count > 0 and max_ranked > count do
      add_error(changeset, :max_ranked, "cannot exceed the number of items")
    else
      changeset
    end
  end
end
