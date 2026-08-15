# DshDesktop

A native macOS wrapper around [`dsh --profile web`](https://github.com/deepseek-ai/deepseek-harness).
Spawns dsh as a child process, shows the web UI in a `WKWebView`,
and lives in the menu bar so the wrapper stays out of your way.

[![build & test](https://github.com/deepseek-ai/dsh-desktop/actions/workflows/build.yml/badge.svg)](https://github.com/deepseek-ai/dsh-desktop/actions/workflows/build.yml)

## Features

- **Native window** — SwiftUI + `WKWebView`; macOS-style traffic lights, drag, zoom, etc.
- **Menu bar presence** — close the window and the wrapper stays alive in the menu bar; click the icon → "Show dsh" to reopen.
- **Single instance** — launching a second copy focuses the existing window and exits.
- **Auto-spawn or reuse** — if dsh is already serving on the configured port, the wrapper connects without spawning; otherwise it spawns dsh itself.
- **Health monitoring** — if dsh dies mid-session, the wrapper detects the dead port and surfaces a "dsh stopped responding" overlay with a Restart button.
- **Bundled dsh plugin: `background-throttle`** — the wrapper auto-loads a TypeScript plugin (sourced from the sibling `../plugins/background-throttle/` directory) that pauses all `setInterval` / `setTimeout` calls when the dsh WebView is hidden (user switches to another app or browser tab) and re-schedules them when visible. This is the single biggest CPU win when you have many dsh plugins installed. The plugin lives in a sibling repo, not inside this one — the wrapper picks it up at build time and synthesizes the `--patch cordis.yml` that loads it.
- **System notifications** — fires a macOS banner when the dsh agent finishes responding to your last prompt (toggled in Settings).
- **Polling interval** — 1–60s slider in Settings; pauses automatically when the window is hidden.
- **Performance monitor** (opt-in) — detects long-running tasks (>100ms) inside dsh's UI, lists the active plugins from the DOM, and shows the data in the menu bar / a detailed alert. Useful when a dsh plugin is eating CPU.
- **Diagnostics** — `dsh ▸ Save Diagnostic Report…` writes a plain-text snapshot of the wrapper's state (prefs, monitor stats, recent os.log lines) for bug reports.
- **Auto-update dsh** — `dsh ▸ Update dsh…` runs `npm update -g @deepseek-ai/dsh` and reports the result.
- **Launch at login** — toggle in the dsh menu; backed by `SMAppService` (modern, no deprecated SMLoginItem).
- **Localized** — English + Simplified Chinese.

## Requirements

- macOS 25.0+ (Tahoe or later)
- Xcode 27+ toolchain (Swift 6.4)
- `dsh` installed and on your shell's `$PATH`

## Build & Install

```bash
./scripts/bundle.sh     # swift build -c release + assemble DshDesktop.app
./scripts/sign.sh       # ad-hoc sign
./scripts/dmg.sh        # optional: build a UDZO DMG for distribution

# Run from build:
open build/DshDesktop.app

# Or install to /Applications:
cp -R build/DshDesktop.app /Applications/
open /Applications/DshDesktop.app
```

## CLI flags

| Flag | Effect |
|---|---|
| `--port <N>` | TCP port dsh serves on (default: 3080, or from Preferences) |
| `--no-spawn` | Don't launch dsh; connect to an externally-managed dsh on `--port` |
| `--debug` | Verbose os.log output (subsystem `ai.deepseek.dsh.desktop`) |
| `--help`, `-h` | Print help and exit |

Unknown flags are silently ignored (so the test runner can pass `--test-bundle-path` etc.).

## Settings

Open with `Cmd+,`. All values persist to `UserDefaults`.

- **Server** — port (with `Apply` button; dsh restart required to take effect)
- **Notifications** — toggle "Show notification when dsh finishes"
- **Polling** — slider 1–60s; toggle "Pause polling when window is hidden"
- **Diagnostics** — toggle "Enable browser performance monitor" (off by default)

## What "design patterns" look like in the code

| Pattern | Where |
|---|---|
| State machine | `DshProcess.State` (idle / starting / running / exited / failed) |
| Strategy | `DshLocator` tries login shells (zsh, bash) then `env which` as fallback |
| Repository | `Preferences` abstracts `UserDefaults` with input sanitization |
| MVVM (light) | `DshApp` owns `process` / `prefs` / `idleWatcher` as `@StateObject`; passes to `ContentView` via init |
| Observer | `@Published` + SwiftUI `.onChange` for hot-reload (polling interval, port) |
| State | SwiftUI Window + `Settings` scenes, menu bar via `NSStatusItem` |
| Sendable | `WhichFunc`, `LoginItemProviding`, `TestHTTPServer` annotated for Swift 6 strict-concurrency |
| DI | `Preferences.init(defaults:)` injects `UserDefaults`; `LaunchConfig.current(preferences:)` injects prefs |

## File structure

```
Sources/DshDesktop/
├── DshApp.swift              # @main, AppDelegate, scene composition
├── ContentView.swift         # thin view: ZStack + startFlow
├── DSHWebView.swift          # NSViewRepresentable
├── Overlays/
│   ├── LoadingOverlay.swift  # .idle/.starting + .running!webReady
│   └── FailedOverlay.swift   # .failed with stderr scrollview
├── WebView/
│   ├── DSHWebView+IdleProbe.swift        # dshIsAgentStreaming() JS
│   └── DSHWebView+PerformanceStats.swift  # long-task + memory + plugins
├── DshProcess.swift          # state machine + spawn lifecycle + stderr tail
├── DshHealthCheck.swift      # one-shot port probe
├── DshLocator.swift          # find dsh binary via login shell
├── DshHealthMonitor.swift    # 15s port liveness poll → .failed on death
├── AgentIdleWatcher.swift    # DOM stream poll + state machine + cooldown
├── LaunchAtLogin.swift       # SMAppService.mainApp toggle
├── LaunchConfig.swift        # CLI parser (Sendable)
├── DshPlugins.swift          # background-throttle patch generator (DshPlugins)
├── Notifications.swift       # UNUserNotificationCenter wrapper
├── Preferences.swift         # UserDefaults persistence + sanitization
├── PreferencesView.swift     # Settings scene UI
├── PerformanceMonitor.swift  # 10s in-page perf poll
├── Diagnostics.swift         # diagnostic report generator
├── ShellRunner.swift         # async shell exec helper
├── Logger.swift              # os.log categories
└── Resources/
    ├── en.lproj/Localizable.strings
    ├── zh-Hans.lproj/Localizable.strings
    ├── AppIcon.svg / .icns
    ├── MenuBarIconTemplate.svg / .png / @2x.png
    └── dsh-plugins/background-throttle/   # bundled dsh plugin (TS, copied at build time)
```

The bundled dsh plugin lives in a **sibling repo**, not inside this
one, so the wrapper picks it up from `../plugins/background-throttle/`
(overrideable via `$DSHDESKTOP_PLUGINS_DIR`):

```
../plugins/
└── background-throttle/         # the dsh plugin
    ├── src/index.ts              # the plugin
    ├── cordis.yml               # standalone-use overlay
    └── README.md
```
```

## Tests

```bash
swift test                  # 70 tests across 12 suites
swift test -Xswiftc -warnings-as-errors
```

## Diagnostics

If dsh is misbehaving (high CPU, crashes, etc.), save a diagnostic report:

1. `dsh ▸ Save Diagnostic Report…` in the menu bar
2. Choose a save location
3. Open the `.txt` and include it in bug reports

The report includes:
- App / macOS / Swift versions
- All Preferences values
- DshProcess state + port + stderr tail
- PerformanceMonitor.lastStats (long-task count, duration, memory, active plugin list)
- Last 100 log entries from the wrapper's subsystem (10-minute lookback via `OSLogStore`)

To see logs in real time: `Console.app` → filter by subsystem `ai.deepseek.dsh.desktop`.

## "How do I figure out which dsh plugin is using CPU?"

Short answer: **you can't get perfect per-plugin attribution from Swift + WebKit**. WebKit's `PerformanceLongTaskTiming` lacks the `attribution` field that Chromium has, so we can't pinpoint which JS source a long task originated from. We can report:

- Total count of long tasks (>100ms)
- Cumulative duration
- JS heap size
- The list of currently-loaded plugins (from DOM `data-plugin-name` / `data-plugin-id` / `.plugin-name`)

To find the culprit: enable the performance monitor in Settings, wait for a CPU spike, and check the active plugin list. The plugin that's present during the spike is the suspect — go to dsh and disable it.

This is the limit of what WebKit exposes today. dsh would need to add its own `performance.mark('plugin-X-task')` calls per plugin for true attribution — out of scope for the wrapper.

## Known limitations

- **No automatic Sparkle update** — ad-hoc signed only. For distribution outside your own machine, sign with a Developer ID and add Sparkle.
- **No notarization** — first run on a new machine requires right-click → Open.
- **No multi-instance** — by design. If you need two wrappers (e.g. for comparing dsh versions), open a second one in a different user session.
- **dsh plugin CPU is not controllable from the wrapper** — see the "How do I figure out which dsh plugin is using CPU?" section.

## License

MIT. See `LICENSE`.
