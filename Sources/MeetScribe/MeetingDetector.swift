import Foundation
import CoreAudio
import AppKit
import os

private let logger = Logger(subsystem: "dev.alejacre.meetscribe", category: "detector")

struct DetectedMeeting: Equatable, Hashable, Identifiable, Sendable {
    let bundleID: String
    let appName: String

    var id: String { bundleID }
}

enum MeetingProbeResult: Equatable, Sendable {
    case success([DetectedMeeting])
    case failure
}

@MainActor
final class MeetingDetector {
    static let confirmedAbsentPolls = 2

    static var knownApps: [String: String] {
        Dictionary(uniqueKeysWithValues: MeetingApps.defaults.map { ($0.bundleID, $0.appName) })
    }

    var onMeetingStart: ((DetectedMeeting) -> Void)?
    var onMeetingEnd: ((DetectedMeeting) -> Void)?

    private var timer: Timer?
    private var current: Set<DetectedMeeting> = []
    private var absentPolls: [DetectedMeeting: Int] = [:]
    private let appDefinitions: () -> [String: String]
    private let activeApplications: @MainActor ([String: String]) -> MeetingProbeResult
    private let isZoomMeetingActive: @MainActor () -> Bool

    init(
        appDefinitions: @escaping () -> [String: String] = { MeetingDetector.knownApps },
        activeApplications: @escaping @MainActor ([String: String]) -> MeetingProbeResult =
            MeetingDetector.appsUsingMicrophone,
        isZoomMeetingActive: @escaping @MainActor () -> Bool =
            MeetingDetector.zoomMeetingHelperRunning
    ) {
        self.appDefinitions = appDefinitions
        self.activeApplications = activeApplications
        self.isZoomMeetingActive = isZoomMeetingActive
    }

    func startPolling(interval: TimeInterval = 1.5) {
        stopPolling()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func poll() {
        guard case .success(let detected) = activeApplications(appDefinitions()) else {
            logger.error("meeting probe failed; preserving the previous meeting state")
            return
        }
        // Zoom holds the microphone after the meeting ends; its CptHost helper
        // only runs during an actual meeting, so treat idle Zoom as no-meeting
        // instead of letting it mask Teams/Chime also on the mic.
        let active = Set(detected.filter {
            $0.appName != "zoom" || isZoomMeetingActive()
        })
        let started = active.subtracting(current)
        for meeting in active {
            absentPolls.removeValue(forKey: meeting)
        }

        var ended: Set<DetectedMeeting> = []
        for meeting in current.subtracting(active) {
            let count = absentPolls[meeting, default: 0] + 1
            if count >= Self.confirmedAbsentPolls {
                absentPolls.removeValue(forKey: meeting)
                ended.insert(meeting)
            } else {
                absentPolls[meeting] = count
            }
        }

        if !started.isEmpty || !ended.isEmpty {
            let activeNames = active.map(\.appName).sorted().joined(separator: ",")
            let previousNames = current.map(\.appName).sorted().joined(separator: ",")
            let activeLabel = activeNames.isEmpty ? "none" : activeNames
            let previousLabel = previousNames.isEmpty ? "none" : previousNames
            logger.info("meeting state: \(activeLabel, privacy: .public) (was \(previousLabel, privacy: .public))")
        }
        current.formUnion(started)
        current.subtract(ended)
        for meeting in ended.sorted(by: Self.orderMeetings) {
            onMeetingEnd?(meeting)
        }
        for meeting in started.sorted(by: Self.orderMeetings) {
            onMeetingStart?(meeting)
        }
    }

    nonisolated static func changes(
        previous: Set<DetectedMeeting>,
        active: Set<DetectedMeeting>
    ) -> (started: Set<DetectedMeeting>, ended: Set<DetectedMeeting>) {
        (active.subtracting(previous), previous.subtracting(active))
    }

    private nonisolated static func orderMeetings(_ lhs: DetectedMeeting, _ rhs: DetectedMeeting) -> Bool {
        if lhs.appName != rhs.appName { return lhs.appName < rhs.appName }
        return lhs.bundleID < rhs.bundleID
    }

    static func zoomMeetingHelperRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "us.zoom.CptHost" || $0.localizedName == "CptHost"
        }
    }

    static func appsUsingMicrophone(
        knownApps: [String: String] = MeetingDetector.knownApps
    ) -> MeetingProbeResult {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return .failure }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr
        else { return .failure }

        var result: [DetectedMeeting] = []
        for obj in objects {
            var runningAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var rSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(obj, &runningAddr, 0, nil, &rSize, &running) == noErr,
                  running == 1 else { continue }

            var pidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var pid: pid_t = 0
            var pSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(obj, &pidAddr, 0, nil, &pSize, &pid) == noErr else { continue }

            guard let app = NSRunningApplication(processIdentifier: pid),
                  let bundleID = app.bundleIdentifier,
                  let name = knownApps[bundleID]
            else {
                continue
            }
            result.append(DetectedMeeting(bundleID: bundleID, appName: name))
        }
        return .success(result)
    }
}
