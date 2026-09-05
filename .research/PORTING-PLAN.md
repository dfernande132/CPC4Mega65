# CPC4MEGA65 — Plan de porting del Amstrad CPC 6128 a MEGA65 vía MiSTer2MEGA65

Este documento es el dossier técnico del port, en el mismo espíritu que
`.research/PORTING-PLAN.md` en QL4M65: anatomía del core original, decisiones
de arquitectura, y milestones con criterio de éxito verificable. El log
día a día de decisiones y hallazgos va en `DECISIONES.md` (raíz del
proyecto, no en este repo — mismo patrón que QL4M65/DECISIONES.md).

## 1. Núcleo MiSTer de referencia

- Repositorio: **MiSTer-devel/Amstrad_MiSTer** — https://github.com/MiSTer-devel/Amstrad_MiSTer
- Cubre CPC6128 (128KB RAM, controlador de disco con escritura), CPC664 y
  CPC464 (menos RAM/ROM, sin FDC de fábrica) como "modelos" seleccionables
  por menú — los tres comparten el mismo RTL, solo cambia el juego de ROMs
  y el tamaño de RAM.
- Copiado en `CORE/Amstrad_MiSTer/` (sin `.git` propio, mismo criterio que
  QL_MiSTer/C64MEGA65/AExp en sus respectivos ports: copia de trabajo, no
  fork/submódulo real hasta que toque).

## 2. Anatomía del core

### 2.1 El módulo `emu` — `Amstrad.sv`

Fichero raíz, instancia entre otras cosas: `pll` (Altera PLL, 64MHz desde
50MHz de referencia), `hps_io`, `sd_card`, `sdram` (ver sección 4 — **aquí
está la diferencia grande frente al QL**), `Amstrad_motherboard` (todo el
"chipset" del CPC), `u765` (FDC), `CPC_Dandanator` (cartucho), `playcity`
(expansión, 2º AY + Z80 CTC), variantes de ratón, `tzxplayer` (cinta).

`Amstrad_motherboard.v` es el verdadero "chipset": instancia `T80pa` (CPU),
`ga40010` (Gate Array — vídeo + contención de memoria + reloj), `UM6845R`
(CRTC), `YM2149` (PSG/AY), `i8255` (PPI), `Amstrad_MMU` (decodificador de
bancos ROM/RAM). No instancia memoria ninguna — expone `mem_rd`/`mem_wr`/
`ram_a`/`romen`/`mreq` hacia quien lo envuelve (`Amstrad.sv`), que es quien
conecta esas señales al controlador de memoria.

### 2.2 CONF_STR — menú OSD actual del core

```
"S0,DSK,Mount A:;"        -> disquete A (vdrive 0)          M2
"S1,DSK,Mount B:;"        -> disquete B (vdrive 1)          M2
"FC0,ROM,Load Main ROM;"  -> ROM principal (OS/BASIC/...)   M1 — imprescindible
"FC3,E??,Load expansion;" -> ROM de expansión                fuera de alcance por ahora
"F4,CDT,Load tape;"       -> cinta                           M5
"F5,ROM,Load Dandanator;" -> cartucho Dandanator             backlog
"F6,SNA,Load snapshot;"   -> snapshot de estado completo     M5
"F7,E??,Load CPC464 ROM;" -> ROM CPC464                      M6 (multi-modelo)
"OK,Tape sound"           -> cableado a "Disabled" en M1
"O[62:61],SNAC"           -> ratón, fuera de alcance por ahora
"OI,Joysticks swap"       -> M3 (joystick)
"R0,Reset & apply model;" -> SÍ, reset básico
"R[32],Reset & Detach Cartridge;" -> backlog (Dandanator)
```

Casi todo lo que no sea "cargar ROM principal" y "reset" se cablea a un
valor fijo en M1 (mismo principio que en QL4M65): sin disquetera, sin
cinta, sin Dandanator, sin PlayCity, sin ratón, sin joystick, modelo fijo a
CPC6128.

## 3. Reloj

Un único PLL de **64MHz** (`rtl/pll/pll_0002.v`, megafunción `altera_pll`
de Cyclone V) a partir de 50MHz de referencia MiSTer. De ahí, clock-enables
derivados por contador (`cen_16` a 16MHz para el secuenciador del Gate
Array, y otros para PSG/FDC) — mismo patrón "menos PLLs, más clock-enables"
que QL4M65 y C64MEGA65. Para MEGA65: MMCM Xilinx desde el reloj de
referencia de la placa (100MHz) generando ~64MHz + los mismos
clock-enables, sustituyendo el `altera_pll`. Sin reconfiguración dinámica
de PLL (no hay equivalente al `pll_cfg` del C64) — un problema menos.

## 4. Memoria — la pieza central de este port

