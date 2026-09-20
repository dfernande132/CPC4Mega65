# Repite EXACTAMENTE las comprobaciones de floppy_copy.vhd sobre un .dsk, para saber si el core
# lo aceptaria antes de gastar un disquete. Mismos ocho codigos de rechazo.
param([Parameter(Mandatory=$true)][string[]]$dsk)

$MAXTRK = 42
$MAXSEC = 9
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
   $tsize = $b[0x32] -bor ($b[0x33] -shl 8)
   $secs = @()
   if ($err -eq 0) {
      for ($t = 0; $t -lt $ntrk -and $err -eq 0; $t++) {
         if ($ext) {
            $ts = $b[0x34 + $t]
            if ($ts -eq 0) { $err = 7; $det = "pista $t sin formatear"; break }
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
      "OK        {0,-62} {1} {2} pistas, sectores pista0: {3}" -f $name, $tipo, $ntrk, $ids.Trim()
   } else {
      "RECHAZO {0}  {1,-62} {2} ({3})" -f $err, $name, $tipo, $det
   }
}
