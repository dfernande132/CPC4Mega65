# Hallazgos: por qué el copiador rechaza 8 imágenes, y qué hace falta de verdad

**Para: la sesión que termina la v1.0. De: el hilo de investigación de M5.**
Documento autocontenido — no hace falta haber seguido el otro hilo.

**Resumen en una frase:** de las 8 imágenes que `valida_copia.ps1` rechaza, **7 no
necesitan nada parecido a un controlador de flujo**; necesitan que el formateador deje de
tener el formato DATA clavado en constantes. La octava no se puede arreglar con ningún
escritor, porque el problema está en el fichero de origen.

Todo lo que sigue está medido sobre las 26 imágenes de `E:\CPC4MEGA65\DSK` con un
decodificador EDSK que lee el SectorInfo completo (C/H/R/N, ST1, ST2 y **longitud real de
datos**, que es el campo que el validador actual no mira).

---

## 1. Antes que nada: el instrumento está roto

`core\.research\valida_copia.ps1`, línea 28:

```powershell
$tsize = $b[0x32] -bor ($b[0x33] -shl 8)
```

**`-shl` sobre un `Byte` satura a 8 bits en PowerShell.** `0x13 -shl 8` no da `0x1300`:
da **0**. Comprobado:

```
b[0x32]=0x00 b[0x33]=0x13   ->  con -shl: 0     correcto: 4864
```

Consecuencia: en las **7 imágenes `DSK` estándar** de la colección `tsize` vale 0, `$off`
nunca avanza y el bucle **valida la pista 0 cuarenta veces**. Sus "OK" no significan nada.
Las EDSK no se ven afectadas porque usan la tabla de tamaños de 0x34.

Parche:

```powershell
$tsize = [int]$b[0x32] + 256 * [int]$b[0x33]
```

Las 7 afectadas: las cuatro `CPM Plus Complete`, `Ghosts 'N' Goblins`, `Green Beret`,
`Matchday 2`. Revalidadas con el cálculo correcto **las siete siguen saliendo OK** — el
bug no ocultaba ningún rechazo, pero la comprobación no se estaba haciendo.

*(Nota: el mismo error lo cometí yo en mi primer analizador. Se caza volcando el hex del
TrackInfo y comparando a mano.)*

---

## 2. Qué hay realmente dentro de las 8 rechazadas

| Imagen | err | Qué hay de verdad | Clase |
|---|---|---|---|
| R-Type Face A | 4 | **10 sectores N=2, GAP3=0x33.** No es una protección: es el formato de 200 KB | parámetros |
| R-Type Face B | 1 | firma `UXTENDED CPC DSC File…` — bit flips sobre `EXTENDED CPC DSK File` | **imagen dañada** |
| Total UK Face A | 5 | pistas de **5 sectores N=3** (1024 B) con marca de datos **borrados**; GAP3 varía 0x43–0x53 por pista | parámetros + campos |
| Total UK Face B | 5 | igual, menos pistas afectadas | parámetros + campos |
| All Star Hits 2 | 5 | una pista con un sector **N=0** y **sin DAM** (ST2 bit 0) | parámetros + campos |
| Dynamite 1, 2, 3 | 5 | pistas de **1 sector, R=0x23, N=6** (declara 8192) con **6144 bytes reales**, **CRC de datos malo** y marca de **borrado** | parámetros + campos |
| Dynamite 4 | 4 | pista 1: **16 IDs R=00..0F con N=0..15**, longitudes 128/256/512/1024/2048/4096/**6144**/0…, **suma 14208 B en una pista de 6250** | **irreproducible** |

Sobre las dos que no son lo que parecen:

* **R-Type Face A no es una protección.** Cuadra al byte: 10 × (62 + 512 + 51) = 6250 =
  una pista DD entera, exactamente. Es el formato Ocean de 10 sectores.
* **Dynamite 4 pista 1 no es reproducible desde el EDSK.** Los campos de datos suman más
  del doble de lo que cabe en una vuelta porque **se solapan**: los 16 identificadores
  comparten un mismo cuerpo físico y cada lectura toma de él una longitud distinta. El
  EDSK guarda *lo que el FDC devolvió*, no *lo que hay en el disco*. Ningún escritor
  puede reconstruirla a partir de este fichero. Haría falta el disco original.

---

## 3. El presupuesto de pista, que es el que manda

Pista DD 250 kbps a 300 RPM: un byte son 16 celdas × 2 µs = 32 µs, y una vuelta son
200 ms → **6250 bytes por pista.** Todo lo que sigue sale de ahí.

