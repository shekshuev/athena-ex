defmodule Athena.Surveys.QuestionTypes.ScaleBounds do
  @moduledoc """
  Shared validation for the two scale-shaped configs (`Scale` and
  `MultiScale`), which declare the same `min`/`max`/`step` and label fields
  flat rather than nesting them in a shared embed - a flat shape keeps the
  stored JSON one level deep, which is what the SQL aggregation in
  `Athena.Surveys.Results` reads.
  """
  import Ecto.Changeset

  @doc """
  Rejects an inverted or unreachable scale, and a `point_labels` list whose
  length does not match the number of points the bounds describe.

  An empty `point_labels` means "label only the poles", which is the common
  Likert presentation - only a non-empty list is length-checked.
  """
  @spec validate(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate(changeset) do
    min = get_field(changeset, :min)
    max = get_field(changeset, :max)
    step = get_field(changeset, :step)

    changeset
    |> validate_number(:step, greater_than: 0)
    |> validate_range(min, max)
    |> validate_point_labels(min, max, step)
  end

  defp validate_range(changeset, min, max) when is_integer(min) and is_integer(max) do
    if max > min do
      changeset
    else
      add_error(changeset, :max, "must be greater than the minimum")
    end
  end

  defp validate_range(changeset, _min, _max), do: changeset

  defp validate_point_labels(changeset, min, max, step)
       when is_integer(min) and is_integer(max) and is_integer(step) and step > 0 and max > min do
    case get_field(changeset, :point_labels) do
      labels when is_list(labels) and labels != [] ->
        expected = div(max - min, step) + 1

        if length(labels) == expected do
          changeset
        else
          add_error(changeset, :point_labels, "must have one label per scale point",
            expected: expected
          )
        end

      _ ->
        changeset
    end
  end

  defp validate_point_labels(changeset, _min, _max, _step), do: changeset
end
