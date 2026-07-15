import Foundation
import AppKit
import UserNotifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    var onRecordAction: (() -> Void)?
    var onRetryAction: ((URL) -> Void)?

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let record = UNNotificationAction(identifier: "RECORD", title: "Record", options: [])
        let retry = UNNotificationAction(identifier: "RETRY", title: "Retry transcription", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "MEETING_START", actions: [record], intentIdentifiers: []),
            UNNotificationCategory(identifier: "INFO", actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: "TRANSCRIBE_FAILED", actions: [retry], intentIdentifiers: []),
        ])
    }

    func notify(title: String, body: String, category: String, userInfo: [String: String] = [:]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.userInfo = userInfo
        // The record prompt is actionable right now  -  break through Focus modes
        // (best effort: full breakthrough needs the time-sensitive entitlement).
        if category == "MEETING_START" {
            content.interruptionLevel = .timeSensitive
        }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // Present banners even while the app is active (menu open, Settings window);
    // without this, macOS suppresses foreground notifications entirely.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        switch response.actionIdentifier {
        case "RECORD": onRecordAction?()
        case "RETRY":
            if let path = response.notification.request.content.userInfo["note"] as? String {
                onRetryAction?(URL(fileURLWithPath: path))
            }
        case UNNotificationDefaultActionIdentifier:
            // Tap on the notification body: open the meeting note if it has one.
            if let path = response.notification.request.content.userInfo["note"] as? String {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        default: break
        }
    }
}
