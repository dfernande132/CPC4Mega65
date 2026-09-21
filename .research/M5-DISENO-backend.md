# M5 — Diseño del backend físico: la pista bajo demanda

Borrador para discutir. **No hay RTL escrito ni voy a escribirlo hasta que esto se apruebe.**

---

## 1. La topología real, que no es la que creíamos

Estuve dos sesiones hablando de "sustituir el `u765`". Al mirar dónde salen de verdad los
bloques, la costura está en otro sitio. `mega65.vhd:308-310`:

> *"Buffers de imagen de disco: RAM solo-QNICE, una por unidad. **El firmware carga la
> imagen entera aquí al montarla y luego sirve los bloques que pide el `u765` desde RAM**,
> en vez de ir a la SD en tiempo real."*

O sea, el camino completo de hoy es:

```
CPC  <->  u765  <--sd_lba/sd_rd-->  vdrives  <->  firmware QNICE  <->  buffer 256 KB (BRAM)
                                                                              ^
                                                        floppy_dsk (puerto B) |
                                                                              |
                          floppy_scan -> floppy_mfm -> disquetera física -----+
```

El `u765` **nunca toca la SD ni la disquetera**. Pide bloques y el firmware se los da del
buffer. Y `floppy_dsk` ya escribe en ese mismo buffer por el puerto B.

**Consecuencia: no hay que tocar el `u765`.** Lo único que hay que cambiar es *cuándo* se
rellena cada pista del buffer. Hoy: las 40 al montar. Propuesta: la que haga falta, cuando
haga falta.

## 2. La arquitectura propuesta: relleno perezoso por pista

```
  el u765 pide un bloque de la pista T
            |
            v
    ¿está T en el buffer?  --si-->  servir desde RAM        (como hoy, microsegundos)
            |
            no
            v
    pedir al RTL "lee la pista T"  ->  seek + 1..2 vueltas  (200..430 ms)
    floppy_scan/floppy_mfm la decodifican
    floppy_dsk la escribe en el buffer, marca T presente
            |
            v
    ahora sí: servir desde RAM
```

Lo que cumple el objetivo declarado: **`CAT` lee una o dos pistas, `LOAD` lee las que
necesite, y montar no lee nada.**

### Por qué esto no es lo que M4018 descartó

M4018 midió *"el `CAT` falla ya con 100 ms de retardo **por bloque**"*. La diferencia:

| | M4018 | Esta propuesta |
|---|---|---|
| Qué se retrasa | **todos** los bloques | sólo el **primero de cada pista** |
| Bloques por `CAT` | decenas | 1-2 pistas |
| Coste acumulado | segundos | 200-430 ms por pista nueva |

El retardo no desaparece: se cobra una vez por pista en vez de una vez por bloque.

### Lo que hace falta medir antes de construirlo, y no está medido

**Aviso importante: el test de estrés de hoy NO valida esta arquitectura.** Midió que
AMSDOS aguanta 410 ms de espera **rotacional dentro del `u765`** (estado `RW_DATA_EXEC3`,
con el FDC ocupado y su modelo girando). Aquí la espera es distinta: el `u765` queda
bloqueado esperando un **bloque** (`buff_wait`), que es otro estado y probablemente otro
timeout de AMSDOS.

Son dos esperas en sitios distintos del protocolo y no hay derecho a suponer que el límite
es el mismo.

→ **El instrumento 2 (retardo selectivo del TrackInfo) vuelve a ser decisivo, no
refinamiento.** Mide exactamente esto: una espera adicional sólo al cambiar de pista.
Con 400 ms de retardo más la rotación, se está probando el caso peor de esta arquitectura.

Mientras no se mida, esta propuesta está *sin validar*, y decirlo ahora es más barato que
descubrirlo con el RTL escrito.

## 3. Presupuesto de latencia

