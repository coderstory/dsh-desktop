# Task 8: System Notifications on Agent Idle — Design Spec

**Date:** 2026-08-15
**Status:** Draft
**Parent plan:** `docs/superpowers/plans/2026-08-15-dsh-desktop-wrapper.md` (Tasks 1–7 complete)
**Parent spec:** `docs/superpowers/specs/2026-08-15-dsh-desktop-wrapper-design.md`

## 1. Goal

Extend `DshDesktop` so the user receives a native macOS notification when the
dsh agent finishes a streaming response (i.e., when the agent's last token
arrives and the web UI transitions out of streaming state). Currently the
wrapper shows the dsh UI but does nothing when the agent goes idle — the
user must keep the window in front and watch.

This is a strict extension of the existing wrapper. No changes to the dsh
service itself, no new IPC, no bridge into dsh internals.

## 2. Non-goals

- Not a notification of "user prompt submitted" or "agent started working"
  (only on completion).
- Not a "task name in the notification body" (we cannot reliably extract
  the task name from the DOM without coupling to dsh internals).
- Not a control-center-style overlay or in-window toast.
- Not cross-platform (macOS only via `UNUserNotificationCenter`).

## 3. Constraints

| Constraint | Decision | Why |
|---|---|---|
| Detection mechanism | DOM observation via `WKWebView.evaluateJavaScript` | User-confirmed during brainstorming; avoids fragile stdout regex |
| Polling interval | 5 seconds | User-chosen; balances CPU vs latency |
| Cooldown between notifications | 3 seconds | Prevents multi-fire when agent pauses mid-stream |
| Notification API | `UNUserNotificationCenter` (system framework) | Standard macOS 13+; no third-party deps |
| Authorization | Request on first `ContentView.task` invocation | Per Apple's recommended UX |
| Failure modes | Silent (no notification) if permission denied; no UI error | Don't interrupt the user about the notifier |
| Test strategy | TDD the state machine (no WebView); manual verification for the WebView integration | Pure-Swift state machine is testable |

## 4. Detection: the dsh DOM contract

dsh's chat conversation UI (package `@deepseek-ai/dsh-client-ui-conversation`)
exposes the streaming tail of an assistant message via a `data-streaming`
HTML attribute on a `<div>` element:

```html
<div data-streaming="true"> ... </div>   <!-- agent is producing tokens -->
<div data-streaming="false"> ... </div>  <!-- explicit idle (rare) -->
<div> ... </div>                          <!-- attribute omitted when idle -->
```

The selector is **`[data-streaming="true"]`** (presence test). While the
agent streams, at least one such element exists; when the agent goes idle,
the attribute is removed.

Source reference: `dsh-client-ui-conversation/lib/client.js:9075` in the
locally-installed npm package, which mirrors the upstream at
`github.com/deepseek-ai/deepseek-harness`.

We poll this selector every 5 seconds via `WKWebView.evaluateJavaScript`.
A boolean result, compared with the previous poll, drives the state machine.

**Robustness considerations:**
- If the selector is removed in a future dsh release, our watcher
  silently no-ops (it observes `null`, treats as "idle", never fires).
  Acceptable degradation.
- If dsh adds multiple `[data-streaming]` elements (parallel sessions),
  we treat "any present" as "busy" — same boolean.

## 5. Architecture

```
┌────────────────────────────────────────────────────────────────┐
│ DshApp                                                       │
│   Window("dsh") { ContentView(process:) }                    │
│     ContentView .task {                                      │
│       await Notifications.requestAuthorization()            │
│       await idleWatcher.start(wkWebView: wv)                 │
│     }                                                        │
└────────────────────────────────────────────────────────────────┘
                │
                ▼
┌────────────────────────────────────────────────────────────────┐
│ AgentIdleWatcher (@MainActor ObservableObject)               │
│   • 弱引用 WKWebView                                          │
│   • 每 5s timer 触发 evaluateJavaScript                       │
│   • 状态: .idle / .busy                                       │
│   • busy → idle 转换：若距上次通知 ≥3s，触发通知              │
│   • 暴露 @Published state (供 UI/调试)                       │
│   • start(wkWebView:) / stop() / reset()                      │
└────────────────────────────────────────────────────────────────┘
                │
                ▼
┌────────────────────────────────────────────────────────────────┐
│ Notifications (enum, static only)                            │
│   • static func requestAuthorization() async -> Bool         │
│   • static func notify(title: String, body: String) async    │
│   • 内部用 UNUserNotificationCenter.current()                 │
└────────────────────────────────────────────────────────────────┘
```

