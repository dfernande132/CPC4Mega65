# M5 — Disquetera a nivel de flujo: bitácora de investigación

Hilo paralelo al de la v1.0. **Nada fuera de este directorio se toca.** Sin Vivado, sin
commits, sin escribir en DECISIONES.md.

---

## Sesión 1 (2026-09-21) — Lectura de referencias y medición de la premisa

### 1. Qué hace el `physical_fdd` de AExp

Nueve ficheros, 50 MHz (dominio QNICE). La cadena es:

```
pines -> inputs -> mfm_gaps -> mfm_quantise -> bits -> wfifo -> (dominio core) adf_track_engine -> Paula
                                                  writer <- wfifo(G_AW=2) <- engine  (camino de escritura, A9)
```

* **`inputs`**: sincronizadores de 2 FF con `async_reg`, cualificación del índice por
  suelo de 200 µs de nivel bajo continuo, medida de periodo y anchura. Las líneas de
  estado se pasan con su polaridad activa-baja intacta.
* **`mfm_gaps`**: contador libre; en el flanco de bajada de RDATA emite el intervalo.
  Filtro de runts con umbral **deliberadamente bajísimo** (16 ciclos = 320 ns, frente a
  ~150 de la ventana válida más corta). El comentario dice por qué: un umbral mayor
  convierte el ruido tardío en una fusión del flanco REAL siguiente — regresión medida
  en la ronda 10 del C64MEGA65.
* **`mfm_quantise`**: clasificador adaptativo. Mantiene `est` (media celda) en Q8.4,
  clasifica a la clase más próxima {2,3,4} por los puntos medios 2.5·est / 3.5·est, y
  acepta si |G − n·est| ≤ est/2 — **las ventanas se tocan, no hay bandas muertas**.
  Adapta `est` con paso FIJO de 1/8 de ciclo por el SIGNO del error (buscador de
  mediana), no con un IIR proporcional: un IIR tiene equilibrio SESGADO bajo
  desplazamiento de pico. Recorte duro a ±10 %.
* **`bits`**: dos fuentes de bit seleccionables en caliente.
  - *legacy*: cada gap de n celdas son (n−1) ceros y un uno.
  - *DPLL* (A5, por defecto): fase += 1 ciclo, emite un bit por frontera de celda;
    cada flanco tira de la fase err/2 y del periodo err/64. **Los errores se quedan
    locales**: un flanco salvaje estropea una posición de bit, no el resto del sector.
  Más: alineador por comparación completa de 16 bits contra DSKSYNC, relleno de ceros
  en sequía de flujo, y el `frame_hold` (A6) que congela el encuadre de palabra al
  cruzar la costura de escritura.
* **`wfifo`**: FIFO asíncrona Gray de libro (Cummings 2002), LUTRAM, FWFT.
  **Disciplina de reset load-bearing**: los dos lados resetean del MISMO evento.
* **`writer`** (A9): serializador de una celda por 100 ciclos, MSB primero, pulso activo
  bajo de 500 ns lanzado en el punto medio de la celda; precompensación de escritura
  fiel a la ROM con ventana de 7 bits de canal y magnitud única de 140 ns; WGATE
  definido en la etapa de salida (ventana = palabras × 16 celdas exactas, sin celdas de
  entrada ni de salida); cualificador de pestaña, pestillo de aborto, y los estados
  DISCARD/ABORTED que **siguen consumiendo** para que el DMA del anfitrión termine.

**Qué de esto es del Amiga y qué es genérico.** Genérico: `inputs`, `mfm_gaps`,
`mfm_quantise`, `wfifo`, y del `writer` todo el motor de celdas, la precompensación y la
disciplina de seguridad. Del Amiga: el alineador por DSKSYNC, el `frame_hold`, el modelo
de episodio ligado al DMA de Paula, y el relleno de sequía (existe porque el DMA de Paula
se colgaría si no). La cuantificación y las constantes magnéticas están probadas en
hardware **a 50 MHz**; nosotros vamos a 64, así que se re-derivan, no se copian.

**La diferencia estructural con nosotros, que es la pregunta de verdad:** AExp **no tiene
buffer de pista**. La FIFO de lectura son 32 palabras y la de escritura 4. El
amortiguador elástico real es la FIFO de 2048 palabras de Paula más la Chip RAM del
Amiga, y **el decodificador es software del Amiga**. AExp es una *tubería de bits tonta*
de extremo a extremo: nunca interpreta lo que pasa. Eso es exactamente lo que el CPC no
puede hacer, porque en el CPC el decodificador es un uPD765 de hardware.

