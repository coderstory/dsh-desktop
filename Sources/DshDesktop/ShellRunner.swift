import Foundation

/// Runs an external command and captures its combined stdout+stderr output.
/// Used by the dsh ▸ Update dsh… menu item to invoke `npm update -g` and
/// surface the result in an NSAlert.
public enum ShellRunner {

    public struct Result: Equatable {
        public let success: Bool
        public let exitCode: Int32
        public let output: String
    }

    /// Spawn `executable` with the given `arguments`, wait for it to exit,
    /// and return the merged stdout+stderr. `success` is true iff exit
    /// code == 0.
    public static func run(
        _ executable: String,
        _ arguments: [String]
    ) async -> Result {
        await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executable)
                proc.arguments = arguments
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe

                do {
                    try proc.run()
                } catch {
                    Log.errors.error("ShellRunner: failed to launch \(executable): \(error.localizedDescription)")
                    cont.resume(returning: Result(
                        success: false,
                        exitCode: -1,
                        output: "failed to launch \(executable): \(error.localizedDescription)"
                    ))
                    return
                }

                proc.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                if proc.terminationStatus != 0 {
                    Log.errors.error("ShellRunner: \(executable) exited \(proc.terminationStatus); output: \(output.prefix(200))")
                }

                cont.resume(returning: Result(
                    success: proc.terminationStatus == 0,
                    exitCode: proc.terminationStatus,
                    output: output
                ))
            }
        }
    }

    /// Get the user's full login-shell environment as `[String: String]`.
    /// Spawns `/bin/zsh -l -c 'env -0'` and parses the NUL-separated
    /// KEY=VALUE pairs that `env -0` emits.
    ///
    /// Critical for GUI apps that inherit a minimal PATH (`/usr/bin:/bin/...`)
    /// and need node/python/etc. directories from `~/.zshrc` or
    /// `~/.bash_profile`. Used by `DshProcess.launch` so child processes
    /// see the same env the user has in their terminal.
    public static func loginShellEnvironment(
        shell: String = "/bin/zsh"
    ) async -> [String: String]? {
        return await withCheckedContinuation { (cont: CheckedContinuation<[String: String]?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: shell)
                proc.arguments = ["-l", "-c", "env -0"]
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = Pipe()

                do {
                    try proc.run()
                } catch {
                    Log.errors.error("ShellRunner: failed to launch \(shell) for env: \(error.localizedDescription)")
                    cont.resume(returning: nil)
                    return
                }

                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: Self.parseEnvZero(data))
            }
        }
    }

    /// Parse NUL-separated `KEY=VALUE\0KEY=VALUE\0...` (the `env -0` format).
    /// Returns nil on parse error or empty output.
    static func parseEnvZero(_ data: Data) -> [String: String]? {
        guard !data.isEmpty else { return nil }
        // Split on NUL byte; the last entry is typically empty (env appends a
        // trailing NUL), so we filter empties.
        let segments = data.split(separator: 0x00, omittingEmptySubsequences: true)
        var env: [String: String] = [:]
        for segment in segments {
            // Data.SubSequence → Data.SubSequence, not String. Convert via
            // explicit String(decoding:) so non-UTF-8 bytes (very rare in env)
            // are skipped instead of throwing.
            let segmentData = Data(segment)
            guard let eq = segmentData.firstIndex(of: 0x3D /* = */) else { continue }
            let keyData = segmentData[segmentData.startIndex..<eq]
            let valueData = segmentData[segmentData.index(after: eq)...]
            guard let key = String(data: keyData, encoding: .utf8),
                  let value = String(data: valueData, encoding: .utf8) else { continue }
            env[key] = value
        }
        return env.isEmpty ? nil : env
    }
}