import Foundation
import AppKit
import OSLog

/// Generates a plain-text diagnostic report for the current wrapper state.
/// Surfaced via the `dsh ▸ Save Diagnostic Report…` menu item. Useful for
/// filing bug reports without asking the user to dig through Console.app.
public enum Diagnostics {

    @MainActor
    public static func generateReport() -> String {
        var lines: [String] = []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        lines.append("DshDesktop — Diagnostic Report")
        lines.append("Generated: \(iso.string(from: Date()))")
        lines.append(String(repeating: "=", count: 60))
        lines.append("")

        // App + system
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let minSys = Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String ?? "?"
        lines.append("App")
        lines.append("  Version:       \(appVersion) (\(build))")
        lines.append("  Min macOS:     \(minSys)")
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        lines.append("  macOS:         \(osVersion)")
        let swiftVersion = (Bundle.main.infoDictionary?["DTPlatformVersion"] as? String) ?? "?"
        lines.append("  Build platform: \(swiftVersion)")
        lines.append("")

        // Preferences
        let prefs = Preferences.shared
        lines.append("Preferences")
        lines.append("  port:                       \(prefs.port)")
        lines.append("  notificationsEnabled:       \(prefs.notificationsEnabled)")
        lines.append("")

        // Process state
        if let process = DSHAppProxy.processSnapshot() {
            lines.append("DshProcess")
            lines.append("  state:        \(process.state)")
            lines.append("  port:         \(process.port)")
            lines.append("  ownsChild:    \(process.ownsChild)")
            if !process.stderrTail.isEmpty {
                lines.append("  stderr (tail, last \(process.stderrTail.count) chars):")
                lines.append(indent(process.stderrTail, "    "))
            }
            lines.append("")
        }

        // Recent log lines (best-effort)
        lines.append("Recent log lines (last ~100, filtered by subsystem)")
        lines.append(String(repeating: "-", count: 60))
        for line in recentLogEntries() {
            lines.append(line)
        }
        lines.append("")

        return lines.joined(separator: "\n")
    }

    private static func indent(_ s: String, _ prefix: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { prefix + $0 }
            .joined(separator: "\n")
    }

    /// Pull the most recent log entries from the same subsystem via OSLogStore.
    /// Best-effort — OSLogStore can throw on some configurations.
    private static func recentLogEntries() -> [String] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            // 10-minute lookback. Plenty of recent activity for debug reports.
            let cutoff = Date().addingTimeInterval(-10 * 60)
            let position = store.position(date: cutoff)
            let entries = try store.getEntries(
                at: position,
                matching: NSPredicate(format: "subsystem == %@", Log.subsystem)
            )
            let lines: [String] = entries
                .compactMap { $0 as? OSLogEntryLog }
                .sorted { $0.date < $1.date }
                .suffix(100)
                .map { entry in
                    let ts = ISO8601DateFormatter().string(from: entry.date)
                    let level = entry.level.shortName
                    return "\(ts) [\(level)] [\(entry.category)] \(entry.composedMessage)"
                }
            return Array(lines)
        } catch {
            return ["(could not read log store: \(error.localizedDescription))"]
        }
    }
}

private extension OSLogEntryLog.Level {
    var shortName: String {
        switch self {
        case .debug:    return "DBG"
        case .info:     return "INF"
        case .notice:   return "NOT"
        case .error:    return "ERR"
        case .fault:    return "FLT"
        default:         return "???"
        }
    }
}

/// Process snapshot captured by `AppDelegate` for the diagnostic report.
/// `DSHAppProxy` keeps `DshApp.swift` decoupled from `Diagnostics.swift`
/// (the latter doesn't import SwiftUI).
@MainActor
public final class DSHAppProxy {
    public static weak var process: DshProcess?
    public static func processSnapshot() -> (state: DshProcess.State, port: Int, ownsChild: Bool, stderrTail: String)? {
        guard let p = process else { return nil }
        return (p.state, p.port, p.ownsChild, p.stderrTail)
    }
}