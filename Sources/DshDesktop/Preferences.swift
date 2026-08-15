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
    }

    public static let defaultPort: Int = 3080
    public static let defaultNotificationsEnabled: Bool = true
    public static let defaultPollingIntervalSeconds: Double = 5.0
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

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let port = defaults.object(forKey: Keys.port) as? Int
        let notifs = defaults.object(forKey: Keys.notificationsEnabled) as? Bool
        let poll = defaults.object(forKey: Keys.pollingIntervalSeconds) as? Double

        self.port = Self.sanitizePort(port) ?? Self.defaultPort
        self.notificationsEnabled = notifs ?? Self.defaultNotificationsEnabled
        self.pollingIntervalSeconds = Self.sanitizePollingInterval(poll) ?? Self.defaultPollingIntervalSeconds
    }

    public func resetToDefaults() {
        port = Self.defaultPort
        notificationsEnabled = Self.defaultNotificationsEnabled
        pollingIntervalSeconds = Self.defaultPollingIntervalSeconds
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