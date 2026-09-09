# scarlett-audio

A macOS command-line tool for reading and setting the sample rate, bit
depth, and clock source of a Focusrite Scarlett 18i20, with verification
that the hardware actually applied the change.

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
scarlett-audio set-clock internal
scarlett-audio set-clock spdif
scarlett-audio set --rate 96000 --bits 24
```

The combined `set` command applies the rate before the bit depth, so if the
bit depth request is rejected, the device is left at the new rate rather
than the original one.

`status` prints the current sample rate and bit depth along with everything
the device supports:

```
Device: Scarlett 18i20 USB
Sample rate: 48000.0 Hz
  available: 44100.0, 48000.0, 88200.0, 96000.0
Bit depth: 24 bits
  available: 24
Clock source: Internal
  available: Internal, S/PDIF, ADAT
```

Every `set` command re-reads the property afterwards and reports whether the
hardware took the change:

```
✅ Sample rate is now 96000.0 Hz
❌ Sample rate is 48000.0 Hz, expected 96000.0 Hz
```

The exit code reflects that verification, not merely whether the Core Audio
call returned without error — so chaining with `&&` is meaningful.

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

## Tests

```bash
swift test
```

The unit tests cover argument parsing and the sample-rate/bit-depth/clock-
source list logic. The Core Audio wrappers are exercised manually against
the connected interface, since they require the physical hardware.

Note on `set-bits`: this interface only advertises 24-bit formats, so
against real hardware `set-bits` has only ever been exercised idempotently
(requesting the depth already in effect) and on its rejection path
(requesting an unsupported depth). Its actual bit-depth *transition* path
has never been observed against hardware and would need a multi-depth
interface to validate.

## Requirements

Requires macOS 12 or later (the code uses
`kAudioObjectPropertyElementMain`, and `Package.swift` declares
`.macOS(.v12)`). The device is matched by the hard-coded substring
`"Scarlett 18i20"`, so other Scarlett models are not currently found.
