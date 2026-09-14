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

**CUMPLIDO en hardware real con M2001 (2026-09-06)**: juego cargado desde
`.DSK`, CP/M arrancado, y guardado persistente confirmado tras recargar.
Ver `DECISIONES.md` y la sección 9 de este documento para el diseño y las
tres builds que costó el timing de los cruces de dominio. Lo que no estaba
en el criterio y se añadió después a petición del usuario (M2002): LED de
disquetera rojo/azul y zumbido del motor, portados de QL4M65.

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

## 9. M2A: diseño de la disquetera `.DSK` (2026-09-06)

Estudio previo a escribir RTL, con el mismo criterio que funcionó en M1: entender la frontera
antes de tocarla. La pregunta central de M2 es **de qué dominio de reloj es cada mitad del
`u765`**, porque la Porting Guide (Parte III §3.I.3) marca ahí una trampa explícita:

> «**TRAP:** en MiSTer estos puertos van con "clk_sys", lo que *parece* dominio del core; en
> M2M corren con el reloj de QNICE, y `vdrives` hace el CDC internamente. Cablea el lado SD de
> tu modelo de disquetera al reloj de QNICE exactamente como hace el `iec_drive` del C64.»

### 9.1 Reparto de dominios en `vdrives.vhd` (leído, no supuesto)

`vdrives.vhd:126-175` separa sus puertos con comentarios de sección:

| Lado | Señales | Notas |
|---|---|---|
| **Dominio core** | `img_mounted_o`, `img_readonly_o`, `img_size_o`, `img_type_o`, `drive_mounted_o`, `cache_dirty_o`, `cache_flushing_o` | ya vienen con CDC hecho dentro (`xpm_cdc_array_single`, `vdrives.vhd:242-272`) |
| **Dominio QNICE** | `sd_lba_i`, `sd_blk_cnt_i`, `sd_rd_i`, `sd_wr_i`, `sd_ack_o`, `sd_buff_addr_o`, `sd_buff_dout_o`, `sd_buff_din_i`, `sd_buff_wr_o` | sin CDC: es responsabilidad nuestra |

`AW=13`/`DW=7` (`vdrives.vhd:103-104`) → `sd_buff_addr_o` es de 14 bits. El `u765` pide 9. Con
`BLKSZ=2` (512 B, el tamaño natural del sector de un `.DSK`) y `sd_blk_cnt` = 0 —el `u765` ni
siquiera tiene puerto `sd_blk_cnt`, así que siempre pide **un** bloque— el firmware solo usa
las direcciones 0..511, luego `sd_buff_addr_o(8 downto 0)` es exacto, no un recorte optimista.

### 9.2 El `u765` NO tiene la separación de relojes que sí tenían QL4M65 y C64MEGA65

Este es el hallazgo que diferencia M2 del trabajo equivalente en los cores hermanos:

- **QL4M65** reutilizó `sd_card.sv`, que ya nace con dos relojes independientes (`clk_sys` para
  el lado bloque, `clk_spi` para el bit-shifting SPI) y con su buffer `sdbuf` ya declarado como
  RAM dual-port de doble reloj (`clock0`/`clock1`, `sd_card.sv:88-96`). Su propio documento de
  diseño lo dice con todas las letras: *«No new CDC bridge needed — reuse as-is»*
  (`learning_cores/QL4M65/.research/qlsd-design.md:98`).
- **C64MEGA65** reutilizó `iec_drive`, que también nace con dos relojes: `clk` (core) y
  `clk_sys` = *«"SD card" clock for writing to the drives' internal data buffers»*
  (`learning_cores/C64MEGA65/CORE/vhdl/main.vhd:1323`), alimentado desde `c64_clk_sd_i`.
- **`u765.sv` tiene un solo reloj**: `module u765 (input clk_sys, input ce, ...)` (`u765.sv:32-58`).
  No hay segundo reloj que cablear. **Aquí sí hay que crear la separación.**

### 9.3 Anatomía interna del `u765`: por qué la separación resulta ser barata

Leyendo el módulo entero, sus bloques secuenciales se reparten así:

| Bloque | Línea | ¿`ce`? | Qué toca |
|---|---|---|---|
| `fdc` | 289 | sí (`if (ce)`) | toda la máquina de estados del controlador, bus del Z80, puerto **B** de los buffers |
| `sdcontrol` | 232 | **no** | `sd_lba`/`sd_rd`/`sd_wr`, sincronizador de `sd_ack`, `sd_buff_type` |
| `image_track_offsets` | 210 | no | RAM de offsets de pista, puro dominio core |
| `tinfo_ram` / `sector_ram` | 173/188 | — | puerto **A** = lado SD (`sd_buff_*`), puerto **B** = lado FDC |

