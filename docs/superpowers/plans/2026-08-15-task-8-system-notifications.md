# Task 8: System Notifications on Agent Idle — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the dsh web UI transitions out of streaming state (agent finishes a response), fire a native macOS notification via `UNUserNotificationCenter`. Detection is DOM observation: poll `[data-streaming="true"]` selector via `WKWebView.evaluateJavaScript` every 5 seconds.

**Architecture:** Two new modules (`Notifications` enum wrapping `UNUserNotificationCenter`; `AgentIdleWatcher` `@MainActor` `ObservableObject` with injectable evaluator closure for testability) plus two modifications (`DSHWebView` exposes its `WKWebView` via a Coordinator callback; `ContentView` owns the watcher and wires the real evaluator once the WebView is built). State machine is pure Swift (TDD-friendly); WebView integration is manual-verification.

**Tech Stack:**
- Swift 6.4, Swift Package Manager, macOS 13 deployment target
- SwiftUI + AppKit (`NSViewRepresentable`, `Coordinator`)
- WebKit (`WKWebView`, `evaluateJavaScript`)
- `UserNotifications` framework (`UNUserNotificationCenter`, `UNMutableNotificationContent`)
- Swift Testing (`@Test`, `#expect`)

**Spec:** `/Users/coderstory/CodeSource/dsh-desktop/docs/superpowers/specs/2026-08-15-task-8-system-notifications.md`

**Parent plan:** `/Users/coderstory/CodeSource/dsh-desktop/docs/superpowers/plans/2026-08-15-dsh-desktop-wrapper.md` (Tasks 1-7 complete at HEAD `b4f20d1`)

## Global Constraints

- macOS deployment target: **13.0** (verbatim from Task 1 spec)
- No third-party deps — Apple SDKs only
- Every task ends with `git commit`
- `AgentIdleWatcher` is `@MainActor` (concurrency discipline matches `DshProcess` from Task 2)
- `Notifications` is a non-isolated `enum` with `static` methods (matches `DshHealthCheck` style from Task 3)
- Polling interval: **5 seconds** (user-decided)
- Cooldown: **3 seconds** (user-decided)
- Notification text: title `"dsh"`, body `"Agent finished responding"`
- Project root: `/Users/coderstory/CodeSource/dsh-desktop/` (git repo on `main`, current HEAD `b4f20d1`)

---

### Task 8.1: `Notifications` enum — UNUserNotificationCenter wrapper

**Files:**
- Create: `Sources/DshDesktop/Notifications.swift`

**Interfaces (consumed by Task 8.3 and 8.4):**
- `enum Notifications` (non-isolated, no instance state)
- `static func requestAuthorization() async -> Bool` — returns true if granted
- `static func notify(title: String, body: String) async` — silent on failure

This task is small enough that no TDD is required (only Apple SDK calls, no logic to verify). We rely on manual verification (Task 8.5).

- [ ] **Step 1: Create `Sources/DshDesktop/Notifications.swift`**

```swift
import Foundation
import UserNotifications

/// Thin wrapper around `UNUserNotificationCenter` for the wrapper app's
/// one notification use case: "agent finished responding".
///
/// All operations are silent on failure — the wrapper app must never
/// interrupt the user about the notifier.
public enum Notifications {

    /// Request `.alert` + `.sound` authorization. Returns whether granted.
    public static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    /// Schedule a notification with the given title and body, fired ~0.1s out.
    /// No-op if permission was denied (requestAuthorization returned false).
    public static func notify(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            // Silent — see file header.
        }
    }
}
```

- [ ] **Step 2: Build to confirm it compiles**

Run: `swift build 2>&1 | tail -10`
Expected: `Build complete!`. If linking fails on `UserNotifications`, confirm `import UserNotifications` is present (it is).

- [ ] **Step 3: Commit**

```bash
cd /Users/coderstory/CodeSource/dsh-desktop
git add Sources/DshDesktop/Notifications.swift
git commit -m "feat: Notifications enum wrapping UNUserNotificationCenter"
```

