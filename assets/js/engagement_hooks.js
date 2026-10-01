// Client-side capture for Athena.Engagement - semantic, low-volume telemetry
// (viewport dwell, scroll depth, paste ratio, video controls, tab focus).
// Never raw pointer/keystroke data - see Athena.Engagement.Event for the full
// catalog of what each event type means and which block type emits it.
//
// All events funnel through one batching queue (EngagementTracker) so the
// server only ever sees a "engagement_batch" push every few seconds, never
// one push per scroll pixel or keystroke.

const FLUSH_INTERVAL_MS = 10_000;
const MAX_QUEUE_SIZE = 25;
const SCROLL_THRESHOLDS = [0, 0.25, 0.5, 0.75, 1];
const SCROLL_MILESTONES = [25, 50, 75, 100];
// Purely a client-side heuristic for "has the student stepped away", not a
// business threshold - deliberately not configurable server-side.
const IDLE_THRESHOLD_MS = 2 * 60 * 1000;

const TRACKER_ROOT_ID = "engagement-tracker";

// Block-answer hooks (CodeEditor, TiptapEditor) are shared with LiveViews
// that are not the student Player (Builder, CohortAccess previews, ...).
// Only push telemetry when the Player's tracker root is actually present in
// the page, so those other views stay silent no-ops instead of pushing an
// event no `handle_event` clause exists for.
export function engagementTrackingActive() {
  return document.getElementById(TRACKER_ROOT_ID) != null;
}

// True only on a real (non-test-run) exam page: the server sets
// `data-heartbeat="true"` on the tracker root there and nowhere else, so the
// extra integrity telemetry (typing shape, offline, pointer, window size,
// fullscreen) never runs in ordinary lessons or in the builder's sandbox.
export function proctoringActive() {
  return document.getElementById(TRACKER_ROOT_ID)?.dataset.heartbeat === "true";
}

export const EngagementHooks = {};

