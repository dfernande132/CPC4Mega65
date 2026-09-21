; ****************************************************************************
; YOUR-PROJECT-NAME (GITHUB-REPO-SHORTNAME) QNICE ROM
;
; Main program that is used to build m2m-rom.rom by make-rom.sh.
; The ROM is loaded by TODO-ADD-NAME-OF-VHDL-FILE-HERE.
;
; The execution starts at the label START_FIRMWARE.
;
; done by YOURNAME in YEAR and licensed under GPL v3
; ****************************************************************************

; If the define RELEASE is defined, then the ROM will be a self-contained and
; self-starting ROM that includes the Monitor (QNICE "operating system") and
; jumps to START_FIRMWARE. In this case it is assumed, that the firmware is
; located in ROM and the variables are located in RAM.
;
; If RELEASE is not defined, then it is assumed that we are in the develop and
; debug mode so that the firmware runs in RAM and can be changed/loaded using
; the standard QNICE Monitor mechanisms such as "M/L" or QTransfer.

#define RELEASE

; ----------------------------------------------------------------------------
; Firmware: M2M system
; ----------------------------------------------------------------------------

; main.asm is the mandatory, so always include it
; It jumps to START_FIRMWARE (see below) after the QNICE "operating system"
; called "Monitor" has been included and initialized
; M4045: indices de menu y device IDs, generados por make_rom.sh
#include "osm_const.asm"
#include "../../M2M/rom/main.asm"

; Only include the Shell, if you want to use the pre-build core automation
; and user experience. If you build your own, then remove this include and
; also remove the include "shell_vars.asm" in the variables section below.
#include "../../M2M/rom/shell.asm"

; ----------------------------------------------------------------------------
; Firmware: Main Code
; ----------------------------------------------------------------------------

                ; Run the Shell: This is where you could put your own system
                ; instead of the shell
START_FIRMWARE  RBRA    START_SHELL, 1

; ----------------------------------------------------------------------------
; Core specific callback functions: Submenus
; ----------------------------------------------------------------------------

; SUBMENU_SUMMARY callback function:
;
; Called when displaying the main menu for every %s that is found in the
; "headline" / starting point of any submenu in config.vhd: You are able to
; change the standard semantics when it comes to summarizing the status of the
; very submenu that is meant by the "headline" / starting point.
;
; Input:
;   R8: pointer to the string that includes the "%s"
;   R9: pointer to the menu item within the M2M$CFG_OPTM_GROUPS structure
;  R10: end-of-menu-marker: if R9 == R10: we reached end of the menu structure
; Output:
;   R8: 0, if no custom SUBMENU_SUMMARY, else:
;       string pointer to completely new headline (do not modify/re-use R8)
;   R9, R10: unchanged

SUBMENU_SUMMARY XOR     R8, R8                  ; R8 = 0 = no custom string
                RET

; ----------------------------------------------------------------------------
; Core specific callback functions: File browsing and disk image mounting
; ----------------------------------------------------------------------------

; FILTER_FILES callback function:
;
; Called by the file- and directory browser. Used to make sure that the 
; browser is only showing valid files and directories.
;
; Input:
;   R8: Name of the file in capital letters
;   R9: 0=file, 1=directory
;  R10: @TODO: Future release: Context (see CTX_* in sysdef.asm)
; Output:
;   R8: 0=do not filter file, i.e. show file
;
; CPC4MEGA65 (M2): al montar una imagen de disco solo se muestran los .DSK, para que el
; navegador no ensucie la lista con las .ROM y la configuracion que viven en el mismo
; directorio /cpc4mega65. El nombre llega ya en mayusculas, asi que se compara con ".DSK".
; Los EDSK usan la misma extension .dsk (lo que cambia es la cabecera del fichero, "E" en vez
; de "M", que distingue el propio u765 - u765.sv:424-427), asi que un solo filtro cubre los dos
; formatos. En cualquier otro contexto no se filtra nada.
FILTER_FILES    INCRB

                CMP     1, R9                   ; los directorios no se filtran nunca
                RBRA    _FFILES_SHOW, Z

                CMP     CTX_MOUNT_DISKIMG, R10  ; contexto: montar imagen de disco?
                RBRA    _FFILES_SHOW, !Z        ; no: no filtrar

                MOVE    CPC_IMGFILE_DSK, R9
                RSUB    M2M$CHK_EXT, 1
                RBRA    _FFILES_SHOW, C         ; es un .DSK: mostrarlo

                MOVE    1, R8                   ; no lo es: ocultarlo
                RBRA    _FFILES_RET, 1

