import XCTest
@testable import MeetScribe

final class MeetingDetectorTests: XCTestCase {
    func testChangesTrackConcurrentMeetingApplicationsIndependently() {
        let zoom = DetectedMeeting(bundleID: "us.zoom.xos", appName: "zoom")
        let slack = DetectedMeeting(bundleID: "com.tinyspeck.slackmacgap", appName: "slack")
        let teams = DetectedMeeting(bundleID: "com.microsoft.teams2", appName: "teams")

        let result = MeetingDetector.changes(
            previous: [zoom, slack],
            active: [slack, teams])

        XCTAssertEqual(result.started, [teams])
        XCTAssertEqual(result.ended, [zoom])
    }
}