| Concepto | Coste | Nota |
|---|---|---|
| Seek | 3 ms × pistas | `floppy_phys.vhd:89`, `C_STEPRATE_CYC` |
| Asentamiento | 15 ms | `C_SETTLE_CYC` |
| Primera vuelta | 200 ms | localizar y leer todos los sectores |
| Segunda vuelta | 200 ms | sólo si faltan sectores (`expect_i`, M4022) |
| **Peor caso realista** | **~430 ms** | seek de 10 pistas + 2 vueltas |
| **Caso bueno** | **~215 ms** | misma pista de la última vez, 1 vuelta |

El motor ya está en marcha (el CPC lo enciende), así que el arranque de 1 s no entra salvo
en el primer acceso.

## 4. Componentes

### 4.1 Mapa de pistas presentes (nuevo, pequeño)

40 bits, uno por pista: "esta pista ya está en el buffer". Muy parecido a `ok_map_o` de
`floppy_dsk`, que ya existe y ya se usa como permiso de la reescritura por pistas. Se vacía
al cambiar de disquete (`f_diskchanged_i`) y al desmontar.

### 4.2 Orden "lee la pista T" (modificación de `floppy_scan`)

Hoy `floppy_scan` barre las 40 pistas de corrido. Hace falta un modo "una pista, ésta, y
avisa al terminar". Es un cambio de secuenciador, no de decodificación: `floppy_mfm` no se
toca.

### 4.3 El firmware QNICE: la espera

Cuando llega una petición de bloque de una pista ausente y la unidad es la física: disparar
la lectura, **no acusar todavía**, y acusar cuando la pista esté. Es el punto donde M4018
metía su retardo artificial, o sea que el sitio ya está identificado.

Aquí está el grueso del trabajo, y es firmware, no RTL.

### 4.4 Escritura

Cuando el CPC escribe, el `u765` hace `sd_wr` → el firmware escribe al buffer y marca la
pista sucia. **La reescritura por pistas de M4 ya hace el resto** (manual y automática).
No hay trabajo nuevo, sólo conectar el disparo.

### 4.5 Qué NO cambia

`floppy_mfm`, `floppy_phys`, `floppy_write`, `floppy_copy`, el `u765`, `vdrives` y el camino
de las imágenes desde la SD. Esa última es una restricción tuya y esta arquitectura la
respeta por construcción: si la unidad no es la física, no pasa nada distinto de hoy.

## 5. Clases de defecto que hay que impedir desde el diseño

Robadas de la disciplina de propiedad de AExp, que nombra las suyas explícitamente:

1. **Servir una pista que no se leyó entera.** Si una pista da errores de CRC persistentes,
   el buffer tiene datos parciales. Hay que distinguir "presente y completa" de "presente y
   con huecos", y decidir qué se le dice al `u765` — probablemente un error de CRC honesto
   en vez de datos inventados. `floppy_mfm` ya publica esa información por pista.
2. **Servir la pista de otro disquete.** Un cambio de disco sin invalidar el mapa entrega
   datos del anterior. `f_diskchanged_i` existe y es la señal correcta; el fallo sería no
   usarla.
3. **Servir la pista equivocada.** El número de pista que pide el `u765` sale de un LBA;
   traducirlo mal da datos de otra pista sin ningún síntoma visible. Es la misma clase que
   el `unsigned * natural` que ya costó "un disco que se leía sin errores y salía vacío".
4. **Escribir al disco lo que nunca se leyó.** La reescritura por pistas sólo debe tocar
   pistas marcadas presentes y completas; el permiso ya existe (`ok_i` en `floppy_copy`).

## 6. Fases con criterio de verificación

| Fase | Qué | Criterio de éxito |
|---|---|---|
| 0 | **Medir con el instrumento 2** | Se sabe cuánto aguanta AMSDOS esperando un bloque. Si es < 430 ms, rediseñar antes de escribir nada |
| 1 | Mapa de pistas + invalidación por cambio de disco | Telemetría: el mapa se llena al leer y se vacía al expulsar |
| 2 | `floppy_scan` en modo "una pista" | Leer la pista 7 sola y comprobar que el buffer sólo cambia ahí |
| 3 | Firmware: relleno perezoso con espera | `CAT` funciona y el mapa marca sólo 1-2 pistas |
| 4 | `LOAD` de un juego | Carga igual que hoy; el mapa marca las pistas que tocó |
| 5 | Escritura | Guardar un fichero, expulsar, releer, comprobar que persiste |
| 6 | Quitar la pre-lectura del camino normal | Montar ya no lee nada; el tiempo de montaje cae a cero |

