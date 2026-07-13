import Foundation
import CoreAudio
import AppKit

struct DetectedMeeting: Equatable {
    let bundleID: String
    let appName: String
}

final class MeetingDetector {
    static let knownApps: [String: String] = [
        "us.zoom.xos": "zoom",
        "com.tinyspeck.slackmacgap": "slack",
        "com.amazon.Amazon-Chime": "chime",
        "com.microsoft.teams2": "teams",
        "com.microsoft.teams": "teams",
        "com.apple.FaceTime": "facetime",
        "com.cisco.webexmeetingsapp": "webex",
        "Cisco-Systems.Spark": "webex",
    ]

    var onMeetingStart: ((DetectedMeeting) -> Void)?
    var onMeetingEnd: ((DetectedMeeting) -> Void)?

    private var timer: Timer?
    private var current: DetectedMeeting?

    func startPolling(interval: TimeInterval = 3) {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stopPolling() { timer?.invalidate(); timer = nil }

    private func poll() {
        let meeting = Self.appsUsingMicrophone().first
        if let meeting, meeting != current {
            current = meeting
            onMeetingStart?(meeting)
        } else if meeting == nil, let ended = current {
            current = nil
            onMeetingEnd?(ended)
        }
    }

    static func appsUsingMicrophone() -> [DetectedMeeting] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr
        else { return [] }

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
                  let name = knownApps[bundleID] else { continue }
            result.append(DetectedMeeting(bundleID: bundleID, appName: name))
        }
        return result
    }
}
