import XCTest
@testable import ScarlettAudio

final class AudioFormatLogicTests: XCTestCase {
    func test_discreteRatesDeduplicatesAndSorts() {
        let ranges: [(min: Double, max: Double)] = [
            (min: 48000, max: 48000),
            (min: 44100, max: 44100),
            (min: 48000, max: 48000)
        ]
        XCTAssertEqual(discreteRates(fromRanges: ranges), [44100, 48000])
    }

    func test_discreteRatesEmpty() {
        XCTAssertEqual(discreteRates(fromRanges: []), [])
    }

    func test_intersectBitDepthsAcrossStreams() {
        let perStream: [[UInt32]] = [
            [16, 24, 32],
            [24, 32]
        ]
        XCTAssertEqual(intersectBitDepths(perStream: perStream), [24, 32])
    }

    func test_intersectBitDepthsSingleStreamDeduplicates() {
        XCTAssertEqual(intersectBitDepths(perStream: [[24, 16, 24]]), [16, 24])
    }

    func test_intersectBitDepthsEmpty() {
        XCTAssertEqual(intersectBitDepths(perStream: []), [])
    }

    func test_intersectBitDepthsWithNoOverlap() {
        XCTAssertEqual(intersectBitDepths(perStream: [[16], [24]]), [])
    }

    func test_findMatchingFormatFound() {
        let available = [
            RateBitsPair(sampleRate: 44100, bits: 16),
            RateBitsPair(sampleRate: 48000, bits: 24)
        ]
        XCTAssertEqual(
            findMatchingFormat(in: available, sampleRate: 48000, bits: 24),
            RateBitsPair(sampleRate: 48000, bits: 24)
        )
    }

    func test_findMatchingFormatToleratesFloatingPointDrift() {
        let available = [RateBitsPair(sampleRate: 48000.2, bits: 24)]
        XCTAssertEqual(
            findMatchingFormat(in: available, sampleRate: 48000, bits: 24),
            RateBitsPair(sampleRate: 48000.2, bits: 24)
        )
    }

    func test_findMatchingFormatRejectsWrongBitDepth() {
        let available = [RateBitsPair(sampleRate: 48000, bits: 16)]
        XCTAssertNil(findMatchingFormat(in: available, sampleRate: 48000, bits: 24))
    }

    func test_findMatchingFormatRejectsWrongRate() {
        let available = [RateBitsPair(sampleRate: 44100, bits: 24)]
        XCTAssertNil(findMatchingFormat(in: available, sampleRate: 48000, bits: 24))
    }

    func test_valuesMatchWithinTolerance() {
        XCTAssertTrue(valuesMatch(requested: 48000, actual: 48000.3))
    }

    func test_valuesMatchOutsideTolerance() {
        XCTAssertFalse(valuesMatch(requested: 48000, actual: 48001))
    }
}
