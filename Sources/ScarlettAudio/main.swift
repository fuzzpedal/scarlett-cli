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
    case .setBits, .set:
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
