defmodule Athena.Content.ExportDocument do
  @moduledoc """
  Renders library rich text for portable question formats. Images remain links;
  no arbitrary URLs are fetched during export. Unknown nodes fail the export
  instead of silently discarding authored content.
  """

  @containers %{
    "doc" => nil,
    "paragraph" => "p",
    "blockquote" => "blockquote",
    "bulletList" => "ul",
    "orderedList" => "ol",
    "listItem" => "li",
    "table" => "table",
    "tableRow" => "tr",
    "details" => "details",
    "detailsSummary" => "summary",
    "detailsContent" => "div",
    "tip" => "aside",
    "dialogue" => "div"
  }
  @marks %{
    "bold" => "strong",
    "italic" => "em",
    "strike" => "s",
    "underline" => "u",
    "code" => "code",
    "highlight" => "mark",
    "subscript" => "sub",
    "superscript" => "sup"
  }

  def html(doc, opts \\ [])
  def html(nil, _opts), do: ""

  def html(%{"type" => "text", "text" => text} = node, opts) do
    Enum.reduce(node["marks"] || [], escape(text), &mark(&1, &2, opts))
  end

  def html(%{"type" => "hardBreak"}, _opts), do: "<br>"
  def html(%{"type" => "horizontalRule"}, _opts), do: "<hr>"

  def html(%{"type" => "image", "attrs" => attrs}, opts) do
    src = export_url(attrs["src"] || "", opts)
    "<img src=\"#{escape(src)}\" alt=\"#{escape(attrs["alt"] || "")}\">"
  end

  def html(%{"type" => type, "attrs" => attrs}, _opts)
      when type in ["inlineMath", "blockMath"] do
    latex = escape(attrs["latex"] || "")
    if type == "inlineMath", do: "\\(#{latex}\\)", else: "\\[#{latex}\\]"
  end

  def html(%{"type" => type} = node, opts) do
    children = Enum.map_join(node["content"] || [], &html(&1, opts))
    attrs = node["attrs"] || %{}

    render_node(type, attrs, children)
  end

  defp render_node("heading", attrs, children) do
    level = attrs["level"] || 1
    if level not in 1..6, do: raise(ArgumentError, "Invalid heading")
    wrap("h#{level}", children)
  end

  defp render_node("codeBlock", _attrs, children), do: wrap("pre", wrap("code", children))

  defp render_node(type, attrs, children) when type in ["tableCell", "tableHeader"] do
    tag = if type == "tableCell", do: "td", else: "th"

    "<#{tag} colspan=\"#{span(attrs["colspan"])}\" rowspan=\"#{span(attrs["rowspan"])}\">#{children}</#{tag}>"
  end

  defp render_node("dialogueLine", attrs, children),
    do: wrap("p", escape(attrs["name"] || "") <> " " <> children)

  defp render_node(type, _attrs, children) do
    case Map.fetch(@containers, type) do
      {:ok, nil} -> children
      {:ok, tag} -> wrap(tag, children)
      :error -> raise ArgumentError, "Unsupported rich text node"
    end
  end

  def plain(nil), do: ""
  def plain(%{"type" => "text", "text" => text}), do: text
  def plain(%{"type" => "hardBreak"}), do: "\n"

  def plain(%{"type" => type} = node) do
    # Matching answer labels in Moodle are plain text, not HTML documents.
    if type not in ["doc", "paragraph", "codeBlock", "heading"],
      do: raise(ArgumentError, "Matching answer cannot be represented as text")

    Enum.map_join(node["content"] || [], if(type == "doc", do: "\n", else: ""), &plain/1)
  end

  def escape(value) do
    if Regex.match?(~r/[\x00-\x08\x0B\x0C\x0E-\x1F]/u, to_string(value)),
      do: raise(ArgumentError, "Unsupported control character")

    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp mark(%{"type" => "link", "attrs" => attrs}, text, opts),
    do: "<a href=\"#{escape(export_url(attrs["href"] || "", opts))}\">#{text}</a>"

  defp mark(%{"type" => "textStyle"}, text, _opts), do: text

  defp mark(%{"type" => type}, text, _opts) do
    case Map.fetch(@marks, type) do
      {:ok, tag} -> wrap(tag, text)
      :error -> raise ArgumentError, "Unsupported rich text mark"
    end
  end

  defp export_url(value, opts) do
    value = String.trim(value)
    uri = URI.parse(value)

    if uri.scheme not in [nil, "http", "https", "mailto"] or
         String.starts_with?(value, ["//", "\\"]) or
         Regex.match?(~r/[\x00-\x1F\x7F]/u, value),
       do: raise(ArgumentError, "Unsupported URL")

    base = Keyword.get(opts, :base_url)

    if base && is_nil(uri.scheme) && value != "" && not String.starts_with?(value, "#"),
      do: URI.merge(base, value) |> to_string(),
      else: value
  end

  defp span(value) when is_integer(value) and value > 0, do: value
  defp span(_), do: 1
  defp wrap(tag, text), do: "<#{tag}>#{text}</#{tag}>"
end
