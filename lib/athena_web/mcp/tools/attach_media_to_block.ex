defmodule AthenaWeb.MCP.Tools.AttachMediaToBlock do
  @moduledoc "MCP tool: attach_media_to_block."
  @behaviour EMCP.Tool

  alias Athena.Content
  alias AthenaWeb.MCP.Tools.{Errors, Serializers}

  @impl EMCP.Tool
  def name, do: "attach_media_to_block"

  @impl EMCP.Tool
  def description,
    do:
      "Step 3 of uploading a file (after prepare_media_upload and PUTting the bytes yourself) " <>
        "- registers the uploaded file and sets content.url on the block. See " <>
        "athena://docs/media-uploads. Pass through bucket/key/url_for_saved_entry exactly as " <>
        "prepare_media_upload returned them."

  @impl EMCP.Tool
  def input_schema do
    %{
      type: :object,
      properties: %{
        block_id: %{type: :string},
        bucket: %{type: :string},
        key: %{type: :string},
        url_for_saved_entry: %{type: :string},
        name: %{type: :string, description: "Original filename."},
        type: %{type: :string, description: "MIME type, e.g. \"image/png\"."},
        size: %{type: :integer, description: "File size in bytes."}
      },
      required: [:block_id, :bucket, :key, :url_for_saved_entry, :name, :type, :size]
    }
  end

  @impl EMCP.Tool
  def call(conn, %{"block_id" => block_id} = args) do
    user = conn.assigns.current_user

    meta = %{
      bucket: args["bucket"],
      key: args["key"],
      url_for_saved_entry: args["url_for_saved_entry"]
    }

    file_info = %{name: args["name"], type: args["type"], size: args["size"]}

    with {:ok, block} <- Content.get_block(user, block_id),
         {:ok, updated} <- Content.attach_media_to_block(user, block, meta, file_info) do
      Errors.ok(Serializers.block(updated))
    else
      error -> Errors.error(error)
    end
  end
end