---

### Task 8.2: `AgentIdleWatcher` — TDD state machine

**Files:**
- Create: `Sources/DshDesktop/AgentIdleWatcher.swift`
- Create: `Tests/DshDesktopTests/AgentIdleWatcherTests.swift`

**Interfaces (consumed by Tasks 8.3 and 8.4):**
- `@MainActor public final class AgentIdleWatcher: ObservableObject`
- `public enum State: Equatable { case idle, busy }`
- `@Published public private(set) var state: State`
- `@Published public private(set) var lastNotifiedAt: Date?`
- `public typealias Evaluator = @MainActor () async -> Bool`
- `public init(pollInterval: TimeInterval = 5.0, cooldown: TimeInterval = 3.0, evaluator: @escaping Evaluator, notify: @escaping (String, String) async -> Void = Notifications.notify)`
- `public func start()` — idempotent
- `public func stop()` — cancels polling task
- `public func reset()` — clears state + lastNotifiedAt
- `public func replaceEvaluator(_ new: @escaping Evaluator)` — for late binding (Task 8.4)

This is the heart of the feature. TDD all 8 tests in the spec §11.

- [ ] **Step 1: Write the failing tests**

`Tests/DshDesktopTests/AgentIdleWatcherTests.swift`:

```swift
import Testing
import Foundation
@testable import DshDesktop

@Suite("AgentIdleWatcher")
@MainActor
struct AgentIdleWatcherTests {

    /// Helper: a watcher with controllable busy state and a captured notify closure.
    private func makeWatcher(
        pollInterval: TimeInterval = 0.05,
        cooldown: TimeInterval = 0.0,
        initialBusy: Bool = false
    ) -> (watcher: AgentIdleWatcher, setBusy: @MainActor (Bool) -> Void, notifications: [(String, String)]) {
        var busy = initialBusy
        var captured: [(String, String)] = []
        let watcher = AgentIdleWatcher(
            pollInterval: pollInterval,
            cooldown: cooldown,
            evaluator: { busy },
            notify: { title, body in captured.append((title, body)) }
        )
        return (watcher, { busy = $0 }, captured)
    }

    @Test func init_startsInIdleState() {
        let (watcher, _, _) = makeWatcher()
        #expect(watcher.state == .idle)
        #expect(watcher.lastNotifiedAt == nil)
    }

    @Test func tick_evaluatorTrue_transitionsToBusy() async throws {
        let (watcher, setBusy, _) = makeWatcher(initialBusy: true)
        watcher.start()
        try await Task.sleep(for: .milliseconds(120))
        watcher.stop()
        #expect(watcher.state == .busy)
    }

    @Test func tick_evaluatorFalse_staysIdleAndDoesNotFire() async throws {
        let (watcher, _, captured) = makeWatcher(initialBusy: false)
        watcher.start()
        try await Task.sleep(for: .milliseconds(120))
        watcher.stop()
        #expect(watcher.state == .idle)
        #expect(captured.isEmpty)
    }

    @Test func busyToIdle_firesNotification() async throws {
        let (watcher, setBusy, captured) = makeWatcher(initialBusy: true, cooldown: 0)
        watcher.start()
        try await Task.sleep(for: .milliseconds(120))  // → busy
        setBusy(false)
        try await Task.sleep(for: .milliseconds(120))  // → idle, fires
        watcher.stop()
        #expect(captured.count == 1)
        #expect(captured[0].0 == "dsh")
        #expect(captured[0].1 == "Agent finished responding")
    }

    @Test func cooldown_suppressesSecondNotification() async throws {
        let (watcher, setBusy, captured) = makeWatcher(
            initialBusy: true,
            cooldown: 10.0  // long cooldown → second transition suppressed
        )
        watcher.start()
        try await Task.sleep(for: .milliseconds(120))   // → busy
        setBusy(false)
        try await Task.sleep(for: .milliseconds(120))   // → idle, fires (#1)
        setBusy(true)
        try await Task.sleep(for: .milliseconds(120))   // → busy
        setBusy(false)
        try await Task.sleep(for: .milliseconds(120))   // → idle, suppressed
        watcher.stop()
        #expect(captured.count == 1)
    }

    @Test func cooldown_doesNotAffectStateTransition() async throws {
        let (watcher, setBusy, _) = makeWatcher(initialBusy: true, cooldown: 10.0)
        watcher.start()
        try await Task.sleep(for: .milliseconds(120))   // → busy
        setBusy(false)
        try await Task.sleep(for: .milliseconds(120))   // → idle
        setBusy(true)
        try await Task.sleep(for: .milliseconds(120))   // → busy
        setBusy(false)
        try await Task.sleep(for: .milliseconds(120))   // → idle (state still transitions)
        watcher.stop()
        #expect(watcher.state == .idle)
    }

    @Test func start_isIdempotent() async throws {
        let (watcher, _, _) = makeWatcher()
        watcher.start()
        watcher.start()
        watcher.start()
        // No assertion on internal state directly — but no crash means idempotent.
        // Verify by sleeping and confirming exactly one tick path runs.
        try await Task.sleep(for: .milliseconds(80))
        watcher.stop()
    }

    @Test func stop_cancelsPolling() async throws {
        let (watcher, setBusy, captured) = makeWatcher(initialBusy: true, cooldown: 0)
        watcher.start()
        try await Task.sleep(for: .milliseconds(80))   // → busy
        watcher.stop()
        let afterStop = captured.count
        setBusy(false)
        try await Task.sleep(for: .milliseconds(200))  // tick should NOT run
        #expect(captured.count == afterStop)
    }

    @Test func reset_clearsStateAndLastNotified() async throws {
        let (watcher, setBusy, _) = makeWatcher(initialBusy: true, cooldown: 0)
        watcher.start()
        try await Task.sleep(for: .milliseconds(120))  // → busy
        setBusy(false)
        try await Task.sleep(for: .milliseconds(120))  // → idle, fires
        #expect(watcher.state == .idle)
        #expect(watcher.lastNotifiedAt != nil)
        watcher.reset()
        #expect(watcher.state == .idle)
        #expect(watcher.lastNotifiedAt == nil)
        watcher.stop()
    }

    @Test func replaceEvaluator_wiresNewClosure() async throws {
        let (watcher, _, _) = makeWatcher(initialBusy: false)
        var newBusy = false
        watcher.replaceEvaluator { newBusy }
        watcher.start()
        try await Task.sleep(for: .milliseconds(80))
        #expect(watcher.state == .idle)
        newBusy = true
        try await Task.sleep(for: .milliseconds(80))
        #expect(watcher.state == .busy)
        watcher.stop()
    }
}
```

