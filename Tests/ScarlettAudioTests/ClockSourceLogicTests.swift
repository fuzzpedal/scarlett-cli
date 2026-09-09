import XCTest
@testable import ScarlettAudio

final class ClockSourceLogicTests: XCTestCase {
    // Real IDs and names read from the Scarlett 18i20 on 2026-09-08.
    private let sources = [
        ClockSource(id: 690487296, name: "Internal"),
        ClockSource(id: 707264512, name: "S/PDIF"),
        ClockSource(id: 724041728, name: "ADAT")
    ]

    func test_normalizedClockNameStripsPunctuationAndCase() {
        XCTAssertEqual(normalizedClockName("S/PDIF"), "spdif")
        XCTAssertEqual(normalizedClockName("Internal"), "internal")
        XCTAssertEqual(normalizedClockName("Word Clock"), "wordclock")
    }

    func test_findClockSourceExactName() {
        XCTAssertEqual(
            findClockSource(named: "Internal", in: sources),
            ClockSource(id: 690487296, name: "Internal")
        )
    }

    func test_findClockSourceIgnoresCase() {
        XCTAssertEqual(
            findClockSource(named: "adat", in: sources),
            ClockSource(id: 724041728, name: "ADAT")
        )
    }

    func test_findClockSourceIgnoresPunctuation() {
        XCTAssertEqual(
            findClockSource(named: "spdif", in: sources),
            ClockSource(id: 707264512, name: "S/PDIF")
        )
        XCTAssertEqual(
            findClockSource(named: "S/PDIF", in: sources),
            ClockSource(id: 707264512, name: "S/PDIF")
        )
    }

    func test_findClockSourceUnknownName() {
        XCTAssertNil(findClockSource(named: "wordclock", in: sources))
    }

    func test_findClockSourceEmptyList() {
        XCTAssertNil(findClockSource(named: "internal", in: []))
    }
}
