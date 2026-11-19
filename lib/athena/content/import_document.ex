defmodule Athena.Content.ImportDocument do
  @moduledoc "Converts portable HTML to supported TipTap nodes. Never stores executable HTML or fetches URLs."

  alias Athena.Content.{ExportDocument, ImportXml}

  @blocks %{
    "p" => "paragraph",
    "blockquote" => "blockquote",
    "ul" => "bulletList",
    "ol" => "orderedList",
    "li" => "listItem",
    "pre" => "codeBlock",
    "table" => "table",
    "tr" => "tableRow",
    "td" => "tableCell",
    "th" => "tableHeader"
  }
  @marks %{
    "b" => "bold",
    "strong" => "bold",
    "i" => "italic",
    "em" => "italic",
    "s" => "strike",
    "strike" => "strike",
    "u" => "underline",
    "code" => "code",
    "mark" => "highlight",
    "sub" => "subscript",
    "sup" => "superscript"
  }
  @entities %{
    "nbsp" => "\u00A0",
    "ndash" => "–",
    "mdash" => "–",
    "laquo" => "«",
    "raquo" => "»",
    "hellip" => "…",
    "copy" => "©",
    "times" => "×",
    "le" => "≤",
    "ge" => "≥",
    "ne" => "≠",
    "bull" => "•"
  }

  def from(text, format) when format in ["plain", "plain_text"], do: plain_document(text)
  def from(text, "markdown"), do: text |> MDEx.to_html!() |> from("html")

  def from(text, format) when format in ["html", "moodle", "moodle_auto_format", ""] do
    text |> html_tree() |> nodes([]) |> document()
  end

  def from(_text, _format), do: throw({:skip_question, :unsupported_format})

  def feedback(text, format), do: text |> from(format) |> plain() |> String.trim()
  def plain(%{"type" => "text", "text" => text}), do: text
  def plain(%{"type" => "hardBreak"}), do: "\n"
  def plain(node), do: Enum.map_join(node["content"] || [], separator(node["type"]), &plain/1)

  defp separator(type) when type in ["doc", "bulletList", "orderedList"], do: "\n"
  defp separator(_type), do: ""

  defp plain_document(text) do
    content = text |> String.split("\n") |> Enum.intersperse(:break) |> Enum.map(&plain_node/1)

    %{
      "type" => "doc",
      "content" => [%{"type" => "paragraph", "content" => Enum.reject(content, &is_nil/1)}]
    }
  end

  defp plain_node(:break), do: %{"type" => "hardBreak"}
  defp plain_node(""), do: nil
  defp plain_node(text), do: %{"type" => "text", "text" => text}

  defp html_tree(text) do
    # Normalize HTML void elements and named entities before the strict XML parser.
    tokens = Regex.scan(~r/<!--.*?-->|<\/?[A-Za-z](?:"[^"]*"|'[^']*'|[^'">])*>|[^<]+|</s, text)
    xml = Enum.map_join(tokens, fn [token] -> html_token(token) end)
    ImportXml.parse("<root>#{xml}</root>")
  end

  defp html_token("<!--" <> _comment), do: ""
  defp html_token("<"), do: "&lt;"

  defp html_token("</" <> tag),
    do: "</" <> (tag |> String.trim_trailing(">") |> String.trim() |> String.downcase()) <> ">"

  defp html_token("<" <> tag) do
    [_, name, rest] = Regex.run(~r/^([A-Za-z][A-Za-z0-9:_-]*)(.*)>$/s, tag)
    name = String.downcase(name)
    attrs = parse_attributes(rest)

    ending =
      if name in ["br", "hr", "img", "wbr"] or String.ends_with?(String.trim(rest), "/"),
        do: "/>",
        else: ">"

    "<#{name}#{attrs}#{ending}"
  end

  defp html_token(text) do
    Regex.replace(~r/&([A-Za-z][A-Za-z0-9]+);/, text, fn full, name ->
      case Map.fetch(@entities, name) do
        {:ok, value} -> value
        :error -> full
      end
    end)
    |> String.replace(~r/&(?!amp;|lt;|gt;|quot;|apos;|#\d+;|#x[0-9A-Fa-f]+;)/, "&amp;")
  end

  defp parse_attributes(text) do
    Regex.scan(~r/([A-Za-z_:][A-Za-z0-9_:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>\/]+))/, text)
    |> Enum.map_join(fn [_, name | values] ->
      value = Enum.find(values, "", &(&1 != ""))
      # Entity references are decoded once by ImportXml, just like text nodes.
      " #{String.downcase(name)}=\"#{html_token(value) |> String.replace("\"", "&quot;")}\""
    end)
  end

  defp nodes(text, marks) when is_binary(text) do
    if text == "", do: [], else: [%{"type" => "text", "text" => text, "marks" => marks}]
  end

  defp nodes(%{name: name} = node, marks) do
    reject_unsafe_node!(name)
    convert_node(name, node, marks)
  end

  defp convert_node("br", _node, _marks), do: [%{"type" => "hardBreak"}]
  defp convert_node("hr", _node, _marks), do: [%{"type" => "horizontalRule"}]
  defp convert_node("wbr", _node, _marks), do: []

  defp convert_node("img", node, _marks) do
    src = Map.get(node.attrs, "src", "")
    validate_url!(src, :image)
    [%{"type" => "image", "attrs" => %{"src" => src, "alt" => Map.get(node.attrs, "alt", "")}}]
  end

  defp convert_node("a", node, marks) do
    href = Map.get(node.attrs, "href", "")
    validate_url!(href, :link)
    child_nodes(node, [%{"type" => "link", "attrs" => %{"href" => href}} | marks])
  end

  defp convert_node("pre", node, _marks) do
    [%{"type" => "codeBlock", "content" => [%{"type" => "text", "text" => ImportXml.text(node)}]}]
  end

  defp convert_node("p", node, marks) do
    case node |> child_nodes(marks) |> document() do
      %{"content" => []} -> [%{"type" => "paragraph"}]
      %{"content" => content} -> content
    end
  end

  defp convert_node("h" <> level, node, marks) when level in ~w(1 2 3 4 5 6),
    do: [
      %{
        "type" => "heading",
        "attrs" => %{"level" => String.to_integer(level)},
        "content" => child_nodes(node, marks)
      }
    ]

  defp convert_node(name, node, marks) do
    cond do
      Map.has_key?(@marks, name) -> child_nodes(node, [%{"type" => @marks[name]} | marks])
      Map.has_key?(@blocks, name) -> [block_node(name, node, marks)]
      true -> child_nodes(node, marks)
    end
  end

  defp block_node(name, node, marks) do
    children = child_nodes(node, marks)

    children =
      if name in ["li", "td", "th", "blockquote"],
        do: block_children(children),
        else: Enum.reject(children, &whitespace_node?/1)

    block = %{"type" => @blocks[name], "content" => children}
    block_attrs(block, name, node.attrs)
  end

  defp block_children(children) do
    case document(children)["content"] do
      [] -> [%{"type" => "paragraph"}]
      content -> content
    end
  end

  defp whitespace_node?(%{"type" => "text", "text" => text}), do: String.trim(text) == ""
  defp whitespace_node?(_node), do: false

  defp block_attrs(block, name, attrs) when name in ["td", "th"],
    do:
      Map.put(block, "attrs", %{
        "colspan" => positive_integer(attrs["colspan"]),
        "rowspan" => positive_integer(attrs["rowspan"])
      })

  defp block_attrs(block, "ol", attrs),
    do: Map.put(block, "attrs", %{"start" => positive_integer(attrs["start"])})

  defp block_attrs(block, _name, _attrs), do: block

  defp positive_integer(nil), do: 1

  defp positive_integer(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _ -> 1
    end
  end

  defp child_nodes(node, marks), do: Enum.flat_map(node.children, &nodes(&1, marks))

  defp reject_unsafe_node!(name)
       when name in [
              "script",
              "style",
              "iframe",
              "object",
              "embed",
              "svg",
              "math",
              "audio",
              "video"
            ],
       do: throw({:skip_question, :unsupported_content})

  defp reject_unsafe_node!(_name), do: :ok

  defp validate_url!(value, kind) do
    uri = URI.parse(String.trim(value))
    validate_url_scheme!(uri.scheme, kind)
    # Reuse the exporter's URL validation, without fetching or resolving anything.
    ExportDocument.html(%{
      "type" => "text",
      "text" => "link",
      "marks" => [%{"type" => "link", "attrs" => %{"href" => value}}]
    })

    if String.contains?(value, "@@PLUGINFILE@@"), do: throw({:skip_question, :embedded_files})
  end

  defp validate_url_scheme!(scheme, :image) when scheme not in ["http", "https"],
    do: throw({:skip_question, :embedded_files})

  defp validate_url_scheme!(_scheme, _kind), do: :ok

  defp document(nodes) do
    {blocks, inline} = Enum.reduce(nodes, {[], []}, &group_blocks/2)
    blocks = flush_inline(blocks, inline)
    %{"type" => "doc", "content" => Enum.reverse(blocks)}
  end

  defp group_blocks(%{"type" => type} = node, {blocks, inline})
       when type in ["text", "hardBreak"],
       do: {blocks, [node | inline]}

  defp group_blocks(node, {blocks, inline}), do: {[node | flush_inline(blocks, inline)], []}
  defp flush_inline(blocks, []), do: blocks

  defp flush_inline(blocks, inline),
    do: [%{"type" => "paragraph", "content" => Enum.reverse(inline)} | blocks]
end
