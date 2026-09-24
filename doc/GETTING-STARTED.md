# Amstrad CPC on the MEGA65 — first steps

For people who have never used a CPC. If you come from a Commodore machine,
most of what you know transfers; the handful of places where it does not are
marked **TRAP**.

---

## 1. Before you start: you need three ROM files

The core does **not** include the Amstrad firmware, so you have to supply it.
Create a folder `/cpc4mega65/` on your SD card and put these three files in
it:

| File | Size | What it is |
|---|---|---|
| `os6128.rom` | 16 KB | the CPC 6128 firmware   (English, French, Spanish...) |
| `basic6128.rom` | 16 KB | Locomotive BASIC 1.1 (English, French o Spanish) |
| `amsdos.rom` | 16 KB | AMSDOS 0.5 , the disk extension |

**Where to get them:** https://www.cpcwiki.eu/index.php/ROM_List

If one is missing the core will not boot, and it tells you *which* file it
could not find. Read the filename on that screen rather than guessing.

Also copy the `m2mcfg` file that comes with the core into the same folder,
or your settings will not be remembered.

---

## 2. Getting software

CPC programs come as **`.DSK`** files (disk images). Put them anywhere on the
SD card, then in the core's Options menu (the **Help** key) choose
`Drive A:` and pick the file.

**Where to find `.DSK` files:** https://archive.org/download/AmstradCPCGameCollectionByGhostware

---

## 3. The four commands you actually need

The CPC boots into BASIC with a `Ready` prompt, like a C64. From there:

```
CAT              list what is on the disk
RUN"NAME         load and run a program
LOAD"NAME        load a BASIC program without running it
|CPM             boot CP/M, if the disk has it
```

That is genuinely most of it. `LIST`, `NEW`, `RUN` and `SAVE` behave the way
you expect.

**TRAP — the closing quote is optional, and nobody types it.**
`RUN"GAME` works. So does `RUN"GAME"`. You will see both in listings.

**TRAP — `CAT` is not `LOAD"$",8`.** There is no directory-as-a-program
trick here. `CAT` prints the catalogue directly and does not disturb the
program in memory.

**TRAP — file names are 8 characters plus a 3-character extension**, and the
extension is usually implied. `RUN"GAME` will find `GAME.BAS` or `GAME.BIN`.

**CPM** —  You can get the 4 disks at https://www.cpc-power.com/index.php?page=detail&onglet=dumps&num=4174 Then insert the first one into drive A and type |CPM

---

## 4. The bar character `|`, and why you need it

Commands that talk to the disk system start with a vertical bar: `|CPM`,
`|A`, `|B`, `|ERA`, `|REN`, `|DIR`. On a CPC that character is **SHIFT + @**.

**On the MEGA65 keyboard it is also SHIFT + @.**

This is the single thing that stops people dead, because `|` is not where a
Commodore user expects it and none of the disk commands work without it.

```
|A        switch back to drive A:
|B        switch to drive B:
|ERA,"NAME.BAS"    erase a file
|CPM      boot CP/M from the current disk
```

---

## 5. Two screen messages that look like failures and are not

**`Drive A: disc missing, Retry, Ignore or Cancel`**
There is no disk in the drive, or the image is not mounted. Mount a `.DSK`
in the Options menu, then press `C` for Cancel and try again.

**A `CAT` that prints something odd instead of a file list**
Some commercial disks — Ocean titles especially — do not use a standard
catalogue; they hold a loader and a message instead. That is the disk being
itself, not a fault. Just `RUN"` whatever the disk or its documentation says.

---

## 6. Other differences worth knowing

- **Reset:** `CTRL` + `SHIFT` + `ESC` restarts the CPC, like a C64's
  RUN/STOP+RESTORE only more so.
- **Screen modes:** `MODE 0` is 160x200 in 16 colours, `MODE 1` is 320x200 in
  4, `MODE 2` is 640x200 in 2. Programs set this themselves; you rarely need
  to.
- **Two drives:** the CPC supports `A:` and `B:`, and this core gives you
  both. Use `|B` to switch.
- **No `,8,1`.** Loading an address-specific binary is `RUN"NAME` as well;
  AMSDOS works out where it goes.
- **Lower case:** the CPC boots in lower case and BASIC keywords work in
  either case. Typing `cat` is fine.

---

## 7. This core can also use the MEGA65's real floppy drive

Set `Internal floppy` in the Options menu and the MEGA65's own 3.5" drive
becomes a real CPC drive: it reads genuine CPC disks, formats them, and
writes `.DSK` images onto physical disks.

That has its own manual, because it can destroy disks if you point it at the
wrong one. If you just want to play games from the SD card you can ignore it
entirely — leave `Internal floppy` set to `Off`, which is the default.

---

*Core by dfsantos. Based on MiSTer-devel's Amstrad core and the
MiSTer2MEGA65 framework. The Amstrad firmware is not included and is not
mine to distribute.*
