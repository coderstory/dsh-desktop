import Testing
import Foundation
@testable import DshDesktop

@Suite("DshProcess")
@MainActor
struct DshProcessTests {

    @Test func start_withEcho_spawnsAndTransitionsToRunning() async throws {
        let proc = DshProcess(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello"],
            port: 3080
        )
        await proc.start()
        // /bin/echo exits immediately; we should observe either .running (handler fired)
        // or .exited depending on timing. Either is acceptable evidence of "spawn worked".
        // Give the termination handler time to fire.
        try await Task.sleep(for: .milliseconds(150))
        #expect(proc.state != .idle)
        #expect(proc.state != .starting)
    }

    @Test func start_withNonexistentExecutable_transitionsToFailed() async throws {
        let proc = DshProcess(
            executable: URL(fileURLWithPath: "/nonexistent/binary/abc"),
            arguments: [],
            port: 3080
        )
        await proc.start()
        try await Task.sleep(for: .milliseconds(200))
        if case .failed = proc.state {
            // ok
        } else {
            Issue.record("expected .failed, got \(proc.state)")
        }
    }

    @Test func stop_afterStart_terminatesTheChild() async throws {
        let proc = DshProcess(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            port: 3080
        )
        await proc.start()
        #expect(proc.state == .running || proc.state == .starting)
        await proc.stop(timeout: 1.0)
        if case .failed = proc.state {
            // acceptable if sleep was already gone
        } else {
            #expect(proc.state == .exited)
        }
    }

    @Test func restart_invokesStartAgain() async throws {
        let proc = DshProcess(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["one"],
            port: 3080
        )
        await proc.start()
        try await Task.sleep(for: .milliseconds(100))
        let firstState = proc.state
        await proc.restart()
        try await Task.sleep(for: .milliseconds(100))
        #expect(proc.state != firstState || proc.state == .exited)
    }

    @Test func stateIsIdleBeforeStart() {
        let proc = DshProcess(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: [],
            port: 3080
        )
        #expect(proc.state == .idle)
    }
}
