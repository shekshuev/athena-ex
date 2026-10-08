# Minimal .docx reader used by parse.exs: returns the body paragraphs as
# `%{text: String.t(), images: [media_name]}` with images in document order,
# plus the media files (name => binary).
#
# Only the pieces the test-bank documents use are handled (paragraphs, runs,
# inline/anchored drawings); tables and VML pictures are not present there.

defmodule QuizImport.DocxReader do
  # xmerl records are matched as plain tuples: with Record macros the
  # unspecified fields fall back to their defaults in patterns, which breaks
  # matching against real parsed elements.
  #   {:xmlElement, name, expanded_name, nsinfo, namespace, parents, pos,
  #    attributes, content, language, xmlbase, elementdef}
  #   {:xmlAttribute, name, expanded_name, nsinfo, namespace, parents, pos,
  #    language, value, normalized}
  #   {:xmlText, parents, pos, language, value, type}

  @type paragraph :: %{text: String.t(), images: [String.t()]}

  @spec read!(Path.t()) :: %{paragraphs: [paragraph()], media: %{String.t() => binary()}}
  def read!(path) do
    {:ok, files} = :zip.unzip(String.to_charlist(path), [:memory])
    files = Map.new(files, fn {name, bin} -> {List.to_string(name), bin} end)

    rels = parse_rels(Map.fetch!(files, "word/_rels/document.xml.rels"))

    media =
      for {name, bin} <- files, String.starts_with?(name, "word/media/"), into: %{} do
        {Path.basename(name), bin}
      end

    body =
      files
      |> Map.fetch!("word/document.xml")
      |> parse_xml()
      |> children(:"w:body")
      |> List.first()

    paragraphs =
      body
      |> children(:"w:p")
      |> Enum.map(&paragraph(&1, rels))

    %{paragraphs: paragraphs, media: media}
  end

  defp parse_rels(xml) do
    xml
    |> parse_xml()
    |> children(:Relationship)
    |> Map.new(fn rel -> {attr(rel, :Id), attr(rel, :Target)} end)
  end

  defp parse_xml(xml) do
    {root, _} = xml |> :erlang.binary_to_list() |> :xmerl_scan.string(quiet: true)
    root
  end

  defp paragraph(p, rels) do
    pieces = p |> descend() |> List.flatten()

    text =
      pieces
      |> Enum.flat_map(fn
        {:text, t} -> [t]
        _ -> []
      end)
      |> Enum.join()
      |> normalize_space()

    images =
      for {:image, rid} <- pieces,
          target = Map.get(rels, rid),
          do: Path.basename(target)

    %{text: text, images: images}
  end

  # Walks a paragraph in document order. `mc:Fallback` is skipped so that
  # an image wrapped in mc:AlternateContent is not counted twice.
  defp descend(el) do
    el
    |> raw_children()
    |> Enum.map(fn
      {:xmlText, _, _, _, _, _} ->
        []

      {:xmlElement, :"w:t", _, _, _, _, _, _, _, _, _, _} = t ->
        [{:text, text_of(t)}]

      {:xmlElement, :"w:tab", _, _, _, _, _, _, _, _, _, _} ->
        [{:text, " "}]

      {:xmlElement, :"w:br", _, _, _, _, _, _, _, _, _, _} ->
        [{:text, " "}]

      {:xmlElement, :"w:drawing", _, _, _, _, _, _, _, _, _, _} = d ->
        case find_blip(d) do
          nil -> []
          rid -> [{:image, rid}]
        end

      {:xmlElement, :"mc:Fallback", _, _, _, _, _, _, _, _, _, _} ->
        []

      {:xmlElement, _, _, _, _, _, _, _, _, _, _, _} = child ->
        descend(child)

      _ ->
        []
    end)
  end

  defp find_blip(el) do
    Enum.find_value(raw_children(el), fn
      {:xmlElement, :"a:blip", _, _, _, _, _, _, _, _, _, _} = b -> attr(b, :"r:embed")
      {:xmlElement, _, _, _, _, _, _, _, _, _, _, _} = c -> find_blip(c)
      _ -> nil
    end)
  end

  defp text_of(el) do
    el
    |> raw_children()
    |> Enum.map_join(fn
      {:xmlText, _, _, _, v, _} -> to_string(v)
      _ -> ""
    end)
  end

  defp normalize_space(text) do
    text
    |> String.replace(~r/[\s\x{00A0}]+/u, " ")
    |> String.trim()
  end

  defp raw_children({:xmlElement, _, _, _, _, _, _, _, content, _, _, _}), do: content

  defp children(el, name) do
    for {:xmlElement, ^name, _, _, _, _, _, _, _, _, _, _} = child <- raw_children(el),
        do: child
  end

  defp attr({:xmlElement, _, _, _, _, _, _, attrs, _, _, _, _}, name) when is_atom(name) do
    Enum.find_value(attrs, fn
      {:xmlAttribute, ^name, _, _, _, _, _, _, v, _} -> to_string(v)
      _ -> nil
    end)
  end
end
