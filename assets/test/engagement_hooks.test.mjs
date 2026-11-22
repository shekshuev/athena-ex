import assert from "node:assert/strict";
import test from "node:test";
import { EngagementHooks } from "../js/engagement_hooks.js";

function mountTracker(t, { fullscreen = false } = {}) {
  const root = new EventTarget();
  root.dataset = { heartbeat: "true" };
  root.querySelectorAll = () => [];
  const page = new EventTarget();
  page.documentElement = new EventTarget();
  page.documentElement.requestFullscreen = () => assert.fail("must not request fullscreen");
  page.fullscreenElement = fullscreen ? page.documentElement : null;
  page.visibilityState = "visible";
  page.hasFocus = () => true;
  page.createElement = () => assert.fail("must not create a monitoring overlay");
  page.exitFullscreen = () => assert.fail("must not exit the student's fullscreen");
  const browser = Object.assign(new EventTarget(), {
    innerWidth: 1905, innerHeight: 950, outerWidth: 1920, outerHeight: 1040,
    devicePixelRatio: 1, matchMedia: () => ({ matches: false }),
  });
  for (const [name, value] of Object.entries({
    window: browser, document: page, screen: { availWidth: 1920, availHeight: 1040 },
    IntersectionObserver: class { observe() {} disconnect() {} },
  })) {
    const descriptor = Object.getOwnPropertyDescriptor(globalThis, name);
    Object.defineProperty(globalThis, name, { configurable: true, writable: true, value });
    t.after(() => {
      if (descriptor) Object.defineProperty(globalThis, name, descriptor);
      else delete globalThis[name];
    });
  }
  t.mock.method(globalThis, "setInterval", () => 1);
  t.mock.method(globalThis, "clearInterval", () => {});
  t.mock.method(globalThis, "setTimeout", () => 1);
  t.mock.method(globalThis, "clearTimeout", () => {});
  const events = [];
  const tracker = Object.assign({}, EngagementHooks.EngagementTracker, {
    el: root, pushEvent: (type, payload) => events.push({ type, payload }),
  });
  tracker.mounted();
  tracker.currentBlockId = "question";
  return { tracker, page, events };
}

test("clipboard and context-menu actions remain native while reporting telemetry", (t) => {
  const { tracker, events } = mountTracker(t);
  const prompt = new EventTarget();
  prompt.dataset = { blockId: "question" };
  const clipboard = Object.assign({}, EngagementHooks.ClipboardTracker, { el: prompt });
  clipboard.mounted();
  for (const [type, expected] of [["copy", "copy_attempt"], ["cut", "cut_attempt"], ["contextmenu", "right_click_attempt"]]) {
    const event = new Event(type, { cancelable: true });
    assert.equal(prompt.dispatchEvent(event), true);
    assert.equal(event.defaultPrevented, false);
    assert.equal(events.at(-1).payload.events[0].event_type, expected);
  }
  clipboard.destroyed();
  tracker.destroyed();
});

test("fullscreen is observed without overlays, requests or forced exits", (t) => {
  const { tracker, page, events } = mountTracker(t, { fullscreen: true });
  let now = 1000;
  t.mock.method(Date, "now", () => now);
  page.fullscreenElement = null;
  page.dispatchEvent(new Event("fullscreenchange"));
  now += 5000;
  page.fullscreenElement = page.documentElement;
  page.dispatchEvent(new Event("fullscreenchange"));
  tracker.flush();
  assert.deepEqual(events.at(-1).payload.events[0].payload, { duration_ms: 5000 });
  assert.equal(events.at(-1).payload.events[0].event_type, "fullscreen_exit");
  tracker.destroyed();
});
