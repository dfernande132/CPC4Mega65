CPC4MEGA65 Changelog
====================

Prerelease - Milestone 4 (2026-09-20)
-------------------------------------

First build handed to testers. The CPC 6128 runs end-to-end on real MEGA65
hardware and the machine's internal 3.5" drive works as a real CPC drive.

### The internal floppy drive

- **Read a real CPC disk** into a `.DSK` image in memory that the CPC then
  sees as an ordinary drive. No image file needed on the SD card.
- **Format** a disk in CPC DATA format, all 40 tracks. Verified by a real
  CPC 6128 reporting 178 KB free.
- **Copy** a mounted `.DSK` onto a physical disk. Verified by taking the
  result to a real CPC 6128 and booting the game from it.
- **Write back** the tracks the CPC modified, on demand or automatically one
  second after the controller goes quiet.
- The whole source image is validated before the write gate opens once, so a
  disk is either copied or left untouched - never half-overwritten.
- Tracks marked unformatted in an EDSK are skipped rather than refused.
  About one image in six has them.
- The drive LED reports the outcome: green for success, amber for a bad
  result or an empty drive, red for a refusal, and steady amber while
  modified tracks are still waiting to be written.

### The rest of the machine

- Amstrad CPC 6128, 128 KB RAM, PAL video over HDMI and VGA.
- MEGA65-native keyboard mapping.
- Two virtual drives from `.DSK`/EDSK images on the SD card.
- Joystick with swappable ports.
- CRT emulation, HDMI aspect ratio and zoom, audio improvement filter.
- Settings are remembered across power cycles.

### Safety

- **Menu actions are never restored from the settings file.** The framework
  saves every menu bit alike, so a core switched off with `FORMAT` ticked
  would have formatted whatever disk was in the drive at the next power-on.
  Actions are cleared at startup; configuration is kept.
- **Actions untick themselves when the operation ends**, and the drive stops
  immediately rather than waiting for the menu to be reopened.
- Reading with an empty drive no longer destroys the mounted image. It used
  to erase the in-memory `.DSK` before checking whether there was anything to
  replace it with.
- An empty drive ends the operation in about a second instead of leaving the
  motor running.

### Known issues

See `README.md`. In short: copy-protected disks cannot be copied and are
refused (a flux-level controller is planned for 1.5), `Dump telemetry` does
not untick itself and will be removed from the menu in 1.0, and only the
CPC 6128 is implemented.

### Framework

Built on MiSTer2MEGA65 V2.0.1. Three changes to shared framework files were
needed and are documented one by one in `doc/m2m/exceptions.md`, together
with the changes to the MiSTer core itself.