_FFILES_SHOW    XOR     R8, R8                  ; R8 = 0 = do not filter file
_FFILES_RET     DECRB
                RET

; PREP_LOAD_IMAGE callback function:
;
; Some images need to be parsed, for example to extract configuration data or
; to move the file read pointer to the start position of the actual data.
; Sanity checks ("is this a valid file") can also be implemented here.
; Last but not least: The mount system supports the concept of a 2-bit
; "image type". In case this is used at the core of your choice, make sure
; you return the correct image type.
;
; Input:
;   R8: File handle: You are allowed to modify the read pointer of the handle
;   R9: @TODO: Future release: Context (see CTX_* in sysdef.asm)
; Output:
;   R8: 0=OK, error code otherwise
;   R9: image type if R8=0, otherwise 0 or optional ptr to  error msg string
PREP_LOAD_IMAGE XOR     R8, R8                  ; no errors
                XOR     R9, R9                  ; image type hardcoded to 0
                RET

; ----------------------------------------------------------------------------
; Core specific callback functions: Custom tasks
; ----------------------------------------------------------------------------

; PREP_START callback function:
;
; Called right before the core is being started. At this point, the core
; is ready to run, settings are loaded (if the core uses settings) and the
; core is still held in reset (if RESET_KEEP is on). So at this point in time,
; you can execute tasks that change the run-state of the core.
;
; Input: None
; Output:
;   R8: 0=OK, else pointer to string with error message
;   R9: 0=OK, else error code
; M4050: NINGUNA ACCION PUEDE RESUCITAR DESDE EL FICHERO DE AJUSTES.
;
; M2M guarda TODOS los bits del menu sin distinguir entre configuraciones y
; acciones. Si el fichero se guarda con una accion marcada, el core la ejecuta al
; arrancar sin que nadie toque nada.
;
; Con "Read disk now" eso ya se observo en hardware: el core leia el disquete nada
; mas encender. Con "FORMAT WHOLE DISK !!" habria FORMATEADO el disquete que hubiera
; dentro, y con "COPY" lo mismo. Un ajuste guardado no puede desencadenar una accion
; destructiva.
;
; Las CONFIGURACIONES si se conservan a proposito: Internal floppy, Auto write-back
; y lo demas son estados y tiene sentido recordarlos.
PREP_START      SYSCALL(enter, 1)

                MOVE    CPC_OSM_FLOPPY_TEST, R8
                RSUB    CFM_CLEAR_BIT, 1
                MOVE    CPC_OSM_FLOPPY_FMT, R8
                RSUB    CFM_CLEAR_BIT, 1
                MOVE    CPC_OSM_FLOPPY_COPY, R8
                RSUB    CFM_CLEAR_BIT, 1
                MOVE    CPC_OSM_FLOPPY_WB, R8
                RSUB    CFM_CLEAR_BIT, 1
                MOVE    CPC_OSM_FLOPPY_DUMP, R8
                RSUB    CFM_CLEAR_BIT, 1

                SYSCALL(leave, 1)
                XOR     R8, R8
                XOR     R9, R9
                RET

