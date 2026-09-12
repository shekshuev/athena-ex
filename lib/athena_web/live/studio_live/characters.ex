defmodule AthenaWeb.StudioLive.Characters do
  @moduledoc """
  LiveView for managing reusable storytelling Characters (name + avatar),
  scoped to the current teacher via the `own_only` ACL policy.
  """
  use AthenaWeb, :live_view

  alias Athena.Content
  alias Athena.Content.Character
  alias Athena.Identity
  alias Athena.Media
  alias AthenaWeb.StudioLive.{AvatarUploadComponent, CharacterFormComponent}

  on_mount {AthenaWeb.Hooks.Permission, "characters.read"}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Characters"))
     |> assign(character_to_delete: nil)
     |> stream(:characters, [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    search = Map.get(params, "search", "")

    flop_params =
      if search != "" do
        Map.put(params, "filters", %{
          "0" => %{"field" => "name", "op" => "ilike_and", "value" => search}
        })
      else
        params
      end

    case Content.list_characters(socket.assigns.current_user, flop_params) do
      {:ok, {characters, meta}} ->
        socket =
          socket
          |> assign(meta: meta, search: search)
          |> stream(:characters, characters, reset: true)
          |> apply_action(socket.assigns.live_action, params)

        {:noreply, socket}

      {:error, _meta} ->
        {:noreply, push_patch(socket, to: ~p"/studio/characters")}
    end
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, character: nil)
  end

  defp apply_action(socket, :new, _params) do
    assign(socket, character: %Character{})
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Content.get_character(socket.assigns.current_user, id) do
      {:ok, character} ->
        assign(socket, character: character)

      _ ->
        socket
        |> put_flash(:error, gettext("Character not found or access denied."))
        |> push_patch(to: ~p"/studio/characters")
    end
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    params = build_query_params(socket.assigns, %{"search" => search, "page" => 1})
    {:noreply, push_patch(socket, to: ~p"/studio/characters?#{params}")}
  end

  def handle_event("update_page_size", %{"page_size" => size}, socket) do
    params = build_query_params(socket.assigns, %{"page_size" => size, "page" => 1})
    {:noreply, push_patch(socket, to: ~p"/studio/characters?#{params}")}
  end

  def handle_event("delete_click", %{"id" => id}, socket) do
    case Content.get_character(socket.assigns.current_user, id) do
      {:ok, character} -> {:noreply, assign(socket, character_to_delete: character)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("confirm_delete", _, %{assigns: %{character_to_delete: character}} = socket) do
    case Content.delete_character(socket.assigns.current_user, character) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Character deleted successfully"))
         |> stream_delete(:characters, character)
         |> assign(character_to_delete: nil)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to delete character"))}
    end
  end

  def handle_event("cancel_delete", _, socket) do
    {:noreply, assign(socket, character_to_delete: nil)}
  end

  @impl true
  def handle_info({CharacterFormComponent, {:saved, character}}, socket) do
    {:noreply, stream_insert(socket, :characters, character)}
  end

  def handle_info({AvatarUploadComponent, {:uploaded, %{id: file_id, url: url}}}, socket) do
    send_update(CharacterFormComponent,
      id: form_id(socket),
      avatar_file_id: file_id,
      avatar_url: url
    )

    {:noreply, socket}
  end

  def handle_info({AvatarUploadComponent, :removed}, socket) do
    send_update(CharacterFormComponent, id: form_id(socket), avatar_file_id: nil, avatar_url: nil)
    {:noreply, socket}
  end

  defp form_id(socket), do: socket.assigns.character.id || :new

  defp avatar_url(nil), do: nil
  defp avatar_url(file_id), do: with(%{key: key} <- Media.get_file(file_id), do: "/media/#{key}")

  defp fallback_letter(name),
    do: name |> String.trim() |> String.first() |> to_string() |> String.upcase()

  @doc false
  defp build_query_params(assigns, overrides) do
    meta = assigns.meta

    order_by =
      meta.flop.order_by
      |> List.wrap()
      |> Enum.map(&to_string/1)

    order_directions =
      meta.flop.order_directions
      |> List.wrap()
      |> Enum.map(&to_string/1)

    %{
      "search" => assigns.search,
      "page" => meta.current_page,
      "page_size" => meta.page_size,
      "order_by" => order_by,
      "order_directions" => order_directions
    }
    |> Map.merge(overrides)
    |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" or v == [] end)
    |> Map.new()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_container size="wide" class="space-y-6">
      <div class="flex justify-between items-center">
        <div>
          <h1 class="text-2xl font-display font-bold text-base-content">{@page_title}</h1>
          <p class="text-base-content/60">
            {gettext("Reusable characters (name + avatar) for storytelling dialogue blocks.")}
          </p>
        </div>

        <.button
          :if={Identity.can?(@current_user, "characters.create")}
          patch={~p"/studio/characters/new?#{build_query_params(assigns, %{})}"}
          class="btn btn-primary"
        >
          <.icon name="hero-plus" class="size-5" />
          <span class="hidden sm:inline">{gettext("Create Character")}</span>
          <span class="sm:hidden">{gettext("Create")}</span>
        </.button>
      </div>

      <div class="flex gap-4">
        <.form for={nil} phx-change="search" phx-submit="search" class="w-full max-w-sm">
          <div class="relative">
            <.icon
              name="hero-magnifying-glass"
              class="absolute left-3 top-3.5 size-5 text-base-content/50 z-10"
            />
            <.input
              type="text"
              name="search"
              value={@search}
              placeholder={gettext("Search characters...")}
              class="input input-bordered w-full pl-10"
              phx-debounce="500"
            />
          </div>
        </.form>
      </div>

      <% path_fn = fn overrides ->
        ~p"/studio/characters?#{build_query_params(assigns, overrides)}"
      end %>

      <.table id="characters" rows={@streams.characters} meta={@meta} path_fn={path_fn}>
        <:col :let={{_id, character}} label={gettext("Name")} sort="name">
          <div class="flex items-center gap-3">
            <div class="avatar placeholder shrink-0">
              <div class="bg-neutral text-neutral-content w-8 rounded-full flex items-center justify-center">
                <img
                  :if={avatar_url(character.avatar_file_id)}
                  src={avatar_url(character.avatar_file_id)}
                  alt=""
                />
                <span :if={!avatar_url(character.avatar_file_id)} class="leading-none text-xs">
                  {fallback_letter(character.name)}
                </span>
              </div>
            </div>
            <span class="font-bold">{character.name}</span>
          </div>
        </:col>

        <:col :let={{_id, character}} label={gettext("Created At")} sort="inserted_at">
          <span class="text-sm opacity-60">
            {Calendar.strftime(character.inserted_at, "%d.%m.%Y")}
          </span>
        </:col>

        <:action :let={{_id, character}}>
          <div class="flex justify-end gap-2">
            <.icon_button
              patch={~p"/studio/characters/#{character.id}/edit?#{build_query_params(assigns, %{})}"}
              icon="hero-pencil-square"
              label={gettext("Edit")}
            />
            <.icon_button
              type="button"
              phx-click="delete_click"
              phx-value-id={character.id}
              icon="hero-trash"
              label={gettext("Delete")}
              variant="danger"
            />
          </div>
        </:action>
      </.table>

      <.empty_state
        :if={@meta.total_count == 0}
        icon="hero-user-group"
        title={gettext("No characters yet")}
        description={gettext("Create one to get started.")}
      />

      <div class="flex justify-end">
        <.pagination meta={@meta} path_fn={path_fn} />
      </div>

      <.slide_over
        id="character-slideover"
        show={@live_action in [:new, :edit]}
        title={
          if(@live_action == :new, do: gettext("Create Character"), else: gettext("Edit Character"))
        }
        on_close={JS.patch(~p"/studio/characters?#{build_query_params(assigns, %{})}")}
      >
        <.live_component
          :if={@character}
          module={CharacterFormComponent}
          id={@character.id || :new}
          action={@live_action}
          character={@character}
          current_user={@current_user}
          patch={~p"/studio/characters?#{build_query_params(assigns, %{})}"}
        />
      </.slide_over>

      <.modal
        id="delete-character-modal"
        show={@character_to_delete != nil}
        title={gettext("Delete Character")}
        description={
          gettext(
            "Are you sure you want to permanently delete this character? This action cannot be undone."
          )
        }
        confirm_label={gettext("Delete")}
        danger={true}
        on_cancel={JS.push("cancel_delete")}
        on_confirm={JS.push("confirm_delete")}
      />
    </.page_container>
    """
  end
end
