# Scarlett Audio CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS command-line tool that reads and sets the sample rate, bit depth, and clock source of a Focusrite Scarlett 18i20, verifying after every change that the hardware actually applied it.

**Architecture:** A Swift Package Manager executable. Pure, unit-tested logic (argument parsing, rate/bit-depth list math, tolerance comparison) is separated from thin Core Audio HAL wrappers that do the actual `AudioObjectGetPropertyData`/`AudioObjectSetPropertyData` I/O. `main.swift` only parses, dispatches, and formats output.

**Tech Stack:** Swift 5.9 tools version (Swift 5 language mode), SwiftPM, CoreAudio + AudioToolbox system frameworks, XCTest. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-09-08-scarlett-audio-cli-design.md`

## Global Constraints

- Platform: macOS only. `platforms: [.macOS(.v12)]`.
- No third-party dependencies. Argument parsing is hand-written.
- Package name `scarlett-audio`; executable **product** name `scarlett-audio`; **target/module** name `ScarlettAudio` (Swift module names cannot contain hyphens — the product/target split is what gives a hyphenated binary and an importable module).
- `// swift-tools-version:5.9` — keeps the Swift 5 language mode under the installed Swift 6.2 compiler, avoiding strict-concurrency errors on top-level code.
- Device is matched by case-insensitive substring `"Scarlett 18i20"`.
- Release binary path after `swift build -c release`: `.build/release/scarlett-audio`.
- Every `set-*` operation must re-read the property and exit non-zero if the readback does not match the request.
- Clock source IDs are hardware-assigned, not stable constants. Always resolve a source by name against the live device list; never hard-code an ID in shipped code (the IDs in test fixtures are fine — they are just data).
- Hardware state: the interface is connected, currently runs at 48000 Hz, is clocked Internal, and is the machine's **default output device** — so a manual step that switches it to an external clock can interrupt system audio until Internal is restored.
- Tasks 1–6 build sample rate and bit depth; Tasks 7–8 add clock source. The tool is complete and usable after Task 6.

---

### Task 1: Package scaffold and CLI argument parser

**Files:**
- Create: `Package.swift`
- Create: `Sources/ScarlettAudio/CLI.swift`
- Create: `Sources/ScarlettAudio/main.swift`
- Create: `Tests/ScarlettAudioTests/CLITests.swift`
- Create: `.gitignore`

**Interfaces:**
- Consumes: nothing (first task).
- Produces:
  - `enum Command: Equatable { case status; case setRate(Double); case setBits(UInt32); case set(rate: Double, bits: UInt32) }`
  - `enum CLIError: Error, Equatable, CustomStringConvertible { case unknownCommand(String); case missingArgument(String); case invalidNumber(String) }`
  - `func parseArguments(_ args: [String]) -> Result<Command, CLIError>`

- [ ] **Step 1: Create the package manifest**

Create `Package.swift`:

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "scarlett-audio",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "scarlett-audio", targets: ["ScarlettAudio"])
    ],
    targets: [
        .executableTarget(
            name: "ScarlettAudio",
            path: "Sources/ScarlettAudio",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox")
            ]
        ),
        .testTarget(
            name: "ScarlettAudioTests",
            dependencies: ["ScarlettAudio"],
            path: "Tests/ScarlettAudioTests"
        )
    ]
)
```

Create `.gitignore`:

```
.build/
.swiftpm/
*.xcodeproj
.DS_Store
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/ScarlettAudioTests/CLITests.swift`:

```swift
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
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test`
Expected: FAIL — compile errors, `cannot find 'parseArguments' in scope` (and no `Sources/ScarlettAudio` sources yet).

- [ ] **Step 4: Write the argument parser**

Create `Sources/ScarlettAudio/CLI.swift`:

```swift
import Foundation

enum Command: Equatable {
    case status
    case setRate(Double)
    case setBits(UInt32)
    case set(rate: Double, bits: UInt32)
}

enum CLIError: Error, Equatable, CustomStringConvertible {
    case unknownCommand(String)
    case missingArgument(String)
    case invalidNumber(String)

    var description: String {
        switch self {
        case .unknownCommand(let name):
            return "Unknown command \"\(name)\". Expected one of: status, set-rate, set-bits, set"
        case .missingArgument(let name):
            return "Missing required argument: \(name)"
        case .invalidNumber(let value):
            return "Expected a number but got \"\(value)\""
        }
    }
}

let usageText = """
Usage:
  scarlett-audio status
  scarlett-audio set-rate <hz>
  scarlett-audio set-bits <bits>
  scarlett-audio set --rate <hz> --bits <bits>
"""

