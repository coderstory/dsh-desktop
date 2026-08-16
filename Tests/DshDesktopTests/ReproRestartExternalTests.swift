import Testing
import Foundation
@testable import DshDesktop

/// External-mode "Restart dsh" must adopt ownership and relaunch, not be a
/// silent no-op (regression for the "点啥都没发生" report).
///
/// Setup: a real HTTP server (python3 http.server) listens on a test port; the
/// DshProcess is external (ownsChild == false), mirroring the wrapper's
/// "reuse existing dsh" branch. restart() must find/kill that listener and
/// flip to owned mode. The relaunched child (/bin/true) exits immediately, so
/// teardown stays clean.
@Suite("ReproRestartExternal")
@MainActor
struct ReproRestartExternalTests {

    private let testPort = 3097

    @Test func externalRestart_adoptsOwnershipAndRelaunches() async throws {
        // 1. A real listener occupies the port (stands in for an external dsh).
        let listener = Process()
        listener.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        listener.arguments = ["-m", "http.server", "\(testPort)", "--bind", "127.0.0.1"]
        listener.standardOutput = FileHandle.nullDevice
        listener.standardError = FileHandle.nullDevice
        try listener.run()
        defer { kill(listener.processIdentifier, SIGKILL) }

        try await Task.sleep(for: .milliseconds(900))
        #expect(await portOpen(testPort), "test HTTP server should listen on \(testPort)")

        // 2. External DshProcess (owns nothing yet).
        let proc = DshProcess(
            executable: URL(fileURLWithPath: "/bin/true"),
            arguments: ["x"],
            port: testPort,
            ownsChild: false
        )

        // 3. restart() must adopt ownership even though we started external.
        await proc.restart()
        try await Task.sleep(for: .milliseconds(200))
        #expect(proc.ownsChild, "restart() must adopt ownership in external mode")
    }

    private func portOpen(_ port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return false }
        do {
            let (_, resp) = try await URLSession.shared.data(from: url)
            return (resp as? HTTPURLResponse) != nil
        } catch {
            return false
        }
    }
}
