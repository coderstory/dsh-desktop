import Foundation
@preconcurrency import WebKit

/// Polls dsh's UI performance stats every `interval` seconds when enabled.
/// Off by default — the user opts in via Preferences or `--debug`.
///
/// Why off by default: `PerformanceObserver` is cheap, but every
/// `evaluateJavaScript` round-trip is a brief WebView pause. The wrapper
/// is the user's primary tool; adding background activity by default
/// would be presumptuous.
@MainActor
public final class PerformanceMonitor: ObservableObject {

    public static let shared = PerformanceMonitor()

    @Published public private(set) var lastStats: DshPerformanceStats?
    @Published public private(set) var lastSampleAt: Date?
    @Published public var enabled: Bool = false

    /// Called on the main actor after every successful sample.
    public var onUpdate: (() -> Void)?

    private weak var webView: WKWebView?
    private var task: Task<Void, Never>?
    private let interval: TimeInterval

    public init(interval: TimeInterval = 10.0) {
        self.interval = interval
    }

    /// Bind to a webview (typically after `DSHWebView.onWebViewReady`).
    /// Idempotent; resets the previous binding.
    public func attach(to webView: WKWebView) {
        self.webView = webView
    }

    /// Start polling. No-op if already running.
    public func start() {
        guard task == nil else { return }
        let interval = self.interval
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sample()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        Log.ui.info("PerformanceMonitor: started (interval=\(interval)s)")
    }

    public func stop() {
        guard task != nil else { return }
        task?.cancel()
        task = nil
        Log.ui.info("PerformanceMonitor: stopped")
    }

    public func sample() async {
        guard enabled, let wv = webView else { return }
        guard let stats = await wv.dshPerformanceStats() else { return }
        lastStats = stats
        lastSampleAt = Date()
        if stats.longTaskCount > 0 {
            Log.app.warning("dsh perf: \(stats.longTaskCount) long tasks (>100ms), \(stats.longTaskTotalMs)ms total, \(stats.memoryMB ?? -1)MB heap, \(stats.plugins.count) plugins: \(stats.plugins.prefix(5).joined(separator: ", "))")
        }
        onUpdate?()
    }

    /// Test-only: reset transient state. Not part of the public API.
    internal func _resetForTests() {
        stop()
        lastStats = nil
        lastSampleAt = nil
        enabled = false
    }
}