El handshake `fdc`↔`sdcontrol` es un protocolo de **niveles mantenidos hasta acuse**, no de
pulsos: `fdc` pone `sd_rd_sector[ds0] <= 1` y no lo baja hasta ver `sd_busy_sector`
(`u765.sv:1143-1151`); `sdcontrol` levanta `sd_rd` y no lo baja hasta el flanco de `sd_ack`
(`u765.sv:235-238`). El giro completo dura toda una transferencia de bloque —microsegundos—,
así que ese handshake **no necesita CDC si ambos bloques se quedan en el mismo dominio**.

La consecuencia práctica: **no hace falta mover `sdcontrol` ni tocar la máquina de estados**.
Lo único que *obliga* a cambiar de dominio es el **bombeo de bytes**, porque el firmware QNICE
pone `sd_buff_addr` y lee `sd_buff_din` de forma combinacional en el mismo acceso — un
ida-y-vuelta que no se puede sincronizar sin handshake por byte. Y eso se resuelve exactamente
igual que en `sd_card.sv`: **haciendo el buffer de doble reloj**.

### 9.4 Diseño elegido (opción mínima, calcada de los dos precedentes probados)

1. **`u765_dpram` pasa a doble reloj** (`u765.sv:1471-1506`): `clock` → `clock_a`/`clock_b`.
   Es una RAM dual-port inferida de libro; Vivado infiere BRAM verdadera con relojes
   independientes sin problema. Cambio de 3 líneas.
2. **`u765` recibe un puerto nuevo `input clk_sd`**, usado *solo* por el puerto A de los dos
   buffers. `clk_sys` sigue siendo el reloj del core en todo lo demás.
3. Los tres controles de dominio core que llegan al puerto A (`sd_buff_type`, `tinfo_ds0`,
   `tinfo_hds`) **salen del `u765` por un puerto nuevo `sd_sel_o` y vuelven ya sincronizados
   por `sd_sel_sd_i`**. El cruce lo hace `main.vhd`, no el `u765`.
4. **`sd_ack` se pre-sincroniza en `main.vhd`** con `xpm_cdc_single` antes de entrar al `u765`.
5. **Camino core→QNICE (`sd_lba`, `sd_rd`, `sd_wr`, `sd_sel`)**: un `xpm_cdc_array_single` de
   39 bits en `main.vhd`. En AExp/QL4M65 estas señales cruzan sin sincronizar (se generan en el
   bloque `clk_spi` de `sd_card.sv` y entran directas a `vdrives`), y funciona porque son
   niveles mantenidos miles de ciclos que el firmware *sondea*. `sd_lba` se fija en el **mismo**
   ciclo que `sd_rd` (`u765.sv:246-250`), luego el desfase entre bits sincronizados es como
   mucho 1 ciclo — y el firmware lee `sd_lba` decenas de ciclos después de detectar `sd_rd=1`.

### 9.4bis. Por qué TODO el CDC acabó en `main.vhd` y nada dentro del `u765` (M2001, medido)

La primera versión hacía lo evidente: sincronizadores de 2 FF escritos a mano dentro de
`u765.sv`, y dejando que la cadena de 6 etapas que ya tenía el `u765` (`ack <= {ack[4:0],
sd_ack}`) absorbiera el `sd_ack` entrante. **Vivado dio `WNS = -4.982 ns` con 8 endpoints
fallando, y las cuatro violaciones grandes eran exactamente esos cuatro cruces**:

| Slack | Camino |
|---|---|
| −4.982 ns | `i_vdrives/sd_ack_reg[1]` (qnice) → `i_u765/ack_reg[3]_srl4_srlopt` (main) |
| −3.617 ns | `i_u765/sd_buff_type_reg` (main) → `i_u765/sd_sel_meta_reg[2]` (qnice) |
| −2.130 ns | `i_u765/tinfo_ds0_reg` (main) → `i_u765/sd_sel_meta_reg[1]` (qnice) |
| −1.683 ns | `i_u765/tinfo_hds_reg` (main) → `i_u765/sd_sel_meta_reg[0]` (qnice) |

