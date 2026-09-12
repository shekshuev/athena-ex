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
     |> assign(has_characters: false)
     |> stream(:characters, [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, socket |> apply_action(socket.assigns.live_action, params) |> load_characters()}
  end

  defp load_characters(socket) do
    case Content.list_characters(socket.assigns.current_user, %{}) do
      {:ok, {characters, _meta}} ->
        socket
        |> assign(has_characters: characters != [])
        |> stream(:characters, characters, reset: true)

      {:error, _meta} ->
        socket
        |> assign(has_characters: false)
        |> stream(:characters, [], reset: true)
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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex justify-between items-center">
        <div>
          <h1 class="text-2xl font-display font-bold text-base-content">{@page_title}</h1>
          <p class="text-base-content/60">
            {gettext("Reusable characters (name + avatar) for storytelling dialogue blocks.")}
          </p>
        </div>

        <.button
          :if={Identity.can?(@current_user, "characters.create")}
          patch={~p"/studio/characters/new"}
          class="btn btn-primary"
        >
          <.icon name="hero-plus" class="size-5" />
          <span class="hidden sm:inline">{gettext("Create Character")}</span>
          <span class="sm:hidden">{gettext("Create")}</span>
        </.button>
      </div>

      <div
        :if={not @has_characters}
        class="text-center py-24 px-6 border border-dashed border-base-300 rounded-box mt-4"
      >
        <.icon name="hero-user-group" class="size-16 text-base-content/20 mb-4 mx-auto" />
        <h3 class="text-xl font-bold text-base-content">{gettext("No characters yet")}</h3>
        <p class="text-base-content/60 mt-2 max-w-sm mx-auto text-sm">
          {gettext("Create a character to use it in dialogue blocks.")}
        </p>
      </div>

      <div
        :if={@has_characters}
        id="characters-list"
        phx-update="stream"
        class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4"
      >
        <div
          :for={{dom_id, character} <- @streams.characters}
          id={dom_id}
          class="flex items-center gap-4 p-4 bg-base-100 border border-base-200 rounded-box"
        >
          <div class="avatar placeholder shrink-0">
            <div class="bg-neutral text-neutral-content w-12 rounded-full flex items-center justify-center">
              <img
                :if={avatar_url(character.avatar_file_id)}
                src={avatar_url(character.avatar_file_id)}
                alt=""
              />
              <span :if={!avatar_url(character.avatar_file_id)} class="leading-none">
                {fallback_letter(character.name)}
              </span>
            </div>
          </div>

          <div class="flex-1 min-w-0">
            <div class="font-bold truncate">{character.name}</div>
            <div class="text-xs text-base-content/50">
              {Calendar.strftime(character.inserted_at, "%d.%m.%Y")}
            </div>
          </div>

          <div class="flex gap-1 shrink-0">
            <.button
              patch={~p"/studio/characters/#{character.id}/edit"}
              class="btn btn-ghost btn-xs btn-square"
              title={gettext("Edit")}
            >
              <.icon name="hero-pencil-square" class="size-4" />
            </.button>
            <.button
              type="button"
              phx-click="delete_click"
              phx-value-id={character.id}
              class="btn btn-ghost btn-xs btn-square text-error hover:bg-error/10"
              title={gettext("Delete")}
            >
              <.icon name="hero-trash" class="size-4" />
            </.button>
          </div>
        </div>
      </div>

      <.slide_over
        id="character-slideover"
        show={@live_action in [:new, :edit]}
        title={
          if(@live_action == :new, do: gettext("Create Character"), else: gettext("Edit Character"))
        }
        on_close={JS.patch(~p"/studio/characters")}
      >
        <.live_component
          :if={@character}
          module={CharacterFormComponent}
          id={@character.id || :new}
          action={@live_action}
          character={@character}
          current_user={@current_user}
          patch={~p"/studio/characters"}
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
    </div>
    """
  end
end