**Diferencia clave frente al QL y el C64**: este core no tiene un `dpram`
por bloque (ROM aquí, VRAM allá) — **absolutamente toda la memoria (RAM
principal, las ROMs, la VRAM, y el buffer de cinta) vive en un único
controlador de SDRAM externa** (`rtl/sdram.v`), con un árbitro round-robin
de 8 estados por ciclo de referencia (`clkref`) y timings ajustados a SDRAM
real (`RASCAS_DELAY`, `CAS_LATENCY`, `STATE_READY` a 7 ciclos). No hay
"un `altsyncram` que sustituir" — hay que **rediseñar de una vez el
subsistema de memoria completo**.

### 4.1 Interfaz exacta que hay que preservar (de `Amstrad.sv:607-632`)

```verilog
sdram sdram (
    .clk(clk_sys), .clkref(ce_ref),        // clkref marca el ritmo del ciclo de memoria
    .oe  (mem_rd & ~mf2_ram_en),           // nivel, no pulso
    .we  (mem_wr & ~mf2_ram_en & ~mf2_rom_en),
    .addr(ram_a),                          // 23 bits (o boot_a/mf2/dandanator overlay)
    .bank(model),                          // 2 bits: CPC6128/664/464/Dandanator
    .din (cpu_dout),
    .dout(ram_dout),                       // -> cpu_din vía AND con el resto de periféricos (idle = 0xFF)

    .vram_bank(model), .vram_addr(...), .vram_dout(vram_dout),  // puerto separado, CRTC/GA
    .tape_addr(...), .tape_din(...), .tape_dout(...), .tape_wr(...), .tape_rd(...)  // puerto separado, cinta
);
```

`ga_ready` (el `READY` del Gate Array, `Amstrad_motherboard.v:119`) es
quien mete wait-states al Z80 (`wait_n = ready | ...`, vía su propio
secuenciador `S[7:0]` a 16MHz) — **independiente de la latencia real de la
memoria**. Esto es la buena noticia encontrada al analizar el core: una
BRAM síncrona (1-2 ciclos) cabe sin problema dentro del presupuesto de 7
ciclos que ya tolera el diseño original; no hace falta imitar el timing de
SDRAM, solo mantener el mismo contrato de puertos (`oe`/`we` a nivel,
`dout` combinacional, un puerto de vídeo aparte). **Aun así, esto se trata
como su propio milestone (M1A) y no como un detalle** — es exactamente el
tipo de suposición que solo se confirma con hardware real, como pasó con
el QL y HyperRAM (`M3001`/`M3002` en `DECISIONES_QL.md`).

### 4.2 Diseño propuesto para M1A (revisado contra la Porting Guide oficial — ver `learning_cores/MiSTer2MEGA65.wiki/Traducido/`, Parte I §1.4 y Parte III §3.A/3.F/3.I)

**Regla de partida (S72, Parte II §2.6): la memoria se divide por *quién
necesita alcanzarla*, no por lo que era una sola SDRAM en el original.**
Eso cambia el diseño inicial (un solo bloque RAM+ROM) por dos bloques
separados:

- **RAM principal (128KB), privada al core, SIN puerto QNICE.**
  Nada externo escribe en ella en M1 (la carga de `.SNA`, que sí necesitaría
  tocar RAM desde QNICE, es M5 — fuera de alcance). Aplicando la lección de
  AExp (S73/3.F.2: un puerto QNICE en una memoria grande y dispersa por el
  die casi rompe timing en el port del Amiga, `WNS -0.757ns`, y se quitó
  por completo porque no hacía falta) — la RAM del CPC no lleva puerto
  QNICE desde el diseño, no como optimización posterior. Vive en `main.vhd`
  (privada al core, S72), instanciada como `dualport_2clk_ram` de 8 bits
  (bus del Z80 ya es de 8 bits — a diferencia del QL/Amiga de 16 bits, aquí
  no hace falta partir en carriles de byte, S74 no aplica):
  - **Puerto A** = CPU/MMU (`ram_a`/`mem_rd`/`mem_wr`/`cpu_dout`↔`ram_dout`),
    flanco de subida, reloj de core.
  - **Puerto B** = lectura de vídeo del CRTC/GA (`vram_addr`, solo lectura),
    también flanco de subida, mismo reloj de core — la pantalla del CPC
    siempre vive en RAM, nunca en ROM, así que no hace falta un tercer
    puerto en ningún bloque.
