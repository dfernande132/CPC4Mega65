# Alcance real de soportar formatos no-DATA: las dos direcciones

**Respuesta al informe `HALLAZGOS-copiador-formatos.md`.** Ese informe analiza la direccion
IMAGEN -> DISQUETE. Aqui esta la otra, y la conclusion de las dos juntas.

Verificado antes de escribir: el bug del `-shl` (cierto, arreglado), R-Type Face A (cierto, y
mas limpio de lo que decia: `ST1=00 ST2=00` en los diez sectores) y Dynamite 4 pista 1 (cierto,
14.208 bytes de datos en una pista de 6.250).

---

## 1. Las dos direcciones no son simetricas, y eso lo decide todo

    IMAGEN -> DISQUETE   floppy_copy + floppy_write     copiar un .dsk a un disquete real
    DISQUETE -> IMAGEN   floppy_mfm  + floppy_dsk       leer un disquete real a un .dsk

La asimetria que importa: **el Milestone 5 borra la segunda y no toca la primera.**

Si el FDC sirve pistas bajo demanda, no hay imagen en RAM que construir. Desaparecen la
pre-lectura de 26 s, la reescritura por pistas, el mapa de sucias y la lectura automatica al
insertar - todo eso son andamios de tener una copia en memoria. Pero seguir queriendo
**grabar un .dsk en un disquete fisico** es igual de util con M5 que sin el.

O sea: **el trabajo en el escritor es permanente. El trabajo en el lector lo tira M5.**

---

## 2. Que hay clavado en el camino de LECTURA

### 2.1 `floppy_mfm.vhd` - el separador

Mejor de lo esperado en una cosa y peor en otra.

| Qué | Estado | Sirve para |
|---|---|---|
| Tamano de sector | `N=0..3` -> 128/256/512/1024, y **N>3 se trata como ID corrupto** (linea 650) | Total UK (N=3) **si**. Dynamite (N=6) **no** |
| `data_len` | `unsigned(10 downto 0)`, maximo 1024 | No llega a 2048+ |
| Numero de sectores | `sect_cnt` de 5 bits, `seen_map` de 32 | 16 sectores caben |
| **Ranura del sector** | `sec_slot_o <= R(3..0) - 1` (linea 336) | **Aqui esta el problema** |

Esa ultima linea es la que decide donde van los datos en la imagen, y **deduce la posicion a
partir del identificador**: `&C1..&C9` -> ranura 0..8. Es la convencion DATA del CPC metida en
el lector.

Con R-Type (`&C1..&CA`) el decimo sector cae en la ranura 9 y `floppy_dsk` lo descarta
(`slot < G_SECTORS`). Con Dynamite 4 (`R=0x00..0x0F`) el sector `R=0` da ranura -1, que envuelve
a 31. Lo correcto en general es el **indice de orden de aparicion en la pista**, no una cuenta
sobre R.

### 2.2 `floppy_dsk.vhd` - el constructor de imagen

Aqui esta clavado de verdad, y en un sitio peor: **la aritmetica de direcciones**.

    G_SECTORS  = 9        G_SECSIZE = 512
    C_TRACK_SIZE = 256 + 9*512 = 4864      (constante)
    direccion = 512 + pista*4864 + ranura*512 + desplazamiento

Con sectores de tamano variable eso deja de ser una multiplicacion. Hace falta la misma tabla de
desplazamientos acumulados que el informe pide para el escritor, **mas** una tabla de offsets de
PISTA, porque las pistas dejan de medir todas lo mismo.

Los arrays de identificadores (`id_c_arr` ... `id_n_arr`) son de `G_SECTORS` = 9 entradas.

### 2.3 Y el problema que no es de RTL: **el formato del fichero**

`C_DISK_SIG` (linea 175) escribe **`"MV - CPCEMU Disk-File"`**: un DSK ESTANDAR, que tiene UN
tamano de pista para todo el disco en 0x32-33.

Un disco de pistas desiguales **no se puede representar en ese formato**. Para escribirlo hay
que emitir un **EDSK** ("EXTENDED CPC DSK File") con la tabla de tamanos por pista en 0x34, mas
las longitudes reales por sector en cada TrackInfo.

Eso no es tocar una constante: es cambiar el fichero que producimos, y con el la cabecera de
disco, la de pista y toda la aritmetica de arriba.

