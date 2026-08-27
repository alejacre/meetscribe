import Foundation
import XCTest
@testable import MeetScribe

final class SingleInstanceGuardTests: XCTestCase {
    func testOnlyOneGuardCanHoldAnIdentifierAtATime() throws {
        let identifier = "test.meetscribe.single-instance.\(UUID().uuidString)"
        let first = SingleInstanceGuard()
        let second = SingleInstanceGuard()
        let lockURL = SingleInstanceGuard.lockURL(identifier: identifier)
        defer { try? FileManager.default.removeItem(at: lockURL) }

        XCTAssertEqual(first.acquire(identifier: identifier), .acquired)
        XCTAssertEqual(second.acquire(identifier: identifier), .alreadyRunning)

        first.release()

        XCTAssertEqual(second.acquire(identifier: identifier), .acquired)
    }

    func testExistingUnlockedLockFileDoesNotBlockAcquisition() throws {
        let identifier = "test.meetscribe.single-instance.stale.\(UUID().uuidString)"
        let guardInstance = SingleInstanceGuard()
        let lockURL = SingleInstanceGuard.lockURL(identifier: identifier)
        defer { try? FileManager.default.removeItem(at: lockURL) }
        try Data("stale-pid\n".utf8).write(to: lockURL)

        XCTAssertEqual(guardInstance.acquire(identifier: identifier), .acquired)
    }

    func testOneGuardCannotAcquireDifferentIdentifiers() {
        let guardInstance = SingleInstanceGuard()
        let firstIdentifier = "test.meetscribe.single-instance.first.\(UUID().uuidString)"
        let secondIdentifier = "test.meetscribe.single-instance.second.\(UUID().uuidString)"
        let firstLockURL = SingleInstanceGuard.lockURL(identifier: firstIdentifier)
        let secondLockURL = SingleInstanceGuard.lockURL(identifier: secondIdentifier)
        defer {
            guardInstance.release()
            try? FileManager.default.removeItem(at: firstLockURL)
            try? FileManager.default.removeItem(at: secondLockURL)
        }

        XCTAssertEqual(guardInstance.acquire(identifier: firstIdentifier), .acquired)
        XCTAssertEqual(guardInstance.acquire(identifier: secondIdentifier), .unavailable)
    }
}