Coste de un sector (formato IBM System 34, el del CPC):

```
12 sync + 3×A1 + 1 IDAM + 4 ID + 2 CRC + 22 GAP2 + 12 sync + 3×A1 + 1 DAM + D datos + 2 CRC + G3
= 62 + D + G3
```

Preámbulo de pista que escribe hoy `floppy_write`:
`80 GAP4A + 12 sync + 3×C2 + 1 IAM + 50 GAP1` = **146 bytes**.

| Caso | Cuentas | Total | ¿Cabe en 6250? |
|---|---|---|---|
| 9×512, GAP3=78 (lo actual) | 146 + 9×652 | 6014 | sí, 236 de margen |
| 10×512, GAP3=51 (R-Type A) | 146 + 10×625 | **6396** | **no** — sin preámbulo: 6250 exacto |
| 5×1024, GAP3=81 (Total UK) | 146 + 5×1167 | 5981 | sí |
| 1×6144, GAP3=78 (Dynamite) | 146 + 6284 | **6430** | **no** — sin preámbulo y sin GAP3 final: 6206, cabe con 44 |
| 16 solapados (Dynamite 4) | — | 16594 | imposible por definición |

**El hallazgo accionable:** los dos casos que no caben, caben en cuanto se **omite el
preámbulo IAM** (los 146 bytes de GAP4A+sync+IAM+GAP1). Que R-Type A dé 6250 clavados sin
preámbulo no es casualidad: **esos discos no llevan IAM**. Es normal en formatos de
capacidad alta y en protecciones.

→ El escritor necesita poder **escribir una pista sin marca de índice**, y repartir el
sobrante en el hueco final en vez de tenerlo clavado.

---

## 4. Qué falta en el RTL, fichero por fichero

### 4.1 `floppy_copy.vhd` — la validación

| Estado | Línea aprox. | Regla actual | Qué la rompe |
|---|---|---|---|
| `CP_V_SEC_N` | 450 | `if rd_data /= x"02"` → err 5 | N≠2: Dynamite, Total UK, All Star |
| `CP_V_NSEC` | 429 | `> G_MAXSEC` (=9) → err 4 | R-Type A (10), Dynamite 4 (16) |
| `CP_SIG` | 353 | `= x"4D" or x"45"` → err 1 | R-Type B (firma con bit flips) |

El comentario de `CP_V_SEC_N` dice la razón de diseño, y es correcta:

> *"N=2 son 512 bytes. Exigirlo aquí es lo que permite que el cálculo de la dirección de
> datos sea una multiplicación y no una tabla acumulada."*

Con N variable, el desplazamiento de los datos de un sector dentro de la pista deja de ser
`sector × 512`. **Hace falta una tabla de desplazamientos acumulados por sector**,
construida en la pasada de validación que ya recorre la lista (`CP_V_SEC_H`/`CP_V_SEC_N`).
Son `G_MAXSEC` entradas de 14 bits: cabe de sobra.

### 4.2 `floppy_write.vhd` — el formateador

Lo bueno: **`W_ID_N` ya escribe `src_id_n_i`** en modo copia, o sea el escritor ya pone en
el identificador el N que le den. Lo que falta es todo lo demás:

| Qué | Dónde | Estado actual |
|---|---|---|
| longitud del campo de datos | `W_DAM_M`: `cnt <= C_SECSZ - 1` | **512 constante** — con N=3 escribiría N=3 en el ID y 512 bytes de datos: incoherente |
| `dat_off` | decl. | `natural range 0 to 511` → hasta 16383 |
| `src_off_o` | puerto | 10 bits → 14 bits |
| GAP3 | `C_GAP3 : natural := 78` | constante → entrada |
| marca de datos | `C_MARK_DAT := x"FB"` | constante → `0xF8` cuando ST2 bit 6 (borrado) |
| CRC de datos forzable | `W_DAT_CRC` | siempre correcto → invertir un bit cuando ST1 bit 5 (CRC malo) |
| sector sin campo de datos | — | no existe → saltar de `W_ID_CRC` a `W_GAP3` cuando ST2 bit 0 (sin DAM) |
| pista sin IAM | `W_GAP4A`→`W_SYNC1`→`W_IAM_*`→`W_GAP1` | siempre se escriben → saltar al primer sector |

`src_sec_o` es de 4 bits (0..15): vale para 16 sectores justo, pero `G_MAXSEC` habría que
subirlo y revisar `t_idarr` y `sec_ix` en `floppy_copy.vhd`.

### 4.3 Lo que hay que respetar

