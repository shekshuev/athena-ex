defmodule AthenaWeb.AnnouncementLive.Index do
  @moduledoc """
  Personal announcements feed: every authenticated account sees global
  announcements plus announcements for any cohort they're a member of, in
  reverse-chronological order. Like `AthenaWeb.FileLive.Index`, access
  does not depend on any `announcements.*` permission — this is a plain
  read surface, not a management page.
  """
  use AthenaWeb, :live_view

  alias Athena.{Announcements, Learning}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, stream(socket, :announcements, [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    case Announcements.list_for_viewer(socket.assigns.current_user, params) do
      {:ok, {announcements, meta}} ->
        cohorts =
          announcements
          |> Enum.map(& &1.cohort_id)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
          |> Learning.get_cohorts_map()

        {:noreply,
         socket
         |> assign(meta: meta, cohorts: cohorts)
         |> stream(:announcements, announcements, reset: true)}

      {:error, _meta} ->
        {:noreply, push_patch(socket, to: ~p"/announcements")}
    end
  end

  @impl true
  def handle_event("update_page_size", %{"page_size" => size}, socket) do
    params = build_query_params(socket.assigns, %{"page_size" => size, "page" => 1})
    {:noreply, push_patch(socket, to: ~p"/announcements?#{params}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_container size="standard" class="space-y-6">
      <div>
        <h1 class="text-2xl font-display font-bold text-base-content">{gettext("Announcements")}</h1>
        <p class="text-base-content/60">{gettext("News and updates for you.")}</p>
      </div>

      <% path_fn = fn overrides -> ~p"/announcements?#{build_query_params(assigns, overrides)}" end %>

      <div id="announcements-feed" phx-update="stream" class="space-y-4">
        <div
          :for={{dom_id, a} <- @streams.announcements}
          id={dom_id}
          class="bg-base-100 border border-base-300 rounded-lg p-5 space-y-2"
        >
          <div class="flex items-start justify-between gap-4">
            <h3 class="font-display font-bold text-lg text-base-content">{a.title}</h3>
            <.badge tone={if a.scope == :global, do: "primary", else: "neutral"} class="shrink-0">
              {if a.scope == :global, do: gettext("Global"), else: cohort_name(@cohorts, a.cohort_id)}
            </.badge>
          </div>
          <p class="text-sm text-base-content/50">{Calendar.strftime(a.inserted_at, "%d.%m.%Y")}</p>
          <p class="text-base-content/80 whitespace-pre-wrap">{a.body}</p>
        </div>
      </div>

      <.empty_state
        :if={@meta.total_count == 0}
        icon="hero-megaphone"
        title={gettext("No announcements yet")}
        description={gettext("Check back later for news and updates.")}
      />

      <div class="flex justify-end">
        <.pagination meta={@meta} path_fn={path_fn} />
      </div>
    </.page_container>
    """
  end

  defp cohort_name(cohorts, cohort_id) do
    case Map.get(cohorts, cohort_id) do
      nil -> "—"
      cohort -> cohort.name
    end
  end

  @doc false
  defp build_query_params(assigns, overrides) do
    meta = assigns.meta

    %{
      "page" => meta.current_page,
      "page_size" => meta.page_size
    }
    |> Map.merge(overrides)
    |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" or v == [] end)
    |> Map.new()
  end
end