EngagementHooks.EngagementTracker = {
  mounted() {
    this.queue = [];
    this.intersecting = new Map(); // block_id -> bool
    this.reachedMilestones = new Map(); // block_id -> Set(percent)
    this.observedNodes = new WeakSet();
    this.currentBlockId = null;

    this.enqueue = (blockId, eventType, payload = {}) => {
      if (!blockId) return;
      this.queue.push({
        block_id: blockId,
        event_type: eventType,
        payload,
        occurred_at: new Date().toISOString(),
      });
      if (this.queue.length >= MAX_QUEUE_SIZE) this.flush();
    };

    this.flush = () => {
      if (this.queue.length === 0) return;
      const events = this.queue;
      this.queue = [];
      this.pushEvent("engagement_batch", { events });
    };

    // On exam pages (`data-heartbeat="true"`) every tick also pings the
    // server unconditionally, even when `flush()` above had nothing queued
    // - that's what lets the server notice *silence* (tracking JS
    // disabled/tampered) instead of only ever seeing suspicious events. A
    // student who patches just the listeners below (visibilitychange,
    // IntersectionObserver, BroadcastChannel) can't quietly stop this too
    // without also breaking their own `pushEvent`-based ability to answer
    // and submit.
    this.flushTimer = setInterval(() => {
      this.flush();
      if (this.el.dataset.heartbeat === "true") this.pushEvent("engagement_heartbeat", {});
    }, FLUSH_INTERVAL_MS);

    this.observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          const node = entry.target;
          const blockId = node.dataset.blockId;
          if (!blockId) continue;

          if (entry.isIntersecting) {
            if (!this.intersecting.get(blockId)) {
              this.intersecting.set(blockId, true);
              // Captured before currentBlockId is overwritten below, so a
              // navigation graph can be reconstructed later purely from
              // this field - no window functions needed over the raw
              // events (see Athena.Engagement.Metrics for how "backtrack"
              // already does exactly that with block order + occurred_at).
              const fromBlockId = this.currentBlockId;
              this.currentBlockId = blockId;
              this.enqueue(blockId, "viewport_enter", { from_block_id: fromBlockId });
            }

            if (node.dataset.blockType === "text") {
              const reached = this.reachedMilestones.get(blockId) || new Set();
              this.reachedMilestones.set(blockId, reached);

              const percent = Math.round(entry.intersectionRatio * 100);
              for (const milestone of SCROLL_MILESTONES) {
                if (percent >= milestone && !reached.has(milestone)) {
                  reached.add(milestone);
                  this.enqueue(blockId, "scroll_milestone", { percent: milestone });
                }
              }
            }
          } else if (this.intersecting.get(blockId)) {
            this.intersecting.set(blockId, false);
            this.enqueue(blockId, "viewport_exit");
          }
        }
      },
      { threshold: SCROLL_THRESHOLDS },
    );

    this.observeBlocks = () => {
      this.el.querySelectorAll("[data-block-id]").forEach((node) => {
        if (!this.observedNodes.has(node)) {
          this.observer.observe(node);
          this.observedNodes.add(node);
        }
      });
    };
    this.observeBlocks();

    this.tabHiddenAt = null;
    this.blurredAt = null;
    this.lastSwitchKeyAt = 0;

    // Alt/Meta/Tab pressed just before losing focus means a keyboard window
    // switch (Alt+Tab, Cmd+Tab, Win key) rather than a click elsewhere. Only
    // annotates the event for the teacher's timeline; it never changes the
    // verdict, the loss of focus itself is what counts.
    this.awayPayload = (extra = {}) =>
      Date.now() - this.lastSwitchKeyAt < 800 ? { ...extra, trigger: "keyboard" } : extra;

    this.handleVisibilityChange = () => {
      if (document.visibilityState === "hidden") {
        this.tabHiddenAt = Date.now();
        this.enqueue(this.currentBlockId, "tab_hidden", this.awayPayload());
      } else {
        const durationMs = this.tabHiddenAt != null ? Date.now() - this.tabHiddenAt : null;
        this.tabHiddenAt = null;
        this.enqueue(this.currentBlockId, "tab_visible", { duration_ms: durationMs });
      }
    };
    document.addEventListener("visibilitychange", this.handleVisibilityChange);

    // Complements visibilitychange - catches switching to another top-level
    // window in setups where visibilitychange doesn't reliably fire (varies
    // by OS/window manager/multi-monitor).
    this.handleWindowBlur = () => {
      this.blurredAt = Date.now();
      this.enqueue(this.currentBlockId, "window_blur", this.awayPayload());
    };
    this.handleWindowFocus = () => {
      const durationMs = this.blurredAt != null ? Date.now() - this.blurredAt : null;
      this.blurredAt = null;
      this.enqueue(this.currentBlockId, "window_focus", { duration_ms: durationMs });
    };
    window.addEventListener("blur", this.handleWindowBlur);
    window.addEventListener("focus", this.handleWindowFocus);

    // PrintScreen - Windows only, and there the browser only ever receives
    // the key's `keyup` (the OS swallows the `keydown`), so both are
    // listened to and de-duplicated. Win+Shift+S, screenshot tools and
    // macOS shortcuts (Cmd+Shift+3/4/5) are OS-level and invisible to any
    // web page, so this can never catch those - see Athena.Engagement.Event.
    this.lastPrintScreenAt = 0;
    this.handleKeyDown = (e) => {
      if (["Alt", "Meta", "Tab", "OS"].includes(e.key)) this.lastSwitchKeyAt = Date.now();
      if (e.key === "PrintScreen" && Date.now() - this.lastPrintScreenAt > 500) {
        this.lastPrintScreenAt = Date.now();
        this.enqueue(this.currentBlockId, "printscreen_attempt");
      }
    };
    this.handleKeyUp = (e) => {
      if (e.key === "PrintScreen" && Date.now() - this.lastPrintScreenAt > 500) {
        this.lastPrintScreenAt = Date.now();
        this.enqueue(this.currentBlockId, "printscreen_attempt");
      }
    };
    document.addEventListener("keydown", this.handleKeyDown);
    document.addEventListener("keyup", this.handleKeyUp);

    // Idle detection - distinct from tab_hidden: the tab can stay focused
    // and in view while the student has simply stepped away, which
    // tab_hidden alone would never catch. Any mouse/keyboard/scroll
    // activity resets the clock; going quiet for IDLE_THRESHOLD_MS starts
    // an idle window, closed out (with its measured duration) on the next
    // sign of activity.
    this.idleStartedAt = null;
    this.idleTimer = null;

    this.resetIdleTimer = () => {
      if (this.idleStartedAt != null) {
        const durationMs = Date.now() - this.idleStartedAt;
        this.enqueue(this.currentBlockId, "idle_end", { duration_ms: durationMs });
        this.idleStartedAt = null;
      }

      clearTimeout(this.idleTimer);
      this.idleTimer = setTimeout(() => {
        this.idleStartedAt = Date.now();
        this.enqueue(this.currentBlockId, "idle_start");
      }, IDLE_THRESHOLD_MS);
    };

    this.idleActivityEvents = ["mousemove", "keydown", "scroll", "click"];
    for (const eventName of this.idleActivityEvents) {
      window.addEventListener(eventName, this.resetIdleTimer, { passive: true });
    }
    this.resetIdleTimer();

    this.handleBeforeUnload = () => this.flush();
    window.addEventListener("beforeunload", this.handleBeforeUnload);

    if (this.el.dataset.heartbeat === "true") this.startProctoring();
  },

  updated() {
    this.observeBlocks();
  },

  disconnected() {
    this.isConnected = false;
    this.checkOutage?.();
  },

  reconnected() {
    this.isConnected = true;
    this.checkOutage?.();
  },

  // Integrity telemetry that only makes sense on a real exam page (see
  // `proctoringActive/0`): the browser's own account of a connection
  // outage, the pointer leaving the window, the window sharing the screen,
  // and - for exams that require it - the fullscreen gate.
  startProctoring() {
    this.isConnected = true;
    this.isOnline = navigator.onLine;
    this.outageStartedAt = null;

    // One outage = from the first moment either the network or the socket
    // went away until both are back; short blips are normal LiveView
    // reconnects and not worth reporting.
    this.checkOutage = () => {
      const healthy = this.isOnline && this.isConnected;
      if (!healthy && this.outageStartedAt == null) {
        this.outageStartedAt = Date.now();
      } else if (healthy && this.outageStartedAt != null) {
        const durationMs = Date.now() - this.outageStartedAt;
        this.outageStartedAt = null;
        if (durationMs >= 5_000) {
          this.enqueue(this.currentBlockId, "offline_period", { duration_ms: durationMs });
        }
      }
    };
    this.handleOffline = () => {
      this.isOnline = false;
      this.checkOutage();
    };
    this.handleOnline = () => {
      this.isOnline = true;
      this.checkOutage();
    };
    window.addEventListener("offline", this.handleOffline);
    window.addEventListener("online", this.handleOnline);

    // The pointer leaving the window catches reading a neighbouring window
    // by hovering it (scrolling works without a click), which never fires
    // blur or visibilitychange.
    this.pointerLeftAt = null;
    this.handleMouseLeave = () => {
      this.pointerLeftAt = Date.now();
    };
    this.handleMouseEnter = () => {
      if (this.pointerLeftAt == null) return;
      const durationMs = Date.now() - this.pointerLeftAt;
      this.pointerLeftAt = null;
      if (durationMs >= 2_000) {
        this.enqueue(this.currentBlockId, "mouse_left", { duration_ms: durationMs });
      }
    };
    document.documentElement.addEventListener("mouseleave", this.handleMouseLeave);
    document.documentElement.addEventListener("mouseenter", this.handleMouseEnter);

    this.startGeometryWatch();
    if (this.el.dataset.fullscreen === "true") this.startFullscreenGate();
  },

  // "Window shares the screen" = the browser's *outer* width is a fraction
  // of the screen's usable width. Outer dimensions, not `innerWidth`: zoom
  // and a docked DevTools change the inner size but not the outer one.
  // Touch devices and small screens are skipped, and a change must hold for
  // ten seconds before it is reported so dragging a window doesn't spam.
  startGeometryWatch() {
    const SPLIT_RATIO = 0.65;
    let reported = false;
    let pending = null;

    const classify = () => {
      if (document.fullscreenElement) return false;
      if (window.matchMedia("(pointer: coarse)").matches) return false;
      if (screen.availWidth < 1000) return false;
      return window.outerWidth / screen.availWidth <= SPLIT_RATIO;
    };

    const evaluate = () => {
      const split = classify();
      clearTimeout(pending);
      if (split === reported) return;
      pending = setTimeout(() => {
        if (classify() !== split) return;
        reported = split;
        this.enqueue(this.currentBlockId, "window_geometry_changed", {
          split,
          ratio: Number((window.outerWidth / screen.availWidth).toFixed(2)),
        });
      }, 10_000);
    };

    this.handleResize = evaluate;
    window.addEventListener("resize", this.handleResize);
    this.geometryTimer = setInterval(evaluate, 5_000);
    evaluate();
  },

  // A blocking overlay until the page is fullscreen. Fullscreen can only be
  // entered from a user gesture, so entering is a button, not automatic.
  // Leaving it (Esc, F11) brings the overlay back over the questions and is
  // reported with how long the student was out. The overlay lives on
  // <body>, outside what LiveView patches. Browsers without the API get no
  // gate and no penalty.
  startFullscreenGate() {
    const root = document.documentElement;
    if (!root.requestFullscreen) return;

    const overlay = document.createElement("div");
    overlay.id = "fullscreen-gate";
    overlay.className =
      "fixed inset-0 z-[10000] flex items-center justify-center bg-base-100 p-6 text-center";
    overlay.innerHTML = `
      <div class="max-w-md space-y-4">
        <h2 class="text-2xl font-black"></h2>
        <p class="text-base-content/70"></p>
        <button type="button" class="btn btn-primary"></button>
      </div>`;
    overlay.querySelector("h2").textContent = this.el.dataset.fsTitle || "";
    overlay.querySelector("p").textContent = this.el.dataset.fsText || "";
    const button = overlay.querySelector("button");
    button.textContent = this.el.dataset.fsButton || "";
    button.addEventListener("click", () => root.requestFullscreen().catch(() => {}));
    document.body.appendChild(overlay);

    this.fullscreenOverlay = overlay;
    this.fullscreenLeftAt = null;

    this.handleFullscreenChange = () => {
      if (document.fullscreenElement) {
        overlay.classList.add("hidden");
        if (this.fullscreenLeftAt != null) {
          const durationMs = Date.now() - this.fullscreenLeftAt;
          this.fullscreenLeftAt = null;
          this.enqueue(this.currentBlockId, "fullscreen_exit", { duration_ms: durationMs });
        }
      } else {
        overlay.classList.remove("hidden");
        if (this.fullscreenLeftAt == null && this.hasBeenFullscreen) {
          this.fullscreenLeftAt = Date.now();
        }
      }
      if (document.fullscreenElement) this.hasBeenFullscreen = true;
    };
    document.addEventListener("fullscreenchange", this.handleFullscreenChange);
  },

  stopProctoring() {
    window.removeEventListener("offline", this.handleOffline);
    window.removeEventListener("online", this.handleOnline);
    document.documentElement.removeEventListener("mouseleave", this.handleMouseLeave);
    document.documentElement.removeEventListener("mouseenter", this.handleMouseEnter);
    window.removeEventListener("resize", this.handleResize);
    clearInterval(this.geometryTimer);

    if (this.handleFullscreenChange) {
      document.removeEventListener("fullscreenchange", this.handleFullscreenChange);
    }
    this.fullscreenOverlay?.remove();
    if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
  },

  destroyed() {
    clearInterval(this.flushTimer);
    clearTimeout(this.idleTimer);
    this.flush();
    this.stopProctoring?.();
    if (this.observer) this.observer.disconnect();
    document.removeEventListener("visibilitychange", this.handleVisibilityChange);
    document.removeEventListener("keydown", this.handleKeyDown);
    document.removeEventListener("keyup", this.handleKeyUp);
    window.removeEventListener("blur", this.handleWindowBlur);
    window.removeEventListener("focus", this.handleWindowFocus);
    window.removeEventListener("beforeunload", this.handleBeforeUnload);
    for (const eventName of this.idleActivityEvents || []) {
      window.removeEventListener(eventName, this.resetIdleTimer);
    }
  },
};

