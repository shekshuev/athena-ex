defmodule AthenaWeb.SearchLive do
  @moduledoc "An isolated search palette; opening it never remounts the course player."
  use AthenaWeb, :live_view

  on_mount {AthenaWeb.Hooks.Auth, :default}
  on_mount {AthenaWeb.Hooks.Auth, :require_authenticated_user}
  on_mount {AthenaWeb.Hooks.Auth, :ensure_password_changed}

  alias Athena.Content

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        open?: false,
        generation: 0,
        query: "",
        status: :initial,
        result_count: 0,
        cursor: nil,
        more_error?: false,
        form: to_form(%{"query" => ""}, as: :search)
      )
      |> stream_configure(:results, dom_id: &"global-search-result-#{&1.block_id}")
      |> stream(:results, [])

    {:ok, socket, layout: false}
  end

  @impl true
  def handle_event("open", _, socket) do
    {:noreply, socket |> assign(:open?, true) |> push_event("search:open", %{})}
  end

  def handle_event("close", _, socket) do
    {:noreply,
     socket
     |> invalidate()
     |> assign(
       open?: false,
       query: "",
       status: :initial,
       cursor: nil,
       result_count: 0,
       more_error?: false,
       form: to_form(%{"query" => ""}, as: :search)
     )
     |> stream(:results, [], reset: true)
     |> push_event("search:close", %{})}
  end

  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    if socket.assigns.open? do
      socket =
        socket
        |> invalidate()
        |> assign(
          query: query,
          form: to_form(%{"query" => query}, as: :search),
          result_count: 0,
          cursor: nil,
          more_error?: false
        )
        |> stream(:results, [], reset: true)

      socket =
        if valid_query?(query) do
          run_search(assign(socket, :status, :loading), nil)
        else
          assign(socket, :status, invalid_query_status(query))
        end

      {:noreply, push_event(socket, "search:updated", %{})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("more", _, socket) do
    if socket.assigns.open? && socket.assigns.cursor && socket.assigns.status == :ready do
      {:noreply,
       socket
       |> invalidate()
       |> assign(status: :loading_more, more_error?: false)
       |> run_search(socket.assigns.cursor)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_async({:search, generation, mode}, result, socket) do
    if socket.assigns.open? && generation == socket.assigns.generation do
      socket = apply_result(socket, result, mode)
      {:noreply, push_event(socket, "search:updated", %{})}
    else
      {:noreply, socket}
    end
  end

  defp run_search(socket, cursor) do
    user = socket.assigns.current_user
    query = socket.assigns.query
    mode = if cursor, do: :more, else: :replace
    name = {:search, socket.assigns.generation, mode}
    start_async(socket, name, fn -> Content.search_blocks(user, query, cursor: cursor) end)
  end

  defp invalidate(socket) do
    generation = socket.assigns.generation

    socket
    |> cancel_async({:search, generation, :replace})
    |> cancel_async({:search, generation, :more})
    |> assign(:generation, generation + 1)
  end

  defp apply_result(socket, {:ok, {:ok, page}}, mode) do
    count = if mode == :more, do: socket.assigns.result_count, else: 0

    socket
    |> stream(:results, page.items, reset: mode == :replace)
    |> assign(
      status: :ready,
      result_count: count + length(page.items),
      cursor: page.next_cursor,
      more_error?: false
    )
  end

  defp apply_result(socket, _error, :more),
    do: assign(socket, status: :ready, more_error?: true)

  defp apply_result(socket, _error, :replace),
    do: assign(socket, status: :error, cursor: nil, result_count: 0)

  defp invalid_query_status(query) do
    if String.trim(query) == "", do: :initial, else: :hint
  end

  defp valid_query?(query) do
    byte_size(query) <= 800 && String.valid?(query) &&
      String.length(String.trim(query)) in 3..200 && Regex.match?(~r/[\p{L}\p{N}]{3}/u, query)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} embedded>
      <div id="global-search-shell">
        <span id="global-search-controller" phx-hook="GlobalSearch" phx-update="ignore"></span>
        <button
          id="global-search-open"
          type="button"
          phx-click="open"
          aria-haspopup="dialog"
          aria-controls="global-search-dialog"
          aria-label={gettext("Search learning materials")}
          aria-keyshortcuts="Control+k Meta+k"
          title={gettext("Search learning materials")}
          class="inline-flex size-11 items-center justify-center rounded-sm text-base-content/70 transition-colors hover:bg-base-200 hover:text-primary focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
        >
          <.icon name="hero-magnifying-glass" class="size-5" />
        </button>

        <dialog
          id="global-search-dialog"
          class="search-palette"
          aria-labelledby="global-search-title"
          aria-describedby="global-search-description"
          aria-modal="true"
          data-open={to_string(@open?)}
          data-query={@query}
          data-status={@status}
          phx-mounted={JS.ignore_attributes(["open", "data-typing"])}
        >
          <div class="search-palette-accent"></div>
          <div class="flex items-center justify-between gap-4 px-5 pb-1 pt-5 sm:px-6">
            <div>
              <h2
                id="global-search-title"
                class="font-display text-xs font-black uppercase tracking-[0.18em] text-primary"
              >
                {gettext("Search materials")}
              </h2>
              <p id="global-search-description" class="mt-1 text-xs text-base-content/60">
                {gettext("Across all your available courses")}
              </p>
            </div>
            <button
              id="global-search-close"
              type="button"
              phx-click="close"
              class="flex size-11 shrink-0 items-center justify-center rounded-sm text-base-content/40 transition hover:bg-base-200 hover:text-base-content focus-visible:outline-2 focus-visible:outline-primary"
              aria-label={gettext("Close search")}
            >
              <.icon name="hero-x-mark" class="size-5" />
            </button>
          </div>

          <.form
            for={@form}
            id="global-search-form"
            phx-change="search"
            phx-submit="search"
            class="search-palette-form flex items-center gap-3 border-b border-base-300 px-5 py-4 sm:px-6"
          >
            <.icon name="hero-magnifying-glass" class="size-6 shrink-0 text-primary" />
            <.input
              field={@form[:query]}
              id="global-search-input"
              type="search"
              autocomplete="off"
              maxlength="200"
              phx-debounce="500"
              placeholder={gettext("Find a topic, a task, a line of code…")}
              aria-label={gettext("Search learning materials")}
              role="combobox"
              aria-controls="global-search-results"
              aria-autocomplete="list"
              aria-expanded={to_string(@open?)}
              aria-describedby="global-search-input-help"
              phx-mounted={JS.ignore_attributes("aria-activedescendant")}
              class="w-full min-w-0 border-0 bg-transparent py-1 font-display text-lg font-medium text-base-content outline-none placeholder:text-base-content/35 sm:text-xl"
            />
            <span id="global-search-input-help" class="sr-only">
              {gettext("Enter at least three characters to find learning materials in your courses.")}
            </span>
            <kbd class="hidden shrink-0 rounded-xs border border-base-300 px-1.5 py-1 font-mono text-[10px] text-base-content/40 sm:inline">
              Esc
            </kbd>
          </.form>

          <div class="search-palette-body">
            <div class="search-typing-state search-palette-message" role="status">
              <.icon name="hero-arrow-path" class="size-5 text-primary motion-safe:animate-spin" />
              <span>{gettext("Searching materials…")}</span>
            </div>
            <div class="search-server-state">
              <div
                :if={@status in [:initial, :hint]}
                id="global-search-hint"
                class="search-palette-message"
              >
                <div class="flex size-12 items-center justify-center rounded-sm border border-primary/15 bg-primary/5 text-primary">
                  <.icon name="hero-book-open" class="size-6" />
                </div>
                <p class="font-display text-base font-bold text-base-content/80">
                  {gettext("What would you like to find?")}
                </p>
                <p class="max-w-xs text-center text-sm leading-relaxed text-base-content/60">
                  {gettext(
                    "Enter at least three characters to find learning materials in your courses."
                  )}
                </p>
              </div>
              <div
                :if={@status == :loading}
                id="global-search-loading"
                class="search-palette-message"
                role="status"
              >
                <.icon name="hero-arrow-path" class="size-5 text-primary motion-safe:animate-spin" />
                <span>{gettext("Searching materials…")}</span>
              </div>
              <div
                :if={@status == :ready && @result_count == 0}
                id="global-search-empty"
                class="search-palette-message"
                role="status"
              >
                <.icon name="hero-magnifying-glass" class="size-8 text-base-content/25" />
                <p class="font-display text-base font-bold">{gettext("No materials found")}</p>
                <p class="max-w-xs text-center text-sm text-base-content/60">
                  {gettext("Try another phrase or check the spelling.")}
                </p>
              </div>
              <div
                :if={@status == :error}
                id="global-search-error"
                class="search-palette-message"
                role="alert"
              >
                <.icon name="hero-exclamation-circle" class="size-7 text-error" />
                <p class="font-display text-base font-bold">
                  {gettext("Search is temporarily unavailable")}
                </p>
                <p class="text-sm text-base-content/60">{gettext("Please try again.")}</p>
                <button
                  id="global-search-retry"
                  type="submit"
                  form="global-search-form"
                  class="search-palette-action"
                >
                  {gettext("Try again")}
                </button>
              </div>
              <div
                :if={@result_count > 0}
                id="global-search-summary"
                class="flex items-center justify-between px-5 pb-1 pt-4 text-[10px] font-bold uppercase tracking-widest text-base-content/40 sm:px-6"
                role="status"
              >
                <span>{gettext("Materials")}</span><span>{@result_count}</span>
              </div>
              <div
                id="global-search-results"
                phx-update="stream"
                role="listbox"
                aria-label={gettext("Search results")}
                class="px-2 pb-2 sm:px-3"
              >
                <.link
                  :for={{dom_id, result} <- @streams.results}
                  id={dom_id}
                  navigate={~p"/go/blocks/#{result.block_id}"}
                  role="option"
                  aria-selected="false"
                  data-search-result
                  data-block-id={result.block_id}
                  class="search-palette-result group flex gap-3 rounded-sm border border-transparent px-3 py-4 outline-none transition-colors sm:px-3"
                >
                  <div class="mt-0.5 flex size-9 shrink-0 items-center justify-center rounded-sm border border-base-300 bg-base-200/60 text-base-content/40 group-hover:text-primary">
                    <.icon name="hero-document-text" class="size-4" />
                  </div>
                  <div class="min-w-0 flex-1">
                    <div class="mb-1 flex min-w-0 items-center gap-1.5 text-[11px] text-base-content/60">
                      <span class="truncate">{result.course_title}</span>
                      <.icon name="hero-chevron-right" class="size-2.5 shrink-0" />
                      <span class="truncate">{result.section_title}</span>
                    </div>
                    <p class="line-clamp-2 break-words font-display text-sm font-bold text-base-content sm:line-clamp-none sm:truncate">
                      {result.title}
                    </p>
                    <p
                      phx-no-format
                      class="mt-1.5 line-clamp-3 whitespace-pre-wrap break-words text-[13px] leading-relaxed text-base-content/65"
                    ><%= for segment <- result.snippet do %><mark :if={segment.match?} class="rounded-xs bg-primary/12 px-0.5 text-primary">{segment.text}</mark><span :if={!segment.match?}>{segment.text}</span><% end %></p>
                  </div>
                  <.icon name="hero-arrow-up-right" class="mt-1 size-4 shrink-0 text-base-content/20" />
                </.link>
              </div>
              <div :if={@cursor} class="border-t border-base-300/60 px-5 py-3 sm:px-6">
                <p
                  :if={@more_error?}
                  id="global-search-more-error"
                  role="alert"
                  class="mb-2 text-xs text-error"
                >
                  {gettext("Could not load more results. Try again.")}
                </p>
                <button
                  id="global-search-more"
                  type="button"
                  phx-click="more"
                  disabled={@status == :loading_more}
                  class="search-palette-action w-full disabled:cursor-wait disabled:opacity-50"
                >
                  <.icon
                    :if={@status == :loading_more}
                    name="hero-arrow-path"
                    class="size-3.5 motion-safe:animate-spin"
                  />
                  {if @status == :loading_more, do: gettext("Loading…"), else: gettext("Show more")}
                </button>
              </div>
            </div>
          </div>
          <footer class="flex flex-wrap items-center justify-between gap-2 border-t border-base-300 bg-base-200/40 px-5 py-3 text-[10px] text-base-content/40 sm:px-6">
            <span class="flex items-center gap-3">
              <span>↑ ↓ {gettext("Navigate")}</span><span>↵ {gettext("Open")}</span><span>Esc {gettext("Close")}</span>
            </span>
            <span class="font-display font-black tracking-widest text-base-content/25">ATHENA</span>
          </footer>
        </dialog>
      </div>
    </Layouts.app>
    """
  end
end
