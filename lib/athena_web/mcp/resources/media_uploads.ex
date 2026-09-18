defmodule AthenaWeb.MCP.Resources.MediaUploads do
  @moduledoc """
  Static MCP resource documenting the S3 direct-upload flow behind the
  `prepare_media_upload`/`attach_media_to_block` tools, and how the
  resulting URL is used for `image`/`video`/`attachment` blocks vs. inline
  images inside a Tiptap `body` document.

  Source of truth: `Athena.Content.Blocks.prepare_media_upload/4`,
  `Athena.Content.Blocks.attach_media_to_block/4`, `Athena.Media.Config`.
  """

  @behaviour EMCP.Resource

  @markdown_content """
  # Uploading files (S3) for image / video / attachment / file_assignment blocks

  There is no single "upload a file" MCP call - a browser-only step (the
  actual byte transfer) sits between two tool calls. The flow is always:

  1. **`prepare_media_upload`** (MCP tool call) - returns a short-lived
     presigned S3 URL.
  2. **You (the agent) PUT the raw file bytes directly to that URL** -
     this is NOT an MCP tool call. It's a plain HTTP request your own
     client makes (e.g. `curl -X PUT --data-binary @file.png "<upload_url>"`).
     No `Authorization` header, no signing of your own - the signature is
     already embedded in the URL's query string. No required
     `Content-Type` either. The URL expires 15 minutes after
     `prepare_media_upload` returned it.
  3. **`attach_media_to_block`** (MCP tool call) - registers the uploaded
     file and writes its URL onto the block's `content`.

  ## Step 1: `prepare_media_upload`

  Arguments: `course_id`, `filename`, `upload_context` (optional, default
  `"course_material"` - also accepts `"submission"`/`"library"`; anything
  other than those two is treated as `"course_material"` for authorization
  purposes, i.e. it just needs course-edit rights).

  Returns:
  ```json
  {
    "url": "https://<s3-endpoint>/athena/courses/<course_id>/<uuid>-<filename>?X-Amz-...",
    "url_for_saved_entry": "/media/courses/<course_id>/<uuid>-<filename>",
    "bucket": "athena",
    "key": "courses/<course_id>/<uuid>-<filename>"
  }
  ```
  - `url` is the presigned PUT URL for step 2 - use it once, then discard it.
  - `url_for_saved_entry`, `bucket`, `key` are what you pass into
    `attach_media_to_block` afterward - keep them.
  - `url_for_saved_entry` is app-relative (`/media/...`); build the
    full URL as `<athena-host>` + `url_for_saved_entry` wherever a full URL
    is needed (e.g. embedding inline in a Tiptap doc, see below).

  ## Step 2: upload the bytes yourself

  ```bash
  curl -X PUT --data-binary @diagram.png "<url from step 1>"
  ```
  A `200` response means it worked. Anything else means the presigned URL
  was wrong/expired/already used - call `prepare_media_upload` again (each
  call mints a fresh key, so retries are always safe, just wasteful of storage).

  ## Step 3: `attach_media_to_block`

  Arguments: `block_id`, plus everything from step 1's response
  (`bucket`, `key`, `url_for_saved_entry`) and simple file metadata:
  `name` (original filename), `type` (MIME type, e.g. `"image/png"`),
  `size` (bytes, integer).

  This does two things atomically: registers an `Athena.Media` file record,
  and sets `block.content["url"] = url_for_saved_entry` - merged into the
  block's existing `content` (other keys like `alt`/`poster_url` are
  preserved, not wiped). It requires the block to already exist (create it
  first via `create_block` with a placeholder `content`, e.g.
  `{"url": null}` for `image`/`video`, then attach the real file after upload).

  Known quirk: the file record this creates is always tagged
  `"course_material"` internally regardless of what `upload_context` you
  passed to `prepare_media_upload` - harmless for authoring, just don't
  rely on the file's stored context matching `"submission"`/`"library"`.

  For `attachment` blocks specifically, `content` holds a **list** under
  `"files"` (`{"files": [{"url": ..., "name": ...}, ...]}`), so after using
  `attach_media_to_block` for the first file, subsequent files need
  `update_block` to append another entry to that list yourself (the
  `attach_media_to_block` tool always sets `content.url`, singular - it
  does not know about the `attachment` block's `files` array convention).

  ## Inline images inside a Tiptap document (`text`/`quiz_question`/`code`/`file_assignment` `body`)

  Same steps 1-2 (`prepare_media_upload` + your own PUT), but there is no
  `attach_media_to_block`-equivalent step for an inline image - instead,
  embed the full URL directly as an `image` node inside the Tiptap JSON you
  send as `content` (or `content.body`, depending on block type - see
  `athena://docs/block-content-schemas`):

  ```json
  {"type": "image", "attrs": {"src": "<athena-host><url_for_saved_entry>", "alt": "Diagram"}}
  ```
  as one entry in that document's `content` array, alongside paragraph nodes.

  ## Size/type limits per media context

  Enforced server-side by `Athena.Media.Config.upload_settings/1`, keyed by
  the block/upload type:

  | context | accepted extensions | max files | max size (each) |
  |---|---|---|---|
  | `image` (default) | jpg, jpeg, png, gif, webp, svg, bmp, tiff | 1 | 25 MB |
  | `video` | mp4, mov, webm, avi, mkv | 1 | 1 GB |
  | `attachment` | pdf, doc(x), xls(x), ppt(x), txt, csv, rtf, zip, rar, 7z, tar, gz, mp3, wav, flac | 10 | 2 GB |
  | `file_assignment` | pdf, doc(x), txt, zip, rar, py, cpp, c, h, js, ts, json, csv | 20 | 50 MB |

  `prepare_media_upload`/`attach_media_to_block` don't enforce these
  themselves (that's LiveView-upload-specific plumbing) - stay within them
  anyway so the file behaves the same as one uploaded through the Studio UI.
  """

  @impl EMCP.Resource
  def uri, do: "athena://docs/media-uploads"

  @impl EMCP.Resource
  def name, do: "media_uploads"

  @impl EMCP.Resource
  def description,
    do:
      "The prepare_media_upload -> (you PUT the file bytes) -> attach_media_to_block flow for " <>
        "image/video/attachment/file_assignment blocks and inline Tiptap images. Read this " <>
        "before calling prepare_media_upload or attach_media_to_block."

  @impl EMCP.Resource
  def mime_type, do: "text/markdown"

  @impl EMCP.Resource
  def read(_conn), do: @markdown_content
end