- **Las 4 ROMs de la CPC6128** (OS 16K, BASIC 16K, AMSDOS 16K, MF2 16K =
  64KB), en un bloque `dualport_2clk_ram` aparte que SÍ necesita puerto
  QNICE (S72): la máquina las carga por SD vía el mecanismo `CRTROM` de
  M2M (Parte III §3.I.2 — arrays `C_CRTROMS_AUTO`/`C_CRTROMS_MAN` en
  `globals.vhd`), igual que el Kickstart del Amiga o Minerva del QL: **sin
  `ROM_PRELOAD`** (contenido con copyright, no se puede hornear en el
  bitstream) — `C_CRTROMTYPE_MANDATORY` es lo más parecido semánticamente
  (sin ROM de sistema el CPC no arranca, igual que el Amiga sin
  `kick.rom`), a decidir junto con qué imagen de ROM concreta usar para
  las pruebas (ver sección 8).
  - **Puerto A** = CPU/MMU, flanco de subida, reloj de core.
  - **Puerto B** = QNICE, `FALLING_B => true` (S73/3.F.2 — el contrato
    estándar del framework, sin sincronizador propio). Direccionamiento
    byte a byte simple (bus de 8 bits): mismo patrón que la RAM plana del
    C64 (§3.I.1 — `x"00" & ram_byte`, direccionamiento palabra-por-byte),
    no hace falta el reparto par/impar en dos carriles que sí necesitó el
    Kickstart de 16 bits del Amiga.
  - Solo 64KB (16 tiles BRAM aprox.) — pequeño, dentro del presupuesto de
    medio periodo de 10ns que exige el flanco de bajada de QNICE (S73).
- **Buffer de cinta** (`tape_addr`/`tape_din`/`tape_dout`): fuera de
  alcance en M1 (cinta es M5). El puerto se deja sin conectar/deshabilitado
  hasta M5, momento en el que si hace falta (por tamaño) sí sería candidato
  razonable a HyperRAM (Parte I §1.4.3) — es tráfico DMA/tolerante a
  latencia, no bus del Z80, la misma distinción que ya se usó para los
  microdrives del QL. Dandanator/MF2 overlay (`mf2_ram_en`/`dan_ena`)
  igual: fuera de M1, decisión de BRAM vs HyperRAM pospuesta a cuando toque
  (M6/backlog).
- **`Amstrad_MMU.v`** se mantiene tal cual (es solo lógica de selección de
  banco, no tiene memoria propia) delante de los dos nuevos bloques —
  ahora tiene que decodificar hacia RAM o hacia ROM por separado, en vez de
  hacia una única `sdram.v` con `bank`/`addr` unificados.
- **`sdram.v` se excluye completo de la compilación** (usa `altddio_out`,
  primitiva Cyclone V, y su lógica de timing no aplica) — se sustituye por
  dos instancias `dualport_2clk_ram` (nombres a decidir, p.ej. `cpc_ram.vhd`
  / uso directo del componente de M2M sin wrapper propio, ya que aquí no
  hay peculiaridades de `altsyncram` que reproducir — a diferencia de los
  wrappers `dpram.v`/`spram.v` de otros cores, este core no tiene ningún
  envoltorio Altera per-bloque que imitar, ver sección 2 y 7).
- **Presupuesto**: 128KB RAM + 64KB ROM = 192KB en BRAM para M1 — muy por
  debajo de la "regla de 1,4MB" (Parte I §1.4.2), no hay riesgo de
  saturación de BRAM como le pasó al Amiga (§1.4.4) en esta fase.

### 4.4 Razonamiento de timing S75 — hecho, para el camino CPU/RAM (2026-09-04)

Análisis "trabajado" (S75) del secuenciador `S[7:0]` de `ga40010.sv`,
hecho a mano a partir del RTL (no de documentación externa del chip real):

- `S[7:0]` es un **contador Johnson de 8 etapas** (`S[0] <= ~S[7]`, resto
  desplazamiento), reloj `clk`=`clk_sys` habilitado por `cen_16`. Un
  contador Johnson de 8 etapas tiene periodo **16 ticks**. `clk_sys`=64MHz
  (PLL de `Amstrad.sv`), `cen_16` = 1 de cada 4 ciclos de `clk_sys`
  (`ce_16 <= !div[1:0]`, `Amstrad.sv:128`) = 16MHz → **una vuelta completa
  del secuenciador = 16 ticks × 62,5ns = exactamente 1µs**, la tasa de
  ciclo de 1MHz del Gate Array real conocida en la literatura del CPC —
  buena señal de que la reconstrucción del contador es correcta.
