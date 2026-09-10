# Clock Source Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `--save` and a `save` command to `scarlett-audio` so the clock source is committed to the 18i20's flash and survives a power cycle with no computer attached.

**Architecture:** `set-clock` keeps using the existing, verified Core Audio path to set the live value. A new libusb-backed component sends one vendor control transfer that tells the device to commit its current configuration to flash. The commit is invoked from `main.swift`'s command switch — deliberately outside `runSetClock` — so the existing same-value early return cannot skip it.

**Tech Stack:** Swift 5.9 (SwiftPM), CoreAudio, AudioToolbox, libusb-1.0 via a `systemLibrary` target.

**Spec:** `docs/superpowers/specs/2026-09-10-clock-source-persistence-design.md`

## Global Constraints

- macOS 12 or later; `Package.swift` declares `.macOS(.v12)`, swift-tools-version 5.9.
- Device is USB `1235:800c` (Scarlett 18i20 Gen 1), matched in Core Audio by the substring `"Scarlett 18i20"`.
- **All USB requests target interface 0.** Interface 5 is the DFU (firmware) interface; sending it anything wedges the control pipe and drops the device off the bus, requiring a physical power cycle.
- Save request, verified against the hardware: `bmRequestType=0x21`, `bRequest=0x03`, `wValue=0x005a`, `wIndex=0x3c00`, 1 byte payload `0xa5`.
- **No retry loop on a failed or timed-out transfer.** A wedged control pipe does not recover without a replug, and `libusb_clear_halt` on endpoint 0 does not clear it.
- The saved config cannot be read back. Never print saved state as though it came from the device.
- New dependency: `brew install libusb` (1.0.27 confirmed working).

---

### Task 1: libusb system library target

**Files:**
- Create: `Sources/CLibUSB/module.modulemap`
- Create: `Sources/CLibUSB/shim.h`
- Modify: `Package.swift`
- Test: `Tests/ScarlettAudioTests/LibUSBLinkageTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: module `CLibUSB`, exporting the libusb 1.0 C API (`libusb_init`, `libusb_exit`, `libusb_get_device_list`, `libusb_free_device_list`, `libusb_get_device_descriptor`, `libusb_open`, `libusb_close`, `libusb_control_transfer`).

- [ ] **Step 1: Write the failing test**

Create `Tests/ScarlettAudioTests/LibUSBLinkageTests.swift`:

```swift
import XCTest
import CLibUSB

