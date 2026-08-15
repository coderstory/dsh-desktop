import Foundation

/// Polls `http://127.0.0.1:<port>/` until it returns 2xx or the timeout expires.
public enum DshHealthCheck {

    public static func waitUntilReady(
        port: Int,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.25
    ) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else {
            return false
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse,
                   (200..<300).contains(http.statusCode) {
                    return true
                }
            } catch {
                // server not yet listening — retry
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return false
    }
}