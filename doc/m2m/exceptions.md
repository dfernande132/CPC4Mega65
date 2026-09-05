How to update CPC4MEGA65
=========================

The following changes have been made to the original MiSTer-devel/Amstrad_MiSTer
core. As soon as you update `CORE/Amstrad_MiSTer/`, make sure you re-apply the changes
described here. No shared MiSTer2MEGA65 framework file (`M2M/`) has been modified for
this milestone - only this one MiSTer core file.

MiSTer core Amstrad_MiSTer
--------------------------

### Removed the embedded "hid" instance from `rtl/Amstrad_motherboard.v` - replaced by `CORE/vhdl/keyboard.vhd`, a MEGA65-native matrix translator

The original `Amstrad_motherboard.v` instantiates `hid` (`rtl/hid.sv` - a PS/2-scancode-to-
CPC-matrix decoder that also handles joystick-as-keys and mouse) directly inside itself,
taking `ps2_key`/`ps2_mouse`/`joy1`/`joy2`/`right_shift_mod`/`keypad_mod` as top-level inputs
and producing the matrix internally (`Y` = row select from the i8255's `portC[3:0]`, `X` =
column data fed into the YM2149's `IOA_in`). `Amstrad_motherboard.v` was modified to:

* Remove the internal `hid HID(...)` instantiation.
* Remove six top-level ports that only fed `hid`: `joy1`, `joy2`, `right_shift_mod`,
  `keypad_mod`, `ps2_key`, `ps2_mouse` - and three top-level outputs `hid` used to drive:
  `key_nmi`, `key_reset`, `Fn` (NMI/reset-via-keyboard shortcuts and the F-key-with-Alt
  vector; none of the three defined milestones through M6 use them).
* Add two new top-level ports in their place: `kbd_row_o` (4 bits, out - what `portC[3:0]`
  used to feed straight into `hid`'s `Y` input) and `kbd_col_i` (8 bits, in - what `hid`'s
  `X` output used to drive into the YM2149's `IOA_in`).
* `assign kbd_row_o = portC[3:0];` replaces the removed `.Y(portC[3:0])` connection;
  `.IOA_in(kbd_col_i)` replaces the removed `.IOA_in(kbd_out)`. `joy1_sel`/`joy2_sel` (derived
  from `portC[3:0] == 9/6`, unrelated to `hid` itself) are untouched.

**What plugs into those two ports**: `CORE/vhdl/keyboard.vhd` - a MEGA65-native translator,
same architectural role as `keyboard.vhd` in QL4M65/C64MEGA65 (both of which replaced their
own core's PS/2-consuming keyboard submodule the same way, rather than synthesizing fake
PS/2 scancodes from MEGA65 key events). It maps `kb_key_num_i`/`kb_key_pressed_n_i` directly
to the real CPC row/column matrix (the exact row/column table was extracted from
`rtl/hid.sv`'s own PS/2-scancode case statement, not guessed or taken from external
documentation - see `core/.research/PORTING-PLAN.md`, section "M1B", for the full table and
what was deliberately left unmapped for M1: the CPC's dedicated numeric-keypad Enter/./Copy
keys, the `[ ] \` symbol keys, half of the keypad's F0-F9 shortcuts, and the row6/row9
joystick-as-keyboard overlay - none of which have a direct MEGA65 key or are needed to reach
the M1 boot criterion).

Files that stay in the repository but excluded from the Vivado compile list (not deleted):
`rtl/hid.sv` (its logic is re-implemented in `CORE/vhdl/keyboard.vhd`; it also contains the
unused `mouse_axis` submodule, since mouse support is backlog, not in any of the six defined
milestones).

When updating from a newer upstream `Amstrad_motherboard.v`: re-apply this same surgery -
find wherever `hid HID(...)` is instantiated, delete it and the six/three ports it exclusively
used, re-expose `kbd_row_o`/`kbd_col_i` the same way. `CORE/vhdl/keyboard.vhd` doesn't need to
change unless the ports themselves change or the real CPC matrix layout is found to differ
from what `rtl/hid.sv` encoded (unlikely - that file itself hasn't changed across MiSTer-devel
Amstrad_MiSTer history as far as this project has checked).

### `rtl/Amstrad_motherboard.v`: named the "video_fetch" always block (Vivado build fix, 2026-09-05)

**Symptom**: `[Synth 8-10632] declarations are not allowed in an unnamed block` on the
`always @(posedge clk) begin ... reg cas_n_old; ... end` block (video fetch pipeline,
originally around line 196) - legal SystemVerilog (unnamed blocks may declare local
variables), rejected by Vivado's stricter plain-Verilog-2001 parser. Same class of issue
QL4M65 hit in `zx8301.v`/`zx8302.v`/`mdv.v`, but **the usual fix (mark the whole file
SystemVerilog in `build_core.tcl`) does not work here**: this file instantiates `T80pa`
with a port named `.do(D)`, and `do` is a reserved SystemVerilog keyword (`do...while`) -
marking the file SystemVerilog turns that legal Verilog-2001 port association into a
syntax error (`[Synth 8-2716]`/`[Synth 8-10307]`).

**Fix**: gave the block a name (`always @(posedge clk) begin : video_fetch`) instead -
Verilog-2001 allows local declarations inside a *named* block, so this needed no
SystemVerilog reclassification at all, and doesn't touch anything else in the file
(`Amstrad_MMU.v`/`i8255.v`/`UM6845R.v` hit the identical unnamed-block issue on their own
`old_wr`/`old_we`/`vsc`+`vsync_allow` declarations, but none of them instantiate anything
with a `do` port, so those three were simply marked SystemVerilog in `build_core.tcl`
instead - a build-setting-only fix, no source change).

When updating from a newer upstream `Amstrad_motherboard.v`: re-apply the same block name if
the video-fetch `always` block (or any other block gaining a local declaration) is still
unnamed and Vivado flags it again - check first whether the file can simply be marked
SystemVerilog (cheaper), and only fall back to naming the block if a keyword collision like
`do` blocks that.

MiSTer2MEGA65
-------------

See `core/.research/PORTING-PLAN.md` section 4.2 for why the M1A memory subsystem redesign
did **not** require any framework or core file changes (it replaces `rtl/sdram.v`, excluded
wholesale from the build rather than modified, with two new `dualport_2clk_ram` instances in
`CORE/vhdl/main.vhd`/`mega65.vhd`, files the porter already owns per the Porting Guide, Part
III section 3.I.1).

### `M2M/vhdl/vdrives.vhd`: guarded the `img_mounted`/`cache_dirty`/`cache_flushing` CDC block against `VDNUM=0` (Vivado build fix, 2026-09-05)

**Symptom**: `ERROR: [Synth 8-6058] Synth Error: [XPM_CDC 5-4] WIDTH (0) is outside of valid
range of 1-1024` on `i_cdc_q2m_img_mounted` (an `xpm_cdc_array_single` instance,
`vdrives.vhd:237-250`), found on the first real Vivado build attempt of this project. CPC4MEGA65
has no floppy disk support yet (that's Milestone 2), so `globals.vhd` sets `C_VDNUM := 0` -
this is documented elsewhere in the Porting Guide as a supported, intentional configuration
("Milestone 1 del port del Amiga: C_VDNUM=0 ... "), but this specific CDC instance computes
its `WIDTH` generic as `3 * VDNUM`, which is exactly `0` when `VDNUM=0` - outside
`xpm_cdc_array_single`'s valid `WIDTH` range of 1-1024. The other two `xpm_cdc_array_single`
instances in the same file (`i_cdc_qnice2main`, fixed `WIDTH=35`; `i_cdc_main2qnice`,
`WIDTH = 1 + VDNUM`, minimum 1) don't have this problem.

**Fix**: wrapped the `i_cdc_q2m_img_mounted` instantiation in `if VDNUM > 0 generate ...
end generate` - when `VDNUM=0` there is nothing to synchronize anyway (every signal this CDC
touches is already a null-range `std_logic_vector(VDNUM-1 downto 0)` in that case), so
skipping the instance entirely is correct, not just a workaround for the width check.

**Why QL4M65/C64MEGA65/AExp never hit this**: verified by diffing this file against all three
projects' own copies (all cloned locally under `learning_cores/`) - none of them has the
`cache_dirty_o`/`cache_flushing_o` synchronization block (`i_cdc_q2m_img_mounted` and its
`WIDTH => 3 * VDNUM`) at all. It's a newer addition to upstream M2M, added after those three
projects pinned their own copy of `vdrives.vhd` and never updated it since. QL4M65 and AExp
both currently ship with `C_VDNUM = 0` too (confirmed in their own `globals.vhd`) - so this
isn't a case of them handling the edge case correctly, they simply never had the code that
has the bug. CPC4MEGA65 is (as far as this project has checked) the first of the four to
build against the current upstream `vdrives.vhd`, hence the first to hit it. Worth reporting
upstream at some point (not done yet, this is local-only per the user's "no GitHub yet" rule).

When updating from a newer upstream `vdrives.vhd`: re-check whether this has been fixed
upstream (search for `3 * VDNUM` near an `xpm_cdc_array_single` generic map); if the fix is
already there, drop this exception and remove the `generate` wrapper we added. If not, keep
the guard.

QNICE
-----

No changes.
