import ClementineCore
import Foundation
import XCTest

final class ProcessRunnerTests: XCTestCase {
    /// Lots of stdout in many chunks, interleaved with stderr, must come back
    /// complete and in order, without waiting for the drain timeout.
    func testLargeOutputArrivesInOrder() async throws {
        let script = "i=0; while [ $i -lt 4000 ]; do echo \"line $i\"; echo \"err $i\" >&2; i=$((i+1)); done"
        for _ in 0..<5 {
            let start = Date()
            let result = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", script])
            XCTAssertEqual(result.status, 0)
            let lines = result.stdoutString.split(separator: "\n")
            XCTAssertEqual(lines.count, 4000)
            XCTAssertEqual(lines.first, "line 0")
            XCTAssertEqual(lines.last, "line 3999")
            XCTAssertEqual(lines, (0..<4000).map { "line \($0)"[...] })
            XCTAssertTrue(result.stderrString.hasSuffix("err 3999\n"))
            XCTAssertLessThan(Date().timeIntervalSince(start), 2.5, "pipes should drain without hitting the timeout")
        }
    }

    func testLineCallbackSeesEveryLine() async throws {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var lines: [String] = []
        }
        let box = Box()
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "for i in 1 2 3; do echo $i; done; printf tail"]) { line in
            box.lock.lock()
            box.lines.append(line)
            box.lock.unlock()
        }
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(box.lines, ["1", "2", "3", "tail"])
    }
}
