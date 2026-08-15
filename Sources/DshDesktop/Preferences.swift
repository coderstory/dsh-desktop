import Foundation
import Combine

/// User-tunable preferences, persisted in `UserDefaults`. Singleton accessed
/// via `Preferences.shared`. Injectable via init for tests (custom
/// UserDefaults suite).
///
/// Not `@MainActor` — it's a data holder. UI consumers (SwiftUI views) read
/// `@Published` properties on the main thread automatically via SwiftUI's
/// view update scheduling.
public final class Preferences: ObservableObject, @unchecked Sendable {

    public static let shared = Preferences()

    public enum Keys {
        public static let port = "preferences.port"
        public static let notificationsEnabled = "preferences.notificationsEnabled"
        public static let pollingIntervalSeconds = "preferences.pollingIntervalSeconds"
        public static let pausePollingWhenHidden = "preferences.pausePollingWhenHidden"
        public static let enablePerformanceMonitoring = "preferences.enablePerformanceMonitoring"
    }

    public static let defaultPort: Int = 3080
    public static let defaultNotificationsEnabled: Bool = true
    public static let defaultPollingIntervalSeconds: Double = 5.0
    public static let defaultPausePollingWhenHidden: Bool = false
    public static let defaultEnablePerformanceMonitoring: Bool = false
    /// Clamp range for the polling-interval slider (seconds).
    public static let pollingIntervalRange: ClosedRange<Double> = 1.0...60.0

    private let defaults: UserDefaults

    @Published public var port: Int {
        didSet {
            defaults.set(port, forKey: Keys.port)
            Log.app.info("Preferences: port → \(self.port)")
        }
    }

    @Published public var notificationsEnabled: Bool {
        didSet {
            defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled)
            Log.app.info("Preferences: notificationsEnabled → \(self.notificationsEnabled)")
        }
    }

    @Published public var pollingIntervalSeconds: Double {
        didSet {
            defaults.set(pollingIntervalSeconds, forKey: Keys.pollingIntervalSeconds)
            Log.app.info("Preferences: pollingIntervalSeconds → \(self.pollingIntervalSeconds)")
        }
    }

    /// When true, `AgentIdleWatcher` is paused while the wrapper window
    /// is hidden (closed) and resumed on next show. Saves the (negligible)
    /// polling CPU during background. Note: dsh's own CPU is unaffected —
    /// see README for details.
    @Published public var pausePollingWhenHidden: Bool {
        didSet {
            defaults.set(pausePollingWhenHidden, forKey: Keys.pausePollingWhenHidden)
            Log.app.info("Preferences: pausePollingWhenHidden → \(self.pausePollingWhenHidden)")
        }
    }

    /// When true, a `PerformanceMonitor` polls dsh's in-page performance
    /// every 10s and surfaces long-task counts + memory + currently-loaded
    /// plugins in the menu bar. Off by default — opt in via Settings
    /// or `DshDesktop --debug` (which also enables this).
    @Published public var enablePerformanceMonitoring: Bool {
        didSet {
            defaults.set(enablePerformanceMonitoring, forKey: Keys.enablePerformanceMonitoring)
            Log.app.info("Preferences: enablePerformanceMonitoring → \(self.enablePerformanceMonitoring)")
            // Live-toggle the monitor. PerformanceMonitor is @MainActor;
            // dispatch the mutation to the main actor.
            let enabled = self.enablePerformanceMonitoring
            Task { @MainActor in
                PerformanceMonitor.shared.enabled = enabled
                if enabled {
                    PerformanceMonitor.shared.start()
                } else {
                    PerformanceMonitor.shared.stop()
                }
            }
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let port = defaults.object(forKey: Keys.port) as? Int
        let notifs = defaults.object(forKey: Keys.notificationsEnabled) as? Bool
        let poll = defaults.object(forKey: Keys.pollingIntervalSeconds) as? Double
        let pauseHidden = defaults.object(forKey: Keys.pausePollingWhenHidden) as? Bool
        let perfMon = defaults.object(forKey: Keys.enablePerformanceMonitoring) as? Bool

        self.port = Self.sanitizePort(port) ?? Self.defaultPort
        self.notificationsEnabled = notifs ?? Self.defaultNotificationsEnabled
        self.pollingIntervalSeconds = Self.sanitizePollingInterval(poll) ?? Self.defaultPollingIntervalSeconds
        self.pausePollingWhenHidden = pauseHidden ?? Self.defaultPausePollingWhenHidden
        self.enablePerformanceMonitoring = perfMon ?? Self.defaultEnablePerformanceMonitoring
        // Sync the monitor after init (MainActor).
        let enabled = self.enablePerformanceMonitoring
        Task { @MainActor in
            PerformanceMonitor.shared.enabled = enabled
        }
    }

    public func resetToDefaults() {
        port = Self.defaultPort
        notificationsEnabled = Self.defaultNotificationsEnabled
        pollingIntervalSeconds = Self.defaultPollingIntervalSeconds
        pausePollingWhenHidden = Self.defaultPausePollingWhenHidden
        enablePerformanceMonitoring = Self.defaultEnablePerformanceMonitoring
    }

    private static func sanitizePort(_ value: Int?) -> Int? {
        guard let p = value, p > 0, p < 65536 else { return nil }
        return p
    }

    private static func sanitizePollingInterval(_ value: Double?) -> Double? {
        guard let v = value else { return nil }
        return min(max(v, pollingIntervalRange.lowerBound), pollingIntervalRange.upperBound)
    }
}