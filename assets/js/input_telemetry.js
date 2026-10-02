// Answer-input telemetry for proctored exam pages: how text got into an
// answer field, and the *shape* of the typing - never what was typed and
// never which keys. Works on anything editable (a plain <input>/<textarea>,
// a CodeMirror content element, a TipTap/ProseMirror editor), so one module
// covers every answer type.
//
// What it reports (all through the caller's `report(eventType, payload)`):
//   paste_detected  - only for fields whose own editor does not already
//                     report pastes (`trackPaste`), and for drag-and-drop
//                     everywhere (`source: "drop"`).
//   bulk_insert     - the field grew by a block of text with no input event
//                     behind it (e.g. a browser extension writing into the
//                     DOM, which fires neither `paste` nor `input`).
//   typing_summary  - aggregated numbers over a window of keystrokes:
//                     median key-hold time, how regular the rhythm is,
//                     pauses, longest run without a correction, characters
//                     typed vs. deleted. Composition input (IME, dictation,
//                     on-screen keyboards) is skipped: it has no meaningful
//                     key timing and must never look like a macro.

import { proctoringActive } from "./engagement_hooks";

const SUMMARY_EVERY_KEYS = 40;
const SUMMARY_MIN_KEYS = 10;
const SUMMARY_MAX_AGE_MS = 20_000;
const PAUSE_MS = 1_500;
const BULK_MIN_CHARS = 20;
const BULK_POLL_MS = 500;
const RECENT_INPUT_MS = 1_000;

function median(values) {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

function coefficientOfVariation(values) {
  if (values.length < 2) return 0;
  const mean = values.reduce((a, b) => a + b, 0) / values.length;
  if (mean === 0) return 0;
  const variance = values.reduce((a, b) => a + (b - mean) ** 2, 0) / values.length;
  return Math.sqrt(variance) / mean;
}

function currentLength(el) {
  if (typeof el.value === "string") return el.value.length;
  return (el.textContent || "").length;
}

/**
 * @param {HTMLElement} el          the editable element
 * @param {object} options
 * @param {(type: string, payload: object) => void} options.report
 * @param {boolean} [options.trackPaste=false]  report paste events itself
 * @returns {() => void} detach function
 */
export function attachInputTelemetry(el, { report, trackPaste = false }) {
  if (!el || !proctoringActive()) return () => {};

  let window_ = newWindow();
  let lastInputAt = 0;
  let lastLength = currentLength(el);
  const downAt = new Map(); // e.code -> keydown time, held only while pressed

  function newWindow() {
    return {
      startedAt: Date.now(),
      dwells: [],
      flights: [],
      lastDownAt: null,
      keys: 0,
      pauses: 0,
      typed: 0,
      deleted: 0,
      run: 0,
      maxRun: 0,
    };
  }

  function flushSummary(force) {
    const w = window_;
    if (w.keys < (force ? 1 : SUMMARY_MIN_KEYS)) return;
    report("typing_summary", {
      n: w.keys,
      median_dwell_ms: Math.round(median(w.dwells)),
      flight_cv: Number(coefficientOfVariation(w.flights).toFixed(2)),
      pauses: w.pauses,
      max_clean_run: w.maxRun,
      chars_typed: w.typed,
      chars_deleted: w.deleted,
    });
    window_ = newWindow();
  }

  const onKeyDown = (e) => {
    if (e.isComposing || e.keyCode === 229 || e.repeat) return;
    const now = performance.now();
    lastInputAt = Date.now();

    const isDelete = e.key === "Backspace" || e.key === "Delete";
    const isPrintable = e.key.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey;
    if (!isDelete && !isPrintable) return;

    downAt.set(e.code, now);
    const w = window_;
    w.keys += 1;

    if (w.lastDownAt != null) {
      const flight = now - w.lastDownAt;
      if (flight > PAUSE_MS) w.pauses += 1;
      else w.flights.push(flight);
    }
    w.lastDownAt = now;

    if (isDelete) {
      w.deleted += 1;
      w.run = 0;
    } else {
      w.typed += 1;
      w.run += 1;
      w.maxRun = Math.max(w.maxRun, w.run);
    }

    if (w.keys >= SUMMARY_EVERY_KEYS) flushSummary(false);
  };

  const onKeyUp = (e) => {
    const started = downAt.get(e.code);
    if (started == null) return;
    downAt.delete(e.code);
    window_.dwells.push(performance.now() - started);
  };

  const markInput = () => {
    lastInputAt = Date.now();
  };

  const onPaste = (e) => {
    lastInputAt = Date.now();
    if (!trackPaste) return;
    const text = e.clipboardData?.getData("text/plain") || "";
    if (!text) return;
    report("paste_detected", {
      pasted_chars: text.length,
      total_chars: currentLength(el) + text.length,
      source: "paste",
    });
  };

  const onDrop = (e) => {
    lastInputAt = Date.now();
    const text = e.dataTransfer?.getData("text/plain") || "";
    if (!text) return;
    report("paste_detected", {
      pasted_chars: text.length,
      total_chars: currentLength(el) + text.length,
      source: "drop",
    });
  };

  // Something wrote into the field without any input event of ours in the
  // last second: a real person typing/pasting/dropping always leaves one.
  const poll = setInterval(() => {
    const length = currentLength(el);
    const grew = length - lastLength;
    lastLength = length;

    if (grew >= BULK_MIN_CHARS && Date.now() - lastInputAt > RECENT_INPUT_MS) {
      report("bulk_insert", { chars: grew });
    }

    if (window_.keys > 0 && Date.now() - window_.startedAt > SUMMARY_MAX_AGE_MS) {
      flushSummary(false);
    }
  }, BULK_POLL_MS);

  el.addEventListener("keydown", onKeyDown);
  el.addEventListener("keyup", onKeyUp);
  el.addEventListener("beforeinput", markInput);
  el.addEventListener("input", markInput);
  el.addEventListener("compositionend", markInput);
  el.addEventListener("paste", onPaste);
  el.addEventListener("drop", onDrop);

  return () => {
    flushSummary(true);
    clearInterval(poll);
    el.removeEventListener("keydown", onKeyDown);
    el.removeEventListener("keyup", onKeyUp);
    el.removeEventListener("beforeinput", markInput);
    el.removeEventListener("input", markInput);
    el.removeEventListener("compositionend", markInput);
    el.removeEventListener("paste", onPaste);
    el.removeEventListener("drop", onDrop);
  };
}
