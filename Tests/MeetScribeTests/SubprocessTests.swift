import XCTest
@testable import MeetScribe

final class SubprocessTests: XCTestCase {
    func testCapturesStdout() throws {
        let out = try Subprocess.run("/bin/echo", ["hello"])
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    func testNonZeroExitThrowsWithStderr() {
        XCTAssertThrowsError(try Subprocess.run("/bin/sh", ["-c", "echo boom >&2; exit 3"])) { error in
            guard case SubprocessError.nonZeroExit(let code, let stderr) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(code, 3)
            XCTAssertTrue(stderr.contains("boom"))
        }
    }

    func testLargeStderrDoesNotDeadlock() throws {
        // >64KB on stderr while stdout stays open used to deadlock the
        // sequential read; both pipes must drain concurrently.
        let out = try Subprocess.run("/bin/sh",
            ["-c", "yes error-line | head -c 200000 >&2; echo done"], timeout: 30)
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "done")
    }

    func testTimeoutTerminatesChild() {
        let started = Date()
        XCTAssertThrowsError(try Subprocess.run("/bin/sleep", ["60"], timeout: 1)) { error in
            guard case SubprocessError.timeout = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
    }

    func testStdinToEarlyExitingChildDoesNotCrash() throws {
        // Child exits without reading stdin; the EPIPE write must not kill us.
        let big = String(repeating: "x", count: 1_000_000)
        _ = try? Subprocess.run("/usr/bin/true", [], stdin: big, timeout: 30)
    }

    func testStdinIsDelivered() throws {
        let out = try Subprocess.run("/bin/cat", [], stdin: "piped input")
        XCTAssertEqual(out, "piped input")
    }
}
