# MeetScribe Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** macOS menu bar app that records meeting audio (mic + system, separate tracks), transcribes with mlx_whisper, attributes Me/Them by track, and polishes the transcript with the `claude` CLI.

**Architecture:** SwiftUI `MenuBarExtra` app built as a SwiftPM executable, assembled into a `.app` bundle by a build script (needed for TCC permissions and notifications). One `SCStream` (macOS 15+ ScreenCaptureKit) captures system audio and microphone as separate outputs written live to `system.m4a` / `mic.m4a`; a mixed `audio.m4a` is composed offline after stop. Transcription and cleanup are subprocesses (`mlx_whisper`, `claude -p`). A `RecordingCoordinator` orchestrates the pipeline; pure logic (formatting, naming, settings) is unit-tested.

**Tech Stack:** Swift 5.10+/SwiftPM, SwiftUI MenuBarExtra, ScreenCaptureKit, AVFoundation, CoreAudio process taps API (detection), UserNotifications, XCTest.

**Spec:** `docs/specs/2026-07-13-meetscribe-design.md`

---

## File Structure

```
Package.swift
Info.plist
build.sh                                  # swift build + assemble MeetScribe.app
Sources/MeetScribe/
  MeetScribeApp.swift                     # @main, MenuBarExtra, app state
  AppState.swift                          # observable state machine (idle/recording/transcribing)
  Settings.swift                          # UserDefaults-backed settings
  RecordingSession.swift                  # folder naming, file URLs
  AudioRecorder.swift                     # SCStream capture → mic/system m4a; offline mix
  MeetingDetector.swift                   # CoreAudio poll: which app uses the mic
  Transcriber.swift                       # mlx_whisper subprocess + JSON parsing
  TranscriptFormatter.swift               # merge tracks → markdown (Me/Them)
  ClaudeCleaner.swift                     # claude -p cleanup pass, fallback-safe
  Notifier.swift                          # UNUserNotificationCenter, Record/Stop actions
  Subprocess.swift                        # small Process helper
  SettingsView.swift                      # settings window
Tests/MeetScribeTests/
  SettingsTests.swift
  RecordingSessionTests.swift
  TranscriptFormatterTests.swift
  TranscriberParseTests.swift
```

---

### Task 1: Project scaffold + app bundle build

**Files:**
- Create: `Package.swift`, `Info.plist`, `build.sh`, `Sources/MeetScribe/MeetScribeApp.swift`, `Sources/MeetScribe/AppState.swift`, `.gitignore`

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MeetScribe",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "MeetScribe", path: "Sources/MeetScribe"),
        .testTarget(name: "MeetScribeTests", dependencies: ["MeetScribe"], path: "Tests/MeetScribeTests"),
    ]
)
```

- [ ] **Step 2: Write `Info.plist`** (bundle identity + permission strings; LSUIElement hides Dock icon)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MeetScribe</string>
    <key>CFBundleIdentifier</key><string>dev.alejacre.meetscribe</string>
    <key>CFBundleName</key><string>MeetScribe</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>MeetScribe records your voice during meetings.</string>
    <key>NSAudioCaptureUsageDescription</key><string>MeetScribe records system audio during meetings.</string>
</dict>
</plist>
```

- [ ] **Step 3: Write `build.sh`** (assemble + ad-hoc codesign; TCC needs a stable signed bundle)

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/MeetScribe.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/MeetScribe "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
codesign --force --deep --sign - "$APP"
echo "Built $APP"
```

- [ ] **Step 4: Write `AppState.swift`**

```swift
import Foundation

enum AppPhase: Equatable {
    case idle
    case recording(start: Date)
    case transcribing
}

@MainActor
final class AppState: ObservableObject {
    @Published var phase: AppPhase = .idle
    @Published var lastError: String?
    @Published var recentRecordings: [URL] = []
}
```

- [ ] **Step 5: Write minimal `MeetScribeApp.swift`** (menu with placeholder items + Quit)

```swift
import SwiftUI

@main
struct MeetScribeApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            Text(menuTitle)
            Divider()
            Button("Quit MeetScribe") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: iconName)
        }
    }

    private var iconName: String {
        switch state.phase {
        case .idle: "waveform"
        case .recording: "record.circle.fill"
        case .transcribing: "hourglass"
        }
    }

    private var menuTitle: String {
        switch state.phase {
        case .idle: "MeetScribe  -  idle"
        case .recording: "Recording…"
        case .transcribing: "Transcribing…"
        }
    }
}
```

- [ ] **Step 6: Write `.gitignore`** (`.build/`, `build/`, `.DS_Store`)

- [ ] **Step 7: Build and launch**

Run: `chmod +x build.sh && ./build.sh && open build/MeetScribe.app`
Expected: waveform icon appears in the menu bar; menu shows "MeetScribe  -  idle" and Quit works.

- [ ] **Step 8: Commit**  -  `git add -A && git commit -m "feat: scaffold menu bar app with bundle build script"`

---

### Task 2: Settings (TDD)

**Files:**
- Create: `Sources/MeetScribe/Settings.swift`, `Tests/MeetScribeTests/SettingsTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import MeetScribe

