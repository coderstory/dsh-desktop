# @dsh-desktop/background-throttle (v2)

A dsh plugin that pauses all `setInterval` / long-delay `setTimeout`
calls when the dsh WebView is hidden (user switches to another app or
browser tab). Re-schedules them when the page becomes visible again.

## What v2 fixes (vs v1)

- **Doesn't intercept `requestAnimationFrame`.** Browsers already
  skip rAF callbacks when `document.visibilityState === 'hidden'`,
  so doing it here was dead weight. We still count rAFs for the
  diagnostic counter so the user can see "how much work is queued
  right now", but we don't actually clear them.
- **Skips `setTimeout(fn, delay)` where `delay < 50` ms.** These are
  microtask schedulers (`setTimeout(fn, 0)` to break up sync work,
  debouncing keypresses, etc.). Pausing them would leave the page
  stuck when the user comes back. The browser also throttles them to
  ~1 Hz in background tabs, which is fine on its own.
- **`protect(id)` / `unprotect(id)` API.** Other plugins can opt a
  specific timer ID out of throttling:
  ```js
  const id = setInterval(heartbeat, 1000);
  window.__dshBgThrottle?.protect(id);
  ```
  This is for plugins that have timers they consider critical (e.g.
  dsh-client-auto-continue's "next user input is imminent" poll).

## What it does NOT do

- **Doesn't reduce JS heap pressure** — paused timers still hold
  their closures. Restart the dsh tab if memory grows.
- **Doesn't pause dsh's own LLM streaming** — the WebView's `fetch`
  and `EventSource` requests are throttled by the browser when
  hidden, but if dsh is doing CPU work *in the page* (rendering,
  parsing), this plugin won't help. The biggest win is when plugins
  poll / animate.

## Tunables

| Constant | Default | Effect |
|---|---|---|
| `MIN_TRACKED_DELAY_MS` | 50 | setTimeouts below this delay are passed through unmodified (microtask safety) |

These are constants in `src/index.ts`; edit the file and reload the
plugin via dsh's HMR.

## Diagnostic API

After the plugin loads, open devtools:

```js
__dshBgThrottle.paused()       // boolean — is the page currently paused?
__dshBgThrottle.activeTimers()  // number — total tracked (interval+timeout+rAF)
__dshBgThrottle.protect(id)     // mark a timer ID as exempt
__dshBgThrottle.unprotect(id)   // unmark
__dshBgThrottle.restore()       // remove the interceptor (debug)
```

## Verified on the user's installed plugins

Tested with the user's actual installed dsh plugin set:

| Plugin | Before | After pause |
|---|---|---|
| dsh-mnemon (15s catalog poll + rAF) | always polling + animating | 0 polls, rAFs already browser-paused |
| dsh-community-hot (configurable poll) | polling per settings.pollMs | paused |
| dsh-task-status (2 intervals for task output) | polling | paused |
| dsh-cost-meter (one-shot timeout) | one-shot | runs on schedule (passes through) |
| dsh-client-auto-continue (3 timeouts) | delay/retry | run on schedule |
| dsline-chat (animation timer) | timing | runs on schedule |

The wrapper's `PerformanceMonitor` (Settings → Diagnostics → Enable
browser performance monitor) helps identify which plugin is the
worst CPU consumer.

## Install

The DshDesktop wrapper auto-installs this plugin via `--patch`. For
standalone use in a regular browser, see `cordis.yml`.

## License

MIT.
