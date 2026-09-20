How to update CPC4MEGA65
=========================

The following changes have been made to the original MiSTer-devel/Amstrad_MiSTer
core, and to the shared MiSTer2MEGA65 framework (`M2M/`). As soon as you update
`CORE/Amstrad_MiSTer/` or the framework, make sure you re-apply the changes described here.

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

### `rtl/u765/u765.sv`: made the two internal sector/track buffers dual-clock (Milestone 2, 2026-09-06)

**Why**: in MiSTer, `u765` is a single-clock module - `clk_sys` drives both the FDC state
machine and the SD-card side. In M2M that split is not optional: the Porting Guide (Part III
section 3.I.3) states that `vdrives.vhd`'s `sd_lba`/`sd_rd`/`sd_wr`/`sd_ack`/`sd_buff_*` ports
run in the **QNICE clock domain**, not the core's, and it points at C64MEGA65's `iec_drive` as
the reference - a module that is dual-clock by design (`clk` = core, `clk_sys` = *"SD card
clock for writing to the drives' internal data buffers"*). QL4M65 reused MiSTer's `sd_card.sv`,
which has the same split built in (`clk_sys`/`clk_spi` plus an `altsyncram` buffer with
separate `clock0`/`clock1`). `u765` has no such second clock, so it had to be created.

**What changed** (three small edits, no state machine touched):

* `u765_dpram`: its single `clock` port became `clock_a` (SD side) and `clock_b` (FDC side).
  It was already a textbook inferred true-dual-port RAM, so Vivado infers a genuine
  dual-clock BRAM from it unchanged otherwise.
* `u765`: new top-level input `clk_sd`, wired **only** to `clock_a` of `tinfo_ram` and
  `sector_ram`. Everything else still runs on `clk_sys`.
* Three core-domain signals select where a port-A write lands (`sd_buff_type`, `tinfo_ds0`,
  `tinfo_hds`). Rather than synchronize them inside this file, they are exported as
  `sd_sel_o[2:0]` and come back already synchronized as `sd_sel_sd_i[2:0]`; the crossing
  itself is an `xpm_cdc_array_single` in `CORE/vhdl/main.vhd`. **This split is not stylistic
  and it is not optional** - see the note below.
* `sd_ack` became **two** ports, `sd_ack` and `sd_ack_sys`, because it has two consumers in
  two different domains - something that simply did not exist in MiSTer, where the whole
  module ran on one clock. `sd_ack` (QNICE domain, used as-is with no synchronizer) gates the
  write enable of the buffers' port A, which is clocked by `clk_sd`. `sd_ack_sys` (core
  domain, pre-synchronized outside by an `xpm_cdc_single`) feeds `sdcontrol`'s `ack` shift
  register. Feeding port A from the core-synchronized copy instead creates a *new* crossing
  into a QNICE-clocked BRAM's `ENBWREN` - a mistake this port actually made and measured
  (`WNS = -3.116 ns` on exactly that path, second M2 build).

**Why no synchronizer logic lives inside this file.** The first M2 build did it the obvious
way: plain 2-FF synchronizers written in RTL right here, plus letting `u765`'s existing
6-stage `ack <= {ack[4:0], sd_ack}` chain absorb the incoming `sd_ack`. Vivado reported
`WNS = -4.982 ns` with 8 failing endpoints, and the four large violations were *exactly* those
four hand-written crossings. A synchronizer written as ordinary RTL carries no timing
exception with it, so the analyzer treats the crossing as a synchronous path and demands a
phase relationship between `main_clk` (64 MHz) and `qnice_clk` (50 MHz) that does not exist.
Worse, the `ack` shift register was synthesized as an **SRL** (a LUT-based shift register, not
adjacent flip-flops), which is not a valid metastability filter at all. The one crossing that
did *not* appear in the violation list was the one already using `xpm_cdc_array_single` - the
XPM macros ship their own `set_max_delay -datapath_only` constraints. So every core/QNICE
crossing of the FDC now lives in `main.vhd` as an XPM macro, and this file keeps zero CDC
logic and zero Xilinx-specific code (it gains two ports instead, which stays portable).

**What deliberately did NOT change**: the `sdcontrol` block stays in the core clock domain.
Its handshake with the `fdc` block is a *level held until acknowledged* protocol with
turnarounds measured in microseconds (`u765.sv` around lines 1143-1151 and 235-238), so
leaving both blocks in the same domain means no CDC is needed there at all. The only thing
that genuinely forces a domain change is the byte pump, because the QNICE firmware sets
`sd_buff_addr` and reads `sd_buff_din` combinationally in the same access - a round trip that
cannot be synchronized without a per-byte handshake. Making the buffer dual-clock removes that
round trip entirely, which is exactly what `sd_card.sv` does. `sd_ack` is now pre-synchronized
into the core domain by an `xpm_cdc_single` in `main.vhd`, so the existing 6-stage `ack` chain
becomes a plain same-domain edge filter, which is all it was ever good for.

Full reasoning, including the two designs that were considered and rejected, is in
`core/.research/PORTING-PLAN.md` section 9.