; HANDLE_CORE_IO callback function:
;
; M2M-EXCEPTION core-io-hook. Llamada desde HANDLE_IO en CADA iteracion del bucle
; principal del Shell y de todos sus bucles de espera bloqueantes (OSD, explorador
; de ficheros, ayuda).
;
; QUE HACE AQUI: desmarcar solas las CINCO ACCIONES de la disquetera -Read disk
; now, FORMAT, COPY, WRITE BACK y Dump telemetry- cuando la operacion termina. Los
; bits del menu los escribe el Shell y el core solo los lee, asi que sin esto hay
; que desmarcar a mano antes de poder volver a lanzar la misma accion.
;
; Las CONFIGURACIONES no se tocan: Auto write-back e Internal floppy son estados, y
; desmarcarlas solas seria desconcertante. Dump telemetry estaba en esa lista por
; error hasta M4052: sobrescribe el fichero montado, o sea que es una ACCION, y se
; comportaba distinto de las otras cuatro sin ninguna razon.
;
; DOS RESTRICCIONES QUE MANDAN SOBRE EL DISENO
;
; 1. OPTM_SET provoca un FATAL si OPTM_RUN no esta activo, o sea si el menu no
;    esta en pantalla (M2M/rom/menu.asm:1142). Y la operacion suele terminar con
;    el menu CERRADO. Por eso el REPINTADO se APLAZA: se acumula en una mascara
;    y se aplica en cuanto el menu vuelve a estar a la vista. El bit que ve el
;    core, en cambio, se borra al instante (M4052): no pasa por OPTM_SET.
;
; 2. El estado del core llega como NIVELES, no pulsos (dispositivo 0x0106): bit 0
;    lectura terminada, bit 1 formateo, bit 2 copia o reescritura, bit 3 rechazo,
;    bit 4 volcado servido (M4052).
;    El flanco se detecta aqui. Es mas robusto que mandar un pulso a traves de un
;    cruce de dominios de reloj.
;
; CONTRATO: preservar todos los registros, volver RAPIDO -esto es multitarea
; cooperativa dentro del bucle del Shell- y se puede cambiar la ventana RAMROM.
; De ahi la ruta rapida: sin cambio de estado y sin nada pendiente, se sale sin
; tocar nada, que es el caso comun con diferencia.
;
; Input: None
; Output: None (todos los registros preservados)
HANDLE_CORE_IO  SYSCALL(enter, 1)

                ; --- leer el estado del core ---
                MOVE    M2M$RAMROM_DEV, R0
                MOVE    CPC_DEV_STATUS, @R0
                MOVE    M2M$RAMROM_4KWIN, R0
                MOVE    0, @R0
                MOVE    M2M$RAMROM_DATA, R0
                MOVE    @R0, R0                 ; R0: estado actual
                AND     0x001F, R0              ; M4052: cinco bits

                MOVE    CORE_IO_LAST, R1
                MOVE    CORE_IO_PEND, R2

                CMP     @R1, R0                 ; ha cambiado el estado?
                RBRA    _HCIO_APPLY, Z          ; no: solo mirar lo pendiente

                ; --- flancos de subida ---
                ;
                ; M4052: EL BIT QUE VE EL CORE SE BORRA AQUI MISMO; SOLO EL MENU SE APLAZA.
                ;
                ; Antes se aplazaban las dos cosas, y el motivo del aplazamiento -que OPTM_SET
                ; provoca un FATAL con el menu cerrado- vale SOLO para el menu. CFM_CLEAR_BIT no
                ; llama a OPTM_SET: escribe M2M$CFM_DATA a pelo, y eso se puede hacer siempre.
                ;
                ; El sintoma que quita: terminar una lectura con el menu cerrado y que la
                ; disquetera siguiera girando hasta que el usuario volviera a abrirlo. El bit
                ; seguia puesto, asi que para el core la operacion no habia terminado.
                ;
                ; El menu se reconstruye desde CFM_DATA al abrirlo -eso es lo que descubrio
                ; M4047-, asi que al volver aparece ya desmarcada. El OPTM_SET aplazado hace
                ; falta para el otro caso: el menu abierto MIENTRAS la operacion termina.
                MOVE    @R1, R3                 ; R3: estado anterior
                MOVE    R0, @R1                 ; recordar el nuevo
                NOT     R3, R3
                AND     R0, R3                  ; R3: bits que ACABAN de subir
                RBRA    _HCIO_APPLY, Z          ; solo han bajado: nada nuevo

                MOVE    R3, R4
                AND     0x0001, R4              ; lectura terminada
                RBRA    _HCIO_E1, Z
                OR      0x0001, @R2
                MOVE    CPC_OSM_FLOPPY_TEST, R8
                RSUB    CFM_CLEAR_BIT, 1        ; parar el core YA
