import Foundation
@preconcurrency import WebKit

/// Snapshot of dsh's in-page performance state at one sample point.
/// Populated by `WKWebView.dshPerformanceStats()`.
///
/// The wrapper cannot directly attribute CPU usage to specific plugins —
/// WebKit's `PerformanceLongTaskTiming` lacks the `attribution` field
/// Chromium has. What we *can* report: total long-task count + cumulative
/// duration, JS heap size, and a list of plugin identifiers currently
/// visible in the DOM. A user correlating "plugin X is the only one in
/// the DOM during a CPU spike" gets a strong-enough signal to act on.
public struct DshPerformanceStats: Equatable, Codable, Sendable {
    public let longTaskCount: Int
    public let longTaskTotalMs: Int
    public let lastSpikeAt: Double?
    public let memoryMB: Int?
    public let pluginCount: Int
    public let plugins: [String]

    public init(
        longTaskCount: Int,
        longTaskTotalMs: Int,
        lastSpikeAt: Double?,
        memoryMB: Int?,
        pluginCount: Int,
        plugins: [String]
    ) {
        self.longTaskCount = longTaskCount
        self.longTaskTotalMs = longTaskTotalMs
        self.lastSpikeAt = lastSpikeAt
        self.memoryMB = memoryMB
        self.pluginCount = pluginCount
        self.plugins = plugins
    }
}

extension WKWebView {

    /// JS that installs a long-task observer on first call and returns
    /// the current snapshot. Self-bootstrapping so we don't need a
    /// separate "init" call.
    static let dshPerfProbeJS: String = """
    (function() {
        if (!window.__dshPerfStats) {
            window.__dshPerfStats = { longTaskCount: 0, longTaskTotalMs: 0, lastSpikeAt: null };
            try {
                if (typeof PerformanceObserver !== 'undefined' &&
                    'longtask' in PerformanceObserver.supportedEntryTypes) {
                    new PerformanceObserver(function(list) {
                        for (const entry of list.getEntries()) {
                            if (entry.duration > 100) {
                                window.__dshPerfStats.longTaskCount++;
                                window.__dshPerfStats.longTaskTotalMs += Math.round(entry.duration);
                                window.__dshPerfStats.lastSpikeAt = performance.now();
                            }
                        }
                    }).observe({ entryTypes: ['longtask'] });
                }
            } catch (e) { /* longtask unsupported — ignore */ }
        }
        const stats = window.__dshPerfStats;
        const memory = (typeof performance !== 'undefined' && performance.memory)
            ? Math.round(performance.memory.usedJSHeapSize / 1024 / 1024)
            : null;
        const candidates = document.querySelectorAll(
            '[data-plugin-id], [data-plugin-name], [data-plugin], .plugin-name, [class*="plugin"]'
        );
        const plugins = [];
        const seen = new Set();
        candidates.forEach(function(el) {
            const name = el.dataset.pluginId
                || el.dataset.pluginName
                || el.dataset.plugin
                || el.className;
            if (name && name.length > 0 && name.length < 100 && !seen.has(name)) {
                seen.add(name);
                plugins.push(name);
            }
        });
        return JSON.stringify({
            longTaskCount: stats.longTaskCount,
            longTaskTotalMs: stats.longTaskTotalMs,
            lastSpikeAt: stats.lastSpikeAt,
            memoryMB: memory,
            pluginCount: plugins.length,
            plugins: plugins
        });
    })()
    """

    /// Evaluate the perf probe and decode the result. Returns nil on
    /// any error (no webview, evaluation threw, JSON parse failed,
    /// unexpected schema).
    @MainActor
    public func dshPerformanceStats() async -> DshPerformanceStats? {
        do {
            guard let json = try await evaluateJavaScript(Self.dshPerfProbeJS) as? String,
                  let data = json.data(using: .utf8) else { return nil }
            return try JSONDecoder().decode(DshPerformanceStats.self, from: data)
        } catch {
            return nil
        }
    }
}