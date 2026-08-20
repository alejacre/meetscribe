import Foundation
import AppKit
import AVFoundation
import CoreGraphics
import UserNotifications

/// Single home for the TCC permissions MeetScribe needs. The setup wizard drives
/// these proactively; the recording path also reads them reactively.
enum Permissions {
    // MARK: Screen Recording (system audio capture rides on this grant)

    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Prompts once per app identity. After the user flips the switch in System
    /// Settings, preflight often keeps returning false until the app relaunches  -
    /// callers should surface a "quit and reopen" hint when that happens.
    @discardableResult
    static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    // MARK: Microphone

    static var micStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static func requestMic() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: Notifications

    static func notificationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    @discardableResult
    static func requestNotifications() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
    }

    // MARK: Deep links

    /// Opens a specific pane of System Settings › Privacy & Security. Anchors:
    /// `Privacy_ScreenCapture`, `Privacy_Microphone`.
    static func openPrivacyPane(_ anchor: String) {
        if let url = privacyPaneURL(anchor) {
            NSWorkspace.shared.open(url)
        }
    }

    static func privacyPaneURL(_ anchor: String) -> URL? {
        let supported = ["Privacy_ScreenCapture", "Privacy_Microphone"]
        guard supported.contains(anchor) else { return nil }
        return URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    static func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