### 2. Qué tenemos nosotros (M4)

* `floppy_phys.vhd` — mecánica. Motor, selección, recalibrado a pista 0 con detección de
  fallo (S_ERROR si se agotan 90 pasos), búsqueda paso a paso, índice con ventana muerta
  de 50 ms (M4039). `f_wdata_o`/`f_wgate_o` salen a `open`: los conduce `floppy_write`.
  `f_side1_o` está fijo a inactivo — **una sola cara**.
* `floppy_mfm.vhd` — separador + parser. Dos juegos de ventanas (DD y HD, alternando
  hasta enganchar) **y** un DPLL portado de AExp (M4023). Busca 0x4489, bifurca por la
  marca (FE/FB/F8), valida los dos CRC, emite el flujo de bytes de datos. Telemetría por
  pista.
* `floppy_write.vhd` — formateador. Motor de celdas de 128 ciclos con FSM **de formato**
  (W_GAP4A, W_SYNC1, W_IAM_A … W_GAP4B) y modo `src_en_i` que toma IDs y datos de fuera:
  eso es lo que lo convierte en copiador. Cinco condiciones de seguridad antes de abrir
  WGATE; ventana ciega de 100 ms para el índice; telemetría de por qué se cerró la puerta.
* `floppy_scan` / `floppy_dsk` / `floppy_copy` — secuenciador de 40 pistas, constructor de
  imagen, validador+alimentador.

**Dónde está la disquetera respecto al CPC.** El CPC habla con `u765`, que habla con el
buffer de montaje de 256 KB vía `sd_lba`/`sd_buff`. `floppy_dsk` llena ese buffer y
`floppy_copy` lo vuelca al disquete. **La disquetera física no está en el camino de datos
del CPC en ningún momento**: es un periférico paralelo que sincroniza la imagen.
→ *Pendiente de confirmar con el usuario; todo el análisis de la costura depende de esto.*

### 3. LA MEDIDA QUE CAMBIA LA PREGUNTA

Se analizaron las 26 imágenes de `E:\CPC4MEGA65\DSK` con un decodificador EDSK propio
(`scratchpad/edsk.ps1`, `scratchpad/barrido.ps1`), leyendo el SectorInfo completo:
C/H/R/N, ST1, ST2 y **longitud real de datos**.

Antes, dos defectos del instrumento:

> **Bug en `valida_copia.ps1` (y estaba también en mi primer analizador).**
> `$b[0x33] -shl 8` sobre un `Byte` **satura a 8 bits en PowerShell**: da 0, no 0x1300.
> Consecuencia: en las **7 imágenes `DSK` estándar** de la colección `tsize` vale 0,
> `$off` nunca avanza y **se valida la pista 0 cuarenta veces**. Los "OK" de esas siete
> no significan nada. (Las EDSK usan la tabla de tamaños de 0x34 y no se ven afectadas.)
> Arreglo: `[int]$b[0x32] + 256*[int]$b[0x33]`.

Clasificación por lo que le exige **al escritor**, no por lo que rechaza el validador:

| Nivel | Qué exige | Imágenes |
|---|---|---|
| 0 | formato DATA estándar — lo que ya hacemos | 14 |
| 1 | solo **parámetros**: nº de sectores, N, GAP3, lista de IDs | 5 |
| 2 | además **campos anómalos**: CRC malo a propósito, DAM borrada, datos más cortos que N | 5 |
| 3 | la pista **no es suma de sectores**: campos solapados | 1 |
| — | firma corrompida (bit flips), no es protección | 1 |

Los ocho rechazos, uno por uno:

* **R-Type Face A** → 10 sectores N=2 con **GAP3=0x33**. No es una protección: es el
  formato de 200 KB. Cuadra al byte: 10 × (12+3+1+4+2+22+12+3+1+512+2+51) = 6250 =
  una pista DD entera. **Nivel 1.**
* **R-Type Face B** → firma `UXTENDED CPC DSC File…`: bit flips dispersos sobre
  `EXTENDED CPC DSK File`. La cabecera sigue siendo estructuralmente válida (0x30 = 40
  pistas, 1 cara). **Imagen dañada, no protección.**