func parseArguments(_ args: [String]) -> Result<Command, CLIError> {
    guard let commandName = args.first else {
        return .failure(.unknownCommand(""))
    }
    let rest = Array(args.dropFirst())

    switch commandName {
    case "status":
        return .success(.status)

    case "set-rate":
        guard let rateString = rest.first else {
            return .failure(.missingArgument("<hz>"))
        }
        guard let rate = Double(rateString) else {
            return .failure(.invalidNumber(rateString))
        }
        return .success(.setRate(rate))

    case "set-bits":
        guard let bitsString = rest.first else {
            return .failure(.missingArgument("<bits>"))
        }
        guard let bits = UInt32(bitsString) else {
            return .failure(.invalidNumber(bitsString))
        }
        return .success(.setBits(bits))

    case "set":
        guard let rateString = flagValue(named: "--rate", in: rest) else {
            return .failure(.missingArgument("--rate <hz>"))
        }
        guard let bitsString = flagValue(named: "--bits", in: rest) else {
            return .failure(.missingArgument("--bits <bits>"))
        }
        guard let rate = Double(rateString) else {
            return .failure(.invalidNumber(rateString))
        }
        guard let bits = UInt32(bitsString) else {
            return .failure(.invalidNumber(bitsString))
        }
        return .success(.set(rate: rate, bits: bits))

    default:
        return .failure(.unknownCommand(commandName))
    }
}

private func flagValue(named flag: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: flag), index + 1 < args.count else {
        return nil
    }
    return args[index + 1]
}
```

- [ ] **Step 5: Write the entry point**

Create `Sources/ScarlettAudio/main.swift`:

```swift
import Foundation

func printError(_ message: String) {
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
}

let arguments = Array(CommandLine.arguments.dropFirst())

switch parseArguments(arguments) {
case .success(let command):
    print("Parsed command: \(command)")
case .failure(let error):
    printError(error.description)
    printError(usageText)
    exit(1)
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test`
Expected: PASS — 13 tests in `CLITests`, no failures.

- [ ] **Step 7: Verify the binary builds and parses**

Run: `swift run scarlett-audio set --rate 96000 --bits 24`
Expected: prints `Parsed command: set(rate: 96000.0, bits: 24)`

Run: `swift run scarlett-audio bogus`
Expected: prints the unknown-command error and usage to stderr, exit code 1. Check with `echo $?` → `1`.

- [ ] **Step 8: Commit**

```bash
git add Package.swift .gitignore Sources/ScarlettAudio/CLI.swift Sources/ScarlettAudio/main.swift Tests/ScarlettAudioTests/CLITests.swift
git commit -m "$(cat <<'EOF'
Add SwiftPM package scaffold and CLI argument parser

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Pure audio format logic

**Files:**
- Create: `Sources/ScarlettAudio/AudioFormatLogic.swift`
- Create: `Tests/ScarlettAudioTests/AudioFormatLogicTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1 (independent pure module).
- Produces:
  - `struct RateBitsPair: Equatable { let sampleRate: Double; let bits: UInt32 }`
  - `func discreteRates(fromRanges ranges: [(min: Double, max: Double)]) -> [Double]`
  - `func intersectBitDepths(perStream streamBitDepths: [[UInt32]]) -> [UInt32]`
  - `func findMatchingFormat(in available: [RateBitsPair], sampleRate: Double, bits: UInt32) -> RateBitsPair?`
  - `func valuesMatch(requested: Double, actual: Double, tolerance: Double = 0.5) -> Bool`

- [ ] **Step 1: Write the failing tests**

Create `Tests/ScarlettAudioTests/AudioFormatLogicTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test`
Expected: FAIL — `cannot find 'discreteRates' in scope`, `cannot find 'RateBitsPair' in scope`, etc.

- [ ] **Step 3: Write the implementation**

Create `Sources/ScarlettAudio/AudioFormatLogic.swift`:

```swift
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test`
Expected: PASS — all `CLITests` and `AudioFormatLogicTests` (25 tests total), no failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/ScarlettAudio/AudioFormatLogic.swift Tests/ScarlettAudioTests/AudioFormatLogicTests.swift
git commit -m "$(cat <<'EOF'
Add pure audio format logic with unit tests

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Core Audio HAL wrappers and the `status` command

**Files:**
- Create: `Sources/ScarlettAudio/CoreAudioHAL.swift`
- Modify: `Sources/ScarlettAudio/main.swift` (replace the whole file)

**Interfaces:**
- Consumes: `Command`, `CLIError`, `parseArguments`, `usageText` (Task 1); `discreteRates`, `intersectBitDepths` (Task 2). Note: `main.swift` is fully replaced in this task, so `printError` from Task 1 is re-declared in the new file below rather than imported.
- Produces:
  - `enum HALError: Error, CustomStringConvertible` with cases `deviceNotFound(String)`, `noStreams(String)`, `formatNotAvailable(rate: Double, bits: UInt32)`, `osStatus(OSStatus, String)`
  - `func findDevice(nameContains query: String) throws -> AudioObjectID`
  - `func deviceName(_ id: AudioObjectID) throws -> String`
  - `func nominalSampleRate(_ id: AudioObjectID) throws -> Double`
  - `func setNominalSampleRate(_ id: AudioObjectID, to rate: Double) throws`
  - `func availableSampleRates(_ id: AudioObjectID) throws -> [Double]`
  - `func streamIDs(_ id: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [AudioObjectID]`
  - `func physicalFormat(_ streamID: AudioObjectID) throws -> AudioStreamBasicDescription`
  - `func setPhysicalFormat(_ streamID: AudioObjectID, to format: AudioStreamBasicDescription) throws`
  - `func availablePhysicalFormats(_ streamID: AudioObjectID) throws -> [AudioStreamBasicDescription]`
  - In `main.swift`: `let deviceNameQuery = "Scarlett 18i20"`, `func allStreamIDs(_ deviceID: AudioObjectID) throws -> [AudioObjectID]`, `func runStatus() throws`

No automated tests here: every function in this task performs real Core Audio I/O against attached hardware, which cannot be exercised without the device. Verification is the build plus the manual run in Steps 3 and 4.

- [ ] **Step 1: Write the HAL wrapper**

Create `Sources/ScarlettAudio/CoreAudioHAL.swift`:

```swift
import CoreAudio
import Foundation

enum HALError: Error, CustomStringConvertible {
    case deviceNotFound(String)
    case noStreams(String)
    case formatNotAvailable(rate: Double, bits: UInt32)
    case osStatus(OSStatus, String)

    var description: String {
        switch self {
        case .deviceNotFound(let query):
            return "No audio device found matching \"\(query)\""
        case .noStreams(let name):
            return "Device \"\(name)\" has no audio streams"
        case .formatNotAvailable(let rate, let bits):
            return "No \(bits)-bit format available at \(rate) Hz"
        case .osStatus(let status, let context):
            return "\(context) failed with OSStatus \(status)"
        }
    }
}

private func propertyDataSize(
    _ objectID: AudioObjectID,
    _ address: inout AudioObjectPropertyAddress
) throws -> UInt32 {
    var size: UInt32 = 0
    let status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
    guard status == noErr else {
        throw HALError.osStatus(status, "AudioObjectGetPropertyDataSize")
    }
    return size
}

private func getPropertyArray<T>(
    _ objectID: AudioObjectID,
    _ address: inout AudioObjectPropertyAddress,
    as type: T.Type
) throws -> [T] {
    var size = try propertyDataSize(objectID, &address)
    let count = Int(size) / MemoryLayout<T>.stride
    guard count > 0 else { return [] }

    let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
    defer { buffer.deallocate() }

    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, buffer)
    guard status == noErr else {
        throw HALError.osStatus(status, "AudioObjectGetPropertyData")
    }
    return Array(UnsafeBufferPointer(start: buffer, count: count))
}

private func getPropertyValue<T>(
    _ objectID: AudioObjectID,
    _ address: inout AudioObjectPropertyAddress,
    as type: T.Type
) throws -> T {
    var size = UInt32(MemoryLayout<T>.stride)
    let buffer = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { buffer.deallocate() }

    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, buffer)
    guard status == noErr else {
        throw HALError.osStatus(status, "AudioObjectGetPropertyData")
    }
    return buffer.pointee
}

