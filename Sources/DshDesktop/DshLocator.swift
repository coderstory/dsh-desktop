import Foundation

/// Locates the `dsh` executable on the user's `$PATH`.
/// Used at app launch to fail fast with a friendly "install dsh first" message
/// instead of a cryptic "command not found" from Process.
public enum DshLocator {

    public struct Location: Equatable {
        public let executablePath: String
        public let arguments: [String]   // typically `["dsh", "--profile", "web"]`
    }

    /// Mockable `which`-style function. Returns the absolute path to a binary
    /// on `$PATH`, or nil if not found.
    public typealias WhichFunc = @Sendable (String) -> String?

    /// Default implementation: tries multiple lookup strategies in order of
/// reliability. GUI apps launched from Finder/Dock inherit a minimal
/// PATH (`/usr/bin:/bin:/usr/sbin:/sbin`) which excludes npm-global bin
/// (e.g. `~/.npm-global/bin` or `~/.global-npm/bin`). A login shell (-l)
/// sources `~/.zshrc` / `~/.bash_profile` and exposes the full user PATH.
public static let whichDefault: WhichFunc = { name in
    // Order matters: login shells first (they have the user's full PATH),
    // then plain `env which` as a last-resort fallback.
    let strategies: [(String, [String])] = [
        ("/bin/zsh",     ["-l", "-c", "command -v \(name)"]),
        ("/bin/bash",    ["-l", "-c", "command -v \(name)"]),
        ("/usr/bin/env", ["which", name]),
    ]
    for (shell, args) in strategies {
        guard let path = runWhich(shell: shell, args: args, name: name) else { continue }
        return path
    }
    Log.errors.error("DshLocator: '\(name)' not found via any strategy (login shell + env which)")
    return nil
}

private static func runWhich(shell: String, args: [String], name: String) -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: shell)
    proc.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe
    do {
        try proc.run()
    } catch {
        Log.errors.error("DshLocator: failed to spawn \(shell): \(error.localizedDescription)")
        return nil
    }
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else {
        Log.app.info("DshLocator: \(shell) returned exit \(proc.terminationStatus) for `\(name)`")
        return nil
    }
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    let path = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return path.isEmpty ? nil : path
}

    /// Locate `dsh` on `$PATH`. Throws `DshLocatorError.notInstalled` if absent.
    public static func locate(which: WhichFunc = whichDefault) throws -> Location {
        guard let path = which("dsh") else {
            throw DshLocatorError.notInstalled
        }
        Log.dsh.info("located dsh at \(path)")
        return Location(executablePath: path, arguments: ["dsh", "--profile", "web"])
    }
}

public enum DshLocatorError: LocalizedError {
    case notInstalled

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return """
            dsh was not found on your PATH.

            Install with:
              npm install -g @deepseek-ai/dsh

            Then make sure your shell's PATH includes the global npm bin
            directory (usually ~/.npm-global/bin or /usr/local/bin).

            If dsh is installed but not detected, launch DshDesktop from the
            same shell where `which dsh` works, or pass --no-spawn and
            manage dsh yourself.
            """
        }
    }
}