* **Total UK A y B** → 5 sectores de **N=3** (1024 B) con la marca de datos borrados.
  5 × 1024 = 5120. GAP3 varía por pista (0x43…0x53). **Nivel 1–2.**
* **All Star Hits 2** → una pista con un sector **N=0** y ST2 bit 0 (sin DAM).
  **Nivel 2.**
* **Dynamite 1, 2 y 3** → pistas con **UN sector, ID=0x23, N=6** (declara 8192) y
  **6144 bytes reales**, con ST1/ST2=0x20 (CRC de datos malo) y bit de borrado.
  El CRC está mal porque el campo nunca termina: el disco se acaba antes. **Nivel 2** —
  hace falta declarar N≠longitud escrita y poder emitir un CRC incorrecto a propósito.
* **Dynamite 4** → pista 1: **16 IDs, R=00..0F, N=0..15**, con longitudes reales
  128, 256, 512, 1024, 2048, 4096, **6144**, y 0 para el resto. Suma = 14208 bytes.
  **Una pista DD tiene ~6250.** No caben: los campos de datos **se solapan** — los 16
  identificadores comparten cuerpo y cada lectura toma una longitud distinta del mismo
  sitio físico. **Nivel 3.**

**Conclusión medida: 7 de los 8 rechazos no necesitan flujo.** Necesitan un formateador
de pista parametrizable (ns, N, GAP3, lista de IDs, marca de datos, longitud real
independiente de la declarada, CRC forzable). Eso es una extensión de `floppy_write`,
que ya tiene el modo `src_en_i` y el motor de celdas probado en hardware.

**Y el que sí lo necesita (Dynamite 4) no se arregla con un escritor de flujo**, porque
el problema está en el ORIGEN: el EDSK no describe esa pista de forma físicamente
reproducible. Para reproducirla hay que leer el disco físico original, o partir de un
formato que describa la pista (HFE, SCP, CTRaw).

### 4. Presupuesto de memoria (calculado, no supuesto)

Pista CPC, DD 250 kbps, 300 RPM: 200 ms / 2 µs = **100.000 celdas de canal por vuelta**.
Con gaps medios de 2,64 celdas → ~37.900 transiciones (coincide con la cifra medida).

| Representación | Por pista | 42 pistas (1 cara) | 2 caras |
|---|---|---|---|
| bitmap de celdas, 1 bit/celda | 12,5 KB | **513 KB** | 1,0 MB |
| clases de gap, 2 bits/transición | 9,5 KB | 398 KB | 797 KB |
| SCP, 16 bits/flujo a 25 ns | 74 KB | 3,1 MB /vuelta | ×3 vueltas ≈ 9,5 MB |

BRAM medida en la última build R6 (`mega65_r6_utilization_placed.rpt`, 2026-09-21):
**230,5 / 365 tiles (63 %)** → quedan **134,5 tiles ≈ 605 KB**. LUTs al 16 %.

* Una **sola pista** en bitmap de celdas: 12,5 KB = 3,5 tiles. Trivial.
* Una **cara entera** en bitmap: 513 KB = 114 tiles → cabe, dejando ~20. Justo.
* El buffer de montaje de 256 KB **no vale** para una cara entera de flujo.
* Multi-vuelta (necesario para sectores débiles) multiplica todo por el nº de vueltas.

→ **Una pista cada vez cabe de sobra. El disco entero en flujo no cabe en BRAM con
holgura.** Pendiente: saber si el core usa la HyperRAM de 8 MB (AExp la usa para las
imágenes ADF). Si está libre, el presupuesto deja de ser un problema.

### 5. Respuestas del usuario (2026-09-21) y lo que implican

1. **Objetivo: el CPC usa la disquetera física EN VIVO, como AExp.** → Es el camino (a):
   un uPD765 sobre motor de flujo. Queda descartado (b), y (c) solo como instrumento.
2. **HyperRAM de 8 MB instanciada y libre** (referencia de uso: QL4M65). → El presupuesto
   de memoria deja de ser restricción: cabe el disco entero en flujo, multi-vuelta
   incluida. Queda por ver la latencia (~9 ciclos tras CDC en AExp) contra el servicio en
   tiempo real del FDC: hay que medir, no suponer.