- Simulando a mano las 16 posiciones del contador Johnson (`S_k`,
  k=0..15) y las ecuaciones combinacionales `RAS_N<=(S[6]|~S[2])&S[0]`
  (registrada a `cen_16`), `CASAD_N<=RAS_N` (registrada a `cen_16`, un
  tick más de retardo) y el latch RS de `READY` (`rslatch`: set
  prioritario en `S[3]&~S[6]`, reset en `CASAD_N`) da la señal `READY`
  completa a lo largo del ciclo de 16 ticks:

  | k (tick `cen_16`) | 0-2 | 3-9 | 10-15 |
  |---|---|---|---|
  | `READY` | 0 (CPU esperando) | 1 (CPU corre) | 0 (CPU esperando) |

  Es decir, el Z80 está en estado de espera (`wait_n=0`, vía
  `Amstrad_motherboard.v:152`) durante **9 de los 16 ticks = 562,5ns**, y
  libre durante los 7 restantes = 437,5ns, por cada ciclo de 1µs.
- **Conclusión**: `READY` es una señal *generada internamente* por el
  secuenciador del Gate Array, totalmente independiente de si la memoria
  real ha respondido o no — el `sdram.v` original tenía que terminar su
  ciclo de 7 estados (a `clkref`=8MHz, ~875ns de margen dentro de la
  ventana) para no servir datos corrompidos, pero el propio `READY` nunca
  esperó a la memoria. Una `dualport_2clk_ram` (lectura síncrona, 1 ciclo
  de `clk_sys` = 15,6ns, S75) cabe con un margen de **~20-35x** dentro de
  la ventana de 562,5ns en la que la dirección (`ram_a`, estable todo el
  ciclo del Z80 por diseño del propio Z80 — `RD_n`/`WR_n`/`MREQ_n` no
  cambian mientras hay wait-states) ya está presentada. **No hace falta
  imitar ningún wait-state ni cambiar el timing de `READY`** — el
  contrato de contención original se preserva exactamente igual con
  memoria más rápida, porque `READY` nunca dependió de la latencia real
  de la memoria, solo de su propio contador.

### 4.5 Razonamiento de timing S75 — puerto de vídeo, cerrado (2026-09-04)

Trazado el pipeline `vram_bs`/`vram_din_shift`/`vram_d` de
`Amstrad_motherboard.v:191-215` y la generación de `CAS_N` en
`casgen_sync.v` (que a su vez depende de `S_d1_a`/`S_d2_a`, dos registros
más de retardo sobre una función de `S`, y de `U708`/`U712`, que dependen
del estado vivo de `MREQ_N`/`M1_N` del Z80, no solo del contador libre —
por eso el `CAS_N` real no se puede tabular con la misma tabla de 16 filas
que `READY`, a diferencia del camino CPU).

**El argumento que sí cierra la pregunta, sin necesitar tabular `CAS_N`
entero**: `vram_addr <= crtc_vram_addr` se actualiza en **cada ciclo de
`clk_sys`** (siempre que `cpu_n` no esté bajo), seguido continuamente —
no es una petición bajo demanda como en `sdram.v` original (que solo
lanzaba una petición de vídeo cuando detectaba que la dirección había
*cambiado*). Pero `crtc_vram_addr = {MA[13:12], RA[2:0], MA[9:0]}` viene
del CRTC, que solo avanza `MA`/`RA` **una vez por carácter de vídeo — a
1MHz, es decir cada 64 ciclos de `clk_sys`** (el mismo ciclo de 1µs del
secuenciador de la sección 4.4). El punto exacto dentro de esos 64 ciclos
en el que `casgen_sync` abre la ventana `!ras_n & !cas_n` para capturar el
byte (en torno a `k=2`/`k=13`, sección anterior) es irrelevante para nuestro
diseño: **la dirección de vídeo lleva entre decenas y hasta 64 ciclos
completos de `clk_sys` sin cambiar antes de que se consuma**, frente a la
latencia de 1-2 ciclos de una `dualport_2clk_ram` síncrona. El `sdram.v`
original necesitaba hasta 7 ciclos de `q` para completar su petición de
vídeo (prioridad más baja del árbitro round-robin) y aun así llegaba a
tiempo siempre — nuestra BRAM, con margen de un orden de magnitud mayor
sobre una ventana de disponibilidad igual o mayor, cierra exactamente el
mismo argumento que el camino CPU (sección 4.4): **el nuevo puerto de
vídeo no necesita replicar el pipeline de latencia de `sdram.v`, solo
presentar `vram_din` como lectura síncrona normal de 1 ciclo sobre
`vram_addr`** — la lógica de `vram_bs`/`vram_din_shift`/`vram_d` en
`Amstrad_motherboard.v` (que decide CUÁNDO capturar el byte, no cuánto
tarda la memoria) se conserva sin cambios.

**Conclusión de la sección 4 completa**: el diseño de M1A (sección 4.2,
dos bloques `dualport_2clk_ram` — RAM sin puerto QNICE con puerto B de
vídeo, ROM con puerto QNICE) queda validado en timing para ambos caminos
de consumo (CPU y vídeo). No queda ninguna incógnita de S75 abierta antes
de escribir el VHDL real.

