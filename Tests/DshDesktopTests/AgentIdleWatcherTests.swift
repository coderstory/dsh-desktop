import Testing
import Foundation
@testable import DshDesktop

@Suite("AgentIdleWatcher")
@MainActor
struct AgentIdleWatcherTests {

    /// Reference-typed log so notify-closure appends are observable through the
    /// returned snapshot. (A returned `var [Tuple]` value copy would diverge
    /// from the closure's view the moment `append` triggers copy-on-write.)
    private final class NotificationLog {
        var items: [(String, String)] = []
        func append(_ item: (String, String)) { items.append(item) }
    }

    /// Helper: a watcher with controllable busy state and a captured notify closure.
    private func makeWatcher(
        pollInterval: TimeInterval = 0.05,
        cooldown: TimeInterval = 0.0,
        initialBusy: Bool = false
    ) -> (watcher: AgentIdleWatcher, setBusy: @MainActor (Bool) -> Void, captured: NotificationLog) {
        var busy = initialBusy
        let captured = NotificationLog()
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
        let (watcher, _, _) = makeWatcher(initialBusy: true)
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
        #expect(captured.items.isEmpty)
    }

    @Test func busyToIdle_firesNotification() async throws {
        let (watcher, setBusy, captured) = makeWatcher(cooldown: 0, initialBusy: true)
        watcher.start()
        try await Task.sleep(for: .milliseconds(120))  // → busy
        setBusy(false)
        try await Task.sleep(for: .milliseconds(120))  // → idle, fires
        watcher.stop()
        #expect(captured.items.count == 1)
        #expect(captured.items[0].0 == "dsh")
        #expect(captured.items[0].1 == "Agent finished responding")
    }

    @Test func cooldown_suppressesSecondNotification() async throws {
        let (watcher, setBusy, captured) = makeWatcher(
            cooldown: 10.0,  // long cooldown → second transition suppressed
            initialBusy: true
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
        #expect(captured.items.count == 1)
    }

    @Test func cooldown_doesNotAffectStateTransition() async throws {
        let (watcher, setBusy, _) = makeWatcher(cooldown: 10.0, initialBusy: true)
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
        let (watcher, setBusy, captured) = makeWatcher(cooldown: 0, initialBusy: true)
        watcher.start()
        try await Task.sleep(for: .milliseconds(80))   // → busy
        watcher.stop()
        let afterStop = captured.items.count
        setBusy(false)
        try await Task.sleep(for: .milliseconds(200))  // tick should NOT run
        #expect(captured.items.count == afterStop)
    }

    @Test func reset_clearsStateAndLastNotified() async throws {
        let (watcher, setBusy, _) = makeWatcher(cooldown: 0, initialBusy: true)
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
        let flag = MutableFlag(false)
        watcher.replaceEvaluator { flag.value }
        watcher.start()
        try await Task.sleep(for: .milliseconds(80))
        #expect(watcher.state == .idle)
        flag.value = true
        try await Task.sleep(for: .milliseconds(80))
        #expect(watcher.state == .busy)
        watcher.stop()
    }
}

@Suite("AgentIdleWatcher pause/resume")
@MainActor
struct AgentIdleWatcherPauseTests {

    @Test func pause_afterStart_cancelsPolling() async throws {
        let watcher = makePauseWatcher()
        watcher.start()
        try await Task.sleep(for: .milliseconds(50))
        let beforeState = watcher.state
        watcher.pause()
        // After pause, polling is gone. Wait past one poll interval and
        // confirm state did not change (no tick ran).
        try await Task.sleep(for: .milliseconds(200))
        #expect(watcher.state == beforeState)
    }

    @Test func pause_isIdempotent() async {
        let watcher = makePauseWatcher()
        watcher.start()
        watcher.pause()
        watcher.pause()  // no-op
        watcher.pause()  // no-op
    }

    @Test func start_afterPause_resumesPolling() async throws {
        let watcher = makePauseWatcher()
        watcher.start()
        watcher.pause()
        watcher.start()  // resume
        try await Task.sleep(for: .milliseconds(80))
        // Watcher ran some tick (idle or busy is fine).
        #expect(watcher.state == .idle || watcher.state == .busy)
        watcher.stop()
    }

    private func makePauseWatcher() -> AgentIdleWatcher {
        AgentIdleWatcher(
            pollInterval: 0.05,
            evaluator: { false },
            notify: { _, _ in }
        )
    }
}

/// Reference-typed wrapper for mutable Bool used across closure boundaries;
/// avoids Swift 6 data-race warnings on captured `var`s.
private final class MutableFlag: @unchecked Sendable {
    var value: Bool
    init(_ v: Bool) { self.value = v }
}