EngagementHooks.VideoTracker = {
  mounted() {
    const blockId = this.el.dataset.blockId;
    if (!blockId) return;

    const push = (eventType, payload = {}) => {
      if (!engagementTrackingActive()) return;
      this.pushEvent("engagement_batch", {
        events: [
          {
            block_id: blockId,
            event_type: eventType,
            payload,
            occurred_at: new Date().toISOString(),
          },
        ],
      });
    };

    this.lastTime = 0;

    this.onPlay = () => push("video_play", { at_sec: this.el.currentTime });
    this.onPause = () => push("video_pause", { at_sec: this.el.currentTime });
    this.onRateChange = () => push("video_rate_change", { rate: this.el.playbackRate });
    this.onEnded = () => push("video_ended", { duration: this.el.duration });

    this.onSeeking = () => {
      push("video_seek", { from_sec: this.lastTime, to_sec: this.el.currentTime });
    };

    this.onTimeUpdate = () => {
      // Track the last known position so a subsequent `seeking` event can
      // report where the jump started from.
      if (!this.el.seeking) this.lastTime = this.el.currentTime;
    };

    this.el.addEventListener("play", this.onPlay);
    this.el.addEventListener("pause", this.onPause);
    this.el.addEventListener("ratechange", this.onRateChange);
    this.el.addEventListener("ended", this.onEnded);
    this.el.addEventListener("seeking", this.onSeeking);
    this.el.addEventListener("timeupdate", this.onTimeUpdate);
  },

  destroyed() {
    this.el.removeEventListener("play", this.onPlay);
    this.el.removeEventListener("pause", this.onPause);
    this.el.removeEventListener("ratechange", this.onRateChange);
    this.el.removeEventListener("ended", this.onEnded);
    this.el.removeEventListener("seeking", this.onSeeking);
    this.el.removeEventListener("timeupdate", this.onTimeUpdate);
  },
};

