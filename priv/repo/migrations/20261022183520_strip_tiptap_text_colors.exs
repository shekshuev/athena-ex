defmodule Athena.Repo.Migrations.StripTiptapTextColors do
  @moduledoc """
  Removes text-colour attributes from every TipTap document already stored.

  Pasting formatted text from a web page used to carry its `color` along, as
  a `textStyle` mark. Nobody asked for those colours - the editor has no
  colour picker - and a hard-coded dark colour is invisible on the dark
  theme. The editor no longer registers `@tiptap/extension-color`, so new
  pastes arrive clean; this clears out what is already in the database.

  Unlike the other content transforms here, this is Elixir rather than a raw
  SQL `execute/1`: the rewrite is a recursive walk over an arbitrarily nested
  document, which jsonb operators cannot express readably. The walk is
  duplicated privately below rather than calling `Athena.Content.Tiptap`, so
  a later change to application code cannot retroactively change what this
  migration does - which is the reason the rest of these migrations stick to
  raw SQL in the first place.

  Irreversible: the original colours are recorded nowhere, so `down/0` is a
  no-op.
  """
  use Ecto.Migration

  # {table, jsonb column}. `blocks` and `library_blocks` hold a type-specific
  # payload with documents nested under several keys (`body`, each option's
  # `text`, each pair's `left`/`right`, ...); `announcements` and
  # `survey_questions` hold a bare document; `submissions` holds a student's
  # rich answer as a JSON *string* under `text_answer`, which the walk
  # handles as well.
  @targets [
    {"blocks", "content"},
    {"library_blocks", "content"},
    {"announcements", "body"},
    {"survey_questions", "body"},
    {"submissions", "content"}
  ]

  @batch_size 500
  @color_keys ["color", "backgroundColor"]
  @first_id "00000000-0000-0000-0000-000000000000"

  def up do
    for {table, column} <- @targets, do: strip_table(table, column, Ecto.UUID.dump!(@first_id))
  end

  def down, do: :ok

  defp strip_table(table, column, after_id) do
    # `::text ILIKE '%color%'` is a deliberately loose pre-filter: it has to
    # match both `"color"` in jsonb and the escaped `\\"color\\"` of a document
    # stored as a JSON *string* (a submission's `text_answer`), plus
    # `backgroundColor`. It over-matches - `color` also occurs in a
    # `dialogueLine`'s own attribute and in prose - but a row is only written
    # when the walk below actually changed it, so over-matching costs reads,
    # never a spurious update. Keyset paging on the (uuid) primary key keeps
    # this bounded on the big tables.
    %{rows: rows} =
      repo().query!(
        """
        SELECT id, #{column} FROM #{table}
        WHERE #{column}::text ILIKE '%color%' AND id > $1
        ORDER BY id
        LIMIT #{@batch_size}
        """,
        [after_id]
      )

    for [id, value] <- rows do
      stripped = strip(value)

      if stripped != value do
        repo().query!("UPDATE #{table} SET #{column} = $1 WHERE id = $2", [stripped, id])
      end
    end

    case List.last(rows) do
      nil -> :ok
      [last_id, _value] -> strip_table(table, column, last_id)
    end
  end

  defp strip(%{} = map) do
    Map.new(map, fn
      {"marks", marks} when is_list(marks) -> {"marks", Enum.flat_map(marks, &clean_mark/1)}
      {"text_answer", value} when is_binary(value) -> {"text_answer", strip_doc_string(value)}
      {key, value} -> {key, strip(value)}
    end)
  end

  defp strip(list) when is_list(list), do: Enum.map(list, &strip/1)
  defp strip(other), do: other

  defp clean_mark(%{"type" => "textStyle"} = mark) do
    attrs = Map.drop(Map.get(mark, "attrs") || %{}, @color_keys)

    if Enum.all?(attrs, fn {_k, v} -> is_nil(v) end),
      do: [],
      else: [Map.put(mark, "attrs", attrs)]
  end

  defp clean_mark(mark), do: [strip(mark)]

  defp strip_doc_string(value) do
    case Jason.decode(value) do
      {:ok, %{"type" => "doc"} = doc} -> Jason.encode!(strip(doc))
      _not_a_document -> value
    end
  end
end
