import Foundation
import ServiceManagement

/// State of the main app's registration as a login item.
/// Mirrors `SMAppService.Status` but is plain-Swift (testable).
public enum LoginItemStatus: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

/// Protocol abstraction over `SMAppService.mainApp` so the toggle logic
/// can be unit-tested with a mock provider.
public protocol LoginItemProviding {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

/// Production implementation backed by `SMAppService.mainApp`.
public struct SMAppLoginItemProvider: LoginItemProviding {
    public init() {}

    public var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered:    return .notRegistered
        case .enabled:          return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound:          return .notFound
        @unknown default:       return .notRegistered
        }
    }

    public func register() throws {
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

/// User-facing toggle for "launch DshDesktop automatically when you sign in".
public enum LaunchAtLogin {

    /// Convenience: query current state.
    public static func isEnabled(provider: LoginItemProviding = SMAppLoginItemProvider()) -> Bool {
        provider.status == .enabled
    }

    /// Toggle: register if not enabled, unregister if enabled. Errors are logged
    /// but never surface to the user (best-effort feature).
    public static func toggle(provider: LoginItemProviding = SMAppLoginItemProvider()) {
        do {
            if provider.status == .enabled {
                try provider.unregister()
                Log.app.info("LaunchAtLogin: unregistered")
            } else {
                try provider.register()
                Log.app.info("LaunchAtLogin: registered")
            }
        } catch {
            Log.errors.error("LaunchAtLogin toggle failed: \(error.localizedDescription)")
        }
    }
}