// Fires the reserved `image_zoom` event (see `Athena.Engagement.Event`) the
// moment a student opens the click-to-preview lightbox on an `:image`
// block's picture (the lightbox itself is plain-JS, see the document-level
// click listener in app.js - this hook only supplies the telemetry side).
EngagementHooks.ImageZoomTracker = {
  mounted() {
    const blockId = this.el.dataset.blockId;
    if (!blockId) return;

    this.onClick = () => {
      if (!engagementTrackingActive()) return;
      this.pushEvent("engagement_batch", {
        events: [
          {
            block_id: blockId,
            event_type: "image_zoom",
            payload: {},
            occurred_at: new Date().toISOString(),
          },
        ],
      });
    };

    this.el.addEventListener("click", this.onClick);
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick);
  },
};

// Fires `attachment_open` (see `Athena.Engagement.Event`) the moment a
// student clicks a file link on an `:attachment` block. Previously this
// event type existed in the catalog but was never actually emitted by any
// code path - `attachment_metrics.open_count` was always zero.
EngagementHooks.AttachmentOpenTracker = {
  mounted() {
    const blockId = this.el.dataset.blockId;
    if (!blockId) return;

    this.onClick = () => {
      if (!engagementTrackingActive()) return;
      this.pushEvent("engagement_batch", {
        events: [
          {
            block_id: blockId,
            event_type: "attachment_open",
            payload: {},
            occurred_at: new Date().toISOString(),
          },
        ],
      });
    };

    this.el.addEventListener("click", this.onClick);
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick);
  },
};

