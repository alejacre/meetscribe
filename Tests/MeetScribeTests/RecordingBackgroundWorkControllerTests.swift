import XCTest
@testable import MeetScribe

@MainActor
final class RecordingBackgroundWorkControllerTests: XCTestCase {
    func testDuplicateTranscriptionIsCoalescedAndCompletionRefreshes() async throws {
        let root = try temporaryDirectory("background-coalesce")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try populatedSession(root: root)
        let blocker = BlockingTranscription(result: RecordingTranscriptionResult(
            finalSession: session,
            processingWarning: nil,
            processorID: nil))
        let state = AppState()
        let notifier = Notifier()
        notifier.isEnabled = false
        let controller = RecordingBackgroundWorkController(
            state: state,
            notifier: notifier,
            transcriptionRunner: blocker.runner,
            publicationRunner: .init { _, _ in [] })
        var refreshCount = 0
        controller.onRecordingsChanged = { refreshCount += 1 }
        let configuration = RecordingTranscriptionConfiguration(
            mlxWhisperPath: "/unused",
            whisperModel: "test/model",
            agentConfiguration: .disabled)

        controller.transcribe(
            session: session,
            configuration: configuration,
            destinationConfiguration: DestinationConfiguration())
        controller.transcribe(
            session: session,
            configuration: configuration,
            destinationConfiguration: DestinationConfiguration())

        try await waitUntil { blocker.callCount == 1 }
        XCTAssertEqual(state.transcribingCount, 1)
        XCTAssertTrue(controller.isWorking(on: session.assetDir))
        blocker.release()
        try await waitUntil { state.transcribingCount == 0 }
        XCTAssertEqual(refreshCount, 1)
        XCTAssertFalse(controller.isWorking(on: session.assetDir))
    }

    func testTranscriptionFailureReportsManifestPersistenceFailure() async throws {
        let root = try temporaryDirectory("background-manifest-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try populatedSession(root: root)
        try Data("not json".utf8).write(
            to: session.manifestURL,
            options: .atomic)
        let state = AppState()
        let notifier = Notifier()
        notifier.isEnabled = false
        let controller = RecordingBackgroundWorkController(
            state: state,
            notifier: notifier,
            transcriptionRunner: .init { _, _ in throw TestError.transcription },
            publicationRunner: .init { _, _ in [] })

        controller.transcribe(
            session: session,
            configuration: .init(
                mlxWhisperPath: "/unused",
                whisperModel: "test/model",
                agentConfiguration: .disabled),
            destinationConfiguration: DestinationConfiguration())

        try await waitUntil { state.transcribingCount == 0 }
        XCTAssertTrue(state.lastError?.contains("transcription failed") == true)
        XCTAssertTrue(
            state.lastError?.contains(
                "Recovery state could not be saved") == true)
    }

    func testSuccessfulTranscriptionStartsConfiguredPublication() async throws {
        let root = try temporaryDirectory("background-publication")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try populatedSession(root: root)
        let publication = LockedCounter()
        let state = AppState()
        let notifier = Notifier()
        notifier.isEnabled = false
        let controller = RecordingBackgroundWorkController(
            state: state,
            notifier: notifier,
            transcriptionRunner: .init { _, _ in
                RecordingTranscriptionResult(
                    finalSession: session,
                    processingWarning: nil,
                    processorID: "test-agent")
            },
            publicationRunner: .init { _, _ in
                publication.increment()
                return [PublicationResult(
                    destinationID: "test",
                    errorDescription: nil)]
            })
        var destinations = DestinationConfiguration()
        destinations.sftp.enabled = true

        controller.transcribe(
            session: session,
            configuration: .init(
                mlxWhisperPath: "/unused",
                whisperModel: "test/model",
                agentConfiguration: .disabled),
            destinationConfiguration: destinations)

        try await waitUntil {
            state.transcribingCount == 0
                && state.publishingCount == 0
                && publication.value == 1
        }
        XCTAssertNil(state.lastError)
    }

    func testPublicationFailureSetsWarningAndClearErrorRemovesIt() async throws {
        let root = try temporaryDirectory("background-publication-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try populatedSession(root: root)
        let state = AppState()
        let notifier = Notifier()
        notifier.isEnabled = false
        let controller = RecordingBackgroundWorkController(
            state: state,
            notifier: notifier,
            transcriptionRunner: .init { _, _ in
                throw TestError.transcription
            },
            publicationRunner: .init { _, _ in
                [PublicationResult(
                    destinationID: "archive",
                    errorDescription: "offline")]
            })
        var destinations = DestinationConfiguration()
        destinations.sftp.enabled = true

        controller.publish(session: session, configuration: destinations)

        try await waitUntil { state.publishingCount == 0 }
        XCTAssertEqual(
            state.lastError,
            "Publishing failed: archive: offline")
        controller.clearError()
        XCTAssertNil(state.lastError)
    }

    private func populatedSession(root: URL) throws -> RecordingSession {
        let session = RecordingSession(
            root: root,
            start: Date(),
            appName: "zoom")
        try session.createFolder()
        try Data("# Transcript\n".utf8).write(to: session.noteURL)
        return session
    }

    private func temporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "meetscribe-\(label)-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true)
        return url
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "condition was not met before timeout")
    }

    private enum TestError: Error, LocalizedError {
        case transcription

        var errorDescription: String? {
            "transcription failed"
        }
    }

    private final class BlockingTranscription: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private let result: RecordingTranscriptionResult
        private var calls = 0

        init(result: RecordingTranscriptionResult) {
            self.result = result
        }

        var runner: RecordingTranscriptionRunner {
            RecordingTranscriptionRunner { [self] _, _ in
                lock.withLock { calls += 1 }
                semaphore.wait()
                return result
            }
        }

        var callCount: Int {
            lock.withLock { calls }
        }

        func release() {
            semaphore.signal()
        }
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.withLock { count += 1 }
        }

        var value: Int {
            lock.withLock { count }
        }
    }
}
