import Foundation

struct RateBitsPair: Equatable {
    let sampleRate: Double
    let bits: UInt32
}

/// Core Audio reports each supported discrete rate as a range whose
/// minimum and maximum are equal, so the minimum is the rate itself.
func discreteRates(fromRanges ranges: [(min: Double, max: Double)]) -> [Double] {
    Set(ranges.map { $0.min }).sorted()
}

func intersectBitDepths(perStream streamBitDepths: [[UInt32]]) -> [UInt32] {
    guard let first = streamBitDepths.first else { return [] }
    var shared = Set(first)
    for depths in streamBitDepths.dropFirst() {
        shared.formIntersection(depths)
    }
    return shared.sorted()
}

func findMatchingFormat(
    in available: [RateBitsPair],
    sampleRate: Double,
    bits: UInt32
) -> RateBitsPair? {
    available.first {
        $0.bits == bits && valuesMatch(requested: sampleRate, actual: $0.sampleRate)
    }
}

func valuesMatch(requested: Double, actual: Double, tolerance: Double = 0.5) -> Bool {
    abs(requested - actual) <= tolerance
}