// Blocks copy/cut/right-click on a question-prompt container (raises the
// bar against a quick Ctrl+C, not bulletproof - a determined student can
// still retype, screenshot, or use devtools) and reports the attempts as
// `copy_attempt`/`cut_attempt`/`right_click_attempt` telemetry. Only ever
// mounted on exam pages (`quiz_exam`/`ticket_exam`) - see
// `AthenaWeb.BlockComponents.render_quiz_question/1`. Right-click still
// gets blocked as a UX deterrent either way, but unlike copy/cut it has
// ordinary innocent causes (inspecting layout, a misclick), so the server
// only ever treats it as a cohort-relative behavioral-outlier signal, not
// hard evidence - see `Athena.Engagement.Proctoring`.
EngagementHooks.NoCopyGuard = {
  mounted() {
    const blockId = this.el.dataset.blockId || this.el.closest("[data-block-id]")?.dataset.blockId;

    const report = (eventType) => {
      if (!blockId || !engagementTrackingActive()) return;
      this.pushEvent("engagement_batch", {
        events: [
          {
            block_id: blockId,
            event_type: eventType,
            payload: {},
            occurred_at: new Date().toISOString(),
          },
        ],
      });
    };

    this.onCopy = (e) => {
      e.preventDefault();
      report("copy_attempt");
    };
    this.onCut = (e) => {
      e.preventDefault();
      report("cut_attempt");
    };
    this.onContextMenu = (e) => {
      e.preventDefault();
      report("right_click_attempt");
    };

    this.el.addEventListener("copy", this.onCopy);
    this.el.addEventListener("cut", this.onCut);
    this.el.addEventListener("contextmenu", this.onContextMenu);
  },

  destroyed() {
    this.el.removeEventListener("copy", this.onCopy);
    this.el.removeEventListener("cut", this.onCut);
    this.el.removeEventListener("contextmenu", this.onContextMenu);
  },
};

