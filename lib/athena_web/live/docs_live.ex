defmodule AthenaWeb.DocsLive do
  @moduledoc """
  The built-in documentation reader (`/docs`, `/docs/<section>/<page>`), laid
  out like a documentation site: the table of contents on the left, the page
  in the middle, "On this page" on the right.

  Pages come from `AthenaWeb.Docs` (compiled markdown) in the interface
  language; a page that exists only in the other language is shown with a
  notice. Requires `docs.read` (admins always pass).
  """
  use AthenaWeb, :live_view

  alias AthenaWeb.Docs

  on_mount {AthenaWeb.Hooks.Permission, "docs.read"}

  @impl true
  def mount(_params, _session, socket) do
    lang = Gettext.get_locale(AthenaWeb.Gettext)

    {:ok,
     socket
     |> assign(:lang, lang)
     |> assign(:tree, Docs.tree(lang))
     |> assign(:query, "")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    case params |> Map.get("path", []) |> List.wrap() |> Enum.join("/") do
      "" ->
        {:noreply,
         socket
         |> assign(:page, nil)
         |> assign(:page_title, gettext("Documentation"))}

      path ->
        open_page(socket, path)
    end
  end

  defp open_page(socket, path) do
    case Docs.get(socket.assigns.lang, path) do
      {:ok, page, fallback?} ->
        {prev, next} = Docs.prev_next(socket.assigns.lang, page.path)

        {:noreply,
         socket
         |> assign(:page, page)
         |> assign(:fallback?, fallback?)
         |> assign(:prev, prev)
         |> assign(:next, next)
         |> assign(:section, section_of(socket.assigns.tree, page.section))
         |> assign(:page_title, page.title)}

      :error ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("This documentation page doesn't exist."))
         |> push_navigate(to: ~p"/docs")}
    end
  end

  defp section_of(tree, section), do: Enum.find(tree, &(&1.section.section == section))

  @impl true
  def handle_event("filter", %{"query" => query}, socket),
    do: {:noreply, assign(socket, :query, query)}

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :visible_tree, filter_tree(assigns.tree, assigns.query))

    ~H"""
    <div id="docs" class="docs-layout">
      <aside id="docs-nav" class="docs-nav" aria-label={gettext("Documentation contents")}>
        <.link navigate={~p"/docs"} class="docs-nav-home">
          <.icon name="hero-book-open" class="size-5" /> {gettext("Documentation")}
        </.link>
        <form phx-change="filter" phx-submit="filter" class="mb-4">
          <input
            id="docs-filter"
            type="search"
            name="query"
            value={@query}
            phx-debounce="150"
            autocomplete="off"
            placeholder={gettext("Filter pages")}
            class="input input-sm w-full"
          />
        </form>
        <nav class="space-y-4">
          <div :for={%{section: section, pages: pages} <- @visible_tree}>
            <.link
              navigate={~p"/docs/#{String.split(section.path, "/")}"}
              class={["docs-nav-section", current?(assigns, section) && "is-active"]}
            >
              {section.title}
            </.link>
            <ul class="mt-1 space-y-0.5">
              <li :for={page <- pages}>
                <.link
                  id={"docs-nav-#{String.replace(page.path, "/", "-")}"}
                  navigate={~p"/docs/#{String.split(page.path, "/")}"}
                  class={["docs-nav-link", current?(assigns, page) && "is-active"]}
                >
                  {page.title}
                </.link>
              </li>
            </ul>
          </div>
          <p :if={@visible_tree == []} class="text-sm text-base-content/50">
            {gettext("Nothing found.")}
          </p>
        </nav>
      </aside>

      <main class="docs-main">
        <%= if @page do %>
          <.page_view {assigns} />
        <% else %>
          <.home tree={@tree} />
        <% end %>
      </main>

      <aside
        :if={@page && @page.headings != []}
        id="docs-toc"
        class="docs-toc"
        aria-label={gettext("On this page")}
      >
        <p class="docs-toc-title">{gettext("On this page")}</p>
        <ul class="space-y-1">
          <li :for={heading <- @page.headings} class={heading.level == 3 && "pl-3"}>
            <a href={"##{heading.id}"} class="docs-toc-link">{heading.text}</a>
          </li>
        </ul>
      </aside>
    </div>
    """
  end

  defp page_view(assigns) do
    ~H"""
    <nav class="docs-breadcrumbs" aria-label={gettext("Breadcrumbs")}>
      <.link navigate={~p"/docs"}>{gettext("Documentation")}</.link>
      <%= if @section && @page.kind == :page do %>
        <.icon name="hero-chevron-right-mini" class="size-4 opacity-50" />
        <.link navigate={~p"/docs/#{@section.section.path}"}>{@section.section.title}</.link>
      <% end %>
    </nav>

    <header class="mb-8">
      <h1 id="docs-title" class="docs-title">{@page.title}</h1>
      <p :if={@page.description} class="docs-lead">{@page.description}</p>
    </header>

    <div :if={@fallback?} id="docs-fallback" class="docs-callout docs-callout--warning mb-6">
      <.icon name="hero-language" class="size-5 shrink-0" />
      <span>
        {gettext("This page hasn't been translated yet - it is shown in another language.")}
      </span>
    </div>

    <div :if={@page.stub?} id="docs-stub" class="docs-callout docs-callout--note mb-6">
      <.icon name="hero-pencil-square" class="size-5 shrink-0" />
      <span>{gettext("This section is being written.")}</span>
    </div>

    <article id="docs-article" class="prose docs-prose">
      {raw(@page.body)}
    </article>

    <ul :if={@page.kind == :section && @section} id="docs-section-pages" class="docs-cards mt-8">
      <li :for={page <- @section.pages}>
        <.link navigate={~p"/docs/#{String.split(page.path, "/")}"} class="docs-card">
          <span class="docs-card-title">{page.title}</span>
          <span :if={page.description} class="docs-card-text">{page.description}</span>
        </.link>
      </li>
    </ul>

    <nav
      :if={@page.kind == :page and (@prev || @next)}
      id="docs-pager"
      class="docs-pager"
      aria-label={gettext("Pages")}
    >
      <.link
        :if={@prev}
        navigate={~p"/docs/#{String.split(@prev.path, "/")}"}
        class="docs-pager-link"
      >
        <span class="docs-pager-hint">{gettext("Previous")}</span>
        <span class="docs-pager-title">{@prev.title}</span>
      </.link>
      <.link
        :if={@next}
        navigate={~p"/docs/#{String.split(@next.path, "/")}"}
        class="docs-pager-link text-right ml-auto"
      >
        <span class="docs-pager-hint">{gettext("Next")}</span>
        <span class="docs-pager-title">{@next.title}</span>
      </.link>
    </nav>
    """
  end

  attr :tree, :list, required: true

  defp home(assigns) do
    ~H"""
    <header class="mb-8">
      <h1 id="docs-title" class="docs-title">{gettext("Documentation")}</h1>
      <p class="docs-lead">
        {gettext("How Athena works and where to find everything in it.")}
      </p>
    </header>
    <ul id="docs-home" class="docs-cards">
      <li :for={%{section: section} <- @tree}>
        <.link navigate={~p"/docs/#{section.path}"} class="docs-card">
          <span class="docs-card-title">{section.title}</span>
          <span :if={section.description} class="docs-card-text">{section.description}</span>
        </.link>
      </li>
    </ul>
    """
  end

  defp current?(%{page: %{path: path}}, %{path: path}), do: true
  defp current?(_assigns, _page), do: false

  defp filter_tree(tree, query) do
    case query |> String.trim() |> String.downcase() do
      "" ->
        tree

      needle ->
        for %{section: section, pages: pages} <- tree,
            matching = Enum.filter(pages, &String.contains?(String.downcase(&1.title), needle)),
            matching != [] or String.contains?(String.downcase(section.title), needle),
            do: %{section: section, pages: matching}
    end
  end
end