final class SettingsTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "test.meetscribe")!
        defaults.removePersistentDomain(forName: "test.meetscribe")
    }

    func testDefaults() {
        let s = Settings(defaults: defaults)
        XCTAssertEqual(s.outputFolder.path, NSHomeDirectory() + "/Recordings")
        XCTAssertEqual(s.whisperModel, "mlx-community/whisper-large-v3-turbo")
        XCTAssertTrue(s.claudeCleanupEnabled)
        XCTAssertNil(s.autoStopSeconds)
        XCTAssertTrue(s.mlxWhisperPath.hasSuffix("mlx_whisper"))
    }

    func testPersistence() {
        var s = Settings(defaults: defaults)
        s.outputFolder = URL(fileURLWithPath: "/tmp/recs")
        s.claudeCleanupEnabled = false
        s.autoStopSeconds = 30
        let s2 = Settings(defaults: defaults)
        XCTAssertEqual(s2.outputFolder.path, "/tmp/recs")
        XCTAssertFalse(s2.claudeCleanupEnabled)
        XCTAssertEqual(s2.autoStopSeconds, 30)
    }
}
```

- [ ] **Step 2: Run** `swift test --filter SettingsTests`  -  Expected: FAIL (Settings not defined)

- [ ] **Step 3: Implement `Settings.swift`**

```swift
import Foundation

struct Settings {
    private let d: UserDefaults
    init(defaults: UserDefaults = .standard) { self.d = defaults }

