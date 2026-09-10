import CoreAudio
import Foundation

let deviceNameQuery = "Scarlett 18i20"

func printError(_ message: String) {
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
}

/// Like `printError`, but without the "Error: " prefix — for messages (like
/// the "❌ ..." readback-mismatch lines) whose wording already stands on its
/// own. Still writes to stderr so failures are visible even when stdout is
/// redirected.
func printStderr(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

func allStreamIDs(_ deviceID: AudioObjectID) throws -> [AudioObjectID] {
    let inputs = try streamIDs(deviceID, scope: kAudioObjectPropertyScopeInput)
    let outputs = try streamIDs(deviceID, scope: kAudioObjectPropertyScopeOutput)
    let streams = inputs + outputs
    guard !streams.isEmpty else {
        throw HALError.noStreams(try deviceName(deviceID))
    }
    return streams
}

func runStatus() throws {
    let deviceID = try findDevice(nameContains: deviceNameQuery)
    let name = try deviceName(deviceID)
    let currentRate = try nominalSampleRate(deviceID)
    let rates = try availableSampleRates(deviceID)

    let streams = try allStreamIDs(deviceID)
    let currentBits = try physicalFormat(streams[0]).mBitsPerChannel
    let bitDepths = intersectBitDepths(
        perStream: try streams.map { stream in
            try availablePhysicalFormats(stream).map { $0.mBitsPerChannel }
        }
    )

    print("Device: \(name)")
    print("Sample rate: \(currentRate) Hz")
    print("  available: \(rates.map { String($0) }.joined(separator: ", "))")
    print("Bit depth: \(currentBits) bits")
    print("  available: \(bitDepths.map { String($0) }.joined(separator: ", "))")

    let sources = try clockSources(deviceID)
    let currentSourceID = try currentClockSource(deviceID)
    let currentSourceName = sources.first { $0.id == currentSourceID }?.name
        ?? "id \(currentSourceID)"

    print("Clock source: \(currentSourceName)")
    print("  available: \(sources.map { $0.name }.joined(separator: ", "))")
}

func runSetRate(_ requestedRate: Double) throws {
    let deviceID = try findDevice(nameContains: deviceNameQuery)

    let rates = try availableSampleRates(deviceID)
    guard rates.contains(where: { valuesMatch(requested: requestedRate, actual: $0) }) else {
        let available = rates.map { String($0) }.joined(separator: ", ")
        printError("Unknown sample rate \(requestedRate) Hz. Available: \(available)")
        exit(1)
    }

    try setNominalSampleRate(deviceID, to: requestedRate)

    let actual = try pollUntilMatches(
        read: { try nominalSampleRate(deviceID) },
        matches: { valuesMatch(requested: requestedRate, actual: $0) }
    )

    guard valuesMatch(requested: requestedRate, actual: actual) else {
        printStderr("❌ Sample rate is \(actual) Hz, expected \(requestedRate) Hz")
        exit(1)
    }
    print("✅ Sample rate is now \(actual) Hz")
}

func runSetBits(_ requestedBits: UInt32) throws {
    let deviceID = try findDevice(nameContains: deviceNameQuery)
    let currentRate = try nominalSampleRate(deviceID)
    let streams = try allStreamIDs(deviceID)

    // Resolve-before-apply: look up the target format for every stream first
    // and only start writing once every stream is known to support the
    // request. This way a stream that cannot satisfy the request aborts the
    // whole operation before any stream has been mutated, instead of leaving
    // some streams on the new format and others on the old one.
    var resolved: [(stream: AudioObjectID, format: AudioStreamBasicDescription)] = []
    for stream in streams {
        let formats = try availablePhysicalFormats(stream)
        let pairs = formats.map {
            RateBitsPair(sampleRate: $0.mSampleRate, bits: $0.mBitsPerChannel)
        }
        guard
            let match = findMatchingFormat(in: pairs, sampleRate: currentRate, bits: requestedBits),
            let format = formats.first(where: {
                $0.mBitsPerChannel == match.bits
                    && valuesMatch(requested: match.sampleRate, actual: $0.mSampleRate)
            })
        else {
            throw HALError.formatNotAvailable(rate: currentRate, bits: requestedBits)
        }
        resolved.append((stream, format))
    }

    do {
        for (stream, format) in resolved {
            try setPhysicalFormat(stream, to: format)
        }
    } catch {
        printStderr(
            "❌ Failed partway through applying the bit depth change: \(error). "
                + "Streams may now be inconsistent with each other — run `status` to check."
        )
        exit(1)
    }

    for stream in streams {
        let actual = try pollUntilMatches(
            read: { try physicalFormat(stream).mBitsPerChannel },
            matches: { $0 == requestedBits }
        )

        guard actual == requestedBits else {
            printStderr("❌ Bit depth is \(actual) bits, expected \(requestedBits) bits")
            exit(1)
        }
    }
    print("✅ Bit depth is now \(requestedBits) bits")
}

func runSetClock(_ requestedName: String) throws {
    let deviceID = try findDevice(nameContains: deviceNameQuery)
    let sources = try clockSources(deviceID)

    guard let requested = findClockSource(named: requestedName, in: sources) else {
        let available = sources.map { $0.name }.joined(separator: ", ")
        printError("Unknown clock source \"\(requestedName)\". Available: \(available)")
        exit(1)
    }

    // Core Audio rejects a write that sets the clock source to the value it
    // already holds, failing with kAudioHardwareUnspecifiedError. So before
    // writing, read the current source from the device (this is the same
    // readback the "changed" path relies on, just performed up front) and
    // skip the write entirely when it already matches the request. Do not
    // "simplify" this away — re-asserting an already-selected clock is a
    // routine no-op for callers and must succeed, not surface a spurious
    // hardware error.
    let existing = try currentClockSource(deviceID)
    if existing != requested.id {
        try setClockSource(deviceID, to: requested.id)

        let actual = try pollUntilMatches(
            read: { try currentClockSource(deviceID) },
            matches: { $0 == requested.id }
        )

        guard actual == requested.id else {
            let actualName = (try? clockSourceName(deviceID, sourceID: actual)) ?? "id \(actual)"
            printStderr("❌ Clock source is \(actualName), expected \(requested.name)")
            exit(1)
        }
    }
    print("✅ Clock source is now \(requested.name)")

    if normalizedClockName(requested.name) != "internal" {
        print("""
            ⚠️  \(requested.name) is an external clock. Core Audio confirms the \
            selection but cannot report lock status: the interface stays locked \
            only while a valid \(requested.name) signal is present, and the sample \
            rate now follows that signal.
            """)
    }
}

// Line-buffer stdout so ✅/❌ output interleaves correctly with stderr when
// stdout is redirected to a pipe or file (where it would otherwise be
// fully block-buffered, delaying output relative to unbuffered stderr).
setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())

let command: Command
switch parseArguments(arguments) {
case .success(let parsed):
    command = parsed
case .failure(let error):
    printError(error.description)
    printError(usageText)
    exit(1)
}

do {
    switch command {
    case .status:
        try runStatus()
    case .setRate(let rate):
        try runSetRate(rate)
    case .setBits(let bits):
        try runSetBits(bits)
    case .setClock(let source, _):
        try runSetClock(source)
    case .save:
        break
    case .set(let rate, let bits):
        try runSetRate(rate)
        try runSetBits(bits)
    }
} catch let error as HALError {
    printError(error.description)
    exit(1)
} catch {
    printError("\(error)")
    exit(1)
}