_HCIO_E1        MOVE    R3, R4
                AND     0x0002, R4              ; formateo terminado
                RBRA    _HCIO_E2, Z
                OR      0x0002, @R2
                MOVE    CPC_OSM_FLOPPY_FMT, R8
                RSUB    CFM_CLEAR_BIT, 1
_HCIO_E2        MOVE    R3, R4
                AND     0x000C, R4              ; copia/reescritura, hecha o rechazada
                RBRA    _HCIO_E3, Z
                OR      0x000C, @R2
                MOVE    CPC_OSM_FLOPPY_COPY, R8
                RSUB    CFM_CLEAR_BIT, 1
                MOVE    CPC_OSM_FLOPPY_WB, R8
                RSUB    CFM_CLEAR_BIT, 1
_HCIO_E3        MOVE    R3, R4
                AND     0x0010, R4              ; M4052: volcado servido
                RBRA    _HCIO_APPLY, Z
                OR      0x0010, @R2
                MOVE    CPC_OSM_FLOPPY_DUMP, R8
                RSUB    CFM_CLEAR_BIT, 1

                ; --- aplicar lo pendiente, si el menu esta en pantalla ---
_HCIO_APPLY     CMP     0, @R2                  ; hay algo pendiente?
                RBRA    _HCIO_RET, Z

                MOVE    M2M$CSR, R0
                MOVE    @R0, R0
                AND     M2M$CSR_OSM, R0        ; el menu esta a la vista?
                RBRA    _HCIO_RET, Z            ; no: seguir esperando

                ; OPTM_STRUCT distinto de cero = OPTM_RUN esta corriendo. NO vale
                ; OPTM_MENULEVEL: ese es CERO en el menu principal y solo sube al entrar
                ; en un submenu, asi que saltaba la aplicacion justo donde mas se nota.
                ; Es la misma prueba que usa OPTM_LIVE_TEXT (menu.asm:1757).
                MOVE    OPTM_STRUCT, R0
                CMP     0, @R0
                RBRA    _HCIO_RET, Z            ; no: OPTM_SET seria un FATAL

                MOVE    @R2, R3                 ; R3: mascara pendiente

                MOVE    R3, R4
                AND     0x0001, R4
                RBRA    _HCIO_A1, Z
                MOVE    CPC_OSM_FLOPPY_TEST, R8
                RSUB    _HCIO_CLEAR, 1
_HCIO_A1        MOVE    R3, R4
                AND     0x0002, R4
                RBRA    _HCIO_A2, Z
                MOVE    CPC_OSM_FLOPPY_FMT, R8
                RSUB    _HCIO_CLEAR, 1
_HCIO_A2        MOVE    R3, R4
                AND     0x000C, R4
                RBRA    _HCIO_A4, Z
                MOVE    CPC_OSM_FLOPPY_COPY, R8
                RSUB    _HCIO_CLEAR, 1
                MOVE    CPC_OSM_FLOPPY_WB, R8
                RSUB    _HCIO_CLEAR, 1
_HCIO_A4        MOVE    R3, R4
                AND     0x0010, R4              ; M4052
                RBRA    _HCIO_A3, Z
                MOVE    CPC_OSM_FLOPPY_DUMP, R8
                RSUB    _HCIO_CLEAR, 1
_HCIO_A3        MOVE    0, @R2                  ; ya esta aplicado

_HCIO_RET       SYSCALL(leave, 1)
                RET