When updating from a newer upstream `u765.sv`: re-apply the same three edits. If upstream ever
gains its own second clock for the SD side, drop this exception and use theirs instead.

Also note that `main.vhd` re-implements the FDC bus glue that lives in the original top-level
`Amstrad.sv` (address decode `fdc_sel`, `io_rd`/`io_wr`, the motor latch and the `ready`
flags, `Amstrad.sv:732-780` and `959-960`), because this port instantiates
`Amstrad_motherboard` directly and never uses `Amstrad.sv`. That is new code on our side, not
a modification of a MiSTer file, but it needs re-checking against upstream in the same way.

### `rtl/u765/u765.sv`: track-info cache invalidation from outside (`tinfo_flush`) and a state readout (Milestone 4, 2026-09-17)

**Why**: this port rewrites the mounted disk image **in RAM, behind the module's back** -
`CORE/vhdl/floppy_dsk.vhd` fills the mount buffer with an image built from the physical
floppy - and `u765` caches the per-track sector list (`i_secinfo_valid` /
`image_trackinfo_dirty`), invalidating it only when an image is mounted. Without telling it,
it keeps using the sector list of the **previous** image. A real CPC `.dsk` stores its
sectors in physical, interleaved order (Bruce Lee: `C1 C6 C2 C7 C3 C8 C4 C9 C5`) while we
place ours in logical order, so the result is a **fixed permutation**: some directory entries
correct and the rest garbage, identical on every attempt.

**What changed** (two small additions, no state machine touched):

* New input `tinfo_flush`. The request is **latched** into `tinfo_flush_pend` and applied
  only while `!tinfo_lock && state == COMMAND_IDLE`, after which
  `image_trackinfo_dirty` is set and `i_secinfo_valid` cleared - the same path the module
  itself uses when changing track, so it cannot deadlock.
* New output `dbg_state` (16 bits, registered): `image_ready`, `i_scan_lock`,
  `tinfo_lock`, idle, `image_edsk`, `image_trackinfo_dirty`, the pending request,
  `image_scan_state` for both units and `i_secinfo_valid`. Purely an observation surface;
  nothing reads it inside the module.

**Why the latch is not stylistic.** The first attempt (build M4015) drove the invalidation
straight in and **held it for ~4 us** from outside. That gave `Read fail` with an EDSK
mounted and, in M4016, hung even the case that previously worked: holding it restarts
sequences that are in flight. The mechanism was right, the delivery was not.

Note also that the first attempt looked wrong for a second reason that had nothing to do with
this file: our own track-0 header was being written one slot late (`floppy_scan.vhd`, fixed
in M4021), so forcing `u765` to read our headers exposed a header full of `0xE5`. Both
causes had to be closed before this could work.

**What deliberately did NOT change**: `img_mounted` handling, the mount scan, the offsets
table and everything about `image_edsk`. Simulating a fresh mount by pulsing `img_mounted`
was tried (build M4014) and **hung the drive**: `image_ready` stayed 0 and AMSDOS retried
forever with the motor spinning. That is still unexplained and is deliberately not attempted
here.

When updating from a newer upstream `u765.sv`: re-apply both additions. If upstream ever
grows its own way of signalling "the image changed underneath you", drop this exception and
use theirs.
### `rtl/crt_filter.v`: NOT modified - an analog-framing change was tried and reverted (2026-09-06)

Recorded here so nobody re-derives it. `blankgen`'s line raster is genuinely lopsided: with
`hborder` counting at `CE_4` (4 MHz, one tick = 0.25 us) over a 256-tick / 64 us line, the split
is 4.00 us of HSYNC pulse + **8.25 us** of back porch + 48.00 us of active + **3.75 us** of
front porch. Real PAL uses about 5.7 us of back porch, so 8.25 is long and it does push the
picture rightwards.

`BEGIN_HBORDER`/`END_HBORDER` were briefly changed to 40/232 (splitting the 48 non-active ticks
evenly, 6.00 us each side, keeping exactly the same 192 active ticks so no pixel is lost) to
chase a report of the VGA image sitting right with its right edge off the panel. **Reverted**:
the user then observed the *stock MEGA65 core* misframing the same way on the same monitor, which
isolates the cause to the monitor's handling of a non-VESA 50 Hz mode, not to this core. The
change fixed nothing observable, and a modification to a vendored third-party file has to earn
its keep - every one of them is debt to re-apply on the next upstream update.

Keep in mind if analog framing ever matters again (a different monitor, the R3 build): the
measurement above still stands, the change is two constants, and it does **not** affect HDMI
(ascal scales whatever `HBLANK`/`VBLANK` delimit, and that region keeps its size - only *when*
it happens inside the line changes).

MiSTer2MEGA65
-------------

### `M2M/vhdl/top_mega65-r6.vhd`: routed the internal floppy drive pins to the core (Milestone 4, 2026-09-09)

