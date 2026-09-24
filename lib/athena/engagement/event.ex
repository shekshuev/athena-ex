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

    # `code` blocks only. `code_run_attempt` is recorded server-side the
    # moment the student clicks "Run" (before the result is known);
    # `code_run_result` follows later - asynchronously, once the Oban-backed
    # execution worker finishes - with `payload: {outcome}` set to the
    # resulting `Athena.Learning.Submission.status` (e.g. "accepted",
    # "wrong_answer", "compilation_error", "time_limit_exceeded"). Together
    # they let a debug cycle ("wrote -> ran -> failed -> fixed -> ran again")
    # be told apart from "pasted and submitted with no attempt to run it",
    # and (via the gap between consecutive `code_run_attempt` timestamps)
    # from a rapid, non-thinking "panic debugging" burst. Deliberately not
    # generalized to every block type - `Athena.Learning.Submission` stays
    # the source of truth for grading; this only mirrors a coarse outcome
    # category into the same session timeline as everything else, so a
    # replay doesn't need to cross-reference two tables by timestamp.
    :code_run_attempt,
    :code_run_result,

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

    # The student's first meaningful interaction with a block after
    # `viewport_enter` - the first keystroke in a `code` editor, or (fired
    # together with `answer_selected`) the first quiz answer saved. Paired
    # with the block's own `viewport_enter`, this gives Time To First Action
    # (TTFA) - did they dive in right away, or sit on the block first.
    :first_interaction,

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
    :nudge_shown,

    # No mouse/keyboard/scroll activity for a client-side idle threshold
    # (`idle_start`), and the resumption of activity afterwards (`idle_end`,
    # payload carries `{duration_ms}`). Applies to whatever block is current
    # when idle begins. This is *not* the same signal as `tab_hidden` - the
    # tab can stay focused and in view while the student has simply stepped
    # away (bathroom, coffee), which `tab_hidden` alone would miss entirely.
    # `Athena.Engagement.Events.pair_viewport_dwells/1` subtracts idle
    # windows from raw dwell time so "away from keyboard" is never counted
    # as "reading" or "stuck".
    :idle_start,
    :idle_end,

    # Academic-integrity signals, `quiz_exam`/`ticket_exam` only.
    # `printscreen_attempt` fires on a `keydown` for the Windows
    # `PrintScreen` key - macOS screenshot shortcuts (Cmd+Shift+3/4/5) are
    # OS-level and invisible to any web page, so this only ever catches the
    # Windows case. `copy_attempt`/`cut_attempt` fire on a native
    # `copy`/`cut` DOM event inside a container explicitly marked
    # no-copy (the question prompt) - the container also blocks the native
    # action, so these mean "the student tried anyway", not that any text
    # was actually captured. See `Athena.Engagement.ProctoringMonitor` for
    # how these get turned into a live risk indicator during an attempt.
    :printscreen_attempt,
    :copy_attempt,
    :cut_attempt,

    # Complements `tab_hidden`/`tab_visible` - the window losing/gaining OS
    # focus (`window.blur`/`window.focus`), which can catch switching to
    # another top-level window in situations where `document.
    # visibilitychange` doesn't reliably fire (varies by OS/window
    # manager/multi-monitor setup). Collected everywhere the engagement
    # tracker mounts (Player and both exam LiveViews), not exam-only.
    :window_blur,
    :window_focus,

    # `quiz_exam`/`ticket_exam` only. The same attempt (`submission_id`) was
    # detected open in more than one browser tab/window at once, via a
    # `BroadcastChannel`/`localStorage` handshake between tabs. Only catches
    # two tabs in the *same* browser profile - a second device or a
    # different browser is invisible to this signal.
    :multi_tab_detected
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

  @doc """
  The full catalog of valid `event_type` values (see the annotated list above
  for what each one means). Used to safely translate an untrusted client
  event-type string into the corresponding atom without risking
  `String.to_existing_atom/1` on arbitrary input.
  """
  @spec event_types() :: [atom()]
  def event_types, do: @event_types

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
