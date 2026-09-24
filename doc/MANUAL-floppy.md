CPC4MEGA65 - Manual for the test build (M4056)
==============================================

An Amstrad CPC 6128 for the MEGA65. This manual covers the **internal floppy
drive**, which is what this build is about. Everything else (video, sound,
keyboard, joystick, `.DSK` images from the SD card) behaves like any other
MiSTer2MEGA65 core.


1. Installing
-------------

1. Copy the `.cor` file for **your** board to the SD card and flash it the
   usual way. `..._r6.cor` for an R6, `..._r3.cor` for an R3.
2. Create a folder called `/cpc4mega65/` on the SD card.
3. **Put the three CPC ROM files in it.** The core does not boot without
   them - they are the Amstrad firmware and they are not mine to distribute,
   so you have to supply them yourself:

   | File | Size | What it is |
   |---|---|---|
   | `/cpc4mega65/os6128.rom` | 16 KB | CPC 6128 firmware / OS |
   | `/cpc4mega65/basic6128.rom` | 16 KB | Locomotive BASIC 1.1 |
   | `/cpc4mega65/amsdos.rom` | 16 KB | AMSDOS (the disk extension) |

   All three are mandatory. If one is missing the core tells you **which**
   file it could not find and stops - so if you get that screen, read the
   filename on it rather than guessing.

4. Copy the `m2mcfg` file into the same folder. That is where your settings
   are stored; without it nothing you change in the menu survives a power
   cycle.

Open the Options menu with the **Help** key.


2. The disks you can use
------------------------

### They must be 720K DD disks

The MEGA65 has a 3.5" HD drive. The CPC writes at double density, so:

- A **720K DD** disk works. That is what you want.
- A **1.44 MB HD** disk does **not**. The drive sees the second hole in the
  corner and switches itself to high density, and nothing will read or write
  correctly. **Cover that hole with a piece of tape** and the drive treats it
  as DD. This is the standard trick and it works, but a taped HD disk is less
  reliable than a real DD disk - if you have real DD disks, use those.

### What format gets written

CPC **DATA** format: 40 tracks, one side, 9 sectors of 512 bytes per track,
sector IDs `&C1` to `&C9`. That is 178 KB free, which is what a real CPC
reports after formatting.

A disk written by the MEGA65 is a **3.5"** disk. A standard CPC 6128 has a
**3"** drive, so to use one of these on a real CPC you need a 3.5" drive
attached to it (normally as `B:`).


3. Turning the internal drive on
--------------------------------

In the Options menu, go into **`Internal floppy`**. Inside you choose which of
the CPC's two drives the physical drive takes over:

```
  Off        <- default: both drives are .DSK images from the SD card
  Drive A:   <- the physical drive becomes the CPC's A:
  Drive B:   <- the physical drive becomes the CPC's B:
```

The other drive keeps working as a normal `.DSK` image. That matters for
copying: **the copier reads from the drive that is NOT the physical one.**


4. Reading a disk
-----------------

**You must do this once every time you insert a disk.** Until you do, the CPC
sees an empty drive.

1. Put the disk in.
2. Options menu -> `Internal floppy` -> **`Read disk now`**.
3. Wait. It takes about **26 seconds** - it reads all 40 tracks. The LED
   blinks while it works.
4. The LED flashes **green** and the option unticks itself. The CPC can now
   use the disk: `CAT`, `RUN"..."`, everything.

You can close the menu while it works; the drive stops on its own when it
finishes.

*(Reading automatically when a disk is inserted is planned, but it is not in
this build.)*


5. Formatting a disk
--------------------

**This destroys everything on the disk. There is no undo.**

1. Put the disk in and set `Internal floppy` to `Drive A:` or `Drive B:`.
2. Tick **`FORMAT WHOLE DISK !!`**.
3. The LED goes **white** while it writes, track by track. It takes about ten
   seconds.
4. A **green** flash means it worked. Do `Read disk now` afterwards, or put
   the disk in a real CPC and `CAT` it - you should see 178 KB free.

If the LED flashes **red**, the disk is write-protected: move the tab in the
corner. If it flashes **amber** after about a second, there is no disk in the
drive.


6. Copying a `.DSK` onto a real disk
------------------------------------

**This also destroys everything on the target disk.**

The idea: the image comes from one drive, the physical disk is the other.

