set cur_dir [pwd]
# ../../CORE/CORE-R6.runs/synth_1/

set m2m_rom_dir E:/CPC4MEGA65/core/CORE/m2m-rom
set core_vhdl   E:/CPC4MEGA65/core/CORE/vhdl

# CPC4MEGA65: Vivado corre nativo en Windows, pero qasm/qasm2rom (M2M/QNICE/tools) son
# binarios ELF de Linux sin build para Windows, y la deteccion de SO de make_rom.sh
# (M2M/QNICE/tools/detect.include) tampoco reconoce el $OSTYPE de MSYS/Git Bash - por eso
# el reensamblado tiene que pasar por WSL, no por un "exec" directo del .sh (mismo hallazgo
# que QL4M65, ver .research/build-toolchain.md de ese proyecto). El "2>&1" es necesario
# porque exec trata cualquier salida por stderr como fallo aunque el proceso acabe con
# codigo 0, y los avisos del preprocesador sobre apostrofes en comentarios .asm van a
# stderr por diseno de esa herramienta.
#
# Ojo con lo que ese "2>&1" hace y lo que NO hace: suprime el pseudo-error "el hijo ha
# escrito en stderr", nada mas. Un codigo de salida distinto de cero SIGUE reventando el
# exec. Por eso el catch de aqui abajo sirve de algo.
if {[catch {exec wsl.exe -d Ubuntu -- bash -c "cd /mnt/e/CPC4MEGA65/core/CORE/m2m-rom && ./make_rom.sh 2>&1"} salida]} {
   puts $salida
   error "CPC4MEGA65: make_rom.sh ha fallado. El firmware QNICE no se ha regenerado."
}
puts $salida

# CPC4MEGA65: comprobar el RESULTADO, no el proceso.
#
# Un fallo del ensamblado NO se ve en el WNS: el contenido de init de una BRAM no pasa por
# ningun camino critico, asi que la build sale con timing impecable y firmware rancio. Y lo
# que se queda rancio es osm_const.asm, el mapa de indices del menu, que make_rom.sh saca
# de mega65.vhd. Su propio comentario lo dice: un indice corrido no da error de compilacion,
# solo selecciona la linea equivocada. En este core esa linea puede ser FORMAT WHOLE DISK.
#
# De ahi que no baste con mirar si el script devolvio 0. Se mira si el .rom es realmente
# posterior a todo aquello de lo que depende.
set rom $m2m_rom_dir/m2m-rom.rom

if {![file exists $rom]} {
   error "CPC4MEGA65: no existe $rom. El firmware QNICE no se ha generado."
}

foreach fuente [list \
      $m2m_rom_dir/m2m-rom.asm \
      $core_vhdl/mega65.vhd \
      $core_vhdl/globals.vhd] {
   if {[file mtime $rom] < [file mtime $fuente]} {
      error "CPC4MEGA65: $rom es anterior a $fuente. El firmware QNICE esta rancio:\
             el mapa de indices del menu no corresponde al VHDL que se va a sintetizar."
   }
}

puts "CPC4MEGA65: firmware QNICE regenerado y al dia."

cd $cur_dir
