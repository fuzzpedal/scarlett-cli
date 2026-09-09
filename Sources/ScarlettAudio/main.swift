import CoreAudio
import Foundation

let deviceNameQuery = "Scarlett 18i20"

func printError(_ message: String) {
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
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
}

func runSetRate(_ requestedRate: Double) throws {
    let deviceID = try findDevice(nameContains: deviceNameQuery)
    try setNominalSampleRate(deviceID, to: requestedRate)

    let actual = try pollUntilMatches(
        read: { try nominalSampleRate(deviceID) },
        matches: { valuesMatch(requested: requestedRate, actual: $0) }
    )

    guard valuesMatch(requested: requestedRate, actual: actual) else {
        print("❌ Sample rate is \(actual) Hz, expected \(requestedRate) Hz")
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

    for (stream, format) in resolved {
        try setPhysicalFormat(stream, to: format)
    }

    for stream in streams {
        let actual = try pollUntilMatches(
            read: { try physicalFormat(stream).mBitsPerChannel },
            matches: { $0 == requestedBits }
        )

        guard actual == requestedBits else {
            print("❌ Bit depth is \(actual) bits, expected \(requestedBits) bits")
            exit(1)
        }
    }
    print("✅ Bit depth is now \(requestedBits) bits")
}

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
    case .set:
        printError("Command not implemented yet")
        exit(1)
    }
} catch let error as HALError {
    printError(error.description)
    exit(1)
} catch {
    printError("\(error)")
    exit(1)
}
