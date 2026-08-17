import XCTest
@testable import DshDesktop

/// Tests for DSHPluginDetector. We exercise the parser by writing temp patch
/// files into a per-test scratch directory and pointing `detect()` at a
/// fabricated DSH home — no real filesystem side-effects, no test pollution.
final class DSHPluginDetectorTests: XCTestCase {

    private var scratchDir: URL!
    private var profileDir: URL!

    override func setUpWithError() throws {
        scratchDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DSHPluginDetectorTests-\(UUID().uuidString)")
        profileDir = scratchDir
            .appendingPathComponent("profiles")
            .appendingPathComponent("web")
        try FileManager.default.createDirectory(
            at: profileDir,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratchDir)
    }

    // MARK: - Cases

    func test_notInstalled_whenBothFilesEmpty() {
        let status = DSHPluginDetector.detect(dshHome: scratchDir.path)
        XCTAssertEqual(status.state, .notInstalled)
        XCTAssertFalse(status.pluginOperational)
    }

    func test_notInstalled_whenOurIdAbsentNotFound() throws {
        try writePatch(into: "cordis.yml", rows: [
            "- id: other-plugin\n  enabled: true"
        ])
        let status = DSHPluginDetector.detect(dshHome: scratchDir.path)
        XCTAssertEqual(status.state, .notInstalled)
    }

    func test_installedCurrent_whenEntryPresentAndMatches() throws {
        try writePatch(into: "cordis.yml", rows: ["""
            - id: \(DSHPluginDetector.pluginID)
              name: \(DSHPluginDetector.pluginID)
              version: \(DSHPluginDetector.expectedPluginVersion)
              main: \(DSHPluginDetector.defaultPluginPath)
            """])
        // The default path doesn't actually exist on the test machine, so we
        // need to override main: to a file we *do* create.
        let realMain = scratchDir.appendingPathComponent("plugin.ts").path
        try "".write(toFile: realMain, atomically: true, encoding: .utf8)

        // Rewrite with the real path:
        try writePatch(into: "cordis.yml", rows: ["""
            - id: \(DSHPluginDetector.pluginID)
              version: \(DSHPluginDetector.expectedPluginVersion)
              main: \(realMain)
            """])
        let status = DSHPluginDetector.detect(dshHome: scratchDir.path)
        XCTAssertEqual(status.state, .installedCurrent)
        XCTAssertTrue(status.pluginOperational)
    }

    func test_installedOutdated_whenVersionDiffers() throws {
        let realMain = scratchDir.appendingPathComponent("plugin.ts").path
        try "".write(toFile: realMain, atomically: true, encoding: .utf8)
        try writePatch(into: "cordis.yml", rows: ["""
            - id: \(DSHPluginDetector.pluginID)
              version: 0.0.1
              main: \(realMain)
            """])
        let status = DSHPluginDetector.detect(dshHome: scratchDir.path)
        XCTAssertEqual(status.state, .installedOutdated(
            expected: DSHPluginDetector.expectedPluginVersion,
            found: "0.0.1"
        ))
        XCTAssertFalse(status.pluginOperational)
    }

    func test_disabled_whenRowHasDisabledTrue() throws {
        let realMain = scratchDir.appendingPathComponent("plugin.ts").path
        try "".write(toFile: realMain, atomically: true, encoding: .utf8)
        try writePatch(into: "cordis.patch.yml", rows: ["""
            - id: \(DSHPluginDetector.pluginID)
              version: \(DSHPluginDetector.expectedPluginVersion)
              main: \(realMain)
              disabled: true
            """])
        let status = DSHPluginDetector.detect(dshHome: scratchDir.path)
        XCTAssertEqual(status.state, .disabled)
        XCTAssertFalse(status.pluginOperational)
    }

    func test_brokenPath_whenMainFileDoesNotExist() throws {
        try writePatch(into: "cordis.yml", rows: ["""
            - id: \(DSHPluginDetector.pluginID)
              version: \(DSHPluginDetector.expectedPluginVersion)
              main: /nonexistent/path/to/plugin.ts
            """])
        let status = DSHPluginDetector.detect(dshHome: scratchDir.path)
        XCTAssertEqual(status.state, .brokenPath(expected: "/nonexistent/path/to/plugin.ts"))
        XCTAssertFalse(status.pluginOperational)
    }

