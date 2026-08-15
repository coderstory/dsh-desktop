// @ts-nocheck — runs inside dsh's plugin runtime; @deepseek-ai/cordis types
// are provided by dsh at load time, not at TS-compile time.

/**
 * @dsh-desktop/background-throttle
 *
 * Pauses all `setInterval` / `setTimeout` / `requestAnimationFrame` calls
 * when the dsh WebView is hidden (user switched tabs, minimized, or
 * another app took focus). This is the single biggest CPU win available
 * to a dsh user with many plugins installed — dsh plugins poll and
 * animate aggressively, and WebKit keeps running them at full speed
 * even when the page isn't visible.
 *
 * Implementation notes:
 * - We install a window.setInterval / setTimeout / requestAnimationFrame
 *   wrapper that tracks active IDs. On `visibilitychange` → hidden, we
 *   call the *original* clearInterval / clearTimeout / cancelAnimationFrame
 *   for every active ID and clear the tracking set. The user code's
 *   re-creation on visible will resume the work normally.
 * - The wrappers track IDs even when the page is visible (cheap; just
 *   a Set lookup on the relevant timer) so we have an exact list of what
 *   to clear when hidden.
 * - `restore()` on `window.__dshBgThrottle` puts the page back to the
 *   raw browser defaults (no interception) — useful for debugging.
 */

interface ThrottleHandle {
  paused: boolean;
  activeTimers: number;
  restore: () => void;
}

declare global {
  interface Window {
    __dshBgThrottle?: ThrottleHandle;
  }
}

export const name = "@dsh-desktop/background-throttle";

export function apply(ctx: any) {
  if (typeof window === "undefined") return;

  // 1) Snapshot the original timer functions so we can both track and
  //    (later) clear using the un-wrapped versions.
  const origSetInterval = window.setInterval.bind(window);
  const origSetTimeout = window.setTimeout.bind(window);
  const origClearInterval = window.clearInterval.bind(window);
  const origClearTimeout = window.clearTimeout.bind(window);
  const origRAF = window.requestAnimationFrame.bind(window);
  const origCancelRAF = window.cancelAnimationFrame.bind(window);

  // 2) Track active timer IDs. The wrappers push into these Sets so that
  //    when we pause we can clear exactly the ones the page scheduled.
  const activeIntervals = new Set<ReturnType<typeof origSetInterval>>();
  const activeTimeouts = new Set<ReturnType<typeof origSetTimeout>>();
  const activeRAFs = new Set<ReturnType<typeof origRAF>>();

  let hidden = document.hidden;
  let interceptorInstalled = false;

  function installInterceptor() {
    if (interceptorInstalled) return;
    interceptorInstalled = true;

    window.setInterval = function (cb: any, delay?: number, ...args: any[]) {
      const id = origSetInterval(cb, delay as number, ...args);
      activeIntervals.add(id);
      return id;
    } as typeof window.setInterval;

    window.setTimeout = function (cb: any, delay?: number, ...args: any[]) {
      const id = origSetTimeout(cb, delay as number, ...args);
      activeTimeouts.add(id);
      return id;
    } as typeof window.setTimeout;

    window.clearInterval = function (id: any) {
      activeIntervals.delete(id);
      return origClearInterval(id);
    } as typeof window.clearInterval;

    window.clearTimeout = function (id: any) {
      activeTimeouts.delete(id);
      return origClearTimeout(id);
    } as typeof window.clearTimeout;

    window.requestAnimationFrame = function (cb: FrameRequestCallback) {
      const id = origRAF(cb);
      activeRAFs.add(id);
      return id;
    } as typeof window.requestAnimationFrame;

    window.cancelAnimationFrame = function (id: any) {
      activeRAFs.delete(id);
      return origCancelRAF(id);
    } as typeof window.cancelAnimationFrame;
  }

  function clearAll() {
    let n = 0;
    for (const id of activeIntervals) { origClearInterval(id); n++; }
    for (const id of activeTimeouts) { origClearTimeout(id); n++; }
    for (const id of activeRAFs) { origCancelRAF(id); n++; }
    activeIntervals.clear();
    activeTimeouts.clear();
    activeRAFs.clear();
    return n;
  }

  function pause() {
    if (!interceptorInstalled) installInterceptor();
    if (hidden) return;
    hidden = true;
    const n = clearAll();
    console.info(`[bg-throttle] paused; cleared ${n} active timers/rAFs`);
  }

  function resume() {
    if (!hidden) return;
    hidden = false;
    console.info("[bg-throttle] resumed; user code will re-schedule on next tick");
  }

  // 3) React to visibility changes.
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) pause();
    else resume();
  });

  // 4) Handle the initial state — if the page loaded while hidden
  //    (e.g. user opened the wrapper then immediately switched away),
  //    we should still pause.
  if (document.hidden) pause();

  // 5) Expose a small debug handle on `window` so the user can inspect
  //    state from devtools (`__dshBgThrottle.paused`, `activeTimers`).
  window.__dshBgThrottle = {
    paused: () => hidden,
    activeTimers: () =>
      activeIntervals.size + activeTimeouts.size + activeRAFs.size,
    restore: () => {
      window.setInterval = origSetInterval as typeof window.setInterval;
      window.setTimeout = origSetTimeout as typeof window.setTimeout;
      window.clearInterval = origClearInterval;
      window.clearTimeout = origClearTimeout;
      window.requestAnimationFrame = origRAF;
      window.cancelAnimationFrame = origCancelRAF;
      interceptorInstalled = false;
    },
  };

  // 6) Cordis lifecycle: clean up on plugin uninstall (re-register
  //    the originals, drop the visibilitychange listener).
  if (ctx && typeof ctx.effect === "function") {
    ctx.effect(() => {
      return () => {
        document.removeEventListener("visibilitychange", () => {});
        window.__dshBgThrottle?.restore();
      };
    });
  } else if (ctx && typeof ctx.on === "function") {
    // Some Cordis versions expose `on('dispose', ...)`; fall back.
    ctx.on("dispose", () => {
      document.removeEventListener("visibilitychange", () => {});
      window.__dshBgThrottle?.restore();
    });
  }

  console.info(
    `[bg-throttle] loaded; document.hidden=${document.hidden}`
  );
}
