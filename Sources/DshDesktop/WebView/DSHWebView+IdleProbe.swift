import Foundation
@preconcurrency import WebKit

/// Idle-probe extension on `WKWebView`. Runs the JS query that detects
/// dsh's busy/idle indicator and returns the result.
extension WKWebView {

    /// JavaScript snippet that returns `true` when dsh's UI is showing
    /// the streaming/busy indicator. Used by `AgentIdleWatcher`.
    static let dshIdleProbeJS: String = """
        document.querySelector('[data-streaming="true"]') !== null
    """

    /// Evaluate the idle-probe JS and return the result. `false` on
    /// any error (no WKWebView, evaluation threw, non-Bool result).
    @MainActor
    func dshIsAgentStreaming() async -> Bool {
        do {
            let result = try await evaluateJavaScript(Self.dshIdleProbeJS)
            return (result as? Bool) ?? false
        } catch {
            return false
        }
    }
}