---

## 3. Alcance de las dos direcciones, junto

| | IMAGEN -> DISQUETE | DISQUETE -> IMAGEN |
|---|---|---|
| Ficheros | `floppy_copy`, `floppy_write` | `floppy_mfm`, `floppy_dsk` |
| Numero de sectores variable | `G_MAXSEC` 9 -> 16 | `sec_slot` deja de salir de R |
| GAP3 variable | constante -> entrada | no aplica |
| Pista sin IAM | anadir salto | no aplica |
| N variable | longitud de datos + tabla acumulada | idem + `data_len` a 13 bits + aceptar N>3 |
| Marca de borrado / sin DAM | anadir | ya se detecta, hay que reflejarlo |
| CRC malo a proposito | anadir | ya se detecta |
| Pistas de tamano desigual | ya lo soporta (lee la tabla EDSK) | **tabla de offsets de pista NUEVA** |
| **Formato de salida** | no aplica | **DSK estandar -> EDSK: rehacer las cabeceras** |
| Riesgo | escribe en disquetes fisicos | solo memoria |
| **Lo borra M5** | **no** | **si** |

---

## 4. Recomendacion

**Hacer el escritor en la 1.0. NO hacer el lector.**

El lector es mas trabajo que el escritor -incluye cambiar el formato de fichero que
producimos- y es justo la mitad que M5 deja sin uso. Invertir ahi ahora es pagar dos veces.

### Como se verifica entonces una copia, si no podemos releerla a imagen

El informe proponia releer con el camino de M4 y contar sectores. Eso no funciona sin tocar el
lector. Pero hay dos vias mejores y las dos existen ya:

1. **La telemetria por pista.** `floppy_mfm` ya publica, por pista, el numero de sectores, los
   identificadores, los errores de CRC de ID y de datos, y las vueltas que hizo falta dar. Eso
   dice si la pista escrita se relee bien **sin necesidad de que la imagen sea correcta**.
   Hace falta un cambio pequeno para que el decimo sector no se pierda: que el indice de ranura
   sea el orden de aparicion y no `R-1`.

2. **El CPC real.** Es la verificacion definitiva y la que ya usamos: copiar R-Type, llevarlo a
   un 6128 y ver si arranca. Un disco que arranca no admite discusion.

### Orden propuesto

| Paso | Que | Prueba | Riesgo |
|---|---|---|---|
| 0 | `-shl` en `valida_copia.ps1` | 26 imagenes, mismo veredicto | ninguno, **ya hecho** |
| 1 | Indice de ranura por orden de aparicion | telemetria de un disco de 9 sectores no cambia | bajo |
| 2 | `G_MAXSEC` 9->16, GAP3 variable, pista sin IAM | **R-Type Face A** copia y arranca en un CPC real | medio |
| 3 | N variable + tabla de desplazamientos | **Total UK** copia, 5 sectores de 1024 | **alto** |
| 4 | Marca de borrado, sector sin DAM, CRC forzable | All Star Hits 2, Dynamite 1-3 | medio |
| 5 | Saltar pistas irreproducibles con aviso | Dynamite 4 copia 42 de 43 y lo dice | bajo |

El paso 2 es la mejor primera prueba que podriamos pedir: **R-Type Face A no tiene ni una
anomalia** -diez sectores N=2, todos los CRC buenos, `ST1=00 ST2=00`-, asi que si algo falla es
culpa nuestra y no de una proteccion rara.

El paso 3 es el peligroso: cambia el rango de `dat_off` y el ancho de `src_off_o`, que es
exactamente la clase de fallo de rango que ya se ha colado dos veces en este proyecto.

---

## 5. Cobertura resultante

| | Ahora | Tras los pasos 1-5 |
|---|---|---|
| Se copian al disquete | 18 de 26 | **25 de 26** |
| Se leen a imagen | solo formato DATA | **igual** - eso es M5 |

Queda fuera Dynamite 4 pista 1, irreproducible desde su EDSK porque los campos de datos se
solapan. Un lector/escritor de flujo si podria copiar **el disquete original** que la contiene,
porque copiaria lo que hay y no lo que un FDC dijo que habia.

---

## 6. Correccion que hay que hacer en los documentos publicos

