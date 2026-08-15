import Testing
import Foundation
@testable import DshDesktop

@Suite("PerformanceMonitor")
@MainActor
struct PerformanceMonitorTests {

    /// Reset the singleton between tests so state doesn't leak.
    private func reset() {
        PerformanceMonitor.shared._resetForTests()
    }

    @Test func shared_isSingleton() {
        #expect(PerformanceMonitor.shared === PerformanceMonitor.shared)
        reset()
    }

    @Test func defaultIsDisabled() {
        reset()
        #expect(PerformanceMonitor.shared.enabled == false)
    }

    @Test func start_whenDisabled_doesNothing() {
        reset()
        PerformanceMonitor.shared.start()
        // No webview attached, so even if enabled, no polling would happen.
        // We just verify the task isn't created when disabled.
        #expect(PerformanceMonitor.shared.lastSampleAt == nil)
    }

    @Test func sample_withoutWebview_returnsEarly() async {
        reset()
        PerformanceMonitor.shared.enabled = true
        await PerformanceMonitor.shared.sample()
        #expect(PerformanceMonitor.shared.lastStats == nil)
    }

    @Test func stop_isIdempotent() {
        reset()
        PerformanceMonitor.shared.stop()
        PerformanceMonitor.shared.stop()  // no-op
    }
}

@Suite("DshPerformanceStats")
struct DshPerformanceStatsTests {

    @Test func decode_handlesFullPayload() throws {
        let json = """
        {"longTaskCount": 12, "longTaskTotalMs": 8450, "lastSpikeAt": 1234.5, "memoryMB": 234, "pluginCount": 2, "plugins": ["@dsh-shell", "@dsh-tool-runner"]}
        """
        let data = Data(json.utf8)
        let stats = try JSONDecoder().decode(DshPerformanceStats.self, from: data)
        #expect(stats.longTaskCount == 12)
        #expect(stats.longTaskTotalMs == 8450)
        #expect(stats.lastSpikeAt == 1234.5)
        #expect(stats.memoryMB == 234)
        #expect(stats.pluginCount == 2)
        #expect(stats.plugins == ["@dsh-shell", "@dsh-tool-runner"])
    }

    @Test func decode_handlesNullFields() throws {
        let json = """
        {"longTaskCount": 0, "longTaskTotalMs": 0, "lastSpikeAt": null, "memoryMB": null, "pluginCount": 0, "plugins": []}
        """
        let data = Data(json.utf8)
        let stats = try JSONDecoder().decode(DshPerformanceStats.self, from: data)
        #expect(stats.longTaskCount == 0)
        #expect(stats.lastSpikeAt == nil)
        #expect(stats.memoryMB == nil)
        #expect(stats.plugins.isEmpty)
    }

    @Test func equatable_worksAsExpected() {
        let a = DshPerformanceStats(longTaskCount: 1, longTaskTotalMs: 2, lastSpikeAt: nil, memoryMB: 100, pluginCount: 0, plugins: [])
        let b = a
        let c = DshPerformanceStats(longTaskCount: 1, longTaskTotalMs: 3, lastSpikeAt: nil, memoryMB: 100, pluginCount: 0, plugins: [])
        #expect(a == b)
        #expect(a != c)
    }
}