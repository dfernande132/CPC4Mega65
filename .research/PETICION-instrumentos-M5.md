# Petición: tres instrumentos para decidir la arquitectura de M5

**Para: la sesión de la v1.0. De: el hilo de M5.**
Todo esto es telemetría y una opción de menú. **No cambia ningún comportamiento** con los
valores por defecto, no toca el camino de datos y cabe en la build de M4057 o la siguiente.

---

## Por qué ha encogido la petición

Iba a pedir un experimento de latencia en tres brazos. Al leer `u765.sv` resulta que **dos
de los tres ya están respondidos por el código que lleváis corriendo en hardware desde M2**:

* `u765.sv:469` — `i_byte_clk_en` se genera cada `CYCLES*32/1000`: **32 µs por byte**. El
  `u765` entrega al CPC al ritmo real de un disco DD.
* `u765.sv:1147-1164` — `COMMAND_RW_DATA_EXEC3/4` **espera a que el sector pase bajo la
  cabeza**: avanza `sector_byte_pos`, compara el campo de ID de cada sector que va pasando,
  y si cruza la marca de índice dos veces sin encontrarlo da *sector not found*
  (`status[1] = 0x04`).
* `u765.sv:100,807` — `TRACK_TIME = CYCLES*205` y `i_rpm_timer` modelan la vuelta de 205 ms.
* `main.vhd:1467` — **`fast => '0'`**, o sea el seek también es temporizado paso a paso.

**Conclusión: el `u765` no es un controlador por imagen. Es un FDC rotacional cuyo backend
es una imagen.** Y por tanto AMSDOS ya está tolerando hoy, en hardware y con juegos reales,
una latencia de hasta una vuelta entera entre el comando y el primer byte. Eso era la
pregunta que yo quería medir, y ya está contestada — solo que nadie la había mirado desde
este ángulo.

Lo que cambia para M5: no hay que reescribir el uPD765. Hay que **cambiarle el backend**,
conservando su FSM de comandos, que es la parte cara. Queda **una** incógnita, y es la que
piden los tres instrumentos.

## La incógnita que queda

Para servir un sector, el `u765` necesita primero **la lista de sectores de la pista**
(`sector_c/h/r/n`, `st1/st2`, `sector_length`). Hoy la saca del TrackInfo del EDSK por la
SD, y es rápida. Con un disco físico esa lista **hay que descubrirla leyendo una vuelta**
(~200 ms), la primera vez que se pisa cada pista.

Ése es el único punto donde M5 añade latencia que el `u765` no modela ya.

**Y es justo lo que M4018 no separó**: allí se retrasó *el acuse de todos los bloques*, así
que un CAT acumulaba decenas de retardos y tardaba segundos. Lo que hay que medir es el
retardo **una vez por pista**, no por bloque.

---

## Instrumento 1 — Latencia rotacional real (solo mirar, no cambia nada)

Tres contadores dentro del `u765`, en el dominio del core:

| Nombre | Qué cuenta |
|---|---|
| `tlm_rot_last` | ms entre entrar en `COMMAND_RW_DATA_EXEC2` y salir por `EXEC4` con sector encontrado |
| `tlm_rot_max`  | el máximo de lo anterior desde el último reset (saturante) |
| `tlm_notfound` | veces que se salió por *sector not found* (dos cruces de índice) |

**Qué responde:** cuánta espera está tragando AMSDOS **hoy**, medida en vez de supuesta. Si
`tlm_rot_max` se acerca a 205 ms, queda demostrado en campo que aguanta una vuelta entera y
el diseño de M5 puede esperar a la rotación como la máquina real.

Es el más valioso de los tres y el más barato: no altera nada, solo observa una FSM que ya
existe.

## Instrumento 2 — Retardo selectivo del TrackInfo (el que decide)

Un retardo configurable en el acuse que ve el `u765`, **aplicado solo a los bloques de
TrackInfo** (`sd_buff_type == UPD765_SD_BUFF_TRACKINFO`) y **no** a los de sector.

* Valores desde el menú: **0 / 100 / 200 / 400 ms**. Por defecto 0.
* Es el mismo punto de inserción que M4018, con la condición añadida del tipo de bloque.

**Qué responde:** si M5 puede permitirse descubrir la pista leyendo una vuelta cuando el
CPC cambia de pista.

* Tolera 200-400 ms → M5 es viable con el `u765` como FDC y descubrimiento perezoso.
* Falla ya en 100 ms → hay que **precargar** la lista de IDs al detectar el SEEK, mientras
  el CPC aún está procesando la pista anterior. Eso cambia el diseño, y más vale saberlo
  ahora que después de escribir el RTL.

## Instrumento 3 — Cuántas veces se recarga la pista

Un contador de recargas de `image_trackinfo_dirty` por operación, o simplemente acumulado:

| Nombre | Qué cuenta |
|---|---|
| `tlm_tinfo_rd` | veces que se ha releído la información de pista desde el último reset |

**Qué responde:** el coste total que M5 pagaría. Hacer un CAT y mirar el contador: si son 2
recargas, M5 cuesta 2 vueltas. Si son 40, hace falta caché de listas de IDs por pista (que
es barato: 16 sectores × 8 bytes = 128 B por pista, 5 KB el disco entero).

---

## Cómo exponerlos

A vuestro criterio. La vía natural parece `dbg_state`, que ya sale del `u765` hacia el
diagnóstico (`u765.sv:446`), o el volcado dentro del `.dsk` como el resto de la telemetría
(M4019/M4020, decodificable con `decode_tlm.ps1`). Si los contadores del `u765` no
llegasen al volcado porque éste se escribe al leer físicamente, con que sobrevivan a la
operación y se puedan leer después basta — el criterio es el mismo que ya usáis para el
motivo del rechazo del copiador.

## Protocolo de medida (5 minutos con el CPC)

1. Con retardo a 0: `CAT`, y anotar `tlm_rot_max`, `tlm_notfound` y `tlm_tinfo_rd`.
2. Lo mismo con un `RUN"` de un juego que cargue varias pistas.
3. Repetir la secuencia con el retardo a 100, 200 y 400 ms.
4. Anotar en qué valor falla cada una, y con qué síntoma (cuelgue, *Read fail*, *Retry*).

---

## De paso: un comentario zombi

`main.vhd:145-146` sigue describiendo el retardo de M4018:

```
-- M4018 (MEDIDA, temporal): retardo artificial del acuse que ve el u765.
-- 00 = sin retardo, 01 = 100 ms, 10 = 400 ms, 11 = 1 s.
-- M4023: '1' = separador DPLL, ...
```

La señal ya no existe y el comentario ha quedado pegado a `dpll_en_i`, que es otra cosa. Si
el instrumento 2 reutiliza ese sitio, el comentario vuelve a tener dueño; si no, conviene
borrarlo.
