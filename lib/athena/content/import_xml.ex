defmodule Athena.Content.ImportXml do
  @moduledoc "String-keyed XML trees for question imports, without interning uploaded tag names as atoms."

  def parse(data) do
    declarations = Regex.replace(~r/<!\[CDATA\[.*?\]\]>|<!--.*?-->/s, data, "")

    if Regex.match?(~r/<!DOCTYPE|<!ENTITY/i, declarations),
      do: raise(ArgumentError, "DTD is unsupported")

    options = [:skip_external_dtd, event_fun: &event/3, event_state: %{stack: [], root: nil}]

    case :xmerl_sax_parser.stream(data, options) do
      {:ok, %{stack: [], root: root}, rest} ->
        if String.trim(to_string(rest)) != "", do: raise(ArgumentError, "Trailing XML")
        root

      _ ->
        raise ArgumentError, "Invalid XML"
    end
  end

  def children(nil, _name), do: []
  def children(node, name), do: Enum.filter(node.children, &match?(%{name: ^name}, &1))
  def child(node, name), do: node |> children(name) |> List.first()
  def field(node, name), do: node |> child(name) |> text()
  def attr(nil, _name, default), do: default
  def attr(node, name, default), do: Map.get(node.attrs, name, default)
  def text(nil), do: ""
  def text(text) when is_binary(text), do: text
  def text(node), do: Enum.map_join(node.children, &text/1)

  def contains?(text, _name) when is_binary(text), do: false
  def contains?(%{name: name}, name), do: true
  def contains?(node, name), do: Enum.any?(node.children, &contains?(&1, name))

  defp event({:startElement, _uri, name, _qualified, attrs}, _location, state) do
    if length(state.stack) >= 64, do: raise(ArgumentError, "XML is too deeply nested")

    attrs =
      Map.new(attrs, fn {_uri, _prefix, key, value} -> {to_string(key), to_string(value)} end)

    node = %{name: to_string(name), attrs: attrs, children: []}
    %{state | stack: [node | state.stack]}
  end

  defp event({:endElement, _uri, _name, _qualified}, _location, %{stack: [node | stack]} = state) do
    node = %{node | children: Enum.reverse(node.children)}
    add_child(node, %{state | stack: stack})
  end

  defp event({:characters, text}, _location, state), do: add_child(to_string(text), state)

  defp event({:ignorableWhitespace, text}, _location, state),
    do: add_child(to_string(text), state)

  defp event({:startDTD, _, _, _}, _location, _state),
    do: raise(ArgumentError, "DTD is unsupported")

  defp event(_event, _location, state), do: state

  defp add_child(node, %{stack: [parent | stack]} = state),
    do: %{state | stack: [%{parent | children: [node | parent.children]} | stack]}

  defp add_child(text, state) when is_binary(text), do: state
  defp add_child(node, state), do: %{state | root: node}
end