    var outputFolder: URL {
        get { d.string(forKey: "outputFolder").map { URL(fileURLWithPath: $0) }
              ?? URL(fileURLWithPath: NSHomeDirectory() + "/Recordings") }
        set { d.set(newValue.path, forKey: "outputFolder") }
    }
    var whisperModel: String {
        get { d.string(forKey: "whisperModel") ?? "mlx-community/whisper-large-v3-turbo" }
        set { d.set(newValue, forKey: "whisperModel") }
    }
    var mlxWhisperPath: String {
        get { d.string(forKey: "mlxWhisperPath")
              ?? NSHomeDirectory() + "/.local/share/mise/installs/python/3.12/bin/mlx_whisper" }
        set { d.set(newValue, forKey: "mlxWhisperPath") }
    }
    var claudeCleanupEnabled: Bool {
        get { d.object(forKey: "claudeCleanupEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "claudeCleanupEnabled") }
    }
    var autoStopSeconds: Int? {
        get { d.object(forKey: "autoStopSeconds") as? Int }
        set { if let v = newValue { d.set(v, forKey: "autoStopSeconds") } else { d.removeObject(forKey: "autoStopSeconds") } }
    }
}
```

- [ ] **Step 4: Run** `swift test --filter SettingsTests`  -  Expected: PASS
- [ ] **Step 5: Commit**  -  `git commit -am "feat: UserDefaults-backed settings"`

---

### Task 3: RecordingSession  -  folder naming and file URLs (TDD)

**Files:**
- Create: `Sources/MeetScribe/RecordingSession.swift`, `Tests/MeetScribeTests/RecordingSessionTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import MeetScribe

final class RecordingSessionTests: XCTestCase {
    func testFolderNameWithApp() {
        let date = ISO8601DateFormatter().date(from: "2026-07-13T15:30:00+02:00")!
        let s = RecordingSession(root: URL(fileURLWithPath: "/tmp/recs"), start: date, appName: "zoom")
        XCTAssertEqual(s.folder.path, "/tmp/recs/2026-07-13_15-30_zoom")
    }

    func testFolderNameManual() {
        let date = ISO8601DateFormatter().date(from: "2026-07-13T09-05-00+02:00".replacingOccurrences(of: "-05-", with: ":05:"))
            ?? ISO8601DateFormatter().date(from: "2026-07-13T09:05:00+02:00")!
        let s = RecordingSession(root: URL(fileURLWithPath: "/tmp/recs"), start: date, appName: nil)
        XCTAssertTrue(s.folder.lastPathComponent.hasSuffix("_manual"))
        XCTAssertTrue(s.folder.lastPathComponent.hasPrefix("2026-07-13_09-05"))
    }

    func testFileURLs() {
        let s = RecordingSession(root: URL(fileURLWithPath: "/tmp/recs"), start: Date(), appName: "slack")
        XCTAssertEqual(s.micURL.lastPathComponent, "mic.m4a")
        XCTAssertEqual(s.systemURL.lastPathComponent, "system.m4a")
        XCTAssertEqual(s.mixURL.lastPathComponent, "audio.m4a")
        XCTAssertEqual(s.transcriptMD.lastPathComponent, "transcript.md")
        XCTAssertEqual(s.transcriptJSON.lastPathComponent, "transcript.json")
    }

    func testAppNameSanitized() {
        let s = RecordingSession(root: URL(fileURLWithPath: "/tmp"), start: Date(), appName: "Microsoft Teams")
        XCTAssertTrue(s.folder.lastPathComponent.hasSuffix("_microsoft-teams"))
    }
}
```

- [ ] **Step 2: Run** `swift test --filter RecordingSessionTests`  -  Expected: FAIL

- [ ] **Step 3: Implement `RecordingSession.swift`**

```swift
import Foundation

struct RecordingSession {
    let folder: URL
    let start: Date

    init(root: URL, start: Date, appName: String?) {
        self.start = start
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let app = (appName ?? "manual")
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        self.folder = root.appendingPathComponent("\(fmt.string(from: start))_\(app)")
    }

    var micURL: URL { folder.appendingPathComponent("mic.m4a") }
    var systemURL: URL { folder.appendingPathComponent("system.m4a") }
    var mixURL: URL { folder.appendingPathComponent("audio.m4a") }
    var transcriptMD: URL { folder.appendingPathComponent("transcript.md") }
    var transcriptJSON: URL { folder.appendingPathComponent("transcript.json") }

    func createFolder() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
}
```

- [ ] **Step 4: Run** `swift test --filter RecordingSessionTests`  -  Expected: PASS
- [ ] **Step 5: Commit**  -  `git commit -am "feat: recording session folder naming"`

---

### Task 4: TranscriptFormatter  -  merge tracks into Me/Them markdown (TDD)

**Files:**
- Create: `Sources/MeetScribe/TranscriptFormatter.swift`, `Tests/MeetScribeTests/TranscriptFormatterTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import MeetScribe

final class TranscriptFormatterTests: XCTestCase {
    func seg(_ start: Double, _ end: Double, _ text: String) -> WhisperSegment {
        WhisperSegment(start: start, end: end, text: text)
    }

    func testInterleavesByTimestampAndLabels() {
        let mic = [seg(5, 8, "Hola, ¿me oís?")]
        let system = [seg(0, 4, "Hi everyone."), seg(9, 12, "Yes, loud and clear.")]
        let md = TranscriptFormatter.format(mic: mic, system: system,
                                            header: .init(date: "2026-07-13 15:30", app: "zoom",
                                                          duration: "00:12", model: "turbo", cleanedByClaude: false))
        let lines = md.split(separator: "\n").map(String.init)
        let themFirst = lines.firstIndex { $0.contains("**Them:** Hi everyone.") }!
        let me = lines.firstIndex { $0.contains("**Me:** Hola, ¿me oís?") }!
        let themLast = lines.firstIndex { $0.contains("**Them:** Yes, loud and clear.") }!
        XCTAssertLessThan(themFirst, me)
        XCTAssertLessThan(me, themLast)
    }

    func testTimestampFormat() {
        let md = TranscriptFormatter.format(mic: [seg(3661, 3663, "one hour in")], system: [],
                                            header: .init(date: "d", app: "a", duration: "x", model: "m", cleanedByClaude: false))
        XCTAssertTrue(md.contains("[01:01:01] **Me:** one hour in"))
    }

    func testConsecutiveSameSpeakerSegmentsMergeWithinPause() {
        // gap < 2s → same paragraph; gap >= 2s → new line
        let mic = [seg(0, 2, "First part."), seg(2.5, 4, "same thought."), seg(10, 11, "New thought.")]
        let md = TranscriptFormatter.format(mic: mic, system: [],
                                            header: .init(date: "d", app: "a", duration: "x", model: "m", cleanedByClaude: false))
        XCTAssertTrue(md.contains("**Me:** First part. same thought."))
        XCTAssertTrue(md.contains("[00:00:10] **Me:** New thought."))
    }

    func testHeader() {
        let md = TranscriptFormatter.format(mic: [], system: [],
                                            header: .init(date: "2026-07-13 15:30", app: "zoom",
                                                          duration: "45:02", model: "turbo", cleanedByClaude: false))
        XCTAssertTrue(md.contains("# Meeting transcript  -  2026-07-13 15:30"))
        XCTAssertTrue(md.contains("zoom"))
        XCTAssertTrue(md.contains("45:02"))
        XCTAssertTrue(md.contains("turbo"))
        XCTAssertTrue(md.contains("not cleaned"))
    }
}
```

- [ ] **Step 2: Run** `swift test --filter TranscriptFormatterTests`  -  Expected: FAIL

- [ ] **Step 3: Implement `TranscriptFormatter.swift`**

```swift
import Foundation

struct WhisperSegment: Codable, Equatable {
    let start: Double
    let end: Double
    let text: String
}

enum Speaker: String { case me = "Me", them = "Them" }

struct TranscriptHeader {
    let date: String
    let app: String
    let duration: String
    let model: String
    let cleanedByClaude: Bool
}

enum TranscriptFormatter {
    static let pauseGap: Double = 2.0

    static func format(mic: [WhisperSegment], system: [WhisperSegment], header: TranscriptHeader) -> String {
        struct Tagged { let speaker: Speaker; let seg: WhisperSegment }
        let all = (mic.map { Tagged(speaker: .me, seg: $0) } + system.map { Tagged(speaker: .them, seg: $0) })
            .sorted { $0.seg.start < $1.seg.start }

        var turns: [(speaker: Speaker, start: Double, texts: [String])] = []
        for t in all {
            let text = t.seg.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if var last = turns.last, last.speaker == t.speaker,
               let prevEnd = (last.texts.isEmpty ? nil : t.seg.start), // placeholder, replaced below
               prevEnd >= 0 {
                _ = prevEnd
            }
            if let lastIdx = turns.indices.last,
               turns[lastIdx].speaker == t.speaker,
               t.seg.start - lastEnd(of: all, before: t) < pauseGap {
                turns[lastIdx].texts.append(text)
            } else {
                turns.append((t.speaker, t.seg.start, [text]))
            }
        }

        var out = """
        # Meeting transcript  -  \(header.date)

        - App: \(header.app)
        - Duration: \(header.duration)
        - Model: \(header.model)
        - Cleanup: \(header.cleanedByClaude ? "cleaned by Claude" : "not cleaned (raw whisper)")

        ---

        """
        for turn in turns {
            out += "\n[\(hms(turn.start))] **\(turn.speaker.rawValue):** \(turn.texts.joined(separator: " "))\n"
        }
        return out
    }

    // end of the segment immediately preceding `t` in the merged, sorted list
    private static func lastEnd(of all: [some Any], before t: Any) -> Double { 0 } // replaced in real impl

    static func hms(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
```

**Note to implementer:** the merge loop above sketches intent but the `lastEnd` helper is deliberately wrong as written  -  implement it properly by tracking the previous segment's `end` in a local variable inside the loop:

```swift
        var turns: [(speaker: Speaker, start: Double, texts: [String])] = []
        var prevEnd: Double = -.infinity
        var prevSpeaker: Speaker? = nil
        for t in all {
            let text = t.seg.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if prevSpeaker == t.speaker, t.seg.start - prevEnd < pauseGap, !turns.isEmpty {
                turns[turns.count - 1].texts.append(text)
            } else {
                turns.append((t.speaker, t.seg.start, [text]))
            }
            prevEnd = t.seg.end
            prevSpeaker = t.speaker
        }
```

Use this loop verbatim and delete the `lastEnd` helper.

- [ ] **Step 4: Run** `swift test --filter TranscriptFormatterTests`  -  Expected: PASS
- [ ] **Step 5: Commit**  -  `git commit -am "feat: transcript formatter with Me/Them interleaving"`

---

### Task 5: Subprocess helper + Transcriber (parse TDD, run manual)

**Files:**
- Create: `Sources/MeetScribe/Subprocess.swift`, `Sources/MeetScribe/Transcriber.swift`, `Tests/MeetScribeTests/TranscriberParseTests.swift`

- [ ] **Step 1: Write `Subprocess.swift`**

```swift
import Foundation

enum SubprocessError: Error { case nonZeroExit(Int32, stderr: String) }

enum Subprocess {
    @discardableResult
    static func run(_ executable: String, _ args: [String], stdin: String? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        if let stdin {
            let inPipe = Pipe()
            p.standardInput = inPipe
            try p.run()
            inPipe.fileHandleForWriting.write(stdin.data(using: .utf8)!)
            inPipe.fileHandleForWriting.closeFile()
        } else {
            try p.run()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw SubprocessError.nonZeroExit(p.terminationStatus,
                stderr: String(data: errData, encoding: .utf8) ?? "")
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}
```

- [ ] **Step 2: Write failing parse test** (fixture mirrors mlx_whisper JSON output shape)

```swift
import XCTest
@testable import MeetScribe

final class TranscriberParseTests: XCTestCase {
    func testParsesWhisperJSON() throws {
        let json = """
        {"text": " Hola. Adiós.", "language": "es",
         "segments": [
           {"id": 0, "start": 0.0, "end": 1.5, "text": " Hola.", "tokens": [1], "temperature": 0.0},
           {"id": 1, "start": 2.0, "end": 3.0, "text": " Adiós.", "tokens": [2], "temperature": 0.0}
         ]}
        """.data(using: .utf8)!
        let segs = try Transcriber.parseSegments(json)
        XCTAssertEqual(segs, [WhisperSegment(start: 0.0, end: 1.5, text: " Hola."),
                              WhisperSegment(start: 2.0, end: 3.0, text: " Adiós.")])
    }
}
```

- [ ] **Step 3: Run** `swift test --filter TranscriberParseTests`  -  Expected: FAIL

- [ ] **Step 4: Implement `Transcriber.swift`**

```swift
import Foundation

struct Transcriber {
    let mlxWhisperPath: String
    let model: String

    /// Transcribes one audio file; returns its segments.
    /// mlx_whisper writes <output-dir>/<input-basename>.json
    func transcribe(_ audio: URL) throws -> [WhisperSegment] {
        let dir = audio.deletingLastPathComponent()
        try Subprocess.run(mlxWhisperPath, [
            audio.path,
            "--model", model,
            "--output-format", "json",
            "--output-dir", dir.path,
        ])
        let jsonURL = dir.appendingPathComponent(audio.deletingPathExtension().lastPathComponent + ".json")
        let data = try Data(contentsOf: jsonURL)
        return try Self.parseSegments(data)
    }

    static func parseSegments(_ data: Data) throws -> [WhisperSegment] {
        struct Root: Codable { let segments: [WhisperSegment] }
        // WhisperSegment ignores unknown keys (id, tokens, ...) via Codable subset
        return try JSONDecoder().decode(Root.self, from: data).segments
    }
}
```

- [ ] **Step 5: Run** `swift test --filter TranscriberParseTests`  -  Expected: PASS

- [ ] **Step 6: Manual smoke test of the real CLI** (verifies flags before the app depends on them)

```bash
say -o /tmp/ms-test.aiff "testing meet scribe one two three" && \
afconvert -f m4af -d aac /tmp/ms-test.aiff /tmp/ms-test.m4a && \
~/.local/share/mise/installs/python/3.12/bin/mlx_whisper /tmp/ms-test.m4a \
  --model mlx-community/whisper-large-v3-turbo --output-format json --output-dir /tmp && \
python3 -c "import json; print(json.load(open('/tmp/ms-test.json'))['text'])"
```
Expected: printed text ≈ "testing meet scribe one two three". If flags differ, fix `Transcriber.transcribe` accordingly.

- [ ] **Step 7: Commit**  -  `git commit -am "feat: mlx_whisper transcriber and subprocess helper"`

---

### Task 6: ClaudeCleaner

**Files:**
- Create: `Sources/MeetScribe/ClaudeCleaner.swift`

- [ ] **Step 1: Implement** (no unit test  -  thin subprocess wrapper; behavior verified end-to-end in Task 10)

```swift
import Foundation

enum ClaudeCleaner {
    static let prompt = """
    You are a transcript editor. Clean up the meeting transcript below: fix punctuation and casing, \
    remove filler words (um, eh, vale vale, you know) and false starts, and merge fragments into \
    coherent paragraphs. STRICT RULES: keep every [hh:mm:ss] timestamp and every **Me:**/**Them:** \
    label exactly as-is; keep each language (Spanish/English) as spoken  -  do not translate; do not \
    summarize, reorder, or omit content; keep the markdown header untouched. Output ONLY the cleaned \
    markdown, no commentary.
    """

    /// Returns cleaned markdown, or nil if claude is unavailable/fails (caller falls back to raw).
    static func clean(_ markdown: String) -> String? {
        let candidates = [NSHomeDirectory() + "/.local/bin/claude", "/usr/local/bin/claude",
                          "/opt/homebrew/bin/claude"]
        guard let bin = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return nil }
        let result = try? Subprocess.run(bin, ["-p", prompt], stdin: markdown)
        guard let result, result.contains("# Meeting transcript") else { return nil }
        return result
    }
}
```

- [ ] **Step 2: Verify claude binary location**

Run: `which claude`
Expected: one of the candidate paths. If different, add it to `candidates`.

- [ ] **Step 3: Build**  -  `swift build`  -  Expected: succeeds
- [ ] **Step 4: Commit**  -  `git commit -am "feat: claude cleanup pass with fallback"`

---

### Task 7: AudioRecorder (ScreenCaptureKit)

**Files:**
- Create: `Sources/MeetScribe/AudioRecorder.swift`

No unit tests (hardware/permissions); verified manually in Step 3 and end-to-end in Task 10.

- [ ] **Step 1: Implement `AudioRecorder.swift`**

```swift
import Foundation
import ScreenCaptureKit
import AVFoundation

final class AudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var micFile: AVAudioFile?
    private var systemFile: AVAudioFile?
    private let queue = DispatchQueue(label: "meetscribe.audio")
    private(set) var sourceWarning: String?

    func start(session: RecordingSession) async throws {
        try session.createFolder()
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw NSError(domain: "MeetScribe", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display found (screen recording permission?)"])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = true
        config.sampleRate = 48_000
        config.channelCount = 1
        // minimize video cost: SCK requires a video stream, keep it tiny and never write it
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async throws {
        try await stream?.stopCapture()
        stream = nil
        queue.sync { micFile = nil; systemFile = nil } // flush/close
    }

    // MARK: SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio || type == .microphone,
              sampleBuffer.isValid,
              let pcm = sampleBuffer.asPCMBuffer else { return }
        do {
            switch type {
            case .microphone:
                if micFile == nil { micFile = try makeFile(url: pendingSession!.micURL, format: pcm.format) }
                try micFile?.write(from: pcm)
            case .audio:
                if systemFile == nil { systemFile = try makeFile(url: pendingSession!.systemURL, format: pcm.format) }
                try systemFile?.write(from: pcm)
            default: break
            }
        } catch {
            sourceWarning = "A capture source failed: \(error.localizedDescription)"
        }
    }

    private var pendingSession: RecordingSession?
    func prepare(session: RecordingSession) { pendingSession = session }

    private func makeFile(url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 64_000,
        ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }

    /// Offline mix mic + system into audio.m4a after stop.
    static func mix(session: RecordingSession) async throws {
        let comp = AVMutableComposition()
        for url in [session.micURL, session.systemURL]
        where FileManager.default.fileExists(atPath: url.path) {
            let asset = AVURLAsset(url: url)
            guard let srcTrack = try await asset.loadTracks(withMediaType: .audio).first,
                  let dstTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let duration = try await asset.load(.duration)
            try dstTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: srcTrack, at: .zero)
        }
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A)
        else { throw NSError(domain: "MeetScribe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot create export session"]) }
        try await export.export(to: session.mixURL, as: .m4a)
    }
}

extension CMSampleBuffer {
    var asPCMBuffer: AVAudioPCMBuffer? {
        try? withAudioBufferList { list, _ -> AVAudioPCMBuffer? in
            guard let absd = formatDescription?.audioStreamBasicDescription else { return nil }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: absd.mSampleRate,
                                             channels: absd.mChannelsPerFrame) else { return nil }
            return AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer)
        } ?? nil
    }
}
```

**Call order contract:** callers must invoke `prepare(session:)` before `start(session:)` (start does not set `pendingSession`; wiring in Task 10 does both).

- [ ] **Step 2: Build**  -  `swift build`  -  Expected: compiles. Fix API drift against the macOS 26 SDK if any (e.g. `SCStreamConfiguration.captureMicrophone` naming); consult `xcrun --show-sdk-path` headers.

- [ ] **Step 3: Manual capture test.** Temporarily add a debug menu item that starts a 10s recording into `/tmp/ms-capture-test` (or drive via Task 10's UI later if preferred). Play music, speak into the mic, then:

Run: `afinfo /tmp/ms-capture-test/mic.m4a && afinfo /tmp/ms-capture-test/system.m4a`
Expected: both files exist with nonzero duration; grant Screen Recording + Microphone permissions when macOS prompts.

- [ ] **Step 4: Commit**  -  `git commit -am "feat: SCK dual-track audio recorder with offline mix"`

---

### Task 8: MeetingDetector

**Files:**
- Create: `Sources/MeetScribe/MeetingDetector.swift`

- [ ] **Step 1: Implement** (CoreAudio process objects, macOS 14+ API)

```swift
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
        let active = Self.appsUsingMicrophone()
        let meeting = active.first
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
```

- [ ] **Step 2: Build**  -  `swift build`  -  Expected: compiles.

- [ ] **Step 3: Manual test.** Add temporary debug logging of `MeetingDetector.appsUsingMicrophone()` on each poll, start a Zoom test meeting or Slack huddle, confirm the app is detected within ~3s and detection clears when the call ends. Remove the logging.

- [ ] **Step 4: Commit**  -  `git commit -am "feat: meeting detection via CoreAudio process list"`

---

### Task 9: Notifier

**Files:**
- Create: `Sources/MeetScribe/Notifier.swift`

- [ ] **Step 1: Implement**

```swift
import Foundation
import UserNotifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
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

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        switch response.actionIdentifier {
        case "RECORD": onRecordAction?()
        case "STOP": onStopAction?()
        case "RETRY":
            if let path = response.notification.request.content.userInfo["folder"] as? String {
                onRetryAction?(URL(fileURLWithPath: path))
            }
        default: break
        }
    }
}
```

- [ ] **Step 2: Build**  -  `swift build`  -  Expected: compiles.
- [ ] **Step 3: Commit**  -  `git commit -am "feat: notifications with record/stop/retry actions"`

---

### Task 10: RecordingCoordinator + full menu UI + SettingsView (wiring)

**Files:**
- Create: `Sources/MeetScribe/RecordingCoordinator.swift`, `Sources/MeetScribe/SettingsView.swift`
- Modify: `Sources/MeetScribe/MeetScribeApp.swift`, `Sources/MeetScribe/AppState.swift`

- [ ] **Step 1: Implement `RecordingCoordinator.swift`**  -  the pipeline glue

```swift
import Foundation
import AppKit

