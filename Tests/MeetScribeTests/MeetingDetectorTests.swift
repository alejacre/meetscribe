import XCTest
@testable import MeetScribe

@MainActor
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

    func testPollFiltersIdleZoomAndOrdersLifecycleCallbacks() {
        let zoom = DetectedMeeting(bundleID: "us.zoom.xos", appName: "zoom")
        let teamsB = DetectedMeeting(bundleID: "com.microsoft.teams.b", appName: "teams")
        let teamsA = DetectedMeeting(bundleID: "com.microsoft.teams.a", appName: "teams")
        let slack = DetectedMeeting(bundleID: "com.tinyspeck.slackmacgap", appName: "slack")
        let definitions = ["bundle": "display"]
        let harness = PollHarness(snapshots: [
            [zoom, teamsB, slack, teamsA],
            [zoom, teamsB, slack, teamsA],
            [zoom],
            [],
            [],
        ])
        var events: [String] = []
        let detector = MeetingDetector(
            appDefinitions: { definitions },
            activeApplications: { knownApps in
                XCTAssertEqual(knownApps, definitions)
                return .success(harness.snapshots.removeFirst())
            },
            isZoomMeetingActive: { harness.zoomIsActive })
        detector.onMeetingStart = { meeting in events.append("start:\(meeting.bundleID)") }
        detector.onMeetingEnd = { meeting in events.append("end:\(meeting.bundleID)") }

        detector.poll()
        harness.zoomIsActive = true
        detector.poll()
        detector.poll()
        detector.poll()
        detector.poll()

        XCTAssertEqual(events, [
            "start:\(slack.bundleID)",
            "start:\(teamsA.bundleID)",
            "start:\(teamsB.bundleID)",
            "start:\(zoom.bundleID)",
            "end:\(slack.bundleID)",
            "end:\(teamsA.bundleID)",
            "end:\(teamsB.bundleID)",
            "end:\(zoom.bundleID)",
        ])
    }

    func testStartAndStopPollingDriveInjectedSource() async {
        let meeting = DetectedMeeting(bundleID: "test.meeting", appName: "test")
        let started = expectation(description: "polling detected the meeting")
        let harness = PollHarness()
        let detector = MeetingDetector(
            appDefinitions: { [:] },
            activeApplications: { _ in
                harness.pollCount += 1
                return .success([meeting])
            },
            isZoomMeetingActive: { false })
        detector.onMeetingStart = { (_: DetectedMeeting) in started.fulfill() }

        detector.startPolling(interval: 0.01)
        await fulfillment(of: [started], timeout: 1)
        detector.stopPolling()
        detector.stopPolling()

        let stoppedCount = harness.pollCount
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(harness.pollCount, stoppedCount)
    }

    func testKnownAppsReflectDefaultDefinitions() {
        XCTAssertEqual(
            MeetingDetector.knownApps,
            Dictionary(uniqueKeysWithValues: MeetingApps.defaults.map { ($0.bundleID, $0.appName) }))
    }

    func testProbeFailurePreservesMeetingAndConfirmedAbsenceEndsIt() {
        let meeting = DetectedMeeting(bundleID: "test.meeting", appName: "test")
        let harness = ProbeHarness(results: [
            .success([meeting]),
            .failure,
            .success([]),
            .success([]),
        ])
        var events: [String] = []
        let detector = MeetingDetector(
            appDefinitions: { [:] },
            activeApplications: { _ in harness.results.removeFirst() },
            isZoomMeetingActive: { false })
        detector.onMeetingStart = { _ in events.append("start") }
        detector.onMeetingEnd = { _ in events.append("end") }

        detector.poll()
        detector.poll()
        detector.poll()
        XCTAssertEqual(events, ["start"])
        detector.poll()
        XCTAssertEqual(events, ["start", "end"])
    }

    private final class PollHarness: @unchecked Sendable {
        var snapshots: [[DetectedMeeting]]
        var zoomIsActive = false
        var pollCount = 0

        init(snapshots: [[DetectedMeeting]] = []) {
            self.snapshots = snapshots
        }
    }

    private final class ProbeHarness: @unchecked Sendable {
        var results: [MeetingProbeResult]

        init(results: [MeetingProbeResult]) {
            self.results = results
        }
    }
}
