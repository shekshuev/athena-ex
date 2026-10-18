defmodule Athena.Surveys.Positions do
  @moduledoc """
  Writing a list's order back as dense `position` values.

  Both questions and branch rules are ordered lists the author drags around,
  and both renumber the same way, so the loop lives here instead of in four
  near-identical copies. Positions stay dense (0, 1, 2 ...) rather than
  gapped, which is what lets `Athena.Surveys.Flow` treat "the next question"
  as `position + 1`.

  Only rows whose position actually changed are written: a reorder that moves
  one item in a long list should be one update, not one per item.
  """

  alias Athena.Repo

  @doc """
  Sets each record's `position` to its index in `records`, updating only the
  ones that moved. Must run inside a transaction - a half-applied renumber
  would leave two items claiming the same place.
  """
  @spec apply_order([struct()]) :: :ok
  def apply_order(records) do
    records
    |> Enum.with_index()
    |> Enum.each(&write_position/1)
  end

  defp write_position({%{position: position}, position}), do: :ok

  defp write_position({record, index}) do
    record
    |> Ecto.Changeset.change(%{position: index})
    |> Repo.update!()

    :ok
  end
end
