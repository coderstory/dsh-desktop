import Foundation

/// Helpers for bundling dsh plugins with the wrapper and generating
/// the cordis.yml patch file that dsh loads on startup.
///
/// Background: dsh plugins are TypeScript modules loaded by the dsh
/// runtime. To load a plugin, dsh accepts a `--patch <file.yml>` flag
/// whose content is a Cordis config overlay. We ship the plugin source
/// inside the wrapper's Resources/ and synthesize the patch file at
/// runtime, pointing at the bundled absolute path.
public enum DshPlugins {

    /// Absolute path to the bundled `background-throttle` plugin source,
    /// or nil if the wrapper isn't running from a .app bundle (e.g. dev
    /// via `swift run` without bundling).
    public static func backgroundThrottleSource() -> URL? {
        Bundle.main.url(
            forResource: "index",
            withExtension: "ts",
            subdirectory: "dsh-plugins/background-throttle"
        )
    }

    /// Build the cordis.yml overlay text that loads the background-throttle
    /// plugin. Pure function — extracted for testability (no bundle state,
    /// no filesystem I/O).
    public static func backgroundThrottlePatchYAML(pluginPath: String) -> String {
        return """
        - insert:
            - id: background-throttle
              name: '\(pluginPath)'

        """
    }

    /// Write a cordis.yml patch file to a unique temp path that loads
    /// the bundled background-throttle plugin. Returns nil if the
    /// plugin source isn't available (e.g. dev run without `bundle.sh`).
    public static func writeBackgroundThrottlePatch() -> URL? {
        guard let pluginURL = backgroundThrottleSource() else { return nil }
        return writeBackgroundThrottlePatch(at: pluginURL.path)
    }

    /// Same as `writeBackgroundThrottlePatch()` but with an explicit
    /// source path (for tests and for callers that already have the
    /// path in scope).
    public static func writeBackgroundThrottlePatch(at pluginPath: String) -> URL? {
        let yaml = backgroundThrottlePatchYAML(pluginPath: pluginPath)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-desktop-bg-throttle-\(UUID().uuidString).yml")
        do {
            try yaml.write(to: tempURL, atomically: true, encoding: .utf8)
            return tempURL
        } catch {
            Log.errors.error("DshPlugins: failed to write patch file — \(error.localizedDescription)")
            return nil
        }
    }

    /// Best-effort cleanup of a previously-written patch file.
    public static func cleanup(_ url: URL?) {
        guard let url = url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}