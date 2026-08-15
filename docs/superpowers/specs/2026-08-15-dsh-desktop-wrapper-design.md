# DSH Desktop Wrapper — Design Spec

**Date:** 2026-08-15
**Status:** Draft
**Target:** macOS desktop shell around the `dsh --profile web` web service

## 1. Goal

Wrap the existing `dsh` Node.js web service (listening on `127.0.0.1:3080`) inside
a native macOS app so the user gets a dedicated Dock icon, a real window, and
the macOS menu/window affordances — instead of having to open Chrome and bookmark
the localhost URL.

**Non-goals:**
- Distributing the wrapper to other users (no notarization, no Sparkle,
  no auto-update).
- Deep macOS integration beyond stock menu/shortcuts.
- Re-implementing dsh UI in Swift; we load the existing web UI as-is via
  WKWebView.

## 2. Constraints

| Constraint | Decision | Why |
|---|---|---|
| Use case | Personal use only | No signing, no notarization, ad-hoc only |
| Native integration depth | Single window + menu + shortcuts | User explicit |
| Backend coupling | None — standard localhost web | User explicit |
| Port | `127.0.0.1:3080` hardcoded | User explicit |
| Backend crash policy | Show "Restart" overlay; do not quit app | User explicit |
| Build tool | Swift Package (no Xcode project file) | User explicit |
| External deps | None beyond Apple's SDK | Keep wrapper trivial |

## 3. Architecture

```
┌──────────────────────────────────────────────────────────┐
│ DshDesktop.app                                           │
│                                                          │
│   ┌──────────────────────┐   ┌────────────────────────┐  │
│   │ DSHApp @main        │──▶│ DshWindow              │  │
│   │  SwiftUI lifecycle   │   │  NSWindowRepresentable │  │
│   └──────────────────────┘   │  holds                 │  │
│             │                │  ┌──────────────────┐  │  │
│             ▼                │  │ DSHWebView       │  │  │
│   ┌──────────────────────┐   │  │ WKWebView hosted │  │  │
│   │ DshProcessManager    │   │  │ in NSView       │  │  │
│   │  • owns Process      │◀──┤  │ load(127.0.0.1:  │  │  │
│   │  • start/stop/restart│   │  │   3080)          │  │  │
│   │  • surfaces stdout   │   │  └──────────────────┘  │  │
│   └──────────────────────┘   └────────────────────────┘  │
│                                                          │
│   ┌──────────────────────┐                                │
│   │ AppDelegate          │                                │
│   │  • windowWillClose   │                                │
│   │  • cmd+Q, cmd+W      │                                │
│   └──────────────────────┘                                │
└──────────────────────────────────────────────────────────┘
             │
             ▼
   ┌────────────────────────┐
   │ dsh --profile web (Node)│  ←─ HTTP on 127.0.0.1:3080
   └────────────────────────┘
```

## 4. Components

### 4.1 `Package.swift`

Swift Package manifest declaring one executable target `DshDesktop`,
Swift tools version 5.9+, deployment target `macOS 13.0` (required for
`WebKit` + `SwiftUI` polish).

### 4.2 `Sources/DshDesktop/main.swift` (~150 LOC total)

Five components:

| Name | Type | Responsibility |
|---|---|---|
| `DSHApp` | `@main struct` (SwiftUI `App`) | Owns the scene, menu, app lifecycle hooks |
| `DSHWindow` | `NSWindowRepresentable` | Hosts the `WKWebView`, declares window size 1200×800, title "dsh" |
| `DSHWebView` | `NSViewRepresentable` | Wraps `WKWebView`, registers message handlers, loads URL on appear |
| `DshProcess` | `class` (ObservableObject) | Owns `Process`, exposes `state: .starting/.running/.failed`, `restart()`, `stop()` |
| `DshHealthCheck` | `func` | Polls `http://127.0.0.1:3080/` every 250 ms up to 10 s; returns when 2xx |

The class `DshProcess` is the only place that knows about `Process`. The
rest of the app reads `state` and reacts.

### 4.3 Standalone shell scripts (in `scripts/`)

| File | Job |
|---|---|
| `scripts/bundle.sh` | Build with `swift build -c release`, then wrap the binary in a `.app` bundle at `build/DshDesktop.app` |
| `scripts/sign.sh` | `codesign --force --deep --sign - build/DshDesktop.app` for ad-hoc signing |

