import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Owns a child `Process` that runs the dsh web backend.
/// Exposes lifecycle as a state machine for SwiftUI overlays.
@MainActor
public final class DshProcess: ObservableObject {

    public enum State: Equatable {
        case idle
        case starting
        case running
        case exited
        case failed(String)
    }

    @Published public private(set) var state: State = .idle
    public private(set) var stderrTail: String = ""

    private let executable: URL
    private let arguments: [String]
    public let port: Int
    /// True when this instance actually owns and manages a child Process.
    /// False in `--no-spawn` mode (external dsh managed by the user).
    public let ownsChild: Bool
    private var process: Process?
    private var stderrPipe: Pipe?
    private let stderrCap = 64 * 1024  // 64 KiB

    public init(executable: URL, arguments: [String], port: Int, ownsChild: Bool = true) {
        self.executable = executable
        self.arguments = arguments
        self.port = port
        self.ownsChild = ownsChild
    }

    public func start() async {
        // External mode: we don't spawn anything. Mark the process as
        // already running; the port-health check in ContentView will
        // confirm it's actually serving.
        guard ownsChild else {
            state = .running
            return
        }
        switch state {
        case .starting, .running:
            return
        case .idle, .exited, .failed:
            await launch()
        }
    }

    public func stop(timeout: TimeInterval = 2.0) async {
        // External mode: nothing to kill.
        guard ownsChild else {
            state = .exited
            return
        }
        guard let proc = process, proc.isRunning else {
            state = .exited
            return
        }
        proc.terminate()
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if proc.isRunning {
            // Foundation's Process only exposes `terminate()` (SIGTERM);
            // for an unresponsive child we escalate to SIGKILL via Darwin.
            #if canImport(Darwin)
            kill(proc.processIdentifier, SIGKILL)
            #endif
        }
        await waitForExit(of: proc)
        state = .exited
    }

    public func restart() async {
        await stop()
        await start()
    }

    // MARK: - Private

    private func launch() async {
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = arguments
        // Inherit user's PATH/environment.
        proc.environment = ProcessInfo.processInfo.environment

        let errPipe = Pipe()
        proc.standardError = errPipe
        stderrPipe = errPipe
        stderrTail = ""

        // Capture stderr tail asynchronously.
        readStderr(errPipe)

        // terminationHandler is called on a background thread;
        // hop to MainActor before mutating state.
        proc.terminationHandler = { [weak self] p in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if p.terminationReason == .uncaughtSignal {
                    self.state = .failed("dsh terminated by signal")
                } else {
                    self.state = .exited
                }
            }
        }

        state = .starting
        process = proc

        do {
            try proc.run()
        } catch {
            state = .failed("\(executable.path) failed to launch: \(error.localizedDescription)")
            return
        }
        state = .running
    }

    private func readStderr(_ pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let chunk = String(data: data, encoding: .utf8) else { return }
                self.stderrTail.append(chunk)
                if self.stderrTail.count > self.stderrCap {
                    let overflow = self.stderrTail.count - self.stderrCap
                    self.stderrTail.removeFirst(overflow)
                }
            }
        }
    }

    private func waitForExit(of proc: Process) async {
        await withCheckedContinuation { cont in
            if !proc.isRunning {
                cont.resume()
                return
            }
            let original = proc.terminationHandler
            proc.terminationHandler = { p in
                original?(p)
                cont.resume()
            }
        }
    }
}