3. **No hay discos originales protegidos.**

**Consecuencia del punto 3, que resultó ser buena noticia.** El primer impulso fue "sin
original no se puede validar la lectura de flujo". Es falso, y hay un bucle cerrado mejor:

```
imagen EDSK -> copiador arreglado -> disquete físico escrito -> FDC de flujo lo lee en vivo
                                                                      |
                                        comparar contra la imagen de partida <-+
```

Es decir: **los siete arreglos del copiador son, además, el generador de material de
prueba para M5**. Un disquete escrito por nosotros con 10 sectores, con N=3, con un sector
N=6 de CRC malo o con una DAM borrada es exactamente el caso difícil que el FDC de flujo
tiene que sobrevivir, y tenemos la verdad de referencia (el fichero de origen) para
comparar. No hace falta ningún original.

La única clase que queda fuera del bucle es la del nivel 3 (campos solapados), porque no
se puede escribir. Para ésa no hay camino sin un disco original, y conviene asumirlo
desde ya en vez de descubrirlo tarde.

### 6. Entregable de esta sesión

`core\.research\HALLAZGOS-copiador-formatos.md` — informe autocontenido para la sesión de
la v1.0: el bug de `valida_copia.ps1`, qué hay dentro de las 8 imágenes, el presupuesto de
bytes por pista, qué falta en `floppy_copy.vhd` y `floppy_write.vhd` línea a línea, y un
orden de siete pasos con criterio de verificación por paso. Cobertura esperada: de 18/26
imágenes a 25/26.

---

## Sesión 2 (2026-09-21) — El objetivo real y la arquitectura de AExp

### 8. El objetivo, fijado por el usuario

> *"Que lea cuando se hace un CAT o que se cargue algo con el LOAD, no como ahora, que
> tenemos que leer el disco entero al principio. Ese es el objetivo principal. Si luego no
> lee discos anticopia o no, eso lo iremos mejorando poco a poco. Es importante también no
> perder la funcionalidad que tenemos ahora de leer DSKs desde la SD."*

Esto reordena las prioridades por completo. **El problema a resolver es la latencia de
arranque y el modelo de uso, no las protecciones.** Las protecciones pasan a ser un
"luego", y el informe del copiador (`HALLAZGOS-copiador-formatos.md`) las cubre casi todas
sin tocar nada de esto.

### 9. Cómo lo hace AExp exactamente (`adf_track_engine.vhd`, cabecera líneas 42-49)

> *"`phys_en_i = '1'` and `sel = phys_unit_i` -> the MEGA65's real internal mechanism (at
> most ONE unit): reconstructed MFM words from `physical_fdd_top`'s word FIFO are streamed
> to Paula AT REAL DISK PACE (~1 word/32 us …). **The requested track in the status word is
> IGNORED: data comes from wherever the real head is, in rotation order, exactly like a
> real Amiga.**"*

Esa frase es toda la arquitectura. AExp **no busca nada y no cachea nada**: entrega lo que
pasa bajo la cabeza, y el sistema operativo del Amiga (trackdisk) se encarga de encontrar
los sectores donde estén y ordenarlos. Puede hacerlo porque **en el Amiga el decodificador
es software**.

Lo que sí es reutilizable de su diseño, y es mucho:

* Todo el front-end `physical_fdd_*` (ya analizado en la sesión 1).
* **El patrón de convivencia de backends**, que es justo lo que pide el requisito de no
  perder la SD: un motor, varias unidades, despacho por unidad en cada sondeo, y la
  *disciplina de propiedad* como invariante — `serve_unit` se engancha en el sondeo que
  aceptó la petición y no se vuelve a derivar; `drain_unit` igual para escritura. Su
  comentario nombra la clase de defecto: *"a frame belonging to unit B fed into a decoder
  opened for unit A would checksum-verify and commit into unit A's image. That is the one
  defect class that silently corrupts a disk image."*
* **Al cambiar el origen de una unidad, resetean la máquina.** No intentan el cambio en
  caliente (ya se aprovechó en M4014).
* El menú por combos (A/B/C/D) con la capa de dependencias.

### 10. LO QUE YA ESTABA MEDIDO Y CASI ME HACE PROPONER UN CAMINO MUERTO

`DECISIONES.md`, entrada del 2026-09-15:

