defmodule AthenaWeb.StudioLive.MediaUploadComponent do
  @moduledoc """
  Reusable S3 direct-upload LiveComponent.
  Handles presigned URLs, visual progress, and registers files in Athena.Media.
  """
  use AthenaWeb, :live_component
  alias Athena.Content

  @impl true
  def update(assigns, socket) do
    {accept, max_entries, max_size, accept_str} =
      case assigns.upload_type do
        "video" ->
          {~w(.mp4 .mov .webm), 1, 500 * 1024 * 1024, ".MP4, .MOV, .WEBM (Max 500MB)"}

        "attachment" ->
          {~w(.pdf .doc .docx .xls .xlsx .ppt .pptx .txt .zip .rar .7z), 10, 50 * 1024 * 1024,
           "Docs, PDFs, Archives (Max 50MB, 10 files)"}

        _ ->
          {~w(.jpg .jpeg .png .gif .webp), 1, 10 * 1024 * 1024,
           ".JPG, .PNG, .GIF, .WEBP (Max 10MB)"}
      end

    {:ok,
     socket
     |> assign(assigns)
     |> assign(accept_str: accept_str)
     |> allow_upload(:media,
       accept: accept,
       max_entries: max_entries,
       max_file_size: max_size,
       external: &presign_upload/2
     )}
  end

  defp presign_upload(entry, socket) do
    context_id = socket.assigns[:course_id] || "library"

    case Content.prepare_media_upload(context_id, entry.client_name) do
      {:ok, meta} ->
        {:ok, meta, socket}

      {:error, _} ->
        {:error, gettext("Could not generate upload URL")}
    end
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_entry", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :media, ref)}
  end

  @impl true
  def handle_event("save", _params, socket) do
    user_id = socket.assigns.current_user.id
    upload_type = socket.assigns.upload_type
    block_id = socket.assigns.block_id

    results =
      consume_uploaded_entries(socket, :media, fn meta, entry ->
        file_info = %{name: entry.client_name, type: entry.client_type, size: entry.client_size}

        file_attrs = %{
          "bucket" => meta.bucket,
          "key" => meta.key,
          "original_name" => file_info.name,
          "mime_type" => file_info.type,
          "size" => file_info.size,
          "context" => "course_material",
          "owner_id" => user_id
        }

        case Athena.Media.create_file(file_attrs) do
          {:ok, _file} ->
            {:ok,
             %{
               "url" => meta.url_for_saved_entry,
               "name" => file_info.name,
               "size" => file_info.size,
               "mime" => file_info.type
             }}

          {:error, err} ->
            {:error, err}
        end
      end)

    send(self(), {__MODULE__, {:saved, block_id, upload_type, results}})

    {:noreply, socket}
  end

  @doc false
  defp error_to_string(:too_large), do: gettext("File is too large")
  defp error_to_string(:not_accepted), do: gettext("Unacceptable file type")
  defp error_to_string(:too_many_files), do: gettext("Too many files")
  defp error_to_string(_), do: gettext("Upload error")

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.modal
        id="media-upload-modal"
        show={true}
        title={gettext("Upload Media")}
        on_cancel={JS.push("cancel_media_upload")}
      >
        <div class="p-6">
          <% has_entries = @uploads.media.entries != []

          is_uploading =
            Enum.any?(
              @uploads.media.entries,
              &(&1.progress > 0 and &1.progress < 100 and upload_errors(@uploads.media, &1) == [])
            )

          has_errors = Enum.any?(@uploads.media.entries, &(upload_errors(@uploads.media, &1) != [])) %>

          <form id="upload-form" phx-submit="save" phx-change="validate" phx-target={@myself}>
            <div
              class={[
                "relative border-2 border-dashed rounded-2xl transition-all duration-200 group flex flex-col items-center justify-center p-10 text-center",
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
              <div class="p-4 bg-primary/10 text-primary rounded-full mb-4 group-hover:scale-110 transition-transform">
                <.icon name="hero-cloud-arrow-up" class="size-10" />
              </div>
              <h4 class="font-black text-lg text-base-content mb-1">
                {gettext("Click or drag files here")}
              </h4>
              <p class="text-sm font-medium text-base-content/50">{@accept_str}</p>
            </div>

            <div :if={has_entries} class="space-y-3 max-h-64 overflow-y-auto">
              <div
                :for={entry <- @uploads.media.entries}
                class="flex flex-col gap-3 p-4 bg-base-200/50 rounded-2xl border border-base-300"
              >
                <div class="flex items-center justify-between">
                  <div class="flex items-center gap-3 min-w-0">
                    <div class="p-2 bg-base-100 rounded-lg shadow-sm text-base-content/50 shrink-0">
                      <.icon
                        name={if @upload_type == "video", do: "hero-video-camera", else: "hero-photo"}
                        class="size-5"
                      />
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
                    <span class="text-sm font-black text-primary">{entry.progress}%</span>
                    <button
                      type="button"
                      phx-click="cancel_entry"
                      phx-value-ref={entry.ref}
                      phx-target={@myself}
                      class="btn btn-ghost btn-sm btn-circle text-error hover:bg-error/20"
                      title={gettext("Cancel")}
                    >
                      <.icon name="hero-x-mark" class="size-5" />
                    </button>
                  </div>
                </div>
                <div class="w-full bg-base-300 rounded-full h-2.5 overflow-hidden">
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

            <div class="flex justify-end gap-3 mt-8 pt-6 border-t border-base-200">
              <button type="button" phx-click="cancel_media_upload" class="btn btn-ghost">
                {gettext("Cancel")}
              </button>
              <button
                type="submit"
                class="btn btn-primary shadow-lg shadow-primary/20"
                disabled={not has_entries or is_uploading or has_errors}
              >
                <.icon name="hero-arrow-up-tray" class="size-4 mr-2" />
                {if is_uploading, do: gettext("Uploading..."), else: gettext("Upload Files")}
              </button>
            </div>
          </form>
        </div>
      </.modal>
    </div>
    """
  end
end
