defmodule AthenaWeb.StudioLive.AvatarUploadComponent do
  @moduledoc """
  Compact inline S3 direct-upload widget for a single character avatar.
  Unlike `MediaUploadComponent`, this isn't tied to a course/block — the
  upload key is namespaced by the owning teacher instead.
  """
  use AthenaWeb, :live_component
  alias Athena.{Content, Media}

  @impl true
  def update(assigns, socket) do
    settings = Media.Config.upload_settings("avatar")

    {:ok,
     socket
     |> assign(assigns)
     |> assign(accept_str: settings.description)
     |> assign_new(:confirm_remove?, fn -> false end)
     |> allow_upload(:avatar,
       accept: settings.accept,
       max_entries: 1,
       max_file_size: settings.max_size,
       external: &presign_upload/2
     )}
  end

  defp presign_upload(entry, socket) do
    case Content.prepare_avatar_upload(socket.assigns.current_user, entry.client_name) do
      {:ok, meta} -> {:ok, meta, socket}
      {:error, _} -> {:error, %{reason: gettext("Could not generate upload URL")}, socket}
    end
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_entry", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :avatar, ref)}
  end

  def handle_event("save", _params, socket) do
    user_id = socket.assigns.current_user.id

    results =
      consume_uploaded_entries(socket, :avatar, fn meta, entry ->
        file_attrs = %{
          "bucket" => meta.bucket,
          "key" => meta.key,
          "original_name" => entry.client_name,
          "mime_type" => entry.client_type,
          "size" => entry.client_size,
          "context" => "avatar",
          "owner_id" => user_id
        }

        case Media.create_file(file_attrs) do
          {:ok, file} -> {:ok, {:ok, %{id: file.id, url: "/media/#{file.key}"}}}
          {:error, err} -> {:ok, {:error, err}}
        end
      end)

    case results do
      [{:ok, file_info}] ->
        send(self(), {__MODULE__, {:uploaded, file_info}})
        {:noreply, socket}

      [{:error, _}] ->
        {:noreply, put_flash(socket, :error, gettext("Failed to upload avatar"))}

      [] ->
        {:noreply, socket}
    end
  end

  def handle_event("remove_avatar_click", _params, socket) do
    {:noreply, assign(socket, :confirm_remove?, true)}
  end

  def handle_event("cancel_remove_avatar", _params, socket) do
    {:noreply, assign(socket, :confirm_remove?, false)}
  end

  def handle_event("confirm_remove_avatar", _params, socket) do
    send(self(), {__MODULE__, :removed})
    {:noreply, assign(socket, :confirm_remove?, false)}
  end

  defp error_to_string(:too_large), do: gettext("File is too large")
  defp error_to_string(:not_accepted), do: gettext("Unacceptable file type")
  defp error_to_string(:too_many_files), do: gettext("Only one avatar is allowed")
  defp error_to_string(:external_client_failure), do: gettext("Upload failed on client side")
  defp error_to_string(_), do: gettext("Upload error")

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex items-center gap-4">
      <div class="avatar placeholder shrink-0">
        <div class="bg-neutral text-neutral-content w-16 rounded-full flex items-center justify-center">
          <img :if={@avatar_url} src={@avatar_url} alt="" />
          <span :if={!@avatar_url} class="text-xl leading-none">
            {@fallback_letter}
          </span>
        </div>
      </div>

      <div class="flex-1">
        <form
          id={"#{@id}-form"}
          phx-change="validate"
          phx-submit="save"
          phx-target={@myself}
          class="space-y-2"
        >
          <.live_file_input upload={@uploads.avatar} class="file-input file-input-sm w-full" />
          <p class="text-xs text-base-content/50">{@accept_str}</p>

          <div :for={entry <- @uploads.avatar.entries} class="flex items-center gap-2 text-xs">
            <span class="truncate">{entry.client_name}</span>
            <progress
              class="progress progress-primary w-24"
              value={entry.progress}
              max="100"
            >
            </progress>
            <.icon_button
              type="button"
              phx-click="cancel_entry"
              phx-value-ref={entry.ref}
              phx-target={@myself}
              icon="hero-x-mark"
              label={gettext("Cancel")}
              variant="danger"
            />
            <span :for={err <- upload_errors(@uploads.avatar, entry)} class="text-error">
              {error_to_string(err)}
            </span>
          </div>

          <.button
            :if={@uploads.avatar.entries != []}
            type="submit"
            variant="primary"
            size="xs"
            phx-disable-with={gettext("Uploading...")}
          >
            {gettext("Upload")}
          </.button>
        </form>

        <.button
          :if={@avatar_url}
          type="button"
          variant="ghost"
          size="xs"
          class="text-error mt-1"
          phx-click="remove_avatar_click"
          phx-target={@myself}
        >
          {gettext("Remove avatar")}
        </.button>
      </div>

      <.modal
        id={"#{@id}-remove-avatar-modal"}
        show={@confirm_remove?}
        title={gettext("Remove this avatar?")}
        on_cancel={JS.push("cancel_remove_avatar", target: @myself)}
        on_confirm={JS.push("confirm_remove_avatar", target: @myself)}
        confirm_label={gettext("Remove")}
        danger={true}
      />
    </div>
    """
  end
end