**CDC**: la mayor parte ya la resuelve el framework (Parte III §3.F.1 — CSR,
vector OSM, reset, todo cruza QNICE↔core sin código propio). El único CDC
de memoria que nos toca es el puerto B de la ROM hacia QNICE, y ya lo
resuelve por construcción el propio `dualport_2clk_ram` con `FALLING_B`
(§3.F.2) — no hace falta sincronizador ni handshake adicional para M1A.

### 4.3 Dimensionamiento

128KB RAM + 64KB ROM = 192KB en BRAM para M1 — a comprobar contra el
presupuesto real de BRAM de la Artix-7 del MEGA65 (igual que QL4M65 verificó
1024KB antes de prometerlo). Para M6 (RAM ampliada hasta 512KB según el
README del core + ROMs de los 3 modelos) habrá que rehacer esta cuenta.

## 5. Periféricos — semántica exacta

- **Teclado**: matriz directa CPC (fila/columna vía PPI `i8255`), sin
  microcontrolador intermedio — mucho más simple que el QL (que emulaba un
  8049 real), más parecido al patrón del C64 (`keyboard.vhd` MEGA65-nativo
  hablando directo con `i8255`).
- **FDC** (`rtl/u765/u765.sv`): uPD765/i8272-compatible, con escritura real.
  Buffers internos (`u765_dpram`, RAM de comportamiento neutro) ya
  sintetizan en Vivado sin tocar — el trabajo real es el protocolo
  LBA/sector hacia `vdrives.vhd` de M2M (más parecido al patrón D64 de
  C64MEGA65 que al problema de "cinta continua" del microdrive QL).
  Milestone 2.
- **CRTC** (`rtl/UM6845R.v`): 6845-compatible, solo registros, sin RAM
  propia — lee vídeo de la RAM principal (ver 4.2). Milestone 1.
- **Gate Array** (`rtl/GA40010/ga40010.sv`): genera `READY`/contención,
  HSYNC/VSYNC/INT, decodificación ROM/RAM, mezcla de color. Milestone 1.
- **PSG** (`rtl/YM2149.sv`): AY-3-8912-compatible, vía PPI (puerto A +
  BC1/BDIR), sin RAM propia. Milestone 1 (o justo después, no es
  bloqueante para llegar al prompt de BASIC).
- **Joystick**: no instanciado directamente en `Amstrad_motherboard.v` en
  el análisis inicial — a confirmar en Fase de diseño de M3 cómo se lee
  (probablemente vía PPI, como en el CPC real "protocolo Amstrad" de
  joystick en el puerto del segundo AY). Milestone 3.
- **Disquetera física del MEGA65**: el framework M2M expone las señales
  físicas crudas (`f_motora_o`, `f_step_o`, `f_stepdir_o`, `f_rdata_i`,
  `f_wdata_o`, `f_wgate_o`, `f_side1_o`, `f_track0_i`, `f_index_i`,
  `f_writeprotect_i` — ver `M2M/MEGA65-R6.xdc`) pero **ningún core hermano
  las usa** (QL4M65/C64MEGA65/AExp las dejan atadas a inactivo en
  `framework.vhd`). No hay controlador MFM/FM de referencia en todo el
  ecosistema M2M — es territorio nuevo, tratado como su propio milestone
  (M4), separado del `u765`/imagen `.DSK` de M2 (que sí seguirá siendo el
  camino "por SD").
- **Cinta** (`tzxplayer.vhd`, formato `.CDT`): Milestone 5.
- **Snapshot** (`.SNA`): carga de estado completo (CPU+RAM+registros) de un
  tirón — Milestone 5, buen complemento de cinta porque permite arrancar
  programas sin depender de disquetera/cinta funcionando.
- **Dandanator, PlayCity, ratón/SNAC**: backlog, no milestone cerrado.

## 6. Milestones

Cada uno con criterio de éxito verificable en pantalla, empezando por el
arranque nativo más simple:

### Milestone 1 — Arranque nativo del CPC6128

**Criterio**: el CPC6128 arranca hasta el prompt `BASIC 1.1 Ready`, teclado
funcionando, vídeo PAL **por HDMI y por VGA** (las dos salidas estándar del
pipeline de vídeo de M2M — verificar explícitamente que VGA funciona, no
darlo por hecho: el QL4M65 se quedó con un bug de VGA sin investigar,
ver su README "Known issues"). Sin disquetera, cinta, Dandanator,
PlayCity, snapshots, joystick, ratón. Modelo fijo CPC6128, RAM fija 128k.

- **1A — Subsistema de memoria** (sección 4.2): sustituir `sdram.v` por
  BRAM propia (RAM+ROM+VRAM), preservando el contrato de `ga_ready`.
