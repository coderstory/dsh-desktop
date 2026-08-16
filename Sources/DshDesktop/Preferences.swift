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
    }

    public static let defaultPort: Int = 3080
    public static let defaultNotificationsEnabled: Bool = true

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

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let port = defaults.object(forKey: Keys.port) as? Int
        let notifs = defaults.object(forKey: Keys.notificationsEnabled) as? Bool

        self.port = Self.sanitizePort(port) ?? Self.defaultPort
        self.notificationsEnabled = notifs ?? Self.defaultNotificationsEnabled
    }

    public func resetToDefaults() {
        port = Self.defaultPort
        notificationsEnabled = Self.defaultNotificationsEnabled
    }

    private static func sanitizePort(_ value: Int?) -> Int? {
        guard let p = value, p > 0, p < 65536 else { return nil }
        return p
    }
}