La causa raíz: **un sincronizador escrito en RTL plano no lleva restricción asociada**, así que
el analizador trata el cruce como un camino síncrono y exige cumplir una relación de fase entre
`main_clk` (64 MHz) y `qnice_clk` (50 MHz) que sencillamente no existe (`Requirement: 0.625ns`).
Y hay algo peor que el número: la cadena `ack` se sintetizó como **SRL** (`ack_reg[3]_srl4_srlopt`
— un desplazador en LUT, no FFs adyacentes), que no es un filtro de metaestabilidad válido en
absoluto. Es decir, el diseño no solo *reportaba* mal, es que *estaba* mal.

**El único cruce que no apareció en la lista fue el que ya usaba `xpm_cdc_array_single`**,
porque los macros XPM traen sus propias restricciones (`set_max_delay -datapath_only` sobre la
primera etapa). De ahí la regla que sigue este port: todo cruce core↔QNICE del FDC va en
`main.vhd` como macro XPM, y `u765.sv` se queda con cero lógica de CDC y cero código específico
de Xilinx (gana dos puertos, que es una excepción mucho más limpia y sigue siendo portable a
Quartus).

**Efecto colateral en el proceso**: `build_core.tcl` había dado `RESULT=BUILD_OK` sobre ese
diseño, porque solo comprobaba que `impl_1` llegara al 100% — y Vivado escribe el bitstream
igualmente con slack negativo. Se ha añadido una comprobación explícita de WNS/WHS que ahora
devuelve `RESULT=TIMING_FAILED`. Es la lección `M1004` del QL, reaprendida por las malas.

### 9.4ter. `sd_ack` no era un cruce, eran dos consumidores (M2001, segunda medida)

El arreglo de 9.4bis dejó `WNS = -3.116 ns`, y la nueva compuerta de timing lo cazó
(`RESULT=TIMING_FAILED`) en vez de entregar un `.cor` malo. Las tres violaciones restantes
tenían todas el mismo origen — `i_cdc_sd_ack/syncstages_ff_reg[3]` (main_clk) — y destinos
`i_u765/sector_ram/ram_reg/ENBWREN` y `/WEBWE[*]` (qnice_clk).

Error de razonamiento, no de sintaxis: **`sd_ack` tiene dos consumidores en dos dominios**, y
yo lo sincronicé entero hacia uno solo.

| Consumidor | Dónde vive | Qué versión necesita |
|---|---|---|
| `wren_a` de `tinfo_ram`/`sector_ram` | puerto A, relojado por `clk_sd` (QNICE) | la nativa, **sin** sincronizar |
| cadena `ack` de `sdcontrol` | `clk_sys` (core) | la sincronizada al core |

Al pasar el único puerto `sd_ack` a la versión de dominio core, la habilitación de escritura de
una BRAM relojada por QNICE quedó gobernada por un registro de `main_clk`: un cruce nuevo, y
encima hacia un pin de control de BRAM, que es de lo peor que se puede dejar sin restringir.

**Arreglo**: `u765` recibe dos puertos, `sd_ack` (dominio QNICE, directo desde `vdrives`) y
`sd_ack_sys` (dominio core, vía `xpm_cdc_single`). En MiSTer esta distinción no existía porque
todo el módulo iba con un solo reloj — es justo el tipo de detalle que aparece solo al partir
un módulo en dos dominios.

**Regla general que sale de aquí**: al hacer dual-clock un módulo de un solo reloj, no basta
con preguntarse "¿de qué dominio es esta señal?", hay que preguntarse **"¿quiénes la consumen y
de qué dominio es cada uno?"**. Una señal con dos consumidores en dos dominios necesita dos
versiones, no una elección entre ellas.

**Descartado — opción "puente CDC completo dejando el `u765` intacto"**: obligaría a cruzar
`sd_buff_addr`→`sd_buff_din` en ida y vuelta (~150 ns) en un camino que el firmware espera
combinacional. Frágil y contrario al patrón del framework.

**Descartado — opción "todo el `u765` en dominio QNICE"**: convertiría el bus del Z80
(`nRD`/`nWR`/`a0`/`din`/`dout`) en un CDC, que es justo lo que no se debe cruzar, y además
descolocaría el `ce` de 8 MHz del que depende la temporización de byte del disquete
(`CYCLES*32/1000` → 32 µs/byte, `u765.sv:399`).

### 9.5 Pegamento de bus que hay que escribir en `main.vhd`

`main.vhd` instancia `Amstrad_motherboard` directamente, no `Amstrad.sv`, así que el decodificado
del FDC —que vive en `Amstrad.sv:732-778`— hay que replicarlo nosotros. Es corto y está leído:

```
fdc_sel  = {cpu_addr[10], cpu_addr[8], cpu_addr[7], cpu_addr[0]}
io_rd    = rd & iorq                    -- Amstrad.sv:959
io_wr    = wr & iorq                    -- Amstrad.sv:960
u765_sel = (fdc_sel[3:1] == 3'b010)     -- status[17] era "desactivar FDC" del OSD: se fija a 0
motor    <= cpu_dout[0]  en flanco de io_wr con fdc_sel[3:1]==0
ready[i] <= |img_size    en img_mounted[i]
```

El `cpu_din` del core original es un AND cableado (`ram_dout & mf2_dout & fdc_dout & ...`,
`Amstrad.sv:955`) donde cada periférico devuelve `8'hFF` si no está seleccionado. Nuestro
`mb_cpu_din` actual es una cadena de multiplexores con `x"FF"` por defecto; el FDC entra como
una rama más, con prioridad sobre RAM/ROM cuando `u765_sel & io_rd`.

`ce_u765` = 8 MHz = `clk_main`/8 (en el original, `!div[2:0]` sobre 64 MHz, `Amstrad.sv:127`).
Nuestro `clk_main` ya es 64 MHz exactos, así que el divisor es idéntico al del core original.

### 9.6 Cambios de configuración del framework

- `globals.vhd`: `C_VDNUM := 2` (las dos unidades A:/B: que el `u765` soporta),
  `C_VD_DEVICE`, y `C_VD_BUFFER` con un ID de dispositivo por unidad.
- `main.vhd`: instanciar `vdrives` con `VDNUM => 2`, `BLKSZ => 2`, siguiendo el ejemplo
  completo de C64MEGA65 (`main.vhd:1537-1586`); añadir el reloj QNICE como puerto de entrada
  (`clk_sd_i`, patrón `c64_clk_sd_i`) y bajar el bus MMIO de QNICE.
- `mega65.vhd`: enrutar `C_VD_DEVICE` en `core_specific_devices` y crear una RAM de buffer por
  unidad bajo su `C_VD_BUFFER`.
- `config.vhd`: entradas de menú `OPTM_G_MOUNT_DRV` para A: y B: (recordatorio: en M1 el
  framework abortó con *«More menu items have OPTM_G_MOUNT_DRV than C_VDNUM»* justo por tener
  esas entradas sin drives; ahora es al revés y hay que reponerlas).
- **La excepción de `vdrives.vhd` para `VDNUM=0` deja de ejercitarse** al pasar a `VDNUM=2`.
  Se mantiene el código y su documentación en `exceptions.md` —el bug de framework sigue
  siendo real y hay que reportarlo aguas arriba— pero deja de estar en nuestro camino crítico.

### 9.7 Riesgos abiertos (a verificar en hardware, no resueltos en papel)

1. **Colisión de puerto en la BRAM de doble reloj**: puerto A escribe mientras B lee. En la
   práctica el FDC espera a que termine la transferencia, pero Vivado avisará; hay que decidir
   el `WRITE_MODE` y confirmar que el aviso es benigno, no taparlo.
2. **`.DSK` vs EDSK**: el `u765` distingue por la primera letra de la cabecera (`"E"` = EDSK,
   `"M"` = DSK estándar, `u765.sv:424-427`). La biblioteca de prueba del usuario
   (`E:\CPC4MEGA65\DSK`, 26 imágenes) tiene tamaños entre 185 KB y 261 KB, o sea que hay de
   los dos tipos — buena cobertura desde el primer test.
3. **Escritura y caché**: el criterio de éxito de M2 incluye *guardado persistente*, que pasa
   por `cache_dirty_o`/`cache_flushing_o` y el retardo de flush de `vdrives`. Es la parte que
   ningún test de solo-lectura cubre.

## 10. M3: joystick (2026-09-07)

Milestone mucho más pequeño que M2, y por una razón concreta: **en el CPC el joystick no es un
periférico aparte, son dos filas de la propia matriz de teclado**. Todo el trabajo del core
original cabe en cinco líneas (`rtl/hid.sv:41-48`):

```verilog
wire row9 = (Y == 9);
wire row6 = (Y == 6);
assign X = ~(key[Y] | joy1 | joy2 | mouse);

wire [6:0] joy1 = row9 ? {joystick1[6:4], joystick1[0], joystick1[1], joystick1[2], joystick1[3]} : 7'd0;
wire [6:0] joy2 = row6 ? {joystick2[6:4], joystick2[0], joystick2[1], joystick2[2], joystick2[3]} : 7'd0;
```

