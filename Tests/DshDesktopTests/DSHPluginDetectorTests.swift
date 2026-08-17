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

    // MARK: - installPackageDependency (the OTHER half of the install —
    //       cordis.patch.yml tells dsh *which* plugins to instantiate,
    //       package.json `dependencies` is what pnpm reads to actually
    //       symlink the plugin into node_modules so dsh can resolve its
    //       `main:` path. Both are required. Without this half, the
    //       - insert row in cordis.patch.yml points at a non-existent
    //       node_modules/<plugin>/, and dsh either auto-prunes the
    //       broken row or fails to load the plugin silently.)

    func test_installPackageDependency_addsLinkEntry() throws {
        let pkgPath = profileDir.appendingPathComponent("package.json").path
        // Seed a minimal package.json with NO bridge entry.
        try """
            {
              "name": "dsh-profile-web-test",
              "private": true,
              "dependencies": {}
            }
            """.write(toFile: pkgPath, atomically: true, encoding: .utf8)

        XCTAssertTrue(try DSHPluginDetector.installPackageDependency(at: profileDir.path))

        let data = try Data(contentsOf: URL(fileURLWithPath: pkgPath))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let deps = try XCTUnwrap(obj["dependencies"] as? [String: Any])
        XCTAssertEqual(deps[DSHPluginDetector.pluginID] as? String, DSHPluginDetector.defaultPackageLink)
    }

    func test_installPackageDependency_isIdempotent() throws {
        let pkgPath = profileDir.appendingPathComponent("package.json").path
        try """
            {
              "name": "dsh-profile-web-test",
              "private": true,
              "dependencies": {}
            }
            """.write(toFile: pkgPath, atomically: true, encoding: .utf8)

        XCTAssertTrue(try DSHPluginDetector.installPackageDependency(at: profileDir.path))
        // Second call: same value already present, no-op.
        XCTAssertFalse(try DSHPluginDetector.installPackageDependency(at: profileDir.path))
    }

    func test_installPackageDependency_doesNotClobberUserCustomisedValue() throws {
        let pkgPath = profileDir.appendingPathComponent("package.json").path
        try """
            {
              "name": "dsh-profile-web-test",
              "private": true,
              "dependencies": {
                "\(DSHPluginDetector.pluginID)": "link:/some/other/path"
              }
            }
            """.write(toFile: pkgPath, atomically: true, encoding: .utf8)

        // User has a different path; we leave it alone.
        XCTAssertFalse(try DSHPluginDetector.installPackageDependency(at: profileDir.path))

        let data = try Data(contentsOf: URL(fileURLWithPath: pkgPath))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let deps = try XCTUnwrap(obj["dependencies"] as? [String: Any])
        XCTAssertEqual(deps[DSHPluginDetector.pluginID] as? String, "link:/some/other/path",
            "user's customised dependency value must not be clobbered")
    }

    func test_installPackageDependency_preservesOtherDependencies() throws {
        let pkgPath = profileDir.appendingPathComponent("package.json").path
        try """
            {
              "name": "dsh-profile-web-test",
              "private": true,
              "dependencies": {
                "another-plugin": "1.2.3",
                "aegis": "git+https://example.com/aegis.git"
              }
            }
            """.write(toFile: pkgPath, atomically: true, encoding: .utf8)

        _ = try DSHPluginDetector.installPackageDependency(at: profileDir.path)

        let data = try Data(contentsOf: URL(fileURLWithPath: pkgPath))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let deps = try XCTUnwrap(obj["dependencies"] as? [String: Any])
        XCTAssertEqual(deps["another-plugin"] as? String, "1.2.3",
            "existing dependency must be preserved")
        XCTAssertEqual(deps["aegis"] as? String, "git+https://example.com/aegis.git",
            "existing dependency must be preserved")
        XCTAssertEqual(deps[DSHPluginDetector.pluginID] as? String, DSHPluginDetector.defaultPackageLink)
    }

    // MARK: - Launch-time install does BOTH writes (patch + dep). This is
    //       the regression test for the user's report that 'the plugin
    //       isn't actually fully installed' — the patch alone isn't
    //       enough; without the package.json dep, pnpm won't materialise
    //       node_modules/<plugin>/ and dsh either silently drops the
    //       - insert or fails to load the plugin at runtime.

    func test_launchInstall_writesBothPatchAndPackageDep() throws {
        // Seed a profile with NOTHING in cordis.patch.yml about the bridge
        // plugin and NOTHING in package.json dependencies either.
        let pkgPath = profileDir.appendingPathComponent("package.json").path
        try """
            {
              "name": "dsh-profile-web-test",
              "private": true,
              "dependencies": {}
            }
            """.write(toFile: pkgPath, atomically: true, encoding: .utf8)

        // Simulate what the wrapper's detectAndAutoInstallBridgePlugin
        // does: installPatchEntry + installPackageDependency.
        let patchPath = profileDir.appendingPathComponent("cordis.patch.yml").path
        _ = try DSHPluginDetector.installPatchEntry(at: patchPath)
        _ = try DSHPluginDetector.installPackageDependency(at: profileDir.path)

        // Both writes should have happened.
        let patch = try String(contentsOfFile: patchPath, encoding: .utf8)
        XCTAssertTrue(patch.contains("- id: \(DSHPluginDetector.pluginID)"),
            "patch.yml must contain the bridge - insert row")

        let data = try Data(contentsOf: URL(fileURLWithPath: pkgPath))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let deps = try XCTUnwrap(obj["dependencies"] as? [String: Any])
        XCTAssertEqual(deps[DSHPluginDetector.pluginID] as? String, DSHPluginDetector.defaultPackageLink,
            "package.json must list the bridge plugin in dependencies (so pnpm symlinks it on next dsh launch)")
    }

    // MARK: - Duplicate-entry guard (regression: user reported that the
    //       wrapper and the package's own cordis.patch.yml both
    //       inserted the same id, causing "duplicate loader entry id"
    //       on dsh boot. Fix: when a real package is in
    //       node_modules/<id>/, installPatchEntry must NOT write the
    //       profile's - insert row, and detect() must report success.)

    func test_installPatchEntry_isNoOpWhenPackageAlreadyInstalled() throws {
        // Simulate a real package install by creating
        // node_modules/<pluginID>/ inside the profile dir.
        let pkgDir = profileDir.appendingPathComponent("node_modules")
            .appendingPathComponent(DSHPluginDetector.pluginID)
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)

        // The patch file would otherwise be written; the guard must
        // make installPatchEntry a no-op.
        let patchPath = profileDir.appendingPathComponent("cordis.patch.yml").path
        XCTAssertFalse(try DSHPluginDetector.installPatchEntry(at: patchPath),
            "installPatchEntry must skip the write when the package is already in node_modules/")
        XCTAssertFalse(FileManager.default.fileExists(atPath: patchPath),
            "no patch file should be created when the package is already installed")
    }

    func test_detect_reportsInstalledCurrentWhenPackageAlreadyInstalled() throws {
        // Plant a row in the profile's patch (which would normally be
        // the wrong / duplicate entry) AND symlink a real package
        // directory. detect() should treat this as installedCurrent
        // — the package's row wins, the profile's - insert is harmless
        // (left as-is), and the wrapper will not re-write it.
        let realMain = profileDir.appendingPathComponent("plugin.ts").path
        try "".write(toFile: realMain, atomically: true, encoding: .utf8)
        try writePatch(into: "cordis.yml", rows: ["""
            - id: \(DSHPluginDetector.pluginID)
              name: \(DSHPluginDetector.pluginID)
              version: \(DSHPluginDetector.expectedPluginVersion)
              main: \(realMain)
            """])

        let pkgDir = profileDir.appendingPathComponent("node_modules")
            .appendingPathComponent(DSHPluginDetector.pluginID)
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)

        let status = DSHPluginDetector.detect(dshHome: scratchDir.path)
        XCTAssertEqual(status.state, .installedCurrent,
            "package in node_modules + profile row = installedCurrent (no duplicate)")
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