final class LibUSBLinkageTests: XCTestCase {
    func test_libusbInitialisesAndExits() {
        var context: OpaquePointer?
        XCTAssertEqual(libusb_init(&context), 0)
        libusb_exit(context)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LibUSBLinkageTests`
Expected: FAIL — `no such module 'CLibUSB'`.

- [ ] **Step 3: Create the module map and shim header**

`Sources/CLibUSB/shim.h`:

```c
#include <libusb.h>
```

`Sources/CLibUSB/module.modulemap`:

```
module CLibUSB [system] {
    header "shim.h"
    link "usb-1.0"
    export *
}
```

- [ ] **Step 4: Wire the target into Package.swift**

In `Package.swift`, add to `targets:` (before the executable target):

```swift
        .systemLibrary(
            name: "CLibUSB",
            path: "Sources/CLibUSB",
            pkgConfig: "libusb-1.0",
            providers: [.brew(["libusb"])]
        ),
```

Add `dependencies: ["CLibUSB"],` to the `.executableTarget(name: "ScarlettAudio", ...)`, and change the test target's dependencies to `["ScarlettAudio", "CLibUSB"]`.

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter LibUSBLinkageTests`
Expected: PASS.

If it fails with a pkg-config error, confirm `pkg-config --cflags libusb-1.0` prints an include path; install with `brew install libusb pkg-config`.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/CLibUSB Tests/ScarlettAudioTests/LibUSBLinkageTests.swift
git commit -m "Add CLibUSB system library target"
```

---

### Task 2: Save-to-hardware transfer

**Files:**
- Create: `Sources/ScarlettAudio/DeviceSave.swift`
- Test: `Tests/ScarlettAudioTests/DeviceSaveTests.swift`

**Interfaces:**
- Consumes: module `CLibUSB` from Task 1.
- Produces: `enum SaveProtocol` with static members `vendorID: UInt16`, `productID: UInt16`, `interface: UInt16`, `requestSave: UInt8`, `valueSave: UInt16`, `unitSave: UInt16`, `magic: UInt8`, `indexSave: UInt16`; `enum SaveError: Error, Equatable, CustomStringConvertible`; `func saveToHardware() throws`.

- [ ] **Step 1: Write the failing test**

Create `Tests/ScarlettAudioTests/DeviceSaveTests.swift`:

```swift
import XCTest
@testable import ScarlettAudio

final class DeviceSaveTests: XCTestCase {
    func test_protocolConstantsMatchVerifiedValues() {
        XCTAssertEqual(SaveProtocol.vendorID, 0x1235)
        XCTAssertEqual(SaveProtocol.productID, 0x800c)
        XCTAssertEqual(SaveProtocol.requestSave, 0x03)
        XCTAssertEqual(SaveProtocol.valueSave, 0x005a)
        XCTAssertEqual(SaveProtocol.magic, 0xa5)
        XCTAssertEqual(SaveProtocol.indexSave, 0x3c00)
    }

    /// Interface 5 is the DFU (firmware) interface. Sending it anything wedges
    /// the control pipe and drops the device off the USB bus. This guards the
    /// constant against a careless edit.
    func test_targetsInterfaceZeroAndNeverTheDFUInterface() {
        XCTAssertEqual(SaveProtocol.interface, 0)
        XCTAssertNotEqual(SaveProtocol.interface, 5)
    }

    func test_errorsDescribeThemselves() {
        XCTAssertTrue(
            SaveError.deviceNotFoundOnUSB.description.contains("1235:800c")
        )
        XCTAssertTrue(
            SaveError.transferFailed(-9).description.contains("not persisted")
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DeviceSaveTests`
Expected: FAIL — `cannot find 'SaveProtocol' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/ScarlettAudio/DeviceSave.swift`:

```swift
import Foundation
import CLibUSB

/// Vendor protocol for the Gen 1 Scarlett, documented in Linux
/// `sound/usb/mixer_scarlett.c` and verified against this 18i20 on 2026-09-10.
///
/// Every request targets interface 0. Interface 5 is the DFU (firmware)
/// interface: a class request to it is a DFU_UPLOAD, which wedges the control
/// pipe and knocks the device off the USB bus until it is power-cycled. Do not
/// enumerate or sweep interfaces here.
enum SaveProtocol {
    static let vendorID: UInt16 = 0x1235
    static let productID: UInt16 = 0x800c
    static let interface: UInt16 = 0
    static let requestSave: UInt8 = 0x03
    static let valueSave: UInt16 = 0x005a
    static let unitSave: UInt16 = 0x3c
    static let magic: UInt8 = 0xa5

    static var indexSave: UInt16 { (unitSave << 8) | interface }
}

enum SaveError: Error, Equatable, CustomStringConvertible {
    case libusbInitFailed(Int32)
    case deviceNotFoundOnUSB
    case openFailed(Int32)
    case transferFailed(Int32)

    var description: String {
        switch self {
        case .libusbInitFailed(let code):
            return "Could not initialise libusb (code \(code))"
        case .deviceNotFoundOnUSB:
            return "No Scarlett 18i20 found on USB (looked for 1235:800c). "
                + "The interface can be present in Core Audio and absent from "
                + "USB — check the cable and that the unit is powered."
        case .openFailed(let code):
            return "Could not open the interface over USB (libusb code \(code))"
        case .transferFailed(let code):
            return "The device rejected the save request (libusb code \(code)). "
                + "Settings were not persisted."
        }
    }
}

/// Tells the interface to commit its current configuration to flash, so it
/// survives a power cycle. This saves the device's *entire* configuration,
/// not just the clock source.
func saveToHardware() throws {
    var context: OpaquePointer?
    let initResult = libusb_init(&context)
    guard initResult == 0 else { throw SaveError.libusbInitFailed(initResult) }
    defer { libusb_exit(context) }

    var list: UnsafeMutablePointer<OpaquePointer?>?
    let count = libusb_get_device_list(context, &list)
    defer { if let list { libusb_free_device_list(list, 1) } }
    guard count > 0, let list else { throw SaveError.deviceNotFoundOnUSB }

    var handle: OpaquePointer?
    for index in 0..<Int(count) {
        guard let device = list[index] else { continue }
        var descriptor = libusb_device_descriptor()
        guard libusb_get_device_descriptor(device, &descriptor) == 0 else { continue }
        guard descriptor.idVendor == SaveProtocol.vendorID,
              descriptor.idProduct == SaveProtocol.productID else { continue }

        let openResult = libusb_open(device, &handle)
        guard openResult == 0 else { throw SaveError.openFailed(openResult) }
        break
    }
    guard let handle else { throw SaveError.deviceNotFoundOnUSB }
    defer { libusb_close(handle) }

    var payload = SaveProtocol.magic
    // 0x21 = host-to-device | class request | interface recipient.
    // No retry: a wedged control pipe does not recover without a replug, so a
    // second attempt would only hide the failure.
    let sent = libusb_control_transfer(
        handle,
        0x21,
        SaveProtocol.requestSave,
        SaveProtocol.valueSave,
        SaveProtocol.indexSave,
        &payload,
        1,
        2000
    )
    guard sent == 1 else { throw SaveError.transferFailed(sent) }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter DeviceSaveTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ScarlettAudio/DeviceSave.swift Tests/ScarlettAudioTests/DeviceSaveTests.swift
git commit -m "Add save-to-hardware USB transfer"
```

---

### Task 3: Last-saved cache

**Files:**
- Create: `Sources/ScarlettAudio/SaveCache.swift`
- Test: `Tests/ScarlettAudioTests/SaveCacheTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `struct LastSaved: Equatable, Codable` with `source: String` and `savedAt: Date`; `enum SaveCache` with `static var defaultURL: URL`, `static func read(from url: URL = defaultURL) -> LastSaved?`, `static func write(_ entry: LastSaved, to url: URL = defaultURL) throws`.

- [ ] **Step 1: Write the failing test**

Create `Tests/ScarlettAudioTests/SaveCacheTests.swift`:

```swift
import XCTest
@testable import ScarlettAudio

final class SaveCacheTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var cacheURL: URL {
        directory.appendingPathComponent("last-saved.json")
    }

    func test_roundTripsAnEntry() throws {
        let entry = LastSaved(source: "S/PDIF", savedAt: Date(timeIntervalSince1970: 1_789_000_000))
        try SaveCache.write(entry, to: cacheURL)
        XCTAssertEqual(SaveCache.read(from: cacheURL), entry)
    }

    func test_createsIntermediateDirectories() throws {
        let nested = directory.appendingPathComponent("a/b/last-saved.json")
        try SaveCache.write(LastSaved(source: "ADAT", savedAt: Date()), to: nested)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    func test_missingFileReadsAsNil() {
        XCTAssertNil(SaveCache.read(from: cacheURL))
    }

    func test_malformedFileReadsAsNilRatherThanThrowing() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: cacheURL)
        XCTAssertNil(SaveCache.read(from: cacheURL))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SaveCacheTests`
Expected: FAIL — `cannot find 'LastSaved' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/ScarlettAudio/SaveCache.swift`:

```swift
import Foundation

/// What this tool last committed to the device's flash.
///
/// The device offers no way to read its saved configuration back — the
/// protocol has a write-and-commit with no corresponding read. This cache is
/// therefore a record of what *this tool* saved, not a reading of the
/// hardware, and it will be stale if anything else writes the device. Present
/// it with wording that stays true when that happens.
struct LastSaved: Equatable, Codable {
    let source: String
    let savedAt: Date
}

enum SaveCache {
    static var defaultURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return base
            .appendingPathComponent("scarlett-audio", isDirectory: true)
            .appendingPathComponent("last-saved.json")
    }

    /// A missing or unreadable cache is normal, not an error.
    static func read(from url: URL = defaultURL) -> LastSaved? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LastSaved.self, from: data)
    }

    static func write(_ entry: LastSaved, to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entry).write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SaveCacheTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ScarlettAudio/SaveCache.swift Tests/ScarlettAudioTests/SaveCacheTests.swift
git commit -m "Add last-saved cache"
```

---

### Task 4: CLI parsing for --save and save

**Files:**
- Modify: `Sources/ScarlettAudio/CLI.swift`
- Modify: `Tests/ScarlettAudioTests/CLITests.swift`
- Modify: `Sources/ScarlettAudio/main.swift` (switch arm only — keeps the build green)

**Interfaces:**
- Consumes: nothing.
- Produces: `Command.setClock(String, save: Bool)` replacing `Command.setClock(String)`; new `Command.save`.

**Note:** changing the `setClock` case breaks the two existing `set-clock` tests and the `main.swift` switch. Both are updated in this task so the build and suite stay green.

- [ ] **Step 1: Write the failing tests**

In `Tests/ScarlettAudioTests/CLITests.swift`, update the two existing `set-clock` tests to the new shape and add four new ones:

```swift
    func test_setClockCommand() {
        assertSuccess(
            parseArguments(["set-clock", "spdif"]),
            equals: .setClock("spdif", save: false)
        )
    }

    func test_setClockPreservesArgumentVerbatim() {
        assertSuccess(
            parseArguments(["set-clock", "S/PDIF"]),
            equals: .setClock("S/PDIF", save: false)
        )
    }

    func test_setClockWithSaveFlag() {
        assertSuccess(
            parseArguments(["set-clock", "spdif", "--save"]),
            equals: .setClock("spdif", save: true)
        )
    }

    func test_setClockSaveFlagBeforeSource() {
        assertSuccess(
            parseArguments(["set-clock", "--save", "spdif"]),
            equals: .setClock("spdif", save: true)
        )
    }

    func test_setClockWithOnlyTheFlagIsMissingItsSource() {
        assertFailure(
            parseArguments(["set-clock", "--save"]),
            equals: .missingArgument("<source>")
        )
    }

    func test_saveCommand() {
        assertSuccess(parseArguments(["save"]), equals: .save)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CLITests`
Expected: FAIL — `extra argument 'save' in call`.

- [ ] **Step 3: Update the Command enum and parser**

In `Sources/ScarlettAudio/CLI.swift`, change the `setClock` case and add `save`:

```swift
enum Command: Equatable {
    case status
    case setRate(Double)
    case setBits(UInt32)
    case setClock(String, save: Bool)
    case save
    case set(rate: Double, bits: UInt32)
}
```

Update the unknown-command message to list `save`:

```swift
            return "Unknown command \"\(name)\". Expected one of: status, set-rate, set-bits, set-clock, save, set"
```

Update `usageText`:

```swift
let usageText = """
Usage:
  scarlett-audio status
  scarlett-audio set-rate <hz>
  scarlett-audio set-bits <bits>
  scarlett-audio set-clock <source> [--save]
  scarlett-audio save
  scarlett-audio set --rate <hz> --bits <bits>

  --save  also commits the setting to the interface's flash, so it survives
          a power cycle. Saves the device's entire configuration, not just
          the clock source.
"""
```

Replace the `set-clock` parse arm, and add a `save` arm:

```swift
    case "set-clock":
        let save = rest.contains("--save")
        // Filter flags out before taking the positional, so
        // `set-clock --save spdif` and `set-clock spdif --save` both work and
        // `set-clock --save` reports a missing source rather than trying to
        // select a clock called "--save".
        let positional = rest.filter { !$0.hasPrefix("--") }
        guard let source = positional.first else {
            return .failure(.missingArgument("<source>"))
        }
        return .success(.setClock(source, save: save))

    case "save":
        return .success(.save)
```

- [ ] **Step 4: Update the main.swift switch so the build compiles**

In `Sources/ScarlettAudio/main.swift`, replace the `.setClock` arm and add `.save`. Wiring the actual save behaviour is Task 5; for now:

```swift
    case .setClock(let source, _):
        try runSetClock(source)
    case .save:
        break
```

- [ ] **Step 5: Run the full suite to verify it passes**

Run: `swift test`
Expected: PASS — all tests including the six `set-clock`/`save` parsing tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/ScarlettAudio/CLI.swift Sources/ScarlettAudio/main.swift Tests/ScarlettAudioTests/CLITests.swift
git commit -m "Parse --save flag and save command"
```

---

### Task 5: Wire up the save, status line, and docs

**Files:**
- Modify: `Sources/ScarlettAudio/main.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: `saveToHardware()` and `SaveError` (Task 2); `LastSaved`, `SaveCache` (Task 3); `Command.setClock(String, save: Bool)` and `Command.save` (Task 4).
- Produces: `func runSave() throws`.

**Deviation from the spec:** the spec calls for a regression test that `--save` still commits when the clock source is already the requested value. This plan makes that bug unrepresentable instead — see below — so the guard is structural, plus the hardware check in Step 6. There is no unit test for it, because the code path it would cover no longer exists.

**Why `runSave` is called from the switch and not from inside `runSetClock`:** `runSetClock` deliberately skips the Core Audio write when the requested source is already selected, because Core Audio rejects writing a clock source to the value it already holds. `set-clock spdif --save` while already on S/PDIF is exactly how someone persists an existing setting, and it is the most likely way this command gets run. Putting the save inside `runSetClock` puts it within reach of that early return; putting it in the switch makes skipping it structurally impossible.

- [ ] **Step 1: Add runSave to main.swift**

In `Sources/ScarlettAudio/main.swift`, add after `runSetClock`:

```swift
/// Commits the device's current configuration to its flash.
///
/// The clock source is read first, purely to record it in the cache — the
/// device gives us no way to read its saved configuration back. If that read
/// fails we still save, and leave the cache alone rather than writing a guess.
func currentClockSourceName() throws -> String? {
    let deviceID = try findDevice(nameContains: deviceNameQuery)
    let sources = try clockSources(deviceID)
    let currentID = try currentClockSource(deviceID)
    return sources.first { $0.id == currentID }?.name
}

func runSave() throws {
    let recorded: String? = try? currentClockSourceName()

    try saveToHardware()

    print("✅ Saved to the interface — settings will survive a power cycle")
    print("   This saves the device's entire configuration, not just the clock source.")

    if let recorded {
        do {
            try SaveCache.write(LastSaved(source: recorded, savedAt: Date()))
        } catch {
            // The hardware save succeeded; a cache failure only costs us the
            // status line, so report it without failing the command.
            printStderr("⚠️  Saved to the device, but could not update the local record: \(error)")
        }
    }
}
```

- [ ] **Step 2: Wire the switch arms**

Replace the placeholder arms from Task 4:

```swift
    case .setClock(let source, let save):
        try runSetClock(source)
        if save {
            try runSave()
        }
    case .save:
        try runSave()
```

- [ ] **Step 3: Catch SaveError at the top level**

Add a catch arm before the existing `catch let error as HALError`:

```swift
} catch let error as SaveError {
    printError(error.description)
    exit(1)
```

- [ ] **Step 4: Add the status line**

In `runStatus()`, after the `print("  available: \(sources.map { $0.name }.joined(separator: ", "))")` line:

```swift
    // Deliberately worded as what this tool last saved, not as the device's
    // saved state: the protocol offers no way to read that back, and this
    // record goes stale if anything else writes the interface.
    if let last = SaveCache.read() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        print("Last saved by this tool: \(last.source) (\(formatter.string(from: last.savedAt)))")
    } else {
        print("Last saved by this tool: unknown")
    }
```

- [ ] **Step 5: Build and run the suite**

Run: `swift build -c release && swift test`
Expected: build succeeds, all tests pass.

- [ ] **Step 6: Verify against the hardware**

With the interface connected:

```bash
.build/release/scarlett-audio status
.build/release/scarlett-audio set-clock spdif --save
.build/release/scarlett-audio status
```

Expected: the save reports success; `status` then shows `Last saved by this tool: S/PDIF` with a current timestamp.

Then run it a second time while already on S/PDIF:

```bash
.build/release/scarlett-audio set-clock spdif --save
```

Expected: still reports the save succeeded. This is the case the early return would have swallowed.

- [ ] **Step 7: Acceptance test — the actual requirement**

1. `.build/release/scarlett-audio set-clock internal --save`
2. `.build/release/scarlett-audio set-clock spdif` (no `--save`, so the live value differs from the saved one)
3. Unplug USB, power the unit off for ten seconds, power on, replug.
4. Read the clock source within ~400 ms of enumeration, before macOS overwrites it.

Expected: the device comes up on **Internal** — the saved value, not the live one. Then restore with `set-clock spdif --save`.

If reading inside that window is awkward, the equivalent end-to-end check is to power-cycle the unit with no computer attached at all and confirm the Kemper's S/PDIF audio passes.

- [ ] **Step 8: Update the README**

Add `--save` and `save` to the Usage block. Add a section after "Clock source":

```markdown
## Persisting settings

`set-clock` alone changes the *driver's* live setting, which does not survive
a power cycle. Add `--save` to also commit it to the interface's own flash, so
the unit comes up on that clock source with no computer attached:

    scarlett-audio set-clock spdif --save

`save` on its own commits whatever the device currently holds. Both save the
device's **entire** configuration, not just the clock source.

Two limitations worth knowing:

- The saved configuration cannot be read back — the protocol provides a
  write-and-commit with no corresponding read. `status` therefore reports what
  this tool last saved, which will be wrong if anything else writes the
  interface.
- macOS overwrites the clock source about 410 ms after the device enumerates,
  with its own remembered value. So while the Mac is attached you cannot
  observe what the device has stored; it only shows in standalone use.

Requires `brew install libusb`.
```

Also add libusb to the Requirements section.

- [ ] **Step 9: Commit**

```bash
git add Sources/ScarlettAudio/main.swift README.md
git commit -m "Wire up --save and save command"
```

---

## Notes for the executor

- The Core Audio path is untouched by this plan. If a `set-clock` test starts failing, the cause is the `Command` enum change in Task 4, not the hardware.
- `set-bits` on this interface can only ever succeed with 24 — it advertises 24-bit only, at all four rates. Unrelated to this work, but it explains an otherwise surprising test surface.
- Sample rate persistence (unit `0x29`) is explicitly out of scope and unverified. Do not add it opportunistically.
