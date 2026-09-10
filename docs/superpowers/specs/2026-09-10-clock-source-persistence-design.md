# Clock Source Persistence — Design

**Date:** 2026-09-10
**Status:** Draft — awaiting review

## Purpose

Let `scarlett-audio` persist the clock source into the interface's own
flash, so the 18i20 comes up on the chosen source when powered with no
computer attached. This restores the one capability lost when Focusrite's
Scarlett MixControl stopped working.

## Context

`set-clock` today writes the Core Audio HAL clock source. That is the
*driver's* live state: it does not survive a power cycle, which is why a
reset or power-cycle silently puts the interface back on Internal and the
Kemper's S/PDIF path starts clicking.

The Gen 1 protocol is documented in Linux `sound/usb/mixer_scarlett.c`,
reverse engineered from MixControl traffic. It is reachable from macOS
userspace: `libusb_open` succeeds on this device even though AppleUSBAudio
holds it, with no root and no entitlements.

Verified against the hardware on 2026-09-10 (USB `1235:800c`):

- Clock source reads and writes work on **interface 0**.
- The save command is accepted and **writes the device's power-on config**.
  Proven by a discriminating test: saved ADAT while leaving the live value
  on Internal, power-cycled, and the device came up ADAT. That rules out
  "Internal is simply the factory default", which the previous, weaker test
  could not.
- The device does **not** retain its live working state. Only an explicit
  save survives a power cycle.
- macOS overwrites the clock source ~410 ms after enumeration with its own
  remembered value.

Focusrite's support documentation states that "Save to Hardware" is a patch
slot and that closing MixControl is what arms standalone mode. The
measurement contradicts this for the 18i20; the measurement is what this
design trusts.

## Protocol

All requests target **interface 0**. `bmRequestType` is class/interface,
direction as shown.

```
clock source  (r/w)  bRequest=0x01  wValue=0x0100  wIndex=(0x28<<8)|0
                     1 byte: 1=Internal 2=S/PDIF 3=ADAT
save to flash (w)    bRequest=0x03  wValue=0x005a  wIndex=(0x3c<<8)|0
                     1 byte: 0xa5
```

## Approach

`--save` does not need a USB write path for the setting itself. The save
command snapshots whatever the device currently holds, and Core Audio's
clock write lands in the same device register — the first probe read `0x02`
off the device while Core Audio had it on S/PDIF. So `set-clock` keeps using
the existing, verified Core Audio code, and USB is used only to commit.

This keeps the new surface to one component and avoids reimplementing a
code path that already works and is already tested.

## Non-goals

- Persisting sample rate. Unit `0x29` is unverified; the reads that failed
  did so while the control pipe was wedged, so nothing is known either way.
- Routing matrix, monitor mixes, pad, impedance. The protocol supports them;
  they are a separate, much larger project.
- Reading the saved config back from the device. See Limitations.

## Component: `Sources/ScarlettAudio/DeviceSave.swift`

Single responsibility: commit the device's current configuration to flash.

- `findDevice()` — locate USB `1235:800c`.
- `saveToHardware()` — open, send the one control transfer, close.

Interface 0 is hard-coded. Interface 5 is unreachable by construction, not
by convention — see Hazards.

## Package.swift

Add a `systemLibrary` target `CLibUSB` with a module map, resolved by
pkg-config (`libusb-1.0`). The existing executable target gains a dependency
on it. `README` documents `brew install libusb` as a build requirement.

## CLI surface

```
scarlett-audio set-clock spdif --save
scarlett-audio save
scarlett-audio status
```

- `set-clock <source> [--save]` — sets the live source as today; with
  `--save`, also commits it.
- `save` — commits whatever the device currently holds. Its help text states
  plainly that it captures the device's entire configuration, not just the
  clock source. To populate the cache it first reads the current clock source
  through the existing Core Audio status path, and records that; if that read
  fails the save is still attempted and the cache is left untouched rather
  than written with a guess.
- `status` — gains one line, rendered from the local cache:
  `Last saved by this tool: S/PDIF (2026-09-10 14:02)` or `unknown`.

## Ordering

For `set-clock <source> --save`:

1. Existing Core Audio path sets the source and verifies by readback.
2. **Only on verified success**, send the save transfer.
3. **Only on save success**, update the cache.
4. Exit code reflects all three.

We never persist a state we failed to set. A failed save leaves the live
setting applied and exits non-zero, preserving the README's promise that
`&&` chaining is meaningful.

## The same-value early return

`runSetClock` deliberately skips the Core Audio write when the requested
source is already selected, because Core Audio rejects writing a clock
source to the value it already holds. **That early return must not skip the
save.**

`set-clock spdif --save` while already on S/PDIF is precisely the case where
someone is trying to persist an existing setting, and it is the most likely
way this command will be run. The early return stays; the save must sit
outside it. This needs a regression test — the bug is silent when written.

## State cache

`~/Library/Application Support/scarlett-audio/last-saved.json`:

```json
{"source": "S/PDIF", "savedAt": "2026-09-10T14:02:00Z"}
```

Written only after a successful save. Rendered with wording that survives
the cache being stale — it reports what this tool last saved, never what the
device currently holds. A missing or unparseable file renders as `unknown`
and is not an error.

## Error handling

- **No Scarlett on USB** — distinct message from the existing "no Scarlett in
  Core Audio". The two genuinely differ; during development the device was
  repeatedly present in one and absent from the other.
- **`libusb_open` fails** — report the libusb error; exit non-zero.
- **Save stalls or times out** — exit non-zero, leave the cache untouched.
  **No retry loop.** A wedged control pipe does not recover without a
  replug, and `libusb_clear_halt` on endpoint 0 does not clear it; retrying
  only hides the problem.

## Testing

- Unit tests for `--save` and `save` argument parsing, alongside the
  existing `CLITests`.
- Unit tests for cache read/write, including missing and malformed files.
- A regression test that `--save` still commits when the clock source is
  already the requested value.
- The libusb transport is verified manually against the hardware, matching
  the convention the README already sets for the Core Audio wrappers.
- Acceptance test: `set-clock spdif --save`, power-cycle with USB unplugged,
  then confirm the device comes up on S/PDIF by reading it within ~400 ms of
  enumeration, before macOS overwrites it.

## Hazards

**Never send anything to interface 5.** It is the DFU (firmware) interface,
class `fe` / subclass `01`. A class read to it is a DFU_UPLOAD; during this
spike it wedged the control pipe and knocked the unit off the USB bus twice,
each time requiring a physical power cycle. `libusb_clear_halt` on endpoint 0
does not recover it. Do not enumerate or sweep interfaces — the driver source
names the correct one.

## Limitations

The saved configuration **cannot be read back**. The protocol as reverse
engineered provides a write-and-commit with no corresponding read;
MixControl's "Load From Hardware" implies one exists, but it is not in the
documented set. The only way to observe the stored value is to power-cycle
and read within the ~410 ms window before macOS overwrites it.

Consequences: `status` cannot truthfully report the device's saved state, and
the local cache is the best available substitute. Its wording must not imply
otherwise, and it will be stale if anything else writes the device.

## Open questions

- Does sample rate (unit `0x29`) persist across a save? Unverified. Relevant
  because a standalone box needs a stored rate and the Kemper's S/PDIF output
  is believed fixed at 44.1 kHz — worth settling before any follow-up work.
