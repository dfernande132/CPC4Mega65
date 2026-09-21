# Hoja de pruebas de M4058 — la medida que decide la arquitectura de M5

Preparada por adelantado. Cuando salga la build, se ejecuta tal cual.
**Tiempo estimado: 15-20 minutos**, no los 5 que dije (hay que repetir cuatro veces).

---

## Qué se mide, y qué NO

**Se prueba CON IMAGEN DESDE LA SD, no con la disquetera física.** La disquetera no
interviene en ninguna de estas pruebas. Lo que se está midiendo es cuánta latencia tolera
AMSDOS en el camino que YA existe, para saber si M5 puede permitirse leer una vuelta de
disco real cada vez que el CPC cambia de pista.

Dicho de otro modo: **estamos midiendo el presente para decidir el futuro.**

---

## Requisito previo (para la sesión de la v1.0, antes de compilar)

Los tres contadores tienen que salir por el **volcado bajo demanda** (`Dump telemetry` →
`C_DUMP_LBA = 400`), no sólo en la imagen que construye `floppy_dsk` al leer físicamente.

Si sólo salieran por ahí, cada medida obligaría a un barrido de 40 pistas (~8 s más el
manejo), y además la lectura física podría alterar los contadores que queremos leer. Con el
volcado bajo demanda, cada medida son diez segundos.

---

## Material

* La SD con la build M4058 y su `m2mcfg` regenerado **del tamaño nuevo** (`OPTM_SIZE` pasa
  de 40 a 44 con el radio de cuatro valores). El `m2mcfg` viejo de 40 bytes hay que
  **borrarlo**: el precedente de DECISIONES.md es un QNICE colgado con teclado muerto que
  sobrevive al reset.
* Un `.dsk` normal de formato DATA montado en A:.
* **Un juego que cargue de muchas pistas.** Es la pieza crítica: ver la advertencia de
  abajo. Candidatos de la colección: `Prince de Perse`, `Batman The Movie`,
  `Ghosts 'N' Goblins`.
* Un cronómetro (el del móvil vale).

---

## La advertencia que hace o deshace esta medida

**Un `CAT` no sirve como prueba.** El directorio del formato DATA vive en la pista 0, así
que un CAT toca **una sola pista** = una recarga de TrackInfo. Con el retardo a 400 ms eso
es 400 ms una vez en toda la operación: no se nota, y el resultado sería un falso
*"tolera 400 ms"*.

El CAT se hace igualmente, pero **como control blando**, para contraste.

La prueba de verdad es la carga de un juego que cruce muchas pistas. Y el juez de si la
prueba fue dura es `tlm_tinfo_rd`: **si tras la carga marca menos de 10, la prueba no
valía** y hay que buscar otro juego.

## La segunda trampa: comprobar que el retardo ACTÚA

Lección propia, de M4023: *"dio resultados IDÉNTICOS con y sin DPLL, y 'idéntico' es también
la firma de 'no se aplicó ningún cambio'"*.

Aquí pasa lo mismo. Si al subir el retardo no cambia nada, hay dos explicaciones y hay que
poder distinguirlas. El discriminador es el **tiempo de carga con cronómetro**:

```
tiempo(retardo) − tiempo(0)  ≈  tlm_tinfo_rd × retardo
```

Si el juego tarda 20 s con retardo 0, `tlm_tinfo_rd` marca 25 y con 200 ms sigue tardando
20 s, **la opción no está llegando al hardware** — no es que AMSDOS lo tolere. Debería
tardar unos 25 s.

Y comprobar que el **nonce cambia** entre volcados (la lección de AExp: siete volcados de
campo que resultaron ser dos observaciones).

---

## PRUEBA PRINCIPAL: el disco a media velocidad (factor 2 de margen)

**Esta es la más informativa de todas y va primero.** Idea de la sesión de la v1.0, con el
signo corregido: no pone el modelo a velocidad real (ya lo está), lo pone **al doble de
lento**.

Con la base de tiempo del `u765` dividida por dos: 64 µs por byte y **410 ms por vuelta**,
o sea un disco girando a 150 RPM.

