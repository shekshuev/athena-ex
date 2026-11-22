%{
  title: "Academic integrity",
  description: "Instructor-only observations, conservative review priorities and the assessment event history."
}
---
## Purpose

Monitoring records browser observations during assessments and ticket assessments. It helps an instructor decide which attempts deserve a closer look. **A colour is a review priority, not proof of cheating.** It does not change a grade, reject an answer or end an attempt.

Students receive no monitoring warnings, fullscreen requests or clipboard restrictions. An author can separately enable rendering instructions as an image, per question or for all questions in an assessment. The normal assessment deadline still applies.

## Review priorities

| Colour | Label | Default rule |
|---|---|---|
| Green | :ui[No scored signals] | Fewer than 2 scored points; contextual observations can still exist |
| Yellow | :ui[Review recommended] | At least 2 points, or client-only observations that would otherwise reach red |
| Red | :ui[Priority review] | At least 4 points **and** a server-confirmed concurrent session |

The red corroboration requirement is enabled by default. It prevents ordinary browser actions or a combination of client reports from independently creating a red priority. A teacher still makes the final decision.

## Scored signals

Each category contributes at most once, regardless of repetition.

| Category | Default rule | Maximum points |
|---|---|---|
| Concurrent sessions | Distinct live server sessions for the same attempt overlap for at least 10 seconds and each continues sending heartbeats. Short reconnect overlaps are ignored. Browser reports do not add a second score | 2 |
| Time away | At least one absence of 10 seconds, or at least 60 seconds away in total. Overlapping absences count once; even long absences cannot independently produce red | 2 |
| Pasting after returning | A paste of at least 150 characters within 60 seconds of returning, or an unusually high paste ratio from these pastes. The ratio is compared with peers where possible. A large paste and the ratio never score twice | 2 |
| Window layout | At least 300 seconds with the window occupying part of the screen, plus at least 3 sideways pointer exits. A narrowed page alone may be a sidebar or developer tools and earns no points | 1 |

For example, a confirmed concurrent session plus a large paste can produce a red priority. Pasting and time away without server confirmation are capped at yellow. Repeated tab reports or repeated pastes do not manufacture a red priority on their own.

## Context without points

The following remain available to the instructor without contributing points:

- copying, cutting, context menus and PrintScreen key events;
- text appearing without a recent input event, typing rhythm, clean answers and frequent revisions;
- network outages, missing heartbeat messages and silence while a connection still appears live;
- focus samples that disagree with absence events, and answer saves or code runs received near unfocused samples;
- a second display, clock differences and long stretches containing only monitoring pings;
- short window changes and narrowed page areas.

These observations have legitimate explanations: autofill, assistive input, ordinary editing, delayed autosaves, reading, browser suspension and network problems. Geometry and focus are self-reported by the browser. They do not prove what another window or display contained. The browser cannot detect another device or every operating-system screenshot tool.

## Event history

Open :ui[Teaching] › :ui[Assignments], then an assessment answer with :ui[Grade] or :ui[View]. In :ui[Academic Integrity], :ui[Learn more] opens :ui[Attempt monitoring and event history].

- :ui[Summary] shows the review priority, the scored signals and all measured context.
- :ui[Timeline] shows the attempt start date and time, each event's elapsed time as **+HH:MM:SS**, and the corresponding date and clock time in the instructor's timezone.

For example, `+01:05:05` means one hour, five minutes and five seconds **after the displayed attempt start**, not a time of day. The adjacent timestamp and timezone identify the actual clock time.

New browser events use the server receipt clock and are bound to one attempt. Interval starts are estimated by subtracting reported durations; they cannot precede the attempt. Older events may use the browser clock. Events from later attempts or after the recorded finish are excluded. Missing batches and server downtime are not charged as time in a particular layout. The first layout batch establishes observation without inventing earlier time.

A notice identifies stored results produced by older scoring rules. Historical results are not silently recalculated; use the history and your own review.

## Instructor review

On :ui[Summary], use :ui[Teacher review]: optionally enter :ui[Note (optional)], then choose :ui[Confirm violation] or :ui[Reviewed - no violation]. The decision records who reviewed the attempt and when. It replaces the automatic badge while preserving the observations.

The live group monitor is available through :ui[Monitor this group for cheating]. :ui[Learn more] opens :ui[How review priority is calculated], with the current thresholds and limitations.

## Configuration

The `config :athena, Athena.Engagement` settings include:

| Key | Default | Meaning |
|---|---|---|
| `exam_risk_yellow_points` | 2 | Yellow review threshold |
| `exam_risk_red_points` | 4 | Red review threshold |
| `exam_require_server_corroboration_for_red` | true | Require confirmed concurrent sessions for red |
| `exam_concurrent_session_grace_seconds` | 10 | Minimum continuous overlap of live sessions |
| `exam_large_paste_chars` | 150 | Minimum large-paste size |
| `exam_paste_away_window_seconds` | 60 | Window after returning in which pastes contribute |
| `exam_away_incident_min_seconds` | 10 | Significant-absence duration |
| `exam_away_red_seconds` | 60 | Legacy key: total away time sufficient for the bounded yellow category |
| `exam_split_yellow_seconds` | 300 | Window-sharing duration for the one-point contextual signal |

Paste-ratio group thresholds retain the configured median, spread and absolute-floor safeguards. Other measured behavioural rates are contextual only.