private func setPropertyValue<T>(
    _ objectID: AudioObjectID,
    _ address: inout AudioObjectPropertyAddress,
    to value: T
) throws {
    var mutableValue = value
    let size = UInt32(MemoryLayout<T>.stride)
    let status = AudioObjectSetPropertyData(objectID, &address, 0, nil, size, &mutableValue)
    guard status == noErr else {
        throw HALError.osStatus(status, "AudioObjectSetPropertyData")
    }
}

private func address(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
}

func deviceName(_ id: AudioObjectID) throws -> String {
    var propertyAddress = address(kAudioObjectPropertyName)
    var size = UInt32(MemoryLayout<CFString?>.stride)
    var cfName: CFString?

    let status = withUnsafeMutablePointer(to: &cfName) { pointer -> OSStatus in
        AudioObjectGetPropertyData(id, &propertyAddress, 0, nil, &size, pointer)
    }
    guard status == noErr, let name = cfName else {
        throw HALError.osStatus(status, "AudioObjectGetPropertyData(kAudioObjectPropertyName)")
    }
    return name as String
}

func findDevice(nameContains query: String) throws -> AudioObjectID {
    var propertyAddress = address(kAudioHardwarePropertyDevices)
    let deviceIDs: [AudioObjectID] = try getPropertyArray(
        AudioObjectID(kAudioObjectSystemObject),
        &propertyAddress,
        as: AudioObjectID.self
    )

    for id in deviceIDs {
        if let name = try? deviceName(id), name.localizedCaseInsensitiveContains(query) {
            return id
        }
    }
    throw HALError.deviceNotFound(query)
}

func nominalSampleRate(_ id: AudioObjectID) throws -> Double {
    var propertyAddress = address(kAudioDevicePropertyNominalSampleRate)
    return try getPropertyValue(id, &propertyAddress, as: Float64.self)
}

func setNominalSampleRate(_ id: AudioObjectID, to rate: Double) throws {
    var propertyAddress = address(kAudioDevicePropertyNominalSampleRate)
    try setPropertyValue(id, &propertyAddress, to: Float64(rate))
}

