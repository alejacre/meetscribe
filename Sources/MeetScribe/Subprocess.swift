import Foundation

enum SubprocessError: Error, LocalizedError {
    case nonZeroExit(Int32, stderr: String)
    case timeout(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .nonZeroExit(let code, let stderr):
            return "exit \(code): \(stderr.prefix(200))"
        case .timeout(let t):
            return "timed out after \(Int(t))s"
        }
    }
}

/// Accumulates a pipe's output via readabilityHandler so both stdout and stderr
/// drain concurrently  -  sequential readDataToEndOfFile deadlocks when the child
/// fills the other pipe's 64KB kernel buffer.
private final class PipeBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    let done = DispatchGroup()

    init(_ handle: FileHandle) {
        done.enter()
        handle.readabilityHandler = { [self] h in
            let chunk = h.availableData
            if chunk.isEmpty {
                h.readabilityHandler = nil
                done.leave()
            } else {
                lock.lock(); data.append(chunk); lock.unlock()
            }
        }
    }

    var contents: Data { lock.lock(); defer { lock.unlock() }; return data }
}

enum Subprocess {
    /// Writing stdin to a child that already exited raises SIGPIPE, which kills the
    /// whole app; ignore it once so the write surfaces as a catchable error instead.
    private static let ignoreSigpipe: Void = { signal(SIGPIPE, SIG_IGN) }()

    @discardableResult
    static func run(_ executable: String, _ args: [String], stdin: String? = nil,
                    timeout: TimeInterval = 1800) throws -> String {
        _ = ignoreSigpipe
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        // Apps launched from Finder get a minimal PATH; tools like mlx_whisper
        // shell out to ffmpeg and need Homebrew/user paths visible.
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
        env["PATH"] = (extra + [(env["PATH"] ?? "/usr/bin:/bin")]).joined(separator: ":")
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let outBuf = PipeBuffer(out.fileHandleForReading)
        let errBuf = PipeBuffer(err.fileHandleForReading)
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        let inPipe: Pipe? = stdin != nil ? Pipe() : nil
        if let inPipe { p.standardInput = inPipe }
        try p.run()
        if let inPipe, let stdin {
            // try? on purpose: the child may exit before consuming stdin (EPIPE);
            // the nonZeroExit check below reports the real failure.
            try? inPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            if exited.wait(timeout: .now() + 5) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                exited.wait()
            }
            throw SubprocessError.timeout(timeout)
        }
        outBuf.done.wait()
        errBuf.done.wait()
        guard p.terminationStatus == 0 else {
            throw SubprocessError.nonZeroExit(p.terminationStatus,
                stderr: String(data: errBuf.contents, encoding: .utf8) ?? "")
        }
        return String(data: outBuf.contents, encoding: .utf8) ?? ""
    }
}