### Why a separate `AgentIdleWatcher` rather than putting logic in `ContentView`?

- **Testable**: the state machine is pure Swift, no `WKWebView` needed
  for TDD. Tests inject a mock "evaluator" closure.
- **Reusable**: future tasks (e.g. sound effects, status-bar icon) can
  observe the same state.
- **Bounded**: single responsibility, ~80 lines.

## 6. Components

### 6.1 `Notifications.swift` (new)

`enum Notifications` with two static methods:

```swift
public enum Notifications {
    public static func requestAuthorization() async -> Bool
    public static func notify(title: String, body: String) async
}
```

`requestAuthorization`:
- Calls `UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])`
- Returns `true` if granted, `false` otherwise
- Silent on failure (no error propagation)

`notify`:
- Creates `UNMutableNotificationContent` with title + body
- Schedules via `UNNotificationRequest` with `UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)`
- Silent on failure (logs to stderr, no user-visible error)

No state, no instance. The notification thread is the system; we don't
need to track anything.

### 6.2 `AgentIdleWatcher.swift` (new)

```swift
@MainActor
public final class AgentIdleWatcher: ObservableObject {

    public enum State: Equatable {
        case idle
        case busy
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var lastNotifiedAt: Date?

    /// Closure injected for testing; in production captures WKWebView.
    public typealias Evaluator = @MainActor () async -> Bool

    private let evaluator: Evaluator
    private let notify: (String, String) async -> Void
    private let pollInterval: TimeInterval
    private let cooldown: TimeInterval
    private var task: Task<Void, Never>?

    public init(
        pollInterval: TimeInterval = 5.0,
        cooldown: TimeInterval = 3.0,
        evaluator: @escaping Evaluator,
        notify: @escaping (String, String) async -> Void = Notifications.notify
    ) { ... }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public func reset() {
        state = .idle
        lastNotifiedAt = nil
    }

    private func runLoop() async {
        while !Task.isCancelled {
            await tick()
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    private func tick() async {
        let isBusy = await evaluator()
        let newState: State = isBusy ? .busy : .idle
        guard newState != state else { return }
        state = newState
        // Fire notification on busy→idle transition only, if cooldown elapsed.
        if case .idle = newState,
           let last = lastNotifiedAt,
           Date().timeIntervalSince(last) < cooldown {
            return
        }
        if case .idle = newState {
            lastNotifiedAt = Date()
            await notify("dsh", "Agent finished responding")
        }
    }
}
```

**Design choices:**
- `evaluator` is a closure so tests can mock without WKWebView.
- Default `notify` is `Notifications.notify`; tests inject a no-op or
  capture closure.
- `start()` is idempotent (guard).
- `reset()` clears state and last-fire time — called by `DSHWebView` after
  Reload to prevent stale notifications.
- 5s polling interval, 3s cooldown.

### 6.3 `DSHWebView.swift` (modify)

Add a `Coordinator` to capture the WKWebView for the watcher:

```swift
struct DSHWebView: NSViewRepresentable {
    let url: URL
    let onWebViewReady: ((WKWebView) -> Void)? = nil  // NEW

    func makeNSView(context: Context) -> WKWebView { ... }

    func updateNSView(_ wv: WKWebView, context: Context) { ... }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var webView: WKWebView?
        // existing reload notification observer
    }
}
```

The `onWebViewReady` closure is invoked once when the WKWebView is created.
`ContentView` passes a closure that hands the WKWebView to the watcher.

### 6.4 `ContentView.swift` (modify)

Add the watcher and wire it up:

```swift
struct ContentView: View {
    @StateObject var process: DshProcess
    @StateObject private var idleWatcher = AgentIdleWatcher(
        evaluator: { false },  // real one wired in onAppear via .task
        notify: { _, _ in }
    )
    @State private var webViewRef: WKWebView?
    // ... existing @State ...

    var body: some View {
        ZStack { ... }
        .task {
            await startFlow()
            await Notifications.requestAuthorization()
            idleWatcher.start()
        }
        // Wire the real evaluator once the WKWebView is created.
        // (See "Implementation note" below.)
    }
}
```

**Implementation note**: because `@StateObject`'s initializer runs at view
construction time (before any WKWebView exists), we cannot inject the real
`evaluateJavaScript` closure directly. Two viable approaches:

1. **Defer wiring**: `idleWatcher` starts with a dummy `evaluator` that
   returns `false`. After `startFlow()` completes (webReady), we
   re-initialize the watcher with the real closure by replacing the
   `idleWatcher` via a helper. This is awkward.

2. **Inline coordinator**: `DSHWebView`'s `Coordinator` owns the
   WKWebView reference; `ContentView` reads it via `onWebViewReady`
   and uses a manual `@MainActor`-coordinated handoff to `idleWatcher`.

Approach 2 is cleaner. The Coordinator stores the WKWebView and the
`idleWatcher` references itself. On Reload, `reset()` is called.

**Final wiring** (sketch):

```swift
// DSHWebView.Coordinator
func webViewCreated(_ wv: WKWebView) {
    webView = wv
    Task { @MainActor in
        idleWatcher?.replaceEvaluator { [weak wv] in
            guard let wv else { return false }
            return await wv.evaluateJavaScript(...)
                .flatMap { ($0 as? Bool) ?? false } ?? false
        }
        idleWatcher?.start()
    }
}
```

(`replaceEvaluator` is a small addition to `AgentIdleWatcher`.)

### 6.5 `DshApp.swift` (modify)

No direct change to `DshApp`; `ContentView` already owns the wiring
via `.task`. The `IdleWatcher` is `@StateObject` on `ContentView`.

## 7. Data flow

### 7.1 Cold start

```
DshApp.body → ContentView → .task fires
  ├─ startFlow()         (existing — waits for dsh port)
  ├─ Notifications.requestAuthorization()  (NEW — may show system prompt)
  └─ idleWatcher.start() (NEW — but evaluator is still the placeholder)
```

When `DSHWebView` constructs the WKWebView (after `webReady=true`),
the `Coordinator` invokes `idleWatcher.replaceEvaluator { evaluateJavaScript(...) }`
and calls `start()` again (idempotent — replaces task if any).

### 7.2 Normal polling tick

```
every 5s:
  tick():
    isBusy = await evaluator()  ← evaluateJavaScript("[data-streaming=true]")
    newState = isBusy ? .busy : .idle
    if newState != state:
      state = newState
      if newState == .idle and (lastNotifiedAt is nil or >3s ago):
        await notify("dsh", "Agent finished responding")
        lastNotifiedAt = now
```

### 7.3 Reload (cmd+R)

```
User presses cmd+R (existing notification)
  → DSHWebView.Coordinator receives .dshReload notification
  → wv.reload()
  → idleWatcher.reset()      ← clears state + lastNotifiedAt
```

Without reset, a reload during a busy stream would fire a stale
"finished" notification when the new page boots up idle.

### 7.4 Window close (existing)

```
windowWillClose → AppDelegate.process?.stop() → NSApp.terminate
  (idleWatcher is owned by ContentView, which is destroyed with the window)
  (the polling Task is cancelled via ContentView's deinit-like teardown)
```

`AgentIdleWatcher.stop()` is called by SwiftUI when `ContentView` is
removed from the window hierarchy (via `onDisappear`).

## 8. State machine

```
                 ┌──────┐
                 │ idle │  (initial)
                 └──┬───┘
                    │ tick: evaluator == true
                    ▼
                 ┌──────┐
                 │ busy │
                 └──┬───┘
                    │ tick: evaluator == false
                    │ AND (lastNotifiedAt is nil OR >3s ago)
                    ▼
                 ┌──────┐
                 │ idle │  ── fires notify("dsh", "Agent finished responding")
                 └──────┘
                    ▲
                    │ tick: evaluator == false
                    │ AND (lastNotifiedAt <3s ago)
                    │
                 (no notification, just transition)
```

The cooldown gates notification fires, not state transitions. State
transitions happen on every tick regardless.

## 9. UX specifics

### Notification text

| Field | Value |
|---|---|
| Title | `dsh` |
| Body | `Agent finished responding` |

User cannot customize in v1 (YAGNI; can add a setting later).

### Notification interaction

- Tapping the notification: brings the DshDesktop window to front
  (`UNNotificationContent` `userInfo: ["activate": "main"]` handled
  by macOS default behavior since the app is already running).
- No actions on the notification (no "Reply" etc.).
- Sound: default system notification sound.

### Permission prompt

- First launch: macOS shows the system "DshDesktop wants to send
  notifications" prompt.