; Desmarca la linea de menu cuyo indice llega en R8.
;
; DOS PASOS, y el segundo es el que faltaba en M4045/M4046:
;
; 1. OPTM_SET actualiza el array de seleccion del menu y lo repinta. Es API del
;    framework (M2M/rom/menu.asm).
;
; 2. Pero OPTM_SET **NO** propaga el cambio a M2M$CFM_DATA, que es el registro que
;    ve el CORE. Quien lo hace normalmente es OPTM_CB_SEL (M2M/rom/options.asm,
;    etiqueta _OPTMC_NOMNT_1), y solo se ejecuta cuando la seleccion viene de una
;    tecla del usuario.
;
;    Sin este paso el sintoma era exactamente el observado en hardware: el menu se
;    desmarcaba, el core SEGUIA viendo el bit puesto -la disquetera girando- y al
;    salir y volver a entrar el menu se reconstruia desde CFM_DATA y la opcion
;    aparecia marcada otra vez.
;
;    Aqui se borra el bit concreto en vez de volcar el array entero: el indice plano
;    de la linea ES su numero de bit, con banco = indice/16 y bit = indice mod 16.
;
; Input: R8 = indice plano de la linea de menu
_HCIO_CLEAR     SYSCALL(enter, 1)
                MOVE    R8, R0                  ; R0: indice plano
                XOR     R9, R9                  ; R9 = 0 = deseleccionar
                RSUB    OPTM_SET, 1             ; 1) el menu
                MOVE    R0, R8
                RSUB    CFM_CLEAR_BIT, 1        ; 2) el registro que ve el core
                SYSCALL(leave, 1)
                RET

; CFM_CLEAR_BIT: pone a cero UN bit de M2M$CFM_DATA, que es el registro que ve el
; core. El indice plano de la linea de menu ES su numero de bit: banco = indice/16,
; bit = indice mod 16.
;
; Se usa desde dos sitios y por dos motivos distintos:
;   * _HCIO_CLEAR, porque OPTM_SET no propaga a CFM_DATA (ver alli).
;   * PREP_START, para que NINGUNA accion pueda resucitar desde el fichero de ajustes.
;
; Input: R8 = indice plano de la linea de menu
CFM_CLEAR_BIT   SYSCALL(enter, 1)

                MOVE    R8, R1
                AND     0x000F, R1              ; R1: numero de bit dentro del banco
                MOVE    R8, R2
                SHR     4, R2                   ; R2: banco = indice / 16

                MOVE    M2M$CFM_ADDR, R3
                MOVE    R2, @R3                 ; seleccionar el banco

                MOVE    1, R4                   ; R4: mascara del bit
_CFMC_SHIFT     CMP     0, R1
                RBRA    _CFMC_MASK, Z
                SHL     1, R4
                SUB     1, R1
                RBRA    _CFMC_SHIFT, 1

_CFMC_MASK      NOT     R4, R4                  ; invertir para BORRAR
                MOVE    M2M$CFM_DATA, R5
                AND     R4, @R5

                SYSCALL(leave, 1)
                RET



; OSM_SEL_POST callback function:
;
; Called each time the user selects something in the on-screen-menu (OSM),
; and while the OSM is still visible. This means, that this callback function
; is called on each press of one of the valid selection keys with the
; exception that pressing a selection key while hovering over a submenu entry
; or exit point does not call this function. All the functionality and
; semantics associated with a certain menu item is already handled by the
; framework when OSM_SELECTED is called, so you are not able to change the
; basic semantics but you are able to add core specific additional
; "intelligent" semantics and behaviors.
;
; Input:
;   R8: selected menu group (as defined in config.vhd)
;   R9: selected item within menu group
;       in case of single selected items: 0=not selected, 1=selected
;   R10: OPTM_KEY_SELECT (by default means "Return") or
;        OPTM_KEY_SELALT (by default means "Space")
; Output:
;   R8: 0=OK, else pointer to string with error message
;   R9: 0=OK, else error code
OSM_SEL_POST    INCRB
                XOR     R8, R8
                XOR     R9, R9
                DECRB
                RET

; OSM_SEL_PRE callback function:
;
; Identical to the OSM_SEL_POST callback function (see above) but it is being
; called before the functionality and semantics associated with a certain
; menu item has been handled by the framework.
OSM_SEL_PRE     INCRB
                XOR     R8, R8
                XOR     R9, R9
                DECRB
                RET