> *"Tras la medida de latencia (**M4018: el `CAT` falla ya con 100 ms de retardo por
> bloque, lo que descarta la lectura por pistas bajo demanda**)"*

Iba a proponer exactamente eso: dejar el `u765` intacto y alimentarlo desde un caché de
pista rellenado bajo demanda desde el disco físico. **Ya está medido y descartado.**

**Pero hay que leer con cuidado qué midió M4018, porque no es lo mismo que el camino (a).**
Lo que se retrasó fue el **acuse del lado SD, por bloque**. En ese modelo el FDC se queda
mudo mientras espera el bloque entero, y con varios bloques por operación el retardo se
acumula a segundos.

Evidencia de que el `u765` **no** tiene ese problema por diseño (`u765.sv`):

* línea 469: `i_byte_clk_en` se genera cada `CYCLES*32/1000` → **32 µs por byte**. El
  `u765` ya entrega los datos al CPC **al ritmo real de un disco DD**, no de golpe.
* línea 100: `TRACK_TIME = CYCLES*205` → ya modela la vuelta de 205 ms, y la usa (línea
  807) para reiniciar la posición rotacional al final de la pista.
* líneas 99 / 1172 / 1264: `OVERRUN_TIMEOUT = CYCLES` = **1 ms**, y es el timeout del
  **lado CPU** (se recarga en cada byte que el CPC lee o escribe; si el CPC no sigue el
  ritmo → `status[1] = 0x10`, overrun). Es el comportamiento del 765 real.

O sea: la maquinaria de tiempo real hacia el CPC **ya existe y ya funciona**. Lo que M4018
midió es que no se puede meter una espera larga *en medio del camino de la imagen*.

**Conclusión honesta: M4018 no avala el camino (a), pero tampoco lo descarta — mide otra
cosa.** Y la diferencia decide la arquitectura entera, así que hay que medirla antes de
escribir una línea de RTL.

### 11. El experimento que decide, antes de cualquier RTL

Pregunta: **¿cuánto tolera AMSDOS entre el comando y el primer byte, y entre bytes
consecutivos?** Un uPD765 real hace esperar hasta 200 ms a que el sector pase bajo la
cabeza, así que AMSDOS tiene que tolerarlo; lo que no sabemos es dónde está su límite ni
cuál de los dos timeouts saltó en M4018.

Instrumento: ya existe el retardo artificial de M4018 (`floppy_delay`, main.vhd:145-147 —
*"00 = sin retardo, 01 = 100 ms, 10 = 400 ms, 11 = 1 s"*). Lo que hay que cambiar es
**dónde** se inserta:

| Arm | Dónde se inserta el retardo | Qué responde |
|---|---|---|
| A | antes del primer byte de un comando READ DATA, una sola vez | ¿tolera AMSDOS la latencia rotacional? |
| B | entre bytes de un mismo sector | ¿cuál es el margen contra el overrun de 1 ms? |
| C | entre sectores de un multi-sector | ¿hay que entregar la pista en una vuelta? |

Barrido de 0 a 300 ms en cada arm, con `CAT` y con `LOAD`. Resultado esperado y por qué
importa:

* Si A tolera ~200 ms → **el camino (a) es viable** y el diseño puede esperar a la
  rotación, como la máquina real.
* Si A falla pronto → hay que servir desde un caché *rellenado por adelantado* (lectura
  anticipada de la pista siguiente mientras el CPC procesa la actual), y eso cambia el
  diseño de arriba abajo.
* B acota el presupuesto del decodificador al vuelo: si el margen es 1 ms por byte y un
  byte son 32 µs, hay factor 30 de holgura, que es mucho.

**Este experimento es barato, no toca el `u765` y se puede hacer con una sola build.** Es
el siguiente paso, no el diseño.

---

## Sesión 3 (2026-09-21) — EL `u765` YA ES UN FDC ROTACIONAL

Al preparar el experimento de la sección 11 resultó que **dos de sus tres brazos ya están
respondidos por el código que lleva corriendo en hardware desde M2**. Evidencia:

