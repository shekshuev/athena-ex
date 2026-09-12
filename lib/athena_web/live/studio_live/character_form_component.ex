defmodule AthenaWeb.StudioLive.CharacterFormComponent do
  @moduledoc """
  A LiveComponent for creating and editing storytelling Characters
  (name + avatar) used by dialogue blocks.
  """
  use AthenaWeb, :live_component

  alias Athena.{Content, Media}
  alias Athena.Content.Character
  alias AthenaWeb.StudioLive.AvatarUploadComponent

  @impl true
  def update(%{character: character} = assigns, socket) do
    changeset = Character.changeset(character, %{})

    {:ok,
     socket
     |> assign(:patch, nil)
     |> assign(:on_cancel, nil)
     |> assign(assigns)
     |> assign(:form, to_form(changeset))
     |> assign(:avatar_file_id, character.avatar_file_id)
     |> assign(:avatar_url, avatar_url(character.avatar_file_id))}
  end

  # Targeted refresh pushed via `send_update/2` from the parent LiveView after
  # the nested AvatarUploadComponent reports a new/removed avatar — messages
  # sent from a LiveComponent land in the parent LiveView's mailbox, not here.
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("validate", %{"character" => params}, socket) do
    changeset =
      socket.assigns.character
      |> Character.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"character" => params}, socket) do
    params = Map.put(params, "avatar_file_id", socket.assigns.avatar_file_id)

    params =
      if socket.assigns.action == :new,
        do: Map.put(params, "owner_id", socket.assigns.current_user.id),
        else: params

    save_character(socket, socket.assigns.action, params)
  end

  defp save_character(socket, :edit, params) do
    case Content.update_character(socket.assigns.current_user, socket.assigns.character, params) do
      {:ok, character} ->
        notify_parent({:saved, character})

        {:noreply,
         socket |> put_flash(:info, gettext("Character updated successfully")) |> close()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_character(socket, :new, params) do
    case Content.create_character(socket.assigns.current_user, params) do
      {:ok, character} ->
        notify_parent({:saved, character})

        {:noreply,
         socket |> put_flash(:info, gettext("Character created successfully")) |> close()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})

  # Navigates back on the dedicated Studio → Characters page (`patch` set);
  # when embedded as a modal elsewhere (e.g. the course builder), the parent
  # LiveView is responsible for closing it after receiving `{:saved, _}`.
  defp close(socket) do
    case socket.assigns[:patch] do
      nil -> socket
      patch -> push_patch(socket, to: patch)
    end
  end

  defp avatar_url(nil), do: nil

  defp avatar_url(file_id) do
    case Media.get_file(file_id) do
      nil -> nil
      file -> "/media/#{file.key}"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-full flex flex-col">
      <div class="flex-1 overflow-y-auto p-6 space-y-6">
        <div class="divider text-xs font-bold uppercase text-base-content/50">
          {gettext("Character")}
        </div>

        <div>
          <label class="label">
            <span class="label-text font-bold">{gettext("Avatar")}</span>
          </label>
          <.live_component
            module={AvatarUploadComponent}
            id="character-avatar-upload"
            current_user={@current_user}
            avatar_url={@avatar_url}
            fallback_letter={fallback_letter(@form[:name].value)}
          />
        </div>

        <.form
          for={@form}
          id="character-form"
          phx-target={@myself}
          phx-change="validate"
          phx-submit="save"
        >
          <.input field={@form[:name]} type="text" label={gettext("Name")} required />
        </.form>
      </div>
      <div class="shrink-0 p-6 border-t border-base-200 bg-base-100 flex justify-end gap-3">
        <.button :if={@patch} variant="ghost" patch={@patch}>{gettext("Cancel")}</.button>
        <.button :if={!@patch} type="button" variant="ghost" phx-click={@on_cancel}>
          {gettext("Cancel")}
        </.button>
        <.button
          type="submit"
          form="character-form"
          variant="primary"
          phx-disable-with={gettext("Saving...")}
        >
          {gettext("Save")}
        </.button>
      </div>
    </div>
    """
  end

  defp fallback_letter(nil), do: "?"
  defp fallback_letter(""), do: "?"
  defp fallback_letter(name), do: name |> String.trim() |> String.first() |> String.upcase()
end