El orden de bits sale de ahí, no de documentación externa: el reordenado
`{[6:4], [0], [1], [2], [3]}` sobre el bus de MiSTer (`[0]`=Derecha, `[1]`=Izquierda,
`[2]`=Abajo, `[3]`=Arriba) da la disposición del CPC: **0=Arriba 1=Abajo 2=Izquierda
3=Derecha 4=Fire1 5=Fire2 6=Fire3**.

### 10.1 Las dos filas no son equivalentes

| Joystick | Fila | Situación |
|---|---|---|
| 0 (principal) | 9 | **Libre.** Nuestro `keyboard.vhd` solo usaba su bit 7 (Delete), así que los bits 0..6 no pisan ninguna tecla. |
| 1 (secundario) | 6 | **Ocupada** por `6 5 R T G F B V`. El joystick se superpone en paralelo. |

Lo segundo **no es un descuido del port ni del core original**: es cómo está cableado el CPC de
verdad, y es la razón conocida de que el segundo joystick del CPC provoque pulsaciones fantasma
en esas teclas. Se reproduce tal cual, que es lo correcto en un port.

### 10.2 Intercambio de puertos

Lo hace entero el framework: `M2M/vhdl/framework.vhd` instancia un `debouncer` con
`flip_joys_i` (framework.vhd:505-520) alimentado desde `qnice_flip_joyports_i`. Basta un item
de menú. Merece la pena en un core de CPC porque **la máquina real solo trae UN conector de
joystick** (el 0); el segundo necesita una Y, así que el usuario querrá elegir en qué puerto del
MEGA65 enchufa sin acordarse de cuál es "el primero".

### 10.3 Fire2 sin mapear (decisión del usuario, 2026-09-07)

El CPC tiene Fire1, Fire2 y Fire3; el puerto de joystick del MEGA65 expone **un solo botón**.
Sacar un segundo obligaría a interpretar las líneas POT, que depende del adaptador concreto.
Decisión: dejar Fire2/Fire3 a `'0'` y revisitar solo si aparece un juego concreto que lo pida.
La mayoría de juegos del CPC usan solo Fire1.

### 10.4 Lo que NO entra en M3

El `hid.sv` original también superpone un ratón sobre las mismas filas (`mouse` en el OR de
`X`). Sigue en el backlog, no en este milestone.

## 11. M4: disquetera física interna del MEGA65 (2026-09-09)

### 11.1 Lo primero: no hay precedente que copiar (verificado, no supuesto)

El usuario pidió mirar cómo lo hacen AExp y C64MEGA65. **No lo hacen.** Comprobado por
búsqueda directa de las señales `f_*` en los tres cores hermanos:

| Dónde | Resultado |
|---|---|
| `M2M/MEGA65-R6.xdc` (los tres cores) | los 14 pines existen y están constrained |
| `M2M/vhdl/top_mega65-r6.vhd` | son puertos del top level, y se **atan a valor inactivo** ahí mismo (líneas 535-544) |
| `M2M/vhdl/framework.vhd` | **ni aparecen** — el framework no los enruta |
| `C64MEGA65/CORE/**` | sin coincidencias |
| `AExp/CORE/**` | sin coincidencias |

O sea que **ningún core hermano toca la disquetera física**. Eso sigue siendo cierto.

**PERO el encuadre inicial de esta sección era erróneo y hay que corregirlo** (2026-09-10, el
usuario objetó con razón que AExp sí lee y escribe discos de Amiga). AExp **sí tiene disquetera
completa, de lectura y escritura** — lo que pasa es que trabaja sobre **imágenes ADF**, no sobre
medio físico:

> *"Floppy: df0 with read/write ADF mount from the OSM (image staged in HyperRAM at word
> 0x200000). Mount via OSM ' ADF:' → Shell streams to HyperRAM (QNICE device 0x0103,
> `adf_mount_wrapper.vhd`) → `adf_track_engine.vhd` serves Paula over the IO_FPGA host channel
> with bit-exact minimig_fdd.cpp MFM encoding."* — `AExp/AGENTS.md`

Así que **sí hay precedente que estudiar**, solo que de la *arquitectura*, no de los pines. Y es
muy relevante, porque valida la Opción B elegida más abajo y acota mejor qué es lo realmente
nuevo. Ver 11.4bis.

**La buena noticia sobre el tamaño de la excepción**: `framework.vhd` **no** instancia el core.
`top_mega65-r6.vhd` instancia por separado `i_framework` (línea 574) y `CORE : entity
work.MEGA65_Core` (línea 757) y los cablea entre sí. Así que llevar los pines hasta nuestro
core es **un solo fichero de framework tocado**: quitar los tie-off y cablearlos a la instancia
`CORE`. `framework.vhd` no se toca.

