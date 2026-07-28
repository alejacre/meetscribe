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
    static let ignoreSigpipe: Void = { signal(SIGPIPE, SIG_IGN) }()

    /// Builds a Process with the widened PATH both `run` and `stream` need.
    /// Apps launched from Finder get a minimal PATH; tools like mlx_whisper
    /// shell out to ffmpeg and need Homebrew/user paths visible.
    static func makeProcess(_ executable: String, _ args: [String],
                            environment: [String: String]? = nil) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        var env = environment ?? ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
        env["PATH"] = (extra + [(env["PATH"] ?? "/usr/bin:/bin")]).joined(separator: ":")
        p.environment = env
        return p
    }

    static var restrictedEnvironment: [String: String] {
        var env = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin",
            "TMPDIR": NSTemporaryDirectory(),
            "LANG": "en_US.UTF-8",
        ]
        if let user = ProcessInfo.processInfo.environment["USER"] { env["USER"] = user }
        return env
    }

    static func signalProcessTree(_ process: Process, _ signal: Int32) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        if kill(-pid, signal) != 0 {
            kill(pid, signal)
        }
    }

    @discardableResult
    static func run(_ executable: String, _ args: [String], stdin: String? = nil,
                    timeout: TimeInterval = 1800,
                    environment: [String: String]? = nil) throws -> String {
        _ = ignoreSigpipe
        let p = makeProcess(executable, args, environment: environment)
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
            signalProcessTree(p, SIGTERM)
            if exited.wait(timeout: .now() + 5) == .timedOut {
                signalProcessTree(p, SIGKILL)
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