| Fichero:línea | Qué dice |
|---|---|
| `u765.sv:469` | `i_byte_clk_en` cada `CYCLES*32/1000` → **32 µs por byte**, el ritmo real de un DD |
| `u765.sv:1147-1164` | `RW_DATA_EXEC3/4` **espera a que el sector pase bajo la cabeza**: avanza `sector_byte_pos`, compara el ID de cada sector que pasa, y tras dos cruces de índice da *sector not found* |
| `u765.sv:100,807` | `TRACK_TIME = CYCLES*205` + `i_rpm_timer` modelan la vuelta |
| `u765.sv:583` | `fast` solo afecta al **seek**, no a la rotación |
| `main.vhd:1467` | **`fast => '0'`** — el seek también es temporizado paso a paso |

**El `u765` no es "un controlador por imagen": es un FDC rotacional cuyo backend es una
imagen.** Consecuencias, y son grandes:

1. **AMSDOS ya tolera hoy la latencia rotacional completa** — hasta una vuelta entera entre
   el comando y el primer byte. No hay que medirlo: está probado en hardware desde M2 con
   juegos reales cargando. La pregunta de la sección 11 brazo A está contestada.
2. **M5 no necesita reescribir el uPD765.** Necesita **cambiarle el backend**, conservando
   su FSM de comandos, que es la parte cara (1600 líneas). Eso reordena el coste del camino
   (a) de "reescribir un FDC" a "sustituir de dónde salen tres cosas":
   * la lista de sectores de la pista (`sector_c/h/r/n`, `st1/st2`, `sector_length`),
   * la posición rotacional (`sector_byte_pos`, `i_current_sector_pos`), que hoy es un
     modelo libre y tendría que engancharse al índice y al flujo reales,
   * los bytes de datos, hoy desde `sector_ram`.
3. **Queda UNA incógnita**: para servir un sector, el `u765` necesita primero la lista de
   sectores de la pista. Hoy sale del TrackInfo del EDSK (rápido); con disco real hay que
   **descubrirla leyendo una vuelta** (~200 ms) la primera vez que se pisa cada pista. Ése
   es el único punto donde M5 añade latencia que el `u765` no modela ya.

**Y es exactamente lo que M4018 no separó.** Allí se retrasó el acuse de *todos* los
bloques, así que un CAT acumulaba decenas de retardos → segundos. Lo que hay que medir es
el retardo **una vez por pista**, y eso nadie lo ha medido todavía.

Petición de instrumentos enviada a la sesión de la v1.0:
`core\.research\PETICION-instrumentos-M5.md` — tres contadores (latencia rotacional real
observada, recargas de TrackInfo) y un retardo selectivo solo sobre el TrackInfo. Nada de
ello cambia comportamiento con los valores por defecto.

### 11bis. Plan acordado con la sesión de la v1.0 (2026-09-21)

1. Sale **M4057** (pasos 1 y 2 del copiador + rango de `slot` a `0 to 31`) → pruebas en
   hardware: un DATA normal sigue bien, y R-Type Face A arranca en el CPC.
2. **M4058** = los tres instrumentos de `PETICION-instrumentos-M5.md` + menú + `m2mcfg`.
3. Cinco minutos de medida con el CPC.
4. M5 decide arquitectura; la v1.0 sigue con el paso 3 del copiador (N variable).

**Avisos enviados para que la medida no salga engañosa:**

* **El CAT no es prueba suficiente.** El directorio del formato DATA vive en la pista 0, así
  que un CAT toca una sola pista = **una** recarga de TrackInfo, y el retardo selectivo
  apenas se notaría → falso "tolera 400 ms". Hace falta algo que cruce muchas pistas. El
  instrumento 3 (`tlm_tinfo_rd`) es el delator: si tras un CAT marca 1 ó 2, la prueba era
  blanda.
* **Separar rotación de cambio de pista.** `tlm_rot_max` mezcla dos fenómenos si incluye los
  casos con recarga de TrackInfo. Conviene contar aparte los "calientes"
  (`i_secinfo_valid` ya a 1 al entrar) y los "fríos".
* **Ningún resultado bloquea M5.** Si falla ya a 100 ms, sólo obliga a precargar la lista de
  IDs al detectar el SEEK, mientras el CPC procesa la pista anterior.
* **Coste de menú**: `OPTM_SIZE` está hoy en **40** (`config.vhd:363`) y `OPTM_DY` en 17 con
  un comentario que lo liga al total. Un radio de 4 valores lo lleva a 44 y obliga a
  regenerar el `m2mcfg`. Alternativa de un solo item: **un toggle con un único valor de
  200 ms** — que es exactamente lo que cuesta una vuelta, o sea el caso real. La pregunta
  de arquitectura es binaria; el barrido de cuatro valores es refinamiento posterior.