1. Set `Internal floppy` to **`Drive A:`**.
2. Mount the `.DSK` you want to copy in **`Drive B:`** (the normal way, from
   the SD card).
3. Put a blank or expendable disk in the MEGA65's drive.
4. Tick **`COPY IMAGE TO DISK !!`**.
5. White LED while it writes, then a **green** flash.

It works the other way round too: internal drive as `B:`, image mounted in
`A:`. The rule is simply that the image must be in the *other* drive.

The whole image is checked before the drive writes a single byte, so if
something is wrong you get a **red** flash and an untouched disk - never a
half-overwritten one.

### If it refuses (red flash)

**First, check the write-protect tab on the target disk.** That is the most
common reason by far, and the red flash means exactly that.

If the disk is writable and it still refuses, the image uses a format the
copier cannot reproduce yet - an unusual sector size, for example. Out of 26
images from a real collection, 8 are refused today, and most of those are
formats that are being added rather than hard limits: a 10-sector 200 KB
Ocean disk already copies. The telemetry dump records exactly which rule was
broken.

One case is a genuine hard limit: a disk whose sector headers share one
physical data area, each declaring a different length. An EDSK records what
the controller *returned*, not what is *on the disk*, so no writer can
rebuild that from the file.

Disks with **unformatted** tracks are fine - those tracks are simply skipped,
which is what "unformatted" means.


7. Saving your work back to the disk
------------------------------------

When the CPC writes to a disk (a `SAVE`, for instance), the change goes into
the image in memory. To get it onto the physical disk:

- **`WRITE BACK TO DISK !!`** writes back the tracks the CPC changed, right
  now. Only those tracks, not the whole disk.
- **`Auto write-back`** does the same by itself, one second after the CPC
  stops writing. Leave this on and you can mostly forget about it.

A track that could not be read completely when you did `Read disk now` is
never written back - the image does not hold its true contents, and writing
it would punch holes in a disk that was fine.


8. The drive LED
----------------

The LED is the main thing telling you what happened.

| LED | Meaning |
|---|---|
| **blinking** | working |
| **white** | writing to the disk right now (format or copy) |
| **green flash** | finished, all good |
| **amber flash** | finished badly: unreadable tracks, nothing written, or **no disk in the drive** |
| **red flash** | refused: write-protected disk, or an image that cannot be copied |
| **steady amber** | there are still changed tracks not written to the disk yet |

**Do not eject the disk while the LED is steady amber.** No timer can promise
you a safe moment; that signal can.

A quick way to tell "no disk" from a real failure: with no disk the operation
ends in about a second instead of twenty-six.


9. Things worth knowing
-----------------------

- **Actions are never remembered.** `Read disk now`, `FORMAT`, `COPY` and
  `WRITE BACK` are cleared every time the core starts, on purpose - a core
  switched off with `FORMAT` ticked would otherwise format whatever disk was
  in the drive at power-on. `Internal floppy` and `Auto write-back` *are*
  remembered, because those are settings.
- **Actions untick themselves** when the operation ends, so you can run the
  same one again without clearing it first.
- **Do not switch the drive off in the middle of a write.** The write gate
  closes immediately, which is correct, but that track is lost.
- Only the CPC **6128** is implemented. No tape yet. The 464, the 664 and
  tape support are on the roadmap.


10. If something goes wrong
---------------------------

Three things identify most problems on their own:

1. **Which MEGA65 you have**, R3 or R6.
2. **What the LED did.** The colour code above is deliberately blunt, but
   green, amber and red already separate "it worked", "it finished badly" and
   "the drive refused" - and those are three completely different kinds of
   problem to chase.
3. **Which disk**, if a particular one is involved. If it is a `.DSK` file you
   can send, better still: most copier refusals are properties of the file
   rather than of your hardware, so they can be reproduced here without the
   disk ever leaving your house.

There is also a diagnostic dump inside the core. It records what the floppy
subsystem actually saw - which tracks read, how many sectors each one gave,
CRC errors, how long the write gate was open, and exactly which rule refused
an operation. **It is not in the menu in version 1.0**: the way it gets the
data out is by overwriting the mounted `.DSK` file, which is not something an
end-user menu should be offering. The mechanism is still in the core and comes
back with a one-line change, so if a problem needs it, say so and you will get
a build that has it.
