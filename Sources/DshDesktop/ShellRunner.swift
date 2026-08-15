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

                cont.resume(returning: Result(
                    success: proc.terminationStatus == 0,
                    exitCode: proc.terminationStatus,
                    output: output
                ))
            }
        }
    }
}