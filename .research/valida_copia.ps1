# Repite EXACTAMENTE las comprobaciones de floppy_copy.vhd sobre un .dsk, para saber si el core
# lo aceptaria antes de gastar un disquete. M4051: el 7 ya no existe, las pistas sin
# formatear se SALTAN, y aqui se dice cuales para poder contrastarlo con la telemetria.
param([Parameter(Mandatory=$true)][string[]]$dsk)

$MAXTRK = 45
$MAXSEC = 16   # M4057: el core subio G_MAXSEC a 16. Este fichero DEBE seguirlo o deja de espejar.
$BUFSZ  = 262144

foreach ($path in $dsk) {
   $b = [System.IO.File]::ReadAllBytes($path)
   $name = Split-Path $path -Leaf
   $err = 0; $det = ""

   if ($b[0] -eq 0x4D) { $ext = $false }
   elseif ($b[0] -eq 0x45) { $ext = $true }
   else { $err = 1; $det = "primer byte 0x{0:X2}" -f $b[0] }

   if ($err -eq 0) {
      $ntrk = $b[0x30]
      if ($ntrk -eq 0 -or $ntrk -gt $MAXTRK) { $err = 3; $det = "$ntrk pistas" }
   }
   if ($err -eq 0) {
      if ($b[0x31] -ne 1) { $err = 2; $det = "{0} caras" -f $b[0x31] }
   }

   $off = 256
   # OJO: NADA de "-bor ($b[0x33] -shl 8)". En PowerShell los operadores de bits devuelven el
   # tipo del operando IZQUIERDO, y $b[x] es un [byte]: el desplazamiento satura a 8 bits y da
   # CERO. Con tsize=0 el bucle no avanzaba y validaba la pista 0 cuarenta veces, o sea que los
   # "OK" de los 7 .dsk estandar de la coleccion no comprobaban nada.
   #
   # Es EL MISMO fallo que costo cinco builds en decode_tlm.ps1. Alli se arreglo con castings
   # explicitos y una autocomprobacion, y no se miro el script hermano de la misma carpeta.
   $tsize = [int]$b[0x32] + 256 * [int]$b[0x33]
   $secs = @()
   $skip = @()
   if ($err -eq 0) {
      for ($t = 0; $t -lt $ntrk -and $err -eq 0; $t++) {
         if ($ext) {
            $ts = $b[0x34 + $t]
            # OJO: el "continue" NO avanza $off, y es correcto: una pista de tamano 0 no
            # ocupa ni un byte del fichero.
            if ($ts -eq 0) { $skip += $t; continue }   # M4051: sin formatear = se salta
            $tsize = $ts * 256
         }
         if ($off + 0x18 -ge $b.Length) { $err = 8; $det = "pista $t fuera del fichero"; break }
         if ($b[$off + 0x11] -ne 0) { $err = 2; $det = "pista $t dice cara {0}" -f $b[$off+0x11]; break }
         $ns = $b[$off + 0x15]
         if ($ns -eq 0 -or $ns -gt $MAXSEC) { $err = 4; $det = "pista $t tiene $ns sectores"; break }
         $secs += $ns
         for ($s = 0; $s -lt $ns; $s++) {
            $e = $off + 0x18 + $s * 8
            if ($b[$e + 1] -ne 0) { $err = 6; $det = "pista $t sector $s dice cara 1"; break }
            if ($b[$e + 3] -ne 2) { $err = 5; $det = "pista $t sector $s tiene N={0}" -f $b[$e+3]; break }
         }
         if ($err -ne 0) { break }
         if ($off + $tsize -gt $BUFSZ) { $err = 8; $det = "no cabe en el buffer"; break }
         $off += $tsize
      }
   }

   $tipo = if ($ext) { "EDSK" } else { "DSK " }
   if ($err -eq 0) {
      $ids = ""
      for ($s = 0; $s -lt $b[256 + 0x15]; $s++) { $ids += ("{0:X2} " -f $b[256 + 0x18 + $s*8 + 2]) }
      $sk = if ($skip.Count) { "  SALTA {0}: {1}" -f $skip.Count, ($skip -join ",") } else { "" }
      "OK        {0,-62} {1} {2} pistas, pista0: {3}{4}" -f $name, $tipo, $ntrk, $ids.Trim(), $sk
   } else {
      "RECHAZO {0}  {1,-62} {2} ({3})" -f $err, $name, $tipo, $det
   }
}