// Draws the `data-text` plain-text prompt onto a <canvas> instead of
// leaving it as selectable DOM text - the opt-in `render_prompt_as_image`
// toggle on `quiz_question`/`quiz_exam` questions. Recomputed on every
// mount (never stale), but loses rich formatting (bold, embedded images,
// tables, math) - the prompt is flattened to plain text server-side
// before it ever reaches this hook (see `extract_plain_text/1` in
// `AthenaWeb.BlockComponents`).
EngagementHooks.PromptCanvas = {
  mounted() {
    this.draw();
    this.onResize = () => this.draw();
    window.addEventListener("resize", this.onResize);
  },

  draw() {
    const canvas = this.el.querySelector("canvas");
    if (!canvas) return;

    const text = this.el.dataset.text || "";
    const lineHeight = 28;
    const fontSize = 17;
    const padding = 4;
    const dpr = window.devicePixelRatio || 1;
    const cssWidth = this.el.clientWidth || 640;

    const ctx = canvas.getContext("2d");
    ctx.font = `${fontSize}px ui-sans-serif, system-ui, sans-serif`;

    const wrapped = text.split("\n").flatMap((paragraph) => wrapLine(ctx, paragraph, cssWidth - padding * 2));
    const cssHeight = Math.max(wrapped.length, 1) * lineHeight + padding * 2;

    canvas.width = cssWidth * dpr;
    canvas.height = cssHeight * dpr;
    canvas.style.width = `${cssWidth}px`;
    canvas.style.height = `${cssHeight}px`;

    ctx.scale(dpr, dpr);
    ctx.font = `${fontSize}px ui-sans-serif, system-ui, sans-serif`;
    ctx.fillStyle = getComputedStyle(this.el).color || "#1f2937";
    ctx.textBaseline = "top";

    wrapped.forEach((line, index) => {
      ctx.fillText(line, padding, padding + index * lineHeight);
    });
  },

  destroyed() {
    window.removeEventListener("resize", this.onResize);
  },
};

// Detects the same exam attempt (`submission_id`) open in more than one
// tab/window of the same browser profile, via a BroadcastChannel handshake
// (falling back to localStorage + the `storage` event for older browsers).
// Only ever mounted on exam pages (`quiz_exam`/`ticket_exam`), keyed by
// `data-submission-id`, never by block - the whole attempt is one exam, not
// per-question. A tab that hears from a peer both reports the violation
// itself and replies, so whichever tab mounted first also gets flagged
// once the second tab shows up, not just the second tab.
EngagementHooks.MultiTabGuard = {
  mounted() {
    const submissionId = this.el.dataset.submissionId;
    const blockId = this.el.dataset.blockId;
    if (!submissionId || !blockId) return;

    this.tabId = `${Date.now()}-${Math.random().toString(36).slice(2)}`;
    this.reported = false;

    const report = () => {
      if (this.reported || !engagementTrackingActive()) return;
      this.reported = true;
      this.pushEvent("engagement_batch", {
        events: [
          {
            block_id: blockId,
            event_type: "multi_tab_detected",
            payload: {},
            occurred_at: new Date().toISOString(),
          },
        ],
      });
    };

    if (typeof BroadcastChannel !== "undefined") {
      this.channel = new BroadcastChannel(`exam-${submissionId}`);
      this.channel.onmessage = (event) => {
        if (event.data?.tabId && event.data.tabId !== this.tabId) {
          report();
          this.channel.postMessage({ tabId: this.tabId });
        }
      };
      this.channel.postMessage({ tabId: this.tabId });
    } else {
      this.storageKey = `exam-tab-${submissionId}`;
      this.handleStorage = (event) => {
        if (event.key === this.storageKey && event.newValue && event.newValue !== this.tabId) {
          report();
        }
      };
      window.addEventListener("storage", this.handleStorage);
      try {
        localStorage.setItem(this.storageKey, this.tabId);
      } catch {
        // Private browsing / storage disabled - silently no-op, this signal
        // is best-effort.
      }
    }
  },

  destroyed() {
    if (this.channel) this.channel.close();
    if (this.handleStorage) window.removeEventListener("storage", this.handleStorage);
  },
};

function wrapLine(ctx, text, maxWidth) {
  if (text === "") return [""];

  const words = text.split(" ");
  const lines = [];
  let current = "";

  for (const word of words) {
    const candidate = current === "" ? word : `${current} ${word}`;
    if (ctx.measureText(candidate).width > maxWidth && current !== "") {
      lines.push(current);
      current = word;
    } else {
      current = candidate;
    }
  }
  if (current !== "") lines.push(current);

  return lines.length > 0 ? lines : [""];
}
