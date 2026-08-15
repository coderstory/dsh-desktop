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
    public typealias WhichFunc = (String) -> String?

    /// Default implementation: spawn `/usr/bin/env which dsh` and parse stdout.
    public static let whichDefault: WhichFunc = { name in
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["which", name]
        let pipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            Log.errors.error("DshLocator: failed to spawn `which`: \(error.localizedDescription)")
            return nil
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            Log.app.info("DshLocator: `which \(name)` returned exit \(proc.terminationStatus)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
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