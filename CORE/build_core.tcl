# Windows defaults general.maxThreads to 2 (Linux defaults to 8) - Vivado's
# own hard cap is 8 regardless of how many CPU cores are available, and each
# command has its own further internal cap (synth_design: 4, route_design: 8).
# Setting this to the max lets synthesis go 2->4 threads and routing 2->8.
# (misma nota que build_core.tcl de QL4M65)
set_param general.maxThreads 8

open_project {E:/CPC4MEGA65/core/CORE/CORE-R6.xpr}

# Reconstruye el firmware Shell de QNICE (m2m-rom.asm -> m2m-rom.rom) antes de sintetizar -
# hook estandar de la plantilla M2M (CORE/m2m-rom/synth_pre.tcl ya viene con el proyecto),
# no un anadido especifico de este core. Sin esto, dualport_2clk_ram podria precargar una
# m2m-rom.rom obsoleta o inexistente -> pantalla negra pese a sintetizar limpio.
set_property STEPS.SYNTH_DESIGN.TCL.PRE {E:/CPC4MEGA65/core/CORE/m2m-rom/synth_pre.tcl} [get_runs synth_1]

set core_cpc_dir  {E:/CPC4MEGA65/core/CORE/Amstrad_MiSTer}
set t80_dir       "$core_cpc_dir/rtl/T80"
set ga_dir        "$core_cpc_dir/rtl/GA40010"

# CPC4MEGA65 M1: lista de ficheros tomada literalmente de files.qip (raiz del core) y de
# los dos sub-qip que referencia (rtl/T80/T80.qip, rtl/GA40010/ga40010.qip) - no adivinada,
# mismo criterio que uso QL4M65 con T8049.qip. Solo se anaden los ficheros que necesita
# Milestone 1 (arranque nativo): CPU, Gate Array, CRTC, PSG, PPI, MMU, el filtro de sync que
# usa Amstrad_motherboard.v, y el propio motherboard. Quedan fuera (Milestones/backlog
# posteriores, no referenciados por Amstrad_motherboard.v de todas formas):
#   rtl/sdram.v        - sustituido por las BRAM de main.vhd (M1A)
#   rtl/hid.sv         - submodulo de teclado quitado, ver doc/m2m/exceptions.md
#   rtl/tzxplayer.vhd  - cinta, Milestone 5
#   rtl/dandanator/*, rtl/playcity/*, rtl/*mouse*.v, rtl/joydb.sv, rtl/progressbar.v - backlog
#   Amstrad.sv, Amstrad.sdc - el top-level "emu" original no se usa (main.vhd es el nuevo top)

# T80 (rtl/T80/T80.qip): el .qip original incluye TODAS las variantes T80 aunque solo T80pa
# se instancia (Amstrad_motherboard.v) - se anaden todas tal cual el qip, igual que QL4M65
# hizo con el T8049.qip completo, para no tener que rastrear a mano las dependencias VHDL.
add_files -norecurse -fileset sources_1 [list \
    "$t80_dir/T80_Pack.vhd" \
    "$t80_dir/T80.vhd" \
    "$t80_dir/T80_ALU.vhd" \
    "$t80_dir/T80_MCode.vhd" \
    "$t80_dir/T80_Reg.vhd" \
    "$t80_dir/T8080se.vhd" \
    "$t80_dir/T80sed.vhd" \
    "$t80_dir/T80as.vhd" \
    "$t80_dir/T80a.vhd" \
    "$t80_dir/T80se.vhd" \
    "$t80_dir/T80s.vhd" \
    "$t80_dir/T80pa.vhd" \
    "$t80_dir/GBse.vhd" \
]

# Gate Array (rtl/GA40010/ga40010.qip, literal)
add_files -norecurse -fileset sources_1 [list \
    "$ga_dir/rslatch.v" \
    "$ga_dir/casgen_sync.v" \
    "$ga_dir/syncgen_sync.v" \
    "$ga_dir/video.sv" \
    "$ga_dir/ga40010.sv" \
]
set_property file_type SystemVerilog [get_files "$ga_dir/video.sv"]
set_property file_type SystemVerilog [get_files "$ga_dir/ga40010.sv"]
# CPC4MEGA65: primer intento real de build (2026-09-05) - [Synth 8-10632]
# "declarations are not allowed in an unnamed block" en syncgen_sync.v:186 (reg cnt5; dentro
# de un always sin nombre - legal en SystemVerilog, rechazado por el parser Verilog-2001
# estricto de Vivado). Mismo problema que QL4M65 encontro en zx8301.v/zx8302.v/mdv.v -
# arreglo de solo build setting, sin tocar el fichero (Porting Guide Parte III S3.C.1).
set_property file_type SystemVerilog [get_files "$ga_dir/syncgen_sync.v"]