### 11ter. Falsa alarma del reloj del `u765` — y el experimento que sale de ella

La sesión de la v1.0 avisó de que `CYCLES = 4000` (por defecto) con `ce_u765` a 8 MHz daría
16 µs por byte y una vuelta de 102,5 ms, o sea un disco girando a ~585 RPM, y que por tanto
nuestras builds no prueban la tolerancia a 205 ms.

**Verificado en el código: el modelo corre a la velocidad correcta.** Lo que faltaba es el
multiplexado de unidades, `u765.sv:464-473`:

```verilog
if (ce) begin
    i_current_drive <= ~i_current_drive;       // alterna en CADA pulso de ce
    if (i_current_drive) begin                 // ... y el contador solo avanza en uno de cada dos
        i_byte_clk_cnt <= i_byte_clk_cnt + 1'd1;
        if (i_byte_clk_cnt == (CYCLES*32/1000-1)) ... // 32us/byte
```

`i_rpm_timer[i_current_drive][i]` (línea 790) se indexa igual, así que cada unidad recibe un
incremento cada dos pulsos de `ce`. La base de tiempo efectiva es **ce/2 = 4 MHz**:

| | Cuenta | Resultado |
|---|---|---|
| `ce` = `cen_u765` | `cen_16_div = "000"`, 64 MHz / 8 (`main.vhd:828`) | 8 MHz |
| base de tiempo | ce / 2 por el multiplexado | **4 MHz** |
| un byte | `4000*32/1000` = 128 incrementos a 4 MHz | **32 µs** ✓ |
| una vuelta | `TRACK_TIME = 4000*205` = 820.000 a 4 MHz | **205 ms** ✓ |

Y el comentario del autor original, *"8MHz = 4000 (default)"*, queda explicado: con `ce` a
8 MHz la base es 4 MHz, luego 4000 ciclos/ms. Era correcto.

**Conclusión: la sección 10 se mantiene tal cual.** Nuestras builds sí demuestran que AMSDOS
tolera hasta una vuelta de 205 ms, porque el modelo gira a 300 RPM de verdad.

**Pero su experimento de una línea es excelente, con la interpretación invertida.**
`CYCLES = 8000` no corrige nada — pone el modelo al **doble de lento**: 64 µs por byte y
410 ms por vuelta, o sea un disco a 150 RPM. Eso lo convierte en un **test de estrés con
factor 2**:

> Si el CPC sigue cargando bien con `CYCLES = 8000`, entonces AMSDOS tolera **410 ms** de
> latencia rotacional — el doble de lo que M5 llegaría a necesitar. Y también se ralentiza
> el seek, porque `i_steptimer` usa la misma constante.

Es un cambio de una línea en el `port map`, no toca el camino de datos, y da más margen de
información que los tres instrumentos juntos. **Tenía razón en el método.**

Sus dos ajustes de instrumentación se adoptan igual, porque son buena práctica con
independencia de esto: `tlm_rot_*` en unidades crudas de la base de tiempo (que no mienten)
y volcar el `CYCLES` efectivo para que el volcado sea autocontenido.

---

## Sesión 4 (2026-09-21) — MEDIDA: LA INCÓGNITA DE M5 ESTÁ CERRADA

Test de estrés ejecutado en hardware con Bruce Lee, misma SD y misma imagen:

| Build | `C_U765_CYCLES` | Disco emulado | Tiempo de carga | Resultado |
|---|---|---|---|---|
| M4057 | 4000 | 300 RPM, vuelta 205 ms | **31 s** | carga bien |
| M4058 | 8000 | 150 RPM, vuelta **410 ms** | **53 s** | **carga bien** |

**Conclusión, y es la que importa: AMSDOS tolera 410 ms de latencia rotacional — el doble de
lo que M5 llegaría a pedir.** M5 tiene factor 2 de margen, demostrado por medida en hardware
y no por argumento. El retardo selectivo del TrackInfo pasa de decisión de arquitectura a
refinamiento opcional.