La fase 0 es la que decide si esto sigue adelante tal cual.

## 7. Lo que esta arquitectura NO da

**Protecciones.** El buffer es una imagen en formato EDSK, así que sólo puede representar lo
que EDSK representa. La pista 1 de Dynamite 4 (campos solapados) seguirá sin funcionar.

Eso es coherente con lo que dijiste — *"si luego no lee discos anticopia o no, eso lo iremos
mejorando poco a poco"* — y deja el camino abierto: cuando haga falta, el caché puede pasar
de "EDSK por pista" a "campos crudos por pista" sin cambiar el resto de la estructura.

## 8. Comparación honesta con la alternativa

| | Pista bajo demanda (ésta) | Streaming en vivo |
|---|---|---|
| Cambios en el `u765` | **ninguno** | muchos, y son excepciones al submódulo |
| Trabajo principal | firmware QNICE | RTL + CDC + modelo rotacional enganchado al índice real |
| Latencia | 200-430 ms por pista nueva | real, como la máquina |
| Protecciones | no | camino abierto |
| Riesgo para lo que ya funciona | bajo, aislado a la unidad física | alto |

Para el objetivo que fijaste —leer al hacer `CAT`, no al montar, sin perder las imágenes de
la SD— **la primera cumple y la segunda es artillería**. Y la primera no cierra la puerta a
la segunda.

## 9. Preguntas abiertas

1. **La fase 0.** Sin ella esto no se construye.
2. ~~¿Qué hace el `u765` si el firmware tarda 400 ms en acusar?~~ **RESUELTO — ver §10.**
3. ~~¿Cuántas pistas toca de verdad un juego?~~ **MEDIDO SOBRE LA COLECCIÓN — ver §11.**
4. ~~¿La pre-lectura son 8 s o 26?~~ **Calculada: 8,6 s — ver §11.**

---

## 10. RESUELTO: el `u765` no tiene timeout esperando un bloque

Traza de `u765.sv:1224-1276`:

```verilog
COMMAND_RW_DATA_EXEC6:
if (!sd_busy_sector & sd_rd_sector == 2'b00 & sd_wr_sector == 2'b00) begin
   ...
   end else if (!i_timeout) begin
      status[1] <= 8'h10;              // overrun
   ...
   end else begin
      i_timeout <= i_timeout - 1'd1;   // 1272: el UNICO decremento
   end
end else begin                         // 1274: aqui cae mientras sd_busy_sector = 1
   sd_rd_sector <= 0;
   sd_wr_sector <= 0;
end
```

El decremento de `i_timeout` vive **dentro** de la rama que sólo se ejecuta cuando
`!sd_busy_sector`. Mientras el firmware no acusa, `sd_busy_sector` está a 1, la condición es
falsa, y **el contador de overrun queda congelado**.

`sd_busy_sector` se pone a 1 al lanzar la petición (línea 308) y sólo se baja con el flanco
del ack (`ack[5:4] == 2'b10`, líneas 287-291). No hay ningún otro camino de salida.

**Conclusión: el `u765` espera indefinidamente a que llegue el bloque.** El
`OVERRUN_TIMEOUT` de 1 ms es del lado CPU y sólo corre cuando el bloque YA está y se están
entregando bytes al Z80.

Consecuencia para el diseño: **el FDC no es un riesgo**. El único que puede rendirse ante
una espera de 430 ms es AMSDOS, o sea software del CPC. Eso reduce la fase 0 a una sola
pregunta, y la hace además más probable de contestar que sí: el test de estrés ya demostró
que AMSDOS aguanta 410 ms con el FDC ocupado en `RW_DATA_EXEC3`. Queda confirmar que el
estado de espera de bloque se le presenta igual de tolerable, que es lo que mide el
instrumento 2.

