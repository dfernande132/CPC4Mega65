#!/usr/bin/env bash
#
# CPC4MEGA65 - comprobacion rapida de VHDL con GHDL, ANTES de lanzar Vivado.
#
# POR QUE EXISTE: el 21/09/2026 se gastaron TRES sintesis de Vivado -entre cuatro y diez
# minutos cada una- en errores que esto caza en un segundo:
#
#   c_secsz is not declared                  (una declaracion puesta antes de la constante)
#   port width mismatch for port 'w_off_i'   (10 bits contra 14)
#   ambiguous type 'crtrom_buf_array'        (un "use work.globals.all" de mas)
#
# QUE NO HACE, y conviene saberlo: esto es ANALISIS, no elaboracion. No sustituye a Vivado.
#   * El diseño es MIXTO: todo el core de MiSTer es Verilog/SystemVerilog y GHDL solo lee VHDL.
#     Por eso aqui solo se analizan NUESTROS modulos VHDL y no main.vhd ni mega65.vhd, que
#     instancian Verilog.
#   * Las primitivas de Xilinx (MMCME2_ADV, BUFGMUX_CTRL, xpm_*) necesitarian unisim.
#   * No dice nada de timing, ni de sintetizabilidad, ni de si el resultado cabe en la FPGA.
#
# Lo que SI caza es toda la familia que mas nos ha costado: ordenes de declaracion, tipos,
# anchos, rangos y puertos mal conectados entre entidades VHDL.
#
# Uso:  bash .research/check-vhdl.sh

set -u
CORE="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --std=08 y no 93: globals.vhd usa arrays de elemento no restringido, que es VHDL-2008.
STD="--std=08"

cd "$CORE/CORE/vhdl" || exit 1

ghdl -a $STD --workdir="$WORK" -frelaxed \
   "$CORE/M2M/QNICE/vhdl/tools.vhd" \
   "$CORE/M2M/vhdl/av_pipeline/video_modes_pkg.vhd" \
   globals.vhd \
   floppy_phys.vhd floppy_mfm.vhd floppy_write.vhd \
   floppy_scan.vhd floppy_dsk.vhd floppy_copy.vhd \
   keyboard.vhd config.vhd 2>&1

rc=$?
echo ""
if [ $rc -eq 0 ]; then
   echo "VHDL OK - se puede lanzar Vivado"
else
   echo "HAY ERRORES: arreglalos antes de gastar una sintesis"
fi
exit $rc
