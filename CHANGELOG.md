CPC4MEGA65 Changelog
====================

Version 1.0 (build M4061)
-------------------------

First release. An Amstrad CPC 6128 for the MEGA65, for **R3 and R6**.

### The machine

- Amstrad CPC 6128, 128 KB RAM, PAL video over HDMI and VGA.
- MEGA65-native keyboard mapping. The `|` used by every disk command is
  SHIFT + @, as on a real CPC.
- Two disk drives from `.DSK` / EDSK images on the SD card.
- Joystick, with swappable ports.
- CRT emulation, HDMI aspect ratio and zoom, audio improvement filter.
- Settings are remembered across power cycles - except menu *actions*, which
  are deliberately never restored (see below).
- The three CPC ROMs are loaded from `/cpc4mega65/` and are not included.

### The MEGA65's internal floppy drive as a real CPC drive

This is what makes the port unusual, and all of it is verified against a real
CPC 6128 in both directions.

- **Read** a genuine CPC disk into an image the CPC then uses as a normal
  drive. No file needed on the SD card.
- **Format** a disk in CPC DATA format. A real CPC reports 178 KB free.
- **Copy** a mounted `.DSK` onto a physical disk. A game copied on the MEGA65
  boots on a real CPC.
- **Write back** the tracks the CPC modified, on demand or automatically one
  second after the controller goes quiet.
- The whole source image is validated before the write gate opens once, so a
  disk is either copied or left untouched - never half-overwritten.
- Formats beyond the standard 9x512 DATA layout are supported where they can
  be reproduced exactly: a 10-sector 200 KB Ocean disk (R-Type) copies and
  behaves identically to the original, oddities included. Tracks marked
  unformatted are skipped, which is what "unformatted" means.
- The drive LED reports the outcome: green for success, amber for a bad
  result or an empty drive, red for a refusal, and steady amber while
  modified tracks are still waiting to be written.

### Safety

- **Menu actions are never restored from the settings file.** The framework
  saves every menu bit alike, so a core switched off with `FORMAT` ticked
  would have formatted whatever disk was in the drive at the next power-on.
  Actions are cleared at startup; configuration is kept.
- **Actions untick themselves when the operation ends**, and the drive stops
  immediately rather than waiting for the menu to be reopened.
- Reading with an empty drive does not destroy the mounted image, and ends in
  about a second instead of leaving the motor running.
- A write-protected disk is refused cleanly instead of hanging the core.

### Known limits

- Only the CPC **6128**. No tape yet. The 464, the 664 and tape are on the
  roadmap.
- **`Audio improvements` uses the framework's C64 filter coefficients.** The
  MiSTer Amstrad core defines no audio filter, so there were no correct values
  to copy. It is a harmless low-pass, but it models the wrong machine.
- **The copier reproduces what it can reproduce exactly, and refuses the
  rest** rather than writing a disk that looks finished and is not. That now
  includes sector sizes from 128 to 8192 bytes, tracks of up to ten sectors,
  tracks written without an index mark, and - for copy-protected originals -
  deleted data marks, sectors with no data field, and data CRCs that are
  deliberately wrong. Reproducing those faults *is* copying faithfully:
  correcting them would break the disk. In a test collection of 29 images,
  two are refused: one whose own signature has bit flips, and one with a
  track whose sector headers share a single physical data area, which no
  `.DSK` can describe. The telemetry records which rule was broken.
- Reading a *physical* disk into an image only supports the standard DATA
  format. Serving tracks straight from the disk - which removes the 26-second
  pre-read entirely - is Milestone 5, targeted at version 1.5.

### For the record

Built on MiSTer2MEGA65 V2.0.1 and MiSTer-devel's Amstrad core. Four changes
to shared framework files and three to the MiSTer core were needed, and each
one is documented with its reasoning in `doc/m2m/exceptions.md`.

Two bugs found here were in MiSTer2MEGA65 itself rather than in this core and
have been reported upstream: `FLUSH_CACHE` killing the core when a drive has
no file behind it, and the settings file restoring *action* menu bits at
power-on. A third, a register clobbered in `ROSM_SAVE` that froze the OSD
with two virtual drives, was already fixed in their development branch.

