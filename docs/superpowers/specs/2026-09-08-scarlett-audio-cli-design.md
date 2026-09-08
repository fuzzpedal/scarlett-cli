# Scarlett Audio CLI — Design

**Date:** 2026-09-08
**Status:** Approved for implementation

## Purpose

A small macOS command-line tool to view and change the sample rate and
bit depth of a Focusrite Scarlett 18i20 (Gen 1) audio interface, and to
verify the hardware actually applied the requested value — without
opening Audio MIDI Setup.

## Context

The interface is a standard class-compliant Core Audio device on
macOS. Sample rate and bit depth are Core Audio HAL device/stream
properties (the same ones Audio MIDI Setup's "Format" dropdown reads
and writes). No Focusrite-specific SDK or driver integration is
required.

Considered and rejected:
- **Tauri + Rust app** — original idea, but the user only needs quick
  set/verify, not a GUI; dropped in favor of a CLI.
- **Rust with `coreaudio-sys`/`coreaudio-rs`** — works, but Swift's
  native C interop with Core Audio is less boilerplate.
- **`cpal` crate** — cross-platform audio I/O library; does not expose
  setting a device's persistent nominal sample rate or physical stream
  format. Not usable for this.
- **Shelling out to an existing CLI utility** — no existing tool
  (e.g. `SwitchAudioSource`) sets sample rate/bit depth, only default
  device selection. Ruled out.

## Approach

A standalone Swift Package Manager executable (`scarlett-audio`) using
the `CoreAudio` and `AudioToolbox` frameworks directly. No external
dependencies (argument parsing is done by hand — only a few
subcommands).

## Device discovery

- Enumerate devices via `kAudioHardwarePropertyDevices` on
  `kAudioObjectSystemObject`.
- Match the first device whose `kAudioObjectPropertyName` contains
  "Scarlett 18i20" (case-insensitive substring match).
- If none found, print an error to stderr and exit non-zero.

## Sample rate

- Read/write `kAudioDevicePropertyNominalSampleRate`
  (`Float64`, scope `kAudioObjectPropertyScopeGlobal`).
- List supported rates via
  `kAudioDevicePropertyAvailableNominalSampleRates`
  (array of `AudioValueRange`; use `mMinimum` for each discrete entry).

## Bit depth

- A device exposes separate stream lists for input and output
  (`kAudioDevicePropertyStreams`, scope `kAudioObjectPropertyScopeInput`
  / `kAudioObjectPropertyScopeOutput`). Bit depth is a property of each
  stream's physical format, not the device.
- Current bit depth: read `kAudioStreamPropertyPhysicalFormat`
  (`AudioStreamBasicDescription.mBitsPerChannel`) from the first stream
  found (input or output — Scarlett interfaces keep both in sync).
- Available bit depths: read
  `kAudioStreamPropertyAvailablePhysicalFormats` for every stream
  (input + output), collect distinct `mBitsPerChannel` values, and
  intersect across streams so only depths valid on all of them are
  offered.
- Setting a bit depth: for each stream (input and output), find the
  available physical format entry matching the **current nominal
  sample rate** and the requested bit depth, and set it via
  `kAudioStreamPropertyPhysicalFormat`. If no such combination exists
  for a stream, fail with an error naming the unsupported
  rate/bit-depth pairing.

## CLI surface

```
scarlett-audio status
    Prints device name, current sample rate, current bit depth,
    and the full lists of supported values for each.

scarlett-audio set-rate <hz>
    Sets the nominal sample rate, then re-reads it and prints
    ✅/❌ against the requested value.

scarlett-audio set-bits <bits>
    Sets the bit depth on all streams, then re-reads and prints
    ✅/❌ against the requested value.

scarlett-audio set --rate <hz> --bits <bits>
    Sets both (rate first, then bit depth against the new rate),
    verifying each independently.
```

Any unrecognized command/flag prints usage to stderr and exits
non-zero.

## Verification

Every `set-*` operation re-reads the property immediately after
writing it. Since hardware clock changes aren't always instantaneous,
poll the readback (short interval, ~200ms, up to a 2s timeout) until
it matches the requested value or the timeout elapses, then print a
✅ (matched) or ❌ (mismatch, showing requested vs. actual) line.
Exit code reflects verification success, not just a non-error HAL
call, so scripting `&&` on this tool is meaningful.

## Error handling

Every Core Audio call checks its returned `OSStatus`; a non-zero
status is surfaced as a human-readable error (status code + the
property/operation that failed) on stderr, with a non-zero process
exit code.

## Build & install

SwiftPM package with the executable **product** named `scarlett-audio`
and the target/**module** named `ScarlettAudio` (Swift module names
cannot contain hyphens):

- `Sources/ScarlettAudio/CLI.swift` — argument parsing (pure)
- `Sources/ScarlettAudio/AudioFormatLogic.swift` — rate/bit-depth list
  math and tolerance comparison (pure)
- `Sources/ScarlettAudio/CoreAudioHAL.swift` — Core Audio property
  get/set wrappers (I/O)
- `Sources/ScarlettAudio/Verification.swift` — readback polling (I/O)
- `Sources/ScarlettAudio/main.swift` — dispatch and output formatting

The pure/I/O split is what makes the logic unit-testable without the
hardware attached.

Build: `swift build -c release` → binary at
`.build/release/scarlett-audio`. No install step required; the user
can copy it onto their `PATH` if desired.

## Testing

The pure logic (argument parsing, rate/bit-depth list math, tolerance
comparison) is unit-tested with XCTest and runs without hardware.

The Core Audio wrappers are hardware/OS-API bound — no meaningful unit
tests without the physical interface attached. Those are verified
manually: run each subcommand with the 18i20 connected, and cross-check
results against Audio MIDI Setup.

## Out of scope

- GUI.
- Support for devices other than by-name substring match.
- Gain, routing, or any other interface control beyond sample rate and
  bit depth.