func availableSampleRates(_ id: AudioObjectID) throws -> [Double] {
    var propertyAddress = address(kAudioDevicePropertyAvailableNominalSampleRates)
    let ranges: [AudioValueRange] = try getPropertyArray(
        id, &propertyAddress, as: AudioValueRange.self
    )
    return discreteRates(fromRanges: ranges.map { (min: $0.mMinimum, max: $0.mMaximum) })
}

func streamIDs(_ id: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [AudioObjectID] {
    var propertyAddress = address(kAudioDevicePropertyStreams, scope: scope)
    return try getPropertyArray(id, &propertyAddress, as: AudioObjectID.self)
}

func physicalFormat(_ streamID: AudioObjectID) throws -> AudioStreamBasicDescription {
    var propertyAddress = address(kAudioStreamPropertyPhysicalFormat)
    return try getPropertyValue(streamID, &propertyAddress, as: AudioStreamBasicDescription.self)
}

func setPhysicalFormat(_ streamID: AudioObjectID, to format: AudioStreamBasicDescription) throws {
    var propertyAddress = address(kAudioStreamPropertyPhysicalFormat)
    try setPropertyValue(streamID, &propertyAddress, to: format)
}

func availablePhysicalFormats(_ streamID: AudioObjectID) throws -> [AudioStreamBasicDescription] {
    var propertyAddress = address(kAudioStreamPropertyAvailablePhysicalFormats)
    let ranged: [AudioStreamRangedDescription] = try getPropertyArray(
        streamID, &propertyAddress, as: AudioStreamRangedDescription.self
    )
    return ranged.map { $0.mFormat }
}
```

- [ ] **Step 2: Wire the `status` command**

Replace the entire contents of `Sources/ScarlettAudio/main.swift` with:

```swift
import CoreAudio
import Foundation

let deviceNameQuery = "Scarlett 18i20"

func printError(_ message: String) {
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
}

func allStreamIDs(_ deviceID: AudioObjectID) throws -> [AudioObjectID] {
    let inputs = (try? streamIDs(deviceID, scope: kAudioObjectPropertyScopeInput)) ?? []
    let outputs = (try? streamIDs(deviceID, scope: kAudioObjectPropertyScopeOutput)) ?? []
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
    case .setRate, .setBits, .set:
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
```

- [ ] **Step 3: Build and run the unit tests**

Run: `swift test`
Expected: PASS — the 25 existing tests still pass and the new sources compile.

- [ ] **Step 4: Manually verify against the hardware**

With the Scarlett 18i20 connected, run: `swift run scarlett-audio status`

Expected output shape (exact values depend on current device state; the device was at 48000 Hz when this plan was written):

```
Device: Scarlett 18i20 USB
Sample rate: 48000.0 Hz
  available: 44100.0, 48000.0, 88200.0, 96000.0
Bit depth: 24 bits
  available: 24
```

Confirm the reported sample rate and bit depth match what Audio MIDI Setup shows for the Scarlett 18i20 (open `/System/Applications/Utilities/Audio MIDI Setup.app`, select the device, read the Format column). If the numbers disagree, stop and investigate before continuing.

- [ ] **Step 5: Commit**

```bash
git add Sources/ScarlettAudio/CoreAudioHAL.swift Sources/ScarlettAudio/main.swift
git commit -m "$(cat <<'EOF'
Add Core Audio HAL wrappers and status command

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `set-rate` command with readback verification

**Files:**
- Create: `Sources/ScarlettAudio/Verification.swift`
- Modify: `Sources/ScarlettAudio/main.swift` (add `runSetRate`, change the `.setRate` switch arm)

**Interfaces:**
- Consumes: `findDevice`, `nominalSampleRate`, `setNominalSampleRate` (Task 3); `valuesMatch` (Task 2).
- Produces:
  - `func pollUntilMatches<T>(timeout: TimeInterval, interval: TimeInterval, read: () throws -> T, matches: (T) -> Bool) throws -> T` (defaults: `timeout: 2.0`, `interval: 0.2`)
  - In `main.swift`: `func runSetRate(_ requestedRate: Double) throws`

- [ ] **Step 1: Write the polling helper**

Create `Sources/ScarlettAudio/Verification.swift`:

```swift
import Foundation

/// Hardware clock changes are not instantaneous, so a readback immediately
/// after a set can still report the old value. Poll until it settles.
func pollUntilMatches<T>(
    timeout: TimeInterval = 2.0,
    interval: TimeInterval = 0.2,
    read: () throws -> T,
    matches: (T) -> Bool
) throws -> T {
    let deadline = Date().addingTimeInterval(timeout)
    var latest = try read()
    while !matches(latest) && Date() < deadline {
        Thread.sleep(forTimeInterval: interval)
        latest = try read()
    }
    return latest
}
```

- [ ] **Step 2: Add `runSetRate` to `main.swift`**

In `Sources/ScarlettAudio/main.swift`, add this function directly after `runStatus()`:

```swift
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
```

- [ ] **Step 3: Dispatch the `.setRate` command**

In `Sources/ScarlettAudio/main.swift`, change the command switch from:

```swift
    case .setRate, .setBits, .set:
        printError("Command not implemented yet")
        exit(1)
```

to:

```swift
    case .setRate(let rate):
        try runSetRate(rate)
    case .setBits, .set:
        printError("Command not implemented yet")
        exit(1)
```

- [ ] **Step 4: Build and run the unit tests**

Run: `swift test`
Expected: PASS — 25 tests, no failures, sources compile.

- [ ] **Step 5: Manually verify against the hardware**

Note the current rate first: `swift run scarlett-audio status`

Change it to another rate the status output listed as available (use 44100 if the device is at 48000):

Run: `swift run scarlett-audio set-rate 44100`
Expected: `✅ Sample rate is now 44100.0 Hz`, exit code 0 (`echo $?` → `0`).

Confirm in Audio MIDI Setup that the Scarlett 18i20 now reads 44100 Hz.

Then check the failure path with a rate the hardware does not support:

Run: `swift run scarlett-audio set-rate 12345`
Expected: an error line (either a `❌` mismatch line or an `Error: AudioObjectSetPropertyData failed with OSStatus ...` line) and exit code 1.

Restore the original rate: `swift run scarlett-audio set-rate 48000`
Expected: `✅ Sample rate is now 48000.0 Hz`

- [ ] **Step 6: Commit**

```bash
git add Sources/ScarlettAudio/Verification.swift Sources/ScarlettAudio/main.swift
git commit -m "$(cat <<'EOF'
Add set-rate command with readback verification

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `set-bits` command with readback verification

**Files:**
- Modify: `Sources/ScarlettAudio/main.swift` (add `runSetBits`, change the `.setBits` switch arm)

**Interfaces:**
- Consumes: `findDevice`, `nominalSampleRate`, `allStreamIDs`, `availablePhysicalFormats`, `setPhysicalFormat`, `physicalFormat`, `HALError.formatNotAvailable` (Task 3); `RateBitsPair`, `findMatchingFormat`, `valuesMatch` (Task 2); `pollUntilMatches` (Task 4).
- Produces: `func runSetBits(_ requestedBits: UInt32) throws` in `main.swift`.

- [ ] **Step 1: Add `runSetBits` to `main.swift`**

In `Sources/ScarlettAudio/main.swift`, add this function directly after `runSetRate`:

```swift
func runSetBits(_ requestedBits: UInt32) throws {
    let deviceID = try findDevice(nameContains: deviceNameQuery)
    let currentRate = try nominalSampleRate(deviceID)
    let streams = try allStreamIDs(deviceID)

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
        try setPhysicalFormat(stream, to: format)
    }

    let actual = try pollUntilMatches(
        read: { try physicalFormat(streams[0]).mBitsPerChannel },
        matches: { $0 == requestedBits }
    )

    guard actual == requestedBits else {
        print("❌ Bit depth is \(actual) bits, expected \(requestedBits) bits")
        exit(1)
    }
    print("✅ Bit depth is now \(actual) bits")
}
```

- [ ] **Step 2: Dispatch the `.setBits` command**

In `Sources/ScarlettAudio/main.swift`, change the command switch from:

```swift
    case .setBits, .set:
        printError("Command not implemented yet")
        exit(1)
```

to:

```swift
    case .setBits(let bits):
        try runSetBits(bits)
    case .set:
        printError("Command not implemented yet")
        exit(1)
```

- [ ] **Step 3: Build and run the unit tests**

Run: `swift test`
Expected: PASS — 25 tests, no failures, sources compile.

- [ ] **Step 4: Manually verify against the hardware**

**Hardware reality, measured 2026-09-08:** this 18i20 exposes exactly one bit
depth — 24 — on both its input and output stream, at all four sample rates
(44100/48000/88200/96000). There is no second depth to switch to, so the
verification below exercises the success path idempotently and the rejection
path with a depth the device genuinely lacks.

Note the current bit depth and the available list: `swift run scarlett-audio status`
Expected: `Bit depth: 24 bits` and `available: 24`.

Success path — re-set the depth the device already has:

Run: `swift run scarlett-audio set-bits 24`
Expected: `✅ Bit depth is now 24 bits`, exit code 0 (`echo $?` → `0`). This
confirms the format lookup, the `setPhysicalFormat` call, and the readback all
work; it is a no-op on the hardware.

Rejection path — a depth the device does not offer:

Run: `swift run scarlett-audio set-bits 16`
Expected: `Error: No 16-bit format available at 48000.0 Hz`, exit code 1.

Run: `swift run scarlett-audio set-bits 8`
Expected: `Error: No 8-bit format available at 48000.0 Hz`, exit code 1.

Nothing needs restoring — the device never left 24-bit.

- [ ] **Step 5: Commit**

```bash
git add Sources/ScarlettAudio/main.swift
git commit -m "$(cat <<'EOF'
Add set-bits command with readback verification

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Combined `set` command and README

**Files:**
- Modify: `Sources/ScarlettAudio/main.swift` (final switch arm)
- Create: `README.md`

**Interfaces:**
- Consumes: `runSetRate` (Task 4), `runSetBits` (Task 5).
- Produces: nothing new — completes the CLI surface from the spec.

- [ ] **Step 1: Dispatch the `.set` command**

In `Sources/ScarlettAudio/main.swift`, change the command switch from:

```swift
    case .set:
        printError("Command not implemented yet")
        exit(1)
```

to:

```swift
    case .set(let rate, let bits):
        try runSetRate(rate)
        try runSetBits(bits)
```

The rate is applied and verified first; `runSetRate` exits non-zero on mismatch, so the bit depth is only matched against a sample rate the hardware actually accepted.

- [ ] **Step 2: Build and run the unit tests**

Run: `swift test`
Expected: PASS — 25 tests, no failures.

- [ ] **Step 3: Manually verify the combined command**

Run: `swift run scarlett-audio set --rate 44100 --bits 16`
Expected: two lines, `✅ Sample rate is now 44100.0 Hz` then `✅ Bit depth is now 16 bits`, exit code 0.

Confirm both values in Audio MIDI Setup, then restore: `swift run scarlett-audio set --rate 48000 --bits 24`

- [ ] **Step 4: Write the README**

Create `README.md`:

````markdown
# scarlett-audio

A macOS command-line tool for reading and setting the sample rate and bit
depth of a Focusrite Scarlett 18i20, with verification that the hardware
actually applied the change.

It talks directly to Core Audio, so it controls the same device properties
Audio MIDI Setup's Format column does — without opening the GUI.

## Build

```bash
swift build -c release
```

The binary lands at `.build/release/scarlett-audio`. Copy it somewhere on
your `PATH` if you want it available everywhere:

```bash
cp .build/release/scarlett-audio /usr/local/bin/
```

## Usage

```bash
scarlett-audio status
scarlett-audio set-rate 48000
scarlett-audio set-bits 24
scarlett-audio set --rate 96000 --bits 24
```

`status` prints the current sample rate and bit depth along with everything
the device supports:

```
Device: Scarlett 18i20 USB
Sample rate: 48000.0 Hz
  available: 44100.0, 48000.0, 88200.0, 96000.0
Bit depth: 24 bits
  available: 24
```

Every `set` command re-reads the property afterwards and reports whether the
hardware took the change:

```
✅ Sample rate is now 96000.0 Hz
❌ Sample rate is 48000.0 Hz, expected 96000.0 Hz
```

The exit code reflects that verification, not merely whether the Core Audio
call returned without error — so chaining with `&&` is meaningful.

## Tests

```bash
swift test
```

The unit tests cover argument parsing and the sample-rate/bit-depth list
logic. The Core Audio wrappers are exercised manually against the connected
interface, since they require the physical hardware.
````

- [ ] **Step 5: Final full verification**

Run: `swift build -c release`
Expected: builds without warnings or errors, binary present at `.build/release/scarlett-audio`.

Run: `swift test`
Expected: PASS — 25 tests, no failures.

Run: `.build/release/scarlett-audio status`
Expected: current device state printed, matching Audio MIDI Setup.

- [ ] **Step 6: Commit**

```bash
git add Sources/ScarlettAudio/main.swift README.md
git commit -m "$(cat <<'EOF'
Add combined set command and README

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Clock source matching logic and `set-clock` parsing

**Files:**
- Create: `Sources/ScarlettAudio/ClockSourceLogic.swift`
- Create: `Tests/ScarlettAudioTests/ClockSourceLogicTests.swift`
- Modify: `Sources/ScarlettAudio/CLI.swift` (add `.setClock`, parse `set-clock`, update usage text)
- Modify: `Tests/ScarlettAudioTests/CLITests.swift` (add `set-clock` parsing tests)
- Modify: `Sources/ScarlettAudio/main.swift` (placeholder `.setClock` switch arm — adding the enum case makes the existing switch non-exhaustive; see Step 6)

**Interfaces:**
- Consumes: `Command`, `CLIError`, `parseArguments` (Task 1).
- Produces:
  - `struct ClockSource: Equatable { let id: UInt32; let name: String }`
  - `func normalizedClockName(_ name: String) -> String`
  - `func findClockSource(named query: String, in sources: [ClockSource]) -> ClockSource?`
  - `Command` gains `case setClock(String)`

- [ ] **Step 1: Write the failing tests for the clock source logic**

Create `Tests/ScarlettAudioTests/ClockSourceLogicTests.swift`:

```swift
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
```

- [ ] **Step 2: Add the `set-clock` parsing tests**

In `Tests/ScarlettAudioTests/CLITests.swift`, add these three tests directly after `test_setBitsInvalidNumber`:

```swift
    func test_setClockCommand() {
        assertSuccess(parseArguments(["set-clock", "spdif"]), equals: .setClock("spdif"))
    }

    func test_setClockPreservesArgumentVerbatim() {
        assertSuccess(parseArguments(["set-clock", "S/PDIF"]), equals: .setClock("S/PDIF"))
    }

    func test_setClockMissingArgument() {
        assertFailure(parseArguments(["set-clock"]), equals: .missingArgument("<source>"))
    }
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test`
Expected: FAIL — `cannot find 'ClockSource' in scope`, `cannot find 'normalizedClockName' in scope`, and `type 'Command' has no member 'setClock'`.

- [ ] **Step 4: Write the clock source logic**

Create `Sources/ScarlettAudio/ClockSourceLogic.swift`:

```swift
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
```

- [ ] **Step 5: Add `set-clock` to the parser**

In `Sources/ScarlettAudio/CLI.swift`, add the case to `Command`:

```swift
enum Command: Equatable {
    case status
    case setRate(Double)
    case setBits(UInt32)
    case setClock(String)
    case set(rate: Double, bits: UInt32)
}
```

Update the unknown-command message to list it:

```swift
        case .unknownCommand(let name):
            return "Unknown command \"\(name)\". Expected one of: status, set-rate, set-bits, set-clock, set"
```

Update `usageText`:

```swift
let usageText = """
Usage:
  scarlett-audio status
  scarlett-audio set-rate <hz>
  scarlett-audio set-bits <bits>
  scarlett-audio set-clock <source>
  scarlett-audio set --rate <hz> --bits <bits>
"""
```

And add this case to the `switch commandName` block, directly after the `"set-bits"` case:

```swift
    case "set-clock":
        guard let source = rest.first else {
            return .failure(.missingArgument("<source>"))
        }
        return .success(.setClock(source))
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test`
Expected: FAIL to compile at first — `main.swift`'s command switch is no longer exhaustive (`Command` gained `.setClock`). Add this arm to the switch in `Sources/ScarlettAudio/main.swift`, directly after the `.setBits` arm, then re-run:

```swift
    case .setClock:
        printError("Command not implemented yet")
        exit(1)
```

Run: `swift test`
Expected: PASS — 34 tests (25 existing + 6 clock logic + 3 CLI), no failures.

- [ ] **Step 7: Commit**

```bash
git add Sources/ScarlettAudio/ClockSourceLogic.swift Sources/ScarlettAudio/CLI.swift Sources/ScarlettAudio/main.swift Tests/ScarlettAudioTests/ClockSourceLogicTests.swift Tests/ScarlettAudioTests/CLITests.swift
git commit -m "$(cat <<'EOF'
Add clock source matching logic and set-clock parsing

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Clock source HAL wiring, `status` line, and `set-clock` command

**Files:**
- Modify: `Sources/ScarlettAudio/CoreAudioHAL.swift` (add four clock functions)
- Modify: `Sources/ScarlettAudio/main.swift` (clock line in `runStatus`, add `runSetClock`, dispatch)
- Modify: `README.md` (document `set-clock` and the external-clock caveats)

**Interfaces:**
- Consumes: `address`, `getPropertyArray`, `getPropertyValue`, `setPropertyValue`, `HALError` (Task 3); `pollUntilMatches` (Task 4); `ClockSource`, `findClockSource`, `normalizedClockName` (Task 7).
- Produces:
  - `func clockSourceName(_ id: AudioObjectID, sourceID: UInt32) throws -> String`
  - `func clockSources(_ id: AudioObjectID) throws -> [ClockSource]`
  - `func currentClockSource(_ id: AudioObjectID) throws -> UInt32`
  - `func setClockSource(_ id: AudioObjectID, to sourceID: UInt32) throws`
  - In `main.swift`: `func runSetClock(_ requestedName: String) throws`

- [ ] **Step 1: Add the clock functions to the HAL**

Append to `Sources/ScarlettAudio/CoreAudioHAL.swift`:

```swift
/// Resolves a clock source ID to its display name. This property takes an
/// AudioValueTranslation, which carries pointers to the input ID and the
/// output CFString rather than the values themselves.
func clockSourceName(_ id: AudioObjectID, sourceID: UInt32) throws -> String {
    var propertyAddress = address(kAudioDevicePropertyClockSourceNameForIDCFString)
    var input = sourceID
    var output: CFString?
    var resolved: String?
    var status: OSStatus = noErr

    withUnsafeMutablePointer(to: &input) { inputPointer in
        withUnsafeMutablePointer(to: &output) { outputPointer in
            var translation = AudioValueTranslation(
                mInputData: UnsafeMutableRawPointer(inputPointer),
                mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                mOutputData: UnsafeMutableRawPointer(outputPointer),
                mOutputDataSize: UInt32(MemoryLayout<CFString?>.size)
            )
            var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
            status = AudioObjectGetPropertyData(id, &propertyAddress, 0, nil, &size, &translation)
            if status == noErr, let name = outputPointer.pointee {
                resolved = name as String
            }
        }
    }

    guard let name = resolved else {
        throw HALError.osStatus(
            status,
            "AudioObjectGetPropertyData(kAudioDevicePropertyClockSourceNameForIDCFString)"
        )
    }
    return name
}

func clockSources(_ id: AudioObjectID) throws -> [ClockSource] {
    var propertyAddress = address(kAudioDevicePropertyClockSources)
    let sourceIDs: [UInt32] = try getPropertyArray(id, &propertyAddress, as: UInt32.self)
    return try sourceIDs.map { sourceID in
        ClockSource(id: sourceID, name: try clockSourceName(id, sourceID: sourceID))
    }
}

func currentClockSource(_ id: AudioObjectID) throws -> UInt32 {
    var propertyAddress = address(kAudioDevicePropertyClockSource)
    return try getPropertyValue(id, &propertyAddress, as: UInt32.self)
}

func setClockSource(_ id: AudioObjectID, to sourceID: UInt32) throws {
    var propertyAddress = address(kAudioDevicePropertyClockSource)
    try setPropertyValue(id, &propertyAddress, to: sourceID)
}
```

- [ ] **Step 2: Add the clock source line to `status`**

In `Sources/ScarlettAudio/main.swift`, inside `runStatus()`, add after the bit depth lines and before the closing brace:

```swift
    let sources = try clockSources(deviceID)
    let currentSourceID = try currentClockSource(deviceID)
    let currentSourceName = sources.first { $0.id == currentSourceID }?.name
        ?? "id \(currentSourceID)"

    print("Clock source: \(currentSourceName)")
    print("  available: \(sources.map { $0.name }.joined(separator: ", "))")
```

- [ ] **Step 3: Add `runSetClock` and dispatch it**

In `Sources/ScarlettAudio/main.swift`, add this function directly after `runSetBits`:

```swift
func runSetClock(_ requestedName: String) throws {
    let deviceID = try findDevice(nameContains: deviceNameQuery)
    let sources = try clockSources(deviceID)

    guard let requested = findClockSource(named: requestedName, in: sources) else {
        let available = sources.map { $0.name }.joined(separator: ", ")
        printError("Unknown clock source \"\(requestedName)\". Available: \(available)")
        exit(1)
    }

    try setClockSource(deviceID, to: requested.id)

    let actual = try pollUntilMatches(
        read: { try currentClockSource(deviceID) },
        matches: { $0 == requested.id }
    )

    guard actual == requested.id else {
        let actualName = (try? clockSourceName(deviceID, sourceID: actual)) ?? "id \(actual)"
        print("❌ Clock source is \(actualName), expected \(requested.name)")
        exit(1)
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
```

Then change the switch arm added in Task 7 from:

```swift
    case .setClock:
        printError("Command not implemented yet")
        exit(1)
```

to:

```swift
    case .setClock(let source):
        try runSetClock(source)
```

- [ ] **Step 4: Build and run the unit tests**

Run: `swift test`
Expected: PASS — 34 tests, no failures, sources compile.

- [ ] **Step 5: Manually verify against the hardware**

> **Caution:** the Scarlett is the machine's default output device. Switching it
> to S/PDIF or ADAT with no valid signal on that input leaves it unclocked, so
> system audio may glitch or go silent until Internal is restored. Do this step
> when nothing important is playing, and run the restore command immediately
> after.

Run: `swift run scarlett-audio status`
Expected: the status output now ends with:

```
Clock source: Internal
  available: Internal, S/PDIF, ADAT
```

Run: `swift run scarlett-audio set-clock spdif`
Expected: `✅ Clock source is now S/PDIF`, followed by the `⚠️` external-clock warning, exit code 0.

Confirm in Audio MIDI Setup that the Scarlett 18i20's Clock Source now reads S/PDIF.

Restore Internal immediately: `swift run scarlett-audio set-clock internal`
Expected: `✅ Clock source is now Internal`, no warning line, exit code 0.

Check the rejection path: `swift run scarlett-audio set-clock wordclock`
Expected: `Error: Unknown clock source "wordclock". Available: Internal, S/PDIF, ADAT`, exit code 1.

- [ ] **Step 6: Update the README**

In `README.md`, add `set-clock` to the usage block:

```bash
scarlett-audio set-clock internal
scarlett-audio set-clock spdif
```

Add `Clock source` to the sample `status` output:

```
Clock source: Internal
  available: Internal, S/PDIF, ADAT
```

And add this section directly before `## Tests`:

```markdown
## Clock source

`set-clock` matches source names case- and punctuation-insensitively, so
`spdif`, `S/PDIF` and `SPDIF` all select the same source.

Two caveats when slaving to an external clock:

- Core Audio confirms that a source was *selected*, but exposes no
  standard way to report whether an external signal is actually
  *locked*. Selecting S/PDIF with nothing plugged in reports success
  while the interface runs unclocked — hence the warning the tool
  prints.
- While slaved to S/PDIF or ADAT, the sample rate follows the incoming
  signal, so `set-rate` may fail or be overridden until you switch back
  to Internal.
```

- [ ] **Step 7: Final full verification**

Run: `swift build -c release`
Expected: builds without warnings or errors.

Run: `swift test`
Expected: PASS — 34 tests, no failures.

Run: `.build/release/scarlett-audio status`
Expected: device name, sample rate, bit depth, and clock source printed, all matching Audio MIDI Setup.

- [ ] **Step 8: Commit**

```bash
git add Sources/ScarlettAudio/CoreAudioHAL.swift Sources/ScarlettAudio/main.swift README.md
git commit -m "$(cat <<'EOF'
Add clock source status and set-clock command

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```