| Arm | Base de tiempo | Simula | Si carga bien, demuestra |
|---|---|---|---|
| control | 4 MHz (hoy) | 300 RPM, vuelta de 205 ms | el estado actual |
| **estrés** | 2 MHz | 150 RPM, vuelta de **410 ms** | AMSDOS tolera **el doble** de lo que M5 pide |

Si con el arm de estrés los juegos cargan y el `CAT` funciona, **la incógnita de M5 queda
cerrada sin escribir una línea de RTL**, y el retardo del TrackInfo pasa de decisión a
refinamiento.

### Cómo implementarlo (importante: NO tocando `CYCLES`)

`CYCLES` es un `parameter` de Verilog y sus usos (`CYCLES*32/1000-1`, `CYCLES*205`) se
evalúan en síntesis: cambiarlo son **dos builds**, y comparar dos builds distintas es lo que
este proyecto aprendió a no hacer.

El modelo cuenta pulsos de `ce`, así que **dividir `cen_u765` de 8 a 4 MHz da el efecto
idéntico** y es conmutable en caliente. En `main.vhd:819-834`, sin tocar el submódulo
MiSTer (o sea, sin excepción nueva en `doc/m2m/exceptions.md`):

```vhdl
-- cen_16_div : unsigned(2 downto 0)  ->  unsigned(3 downto 0)
if (fdc_slow_i = '0' and cen_16_div(2 downto 0) = "000") or
   (fdc_slow_i = '1' and cen_16_div(3 downto 0) = "0000") then
   cen_u765 <= '1';
```

* `cen_16` no se toca: sigue en `cen_16_div(1 downto 0) = "00"` → 16 MHz. El Gate Array no
  se entera.
* Con `fdc_slow_i = '0'` es **bit-idéntico al actual** (`div(3)` no se mira): regresión nula.
* Se preserva la relación de fase que `main.vhd:272-274` marca como load-bearing —
  `div(1 downto 0) = "00"` se cumple en ambos casos, así que cada pulso de `cen_u765` sigue
  cayendo sobre uno de `cen_16`.

### Protocolo del arm de estrés

1. Con el bit a 0: cargar el juego, **cronometrar**. Es la referencia.
2. Activar el bit (sin resetear el core, si el menú lo permite).
3. Cargar el mismo juego otra vez, cronometrar.
4. **Comprobar que el instrumento actúa**: el tiempo debe ser **aproximadamente el doble**.
   Si no lo es, la opción no está llegando al hardware — es la lección de M4023, donde
   "idéntico" resultó ser la firma de "no se aplicó ningún cambio".
5. Lo que se juzga es si la carga **completa**, no si tarda. Que tarde el doble es lo
   esperado, no un fallo.

**Interpretación:** si con el arm de estrés todo carga, AMSDOS tolera 410 ms de latencia
rotacional y M5 tiene factor 2 de margen. Si algo falla, el límite está entre 205 y 410 ms,
y entonces sí hacen falta los cuatro valores del retardo para acotar dónde exactamente.

### CUIDADO: el seek también se ralentiza, y eso es ruido, no propina

`i_steptimer <= CYCLES` (`u765.sv:589,598`), bajo el mismo multiplexado, así que el
movimiento de cabeza también va al doble de lento. **M5 no toca eso**: la disquetera física
hace seeks a velocidad real (`floppy_phys.vhd:89`, `C_STEPRATE_CYC` = 3 ms por paso, sin
cambio). El test es por tanto más duro que la realidad en una dimensión que M5 no pide.

Si algo falla, **descartar primero el seek** antes de concluir nada sobre M5:

| Síntoma | Apunta a |
|---|---|
| `Drive not ready`, error al posicionar, fallo al cambiar de pista | **seek** → ruido del experimento, M5 no afectado |
| Overrun, `Read fail`, cuelgue a mitad de una carga que ya iba bien | **latencia rotacional** → resultado válido |

Si carga todo bien, da igual: el experimento pasó siendo más exigente de lo necesario.

### El cronómetro es el discriminador, no un adorno