### 11.2 Interfaz disponible (Shugart/PC de 34 pines, completo)

| Salidas | Entradas |
|---|---|
| `f_density_o` (REDWC), `f_motora_o`, `f_motorb_o`, `f_selecta_o`, `f_selectb_o`, `f_side1_o`, `f_stepdir_o`, `f_step_o`, `f_wdata_o`, `f_wgate_o` | `f_diskchanged_i`, `f_index_i`, `f_rdata_i`, `f_track0_i`, `f_writeprotect_i` |

No falta nada para un controlador de disquete completo, lectura y escritura.

### 11.3 Qué puede significar M4 realmente (y qué no)

**El CPC usa disquetes de 3 pulgadas (Amstrad/Hitachi CF-2). El MEGA65 lleva una disquetera de
3,5 pulgadas. Un disco de CPC no entra físicamente.** Así que M4 no puede ser "leer discos
originales del CPC" — es **leer/escribir un disquete de 3,5" formateado con formato CPC**, que
es justo lo que dice el criterio del milestone. Compatible: el formato DATA del CPC (40 pistas,
1 cara, 9 sectores de 512 B, IDs &C1-&C9) es MFM a 250 kbps, lo mismo que un 3,5" DD.

### 11.4 El problema de arquitectura

`u765` es un controlador **de imagen**: parsea estructuras `.DSK` (cabecera de disco, cabeceras
de pista, datos) leídas en bloques LBA de 512 B que le sirve `vdrives`/QNICE. **No sabe hacer
MFM.** Un disquete físico da **flujo MFM crudo** por `f_rdata_i`. Hay que unir esos dos mundos.

**Opción A — FDC MFM en tiempo real que sustituya al u765.** Implementar un uPD765 completo
contra medio físico. Enorme (juego de comandos + separador de datos + timing real). Descartada.

**Opción B — puente MFM↔imagen con caché de disco entero (ELEGIDA).** El `u765` y toda la
cadena de M2 se quedan **intactos**. Se añade un motor MFM que, al montar, lee las 40 pistas ×
9 sectores (180 KB) al buffer de imagen que YA existe de M2, **sintetizando la envoltura `.DSK`**
por delante, de forma que el `u765` ve una imagen normal y todo lo demás funciona sin cambios.
La escritura es el camino inverso, al volcar la caché.

*Por qué esta*: reutiliza el 100% de M2, ya probado en hardware. Y sobre todo, **el motor MFM no
tiene que servir sectores en tiempo real** — puede tomarse su tiempo, que es lo que elimina la
parte más difícil del problema. Coste: montar tarda unos segundos (40 pistas × 200 ms/vuelta ≈
10 s) y no hay fidelidad a protecciones anticopia (sectores débiles, IDs raros). Aceptable.

**Opción C — servidor de sectores MFM detrás del interfaz de bloques de vdrives.** En vez de que
QNICE saque los bloques de un `.DSK` de la SD, el motor MFM responde a `sd_rd`/`sd_wr` buscando
la pista/sector correspondiente. Más elegante en memoria, pero obliga a sintetizar al vuelo los
bloques de cabecera del `.DSK` y mete el medio físico en el camino crítico de cada petición.
Guardada como alternativa si B se queda corta.

### 11.4bis Qué se aprende de la disquetera ADF de AExp (2026-09-10)

Estudiado `AExp/CORE/vhdl/adf_track_engine.vhd` y `adf_mount_wrapper.vhd`. Cuatro conclusiones,
todas útiles:

