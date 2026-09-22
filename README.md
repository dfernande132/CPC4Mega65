Amstrad CPC for MEGA65 (CPC4MEGA65)
===================================

A port of the **Amstrad CPC 6128** to the **MEGA65**, built on top of the
[MiSTer2MEGA65](https://github.com/sy2002/MiSTer2MEGA65) (M2M) framework and
based on the
[MiSTer-devel/Amstrad_MiSTer](https://github.com/MiSTer-devel/Amstrad_MiSTer)
core (`T80pa` Z80 CPU, `ga40010` gate array, `UM6845R` CRTC, `YM2149` PSG,
`i8255` PPI, `u765` uPD765 floppy controller).

**Current status: version 1.0**, for MEGA65 R3 and R6. The CPC 6128 boots
end-to-end on real MEGA65 hardware with working keyboard, video, sound,
joystick and two `.DSK` disk drives. What makes this port unusual is that
**the MEGA65's internal 3.5" floppy drive works as a real CPC drive** - it
reads genuine CPC disks, formats them, writes `.DSK` images onto physical
disks, and writes changed tracks back. All of that is confirmed
on real hardware against a real CPC 6128: a disk formatted on the MEGA65 is
read by the CPC, and a game copied on the MEGA65 boots on the CPC.

See `.research/PORTING-PLAN.md` for the technical plan the port was built
against, and `doc/m2m/exceptions.md` for every change made to the framework and
to the MiSTer core, each with the reasoning behind it.

*(Comments in the source refer to `DECISIONES.md`, a day-by-day development log
kept outside this repository. It is not published; where a decision matters to
someone reading the code, the reasoning is in the comment itself.)*

Feature overview
----------------

- **Machine**: Amstrad CPC 6128 (128 KB RAM), PAL video, Locomotive-compatible
  keyboard mapping on the MEGA65 keyboard, and joystick support with
  swappable ports.
- **ROMs are not included.** The core loads three mandatory 16 KB files from
  `/cpc4mega65/` on the SD card - `os6128.rom`, `basic6128.rom` and
  `amsdos.rom` - and does not boot without them. They are Amstrad firmware
  and are not mine to distribute. If one is missing, the core names the file
  it could not find rather than failing silently.
- **Disk drives**: two virtual drives, `Drive A:` and `Drive B:`, each able to
  mount a `.DSK` or `.EDSK` image from the SD card - exactly like any other
  MiSTer2MEGA65 core.
- **Real floppy drive**: either virtual drive can be replaced by the MEGA65's
  own internal 3.5" drive. See the next section; this is the headline feature.
- **Video**: CRT emulation, 4:3 / 5:4 / 16:9 HDMI aspect ratios, HDMI zoom.
- **Audio**: audio improvement filter.
- **Settings are remembered** across power cycles, with one deliberate
  exception: see "Actions are never remembered" below.

The real floppy drive
---------------------

Set `Internal floppy` to `Drive A:` or `Drive B:` in the Options menu and that
drive stops being an image and becomes the physical 3.5" drive in your MEGA65.
Everything below happens on genuine CPC DATA-format disks (40 tracks, single
sided, 9 x 512-byte sectors, IDs `&C1`-`&C9`).

| Menu item | What it does |
|---|---|
| `Read disk now` | Reads the whole disk and builds a `.DSK` image in memory that the CPC then sees as a normal drive. About 26 seconds. |
| `FORMAT WHOLE DISK !!` | Formats all 40 tracks in CPC DATA format. **Destroys the disk.** |
| `COPY IMAGE TO DISK !!` | Writes the `.DSK` mounted in the *other* drive onto the physical disk. **Destroys the disk.** |
| `WRITE BACK TO DISK !!` | Writes back only the tracks the CPC has modified since the last read. |
| `Auto write-back` | Does the same automatically, one second after the CPC stops writing. |

### What the LED tells you

The MEGA65's drive LED is the main feedback channel, and it is deliberately
blunt - it answers "did it work?", not "what happened":

- **Blinking** while an operation is running.
- **Green** for half a second when an operation finished correctly.
- **Amber** for half a second when it finished badly: unreadable tracks, or
  nothing written, or **no disk in the drive**.
- **Red** for half a second when the drive refused: the disk is
  write-protected, or the image cannot be copied (see "Known issues").
- **Amber, steady** while there are still modified tracks that have not been
  written back yet. **Do not eject the disk while the LED is amber.** No
  timer can promise you a safe moment; a "not yet" signal can.

### Actions are never remembered

`Read disk now`, `FORMAT`, `COPY` and `WRITE BACK` are *actions*, not
settings. They are cleared every time the core starts, on purpose: the
framework's settings file stores every menu bit alike, so without this a core
that was switched off with `FORMAT` ticked would format whatever disk was in
the drive at power-on. `Internal floppy` and `Auto write-back` *are*
remembered, because those are states.

Actions also untick themselves as soon as the operation ends, so you never
have to remember to clear them before running the same one again.

Known issues
------------

### What the copier can and cannot reproduce

`COPY IMAGE TO DISK !!` reproduces what it can reproduce *exactly*, and
refuses the rest rather than writing a disk that looks finished and is not.

It handles sector sizes from 128 to 8192 bytes, tracks of up to ten sectors,
tracks written without an index mark, and the things copy-protected originals
use to tell an original from a copy: deleted data marks, sectors with no data
field at all, and data CRCs that are deliberately wrong. Reproducing those
faults *is* copying faithfully - correcting them would break the disk, which
is why the telemetry counts them separately from real errors.

Tracks marked unformatted are skipped, which is what "unformatted" means.

Two things it cannot do, and both are properties of the file rather than of
the format:

- An image whose own signature has bit flips is not recognised as a `.DSK`.
- A track whose sector headers share one physical data area, each declaring a
  different length, cannot be rebuilt from an EDSK at all: the file records
  what the controller *returned*, not what is *on the disk*. Copying the
  original disk itself would need a flux-level controller, which is on the
  roadmap.

When the copier refuses, the LED goes red and the telemetry dump records
exactly which rule was broken.

### Other known issues

- **`Dump telemetry` is no longer in the menu.** It overwrites the mounted
  `.DSK` file, which is what it is for, but that is not something an
  end-user menu should offer. The mechanism is still in the core and can be
  put back with a one-line change when a disk problem needs diagnosing at a
  distance.
- **Switching the drive off mid-write leaves a half-written track.** Closing
  the write gate immediately is the correct thing to do, but the track that
  was being written is lost. Let the operation finish.
- Only the CPC **6128** is implemented. The 464 and 664 are on the roadmap.
- No tape support yet; see `ROADMAP.md`.

Some things that are the way they are on purpose
-------------------------------------------------

### Reading a physical disk needs no `.DSK` file, but copying one does

`Read disk now` builds the image in memory from nothing. `COPY IMAGE TO
DISK !!` is the opposite direction and needs a source, so the *other* drive
has to have a real `.DSK` mounted - if `Internal floppy` is `Drive A:`, the
copier reads from `Drive B:`.

### The whole image is validated before the head moves

The copier checks every track and every sector header of the source image
before it opens the write gate once. A disk is either copied or left
untouched; it is never left half-overwritten because the copier discovered a
problem on track 30.

### Write-back is per track, not per disk

Only the tracks the CPC actually modified are written back, and a track that
could not be read completely is never written back at all - the in-memory
image does not hold its true contents, so writing it would punch holes in a
disk that was fine.

Building
--------

The project targets Vivado 2022.2 and builds for MEGA65 R6 with:

```
vivado -mode batch -source CORE/build_core.tcl
```

The build script checks timing after implementation and **fails the build on
negative slack**, because Vivado will happily write a bitstream that does not
meet timing and the resulting core fails erratically on real hardware.

The QNICE Shell firmware is reassembled automatically at the start of
synthesis (`CORE/m2m-rom/synth_pre.tcl`), which also regenerates the menu
index constants from `CORE/vhdl/mega65.vhd`, so a menu change can never leave
a stale index behind in the firmware. If the QNICE toolchain is missing - almost always a
clone without `git submodule update --init --recursive` - **the build stops**
instead of falling back on the `m2m-rom.rom` that is already in the tree. That
matters more than it sounds: a stale firmware passes timing cleanly, because
the contents of an initialised BRAM never touch the critical path, and the only
symptom is menu lines that do somebody else's job.

Credits
-------

See `AUTHORS`. In short: the Amstrad CPC hardware is Amstrad plc's, the
MiSTer core is the MiSTer Development Team's, the framework is
MiSTer2MEGA65's, and the MEGA65 port is mine. No Amstrad ROMs are included.



