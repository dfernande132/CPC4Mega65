CPC4MEGA65 Roadmap
==================

What is done, what is next, and - where it matters - *why* something is
ordered the way it is. Nothing here is a promise with a date attached; it is
the order the work is intended to happen in.

Done
----

- **Milestone 1 - Native CPC 6128 boot.** `T80pa` CPU, `ga40010` gate array,
  `UM6845R` CRTC, `YM2149` PSG, `i8255` PPI and the Amstrad MMU, with the
  MiSTer core's SDRAM replaced by FPGA BRAM, a MEGA65-native keyboard matrix
  translator, and PAL video over both HDMI and VGA.
- **Milestone 2 - Disk drives from `.DSK`/EDSK images.** Two virtual drives
  through the `u765` controller and the framework's `vdrives`, with
  persistent saving back to the SD card.
- **Milestone 3 - Joystick**, with swappable ports.
- **Milestone 4 - The MEGA65's internal 3.5" floppy drive as a real CPC
  drive.** MFM data separator, track formatter, whole-disk copier from a
  `.DSK` image, and per-track write-back, manual and automatic. Verified
  against a real CPC 6128 in both directions.

Next
----

### Storage

- **Automatic read when a disk is inserted.** Today you tick `Read disk now`.
  The drive can already tell us a disk changed; this is the first thing on
  the list after the prerelease because it removes the one step a user should
  never have had to take.

- **Milestone 5 - Serve tracks straight from the disk. Targeted at version
  1.5.** This is the big one, and what justifies it on its own is simple:
  **the 26-second pre-read goes away.**

  Today you tick `Read disk now`, the core reads all 40 tracks into an image
  in memory, and the CPC uses that image. Reading on demand instead - the
  drive answers the CPC as the sectors pass under the head - removes the
  pre-read, and with it the whole scaffolding that exists only because there
  is a copy in RAM: the write-back of modified tracks, the dirty-track map,
  and the automatic read on insertion.

  It turns out this is less work than it sounds. The `u765` in the MiSTer
  core is **already a rotational controller** - it times a byte every 32 µs,
  models a 205 ms revolution, and waits for the requested sector to come
  round - whose backend happens to be an image. So the command state machine,
  which is the expensive part, stays; what changes is where the sector list,
  the rotational position and the bytes come from.

  Copying protected originals is an *extension* of this, not its reason: once
  the flux is what we read and write, a disk is copied as it is rather than
  as a controller described it.

- **Milestone 6 - Tape (`.CDT`) and snapshots (`.SNA`).** The MiSTer core
  already carries `tzxplayer.vhd`. Snapshots pair naturally with tape because
  they let a game be started without waiting for a load.

### Hardware models

- **Milestone 7 - CPC 464 and 664.** Today the core is a fixed 6128. Model
  selection means different ROMs, different RAM, and the 464's cassette
  instead of a disk drive - which is part of why tape comes first.

### Expansion hardware

- **Dandanator** and **PlayCity** are present in the MiSTer core and left out
  of this port so far. Backlog, no milestone assigned.
- **Mouse** (AMX / Kempston). Backlog.

### Quality of life

- **Live status text in the Options menu** while a floppy operation runs.
  Designed and deliberately postponed: the LED already answers "did it work?",
  and adding a second channel that says the same thing is not worth the
  risk to a subsystem that is finally stable.
- **Remove `Dump telemetry` from the menu for version 1.0.** The mechanism
  stays - it is the only way to diagnose a user's disk problem remotely, and
  it has already earned its keep several times - but it overwrites the
  mounted image and has no business in an end user's menu.

Deliberately not planned
------------------------

- **RAM beyond 128 KB.** The 6128's 128 KB is what the core models; larger
  expansions are a different machine's worth of work for a small audience.
  Reconsider if someone asks with a concrete use.

Contributing back
-----------------

Three things found during this port belong upstream in MiSTer2MEGA65 rather
than in this repository, and are documented in `doc/m2m/exceptions.md`:

1. `FLUSH_CACHE` kills the core with a fatal error when a drive has no file
   behind it. The guard that should catch it can never fire, because of a
   double indirection in how the file handles are initialised.
2. **The settings file stores action bits exactly like configuration bits.**
   Any core with a destructive action in its menu will execute it at power-on
   if it was saved ticked. This one is not specific to the CPC.
3. A hook that gives the core's own firmware a time slice inside `HANDLE_IO`.
   The framework has hooks for what the *user* does and none for what the
   *core* does; a long-running action needs the second kind.
