import Foundation
import AppKit
import UserNotifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let recordWithMicrophoneAction = "RECORD_WITH_MICROPHONE"
    static let recordSystemOnlyAction = "RECORD_SYSTEM_ONLY"

    var onRecordAction: ((String?, RecordingAudioMode) -> Void)?
    var onRetryAction: ((URL) -> Void)?
    var isEnabled = true

    /// Wires the delegate and notification categories. Does NOT request authorization:
    /// on first run the setup wizard asks (sequenced with the other permissions);
    /// afterwards `RecordingCoordinator` requests it at launch if still undetermined.
    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let recordWithMicrophone = UNNotificationAction(
            identifier: Self.recordWithMicrophoneAction,
            title: RecordingAudioMode.microphoneAndSystem.displayName,
            options: [])
        let recordSystemOnly = UNNotificationAction(
            identifier: Self.recordSystemOnlyAction,
            title: RecordingAudioMode.systemOnly.displayName,
            options: [])
        let retry = UNNotificationAction(identifier: "RETRY", title: "Retry transcription", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: "MEETING_START",
                actions: [recordWithMicrophone, recordSystemOnly],
                intentIdentifiers: []),
            UNNotificationCategory(identifier: "INFO", actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: "TRANSCRIBE_FAILED", actions: [retry], intentIdentifiers: []),
        ])
    }

    func notify(title: String, body: String, category: String, userInfo: [String: String] = [:]) {
        guard isEnabled else { return }
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
        case "RETRY":
            if let note = Self.noteURL(
                from: response.notification.request.content.userInfo,
                outputFolder: Settings().outputFolder)
            {
                onRetryAction?(note)
            }
        case UNNotificationDefaultActionIdentifier:
            // Tap on the notification body: open the meeting note if it has one.
            if let note = Self.noteURL(
                from: response.notification.request.content.userInfo,
                outputFolder: Settings().outputFolder)
            {
                let session = RecordingSession(existingNote: note)
                NSWorkspace.shared.open(
                    FileManager.default.fileExists(atPath: note.path) ? note : session.assetDir)
            }
        default:
            if let audioMode = Self.audioMode(
                forRecordActionIdentifier: response.actionIdentifier)
            {
                onRecordAction?(
                    response.notification.request.content.userInfo["meetingBundleID"] as? String,
                    audioMode)
            }
        }
    }

    /// Maps a MEETING_START action identifier to the audio mode it requests.
    /// The legacy "RECORD" identifier keeps notifications delivered by builds
    /// that offered a single record action working after an update; it maps to
    /// the old both-tracks behavior.
    static func audioMode(
        forRecordActionIdentifier actionIdentifier: String
    ) -> RecordingAudioMode? {
        switch actionIdentifier {
        case recordWithMicrophoneAction, "RECORD":
            .microphoneAndSystem
        case recordSystemOnlyAction:
            .systemOnly
        default:
            nil
        }
    }

    static func noteURL(
        from userInfo: [AnyHashable: Any],
        outputFolder: URL
    ) -> URL? {
        if let path = userInfo["notePath"] as? String {
            let note = URL(fileURLWithPath: path).standardizedFileURL
            guard note.pathExtension == "md",
                  note.lastPathComponent == URL(fileURLWithPath: note.lastPathComponent).lastPathComponent
            else {
                return nil
            }
            return note
        }
        guard let basename = userInfo["recording"] as? String,
              basename == URL(fileURLWithPath: basename).lastPathComponent,
              !basename.contains("/")
        else { return nil }
        return outputFolder.appendingPathComponent(basename + ".md")
    }
}
