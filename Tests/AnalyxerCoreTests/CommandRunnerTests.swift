import XCTest
@testable import AnalyxerCore

final class CommandRunnerTests: XCTestCase {
    func testArgumentsAreNotEvaluatedByShell() async throws {
        let argument = "literal;$(echo unexpected) `whoami`"
        let result = try await ProcessCommandRunner().run(Command(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s", argument]))
        XCTAssertEqual(result.text, argument)
        XCTAssertEqual(result.status, 0)
    }

    func testDrainsBothPipesAndCapsOutput() async throws {
        // A fixed test fixture intentionally invokes a shell; application commands never do.
        let result = try await ProcessCommandRunner().run(Command(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "i=0; while [ $i -lt 10000 ]; do printf 'abcdefghij'; printf '0123456789' >&2; i=$((i+1)); done"], timeout: 10, outputLimit: 1024))
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.count, 1024)
        XCTAssertEqual(result.stderr.count, 1024)
        XCTAssertTrue(result.truncated)
    }

    func testTimeoutStopsOnlyLaunchedProcess() async {
        let started = Date()
        do {
            _ = try await ProcessCommandRunner().run(Command(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.1))
            XCTFail("Expected timeout")
        } catch AnalyxerError.timedOut {} catch { XCTFail("Wrong error: \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testCancellationStopsCommandPromptly() async throws {
        let task = Task { try await ProcessCommandRunner().run(Command(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"])) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch AnalyxerError.cancelled {} catch { XCTFail("Wrong error: \(error)") }
    }
}
