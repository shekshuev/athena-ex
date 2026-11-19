defmodule Athena.Content.LibraryImport do
  @moduledoc "Imports supported questions as new private templates owned by the importing user."
  alias Athena.{Identity, Repo}
  alias Athena.Content.{GiftQuestionImport, LibraryBlock, MoodleQuestionImport}

  @max_size 5_000_000
  @max_questions 2000

  def run(user, data, format) do
    with true <- Identity.can?(user, "library.create"),
         :ok <- validate_input(data),
         {:ok, records} <- parse(data, format),
         :ok <- validate_count(records) do
      Repo.transaction(fn ->
        records
        |> Enum.with_index(1)
        |> Enum.reduce(%{imported: 0, skipped: []}, &import_record(&1, &2, user))
        |> summarize()
      end)
    else
      false -> {:error, :forbidden}
      {:error, _} = error -> error
    end
  end

  defp validate_input(data) when is_binary(data) and byte_size(data) <= @max_size do
    if String.valid?(data) and not String.contains?(data, <<0>>),
      do: :ok,
      else: {:error, :invalid_file}
  end

  defp validate_input(_data), do: {:error, :file_too_large}
  defp validate_count([]), do: {:error, :no_questions}

  defp validate_count(records) when length(records) > @max_questions,
    do: {:error, :too_many_questions}

  defp validate_count(_records), do: :ok

  defp parse(data, format) do
    data = String.trim_leading(data, "\uFEFF")
    parse_format(data, format)
  rescue
    _ in [ArgumentError, FunctionClauseError, MatchError] -> {:error, :invalid_file}
  end

  defp parse_format(data, "gift"), do: {:ok, GiftQuestionImport.parse(data)}
  defp parse_format(data, "moodle_xml"), do: {:ok, MoodleQuestionImport.parse(data)}
  defp parse_format(_data, _format), do: {:error, :invalid_format}

  defp import_record({{:ok, attrs}, index}, result, user) do
    # File metadata never controls ownership, visibility or IDs.
    attrs = Map.take(attrs, ~w(title content tags points)) |> Map.put("type", "quiz_question")
    changeset = LibraryBlock.changeset(%LibraryBlock{owner_id: user.id, is_public: false}, attrs)

    case Repo.insert(changeset) do
      {:ok, _block} -> %{result | imported: result.imported + 1}
      {:error, _changeset} -> skip(result, index, attrs["title"], :invalid_question)
    end
  end

  defp import_record({{:skip, %{title: title, reason: reason}}, index}, result, _user),
    do: skip(result, index, title, reason)

  defp skip(result, index, title, reason),
    do: %{result | skipped: [%{id: index, title: title, reason: reason} | result.skipped]}

  defp summarize(result),
    do:
      result
      |> Map.put(:skipped, Enum.reverse(result.skipped))
      |> Map.put(:skipped_count, length(result.skipped))
end
