import Testing
import Foundation
@testable import DshDesktop

@Suite("DshPlugins")
struct DshPluginsTests {

    @Test func backgroundThrottlePatchYAML_containsInsertAndName() {
        let yaml = DshPlugins.backgroundThrottlePatchYAML(pluginPath: "/abs/path/to/index.ts")
        #expect(yaml.contains("- insert:"))
        #expect(yaml.contains("id: background-throttle"))
        #expect(yaml.contains("name: '/abs/path/to/index.ts'"))
    }

    @Test func backgroundThrottlePatchYAML_isMultiLine() {
        // dsh expects a multi-line YAML; our formatter must produce >1 line.
        let yaml = DshPlugins.backgroundThrottlePatchYAML(pluginPath: "/x")
        #expect(yaml.split(separator: "\n").count >= 3)
    }

    @Test func writeBackgroundThrottlePatch_at_createsFileWithYAML() throws {
        let path = "/tmp/some/fake/index.ts"
        guard let url = DshPlugins.writeBackgroundThrottlePatch(at: path) else {
            Issue.record("write returned nil")
            return
        }
        defer { DshPlugins.cleanup(url) }
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.contains("name: '\(path)'"))
        #expect(content.contains("id: background-throttle"))
    }

    @Test func writeBackgroundThrottlePatch_at_usesUniqueTempPath() {
        let url1 = DshPlugins.writeBackgroundThrottlePatch(at: "/x")!
        let url2 = DshPlugins.writeBackgroundThrottlePatch(at: "/y")!
        #expect(url1 != url2)
        #expect(url1.path.contains("dsh-desktop-bg-throttle-"))
        #expect(url2.path.contains("dsh-desktop-bg-throttle-"))
        DshPlugins.cleanup(url1)
        DshPlugins.cleanup(url2)
    }

    @Test func cleanup_removesFile() throws {
        let url = DshPlugins.writeBackgroundThrottlePatch(at: "/x")!
        #expect(FileManager.default.fileExists(atPath: url.path))
        DshPlugins.cleanup(url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func cleanup_nilIsNoOp() {
        DshPlugins.cleanup(nil)  // must not crash
    }
}