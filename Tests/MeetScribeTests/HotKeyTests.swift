import XCTest
@testable import MeetScribe

final class HotKeyTests: XCTestCase {
    func testDescriptionAndInactiveLifecycle() {
        XCTAssertEqual(HotKey.comboDescription, "⌥⇧R")
        XCTAssertEqual(
            HotKey.RegistrationError.eventHandler(-50).errorDescription,
            "Could not install hotkey handler (OSStatus -50)")
        XCTAssertEqual(
            HotKey.RegistrationError.hotKey(-9876).errorDescription,
            "The global shortcut is unavailable (OSStatus -9876)")

        var hotKey: HotKey? = HotKey(onPress: {})
        hotKey?.unregister()
        hotKey = nil
    }
}
