import Foundation

extension Subprocess {
    /// Runs a command and yields merged stdout+stderr as text chunks the moment they
    /// arrive, for live progress UIs. uv's installer and mlx_whisper/HuggingFace both
    /// write progress to stderr, so the two streams are merged into one ordered feed.
    ///
    /// Finishes normally on exit 0; otherwise finishes by throwing
    /// `SubprocessError.nonZeroExit` (carrying the tail of the output) or
    /// `SubprocessError.timeout`. Cancelling the consuming Task (e.g. closing the
    /// wizard window) terminates the child: SIGTERM, then SIGKILL after 5s.
    static func stream(_ executable: String, _ args: [String],
                       timeout: TimeInterval = 3600,
                       terminationGracePeriod: TimeInterval = 5) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            _ = ignoreSigpipe
            let p = makeProcess(executable, args)
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe

            // Keep the last ~4KB so a non-zero exit can report meaningful context,
            // mirroring the synchronous run()'s stderr surfacing.
            let tail = Tail()
            let completion = StreamCompletion()
            let handle = pipe.fileHandleForReading
            handle.readabilityHandler = { h in
                let chunk = h.availableData
                guard !chunk.isEmpty else { h.readabilityHandler = nil; return }
                let text = String(decoding: chunk, as: UTF8.self)
                tail.append(text)
                continuation.yield(text)
            }

            p.terminationHandler = { proc in
                handle.readabilityHandler = nil
                let finalData = handle.readDataToEndOfFile()
                if !finalData.isEmpty {
                    let text = String(decoding: finalData, as: UTF8.self)
                    tail.append(text)
                    continuation.yield(text)
                }
                if completion.timedOut {
                    continuation.finish(throwing: SubprocessError.timeout(timeout))
                } else if proc.terminationStatus == 0 {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: SubprocessError.nonZeroExit(
                        proc.terminationStatus, stderr: tail.contents))
                }
            }

            continuation.onTermination = { reason in
                if case .cancelled = reason, p.isRunning {
                    signalProcessTree(p, SIGTERM)
                    DispatchQueue.global().asyncAfter(deadline: .now() + terminationGracePeriod) {
                        signalProcessTree(p, SIGKILL)
                    }
                }
            }

            do { try p.run() }
            catch { continuation.finish(throwing: error); return }

            // Timeout watchdog: terminate the child; terminationHandler then finishes
            // the stream. Only fires if the process outlives the budget.
            if timeout.isFinite {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard p.isRunning else { return }
                    completion.markTimedOut()
                    signalProcessTree(p, SIGTERM)
                    DispatchQueue.global().asyncAfter(deadline: .now() + terminationGracePeriod) {
                        signalProcessTree(p, SIGKILL)
                    }
                }
            }
        }
    }

    /// Thread-safe bounded ring of the most recent output for error reporting.
    private final class Tail: @unchecked Sendable {
        private var buf = ""
        private let lock = NSLock()
        private let limit = 4096
        func append(_ s: String) {
            lock.lock(); defer { lock.unlock() }
            buf += s
            if buf.count > limit { buf = String(buf.suffix(limit)) }
        }
        var contents: String { lock.lock(); defer { lock.unlock() }; return buf }
    }

    private final class StreamCompletion: @unchecked Sendable {
        private var didTimeOut = false
        private let lock = NSLock()

        func markTimedOut() {
            lock.lock()
            didTimeOut = true
            lock.unlock()
        }

        var timedOut: Bool {
            lock.lock()
            defer { lock.unlock() }
            return didTimeOut
        }
    }
}