El cronómetro hizo además su trabajo de discriminador: 53/31 = 1,71, o sea el tiempo subió
sustancialmente → el `CYCLES` llegó al hardware. Un resultado plano habría sido sospechoso
de "la opción no se aplicó" (la lección de M4023).

### Lo que está medido y lo que está interpolado

La sesión de la v1.0 descompone el tiempo en parte-disco y parte-CPU:

```
  D + C = 31        ->   D = 22 s  (disco)
 2D + C = 53        ->   C =  9 s  (CPU: descomprimir y pintar)
```

**La aritmética es correcta, pero no es una medida: es una interpolación sin grado de
libertad.** Dos ecuaciones con dos incógnitas siempre tienen solución, así que el ajuste no
puede fallar y por tanto no confirma nada. Descansa en dos supuestos no verificados: que la
parte de disco escala exactamente ×2 y que las dos partes son estrictamente serie.

* Para la conclusión principal (¿aguanta 410 ms?) **da igual**: el juego carga, y punto.
* Para la estimación de cuánto ganaría M5 **sí importa**, porque esa cifra sale de aquí.

Validarla costaría un tercer punto: `CYCLES = 6000` debería dar 1,5·D + C = **42 s**. Si
diera otra cosa, el modelo lineal es falso. No es urgente, pero conviene no citar "22 s de
disco" como dato medido hasta entonces.

### Un número que no me cuadra: los 26 s de pre-lectura

La estimación de ganancia de M5 parte de *"26 s de pre-lectura del disco entero"*. Pero
`floppy_mfm.vhd:68-70` dice, a propósito de M4022:

> *"una pista sana se lee en UNA vuelta en vez de dos: el recorrido de 40 pistas baja de
> ~16 s a ~8 s"*

Si la pre-lectura son ~8 s y no 26, la ganancia de M5 cae de 22 s a unos 4, y podría incluso
ser negativa según cuántas pistas toque el juego. Los 26 s pueden incluir montaje, escritura
de la imagen y remontaje — pero entonces hay que decir qué parte es cuál. **Conviene medir la
pre-lectura sola con cronómetro antes de usar esa cifra en ningún sitio público.**

Que quede claro: esto **no afecta a la viabilidad de M5**, que se justifica por el modelo de
uso (leer al hacer CAT, no al montar) y no por el ahorro de segundos. Sólo afecta a cómo se
cuenta.

### 12. Siguiente en este hilo

Diseñar el camino (a): uPD765 sobre flujo. Temas abiertos identificados hasta ahora:

* **La latencia deja de ser gratis.** El `u765` actual tiene modo `fast` (búsqueda y
  lectura inmediatas). Sobre flujo real hay que esperar a que el sector pase bajo la
  cabeza: hasta 200 ms. Es lo que hace la máquina real, pero es una clase de fallo nueva.
* **Qué comandos hacen falta de verdad**: READ ID, READ DATA, READ DELETED DATA, WRITE
  DATA, FORMAT TRACK, READ TRACK, RECALIBRATE, SEEK, SENSE INTERRUPT/DRIVE. El `u765`
  actual declara SCAN y READ TRACK sin implementarlos de verdad (ver su cabecera: *"TODO:
  GAP, CRC generation … SCAN commands … real FORMAT"*).
* **Convivencia con las dos unidades por imagen.** El CPC 6128 tiene A: y B:. Si la física
  es una de ellas, la otra sigue siendo `u765`+vdrives: hay que decidir si conviven dos
  controladores o uno solo con dos backends (AExp resolvió esto con un mux por unidad
  dentro de `paula_floppy.v`, ver su excepción 7).
* **Reloj.** AExp pone el front-end a 50 MHz (dominio QNICE) y cruza con FIFO Gray a los
  28,375 MHz del core. Nosotros vamos a 64 MHz de core; hay que decidir si el front-end
  vive en el dominio del core (sin CDC, celdas de 128 ciclos) o en el de QNICE.

### 6. Herramientas de esta sesión

* `scratchpad/edsk.ps1` — decodificador EDSK completo por sector (C/H/R/N, ST1/ST2,
  longitud real vs declarada, IDs repetidos). `-Full` lista pista a pista.
* `scratchpad/barrido.ps1` — clasifica la colección por nivel de exigencia al escritor.

*(Ambos están en el scratchpad de la sesión; si van a sobrevivir hay que moverlos a
`.research/`, y eso hay que pedirlo.)*