`README.md`, `ROADMAP.md`, `MANUAL.md` y el anuncio de Discord dicen que estas 8 imagenes
necesitan un controlador de flujo y que por eso van a la 1.5. **Es falso para 7 de las 8.** El
caso mas claro, R-Type Face A, no lleva ninguna proteccion: es el formato Ocean de 10 sectores y
lo rechazamos por tener `G_MAXSEC = 9`.

La justificacion honesta de M5, que ademas es mas fuerte, es la que dio el usuario: **servir
pistas bajo demanda y quitar la pre-lectura de 26 segundos**. Copiar originales protegidos es
una ampliacion de eso, no su razon de ser.

---

## 7. Lista de comprobacion ANTES de sintetizar el paso 3 (N variable)

Aportada por el hilo de M5, y tiene un precedente exacto en este mismo arbol.

`floppy_dsk.vhd:162-167` documenta un fallo que ya nos mordio:

> CUIDADO CON `unsigned * natural` EN numeric_std. Esta definido como
> `L * TO_UNSIGNED(R, L'LENGTH)`, o sea que el entero se convierte al ancho del OTRO operando.
> `track_i` son 7 bits, y `TO_UNSIGNED(4864, 7)` se desborda: 4864 mod 128 = 0, asi que valia
> CERO para todas las pistas.

Sintoma que produjo: **un disco que se leia sin ningun error y salia vacio.** Silencioso, sin
aviso de sintesis, y solo visible mirando el resultado.

El paso 3 cambia justo esa aritmetica -multiplicacion por tablas acumuladas- y amplia los
desplazamientos. Mismo terreno, misma clase de fallo. Antes de gastar una sintesis hay que
comprobar POR SEPARADO que los anchos aguantan el caso peor, que es un desplazamiento de 6144
bytes dentro de una pista:

| Senal | Ahora | Aguanta 6144? | Hace falta |
|---|---|---|---|
| `floppy_write.src_off_o` | 10 bits (0..1023) | **NO** | 14 bits |
| `floppy_write.dat_off` | `range 0 to 511` | **NO** | `0 to 16383` |
| `floppy_copy`, direccion de datos | `sec_ix * C_SECSZ`, C_SECSZ=512 | no aplica | tabla acumulada |
| `floppy_mfm.data_len` | 11 bits, max 1024 | NO, pero **no se toca** | es camino de lectura, o sea M5 |

Regla general que sale de esto: **en `numeric_std`, nunca multiplicar un `unsigned` por un
literal entero sin convertirlo antes a un `unsigned` del ancho que de verdad hace falta.** En
ese fichero ya esta hecho asi a proposito -`C_TRKSZ_U` es un `unsigned(12 downto 0)` y no un
`natural`- precisamente por haberlo sufrido.

## 8. Metodo de verificacion: lazo corto primero, CPC real al final

Tambien del hilo de M5, y se adopta.

Escribir -> releer con la telemetria de `floppy_mfm` es el lazo de depuracion. `tlm_seen_o`
indexa por `ID and 31`, igual que la tabla de ranuras de M4057, asi que para R-Type
(`&C1..&CA` -> 1..10) y para Dynamite 4 (`0x00..0x0F` -> 0..15) funciona sin colisiones.

El CPC real es la **prueba final**, no el bucle de depuracion: gastar un disquete y un viaje a
la otra maquina en cada iteracion es caro y lento, y ademas solo contesta si o no, mientras que
la telemetria dice POR QUE.

## 9. Corregido sobre la marcha en M4057

`floppy_dsk.vhd` tenia `variable slot : integer range 0 to 15` con la asignacion
`slot := to_integer(unsigned(sec_slot_i))` ANTES de la guarda `if slot < G_SECTORS`.
`sec_slot_i` son cinco bits.

Se podia violar **ya antes** de M4057: la ranura salia de `R(3..0) - 1`, y un sector con el
nibble bajo a cero -el `R=0x00` de Ocean Dynamite 4- daba -1, que en cinco bits es 31.

Lo llamativo: el comentario de la declaracion de al lado, dos lineas mas abajo, documenta
EXACTAMENTE este fallo en otra variable (`M4029: ERA 0 to 31 Y EL BLOQUE YA LLEGA A 35`).
Tercera vez en el mismo fichero.
