import Testing
import Foundation
@testable import DshDesktop

@Suite("DshHealthMonitor")
@MainActor
struct DshHealthMonitorTests {

    @Test func shared_isSingleton() {
        #expect(DshHealthMonitor.shared === DshHealthMonitor.shared)
        DshHealthMonitor.shared._resetForTests()
    }

    @Test func stop_isIdempotent() {
        DshHealthMonitor.shared._resetForTests()
        DshHealthMonitor.shared.stop()
        DshHealthMonitor.shared.stop()  // no-op
    }

    @Test func start_isIdempotent() {
        DshHealthMonitor.shared._resetForTests()
        DshHealthMonitor.shared.start()
        DshHealthMonitor.shared.start()  // no-op
        DshHealthMonitor.shared.stop()
    }

    @Test func sample_withoutProcess_returnsEarly() async {
        DshHealthMonitor.shared._resetForTests()
        DshHealthMonitor.shared.process = nil
        await DshHealthMonitor.shared.sample()
        // No crash, no state change.
    }

    @Test func markFailedExternally_setsFailedState() {
        let proc = DshProcess(
            executable: URL(fileURLWithPath: "/bin/true"),
            arguments: [],
            port: 3080
        )
        // We can't easily test .running without spawning, but we can verify
        // the .failed transition is allowed from .idle.
        #expect(proc.state == .idle)
        proc.markFailedExternally(reason: "test")
        if case .failed(let reason) = proc.state {
            #expect(reason == "test")
        } else {
            Issue.record("expected .failed, got \(proc.state)")
        }
    }

    @Test func markFailedExternally_isNoOpWhenAlreadyFailed() {
        let proc = DshProcess(
            executable: URL(fileURLWithPath: "/bin/true"),
            arguments: [],
            port: 3080
        )
        proc.markFailedExternally(reason: "first")
        proc.markFailedExternally(reason: "second")
        // Second call should be ignored; reason remains "first".
        if case .failed(let reason) = proc.state {
            #expect(reason == "first")
        } else {
            Issue.record("expected .failed")
        }
    }
}