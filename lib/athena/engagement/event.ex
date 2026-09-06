defmodule Athena.Engagement.Event do
  @moduledoc """
  A single raw engagement telemetry event (viewport dwell, paste, video control,
  tab focus, etc.) reported by the student-facing Player.

  Events are intentionally low-level and semantically thin (verb + object + time,
  in the spirit of xAPI/IMS Caliper) - all interpretation happens in
  `Athena.Engagement.Metrics` and `Athena.Engagement.BlockStats`, never here.
  See the comment on each `@event_types` entry below for what it captures and
  which block type(s) emit it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @event_types [
    # A block scrolled into/out of the viewport (client IntersectionObserver).
    # One observer watches every block wrapper regardless of type, so these
    # two fire for all 9 block types; paired enter/exit give dwell ("active
    # time") - the base signal used everywhere except `attachment` (which has
    # no on-page dwell concept - see attachment_open) and `video` (which has
    # its own play/pause clock instead, see video_play below).
    :viewport_enter,
    :viewport_exit,

    # A `text` block's scroll position crossed the 25/50/75/100% mark of its
    # own content height. text only - tells "opened and left it open" apart
    # from "actually scrolled through it".
    :scroll_milestone,

    # Browser tab lost/regained focus (`document.visibilitychange`). Applies
    # to whatever block is on screen at the time: excludes backgrounded time
    # from dwell on any block type, and on `quiz_exam`/`ticket_exam` doubles
    # as an academic-integrity signal (focus loss during a timed attempt).
    :tab_hidden,
    :tab_visible,

    # Native `paste` DOM event while typing an answer. Payload carries
    # `{pasted_chars, total_chars}` counts only, never clipboard content.
    # Fires on `code` blocks (CodeMirror) and on `quiz_question` blocks whose
    # answer type is an open text field.
    :paste_detected,

    # Native `<video>` element controls. `video` blocks only.
    # `video_seek`'s payload carries `{from_sec, to_sec}` - direction
    # (forward = skip/skim, backward = rewatch/confusion) is derived from
    # that pair, it is not a separate event type.
    :video_play,
    :video_pause,
    :video_seek,
    :video_rate_change,
    :video_ended,

    # The first choice made on a quiz answer widget, and every change after
    # that before submit. `quiz_question`, and per sub-question on
    # `quiz_exam`/`ticket_exam`. `answer_selected` marks the first pick (used
    # for "time to first answer"); `answer_changed` marks each subsequent
    # revision (deliberation/uncertainty signal).
    :answer_selected,
    :answer_changed,

    # Click on an `attachment` block's file link. `attachment` only - this is
    # the block type's primary engagement signal, since a downloaded file has
    # no on-page dwell time once it leaves the page.
    :attachment_open,

    # Lightbox/zoom interaction on an `image` block, when the renderer offers
    # one. `image` only.
    :image_zoom,

    # Recorded server-side (never pushed by the client) when a student is
    # shown an auto-nudge banner for a block. Lets nudge frequency itself be
    # analyzed over time and stops the same block from re-nudging within one
    # session. Attached to whichever block the nudge fired on.
    :nudge_shown
  ]

  @derive {
    Flop.Schema,
    filterable: ~w(account_id cohort_id section_id block_id event_type session_id)a,
    sortable: ~w(occurred_at)a,
    default_limit: 50,
    default_order: %{order_by: [:occurred_at], order_directions: [:asc]}
  }

  schema "engagement_events" do
    field :account_id, :binary_id
    field :block_id, :binary_id
    field :section_id, :binary_id
    field :cohort_id, :binary_id
    field :session_id, :binary_id

    field :event_type, Ecto.Enum, values: @event_types
    field :payload, :map, default: %{}
    field :occurred_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :account_id,
      :block_id,
      :section_id,
      :cohort_id,
      :session_id,
      :event_type,
      :payload,
      :occurred_at
    ])
    |> validate_required([
      :account_id,
      :block_id,
      :section_id,
      :session_id,
      :event_type,
      :occurred_at
    ])
  end
end