- **1B — CPU + GA + CRTC + PSG + teclado**: instanciar `T80pa`, `ga40010`,
  `UM6845R`, `YM2149`, `i8255`, `Amstrad_MMU` en `main.vhd`/`mega65.vhd`;
  teclado MEGA65→matriz CPC; reloj MMCM Xilinx sustituyendo `altera_pll`.

### Milestone 2 — Disquetera por imagen (`.DSK`/EDSK desde SD)

**Criterio**: cargar un juego real desde `.DSK` con `|A`/`RUN"..."` y
confirmar guardado persistente tras recargar. Buffers de `u765.sv` ya son
Vivado-clean; el trabajo es el puente `u765`↔`vdrives.vhd`.

### Milestone 3 — Joystick

**Criterio**: un juego que use joystick responde correctamente desde un
mando conectado al MEGA65. Prioridad alta pese a ser sencillo: máquina de
juegos de 8 bits, coste de implementación bajo.

### Milestone 4 — Disquetera física interna del MEGA65

**Criterio**: leer/escribir un disquete físico real, con formato CPC,
insertado en la disquetera del propio MEGA65. Requiere diseñar un
controlador MFM/FM desde cero sobre las señales `f_*` del framework — no
hay precedente en QL4M65/C64MEGA65/AExp. Milestone de riesgo/novedad alto,
comparable a 1A.

### Milestone 5 — Cinta (`.CDT`) y snapshots (`.SNA`)

**Criterio**: cargar un `.CDT` por `tzxplayer` y arrancar directo un
`.SNA`. Aún en CPC6128. Candidatos razonables a HyperRAM (tráfico DMA, no
bus del Z80) si el tamaño lo justifica.

### Milestone 6 — Multi-modelo y RAM ampliada

**Criterio**: selector de modelo (CPC6128/664/464) en el menú, RAM
ampliable más allá de 128k (hasta 512k según el README del core),
dimensionado contra presupuesto real de BRAM antes de prometer un tamaño.

### Backlog (`ROADMAP.md`, sin milestone cerrado)

Dandanator (cartucho), PlayCity (2º AY + Z80 CTC), ratón/SNAC, build para
R3, publicación en GitHub.

## 7. Lista de ficheros IN/OUT (borrador, según `files.qip` del core original)

```
rtl/T80/*                  CPU T80pa (VHDL) — SÍ, milestone 1
rtl/GA40010/ga40010.sv     Gate Array — SÍ, milestone 1 (excluir variantes *_sim.v/VERILATOR)
rtl/UM6845R.v              CRTC — SÍ, milestone 1
rtl/YM2149.sv              PSG — SÍ, milestone 1
rtl/i8255.v                PPI — SÍ, milestone 1
Amstrad_MMU.v              decodificador de bancos — SÍ, milestone 1 (sin cambios)
Amstrad_motherboard.v      integración — reescrito como main.vhd/mega65.vhd
rtl/sdram.v                OUT — usa altddio_out, timing SDRAM real; sustituido por BRAM propia
rtl/pll/pll_0002.v, rtl/pll.v   OUT — altera_pll; sustituido por MMCM Xilinx
rtl/u765/u765.sv           SÍ, milestone 2 (buffers internos ya Vivado-clean)
rtl/playcity/*             OUT de milestone 1-6, backlog
rtl/dandanator/*           OUT de milestone 1-6, backlog
rtl/tzxplayer.vhd          SÍ, milestone 5
Amstrad.sv                 NO se porta tal cual — se reescribe como main.vhd
sys/*                      framework MiSTer genérico — fuera por definición, M2M ya tiene sus equivalentes
```

Nuevo, no presente en el core original: `CORE/vhdl/keyboard.vhd`
MEGA65-nativo (matriz CPC vía PPI), `CORE/vhdl/cpc_ram.vhd` o similar
(sustituto de `sdram.v`, sección 4.2).

## 8bis. M1A: RTL escrito (2026-09-04)

Primer VHDL real del proyecto, en `core/CORE/vhdl/` (ficheros que el porter posee, no
compartidos del framework — ver Parte III §3.I.1 de la Porting Guide, así que no hace falta
ninguna entrada en `doc/m2m/exceptions.md` para estos cambios):

- **`globals.vhd`**: `CORE_CLK_SPEED` a 64MHz; `C_VDNUM/C_VD_DEVICE/C_VD_BUFFER` a "sin usar"
  (disquetera es M2); dos entradas `C_CRTROMS_AUTO` (OS y BASIC, ambas `C_CRTROMTYPE_MANDATORY`,
  dispositivos `C_DEV_CPC_ROM_OS`/`C_DEV_CPC_ROM_BASIC` en `0x0100`/`0x0101`) con nombres de
  fichero **provisionales** (`/cpc4mega65/os6128.rom`, `/cpc4mega65/basic6128.rom` — pendiente de
  decisión real, sección 8).