- Subsequent launches: silent (already decided).
- If denied: `idleWatcher` continues polling but `notify` is a no-op.
  No error message, no banner — we just don't notify. Logged in
  console only.

## 10. Error handling

| Scenario | Behavior |
|---|---|
| Notification permission denied | `notify` becomes a no-op (per `requestAuthorization` return value) |
| `evaluateJavaScript` throws | Caught, treated as "no result" → idle |
| `evaluateJavaScript` returns non-Bool | Coerced to `false` (idle) — defensive |
| Watcher started twice | Second call is a no-op (guard `task == nil`) |
| WKWebView destroyed mid-polling | `evaluator` closure's `guard let wv else { return false }` returns false; watcher stays in idle |
| Window closed | SwiftUI tears down `ContentView`; `idleWatcher.stop()` called via `.onDisappear` |

## 11. Testing / Verification

### Unit (TDD)

`Tests/DshDesktopTests/AgentIdleWatcherTests.swift`:

| Test | Asserts |
|---|---|
| `init_startsInIdleState` | `state == .idle`, `lastNotifiedAt == nil` |
| `tick_evaluatorTrue_transitionsToBusy` | After tick with evaluator returning true, `state == .busy` |
| `tick_evaluatorFalse_transitionsToIdleAndFires` | After busy→idle, `notify` was called once |
| `cooldown_suppressesSecondNotification` | Two consecutive busy→idle transitions within 3s: only first fires |
| `cooldown_doesNotAffectStateTransition` | State still goes busy→idle on second transition |
| `start_isIdempotent` | Calling `start()` twice doesn't create two polling tasks |
| `stop_cancelsPolling` | After stop, ticks don't fire |
| `reset_clearsStateAndLastNotified` | reset() returns to initial state |

8 tests, all runnable without WKWebView. Use an in-test
`var busy = false` and `let evaluator = { self.busy }` to drive.

### Manual

| Test | Expected | Pass criteria |
|---|---|---|
| Cold start with dsh installed | Authorization prompt appears once | macOS system dialog visible; tapping Allow/Don't Allow terminates cleanly |
| dsh agent streams then finishes | "Agent finished responding" banner | Visible within ~5s of stream ending |
| Two tasks in quick succession (<3s gap) | Only one notification | Second task's completion suppressed by cooldown |
| Reload (cmd+R) during busy stream | No spurious "finished" notification | Watcher reset clears state |
| Close window mid-stream | No notification, no crash | `idleWatcher.stop()` cancels task |
| Permission denied in macOS settings | Watcher runs but no notifications appear | Console log only |

## 12. Files to create / modify

| File | Action |
|---|---|
| `Sources/DshDesktop/Notifications.swift` | new (~30 lines) |
| `Sources/DshDesktop/AgentIdleWatcher.swift` | new (~80 lines) |
| `Sources/DshDesktop/DSHWebView.swift` | modify (add Coordinator + onWebViewReady callback) |
| `Sources/DshDesktop/ContentView.swift` | modify (inject idleWatcher, .task wires notifications + watcher) |
| `Tests/DshDesktopTests/AgentIdleWatcherTests.swift` | new (8 tests, TDD) |
| `README.md` | modify (add "Notifications" section) |

No changes to `DshApp.swift`, `DshProcess.swift`, `DshHealthCheck.swift`,
`scripts/bundle.sh`, `scripts/sign.sh`, or Info.plist.

## 13. Out of scope (deferred)

- Custom notification body text (e.g., first line of agent's response)
- Settings UI for "enable/disable notifications" or "mute for X minutes"
- Per-session notification routing (current dsh might have multiple
  sessions in the sidebar)
- Notification actions ("Reply", "Open session", "Mark as read")
- Bundling the notification permission denial into a Settings pane

## 14. Open risks

| Risk | Mitigation |
|---|---|
| dsh removes the `[data-streaming]` attribute in a future release | Watcher silently no-ops. Acceptable degradation. Add unit test that verifies "evaluator=false" path is silent. |
| Polling creates visible CPU flicker | 5s interval × ~1ms = negligible; no mitigation needed |
| Permission prompt blocks `ContentView.task` | `requestAuthorization()` is async; we don't `await` its result. Prompt appears non-blocking. |
| WebView reload + watcher reset race | `reset()` is idempotent and MainActor-isolated. Reload notification handler hops to MainActor before calling `reset()`. |

---

**Status:** Draft, ready for plan derivation via `writing-plans` skill.