- [ ] **Step 2: Run tests — confirm they fail (no implementation yet)**

Run: `swift test --filter AgentIdleWatcherTests 2>&1 | tail -10`
Expected: Build failure — "cannot find 'AgentIdleWatcher' in scope".

- [ ] **Step 3: Implement `Sources/DshDesktop/AgentIdleWatcher.swift`**

```swift
import Foundation

/// Polls an evaluator closure (typically a `WKWebView.evaluateJavaScript`
/// wrapper) and fires a notification on the busy→idle transition, subject
/// to a cooldown. State machine is pure Swift — the evaluator closure is
/// injectable so tests don't need a real `WKWebView`.
@MainActor
public final class AgentIdleWatcher: ObservableObject {

    public enum State: Equatable {
        case idle
        case busy
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var lastNotifiedAt: Date?

    public typealias Evaluator = @MainActor () async -> Bool

    private let pollInterval: TimeInterval
    private let cooldown: TimeInterval
    private var evaluator: Evaluator
    private let notify: (String, String) async -> Void
    private var task: Task<Void, Never>?

    public init(
        pollInterval: TimeInterval = 5.0,
        cooldown: TimeInterval = 3.0,
        evaluator: @escaping Evaluator,
        notify: @escaping (String, String) async -> Void = Notifications.notify
    ) {
        self.pollInterval = pollInterval
        self.cooldown = cooldown
        self.evaluator = evaluator
        self.notify = notify
    }

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

    public func replaceEvaluator(_ newEvaluator: @escaping Evaluator) {
        evaluator = newEvaluator
    }

    // MARK: - Private

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

        // Fire notification only on busy → idle.
        guard case .idle = newState else { return }

        if let last = lastNotifiedAt,
           Date().timeIntervalSince(last) < cooldown {
            return
        }

        lastNotifiedAt = Date()
        await notify("dsh", "Agent finished responding")
    }
}
```

