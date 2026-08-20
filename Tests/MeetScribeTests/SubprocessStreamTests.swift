import XCTest
@testable import MeetScribe

final class SubprocessStreamTests: XCTestCase {
    func testYieldsChunksAndCompletes() async throws {
        var out = ""
        for try await chunk in Subprocess.stream("/bin/sh", ["-c", "echo a; echo b"]) {
            out += chunk
        }
        XCTAssertTrue(out.contains("a"))
        XCTAssertTrue(out.contains("b"))
    }

    func testMergesStderr() async throws {
        var out = ""
        for try await chunk in Subprocess.stream("/bin/sh", ["-c", "echo err 1>&2"]) {
            out += chunk
        }
        XCTAssertTrue(out.contains("err"))
    }

    func testNonZeroExitThrows() async {
        do {
            for try await _ in Subprocess.stream("/bin/sh", ["-c", "exit 3"]) {}
            XCTFail("expected throw")
        } catch let SubprocessError.nonZeroExit(code, _) {
            XCTAssertEqual(code, 3)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testCancellationKillsChildQuickly() async {
        let start = Date()
        let task = Task {
            for try await _ in Subprocess.stream("/bin/sleep", ["60"]) {}
        }
        // Give it a moment to spawn, then cancel.
        try? await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        _ = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "child should die well before 60s")
    }

    func testTimeoutReportsTimeoutAndKillsTermIgnoringChild() async {
        let start = Date()
        do {
            for try await _ in Subprocess.stream(
                "/bin/sh",
                ["-c", "trap '' TERM; echo ready; sleep 30"],
                timeout: 0.2,
                terminationGracePeriod: 0.2) {}
            XCTFail("expected timeout")
        } catch let SubprocessError.timeout(value) {
            XCTAssertEqual(value, 0.2)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testParentExitDoesNotWaitForDescendantHoldingPipe() async throws {
        let started = Date()
        var output = ""

        for try await chunk in Subprocess.stream(
            "/bin/sh",
            ["-c", "(sleep 5) & echo done"],
            timeout: 10)
        {
            output += chunk
        }

        XCTAssertTrue(output.contains("done"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
}