@MainActor
final class RecordingCoordinator: ObservableObject {
    let state: AppState
    let notifier = Notifier()
    let detector = MeetingDetector()
    private var recorder: AudioRecorder?
    private var session: RecordingSession?
    private var detectedApp: String?
    private var settings = Settings()

    init(state: AppState) {
        self.state = state
        notifier.setup()
        notifier.onRecordAction = { [weak self] in Task { await self?.startRecording() } }
        notifier.onStopAction = { [weak self] in Task { await self?.stopRecording() } }
        notifier.onRetryAction = { [weak self] folder in Task { await self?.retryTranscription(folder: folder) } }
        detector.onMeetingStart = { [weak self] meeting in
            guard let self, case .idle = self.state.phase else { return }
            self.detectedApp = meeting.appName
            self.notifier.notify(title: "Meeting detected: \(meeting.appName)",
                                 body: "Want to record it?", category: "MEETING_START")
        }
        detector.onMeetingEnd = { [weak self] _ in
            guard let self, case .recording = self.state.phase else { return }
            self.notifier.notify(title: "Meeting ended",
                                 body: "Stop the recording?", category: "MEETING_END")
            if let secs = self.settings.autoStopSeconds {
                Task {
                    try? await Task.sleep(for: .seconds(secs))
                    if case .recording = self.state.phase { await self.stopRecording() }
                }
            }
        }
        detector.startPolling()
        refreshRecent()
    }