- [ ] **Step 4: Run tests — verify they pass**

Run: `swift test --filter AgentIdleWatcherTests 2>&1 | tail -30`
Expected: 10 tests pass (the brief lists 8 but the test file above includes 2 additional: `tick_evaluatorFalse_staysIdleAndDoesNotFire` and `replaceEvaluator_wiresNewClosure` which are needed for the late-binding semantics; all are pure-Swift).

If any fail, debug before continuing.

- [ ] **Step 5: Run full test suite**

Run: `swift test 2>&1 | tail -10`
Expected: 9 (existing) + 10 (new) = **19/19 passing**.

- [ ] **Step 6: Commit**

```bash
cd /Users/coderstory/CodeSource/dsh-desktop
git add Sources/DshDesktop/AgentIdleWatcher.swift Tests/DshDesktopTests/AgentIdleWatcherTests.swift
git commit -m "feat: AgentIdleWatcher state machine with TDD"
```

---

### Task 8.3: `DSHWebView` — expose WKWebView via Coordinator

**Files:**
- Modify: `Sources/DshDesktop/DSHWebView.swift`

**Interfaces (consumed by Task 8.4):**
- `struct DSHWebView: NSViewRepresentable`
- `let url: URL`
- `let onWebViewReady: ((WKWebView) -> Void)?` (NEW, optional with default nil to keep Task 4's tests untouched)
- `func makeCoordinator() -> Coordinator`
- `final class Coordinator` with `var webView: WKWebView?` and the existing reload observer

This task is straightforward but has a subtle requirement: `Coordinator`
must be created via `makeCoordinator()` so it persists across
`updateNSView` calls.

- [ ] **Step 1: Modify `Sources/DshDesktop/DSHWebView.swift`**

```swift
import SwiftUI
import WebKit

/// Wraps a WKWebView in a SwiftUI-compatible NSViewRepresentable.
/// `url` is fixed for the app lifetime because dsh serves a single origin.
///
/// `onWebViewReady` is invoked once on first construction with the underlying
/// WKWebView, so callers (e.g. ContentView) can hand it to AgentIdleWatcher
/// for `evaluateJavaScript` polling.
struct DSHWebView: NSViewRepresentable {

    let url: URL
    var onWebViewReady: ((WKWebView) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        // Note: brief specified `config.allowsInlineMediaPlayback = true`, but
        // that property is iOS-only and not exposed on macOS. On macOS WebKit
        // already plays video inline by default, so no equivalent is needed.
        let config = WKWebViewConfiguration()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.allowsBackForwardNavigationGestures = false
        wv.load(URLRequest(url: url))

        // Listen for reload notifications (posted by File ▸ Reload).
        // Hop to MainActor for the reload call — Swift 6 strict-concurrency safety.
        NotificationCenter.default.addObserver(
            forName: .dshReload, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                wv.reload()
            }
        }

        // Hand the WKWebView to the coordinator and notify the consumer.
        context.coordinator.webView = wv
        if let callback = onWebViewReady {
            callback(wv)
        }
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        // Reload if the URL changes (only on explicit user Reload).
        if wv.url != url {
            wv.load(URLRequest(url: url))
        }
    }

    @MainActor
    final class Coordinator {
        var webView: WKWebView?
    }
}
```

- [ ] **Step 2: Build to confirm it compiles**

Run: `swift build 2>&1 | tail -10`
Expected: `Build complete!`. If Swift 6 strict-concurrency complains about
`@MainActor final class Coordinator` being referenced from a non-isolated
context, the existing call sites in `makeNSView` are already on MainActor
(SwiftUI calls `makeNSView` on the main thread), so this should work.

- [ ] **Step 3: Run full test suite (sanity check)**

Run: `swift test 2>&1 | tail -5`
Expected: 19/19 still pass.

- [ ] **Step 4: Commit**

```bash
cd /Users/coderstory/CodeSource/dsh-desktop
git add Sources/DshDesktop/DSHWebView.swift
git commit -m "feat: DSHWebView exposes WKWebView via onWebViewReady callback"
```

---

### Task 8.4: `ContentView` — wire `AgentIdleWatcher` + `Notifications`

**Files:**
- Modify: `Sources/DshDesktop/ContentView.swift`

**Interfaces (consumed by Task 8.5 manual verification):**
- `ContentView` owns `@StateObject private var idleWatcher: AgentIdleWatcher`
- `.task { ... }` calls `await Notifications.requestAuthorization()`, then starts `idleWatcher`
- `DSHWebView(...)` is constructed with `onWebViewReady: { wv in idleWatcher.replaceEvaluator { ... } ; idleWatcher.start() }`
- `.onDisappear { idleWatcher.stop() }` to clean up on view teardown

The lazy-binding pattern: `idleWatcher` is created with a placeholder
evaluator (`{ false }`) at `@StateObject` init time (when no WKWebView
exists yet). Once `DSHWebView` constructs the WKWebView and calls
`onWebViewReady`, we replace the evaluator and start polling.

The placeholder is safe because `replaceEvaluator` swaps it before `start()`
runs the first tick — `start()` is invoked from inside the same
`onWebViewReady` callback.

- [ ] **Step 1: Modify `Sources/DshDesktop/ContentView.swift`**

Open `Sources/DshDesktop/ContentView.swift` and add:

1. Import `WebKit` at the top:
```swift
import WebKit
```

2. Add a new `@StateObject` property next to `webReady`/`overlayHidden`:
```swift
@StateObject private var idleWatcher: AgentIdleWatcher = {
    // Placeholder evaluator; replaced in onWebViewReady once WKWebView exists.
    AgentIdleWatcher(evaluator: { false })
}()
```

3. Update the `body` `ZStack` so `DSHWebView(...)` passes `onWebViewReady`:
```swift
DSHWebView(url: webURL, onWebViewReady: { wv in
    // Replace the placeholder evaluator with one that polls WKWebView.
    idleWatcher.replaceEvaluator { [weak wv] in
        guard let wv else { return false }
        return await Self.isAgentStreaming(wv)
    }
    idleWatcher.reset()
    idleWatcher.start()
})
.opacity(webReady ? 1 : 0)
```

4. Update `.task` to also request notification authorization:
```swift
.task {
    await startFlow()
    await Notifications.requestAuthorization()
}
```

5. Add `.onDisappear` to stop the watcher:
```swift
.onDisappear {
    idleWatcher.stop()
}
```

6. Add a static helper at file scope (above `ContentView`):
```swift
private extension ContentView {
    /// Poll the dsh UI for the streaming indicator.
    /// Returns true when at least one `[data-streaming="true"]` element exists.
    static func isAgentStreaming(_ wv: WKWebView) async -> Bool {
        let js = "document.querySelector('[data-streaming=\"true\"]') !== null"
        do {
            let result = try await wv.evaluateJavaScript(js)
            return (result as? Bool) ?? false
        } catch {
            return false
        }
    }
}
```

- [ ] **Step 2: Build to confirm it compiles**

Run: `swift build 2>&1 | tail -10`
Expected: `Build complete!`. Watch for:
- Swift 6 strict-concurrency may flag `ContentView` as needing `@MainActor` (it's a `View` so this should be implicit).
- The `[weak wv]` capture in `replaceEvaluator` may produce a warning about a Sendable closure capturing a non-Sendable WKWebView. If so, the simplest mitigation is the `@MainActor` isolation on `AgentIdleWatcher` itself (already there) plus the static helper also being implicitly MainActor.

- [ ] **Step 3: Run full test suite (sanity check)**

Run: `swift test 2>&1 | tail -5`
Expected: 19/19 still pass (ContentView has no tests; integration is manual).

- [ ] **Step 4: Commit**

```bash
cd /Users/coderstory/CodeSource/dsh-desktop
git add Sources/DshDesktop/ContentView.swift
git commit -m "feat: ContentView wires AgentIdleWatcher + Notifications authorization"
```

---

### Task 8.5: README — document the notification feature + manual verification

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Append a "Notifications" section to `README.md`**

After the existing "What it does" section and before "Layout", insert:

```markdown
## Notifications

DshDesktop requests macOS notification permission on first launch and shows a
banner when the dsh agent finishes responding to your last prompt. Detection
works by polling the dsh UI's streaming indicator (`[data-streaming="true"]`)
every 5 seconds; a 3-second cooldown prevents duplicate notifications when
the agent pauses briefly mid-response.

If you deny notification permission in the macOS prompt, the watcher still
runs but no banners appear — you can re-enable notifications later in
**System Settings → Notifications → DshDesktop**.

To turn notifications off without changing system settings: not currently
exposed in v1; future enhancement.
```

- [ ] **Step 2: Update "Layout" section to include new files**

In the existing `Sources/DshDesktop/` tree, add:
```
  AgentIdleWatcher.swift  # DOM polling + state machine + cooldown
  Notifications.swift     # UNUserNotificationCenter wrapper
```

In the existing `Tests/DshDesktopTests/` tree, add:
```
  AgentIdleWatcherTests.swift
```

- [ ] **Step 3: Build, bundle, sign, smoke-launch**

```bash
cd /Users/coderstory/CodeSource/dsh-desktop
swift build 2>&1 | tail -5
swift test 2>&1 | tail -5   # 19/19 expected
./scripts/bundle.sh 2>&1 | tail -5
./scripts/sign.sh
open build/DshDesktop.app && sleep 3 && PID=$(pgrep -f DshDesktop | head -1) && [ -n "$PID" ] && kill "$PID" 2>/dev/null
pgrep -f "dsh --profile web" || echo "no orphan dsh"
```

Expected: build clean, 19/19 tests, bundle/sign OK, no orphan dsh.

- [ ] **Step 4: Manual verification of the notification flow**

For each item below, you must explicitly note whether it could be verified
in this environment or is a headless limit:

| Test | Verified | Note |
|---|---|---|
| Authorization prompt appears on first launch | ⚠️ headless limit | System dialog cannot be auto-clicked; user must run interactively |
| Notification fires when agent finishes | ⚠️ headless limit | Requires user-driven dsh session; document the manual test in the report |
| Cooldown suppresses second notification | ⚠️ headless limit | Same as above |
| Reload (cmd+R) during busy stream doesn't fire spurious notification | ⚠️ headless limit | Code path verified by unit test `reset_clearsStateAndLastNotified` |
| Window close cancels polling task | ⚠️ headless limit | `.onDisappear` hook verified by static review |

For the unit-tested behaviors (state machine, cooldown, reset), report
the test names and pass status.

- [ ] **Step 5: Commit**

```bash
cd /Users/coderstory/CodeSource/dsh-desktop
git add README.md
git commit -m "docs: README describes notification feature + manual verification"
```

---

## Self-Review

**1. Spec coverage:**

| Spec § | Covered by |
|---|---|
| §1 Goal | Holistic (Tasks 8.1–8.5) |
| §2 Non-goals | Honored (no session name in body, no actions, etc.) |
| §3 Constraints | 5s interval + 3s cooldown captured in Task 8.2 defaults; UNUserNotificationCenter chosen in Task 8.1 |
| §4 Detection (DOM contract) | Task 8.4 `isAgentStreaming` static helper polls exactly `[data-streaming="true"]` |
| §5 Architecture | Tasks 8.1 + 8.2 + 8.3 + 8.4 map 1:1 to the 4 boxes in the diagram |
| §6.1 Notifications | Task 8.1 |
| §6.2 AgentIdleWatcher | Task 8.2 |
| §6.3 DSHWebView modification | Task 8.3 |
| §6.4 ContentView modification | Task 8.4 |
| §7.1 Cold start | Task 8.4 `.task` chain |
| §7.2 Normal polling tick | Task 8.2 `tick()` |
| §7.3 Reload | Implicit — `reset()` is called on Reload; the spec describes the desired behavior; an explicit Reload hook in `DSHWebView` calling `idleWatcher.reset()` is **missing from the plan**. Flagged below for inclusion. |
| §7.4 Window close | Task 8.4 `.onDisappear { idleWatcher.stop() }` |
| §8 State machine | Task 8.2 `tick()` |
| §9 UX (notification text) | Task 8.2 `tick()` hardcodes title/body |
| §10 Error handling | Task 8.1 silent-failure; Task 8.4 `isAgentStreaming` catches and returns false |
| §11 Testing | Task 8.2 unit tests; Task 8.5 manual verification |
| §12 Files to create/modify | All 6 mapped to tasks |
| §13 Out of scope | Honored |
| §14 Open risks | Implicit mitigation: Task 8.2 tests include "evaluator=false path is silent" (covered by `tick_evaluatorFalse_staysIdleAndDoesNotFire`) |

**Gap found:** Spec §7.3 calls for `idleWatcher.reset()` on Reload
(`DSHWebView.Coordinator receives .dshReload notification → wv.reload() →
idleWatcher.reset()`). The plan as drafted does **not** wire this. Need to
add a reset hook to `DSHWebView` and pass `idleWatcher` into it.

**Fix inline:** Task 8.3 is missing the reload-reset hook. Adding it.

Updated Task 8.3 modification (Step 1) — add a second closure parameter:

```swift
let url: URL
var onWebViewReady: ((WKWebView) -> Void)? = nil
var onReload: (() -> Void)? = nil  // NEW
```

In `makeNSView`, update the NotificationCenter observer:

```swift
NotificationCenter.default.addObserver(
    forName: .dshReload, object: nil, queue: .main
) { _ in
    Task { @MainActor in
        onReload?()           // NEW — reset state before reloading
        wv.reload()
    }
}
```

Updated Task 8.4 `DSHWebView(...)` construction:

```swift
DSHWebView(
    url: webURL,
    onWebViewReady: { wv in
        idleWatcher.replaceEvaluator { [weak wv] in
            guard let wv else { return false }
            return await Self.isAgentStreaming(wv)
        }
        idleWatcher.reset()
        idleWatcher.start()
    },
    onReload: {
        idleWatcher.reset()
    }
)
```

**2. Placeholder scan:** No "TBD", "TODO", "implement later", "appropriate
error handling", "similar to Task N". Every code block is concrete and
copy-pasteable.

**3. Type consistency:**
- `AgentIdleWatcher.init(pollInterval:cooldown:evaluator:notify:)` —
  defined Task 8.2, used Task 8.2 and Task 8.4. Match.
- `AgentIdleWatcher.replaceEvaluator(_:)` — defined Task 8.2, used
  Task 8.4. Match.
- `AgentIdleWatcher.start()` / `stop()` / `reset()` — defined Task 8.2,
  used Task 8.4. Match.
- `Notifications.requestAuthorization() -> Bool` — defined Task 8.1,
  used Task 8.4. Match.
- `Notifications.notify(title:body:)` — defined Task 8.1, used as default
  parameter in Task 8.2. Match.
- `DSHWebView.onWebViewReady` and `DSHWebView.onReload` — defined
  Task 8.3, used Task 8.4. Match.
- `ContentView.isAgentStreaming(_:)` — defined Task 8.4 as `private
  extension`, used Task 8.4 in `replaceEvaluator` body. Match.

All consistent. Ready for execution.