Con `C_U765_CYCLES` como constante de `globals.vhd` (en vez del divisor conmutable), M4057 y
M4058 son **dos builds distintas**, y entre ellas cambian además el menú, los instrumentos y
el `m2mcfg`. Esa es justo la comparación de la que el proyecto desconfía. El cronómetro la
neutraliza:

* falla **y** tarda el doble → el `CYCLES` actúa, el fallo es de latencia → **válido**;
* falla **y no** tarda el doble → el `CYCLES` no llegó, el fallo es de otra cosa de la
  build → **inválido**, mirar el volcado (bytes 66-67) antes de creerse nada.

Usar la **misma SD y la misma imagen** en las dos tandas, y anotar qué juego exactamente.

---

## Protocolo del retardo del TrackInfo (refinamiento)

Hacerlo sólo si el arm de estrés falla, o para afinar.

Para cada valor del retardo — **0, 100, 200, 400 ms** — repetir:

1. Reset del core (para poner los contadores a cero).
2. Seleccionar el retardo en el menú.
3. `CAT` → anotar si funciona y el tiempo.
4. `Dump telemetry` → guardar el `.dsk` y decodificar con `decode_tlm.ps1`.
5. Anotar `tlm_tinfo_rd` **de este CAT** (es el que dice si el control fue blando).
6. Reset otra vez.
7. `RUN"` del juego, **cronómetro en marcha**. Anotar tiempo y si carga entero.
8. `Dump telemetry` → decodificar → anotar los cuatro contadores.

### Tabla para anotar

| Retardo | CAT ok | `tinfo_rd` CAT | Juego ok | Tiempo juego | `rot_max` | `rot_max` frío | `notfound` | `tinfo_rd` |
|---|---|---|---|---|---|---|---|---|
| 0 ms   | | | | | | | | |
| 100 ms | | | | | | | | |
| 200 ms | | | | | | | | |
| 400 ms | | | | | | | | |

Si algo falla, anotar **el síntoma exacto**: cuelgue, `Read fail`, `Retry, Ignore or
Cancel?`, pantalla negra, o carga incompleta. No es lo mismo un timeout de AMSDOS que un
overrun del FDC, y el síntoma los distingue.

---

## Cómo se lee el resultado

### `tlm_rot_max` con el retardo a 0 — la medida más valiosa

Es la latencia rotacional que AMSDOS **ya está tragando hoy**, sin que nadie lo hubiera
mirado.

* Se acerca a 205 ms → **demostrado en campo** que tolera una vuelta entera. M5 puede
  esperar a la rotación como la máquina real, y esa incógnita queda cerrada para siempre.
* Sale mucho menor (30-50 ms) → el modelo rotacional del `u765` está siendo más benévolo de
  lo que yo leí, y hay que volver a mirar `RW_DATA_EXEC3`.

### El retardo del TrackInfo — el que decide

* **Tolera 200-400 ms** → M5 puede descubrir la pista de forma perezosa: cuando el CPC pide
  una pista nueva, se lee una vuelta, se monta la lista de sectores y se sirve. Diseño
  simple, y el `u765` se queda casi intacto.
* **Falla en 100 ms** → hay que **precargar**: detectar el SEEK y leer la lista de IDs de la
  pista de destino mientras el CPC todavía procesa la anterior. Es más trabajo y necesita
  una máquina de anticipación, pero es lo que hace cualquier controlador decente.

**Ninguno de los dos resultados cierra M5.** Cambian el diseño, no la viabilidad.

### `tlm_notfound`

Debería ser 0 o muy bajo. Si sube con el retardo, significa que el retardo está desplazando
la posición rotacional simulada y el `u765` cruza el índice dos veces sin encontrar el
sector — sería un artefacto del instrumento, no un resultado, y habría que mover el punto
de inserción del retardo.

---

## Qué hago yo con esto

Con la tabla rellena diseño el backend físico del `u765`: las tres sustituciones (lista de
sectores de la pista, posición rotacional enganchada al índice real, y bytes desde el flujo
decodificado), el reparto de dominios de reloj y dónde va exactamente la costura. Eso ya es
RTL, y no lo escribo hasta haberlo discutido contigo.