**1. Sí, pasan la imagen a memoria antes. Eso valida la Opción B.** AExp no sirve a Paula
directamente desde la SD: el Shell vuelca la imagen entera a memoria y el motor de pista lee de
ahí. Es exactamente el patrón que se eligió aquí. Diferencia importante: **AExp la pone en
HyperRAM, no en BRAM**, porque su BRAM está lleno (*"BRAM is at 363.5/365 tiles — full. All
future buffers MUST live in HyperRAM"*). Nosotros vamos por el 63% y además **reutilizamos el
buffer de imagen que ya existe de M2**, así que no hace falta memoria nueva — pero si en algún
momento hiciera falta, HyperRAM es la salida y AExp tiene el patrón probado (`avm_cache` +
`avm_fifo` para el CDC).

**2. Su códec MFM es de nivel PALABRA, no de flujo.** Y esto es lo que acota de verdad el
trabajo nuevo. AExp nunca mide tiempos de flujo magnético: Paula le entrega/recibe **palabras de
16 bits** por una FIFO (`io_fpga`/`io_strobe`), ya sincronizadas. Su codificador
(`f_mfm_odd`/`f_mfm_even`) y su decodificador (`FindSync`/`GetHeader`/`GetData`) trabajan sobre
esas palabras.

Conclusión para M4B: el trabajo se parte en dos, y solo la primera mitad no tiene precedente.

| Capa | ¿Precedente en AExp? |
|---|---|
| **Separador de datos**: medir intervalos de `f_rdata_i` y sacar bits | **NO. Esto es lo genuinamente nuevo.** Nadie lee medio físico |
| Sincronizar con la marca, parsear cabecera y datos, verificar | **SÍ**, estructuralmente. Y sincronizan con `0x4489`, que es **la misma palabra de sincronismo** que usa el formato IBM/CPC |

**3. Los dos formatos MFM no son el mismo, pero el sincronismo sí.** Amiga: pista entera, 11
sectores, separación de bits pares/impares, checksum XOR. IBM/CPC: 9 sectores con IDAM/DAM
(`A1 A1 A1` = tres `0x4489` seguidos), CRC-16 y huecos entre sectores. Lo transferible es el
detector de sincronismo a nivel de bit; la estructura por encima hay que escribirla para el
formato del CPC.

**4. Su arquitectura de escritura es la referencia para M4C.** Mapa de bits de pistas sucias +
anti-thrashing de 2 s + volcado en segundo plano desde el firmware — el mismo esquema que
`vdrives`. Ellos tuvieron que añadir una excepción al framework (`HANDLE_CORE_IO`, un callback
por iteración del bucle principal del Shell) porque no usan `vdrives`. **Nosotros no la
necesitamos: ya tenemos `vdrives` con su propio camino de volcado**, funcionando desde M2.

**Sentido opuesto, mismo problema.** AExp *codifica* MFM (Paula quiere flujo MFM); nosotros
*decodificamos* (u765 quiere sectores). La frontera MFM cae en sitios distintos porque en el
Amiga real es Paula quien hace el MFM, y en el CPC es el propio uPD765.

### 11.5 Fases (cada una con criterio observable en hardware)

**M4A — "el hierro responde"**. Sin nada de MFM todavía.
- Enrutar `f_*` desde `top_mega65-r6.vhd` hasta `main.vhd` (excepción de framework, un fichero).
- Módulo `floppy_phys.vhd`: control de motor y selección, `step`/`stepdir` con contador de pista
  y recalibrado a pista 0 usando `f_track0_i`, detección de pulso de índice.
- **Criterio**: la disquetera gira y el pulso de índice se detecta a ~5 Hz (300 RPM). Se observa
  con el LED de la placa, que ya sabemos usar de M2 — sin necesidad de la consola serie de
  QNICE, que este proyecto no tiene disponible.

**M4B — lectura MFM.** Separador de datos, sincronización con la marca A1, lectura de campos de
ID y de datos, comprobación de CRC-16.
- **Criterio**: leer el disco entero al buffer de imagen con la envoltura `.DSK` sintetizada y
  que `CAT` liste el directorio de un disquete físico.

**M4C — escritura MFM.** Codificador MFM, `f_wgate_o`/`f_wdata_o`, volcado de la caché al medio.
- **Criterio**: grabar, recargar y que persista — el mismo criterio que cerró M2, ahora contra
  hierro real.

### 11.6 Notas técnicas de partida para el separador de datos (M4B)

A 250 kbps MFM la celda de bit son 4 µs, y los intervalos entre transiciones de flujo son de
4, 6 u 8 µs. Con `clk_main_i` a 64 MHz eso son **256, 384 y 512 ciclos**: resolución de sobra
para clasificar los tres intervalos con un simple contador y ventanas, sin necesidad de PLL en
la primera versión. `f_rdata_i` entrega pulsos activos a nivel bajo.


## 12. M4D: arquitectura objetivo — lectura/escritura por pistas, bajo demanda (2026-09-13)

Decidida con el usuario tras cerrar el diagnóstico de M4015. **Esto es el destino, no lo que
hay hoy**: lo de hoy (leer el disco entero a un buffer y montar un `.dsk` de destino a mano)
queda explícitamente marcado como apaño provisional.

### Por qué se cambia

El usuario lo dijo sin rodeos: *"lo de montar un dsk vacío me parece muy cutre"*. Y tiene
razón — obligar a montar una imagen en blanco con la geometría correcta antes de poder volcar
un disquete no es un diseño, es una consecuencia de cómo llegamos aquí. Su propuesta:

> cuando eliges la unidad A en el menú OSD puedes elegir o disquetera real o dsks, en el mismo
> menú. De esta forma, no lees el disco cuando lo metes, sino cuando haces un cat.

### La arquitectura

**Menú**: cada unidad (A: y B:) tiene un origen seleccionable — *imagen `.dsk` de la SD* o
*disquetera física*. Sin acción aparte de "leer": eliges el origen y la unidad se comporta
como esa cosa.

**Lectura por pistas y bajo demanda**: cuando el u765 pide un bloque que cae en la pista T y
esa pista todavía no se ha leído del disco físico, se lee **solo esa pista** (~400 ms
contando la búsqueda) y se sirve. Se lleva un mapa de bits de pistas ya leídas. El primer
`CAT` solo toca la pista 0, así que responde rápido; el resto se va poblando según se use.

### La restricción física que descarta la versión ingenua

Leer las 40 pistas son **8 segundos como mínimo** (una vuelta por pista a 200 ms; hoy son
unos 16 porque se dan dos vueltas). El temporizador de AMSDOS está en el orden de uno o dos
segundos, así que **"leer el disco entero en el primer acceso" no es viable**: el primer `CAT`
fallaría siempre. De ahí que la granularidad tenga que ser la pista, no el disco.

La alternativa intermedia —leer el disco entero al detectar inserción, con `f_diskchanged_i`
(ya cableado desde M4A)— sí es viable y sería un escalón intermedio aceptable si la lectura
por pistas se complica.

### El bloqueo real que hay que resolver primero

**Que el u765 acepte nuestra imagen sin que haya ningún fichero montado.** Hoy, sin montar
nada, nunca recibe el evento de montaje: `image_ready` se queda a 0 y la unidad no existe
para él. Dárselo por detrás es exactamente lo que se intentó en M4014 (pulso en `img_mounted`
con `img_size` propio) y **colgó la unidad**: `image_ready` a 0 y AMSDOS reintentando para
siempre con el motor girando, tal como lo describió el usuario por el LED rojo fijo.

**Ese modo de fallo sigue sin explicarse** y es el primer trabajo de M4D. No es mucho código;
es entender por qué el re-escaneo no completa. Pistas para retomarlo: el escaneo exige
`!sd_busy_mount && !i_scan_lock && state == COMMAND_IDLE` (u765.sv:443), `i_scan_lock` es
único y compartido entre las dos unidades, y la máquina de escaneo solo avanza cuando
`i_current_drive` coincide, que alterna en cada `ce`.

### Lo que NO era el problema (para no volver a perseguirlo)

La tabla de desplazamientos de pista. El `.dsk` de Bruce Lee del usuario es un EDSK, pero con
pistas uniformes de 4864 bytes (`0x34..` todo `0x13`), así que la rama EDSK de u765 produce
**los mismos offsets** que la estándar. Esa tabla ya era correcta para nuestra imagen. Lo que
fallaba era la **lista de sectores cacheada** — ver la cabecera de `main.vhd`, sección M4015.

### Puerta que esto deja abierta: protecciones

Hoy todo lo que hay después del separador MFM asume 40 pistas x 9 sectores x 512 bytes y
coloca cada sector en `ranura = ID - 1`, y se genera un `.DSK` **estándar**, que no puede
representar un CRC malo intencionado ni un sector débil (para eso existe el EDSK, con el
tamaño real de cada sector y sus banderas ST1/ST2).

Leer pista a pista hace natural anotar **lo que hay de verdad** en cada una -cuántos sectores,
de qué tamaño, con qué CRC- en vez de forzarlo a un molde fijo, así que generar EDSK pasaría a
ser un cambio acotado. No es objetivo de M4D, pero la arquitectura no se cierra la puerta.

En la práctica importa poco a corto plazo: los juegos originales venían en 3" y esos no entran
físicamente en la disquetera del MEGA65. Lo único plausible es una copia en 3,5" hecha desde
un CPC, y esas suelen ser copias ya limpias. Nota para no confundir dos cosas distintas: una
disquetera de 3,5" en un CPC real **sí** leería un disco protegido — la protección vive en la
codificación magnética, no en la disquetera, y quien la interpreta es el mismo uPD765. Si
algún día no la leemos, seremos nosotros, no el hardware.

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
