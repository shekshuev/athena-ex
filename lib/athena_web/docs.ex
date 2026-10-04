defmodule AthenaWeb.Docs do
  @moduledoc """
  Athena's built-in documentation, written as markdown in `priv/docs` and
  compiled into the release (NimblePublisher + `AthenaWeb.Docs.Converter`).

  Layout: `priv/docs/<lang>/<NN-section>/_index.md` describes a section,
  `priv/docs/<lang>/<NN-section>/<NN-slug>.md` is one page; numeric prefixes
  set the order and are not part of the URL (`/docs/<section>/<slug>`).
  Every page exists in each of `languages/0`; when one is missing, `get/2`
  serves the other language and says so.
  """
  alias AthenaWeb.Docs.Page

  use NimblePublisher,
    build: Page,
    from: "priv/docs/**/*.md",
    as: :pages,
    html_converter: AthenaWeb.Docs.Converter

  # Interface labels are checked against the .pot at compile time.
  @external_resource "priv/gettext/default.pot"

  @languages ~w(ru en)
  @pages Enum.sort_by(@pages, &{&1.lang, &1.section_order, &1.kind != :section, &1.order})

  @doc "Documentation languages, in fallback order."
  @spec languages() :: [String.t()]
  def languages, do: @languages

  @doc "Every compiled page, sections included."
  @spec all() :: [Page.t()]
  def all, do: @pages

  @doc """
  The table of contents for `lang`: `[%{section: Page.t(), pages: [Page.t()]}]`
  in order.
  """
  @spec tree(String.t()) :: [%{section: Page.t(), pages: [Page.t()]}]
  def tree(lang) do
    lang = normalize(lang)

    {sections, pages} =
      @pages |> Enum.filter(&(&1.lang == lang)) |> Enum.split_with(&(&1.kind == :section))

    Enum.map(sections, fn section ->
      %{section: section, pages: Enum.filter(pages, &(&1.section == section.section))}
    end)
  end

  @doc """
  The page (or section) at `path` in `lang`: `{:ok, page, fallback?}`, where
  `fallback?` means it was only found in another language.
  """
  @spec get(String.t(), String.t()) :: {:ok, Page.t(), boolean()} | :error
  def get(lang, path) do
    lang = normalize(lang)

    case find(lang, path) do
      nil ->
        case Enum.find_value(@languages -- [lang], &find(&1, path)) do
          nil -> :error
          page -> {:ok, page, true}
        end

      page ->
        {:ok, page, false}
    end
  end

  @doc "The pages before and after `path` in reading order (sections excluded)."
  @spec prev_next(String.t(), String.t()) :: {Page.t() | nil, Page.t() | nil}
  def prev_next(lang, path) do
    pages = lang |> tree() |> Enum.flat_map(& &1.pages)

    case Enum.find_index(pages, &(&1.path == path)) do
      nil -> {nil, nil}
      index -> {if(index > 0, do: Enum.at(pages, index - 1)), Enum.at(pages, index + 1)}
    end
  end

  defp find(lang, path), do: Enum.find(@pages, &(&1.lang == lang and &1.path == path))

  defp normalize(lang) when lang in @languages, do: lang
  defp normalize(_lang), do: hd(@languages)
end
