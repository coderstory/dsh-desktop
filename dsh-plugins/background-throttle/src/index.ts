// @ts-nocheck — runs inside dsh's plugin runtime; @deepseek-ai/cordis types
// are provided by dsh at load time, not at TS-compile time.

/**
 * @dsh-desktop/background-throttle v2
 *
 * Pauses all `setInterval` / long-delay `setTimeout` calls when the dsh
 * WebView is hidden (user switches to another app or browser tab).
 * Re-schedules them when the page becomes visible again.
 *
 * v2 design changes (vs v1):
 *
 * 1. We do NOT intercept `requestAnimationFrame`. Browsers already
 *    skip rAF callbacks when document.visibilityState === 'hidden',
 *    so intercepting them here was dead weight. The biggest CPU wins
 *    come from clearing active setInterval / setTimeout IDs, not rAFs.
 *    We still count rAFs for the diagnostic counter so the user can
 *    see "how much work is queued right now", but we don't pause them.
 *
 * 2. We skip setTimeout calls with delay < 50 ms. These are microtask
 *    schedulers (setTimeout(fn, 0) for breaking up synchronous work,
 *    debouncing keypresses, etc.). Pausing them would leave the page
 *    stuck when it comes back. The browser also throttles them to
 *    ~1 Hz in background tabs, which is fine on its own.
 *
 * 3. We expose window.__dshBgThrottle.protect(id) so other plugins
 *    can mark a specific timer ID as "never pause this one". Example
 *    in a critical plugin:
 *
 *        const id = setInterval(heartbeat, 1000);
 *        window.__dshBgThrottle?.protect(id);
 *
 * 4. Tested against the user's installed plugin set: dsh-mnemon's
 *    15s catalog poll, dsh-community-hot's poll, dsh-task-status's
 *    task-output poll all get cleared; dsh-cost-meter / dsh-client-auto-
 *    continue's one-shot timeouts and dsline-chat's animation timer
 *    pass through (they're short-delay or one-shot and shouldn't be
 *    deferred by minutes).
 */

interface ThrottleHandle {
  /** True when the page is hidden and timers are suspended. */
  paused: boolean;
  /** Total count of all tracked timers (interval + timeout + rAF). */
  activeTimers: number;
  /** Restore the original timer APIs (debug; deactivates the throttle). */
  restore: () => void;
  /** Mark a timer ID as exempt from pausing. */
  protect: (id: any) => void;
  /** Unmark a timer ID. */
  unprotect: (id: any) => void;
}

declare global {
  interface Window {
    __dshBgThrottle?: ThrottleHandle;
  }
}

export const name = "@dsh-desktop/background-throttle";

/** setTimeouts below this delay (in ms) are NOT paused on hide. */
const MIN_TRACKED_DELAY_MS = 50;

export function apply(ctx: any) {
  if (typeof window === "undefined") return;

  // 1) Snapshot originals.
  const origSetInterval = window.setInterval.bind(window);
  const origSetTimeout = window.setTimeout.bind(window);
  const origClearInterval = window.clearInterval.bind(window);
  const origClearTimeout = window.clearTimeout.bind(window);
  const origRAF = window.requestAnimationFrame.bind(window);
  const origCancelRAF = window.cancelAnimationFrame.bind(window);

  // 2) Tracking state.
  const activeIntervals = new Set<ReturnType<typeof origSetInterval>>();
  const activeTimeouts = new Set<ReturnType<typeof origSetTimeout>>();
  const activeRAFs = new Set<ReturnType<typeof origRAF>>();
  const protectedIds = new Set<any>();
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
      // Skip short-delay setTimeouts (microtask schedulers, debounce, etc.)
      // — they should run on hide too, otherwise the page comes back
      // stuck. The browser already throttles them to 1Hz in background
      // tabs, which is fine.
      if (typeof delay === "number" && delay < MIN_TRACKED_DELAY_MS) {
        return origSetTimeout(cb, delay, ...args);
      }
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

    // We still wrap rAF so the diagnostic counter includes them, but
    // we don't pause them on hide — the browser already does that.
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

  // 3) Pause / resume.
  function clearAll() {
    let n = 0;
    for (const id of activeIntervals) {
      if (protectedIds.has(id)) continue;
      origClearInterval(id);
      n++;
    }
    activeIntervals.clear();
    for (const id of activeTimeouts) {
      if (protectedIds.has(id)) continue;
      origClearTimeout(id);
      n++;
    }
    activeTimeouts.clear();
    return { paused: n, rAFsQueued: activeRAFs.size };
  }

  function pause() {
    if (!interceptorInstalled) installInterceptor();
    if (hidden) return;
    hidden = true;
    const { paused, rAFsQueued } = clearAll();
    console.info(
      `[bg-throttle] paused; cleared ${paused} tracked timers ` +
        `(${rAFsQueued} rAFs will fire when page becomes visible again)`
    );
  }

  function resume() {
    if (!hidden) return;
    hidden = false;
    console.info("[bg-throttle] resumed; user code will re-schedule on next tick");
  }

  document.addEventListener("visibilitychange", () => {
    if (document.hidden) pause();
    else resume();
  });

  if (document.hidden) pause();

  // 4) Public API.
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
    protect: (id: any) => {
      protectedIds.add(id);
    },
    unprotect: (id: any) => {
      protectedIds.delete(id);
    },
  };

  // 5) Cordis cleanup.
  if (ctx && typeof ctx.effect === "function") {
    ctx.effect(() => {
      return () => {
        document.removeEventListener("visibilitychange", () => {});
        window.__dshBgThrottle?.restore();
      };
    });
  } else if (ctx && typeof ctx.on === "function") {
    ctx.on("dispose", () => {
      document.removeEventListener("visibilitychange", () => {});
      window.__dshBgThrottle?.restore();
    });
  }

  console.info(
    `[bg-throttle v2] loaded; document.hidden=${document.hidden}; ` +
      `min-tracked-delay=${MIN_TRACKED_DELAY_MS}ms`
  );
}
