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
    /// Whether this instance actually owns and manages a child Process.
    /// `false` means external-mode (e.g. `--no-spawn` or pre-check found dsh
    /// already running). Settable via `releaseOwnership()` so a pre-check
    /// pass can flip an initially-owned instance to external.
    public private(set) var ownsChild: Bool
    private var process: Process?
    private var stderrPipe: Pipe?
    private var pluginPatchURL: URL?
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

    /// Flip from owning the child to external mode. After this, `start()` is
    /// a no-op (state goes directly to .running) and `stop()` won't kill any
    /// process. Used by the pre-check in `ContentView.startFlow` when
    /// `127.0.0.1:<port>` is already responding on launch.
    public func releaseOwnership() {
        guard ownsChild else { return }
        ownsChild = false
        Log.dsh.info("DshProcess: ownership released — child lifecycle no longer managed")
    }

    public func stop(timeout: TimeInterval = 2.0) async {
        // External mode: nothing to kill.
        guard ownsChild else {
            state = .exited
            return
        }
        guard let proc = process, proc.isRunning else {
            // Even if the process already exited, the plugin patch file
            // we created at launch is still on disk; clean it up.
            DshPlugins.cleanup(pluginPatchURL)
            pluginPatchURL = nil
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
        DshPlugins.cleanup(pluginPatchURL)
        pluginPatchURL = nil
        state = .exited
    }

    /// Externally mark the process as failed (e.g. health monitor detects
    /// the port has stopped responding). Skips the state transition if the
    /// process is already in a terminal state (exited / failed).
    public func markFailedExternally(reason: String) {
        switch state {
        case .exited, .failed:
            return
        default:
            Log.dsh.error("DshProcess: externally marked failed — \(reason)")
            state = .failed(reason)
        }
    }

    public func restart() async {
        await stop()
        await start()
    }

    // MARK: - Private

    private func launch() async {
        let proc = Process()
        proc.executableURL = executable

        // Compose the argv: caller-supplied args + --port + (optional)
        // --patch pointing at the bundled background-throttle plugin.
        // We append --port to ensure dsh binds the user's chosen port
        // regardless of the caller's arguments.
        var args = arguments
        args.append(contentsOf: ["--port", String(port)])

        // Inject the bundled dsh plugin(s) as a patch file. This is
        // what tells dsh to load our background-throttle TypeScript
        // module alongside its own plugins.
        if let patchURL = DshPlugins.writeBackgroundThrottlePatch() {
            pluginPatchURL = patchURL
            args.append(contentsOf: ["--patch", patchURL.path])
            Log.app.info("dsh plugin patch: \(patchURL.path)")
        } else {
            Log.app.notice("dsh plugin patch not available (no bundled plugins); running dsh without patch")
        }

        proc.arguments = args
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
                    Log.dsh.error("dsh killed by signal")
                    self.state = .failed("dsh terminated by signal")
                } else if p.terminationStatus != 0 {
                    Log.dsh.error("dsh exited with code \(p.terminationStatus)")
                    self.state = .failed("dsh exited with code \(p.terminationStatus)")
                } else {
                    Log.dsh.info("dsh exited cleanly")
                    self.state = .exited
                }
            }
        }

        state = .starting
        process = proc

        do {
            try proc.run()
        } catch {
            Log.errors.error("DshProcess: failed to spawn \(self.executable.path): \(error.localizedDescription)")
            state = .failed("\(self.executable.path) failed to launch: \(error.localizedDescription)")
            return
        }
        Log.dsh.info("spawned dsh (pid \(proc.processIdentifier)) on port \(self.port)")
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
