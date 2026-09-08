import XCTest
@testable import ScarlettAudio

final class CLITests: XCTestCase {
    func test_statusCommand() {
        assertSuccess(parseArguments(["status"]), equals: .status)
    }

    func test_setRateCommand() {
        assertSuccess(parseArguments(["set-rate", "48000"]), equals: .setRate(48000))
    }

    func test_setRateMissingArgument() {
        assertFailure(parseArguments(["set-rate"]), equals: .missingArgument("<hz>"))
    }

    func test_setRateInvalidNumber() {
        assertFailure(parseArguments(["set-rate", "fast"]), equals: .invalidNumber("fast"))
    }

    func test_setBitsCommand() {
        assertSuccess(parseArguments(["set-bits", "24"]), equals: .setBits(24))
    }

    func test_setBitsMissingArgument() {
        assertFailure(parseArguments(["set-bits"]), equals: .missingArgument("<bits>"))
    }

    func test_setBitsInvalidNumber() {
        assertFailure(parseArguments(["set-bits", "deep"]), equals: .invalidNumber("deep"))
    }

    func test_setCommand() {
        assertSuccess(
            parseArguments(["set", "--rate", "96000", "--bits", "24"]),
            equals: .set(rate: 96000, bits: 24)
        )
    }

    func test_setCommandAcceptsFlagsInAnyOrder() {
        assertSuccess(
            parseArguments(["set", "--bits", "24", "--rate", "96000"]),
            equals: .set(rate: 96000, bits: 24)
        )
    }

    func test_setCommandMissingBitsFlag() {
        assertFailure(
            parseArguments(["set", "--rate", "96000"]),
            equals: .missingArgument("--bits <bits>")
        )
    }

    func test_setCommandMissingRateFlag() {
        assertFailure(
            parseArguments(["set", "--bits", "24"]),
            equals: .missingArgument("--rate <hz>")
        )
    }

    func test_unknownCommand() {
        assertFailure(parseArguments(["nonsense"]), equals: .unknownCommand("nonsense"))
    }

    func test_noArguments() {
        assertFailure(parseArguments([]), equals: .unknownCommand(""))
    }

    private func assertSuccess(
        _ result: Result<Command, CLIError>,
        equals expected: Command,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success(let command):
            XCTAssertEqual(command, expected, file: file, line: line)
        case .failure(let error):
            XCTFail("Expected success but got error: \(error)", file: file, line: line)
        }
    }

    private func assertFailure(
        _ result: Result<Command, CLIError>,
        equals expected: CLIError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success(let command):
            XCTFail("Expected failure but got command: \(command)", file: file, line: line)
        case .failure(let error):
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }
}
