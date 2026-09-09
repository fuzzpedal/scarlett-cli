import Foundation

struct ClockSource: Equatable {
    let id: UInt32
    let name: String
}

/// Clock source IDs are hardware-assigned rather than stable constants, so
/// sources are always matched by name against the live device list. Names are
/// reduced to lowercase alphanumerics so "S/PDIF", "spdif" and "SPDIF" match.
func normalizedClockName(_ name: String) -> String {
    name.lowercased().filter { $0.isLetter || $0.isNumber }
}

func findClockSource(named query: String, in sources: [ClockSource]) -> ClockSource? {
    let target = normalizedClockName(query)
    return sources.first { normalizedClockName($0.name) == target }
}
