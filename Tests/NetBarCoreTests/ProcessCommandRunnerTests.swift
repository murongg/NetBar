import XCTest
@testable import NetBarCore

final class ProcessCommandRunnerTests: XCTestCase {
    func testThrowsTimeoutWhenCommandDoesNotExitInTime() {
        let runner = ProcessCommandRunner(timeout: 0.1)

        XCTAssertThrowsError(try runner.run(executablePath: "/bin/sleep", arguments: ["2"])) { error in
            XCTAssertEqual(error as? CommandRunnerError, .timedOut)
        }
    }
}
