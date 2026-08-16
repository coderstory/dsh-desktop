import Foundation
import UserNotifications

/// Thin wrapper around `UNUserNotificationCenter` for the wrapper app's
/// one notification use case: "agent finished responding".
///
/// All operations are silent on failure — the wrapper app must never
/// interrupt the user about the notifier.
public enum Notifications {

    /// Ensure the notification center's delegate is installed so banners
    /// are delivered even while the wrapper's main window is frontmost.
    ///
    /// By default macOS suppresses foreground notification delivery unless
    /// the app implements `UNUserNotificationCenterDelegate.willPresent`.
    /// DshDesktop keeps its window open while the dsh agent runs, so
    /// without this the "finished responding" banner is silently dropped
    /// and the feature looks dead. Setting the delegate once here fixes it.
    @MainActor
    public static func installDelegate() {
        let center = UNUserNotificationCenter.current()
        if center.delegate == nil {
            center.delegate = NotificationDeliveryDelegate.shared
        }
    }

    /// Request `.alert` + `.sound` authorization. Returns whether granted.
    public static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        // Record the authorization status up front so we can tell a
        // "denied / already decided" state from a genuine call failure.
        let settings = await center.notificationSettings()
        Log.app.info("notification: current authorizationStatus=\(settings.authorizationStatus.rawValue, privacy: .public)")
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            Log.app.info("notification: requestAuthorization granted=\(granted, privacy: .public)")
            return granted
        } catch {
            Log.errors.error("notification authorization request failed: \(error.localizedDescription, privacy: .public)")
            // Re-read status so the log shows whether the center decided
            // (denied) vs. we genuinely failed to ask.
            let after = await center.notificationSettings()
            Log.errors.error("notification: post-request authorizationStatus=\(after.authorizationStatus.rawValue, privacy: .public)")
            return false
        }
    }

    /// Schedule a notification with the given title and body, fired ~0.1s out.
    /// No-op if permission was denied (requestAuthorization returned false).
    /// Callers should localize `title` and `body` via `String(localized:)` before
    /// passing — UNNotificationContent doesn't support LocalizedStringResource
    /// parameters directly.
    public static func notify(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Log.errors.error("notification add failed: \(error.localizedDescription)")
        }
    }
}

/// Keeps foreground notification delivery on: without a `willPresent`
/// implementation, macOS never shows a banner while the app is frontmost,
/// which is exactly when DshDesktop's window is up during an agent run.
@MainActor
private final class NotificationDeliveryDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDeliveryDelegate()

    var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