    func test_laterPatchFileWins_whenSameIdInBoth() throws {
        // cordis.yml has a stale 0.0.1 entry; cordis.patch.yml upgrades to 0.1.0.
        // Cordis's own layer order is: bundles → cordis.yml → cordis.patch.yml
        // → HOME-level → --patch. The patch file overrides earlier rows.
        let realMain = scratchDir.appendingPathComponent("plugin.ts").path
        try "".write(toFile: realMain, atomically: true, encoding: .utf8)

        try writePatch(into: "cordis.yml", rows: ["""
            - id: \(DSHPluginDetector.pluginID)
              version: 0.0.1
              main: \(realMain)
            """])
        try writePatch(into: "cordis.patch.yml", rows: ["""
            - id: \(DSHPluginDetector.pluginID)
              version: \(DSHPluginDetector.expectedPluginVersion)
              main: \(realMain)
            """])
        let status = DSHPluginDetector.detect(dshHome: scratchDir.path)
        XCTAssertEqual(status.state, .installedCurrent)
    }

    func test_inlineYamlWithMultipleFieldsOnSameLine() throws {
        // Real cordis patch files commonly put several fields on the `- id:`
        // line (e.g. `- id: foo name: bar version: 1.0`). The parser must
        // tokenise each pair cleanly without bleeding the next key's name
        // into the previous value.
        let realMain = scratchDir.appendingPathComponent("plugin.ts").path
        try "".write(toFile: realMain, atomically: true, encoding: .utf8)
        try writePatch(into: "cordis.yml", rows: ["""
            - id: \(DSHPluginDetector.pluginID) name: \(DSHPluginDetector.pluginID) version: \(DSHPluginDetector.expectedPluginVersion) main: \(realMain)
            """])
        let status = DSHPluginDetector.detect(dshHome: scratchDir.path)
        XCTAssertEqual(status.state, .installedCurrent)
    }

    // MARK: - installPatchEntry / reenablePatchEntry

    func test_installPatchEntry_appendsOurRowToEmptyFile() throws {
        let patchPath = profileDir.appendingPathComponent("cordis.patch.yml").path
        let wrote = try DSHPluginDetector.installPatchEntry(at: patchPath)
        XCTAssertTrue(wrote)
        let result = try String(contentsOfFile: patchPath, encoding: .utf8)
        XCTAssertTrue(result.contains("- id: \(DSHPluginDetector.pluginID)"))
        XCTAssertTrue(result.contains("main: \(DSHPluginDetector.defaultPluginPath)"))
    }

    func test_installPatchEntry_isIdempotent() throws {
        let patchPath = profileDir.appendingPathComponent("cordis.patch.yml").path
        XCTAssertTrue(try DSHPluginDetector.installPatchEntry(at: patchPath))
        XCTAssertFalse(try DSHPluginDetector.installPatchEntry(at: patchPath))
    }

    func test_reenablePatchEntry_flipsDisabledTrueToFalse() throws {
        let patchPath = profileDir.appendingPathComponent("cordis.patch.yml").path
        try """
            # initial user content
            - id: \(DSHPluginDetector.pluginID)
              main: \(DSHPluginDetector.defaultPluginPath)
              version: \(DSHPluginDetector.expectedPluginVersion)
              disabled: true
            """.write(toFile: patchPath, atomically: true, encoding: .utf8)

        XCTAssertTrue(try DSHPluginDetector.reenablePatchEntry(at: patchPath))
        let result = try String(contentsOfFile: patchPath, encoding: .utf8)
        XCTAssertTrue(result.contains("disabled: false"), "expected flag flipped to false")
        XCTAssertFalse(result.contains("disabled: true"), "expected original true replaced")
    }

    func test_reenablePatchEntry_returnsFalseIfNoDisabledRow() throws {
        let patchPath = profileDir.appendingPathComponent("cordis.patch.yml").path
        try """
            - id: \(DSHPluginDetector.pluginID)
              main: \(DSHPluginDetector.defaultPluginPath)
            """.write(toFile: patchPath, atomically: true, encoding: .utf8)

        XCTAssertFalse(try DSHPluginDetector.reenablePatchEntry(at: patchPath))
    }

    func test_installPatchEntry_preservesExistingUserContent() throws {
        let patchPath = profileDir.appendingPathComponent("cordis.patch.yml").path
        let preExisting = "# user's own patch row\n- id: another-plugin\n  main: /y\n"
        try preExisting.write(toFile: patchPath, atomically: true, encoding: .utf8)
        _ = try DSHPluginDetector.installPatchEntry(at: patchPath)
        let result = try String(contentsOfFile: patchPath, encoding: .utf8)
        XCTAssertTrue(result.contains("- id: another-plugin"), "user content preserved")
        XCTAssertTrue(result.contains("- id: \(DSHPluginDetector.pluginID)"), "our row added")
    }

    // MARK: - Helpers

    private func writePatch(into filename: String, rows: [String]) throws {
        // The real cordis files start with `# comment` lines; we mimic that so
        // the parser's comment-stripping path is covered.
        let prefix = "# cordis.yml — bundles list (test fixture)\n"
        let joined = rows.joined(separator: "\n")
        let content = prefix + joined + "\n"
        let url = profileDir.appendingPathComponent(filename)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}