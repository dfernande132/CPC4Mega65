set cur_dir [pwd]
# ../../CORE/CORE-R6.runs/synth_1/

# CPC4MEGA65: Vivado corre nativo en Windows, pero qasm/qasm2rom (M2M/QNICE/tools) son
# binarios ELF de Linux sin build para Windows, y la deteccion de SO de make_rom.sh
# (M2M/QNICE/tools/detect.include) tampoco reconoce el $OSTYPE de MSYS/Git Bash - por eso
# el reensamblado tiene que pasar por WSL, no por un "exec" directo del .sh (mismo hallazgo
# que QL4M65, ver .research/build-toolchain.md de ese proyecto). El "2>&1" es necesario
# porque exec trata cualquier salida por stderr como fallo aunque el proceso acabe con
# codigo 0, y los avisos del preprocesador sobre apostrofes en comentarios .asm van a
# stderr por diseno de esa herramienta.
exec wsl.exe -d Ubuntu -- bash -c "cd /mnt/e/CPC4MEGA65/core/CORE/m2m-rom && ./make_rom.sh 2>&1"

cd $cur_dir

