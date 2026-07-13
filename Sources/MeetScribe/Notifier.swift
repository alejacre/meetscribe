import Foundation
import AppKit
import UserNotifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    var onRecordAction: (() -> Void)?
    var onStopAction: (() -> Void)?
    var onRetryAction: ((URL) -> Void)?

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let record = UNNotificationAction(identifier: "RECORD", title: "Record", options: [])
        let stop = UNNotificationAction(identifier: "STOP", title: "Stop recording", options: [])
        let retry = UNNotificationAction(identifier: "RETRY", title: "Retry transcription", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "MEETING_START", actions: [record], intentIdentifiers: []),
            UNNotificationCategory(identifier: "MEETING_END", actions: [stop], intentIdentifiers: []),
            UNNotificationCategory(identifier: "TRANSCRIBE_FAILED", actions: [retry], intentIdentifiers: []),
        ])
    }

    func notify(title: String, body: String, category: String, userInfo: [String: String] = [:]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.userInfo = userInfo
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Same as notify, callable from background tasks (UNUserNotificationCenter is thread-safe).
    func notifyAsync(title: String, body: String, category: String, userInfo: [String: String] = [:]) async {
        notify(title: title, body: body, category: category, userInfo: userInfo)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        switch response.actionIdentifier {
        case "RECORD": onRecordAction?()
        case "STOP": onStopAction?()
        case "RETRY":
            if let path = response.notification.request.content.userInfo["folder"] as? String {
                onRetryAction?(URL(fileURLWithPath: path))
            }
        case UNNotificationDefaultActionIdentifier:
            // Tap on the notification body: reveal the recording folder if it has one.
            if let path = response.notification.request.content.userInfo["folder"] as? String {
                NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
            }
        default: break
        }
    }
}