    func startRecording() async {
        guard case .idle = state.phase else { return }
        let s = RecordingSession(root: settings.outputFolder, start: Date(), appName: detectedApp)
        let r = AudioRecorder()
        r.prepare(session: s)
        do {
            try await r.start(session: s)
            recorder = r
            session = s
            state.phase = .recording(start: Date())
        } catch {
            state.lastError = "Could not start recording: \(error.localizedDescription)"
        }
    }

    func stopRecording() async {
        guard case .recording = state.phase, let r = recorder, let s = session else { return }
        state.phase = .transcribing
        do {
            try await r.stop()
            if let warning = r.sourceWarning { state.lastError = warning }
            try await AudioRecorder.mix(session: s)
            try await transcribe(session: s)
        } catch {
            state.lastError = error.localizedDescription
            notifier.notify(title: "Transcription failed", body: "Audio is safe. Retry?",
                            category: "TRANSCRIBE_FAILED", userInfo: ["folder": s.folder.path])
        }
        recorder = nil
        session = nil
        detectedApp = nil
        state.phase = .idle
        refreshRecent()
    }

    private func transcribe(session s: RecordingSession) async throws {
        let settings = self.settings
        let start = s.start
        let result = try await Task.detached(priority: .userInitiated) { () -> String in
            let t = Transcriber(mlxWhisperPath: settings.mlxWhisperPath, model: settings.whisperModel)
            let mic = FileManager.default.fileExists(atPath: s.micURL.path) ? try t.transcribe(s.micURL) : []
            let sys = FileManager.default.fileExists(atPath: s.systemURL.path) ? try t.transcribe(s.systemURL) : []

            // consolidate raw segments
            let raw = try JSONEncoder().encode(["mic": mic, "system": sys])
            try raw.write(to: s.transcriptJSON)

            let dur = max(mic.last?.end ?? 0, sys.last?.end ?? 0)
            let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH:mm"
            var cleaned = false
            var md = TranscriptFormatter.format(mic: mic, system: sys, header: .init(
                date: fmt.string(from: start),
                app: s.folder.lastPathComponent.components(separatedBy: "_").last ?? "manual",
                duration: TranscriptFormatter.hms(dur),
                model: settings.whisperModel, cleanedByClaude: false))
            if settings.claudeCleanupEnabled, let polished = ClaudeCleaner.clean(md) {
                md = polished
                cleaned = true
            }
            _ = cleaned
            return md
        }.value
        try result.write(to: s.transcriptMD, atomically: true, encoding: .utf8)
        notifier.notify(title: "Transcript ready", body: s.folder.lastPathComponent, category: "MEETING_END")
    }

