# Decodifica el bloque de telemetria "CPCTLM" de un volcado .dsk de CPC4MEGA65.
# Mapa v1 = M4019..M4032, mapa v2 = M4033 (anade los dos mapas de pistas de 40 bits).
param([Parameter(Mandatory=$true)][string]$dsk)

$b = [System.IO.File]::ReadAllBytes($dsk)
"fichero : $dsk"
"tamano  : $($b.Length) bytes  (imagen entera = 194816)"

$sig = [System.Text.Encoding]::ASCII.GetString($b, 0x34, 6)
if ($sig -ne "CPCTLM") { "*** sin bloque de telemetria en 0x34 (leido '$sig')"; exit 1 }

$ver = $b[0x3A]
"version del mapa : 0x{0:X2}" -f $ver
if ($ver -ge 0x08) {
   # M4058: base de tiempo rotacional del u765 con la que se tomo ESTE volcado.
   # 4000 = disco real, 300 RPM, vuelta de 205 ms.  8000 = estres, 150 RPM, 410 ms.
   # Ojo con la aritmetica: ce_u765 son 8 MHz pero el u765 multiplexa las dos unidades
   # (u765.sv:464-473), asi que la base efectiva es 4 MHz y 4000 cuentas son 1 ms de verdad.
   $cyc = [int]$b[0x76] + 256 * [int]$b[0x77]
   if ($cyc -gt 0) {
      $vuelta = 205.0 * $cyc / 4000.0
      "base u765        : {0} cuentas/ms  -> vuelta {1:N0} ms, {2:N0} RPM" -f $cyc, $vuelta, (60000.0 / $vuelta)
      if ($cyc -ne 4000) { "  OJO: NO es la velocidad real. Este volcado es de un experimento." }
   }
}

# OJO: en PowerShell los operadores de bits devuelven el tipo del operando IZQUIERDO, y $b[$o]
# es un [byte]. Sin el casteo explicito, "byte -bor entero" se TRUNCA a byte y estas dos
# funciones devuelven solo el byte bajo. Eso hizo que durante toda la investigacion del
# escritor se leyeran 22, 170, 161... cuando el valor real era de millones.
function U32($o) { [uint32]$b[$o] -bor ([uint32]$b[$o+1] -shl 8) -bor ([uint32]$b[$o+2] -shl 16) -bor ([uint32]$b[$o+3] -shl 24) }
function U16($o) { [uint32]$b[$o] -bor ([uint32]$b[$o+1] -shl 8) }

# AUTOCOMPROBACION. Esto existe porque la version anterior de las dos funciones de arriba
# devolvia SOLO EL BYTE BAJO -en PowerShell los operadores de bits devuelven el tipo del operando
# izquierdo, y $b[$o] es un [byte]- y durante dos dias se leyeron 22, 170 y 161 donde habia
# 12.799.393. Cinco compilaciones y tres diagnosticos equivocados persiguiendo un fallo del core
# que no existia.
#
# La regla: un instrumento se valida contra un valor conocido ANTES de creerse nada de lo que
# dice. Aqui el valor conocido se fabrica: un patron cuyos cuatro bytes son distintos y cuyo
# resultado solo sale bien si no hay truncamiento.
$__save = $b
$b = [byte[]]@(0x78, 0x56, 0x34, 0x12)
if ((U32 0) -ne 0x12345678 -or (U16 0) -ne 0x5678) {
   $b = $__save
   "*** EL DECODIFICADOR ESTA ROTO: U32 da {0:X} y U16 da {1:X}, deberian ser 12345678 y 5678" -f (U32 0), (U16 0)
   "*** No te creas ni un numero de los de abajo."
   exit 1
}
$b = $__save