---

## 11. MEDIDO: cuántas pistas toca de verdad un disco

Decodificando el directorio CP/M de las 26 imágenes de `E:\CPC4MEGA65\DSK` y mapeando los
bloques de 1 KB a pistas (`scratchpad/pistas.ps1`; DATA = 0 reservadas y directorio en la
pista 0, SYSTEM = 2 reservadas y directorio en la 2):

| Disco | Pistas usadas | Peor fichero | Coste perezoso | Pre-lectura |
|---|---|---|---|---|
| Bomb Jack | 6 / 42 | 6 | **1,5 s** | 9,0 s |
| Batman The Movie | 9 / 43 | 5 | **2,1 s** | 9,2 s |
| Yie Ar Kung Fu | 10 / 40 | 7 | **2,4 s** | 8,6 s |
| Bruce Lee | 11 / 40 | 8 | **2,6 s** | 8,6 s |
| Matchday 2 | 13 / 40 | 9 | **3,0 s** | 8,6 s |
| Ghosts 'N' Goblins | 15 / 40 | 9 | **3,4 s** | 8,6 s |
| Green Beret | 16 / 40 | 5 | **3,7 s** | 8,6 s |
| Total UK Face A | 38 / 43 | 38 | 8,4 s | 9,2 s |
| Exploding Fist (3 juegos) | 40 / 45 | 9 | 8,8 s | 9,7 s |
| CPM Plus 1 y 2 | 39 / 40 | 6 | 8,6 s | 8,6 s |

**Un juego individual toca 6-16 pistas, y su fichero más grande nunca pasa de 9.** Cargar
cuesta ~2-3,5 s de descubrimiento contra los 8,6 s de pre-lectura: **gana 5-6 segundos**.

Un disco lleno de utilidades (CP/M, compilaciones) toca casi todo y el acumulado empata con
la pre-lectura. **Pero el acumulado no es la comparación justa**, y aquí está el argumento
de fondo:

* **Hoy**: 8,6 s **siempre**, al montar, aunque sólo quieras hacer `CAT`.
* **Con relleno perezoso**: 0,2 s para un `CAT`, y después sólo lo que uses. Llegar a 8,6 s
  exige tocar las 40 pistas, y para entonces están todas en el buffer y la segunda pasada es
  gratis.

Es exactamente lo que se pidió: *"que lea cuando se hace un CAT o que se cargue algo con el
LOAD, no como ahora, que tenemos que leer el disco entero al principio"*.

### La pre-lectura son ~8,6 s, no 26

40 pistas × 215 ms = 8,6 s, coherente con `floppy_mfm.vhd:68-70` (*"el recorrido de 40
pistas baja de ~16 s a ~8 s"*). Si muchas pistas necesitan dos vueltas se va a ~16,6 s, y
con el montaje y la construcción de la imagen encima se llega a los 26 s observados. Al
comparar hay que decir con cuál de los tres números se compara.

### LÍMITE DEL MÉTODO, y es importante

Esto cuenta **sólo las pistas que el directorio CP/M declara**. Dos casos de la colección lo
delatan: **Prince de Perse** sale con 1 fichero y 1 pista, y **Dynamite 4** con 2 ficheros y
1 pista, ocupando ambos el disco entero. Son cargadores que leen pistas **directamente por
firmware**, fuera del sistema de ficheros.

Para esos títulos la cifra real de pistas tocadas es mucho mayor y no se puede saber desde
la imagen. **Las cifras de arriba son un límite inferior**, y por eso el instrumento 3
(contar recargas de pista en vivo) sigue mereciendo la pena: es el único que ve a los
trackloaders.

Nota lateral: cuatro directorios no se dejan decodificar (Pack 5 Estrellas, R-Type Face A,
Total UK Face B, CPM Plus 4), por formato vendor o por protección. No cambia la conclusión.