    func retryTranscription(folder: URL) async {
        state.phase = .transcribing
        let s = RecordingSession(root: folder.deletingLastPathComponent(), start: Date(), appName: nil)
        // reuse existing folder: build a session pointing at it
        let fixed = RecordingSessionRef(folder: folder)
        do { try await transcribe(session: fixed.asSession(start: Date())) }
        catch { state.lastError = error.localizedDescription }
        _ = s
        state.phase = .idle
    }

    func refreshRecent() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: settings.outputFolder,
                                                includingPropertiesForKeys: [.creationDateKey]))?
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
        state.recentRecordings = Array(dirs.prefix(5))
    }
}

/// Re-points a session at an existing folder (for retry).
struct RecordingSessionRef {
    let folder: URL
    func asSession(start: Date) -> RecordingSession {
        var s = RecordingSession(root: folder.deletingLastPathComponent(), start: start, appName: nil)
        // RecordingSession derives folder from date; for retry we need the original folder.
        // Add this initializer to RecordingSession instead:
        return s
    }
}
```

**Note to implementer:** delete `RecordingSessionRef` and instead add a second initializer to `RecordingSession` (and use it in `retryTranscription`):

```swift
    init(existingFolder: URL, start: Date) {
        self.folder = existingFolder
        self.start = start
    }
