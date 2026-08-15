import Foundation
import UserNotifications

/// Thin wrapper around `UNUserNotificationCenter` for the wrapper app's
/// one notification use case: "agent finished responding".
///
/// All operations are silent on failure — the wrapper app must never
/// interrupt the user about the notifier.
public enum Notifications {

    /// Request `.alert` + `.sound` authorization. Returns whether granted.
    public static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            Log.errors.error("notification authorization request failed: \(error.localizedDescription)")
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
