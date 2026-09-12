# scarlett-audio

A macOS command-line tool for reading and setting the sample rate, bit
depth, and clock source of a Focusrite Scarlett 18i20, with verification
that the hardware actually applied the change.

It talks directly to Core Audio, so it controls the same device properties
Audio MIDI Setup's Format column does — without opening the GUI.

## Build

You need macOS 12 or later, the Xcode command line tools (Swift 5.9 or
newer), and `libusb`:

```bash
xcode-select --install
brew install libusb
```

`libusb` is needed to *build*, not only to save: the `CLibUSB` target
includes `<libusb.h>`, so the compile fails outright without it.

```bash
git clone https://github.com/fuzzpedal/scarlett-cli.git
cd scarlett-cli
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
scarlett-audio set-clock spdif --save
scarlett-audio save
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

Saving talks to the device over USB rather than through Core Audio, and is
written for the **1st-generation** 18i20 specifically — see Requirements.

## Tests

```bash
swift test
```

The unit tests cover argument parsing and the sample-rate/bit-depth/clock-
source list logic. The Core Audio wrappers, along with the libusb transfer
that saves the clock source to the interface's flash, are exercised
manually against the connected interface, since they require the physical
hardware. The save path's end-to-end behavior — that a saved clock source
actually survives a power cycle — is verified by a manual power-cycle
acceptance test rather than by the unit suite; as of this commit that
acceptance test has not yet been run.

Note on `set-bits`: this interface only advertises 24-bit formats, so
against real hardware `set-bits` has only ever been exercised idempotently
(requesting the depth already in effect) and on its rejection path
(requesting an unsupported depth). Its actual bit-depth *transition* path
has never been observed against hardware and would need a multi-depth
interface to validate.

## Requirements

- macOS 12 or later — the code uses `kAudioObjectPropertyElementMain`, and
  `Package.swift` declares `.macOS(.v12)`.
- Swift 5.9 or newer, from Xcode or the Command Line Tools.
- `libusb` (`brew install libusb`), at build time as well as at run time.

The device is matched by the hard-coded substring `"Scarlett 18i20"`, so other
Scarlett models are not currently found.

Saving to flash (`--save` / `save`) is narrower still: it implements the
**1st-generation** 18i20's USB protocol and matches `1235:800c` exactly. On a
2nd- or 3rd-generation 18i20 the Core Audio commands (`status`, `set-rate`,
`set-bits`, and `set-clock` without `--save`) still work, but saving reports
`No Scarlett 18i20 found on USB` rather than sending the wrong protocol to the
device.

## License

MIT — see [LICENSE](LICENSE).