* **No tocar el motor de celdas ni la temporización.** Está probado en hardware con 40
  pistas y contra un CPC 6128 real. El cambio es *qué* se emite, no *cuándo*.
* **No tocar las cinco condiciones de seguridad de WGATE** ni la ventana ciega de 100 ms
  del índice (M4039). Siguen aplicando igual.
* El formateo **termina en el pulso de índice**, así que el último hueco se trunca solo.
  Eso ya funciona y es lo que absorbe los redondeos del presupuesto.

---

## 5. Lo que NO se puede arreglar, y conviene decirlo

* **Dynamite 4 pista 1.** Campos solapados: el EDSK no la describe de forma reproducible.
  Con esta imagen como origen no hay solución, ni con flujo. Lo honesto es **saltar la
  pista y avisar**, no rechazar el disco entero: las otras 42 pistas son normales.
* **R-Type Face B.** La imagen tiene bit flips en la firma. Se puede aceptar siendo
  tolerante en `CP_SIG` (la cabecera es válida en todo lo demás: 0x30 = 40 pistas,
  0x31 = 1 cara), pero conviene avisar de que el fichero está dañado — puede tener más
  bits mal en los datos y eso no se ve desde aquí.
* **Sectores débiles / múltiples copias.** No aparecen en esta colección (ningún sector
  tiene longitud real *mayor* que la declarada), así que no hay que resolverlos ahora.
  Si aparecieran, sí harían falta varias vueltas y el EDSK los representa concatenando
  copias.

---

## 6. Orden sugerido y cómo verificar cada paso

Cada paso deja el copiador en un estado mejor y verificable por separado.

1. **Arreglar `valida_copia.ps1`** (el `-shl`). *Verificación:* las 26 imágenes dan el
   mismo veredicto que el analizador nuevo, y las 7 DSK recorren de verdad sus 40 pistas.
2. **GAP3 y número de sectores variables** (`C_GAP3` → entrada, `G_MAXSEC` → 16).
   *Verificación:* R-Type Face A pasa la validación y se copia; releer con el camino de
   lectura de M4 debe dar 10 sectores con los dos CRC buenos en todas las pistas.
3. **Pista sin IAM** + reparto del sobrante en el hueco final. *Verificación:* el
   presupuesto de R-Type A cuadra en 6250 y la telemetría de `floppy_write` da una
   apertura de WGATE de ~12,8 M ciclos (una vuelta) por pista.
4. **N variable** (longitud de datos + tabla de desplazamientos acumulados).
   *Verificación:* Total UK Face A y B se copian; 5 sectores de 1024 con CRC bueno.
5. **Marca de borrado y sector sin DAM.** *Verificación:* All Star Hits 2; el sector N=0
   sin DAM debe leerse como tal, no como sector con CRC malo.
6. **CRC de datos forzable.** *Verificación:* Dynamite 1, 2 y 3; la pista de 1 sector
   N=6 debe releerse dando **error de CRC** — que aquí el éxito es que falle igual que el
   original.
7. **Saltar pistas irreproducibles con aviso.** *Verificación:* Dynamite 4 copia 42 de
   43 pistas y lo dice.

Nota sobre el paso 6: es el único donde "funciona" significa "reproduce el fallo". Merece
un contador de telemetría propio para no confundirlo con un fallo nuestro.

---

## 7. Cobertura esperada

| | Ahora | Tras los pasos 1–7 |
|---|---|---|
| Imágenes aceptadas | 18 de 26 | **25 de 26** |
| Irreproducible | — | Dynamite 4 (1 pista de 43) |

Ninguno de estos siete pasos toca el `u765`, ni el camino de datos del CPC, ni el motor de
celdas. Todo el riesgo queda dentro de `floppy_copy.vhd` y `floppy_write.vhd`.

---

## 8. Herramientas

En el scratchpad del hilo de M5 (hay que moverlas a `.research/` si van a sobrevivir):

* `edsk.ps1` — decodificador EDSK por sector: C/H/R/N, ST1/ST2, longitud real vs
  declarada, IDs repetidos. `-Full` lista pista a pista.
* `anomalas.ps1` — lista solo las pistas que se salen del formato DATA, con el cálculo de
  presupuesto de bytes y si cabe o no en una vuelta.
* `barrido.ps1` — clasifica la colección por nivel de exigencia al escritor.

Dos avisos si se reutilizan: el campo de longitud real **solo existe en EDSK** (en DSK
estándar vale 0 y hay que derivar el tamaño de N), y cuidado con `-shl` sobre bytes.