$wr = $b[0x3C] -bor ($b[0x3D] -shl 8) -bor (($b[0x3E] -band 0x0F) -shl 16)
""
"nonce            : {0}" -f $b[0x3B]
"bytes escritos   : {0}" -f $wr
"pistas escritas  : {0}" -f $b[0x40]
"pistas con fallo : {0}" -f ($b[0x41] -band 0x1F)
$fl = $b[0x42]
"banderas         : 0x{0:X2}  idCPC={1} HD={2} densidad={3} scan_done={4} dpll={5}" -f `
   $fl, ($fl -band 1), (($fl -shr 1) -band 1), (($fl -shr 2) -band 1), (($fl -shr 3) -band 1), (($fl -shr 4) -band 1)
"codigo posicion  : {0}" -f ($b[0x43] -band 0x1F)
"actividad (ms)   : {0}" -f (U32 0x44)
"celdas DPLL      : {0}" -f (U16 0x48)
"flancos espurios : {0}" -f (U16 0x4A)
""
"--- formateo ---"
$wg = U32 0x4C
"ciclos WGATE     : {0}   ({1:N1} ms a 64 MHz)" -f $wg, ($wg / 64000.0)
"pulsos WDATA     : {0}" -f (U32 0x50)
"formateos        : {0}" -f $b[0x54]
$refus = $b[0x55]
$noidx = if ($ver -ge 0x07) { $b[0x3F] } else { 0 }   # M4052: byte 11 del bloque
"rechazos         : {0}" -f $refus
if ($ver -ge 0x07) {
   "  ...por no ver el indice (SIN DISQUETE DENTRO) : {0}" -f $noidx
   $prot = $refus - $noidx
   if ($prot -gt 0) { "  ...por PROTECCION contra escritura            : {0}" -f $prot }
   if ($noidx -gt 0) {
      "  Antes de M4052 esto no era un rechazo sino un CUELGUE: floppy_write esperaba"
      "  el indice para siempre y el recorrido no terminaba nunca."
   }
} elseif ($refus -gt 0) {
   "  (mapa anterior a 0x07: no se puede saber si fue proteccion o falta de disquete)"
}
"estado u765      : 0x{0:X4}" -f (U16 0x56)

function Bitmap($off) {
   $v = [uint64]0
   for ($i = 0; $i -lt 5; $i++) { $v = $v -bor ([uint64]$b[$off + $i] -shl (8 * $i)) }
   return $v
}
function Show($v) {
   $s = ""
   for ($t = 0; $t -lt 40; $t++) { $s += if ((($v -shr $t) -band 1) -eq 1) { "#" } else { "." } }
   $n = 0; for ($t = 0; $t -lt 40; $t++) { if ((($v -shr $t) -band 1) -eq 1) { $n++ } }
   return "$s  ($n de 40)"
}

if ($ver -ge 2) {
   $dirty = Bitmap 0x58
   $ok    = Bitmap 0x5D
   ""
   "--- reescritura por pistas (M4033, solo medida) ---"
   "                    pista 0 ------------------------------> 39"
   "escritas por CPC  : {0}" -f (Show $dirty)
   "leidas enteras    : {0}" -f (Show $ok)
   "REGRABABLES       : {0}" -f (Show ($dirty -band $ok))
   $blocked = $dirty -band (-bnot $ok)
   "BLOQUEADAS        : {0}" -f (Show $blocked)
   if ($blocked -ne 0) { "  *** hay pistas escritas por el CPC que NO se leyeron enteras: no se pueden regrabar" }
}

if ($ver -ge 3) {
   ""
   "--- escrituras del u765 y copiador (M4034) ---"
   "flancos de escritura : {0}   (sin filtrar por pista ni unidad)" -f (U16 0x62)
   $cp = $b[0x64] -band 0x0F
   $motivo = switch ($cp) {
      0 { "sin rechazo" }
      1 { "firma desconocida (no hay .dsk montado o no es un .dsk)" }
      2 { "dos caras" }
      3 { "numero de pistas imposible" }
      4 { "una pista tiene 0 o mas de 9 sectores" }
      5 { "un sector no es de 512 bytes (N distinto de 2)" }
      6 { "un sector dice que es de la cara 1" }
      7 { "pista sin formatear en un EDSK" }
      8 { "la imagen no cabe en el buffer" }
      9 { "no se ha leido el disco: no hay mapa de pistas buenas" }
      default { "codigo desconocido" }
   }
   "rechazo del copiador : {0}  ({1})" -f $cp, $motivo
   "pistas preparadas    : {0}" -f $b[0x65]
}

if ($ver -ge 4) {
   ""
   "--- plazo del volcado automatico (M4036) ---"
   $gap = U16 0x66
   "hueco maximo entre escrituras : {0} ms   <-- SUELO del plazo de espera" -f $gap
   "disparos del automatico       : {0}" -f $b[0x68]
   "pistas bloqueadas             : {0}" -f $b[0x69]
   if ($gap -gt 0) {
      "  el plazo tiene que quedar claramente por encima de {0} ms" -f $gap
   }
}

if ($ver -ge 5) {
   # Orden de t_state en floppy_write.vhd
   $st = @("W_IDLE","W_WAIT_IDX","W_GAP4A","W_SYNC1","W_IAM_A","W_IAM_M","W_GAP1",
           "W_SSYNC","W_IDAM_A","W_IDAM_M","W_ID_C","W_ID_H","W_ID_R","W_ID_N",
           "W_ID_CRC","W_GAP2","W_DSYNC","W_DAM_A","W_DAM_M","W_DATA","W_DAT_CRC",
           "W_GAP3","W_GAP4B","W_DONE","W_REFUSED")
   ""
   "--- por que se cierra WGATE (M4038) ---"
   $ab = $b[0x6A]; $ix = $b[0x6B]; $ss = $b[0x6C]
   $wgmax = U32 0x6E
   "cierres por PERDIDA DE PERMISO : {0}" -f $ab
   "cierres por INDICE (normal)    : {0}" -f $ix
   $nom = if ($ss -lt $st.Count) { $st[$ss] } else { "desconocido" }
   "estado en el ultimo cierre     : {0}  ({1})" -f $ss, $nom
   "apertura mas larga             : {0} ciclos = {1:N1} ms   (una pista entera son ~12,8 M = 200 ms)" -f $wgmax, ($wgmax / 64000.0)
   if ($ver -ge 0x07) {
      # M4054: antes se acumulaba durante TODA la sesion y no se borraba nunca, asi que un
      # formateo bueno dejaba este campo alto para siempre y el LED daba VERDE a los rechazos
      # posteriores. Ahora se borra al empezar cada operacion de ESCRITURA; una LECTURA no lo
      # toca, que es lo que permite que sea la lectura posterior la que vuelque este bloque.
      "  (desde M4054 es de la ULTIMA operacion de escritura, no de toda la sesion)"
   }
   ""
   if ($wgmax -gt 10000000) {
      "  VEREDICTO: se grabaron pistas enteras. El problema, si lo hay, esta en otro sitio."
   } elseif ($ab -gt 0 -and $ix -eq 0) {
      "  VEREDICTO: el permiso sigue cayendo por debajo del escritor. Mirar quien baja enable_i"
      "             estando la maquina en $nom."
   } elseif ($ix -gt 0 -and $wgmax -lt 1000) {
      "  VEREDICTO: el indice llega justo despues de arrancar y cierra la pista al instante."
      "             El problema esta en el arranque (W_WAIT_IDX / idx_seen), no en el permiso."
   } else {
      "  VEREDICTO: no concluyente, mirar los numeros a mano."
   }
}

if ($ver -ge 6) {
   $idxwr = U16 0x72
   $blind = U16 0x74
   $starts = $b[0x54]
   ""
   "--- el indice durante la escritura (M4039) ---"
   "indices vistos con WGATE ABIERTO : {0}" -f $idxwr
   "indices RECHAZADOS por la ventana ciega : {0}" -f $blind
   "pistas escritas (arranques)      : {0}" -f $starts
   ""
   if ($starts -eq 0) {
      "  no se ha escrito nada en esta sesion: nada que interpretar aqui"
   } elseif ($blind -gt 0) {
      "  ACOPLAMIENTO DEMOSTRADO: {0} pulsos de indice espurios rechazados en {1} pistas" -f $blind, $starts
      "  ({0:N2} por pista). Sin la ventana ciega, cada uno mataba su pista." -f ($blind / [double]$starts)
   } elseif ($idxwr -le $starts) {
      "  el indice esta limpio: {0} pulsos para {1} pistas, o sea el de cierre y nada mas." -f $idxwr, $starts
      "  Si aun asi no se escribe, la causa es OTRA y hay que replantear."
   } else {
      "  hay mas indices que pistas pero la ventana no rechazo ninguno: llegan TARDE,"
      "  fuera de los 100 ms. Habria que ampliar la ventana."
   }
}

""
"--- por pista (cabecera de cada pista, 0x60..0x6B) ---"
"pista  sect  vueltas  idCRC  datCRC  vistos"
for ($t = 0; $t -lt 40; $t++) {
   $base = 256 + $t * 4864
   $seen = U32 ($base + 0x60)
   $revs = $b[$base + 0x64] -band 0x0F
   $sct  = $b[$base + 0x65] -band 0x1F
   $idc  = U16 ($base + 0x66)
   $dtc  = U16 ($base + 0x68)
   $trk  = $b[$base + 0x6A] -band 0x7F
   $mark = if ($sct -eq 9) { " " } else { "<" }
   "{0,4}  {1,4}    {2,5}  {3,5}   {4,5}   0x{5:X8}  (cab. dice pista {6}) {7}" -f $t, $sct, $revs, $idc, $dtc, $seen, $trk, $mark
}