The template ties all ten FDC **outputs** to their inactive level right in the top level
(`f_density_o`, `f_motora_o`, `f_motorb_o`, `f_selecta_o`, `f_selectb_o`, `f_side1_o`,
`f_stepdir_o`, `f_step_o`, `f_wdata_o`, `f_wgate_o`) and leaves the five **inputs**
(`f_diskchanged_i`, `f_index_i`, `f_rdata_i`, `f_track0_i`, `f_writeprotect_i`) unconnected.
That is why these signals do not appear in `framework.vhd` at all: **the framework never routes
them anywhere**. Milestone 4 needs them, so the tie-offs were replaced by a wiring of all
fifteen into the `CORE : entity work.MEGA65_Core` instance.

**Only this one framework file changes.** `framework.vhd` does not instantiate the core -
`top_mega65-r6.vhd` instantiates `i_framework` (line 574) and `CORE` (line 757) separately and
wires them together - so there is nothing to thread through the framework itself.

Verified before writing any of this: **no sibling core does this**. Searching `f_motora`,
`f_rdata`, `f_index`, `f_track0` and `f_stepdir` across QL4M65, C64MEGA65 and AExp finds them
only in each project's own copy of the framework top levels and XDC constraints, never in any
`CORE/` directory. There was no precedent to copy, which is why `CORE/vhdl/floppy_phys.vhd` is
written from scratch.

Only the R6 top level is touched, because R6 is the only board this project builds for so far.
The same change will be needed in `top_mega65-r3/r4/r5.vhd` when other boards are added.

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

**Status since Milestone 2 (2026-09-06)**: with `C_VDNUM := 2` this guard is no longer
exercised - the `VDNUM=0` path it protects is now dead code in this project. It is kept
deliberately: the upstream bug is real and still unreported, and dropping the guard would
mean re-discovering it if the core ever goes back to `VDNUM=0` (or if another port copies
this framework tree). It is simply no longer on our critical path.

When updating from a newer upstream `vdrives.vhd`: re-check whether this has been fixed
upstream (search for `3 * VDNUM` near an `xpm_cdc_array_single` generic map); if the fix is
already there, drop this exception and remove the `generate` wrapper we added. If not, keep
the guard.


### `M2M/rom/shell.asm`: `FLUSH_CACHE` no mata el core cuando la unidad no tiene fichero (Milestone 4, 2026-09-20)

Etiqueta en el codigo: `M2M-EXCEPTION flush-no-file`.

**El fallo del framework.** `FLUSH_CACHE` comprobaba el manejador de fichero asi:

    MOVE    HNDL_VD_FILES, R1
    ADD     R0, R1
    MOVE    @R1, R1                 ; R1: image-file handle
    ...
    CMP     0, R1
    RBRA    _FC_PREP, !Z
    MOVE    ERR_FATAL_FZERO, R8
    RBRA    FATAL, 1

Pero `HNDL_VD_FILES` es un array de **punteros a bloques `FAT32$FDH_STRUCT_SIZE`
reservados estaticamente** (`shell_vars.asm`), y `VD_INIT` los inicializa por **doble
indireccion** (`vdrives.asm:23-28`): lo que pone a cero es el primer campo de la
estructura, `FDH_DEVICE`, no el puntero.

O sea que `R1` **nunca vale cero** y esa guarda no puede dispararse jamas. Es codigo
muerto. Con la unidad sin montar, `f32_fseek` se lanza sobre un manejador que nunca se
abrio, con el numero de cluster a 0, y el Shell muere con `ERR_FATAL_SEEK` y el codigo
`0xEE17` = `FAT32$ERR_ILLEGAL_CLUS`.

**Como nos aparecio.** Desde M4031 se puede leer un disquete fisico **sin montar ninguna
imagen**: el core llena el buffer de montaje directamente. Si despues el CPC escribe algo,
`HANDLE_DRV_WR` lo sirve sin problema (no usa manejador) y marca la cache sucia; dos
segundos despues `FLUSH_CACHE` intenta volcarla a un fichero que no existe y tumba la
maquina. Le paso al usuario con un `SAVE"HOLA.BAS"`.

**El arreglo.** Comprobar `@R1` (el campo `FDH_DEVICE`) en vez de `R1`, y si no hay fichero
abierto **saltarse el volcado** en vez de provocar un error fatal: se salta a `_FC_DONE`,
que marca la cache como limpia y vuelve por la salida normal. Marcarla limpia es necesario;
si no, el Shell reintentaria el volcado indefinidamente.

**Por que no es fatal.** Que la cache se ensucie sin fichero detras es una situacion
legitima en cuanto el core puede llenar el buffer por su cuenta. La respuesta correcta es
no volcar nada, no matar la maquina.

**Alcance.** Afecta a CUALQUIER core de M2M cuyo lado del core pueda ensuciar la cache de
una unidad virtual sin imagen montada. Pendiente de reportar aguas arriba junto con el
`ROSM_SAVE` (ese ya arreglado por sy2002 en `bcb34f4`, traido a nuestro arbol y verificado
identico byte a byte al de arriba).

**Al actualizar desde un M2M mas nuevo**: comprobar si la guarda ya mira `@R1`. Si es asi,
quitar esta excepcion.
QNICE
-----

No changes.
