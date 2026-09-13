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

    this.flushTimer = setInterval(this.flush, FLUSH_INTERVAL_MS);

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

    this.handleVisibilityChange = () => {
      if (document.visibilityState === "hidden") {
        this.tabHiddenAt = Date.now();
        this.enqueue(this.currentBlockId, "tab_hidden");
      } else {
        const durationMs = this.tabHiddenAt != null ? Date.now() - this.tabHiddenAt : null;
        this.tabHiddenAt = null;
        this.enqueue(this.currentBlockId, "tab_visible", { duration_ms: durationMs });
      }
    };
    document.addEventListener("visibilitychange", this.handleVisibilityChange);

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
  },

  updated() {
    this.observeBlocks();
  },

  destroyed() {
    clearInterval(this.flushTimer);
    clearTimeout(this.idleTimer);
    this.flush();
    if (this.observer) this.observer.disconnect();
    document.removeEventListener("visibilitychange", this.handleVisibilityChange);
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
