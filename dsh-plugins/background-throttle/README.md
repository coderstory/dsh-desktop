# @dsh-desktop/background-throttle

A dsh plugin that pauses all JS timers (`setInterval`, `setTimeout`,
`requestAnimationFrame`) when the dsh WebView is hidden. Designed
to address the "many plugins → high CPU" complaint.

## Why

dsh's WebView keeps running JavaScript at full speed even when the
user is looking at another app or another browser tab. With many
plugins installed, those plugins can easily saturate the main thread
between long tasks (>50ms), which the DshDesktop wrapper surfaces as
`document.visibilityState === 'hidden'`.

This plugin intercepts the timer APIs, tracks every active ID, and
clears them all on `visibilitychange → hidden`. The user code will
re-schedule on the next visible tick (the standard browser behavior
for setInterval/setTimeout when the page is hidden anyway).

## Install

The DshDesktop wrapper auto-installs this plugin by bundling it under
`Contents/Resources/dsh-plugins/background-throttle/` and passing
`--patch` to dsh on launch.

For standalone use (e.g. `pnpm dsh web` in a regular browser):

```bash
# Build the wrapper once so it copies the plugin into the bundle
./scripts/bundle.sh

# Find the bundled plugin source
PLUGIN="$(pwd)/build/DshDesktop.app/Contents/Resources/dsh-plugins/background-throttle/src/index.ts"

# Generate a patch file pointing at the plugin
cat > /tmp/bg-throttle.yml <<EOF
- insert:
    - id: background-throttle
      name: '${PLUGIN}'
EOF

# Launch dsh with the patch
pnpm dsh web --patch /tmp/bg-throttle.yml
```

## Verify

After loading, the plugin logs to console:

```
[bg-throttle] loaded; document.hidden=false
```

When the dsh tab/window loses focus:

```
[bg-throttle] paused; cleared 14 active timers/rAFs
```

When focus returns:

```
[bg-throttle] resumed; user code will re-schedule on next tick
```

You can also inspect state from devtools:

```js
__dshBgThrottle.paused()       // → boolean
__dshBgThrottle.activeTimers()  // → number (interval + timeout + rAF combined)
__dshBgThrottle.restore()      // → undoes all interception (debug)
```

## What it does NOT do

- **Doesn't reduce JS heap pressure** — paused timers still hold their
  closures. Restart the dsh tab if memory grows.
- **Doesn't throttle per-plugin** — it throttles ALL timers globally.
  The DshDesktop wrapper's perf-monitor (in Settings → Diagnostics)
  can help identify which plugin is the worst offender.
- **Doesn't pause dsh's own LLM streaming** — the WebView's
  `fetch` / `EventSource` requests are throttled by the browser when
  hidden, but if dsh is doing CPU work *in the page* (rendering,
  parsing), this plugin won't help. The biggest win is when plugins
  poll / animate.

## License

MIT, same as the rest of DshDesktop.