```

`retryTranscription` becomes:

```swift
    func retryTranscription(folder: URL) async {
        state.phase = .transcribing
        do { try await transcribe(session: RecordingSession(existingFolder: folder, start: Date())) }
        catch { state.lastError = error.localizedDescription }
        state.phase = .idle
    }
```

- [ ] **Step 2: Implement `SettingsView.swift`**

```swift
import SwiftUI

struct SettingsView: View {
    @State private var settings = Settings()
    @State private var outputPath: String = ""
    @State private var model: String = ""
    @State private var whisperPath: String = ""
    @State private var cleanup = true
    @State private var autoStop = false
    @State private var autoStopSecs = 30

    var body: some View {
        Form {
            HStack {
                TextField("Output folder", text: $outputPath)
                Button("Choose…") {
                    let p = NSOpenPanel()
                    p.canChooseDirectories = true; p.canChooseFiles = false
                    if p.runModal() == .OK, let url = p.url { outputPath = url.path }
                }
            }
            TextField("Whisper model", text: $model)
            TextField("mlx_whisper path", text: $whisperPath)
            Toggle("Clean transcript with Claude", isOn: $cleanup)
            Toggle("Auto-stop when meeting ends", isOn: $autoStop)
            if autoStop { Stepper("After \(autoStopSecs)s", value: $autoStopSecs, in: 5...120, step: 5) }
            Button("Save") {
                settings.outputFolder = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath)
                settings.whisperModel = model
                settings.mlxWhisperPath = whisperPath
                settings.claudeCleanupEnabled = cleanup
                settings.autoStopSeconds = autoStop ? autoStopSecs : nil
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            outputPath = settings.outputFolder.path
            model = settings.whisperModel
            whisperPath = settings.mlxWhisperPath
            cleanup = settings.claudeCleanupEnabled
            autoStop = settings.autoStopSeconds != nil
            autoStopSecs = settings.autoStopSeconds ?? 30
        }
    }
}
```

- [ ] **Step 3: Rewrite `MeetScribeApp.swift`** with full menu

```swift
import SwiftUI