- **`main.vhd`**: instancia los tres bloques de memoria de la sección 4.2 —
  `dualport_2clk_ram` de 128KB (RAM, sin puerto QNICE) y dos de 16KB (ROM OS/BASIC, con puerto
  QNICE `FALLING_B=>true`). Nuevos puertos de entidad para el lado QNICE de las ROMs
  (`qnice_clk_i`, `qnice_rom_{os,basic}_{we,addr,data}_i/o`).
- **`mega65.vhd`**: pasa esas señales entre `qnice_dev_*` y `i_main` (nuevo `when
  C_DEV_CPC_ROM_OS/BASIC` en `core_specific_devices`, mismo patrón que el Kernal ROM de
  C64MEGA65). `i_vdrives` se queda instanciado con `VDNUM=0` (patrón soportado por el
  framework) en vez de borrarlo, para no reintroducirlo desde cero en M2.
- **`clk.vhd`**: MMCM recalculado para 64MHz exactos (100MHz×8.000/12.500) — aritmética
  verificada a mano (VCO=800MHz, dentro de rango Artix-7 -2), **timing real sin verificar en
  Vivado todavía**.

**Decisión que cambia el plan original — `Amstrad_MMU.v` NO se toca, ni falta.** El plan
original (sección 4.2, versión anterior) asumía que había que "adaptar" la MMU para producir
`rom_a`/`ram_a` separados. Analizando `Amstrad_MMU.v` a fondo: su salida `ram_A[22:0]` ya
codifica RAM (bits altos siempre `00`) y ROM (bits altos dependientes de `A[15]`/`ROMbank`) en
rangos que nunca colisionan **solo porque comparten el mismo espacio de direcciones de 8MB de
la SDRAM original** — una vez que RAM y ROM son dos BRAMs físicamente separadas, esa
codificación deja de ser necesaria: basta con tomar `ram_A[16:0]` para la RAM (aritmética de
`RAMmap`/`RAMpage` sin tocar) y derivar la selección OS/BASIC directamente de `A[15]` +
`ROMEN_N` (ya calculado por la Gate Array) en `main.vhd`, sin pasar por la rama ROM de la MMU
en absoluto. Cero riesgo, cero superficie de excepción — mejor que el plan original.
Documentado con detalle (incluyendo por qué `ROMbank=0→página 0x100` decodifica a "BASIC" y no
a "OS", una confusión real que costó un rato desentrañar) en `DECISIONES.md`.

**Lo que queda explícitamente para M1B** (marcado `@TODO M1B` en el código): los puertos A de
los tres bloques de memoria y el puerto B de vídeo de la RAM están atados a valores fijos/no
usados — no hay ningún CPU real todavía, `main.vhd` sigue corriendo el `democore` de la
plantilla. M1B sustituye el democore por `T80pa`+`ga40010`+`UM6845R`+`YM2149`+`i8255`+
`Amstrad_MMU` y conecta de verdad estos tres bloques, más `keyboard.vhd` (matriz CPC vía PPI,
más simple que el QL — sin microcontrolador 8049 emulado) y el `clk.vhd` ya preparado arriba.

## 8ter. M1B: RTL escrito (2026-09-04)

CPU+Gate Array+CRTC+PSG+PPI+MMU reales, sustituyendo el `democore` de la plantilla. Decisión
central: **`Amstrad_motherboard.v` se instancia tal cual desde `main.vhd`** (frontera de
lenguaje mixto VHDL/Verilog estándar del framework, Parte III §3.E) en vez de reimplementar
su cableado interno CPU↔GA↔CRTC↔PSG↔PPI↔MMU — ese cableado ya es correcto en el core
original (confirmado leyendo `Amstrad_motherboard.v` entero), así que la única superficie de
riesgo real es la interfaz externa (memoria, vídeo, teclado, reloj), no el interior.

