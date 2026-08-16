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
    // Reserved for future plugin loader. Was previously used to point at
    // the temporary cordis patch file generated for bg-throttle. With
    // the bg-throttle plugin removed, this is a no-op slot kept so a
    // future plugin-loader implementation has a hook without re-touching
    // the file shape.
    private var pluginPatchURL: URL? = nil
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

        // Compose the argv: caller-supplied args + --port.
        // We append --port to ensure dsh binds the user's chosen port
        // regardless of the caller's arguments.
        var args = arguments
        args.append(contentsOf: ["--port", String(port)])

        // Verbose: log exactly what we're about to spawn so the user
        // can see which dsh binary and which argv in Console.app /
        // `log show --predicate 'subsystem == "ai.deepseek.dsh.desktop"'`.
        // The wrapper may be finding the wrong dsh via the login shell
        // (e.g. the published npm-global one vs the user's local build).
        //
        // Log levels:
        //   - .error  : dsh's stderr + non-zero exit (always shown —
        //               this is the actionable signal)
        //   - .info   : which dsh binary, which argv, env merge result
        //               (visible in `log show` only with `--info`)
        //   - .debug  : full PATH / HOME / etc. dump (only with `--debug`)
        let exePath = self.executable.path
        // Privacy: .public opts out of os.log's automatic string
        // interpolation redaction (which otherwise prints "<private>" in
        // `log show` output for any dynamic value).
        Log.app.info("spawning dsh: executable=\(exePath, privacy: .public)")
        Log.app.info("spawning dsh: arguments=\(args, privacy: .public)")
        proc.arguments = args

        // Merge the wrapper's minimal GUI env with the user's full
        // login-shell env. The wrapper is launched from Finder/Dock with
        // PATH=/usr/bin:/bin:/usr/sbin:/sbin; that misses node and any
        // npm-global bin that's not already in the wrapper's PATH. Without
        // this merge, dsh's own `#!/usr/bin/env node` shebang fails with
        // "env: node: No such file or directory".
        var env = ProcessInfo.processInfo.environment
        if let userEnv = await ShellRunner.loginShellEnvironment() {
            // User env wins for PATH (and most other vars). The wrapper's
            // existing env values stay for keys the user shell didn't set.
            for (key, value) in userEnv {
                env[key] = value
            }
            Log.app.info("spawning dsh: merged login-shell env (\(userEnv.count, privacy: .public) keys)")
        } else {
            Log.app.notice("spawning dsh: could not read login-shell env — using wrapper's minimal env")
        }
        proc.environment = env

        // Launch dsh rooted at its profile directory. dsh resolves its
        // plugin-bundle loader entries (cordis:include → the profile's
        // node_modules) relative to the *current working directory*. The
        // wrapper is launched from Finder/Dock, so its own cwd is the
        // .app bundle / repo — from there node's ESM loader can't reach
        // the profile's node_modules and every profile plugin import
        // fails with ERR_MODULE_NOT_FOUND (dsh boot aborts). Chdir into
        // the profile so plugin resolution matches a manually-launched
        // `dsh --profile web`.
        if let dshHome = env["DSH_HOME"], !dshHome.isEmpty {
            proc.currentDirectoryURL = URL(fileURLWithPath: dshHome)
                .appendingPathComponent("profiles")
                .appendingPathComponent("web")
        } else {
            let home = env["HOME"] ?? NSHomeDirectory()
            proc.currentDirectoryURL = URL(fileURLWithPath: home)
                .appendingPathComponent(".dsh/profiles/web")
        }
        // Only honor the cwd if it actually exists — otherwise leave it
        // inherited so Process doesn't fail to spawn (a nonexistent cwd
        // aborts launch).
        if let cwd = proc.currentDirectoryURL {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDir)
            if exists && isDir.boolValue {
                Log.app.info("spawning dsh: cwd = \(cwd.path, privacy: .public)")
            } else {
                Log.app.notice("spawning dsh: cwd \(cwd.path, privacy: .public) missing — leaving inherited")
                proc.currentDirectoryURL = nil
            }
        }

        // Dump PATH / HOME / etc. at debug level — visible only with
        // `log show ... --debug`. Keeps the user's default filter clean.
        if let path = env["PATH"] {
            Log.app.debug("spawning dsh: PATH=\(path, privacy: .public)")
        }
        if let home = env["HOME"] {
            Log.app.debug("spawning dsh: HOME=\(home, privacy: .public)")
        }
        if let nodePath = env["NODE_PATH"] {
            Log.app.debug("spawning dsh: NODE_PATH=\(nodePath, privacy: .public)")
        }
        // Dsh looks at DSH_HOME too
        if let dshHome = env["DSH_HOME"] {
            Log.app.debug("spawning dsh: DSH_HOME=\(dshHome, privacy: .public)")
        }

        let errPipe = Pipe()
        proc.standardError = errPipe
        stderrPipe = errPipe
        stderrTail = ""

        // Capture stderr tail asynchronously.
        readStderr(errPipe)

        // terminationHandler is called on a background thread;
        // hop to MainActor before mutating state. Log dsh's stderr at
        // error level so it survives the user's log filter — that's the
        // actual diagnostic information they need.
        proc.terminationHandler = { [weak self] p in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if p.terminationReason == .uncaughtSignal {
                    Log.dsh.error("dsh killed by signal")
                    self.state = .failed("dsh terminated by signal")
                } else if p.terminationStatus != 0 {
                    // Dump whatever dsh said on stderr — this is the
                    // actual error message dsh emitted.
                    let stderr = self.stderrTail
                    Log.dsh.error("dsh exited with code \(p.terminationStatus, privacy: .public)")
                    if !stderr.isEmpty {
                        Log.dsh.error("dsh stderr (\(stderr.count, privacy: .public) chars):\n\(stderr, privacy: .public)")
                    }
                    self.state = .failed("dsh exited with code \(p.terminationStatus)")
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