; ----------------------------------------------------------------------------
; Core specific callback functions: Custom messages
; ----------------------------------------------------------------------------

; CUSTOM_MSG callback function:
;
; Called in various situations where the Shell needs to output a message
; to the end user. The situations and contexts are described in sysdef.asm
;
; Input:
;   R8: Situation (CMSG_* constants in sysdef.asm)
;   R9: Context   (CTX_* constants in sysdef.asm)
; Output:
;   R8: 0=no custom message available, otherwise pointer to string

CUSTOM_MSG      XOR     R8, R8
                RET              

; ----------------------------------------------------------------------------
; Core specific constants and strings
; ----------------------------------------------------------------------------

; Add your core specific constants and strings here

; CPC4MEGA65 (M2): extension de imagen de disco, usada por FILTER_FILES. Vale tanto para DSK
; estandar como para EDSK: los dos usan .dsk y se distinguen por la cabecera del fichero.
CPC_IMGFILE_DSK .ASCII_W ".DSK"

; This needs to be the last thing before the "Variables" sections starts
END_OF_ROM      .DW 0

; ----------------------------------------------------------------------------
; Variables: Need to be located in RAM
; ----------------------------------------------------------------------------

#ifdef RELEASE
                .ORG    0x8000                  ; RAM starts at 0x8000
#endif

;
; add your own variables here
;
; M4045: estado del core en la ultima llamada a HANDLE_CORE_IO, para detectar el
; flanco; y mascara de acciones del menu pendientes de desmarcar, que se aplica
; en cuanto el menu vuelve a estar en pantalla (OPTM_SET da FATAL si no lo esta).
CORE_IO_LAST    .BLOCK 1
CORE_IO_PEND    .BLOCK 1


; M2M Shell variables (only include, if you included "shell.asm" above)
#include "../../M2M/rom/shell_vars.asm"

; ----------------------------------------------------------------------------
; Heap and Stack: Need to be located in RAM after the variables
; ----------------------------------------------------------------------------

; The On-Screen-Menu uses the heap for several data structures. This heap
; is located before the main system heap in memory.
; You need to deduct MENU_HEAP_SIZE from the actual heap size below.
; Example: If your HEAP_SIZE would be 29696, then you write 29696-1024=28672
; instead, but when doing the sanity check calculations, you use 29696
MENU_HEAP_SIZE  .EQU 1024

#ifndef RELEASE

; heap for storing the sorted structure of the current directory entries
; this needs to be the last variable before the monitor variables as it is
; only defined as "BLOCK 1" to avoid a large amount of null-values in
; the ROM file
HEAP_SIZE       .EQU 6144                       ; 7168 - 1024 = 6144
HEAP            .BLOCK 1

; in RELEASE mode: 28k of heap which leads to a better user experience when
; it comes to folders with a lot of files
#else

HEAP_SIZE       .EQU 28672                      ; 29696 - 1024 = 28672
HEAP            .BLOCK 1

; The monitor variables use 22 words, round to 32 for being safe and subtract
; it from FF00 because this is at the moment the highest address that we
; can use as RAM: 0xFEE0
; The stack starts at 0xFEE0 (search var VAR$STACK_START in osm_rom.lis to
; calculate the address). To see, if there is enough room for the stack
; given the HEAP_SIZE do this calculation: Add 29696 words to HEAP which
; is currently 0xXXXX and subtract the result from 0xFEE0. This yields
; currently a stack size of more than 1.5k words, which is sufficient
; for this program.

                .ORG    0xFEE0                  ; TODO: automate calculation
#endif

; STACK_SIZE: Size of the global stack and should be a minimum of 768 words
; after you subtract B_STACK_SIZE.
; B_STACK_SIZE: Size of local stack of the the file- and directory browser. It
; should also have a minimum size of 768 words. If you are not using the
; Shell, then B_STACK_SIZE is not used.
STACK_SIZE      .EQU    1536
B_STACK_SIZE    .EQU    768

#include "../../M2M/rom/main_vars.asm"
