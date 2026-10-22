defmodule Athena.Content.Tiptap do
  @moduledoc """
  Helpers for the TipTap/ProseMirror JSON documents this app stores in jsonb
  columns (`blocks.content`, `library_blocks.content`, `announcements.body`,
  `survey_questions.body`, and the rich open answers inside
  `submissions.content`).

  ## Why `strip_colors/1` exists

  Pasting formatted text from a web page used to carry its `color` along, as a
  `textStyle` mark on the pasted text runs. Authors never asked for those
  colours - there is no colour picker in the toolbar - and a hard-coded dark
  colour is invisible on the dark theme, which is how this surfaced.

  The editor no longer registers `@tiptap/extension-color`, so nothing parses
  `color` out of pasted HTML any more. This module is the other half of that:
  it removes the colours already written to the database, and runs on the way
  in so a document that arrives coloured by some other route (an import, a
  seed, a client running stale JS) is stored clean.

  `textStyle` itself stays in the editor's schema - dropping it would make
  ProseMirror reject every stored document that still carries the mark, and
  the block would not render at all.
  """

  # `textStyle` is the only mark the colour extensions attach attributes to;
  # `backgroundColor` comes from the same family and is just as invisible on
  # the opposite theme.
  @color_keys ["color", "backgroundColor", :color, :backgroundColor]

  @doc """
  Removes text-colour attributes from every `textStyle` mark in `doc`,
  dropping marks left with nothing to say.

  Walks maps and lists indiscriminately rather than assuming a document
  shape: a block's `content` is a type-specific payload that nests documents
  under different keys (`"body"`, each option's `"text"`, each pair's
  `"left"`/`"right"`, ...), and this has to clean all of them. Anything that
  is not a map or a list is returned untouched, so it is safe to call on a
  whole `content` map, a bare document, or a value that holds neither.

  A string under a `text_answer` key is passed through
  `strip_colors_in_doc_string/1`, since that is where a submission keeps a
  rich answer - see that function for why the key has to be special-cased.

  Idempotent.

      iex> Athena.Content.Tiptap.strip_colors(%{
      ...>   "type" => "text",
      ...>   "text" => "hi",
      ...>   "marks" => [
      ...>     %{"type" => "bold"},
      ...>     %{"type" => "textStyle", "attrs" => %{"color" => "#000"}}
      ...>   ]
      ...> })
      %{"type" => "text", "text" => "hi", "marks" => [%{"type" => "bold"}]}
  """
  @spec strip_colors(term()) :: term()
  def strip_colors(%{} = map) do
    Map.new(map, fn
      {key, marks} when is_list(marks) and (key == "marks" or key == :marks) ->
        {key, Enum.flat_map(marks, &clean_mark/1)}

      {key, value} when is_binary(value) and (key == "text_answer" or key == :text_answer) ->
        {key, strip_colors_in_doc_string(value)}

      {key, value} ->
        {key, strip_colors(value)}
    end)
  end

  def strip_colors(list) when is_list(list), do: Enum.map(list, &strip_colors/1)
  def strip_colors(other), do: other

  @doc """
  Same as `strip_colors/1`, for a document stored as a JSON *string* rather
  than as jsonb.

  A student's rich open answer is encoded into the `text_answer` of
  `submissions.content`, which otherwise holds plain prose or - for a code
  submission - source code. So this only rewrites the value when it actually
  decodes to a TipTap document, and returns anything else untouched.
  """
  @spec strip_colors_in_doc_string(term()) :: term()
  def strip_colors_in_doc_string(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{"type" => "doc"} = doc} -> Jason.encode!(strip_colors(doc))
      _not_a_document -> value
    end
  end

  def strip_colors_in_doc_string(value), do: value

  defp clean_mark(%{} = mark) do
    if text_style?(mark) do
      attrs = mark |> fetch(:attrs) |> drop_colors()

      if blank_attrs?(attrs), do: [], else: [put_attrs(mark, attrs)]
    else
      [strip_colors(mark)]
    end
  end

  defp clean_mark(other), do: [strip_colors(other)]

  defp text_style?(mark), do: fetch(mark, :type) in ["textStyle", :textStyle]

  defp drop_colors(%{} = attrs), do: Map.drop(attrs, @color_keys)
  defp drop_colors(_other), do: %{}

  # A `textStyle` mark whose attributes are all gone (or were only ever nil)
  # styles nothing, so it is dropped rather than left as noise in the doc.
  defp blank_attrs?(attrs), do: Enum.all?(attrs, fn {_k, v} -> is_nil(v) end)

  defp put_attrs(mark, attrs) do
    if Map.has_key?(mark, :attrs), do: %{mark | attrs: attrs}, else: Map.put(mark, "attrs", attrs)
  end

  defp fetch(%{} = map, key) when is_atom(key) do
    case Map.fetch(map, Atom.to_string(key)) do
      {:ok, value} -> value
      :error -> Map.get(map, key)
    end
  end

  defp fetch(_other, _key), do: nil
end
