defmodule AthenaWeb.MCP.Tools.PrepareMediaUpload do
  @moduledoc "MCP tool: prepare_media_upload."
  @behaviour EMCP.Tool

  alias Athena.Content
  alias AthenaWeb.MCP.Tools.Errors

  @impl EMCP.Tool
  def name, do: "prepare_media_upload"

  @impl EMCP.Tool
  def description,
    do:
      "Step 1 of uploading a file: returns a presigned S3 URL. See " <>
        "athena://docs/media-uploads for the full flow - you must PUT the file bytes to the " <>
        "returned url yourself (not via MCP), then call attach_media_to_block."

  @impl EMCP.Tool
  def input_schema do
    %{
      type: :object,
      properties: %{
        course_id: %{type: :string},
        filename: %{type: :string},
        upload_context: %{
          type: :string,
          description: "\"course_material\" (default), \"submission\", or \"library\"."
        }
      },
      required: [:course_id, :filename]
    }
  end

  @impl EMCP.Tool
  def call(conn, %{"course_id" => course_id, "filename" => filename} = args) do
    user = conn.assigns.current_user
    upload_context = args["upload_context"] || "course_material"

    case Content.prepare_media_upload(user, course_id, filename, upload_context) do
      {:ok, meta} -> Errors.ok(meta)
      error -> Errors.error(error)
    end
  end
end
