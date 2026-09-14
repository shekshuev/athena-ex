defmodule AthenaWeb.FileLive.PersonalUploadComponent do
  @moduledoc """
  S3 direct-upload LiveComponent for a user's own personal storage.

  Unlike `AthenaWeb.StudioLive.MediaUploadComponent`, uploads here are never
  scoped to a course/block: `context` is always `"personal"` and `owner_id`
  is always the current user. Each entry is checked against the user's
  storage quota (`Athena.Media.check_quota/3`) before a presigned URL is
  issued.
  """
  use AthenaWeb, :live_component
  alias Athena.Media

  @impl true
  def update(assigns, socket) do
    settings = Media.Config.upload_settings("personal")

    {:ok,
     socket
     |> assign(assigns)
     |> assign(accept_str: settings.description)
     |> allow_upload(:media,
       accept: settings.accept,
       max_entries: settings.max_entries,
       max_file_size: settings.max_size,
       external: &presign_upload/2
     )}
  end

  defp presign_upload(entry, socket) do
    user = socket.assigns.current_user

    case Media.check_quota(user.id, user.role_id, entry.client_size) do
      :ok ->
        case Media.prepare_personal_upload(user, entry.client_name) do
          {:ok, meta} -> {:ok, meta, socket}
          {:error, _} -> {:error, %{reason: gettext("Could not generate upload URL")}, socket}
        end

      {:error, :quota_exceeded} ->
        {:error, %{reason: gettext("Not enough storage space remaining")}, socket}
    end
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_entry", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :media, ref)}
  end

  def handle_event("save", _params, socket) do
    user_id = socket.assigns.current_user.id

    results =
      consume_uploaded_entries(socket, :media, fn meta, entry ->
        file_attrs = %{
          "bucket" => meta.bucket,
          "key" => meta.key,
          "original_name" => entry.client_name,
          "mime_type" => entry.client_type,
          "size" => entry.client_size,
          "context" => "personal",
          "owner_id" => user_id
        }

        case Media.create_file(file_attrs) do
          {:ok, file} -> {:ok, {:ok, file}}
          {:error, err} -> {:ok, {:error, err}}
        end
      end)

    send(self(), {__MODULE__, {:saved, results}})

    {:noreply, socket}
  end

  def handle_event("clear_all_entries", _params, socket) do
    socket =
      Enum.reduce(socket.assigns.uploads.media.entries, socket, fn entry, acc ->
        cancel_upload(acc, :media, entry.ref)
      end)

    {:noreply, socket}
  end

  @doc false
  defp error_to_string(:too_large), do: gettext("File is too large")
  defp error_to_string(:not_accepted), do: gettext("Unacceptable file type")
  defp error_to_string(:too_many_files), do: gettext("Too many files — remove some and try again")
  defp error_to_string(:external_client_failure), do: gettext("Upload failed on client side")
  defp error_to_string({:writer_fail, _}), do: gettext("Upload writer failed")
  defp error_to_string(_), do: gettext("Upload error")

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.modal
        id="personal-upload-modal"
        show={true}
        title={gettext("Upload Files")}
        on_cancel={JS.push("close_upload")}
      >
        <div>
          <p class="text-sm font-bold text-base-content/60 mb-4">
            {gettext("%{remaining} remaining",
              remaining: Media.format_bytes(max(@usage.limit - @usage.used, 0))
            )}
          </p>

          <% has_entries = @uploads.media.entries != []

          is_uploading =
            Enum.any?(
              @uploads.media.entries,
              &(&1.progress > 0 and &1.progress < 100 and upload_errors(@uploads.media, &1) == [])
            )

          has_errors = Enum.any?(@uploads.media.entries, &(upload_errors(@uploads.media, &1) != []))

          quota_full = @usage.used >= @usage.limit %>

          <form id="personal-upload-form" phx-submit="save" phx-change="validate" phx-target={@myself}>
            <div
              :if={not quota_full}
              class={[
                "relative border-2 border-dashed rounded-sm transition-all duration-200 group flex flex-col items-center justify-center p-10 text-center",
                if(has_entries,
                  do: "hidden",
                  else: "border-base-300 hover:border-primary/50 hover:bg-base-200/50 bg-base-100"
                )
              ]}
              phx-drop-target={@uploads.media.ref}
            >
              <.live_file_input
                upload={@uploads.media}
                class="absolute inset-0 w-full h-full opacity-0 cursor-pointer z-10"
              />
              <div class="flex items-center justify-center w-16 h-16 bg-primary/10 border border-primary/20 text-primary rounded-sm mb-4 group-hover:scale-105 transition-transform">
                <.icon name="hero-cloud-arrow-up" class="size-8" />
              </div>
              <h4 class="font-black text-lg text-base-content mb-1">
                {gettext("Click or drag files here")}
              </h4>
              <p class="text-sm font-medium text-base-content/50">{@accept_str}</p>
            </div>

            <div
              :if={quota_full}
              class="p-4 bg-error/10 border border-error/30 rounded-sm text-error text-sm font-bold flex items-start gap-3"
            >
              <.icon name="hero-exclamation-triangle" class="size-5 shrink-0 mt-0.5" />
              <div>{gettext("Your storage quota is full. Delete some files to upload more.")}</div>
            </div>

            <div :if={has_entries} class="space-y-3 max-h-64 overflow-y-auto mt-4">
              <div
                :for={entry <- @uploads.media.entries}
                class="flex flex-col gap-3 p-4 bg-base-200/50 rounded-sm border border-base-300"
              >
                <div class="flex items-center justify-between">
                  <div class="flex items-center gap-3 min-w-0">
                    <div class="p-2 bg-base-100 rounded-sm border border-base-200 text-base-content/50 shrink-0">
                      <.file_type_icon mime_type={entry.client_type} class="size-5" />
                    </div>
                    <div class="truncate">
                      <div class="text-sm font-bold text-base-content truncate">
                        {entry.client_name}
                      </div>
                      <div class="text-xs font-medium text-base-content/50 uppercase tracking-wider">
                        {Float.round(entry.client_size / 1024 / 1024, 2)} MB
                      </div>
                    </div>
                  </div>

                  <div class="flex items-center gap-4 shrink-0">
                    <span :if={entry.progress > 0} class="text-sm font-black text-primary">
                      {entry.progress}%
                    </span>
                    <.icon_button
                      type="button"
                      phx-click="cancel_entry"
                      phx-value-ref={entry.ref}
                      phx-target={@myself}
                      icon="hero-x-mark"
                      label={gettext("Cancel")}
                      variant="danger"
                      size="sm"
                      class="min-h-9 h-9 w-9"
                    />
                  </div>
                </div>

                <div class="w-full bg-base-300 rounded-sm h-2 overflow-hidden">
                  <div
                    class={[
                      "h-full transition-all duration-300",
                      upload_errors(@uploads.media, entry) != [] && "bg-error",
                      upload_errors(@uploads.media, entry) == [] && "bg-primary"
                    ]}
                    style={"width: #{entry.progress}%"}
                  >
                  </div>
                </div>
                <div
                  :for={err <- upload_errors(@uploads.media, entry)}
                  class="text-error text-xs font-bold flex items-center gap-1"
                >
                  <.icon name="hero-exclamation-circle" class="size-4 shrink-0" />
                  {error_to_string(err)}
                </div>
              </div>
            </div>

            <div class="flex flex-col-reverse sm:flex-row justify-end gap-3 mt-8 pt-6 border-t border-base-200">
              <.button type="button" phx-click="close_upload">
                {gettext("Cancel")}
              </.button>

              <.button
                :if={has_errors}
                type="button"
                variant="warning"
                phx-click="clear_all_entries"
                phx-target={@myself}
              >
                <.icon name="hero-arrow-path" class="size-4 mr-1" />
                {gettext("Clear Selection")}
              </.button>

              <.button
                type="submit"
                variant="primary"
                class="phx-submit-loading:opacity-70"
                disabled={not has_entries or is_uploading or has_errors}
              >
                <.icon name="hero-arrow-up-tray" class="size-4 mr-2" />
                {if is_uploading, do: gettext("Uploading..."), else: gettext("Upload Files")}
              </.button>
            </div>
          </form>
        </div>
      </.modal>
    </div>
    """
  end
end