## 5. Data Flow

### 5.1 Launch

```
user clicks DshDesktop.app
  ├─ DSHApp.body runs
  ├─ DSHWindow appears (window + WKWebView in WebView mode)
  └─ DshProcess.start()
        ├─ Process executable: "/usr/bin/env" — args: ["dsh", "--profile", "web"]
        ├─ Inherits user PATH (important: user's env, not sandbox env)
        ├─ Capture stdout/stderr to a Pipe (kept for crash overlay logs)
        └─ emits state = .starting
  ├─ DSHApp subscribes to state; while .starting shows "Starting dsh…"
  ├─ DshHealthCheck.waitUntilReady(timeout: 10s) runs in Task
  │     └─ on success: state = .running
  │         └─ WKWebView.load(URL("http://127.0.0.1:3080"))
  │         └─ overlay hides
  │     └─ on timeout: state = .failed("Port 3080 not responding")
  └─ on .running: subscribes to Process termination
        └─ on exit code 0: state = .exited (user-quit case → close window too)
        └─ on exit code != 0 or signal: state = .failed(reason)
```

### 5.2 Normal exit

```
user presses cmd+Q or closes window
  ├─ windowWillClose hook fires
  ├─ DshProcess.stop()
  │     ├─ process.terminate() (sends SIGTERM)
  │     └─ if alive after 2 s: process.kill() (SIGKILL)
  └─ app.terminate(0)
```

### 5.3 dsh crash during session

```
WKWebView observes Process.terminationStatus
  ├─ state = .failed(reason from stderr tail)
  ├─ WKWebView keeps showing last content for 1 s while fade-in overlay says "dsh stopped"
  └─ overlay shows two buttons: "Restart" and "Quit"
        ├─ Restart: state = .starting; waitUntilReady again
        └─ Quit: process.stop() (no-op); app.terminate(0)
```

## 6. State Machine

`DshProcess.State`:

```
                ┌──────┐
   start() ────▶│ idle │ (transient, not observable)
                └──────┘
                    │
                    ▼
              ┌──────────┐  health OK   ┌─────────┐
       ──────▶│ starting │─────────────▶│ running │
              └──────────┘              └─────────┘
                    │                        │
                    │ health fail            │ process exit != 0
                    ▼                        ▼
              ┌──────────┐              ┌──────────┐
              │ failed   │◀─────────────│ failed   │
              └──────────┘              └──────────┘
                    │                        │
              restart()                  restart()
                    ▼                        ▼
                 back to starting
```

`failed` state holds `reason: String` derived from the captured stderr tail.

## 7. UX Specifics

### 7.1 Window

- Initial size: 1200×800, min 800×500.
- Title: `"dsh"`.
- Centered on first display on startup.
- Standard traffic-light buttons; no custom chrome.

### 7.2 Menu bar

App menu (replaces default `DshDesktop`):

- **About DshDesktop** — modal with version
- **Quit DshDesktop** (`cmd+Q`) — triggers §5.2 normal exit

File menu:

- **Open in Browser** (`cmd+B`) — `NSWorkspace.open(URL("http://127.0.0.1:3080/"))`
- **Reload** (`cmd+R`) — `wkwebView.reload()`

View menu:

- **Toggle Developer Tools** — toggles WKWebView inspector via `WKWebView` private `_inspector` if available, fall back to `NSWorkspace.open` of the inspector URL. Documented as a known macOS quirk.

Edit / Window / Help: defaults from SwiftUI `CommandGroup`.

### 7.3 Overlays (in-window, not sheet)

- `.starting`: centered `ProgressView` + label "Starting dsh…" (translucent card)
- `.failed`: translucent card with reason text + `Restart` button + `Quit` button

Both overlays rendered by a SwiftUI `ZStack` overlay layered over the
`DSHWebView`. WKWebView is always there; overlays are on top.

### 7.4 Dock icon

Default SwiftUI app icon. Bundled `AppIcon.icns` is **out of scope** for
this iteration — first-launch prompt about the generic icon is acceptable
for personal use.

## 8. Error Handling