**Única modificación real al core MiSTer**: se quitó el submódulo `hid` (traductor PS/2→matriz)
de `Amstrad_motherboard.v`, sustituido por dos puertos nuevos (`kbd_row_o`/`kbd_col_i`) que
`CORE/vhdl/keyboard.vhd` alimenta directamente — mismo patrón que QL4M65/C64MEGA65 con sus
propios submódulos de teclado. **Documentado en `core/doc/m2m/exceptions.md`** (primera
entrada de ese fichero en este proyecto). La tabla fila/columna de `keyboard.vhd` se extrajo
del propio `rtl/hid.sv` (su `case` de códigos PS/2), no de documentación externa — quedan sin
mapear a propósito: las teclas del teclado numérico dedicado del CPC (Enter/./Copiar propios),
los símbolos `[ ] \`, media docena de atajos F0/F2/F4/F6/F8 del keypad, y la superposición de
joystick-como-teclado (filas Y=6/9 del `hid` original — pospuesta a Milestone 3).

**Entradas fijadas para M1** (todas justificadas contra `Amstrad.sv` con los valores por
defecto de sus opciones OSD, no inventadas): `ppi_jumpers="1111"` (Amstrad+50Hz),
`crtc_type='1'` (Type 1/UM6845R — el real del CPC6128), `sync_filter='1'` (fijo en el
original), `no_wait='0'` (timing de contención auténtico), `ram64k='0'` (modelo 6128),
`sna_*`/`irq`/`nmi` inactivos (snapshot y PlayCity fuera de alcance).

**Escrituras a ROM**: el core original, con una única SDRAM compartida, dejaba que una
escritura con ROM activa corrompiera la copia de la ROM en la SDRAM (inofensivo en la
práctica, pero un efecto secundario real). Con dos BRAMs separadas eso ya no es replicable
tal cual — se decidió que las escrituras vayan siempre a RAM y nunca a ROM (`wren` de los
bloques ROM fijo a `'0'`), que además es *más* fiel al hardware real (un chip de ROM no
tiene pin de escritura) que el comportamiento del propio core original.

**Ensamblador de vídeo**: como `dualport_2clk_ram` no soporta anchos de puerto distintos por
lado, y `Amstrad_motherboard` espera una palabra de 16 bits (`vram_din`) para su `vram_addr`
de 15 bits, se añadió una pequeña FSM de 3 estados en `main.vhd` que hace dos lecturas de 8
bits del puerto B de la RAM y las combina — margen de sobra según el análisis de la sección
4.5 (~64 ciclos disponibles, la FSM solo necesita 3).

**`build_core.tcl` escrito y BUILD_OK conseguido (M1B001, 2026-09-05)** - lista de ficheros
tomada literalmente de `files.qip`/`T80.qip`/`ga40010.qip`, más el hook `synth_pre.tcl`
(reconstruye el firmware QNICE antes de sintetizar - ya venía con la plantilla M2M). Primera
build real: WNS=0.205ns, WHS=0.053ns (timing cumplido de verdad). `.cor` empaquetado en
`E:\CPC4MEGA65\CPC4MEGA65-CoreCPC-M1B001_r6.cor`. Detalle completo de los ~10 intentos y sus
causas raíz (submódulo QNICE sin iniciar, CRLF en scripts WSL, `exec pwd` inexistente en
Windows, `[Synth 8-10632]` en 5 ficheros, colisión de palabra reservada `do` en
`Amstrad_motherboard.v`, y un bug real de `vdrives.vhd` con `VDNUM=0` que ni QL4M65 ni
C64MEGA65 ni AExp tienen porque corren una copia más antigua del framework) en
`DECISIONES.md`, sección "M1B001".

**Pendiente real, no resuelto todavía**:
- No hay ninguna ROM de CPC (OS/BASIC) cargada todavía - el build compila y sintetiza pero el
  CPC en sí no puede arrancar sin ellas (sección 8, decisión pendiente de qué imágenes usar).
  Sin esto, la prueba en hardware real mostrará la pantalla de "fichero obligatorio no
  encontrado" del Shell, no un arranque del CPC.
- El teclado (tabla extraída de `hid.sv`, nunca simulada) sigue sin probarse en hardware.
- Vale la pena reportar aguas arriba el bug de `vdrives.vhd`/`VDNUM=0` en algún momento
  (ver `exceptions.md`) - no hecho todavía, sin GitHub por ahora.

## 8. Decisiones pendientes

1. **Diseño de memoria M1A (sección 4.2) ya validado contra la Porting
   Guide oficial** (RAM sin puerto QNICE, ROM con puerto QNICE vía CRTROM,
   sin byte-lanes por ser bus de 8 bits) — queda decidir el nombre de
   ficheros concretos y si se usa el componente `dualport_2clk_ram` de M2M
   directamente o un wrapper propio (probablemente innecesario aquí, a
   diferencia de otros cores que sí necesitan reproducir peculiaridades de
   `altsyncram`).
2. **Razonamiento de timing S75 — cerrado para ambos caminos** (secciones
   4.4 CPU/RAM y 4.5 vídeo): márgenes de un orden de magnitud o más en los
   dos casos. No queda ninguna incógnita de timing de memoria abierta antes
   de escribir VHDL real.
3. ROM de sistema concreta para las pruebas de M1 (OS/BASIC/AMSDOS/MF2 —
   pendiente de decidir cuál usar, análogo a la elección Minerva/JS-ROM
   del QL) y qué `C_CRTROMTYPE_*` exacto usar (candidato: `MANDATORY`,
   a confirmar contra el comportamiento real que se quiera si falta la ROM).