# CRTC, PSG, PPI, MMU, filtro de sincronismo y el motherboard (todo lo que
# Amstrad_motherboard.v instancia directamente)
add_files -norecurse -fileset sources_1 [list \
    "$core_cpc_dir/rtl/UM6845R.v" \
    "$core_cpc_dir/rtl/YM2149.sv" \
    "$core_cpc_dir/rtl/i8255.v" \
    "$core_cpc_dir/rtl/Amstrad_MMU.v" \
    "$core_cpc_dir/rtl/crt_filter.v" \
    "$core_cpc_dir/rtl/color_mix.sv" \
    "$core_cpc_dir/rtl/Amstrad_motherboard.v" \
]
set_property file_type SystemVerilog [get_files "$core_cpc_dir/rtl/YM2149.sv"]
# CPC4MEGA65 (M1B003): color_mix.sv hace falta despues de todo - convierte los 2 bits por
# canal del Gate Array (codigo de 3 estados, no binario) a RGB de 8 bits usando la paleta
# real de 27 colores del CPC. En M1B001/M1B002 se excluyo por error creyendo que solo lo
# usaba el top-level Amstrad.sv (opciones de monitor verde/ambar), y se sustituyo por
# replicacion de bits en main.vhd - de ahi los colores equivocados en pantalla.
set_property file_type SystemVerilog [get_files "$core_cpc_dir/rtl/color_mix.sv"]
# CPC4MEGA65: mismo [Synth 8-10632] que arriba, encontrado en el primer intento real de
# build (2026-09-05) en estos ficheros (reg declarado dentro de un always sin nombre):
# Amstrad_MMU.v:49 (old_wr), i8255.v:84 (old_we), UM6845R.v:267-268 (vsc, vsync_allow).
# crt_filter.v no lo necesita (revisado, sin el mismo patron).
set_property file_type SystemVerilog [get_files "$core_cpc_dir/rtl/UM6845R.v"]
set_property file_type SystemVerilog [get_files "$core_cpc_dir/rtl/i8255.v"]
set_property file_type SystemVerilog [get_files "$core_cpc_dir/rtl/Amstrad_MMU.v"]
# Amstrad_motherboard.v NO se marca SystemVerilog (aunque tiene el mismo problema en su
# propio "reg cas_n_old" - ver doc/m2m/exceptions.md): instancia T80pa con un puerto
# ".do(D)", y "do" es palabra reservada en SystemVerilog - marcar el fichero entero rompia
# la instanciacion ([Synth 8-2716]/[Synth 8-10307]). Arreglado en el propio fichero dandole
# nombre al bloque afectado (": video_fetch"), sin necesitar SystemVerilog en absoluto.
# Reset explicito a Verilog: el proyecto guarda el file_type entre ejecuciones de este
# script, así que una ejecución anterior que sí lo marcó SystemVerilog deja el ajuste
# pegado si no se revierte aquí a propósito.
set_property file_type Verilog [get_files "$core_cpc_dir/rtl/Amstrad_motherboard.v"]

# CPC4MEGA65 (M2): controlador de disquete uPD765. Ya venia declarado como SYSTEMVERILOG_FILE
# en files.qip del core original, asi que aqui solo se replica ese tipo. Los ficheros vecinos
# u765_test.sv (banco de pruebas) y u765_tb.cpp (Verilator) no entran: son de simulacion.
add_files -norecurse -fileset sources_1 [list \
    "$core_cpc_dir/rtl/u765/u765.sv" \
]
set_property file_type SystemVerilog [get_files "$core_cpc_dir/rtl/u765/u765.sv"]

# CPC4MEGA65 (M4A): ficheros VHDL propios que no estaban en el .xpr original de la plantilla.
# Los demas (main.vhd, mega65.vhd, keyboard.vhd, config.vhd, globals.vhd...) si venian con
# ella, por eso no aparecen aqui. add_files es idempotente: si el fichero ya esta en el
# proyecto de una ejecucion anterior, no lo duplica.
add_files -norecurse -fileset sources_1 [list \
    "E:/CPC4MEGA65/core/CORE/vhdl/floppy_phys.vhd" \
    "E:/CPC4MEGA65/core/CORE/vhdl/floppy_mfm.vhd" \
    "E:/CPC4MEGA65/core/CORE/vhdl/floppy_scan.vhd" \
]

# CPC4MEGA65: si el log de sintesis da mas casos de [Synth 8-10632]/[Synth 8-1873]/
# [Synth 8-2671] (construcciones SystemVerilog en un fichero marcado como Verilog puro) en
# algun otro fichero - la correccion es marcar ESE fichero concreto como SystemVerilog
# (Porting Guide Parte III S3.C.1/S3.C.5), no todos a la vez. QL4M65 se encontro el mismo
# problema con zx8301.v/zx8302.v/mdv.v.

update_compile_order -fileset sources_1

reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1

set synth_status [get_property STATUS [get_runs synth_1]]
puts "SYNTH_STATUS=$synth_status"
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "RESULT=SYNTH_FAILED"
    close_project
    exit 1
}

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]
puts "IMPL_STATUS=$impl_status"
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "RESULT=IMPL_FAILED"
    close_project
    exit 1
}

# CPC4MEGA65 (M2): comprobacion de timing.
#
# Hasta aqui el script solo miraba que impl_1 llegase al 100%, y eso NO significa que el
# diseno cumpla timing: Vivado escribe el bitstream igualmente aunque haya slack negativo.
# La primera build de M2 salio con "RESULT=BUILD_OK" y WNS = -4.98 ns / 8 endpoints fallando
# - un .cor que habria fallado de forma erratica en hardware. Es exactamente la leccion
# "M1004" del port del QL: no fiarse de un build "exitoso" sin mirar el WNS.
open_run impl_1 -name impl_1
set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1 -nworst 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1 -nworst 1]]
puts "TIMING: WNS=$wns ns  WHS=$whs ns"
if {$wns < 0 || $whs < 0} {
    puts "RESULT=TIMING_FAILED"
    close_project
    exit 1
}

puts "RESULT=BUILD_OK"
close_project
exit 0
