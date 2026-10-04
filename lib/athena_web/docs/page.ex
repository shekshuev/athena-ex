defmodule AthenaWeb.Docs.Page do
  @moduledoc """
  One compiled documentation file (see `AthenaWeb.Docs`).

  Built from its location, `priv/docs/<lang>/<NN-section>/<NN-slug>.md`:
  the language and section come from the directories, the order from the
  numeric prefixes, and the `_index.md` of a section describes the section
  itself (`kind: :section`). The front matter map provides `title`,
  `description` and, for pages not written yet, `stub: true`.
  """

  @enforce_keys [:lang, :kind, :section, :path, :title]
  defstruct [
    :lang,
    :kind,
    :section,
    :slug,
    :path,
    :title,
    :description,
    :body,
    section_order: 0,
    order: 0,
    stub?: false,
    headings: []
  ]

  @type t :: %__MODULE__{}

  @doc false
  def build(filename, attrs, body) do
    [file, section_dir, lang | _] = filename |> Path.split() |> Enum.reverse()
    {section_order, section} = split_order(section_dir)
    {order, slug} = split_order(Path.rootname(file))
    kind = if slug == "_index", do: :section, else: :page

    %__MODULE__{
      lang: lang,
      kind: kind,
      section: section,
      slug: if(kind == :page, do: slug),
      path: if(kind == :section, do: section, else: section <> "/" <> slug),
      title: Map.fetch!(attrs, :title),
      description: Map.get(attrs, :description),
      body: body,
      section_order: section_order,
      order: order,
      stub?: Map.get(attrs, :stub, false),
      headings: headings(body)
    }
  end

  # "06-engagement" -> {6, "engagement"}; no prefix sorts first.
  defp split_order(name) do
    case Regex.run(~r/^(\d+)-(.+)$/, name) do
      [_, number, rest] -> {String.to_integer(number), rest}
      _ -> {0, name}
    end
  end

  # The h2/h3 headings MDEx gave ids to, for "On this page".
  defp headings(body) do
    ~r{<h([23]) id="([^"]+)">(.*?)<a href="#}s
    |> Regex.scan(body)
    |> Enum.map(fn [_, level, id, html] ->
      %{level: String.to_integer(level), id: id, text: html |> strip_tags() |> String.trim()}
    end)
  end

  defp strip_tags(html), do: Regex.replace(~r/<[^>]+>/, html, "")
end