@main
struct MeetScribeApp: App {
    @StateObject private var state: AppState
    @StateObject private var coordinator: RecordingCoordinator

    init() {
        let s = AppState()
        _state = StateObject(wrappedValue: s)
        _coordinator = StateObject(wrappedValue: RecordingCoordinator(state: s))
    }

    var body: some Scene {
        MenuBarExtra {
            switch state.phase {
            case .idle:
                Button("Start recording") { Task { await coordinator.startRecording() } }
            case .recording(let start):
                Button("Stop recording (\(elapsed(since: start)))") { Task { await coordinator.stopRecording() } }
            case .transcribing:
                Text("Transcribing…")
            }
            if let err = state.lastError {
                Divider()
                Text("Warning: \(err)").font(.caption)
            }
            Divider()
            if !state.recentRecordings.isEmpty {
                Menu("Recent recordings") {
                    ForEach(state.recentRecordings, id: \.self) { url in
                        Button(url.lastPathComponent) { NSWorkspace.shared.open(url) }
                    }
                }
            }
            Button("Open recordings folder") { NSWorkspace.shared.open(Settings().outputFolder) }
            Divider()
            SettingsLink { Text("Settings…") }
            Button("Quit MeetScribe") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Image(systemName: iconName)
        }
        Settings { SettingsView() }
    }

    private var iconName: String {
        switch state.phase {
        case .idle: "waveform"
        case .recording: "record.circle.fill"
        case .transcribing: "hourglass"
        }
    }

    private func elapsed(since start: Date) -> String {
        let s = Int(Date().timeIntervalSince(start))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
```

- [ ] **Step 4: Run all tests**  -  `swift test`  -  Expected: all PASS
- [ ] **Step 5: Build the bundle**  -  `./build.sh && open build/MeetScribe.app`  -  Expected: launches, menu complete
- [ ] **Step 6: Commit**  -  `git commit -am "feat: wire coordinator, full menu, settings window"`

---

### Task 11: End-to-end verification (manual)

- [ ] **Step 1: Permissions.** First run: start a recording from the menu → grant Microphone and Screen Recording when prompted (Screen Recording grant requires relaunching the app).
- [ ] **Step 2: Manual recording.** Record ~30s while playing a YouTube video and speaking. Stop. Verify in the session folder: `mic.m4a`, `system.m4a`, `audio.m4a` all playable; `transcript.md` has header, `[hh:mm:ss]` timestamps, **Me:** lines matching your words and **Them:** lines matching the video.
- [ ] **Step 3: Claude cleanup.** Confirm transcript header says "cleaned by Claude". Toggle it off in Settings, retry transcription, confirm "not cleaned (raw whisper)".
- [ ] **Step 4: Detection.** Start a Slack huddle or Zoom meeting → notification with Record button appears; click Record → recording starts; end the call → stop suggestion appears.
- [ ] **Step 5: Failure path.** Temporarily set a bogus mlx_whisper path in Settings, record 5s → "Transcription failed" notification; audio files intact; fix path, use Retry → transcript produced.
- [ ] **Step 6: Commit any fixes**  -  `git commit -am "fix: end-to-end verification fixes"`

---

## Self-Review Notes

- Spec coverage: recorder (T7), detector (T8), transcriber+formatter (T4/T5), claude cleanup (T6), UI+settings incl. output folder (T10), output layout (T3), error handling (T9/T10/T11), tests (T2 - T5 unit, T11 manual). Auto-stop covered in T10 coordinator.
- Known risk: exact SCK/CoreAudio API names may drift on the macOS 26 SDK; T7/T8 include build-and-fix steps.
- `sw_vers` shows 26.5 but SwiftPM platform uses `.v15` as minimum  -  fine, APIs used exist from macOS 15.