| Trigger | Detection | Surface | Recovery |
|---|---|---|---|
| `dsh` not in PATH | `start()` resolves executable via `/usr/bin/which dsh`, fails | `.failed("`dsh` not found in PATH")` overlay with **Quit** only | Install dsh, relaunch |
| Port 3080 already in use | Health check 10 s timeout | `.failed("127.0.0.1:3080 not responding. Is something else using it?")` | User frees port, clicks Restart |
| dsh crashes mid-session | Process terminates with code != 0 / signal | §5.3 crash overlay | Restart button |
| WKWebView load fails (network) | WKNavigationDelegate `didFail` | Toast (transient) "Reload failed" | Auto-retry once after 2 s, then show toast |
| User quits dsh externally (Ctrl-C from terminal that owns the child? unlikely since we own it) | Process exit code 0 | Normal close | Auto-close window |

## 9. Build & Distribution

### 9.1 Build commands

```bash
# Compile
swift build -c release

# Wrap into .app + ad-hoc sign
./scripts/bundle.sh    # → build/DshDesktop.app
./scripts/sign.sh      # → ad-hoc signed

# Open
open build/DshDesktop.app
```

`scripts/bundle.sh` performs:
1. `swift build -c release` → `build/release/DshDesktop`
2. Creates `build/DshDesktop.app/Contents/{MacOS,Resources}`
3. Copies binary to `MacOS/DshDesktop`
4. Writes `Contents/Info.plist` with:
   - `CFBundleIdentifier=ai.deepseek.dsh.desktop`
   - `CFBundleName=DshDesktop`
   - `CFBundleShortVersionString=0.1.0`
   - `LSMinimumSystemVersion=13.0`
   - `NSHighResolutionCapable=true`
   - `LSUIElement=false`

### 9.2 Distribution

Out of scope. To install permanently, user symlinks `DshDesktop.app` into
`~/Applications`.

### 9.3 Logs

Captured `FileHandle` for dsh stderr in memory (capped 64 KiB).
Reset on each start. Surfaced via "Open Logs" link in the failed overlay
(opens `Console.app`-style viewer in a sheet — small NSView showing tail).

## 10. Testing / Verification

Manual, since the wrapper is small and integration-heavy:

| Test | Expected | Pass criteria |
|---|---|---|
| Cold start with dsh installed | App window appears, localhost 3080 loads | UI shows the dsh chat panel within 2 s |
| Cold start with dsh NOT in PATH | `.failed` overlay "dsh not found" | Quit closes app; no orphan processes |
| Port 3080 occupied (`python3 -m http.server 3080`) | `.failed` overlay "port 3080 not responding" | Restart fails the same way until port freed |
| dsh crash (`kill -9 $!` from inside dsh terminal if attached, otherwise impossible since we own it — simulate by killing via `pgrep dsh` + `kill`) | Crash overlay with Restart button | Click Restart → app recovers without quitting |
| cmd+Q with session active | App exits, no orphan `dsh` process | `pgrep -f "dsh --profile web"` returns nothing |
| Close window with red dot | Same as cmd+Q | Same |
| cmd+R while in app | WKWebView reloads | UI flashes re-render |
| cmd+B | Default browser opens 127.0.0.1:3080 | Safari/Chrome tab opens |
| Quit app, reopen | Fresh start | Overlay briefly shows, UI loads |

## 11. Out of Scope

- App icon / branding
- Auto-update / Sparkle / DMG
- Apple notarization
- Code-signed distribution beyond ad-hoc
- Multi-profile support (always `--profile web`)
- Windows / Linux
- Touch Bar controls
- Deep system integration (TouchID, system services, etc.)

## 12. Open Risks

| Risk | Mitigation |
|---|---|
| WKWebView "Toggle Developer Tools" relies on undocumented API | Falls back to opening inspector URL; acceptable for personal use |
| User's `.zshrc` PATH additions not inherited if launched from Finder vs Terminal | Document "first run from Terminal" via a fallback in `bundle.sh`'s `open -a Terminal` shortcut if PATH-in-process fails |
| dsh changes its CLI flags (e.g. `--profile` renamed) | Process spawn string is in exactly one file (`DshProcess`); changing it is a one-liner |
| Mac App Translocation blocks ad-hoc-signed apps from spawning children | README documents running once via right-click → Open |
