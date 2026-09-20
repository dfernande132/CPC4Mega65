----------------------------------------------------------------------------------
-- MiSTer2MEGA65 Framework
--
-- Wrapper for the MiSTer core that runs exclusively in the core's clock domanin
--
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.video_modes_pkg.all;

-- CPC4MEGA65 M2: xpm_cdc_array_single para el cruce core->QNICE del lado SD del u765
library xpm;
use xpm.vcomponents.all;

entity main is
   generic (
      G_VDNUM                 : natural;                    -- amount of virtual drives
      -- CPC4MEGA65 M4A: frecuencia de clk_main_i. Hace falta como GENERICO y no vale el puerto
      -- clk_main_speed_i que ya existe: floppy_phys deriva de el constantes de tiempo (arranque
      -- de motor, ancho del pulso de step...) que dimensionan contadores, y eso tiene que ser
      -- una expresion constante en tiempo de elaboracion. Un puerto no lo es.
      G_CLK_HZ                : natural
   );
   port (
      clk_main_i              : in  std_logic;
      reset_soft_i            : in  std_logic;
      reset_hard_i            : in  std_logic;
      pause_i                 : in  std_logic;

      -- CPC4MEGA65 M1A: acceso QNICE (carga de ROM por SD) a las dos ROMs de
      -- arranque, ver core/.research/PORTING-PLAN.md seccion 4.2. Puerto B de
      -- cada dualport_2clk_ram, en el reloj y flanco de QNICE (S72/S73 de la
      -- Porting Guide: FALLING_B => true, sin sincronizador propio necesario).
      qnice_clk_i             : in  std_logic;
      qnice_rom_os_we_i       : in  std_logic;
      qnice_rom_os_addr_i     : in  std_logic_vector(13 downto 0);
      qnice_rom_os_data_i     : in  std_logic_vector(7 downto 0);
      qnice_rom_os_data_o     : out std_logic_vector(7 downto 0);
      qnice_rom_basic_we_i    : in  std_logic;
      qnice_rom_basic_addr_i  : in  std_logic_vector(13 downto 0);
      qnice_rom_basic_data_i  : in  std_logic_vector(7 downto 0);
      qnice_rom_basic_data_o  : out std_logic_vector(7 downto 0);
      qnice_rom_amsdos_we_i   : in  std_logic;
      qnice_rom_amsdos_addr_i : in  std_logic_vector(13 downto 0);
      qnice_rom_amsdos_data_i : in  std_logic_vector(7 downto 0);
      qnice_rom_amsdos_data_o : out std_logic_vector(7 downto 0);

      -- CPC4MEGA65 M2: disquetera por imagen (.DSK/EDSK) - u765 + vdrives.
      -- El reparto de dominios NO es simetrico y es la trampa que marca la Porting Guide
      -- (Parte III seccion 3.I.3); ver PORTING-PLAN.md seccion 9:
      --   - "SD config" (img_*): dominio del CORE. vdrives ya hace el CDC internamente.
      --   - "SD block/byte" (sd_*): dominio de QNICE, sin CDC por parte de vdrives.
      -- Las salidas qnice_sd_lba/rd/wr las genera el u765 en dominio core y se sincronizan
      -- aqui dentro antes de salir por estos puertos (ver i_cdc_u765_main2qnice).
      main_img_mounted_i      : in  std_logic_vector(G_VDNUM - 1 downto 0);
      main_img_readonly_i     : in  std_logic;
      main_img_size_i         : in  std_logic_vector(31 downto 0);

      qnice_sd_lba_o          : out std_logic_vector(31 downto 0);
      qnice_sd_rd_o           : out std_logic_vector(G_VDNUM - 1 downto 0);
      qnice_sd_wr_o           : out std_logic_vector(G_VDNUM - 1 downto 0);
      qnice_sd_ack_i          : in  std_logic;
      qnice_sd_buff_addr_i    : in  std_logic_vector(8 downto 0);
      qnice_sd_buff_dout_i    : in  std_logic_vector(7 downto 0);
      qnice_sd_buff_din_o     : out std_logic_vector(7 downto 0);
      qnice_sd_buff_wr_i      : in  std_logic;

      -- CPC4MEGA65 M2 (M2002): "la disquetera esta girando" para el LED de la placa. Es el
      -- latch del motor, que es literalmente lo que enciende el LED en un CPC real. Dominio
      -- del core, un solo nivel - no necesita CDC para un LED (mismo criterio que el
      -- drive_led_o de QL4M65).
      main_drive_active_o     : out std_logic;

      -- CPC4MEGA65 M4A: disquetera fisica interna. enable la enciende el usuario desde el menu;
      -- las tres senales de estado son las que pinta el LED de la placa (ver mega65.vhd).
      floppy_enable_i         : in  std_logic;
      floppy_busy_o           : out std_logic;
      floppy_ready_o          : out std_logic;
      floppy_error_o          : out std_logic;
      -- Conmuta en cada pulso de indice: a 300 RPM el indice llega 5 veces por segundo, asi que
      -- esto da una onda cuadrada de 2,5 Hz - perfectamente visible en el LED. El pulso crudo
      -- dura un ciclo de 64MHz y no se veria.
      floppy_index_blink_o    : out std_logic;
      floppy_disk_in_o        : out std_logic;
      -- M4B: resultado de leer una vuelta de la pista 0
      floppy_mfm_done_o       : out std_logic;
      floppy_sector_count_o   : out std_logic_vector(4 downto 0);
      floppy_is_hd_o          : out std_logic;
      -- M4B2b-i: resultado del recorrido de las 40 pistas
      floppy_scan_done_o      : out std_logic;
      floppy_bad_tracks_o     : out std_logic_vector(4 downto 0);
      floppy_pos_code_o       : out std_logic_vector(4 downto 0);
      floppy_wr_code_o        : out std_logic_vector(4 downto 0);
      -- M4B2b-ii: puerto de escritura hacia el buffer de imagen (puerto B, libre desde M2)
      floppy_buf_addr_o       : out std_logic_vector(17 downto 0);
      floppy_buf_data_o       : out std_logic_vector(7 downto 0);
      floppy_buf_we_o         : out std_logic;
      -- M4034: lectura del buffer de montaje por el lado del core. El puerto ya existia en
      -- mega65.vhd y estaba sin usar (q_b => open); sacarlo aqui es lo que permite copiar un
      -- .dsk al disquete fisico sin gastar ni un bloque de RAM nuevo. Llegan las DOS unidades
      -- porque el origen de la copia es la que NO sea la disquetera fisica.
      floppy_buf_qa_i         : in  std_logic_vector(7 downto 0) := (others => '0');
      floppy_buf_qb_i         : in  std_logic_vector(7 downto 0) := (others => '0');
      -- M4034: opcion de menu 'copiar disco'
      floppy_copy_en_i        : in  std_logic := '0';
      floppy_copy_busy_o      : out std_logic;
      floppy_copy_done_o      : out std_logic;
      floppy_copy_refused_o   : out std_logic;
      -- M4035: reescritura por pistas
      floppy_wb_en_i          : in  std_logic := '0';   -- boton manual del menu
      floppy_wb_auto_i        : in  std_logic := '0';   -- interruptor de automatico
      floppy_wb_active_o      : out std_logic;          -- '1' = hay una reescritura en marcha
      floppy_wb_pending_o     : out std_logic;          -- '1' = quedan pistas sin volcar
      -- M4039: '1' = la ultima operacion de escritura abrio WGATE durante al menos media
      -- vuelta. Sin esto el LED verde de fin de operacion solo miraba que el recorrido
      -- terminara, no que se hubiera escrito algo - y en M4034..M4038 salio verde 40 veces
      -- seguidas con la puerta abierta 50 ciclos. Un indicador que no puede decir que no,
      -- no informa.
      floppy_wrote_ok_o       : out std_logic;
      -- M4014: a que unidad va la disquetera fisica ('0' = A:, '1' = B:). Hace falta aqui
      -- para saber en cual de las dos hay que volver a disparar el montaje al terminar.
      floppy_tgt_b_i          : in  std_logic;
      -- M4018 (MEDIDA, temporal): retardo artificial del acuse que ve el u765.
      -- 00 = sin retardo, 01 = 100 ms, 10 = 400 ms, 11 = 1 s.
      -- M4023: '1' = separador DPLL, '0' = clasificador de ventanas fijas
      dpll_en_i               : in  std_logic;
      -- M4C1: formateo de pista. floppy_fmt_enable_i es el permiso Y el disparo.
      floppy_fmt_enable_i     : in  std_logic;
      floppy_density_i        : in  std_logic;
      floppy_fmt_busy_o       : out std_logic;
      floppy_fmt_done_o       : out std_logic;
      floppy_fmt_refused_o    : out std_logic;
      floppy_fmt_full_o       : out std_logic;
      floppy_id_is_cpc_o      : out std_logic;

      f_density_o             : out std_logic;
      f_motora_o              : out std_logic;
      f_motorb_o              : out std_logic;
      f_selecta_o             : out std_logic;
      f_selectb_o             : out std_logic;
      f_side1_o               : out std_logic;
      f_stepdir_o             : out std_logic;
      f_step_o                : out std_logic;
      f_wdata_o               : out std_logic;
      f_wgate_o               : out std_logic;
      f_index_i               : in  std_logic;
      f_track0_i              : in  std_logic;
      f_writeprotect_i        : in  std_logic;
      f_diskchanged_i         : in  std_logic;
      f_rdata_i               : in  std_logic;

      -- MiSTer core main clock speed:
      -- Make sure you pass very exact numbers here, because they are used for avoiding clock drift at derived clocks
      clk_main_speed_i        : in  natural;

      -- Video output
      video_ce_o              : out std_logic;
      video_ce_ovl_o          : out std_logic;
      video_red_o             : out std_logic_vector(7 downto 0);
      video_green_o           : out std_logic_vector(7 downto 0);
      video_blue_o            : out std_logic_vector(7 downto 0);
      video_vs_o              : out std_logic;
      video_hs_o              : out std_logic;
      video_hblank_o          : out std_logic;
      video_vblank_o          : out std_logic;

      -- Audio output (Signed PCM)
      audio_left_o            : out signed(15 downto 0);
      audio_right_o           : out signed(15 downto 0);

      -- M2M Keyboard interface
      kb_key_num_i            : in  integer range 0 to 79;    -- cycles through all MEGA65 keys
      kb_key_pressed_n_i      : in  std_logic;                -- low active: debounced feedback: is kb_key_num_i pressed right now?

      -- MEGA65 joysticks and paddles/mouse/potentiometers
      joy_1_up_n_i            : in  std_logic;
      joy_1_down_n_i          : in  std_logic;
      joy_1_left_n_i          : in  std_logic;
      joy_1_right_n_i         : in  std_logic;
      joy_1_fire_n_i          : in  std_logic;

      joy_2_up_n_i            : in  std_logic;
      joy_2_down_n_i          : in  std_logic;
      joy_2_left_n_i          : in  std_logic;
      joy_2_right_n_i         : in  std_logic;
      joy_2_fire_n_i          : in  std_logic;

      pot1_x_i                : in  std_logic_vector(7 downto 0);
      pot1_y_i                : in  std_logic_vector(7 downto 0);
      pot2_x_i                : in  std_logic_vector(7 downto 0);
      pot2_y_i                : in  std_logic_vector(7 downto 0)
   );
end entity main;

architecture synthesis of main is

----------------------------------------------------------------------------------------------
-- CPC4MEGA65 M1A: subsistema de memoria
--
-- Sustituye rtl/sdram.v (SDRAM externa unica para RAM+ROM+VRAM+cinta del core original) por
-- BRAM propia, en dos bloques separados por la regla S72 de la Porting Guide (la memoria se
-- divide por quien necesita alcanzarla, no por como estaba organizada en el original):
--
--   - RAM (128KB, CPC6128 sin ampliar): privada al core, SIN puerto QNICE (nada la escribe
--     desde fuera hasta M5/.SNA). Puerto A = CPU/Amstrad_MMU, puerto B = lectura de video del
--     CRTC/Gate Array (crtc_vram_addr, ver Amstrad_motherboard.v:191). Razonamiento de timing
--     completo (regla S75) en PORTING-PLAN.md secciones 4.4 y 4.5.
--   - ROM (2x16KB: OS/firmware bajo, BASIC banco 0 alto): SI necesita puerto QNICE, se carga
--     por SD via el mecanismo CRTROM de M2M (globals.vhd) igual que el Kickstart del Amiga o
--     Minerva del QL. Sin ROM_PRELOAD (contenido con copyright).
--
-- Amstrad_MMU.v (rtl/Amstrad_MMU.v) NO se modifica: para M1 (modelo CPC6128 fijo, sin
-- expansion) la seleccion de ROM (romen + cpu_addr(15)) se resuelve directamente aqui a
-- partir de la direccion cruda del Z80, sin pasar por el calculo de ROMbank del MMU (que
-- sigue calculando algo internamente pero no se consume mientras romen=1, hasta que
-- M2/AMSDOS lo necesite). mem_addr(16 downto 0) (los 17 bits bajos de la salida de 23 bits
-- de la MMU, sin tocar la aritmetica de RAMmap/RAMpage) es la direccion de RAM.
----------------------------------------------------------------------------------------------

constant C_CPC_RAM_ADDR_WIDTH : natural := 17;   -- 128KB (CPC6128 sin ampliar; M6 lo revisita)
constant C_CPC_ROM_ADDR_WIDTH : natural := 14;   -- 16KB por imagen (OS, BASIC)

-- Puerto A (CPU/Amstrad_MMU, dentro de Amstrad_motherboard) de la RAM
signal main_ram_addr_a  : std_logic_vector(C_CPC_RAM_ADDR_WIDTH-1 downto 0);
signal main_ram_data_a  : std_logic_vector(7 downto 0);
signal main_ram_wren_a  : std_logic;
signal main_ram_q_a     : std_logic_vector(7 downto 0);

-- Puerto B (lectura de video CRTC/GA, via el ensamblador de 16 bits mas abajo)
signal main_ram_addr_b  : std_logic_vector(C_CPC_RAM_ADDR_WIDTH-1 downto 0);
signal main_ram_q_b     : std_logic_vector(7 downto 0);

-- Puerto A (CPU) de cada ROM, seleccionado por cpu_addr(15)/romen mas abajo
signal main_rom_os_addr_a    : std_logic_vector(C_CPC_ROM_ADDR_WIDTH-1 downto 0);
signal main_rom_os_q_a       : std_logic_vector(7 downto 0);
signal main_rom_basic_addr_a : std_logic_vector(C_CPC_ROM_ADDR_WIDTH-1 downto 0);
signal main_rom_basic_q_a    : std_logic_vector(7 downto 0);
-- CPC4MEGA65 M2: AMSDOS, la ROM que aporta los comandos de disco (banco de ROM alta 7)
signal main_rom_amsdos_addr_a : std_logic_vector(C_CPC_ROM_ADDR_WIDTH-1 downto 0);
signal main_rom_amsdos_q_a    : std_logic_vector(7 downto 0);

----------------------------------------------------------------------------------------------
-- CPC4MEGA65 M1B: Amstrad_motherboard (CPU+GA+CRTC+PSG+PPI+MMU reales) y su interfaz externa
----------------------------------------------------------------------------------------------

-- cen_16: equivalente a "ce_16" en Amstrad.sv (Amstrad.sv:119-129) - 16MHz derivados de los
-- 64MHz de clk_main_i por clock-enable (divide por 4), sin PLL adicional. Ritmo del
-- secuenciador S[7:0] del Gate Array - ver PORTING-PLAN.md seccion 4.4.
-- CPC4MEGA65 M2: el contador pasa de 2 a 3 bits para sacar ademas cen_u765 (8MHz, "ce_u765"
-- en Amstrad.sv:127) del MISMO contador, igual que el original. Compartir contador no es
-- cosmetico: garantiza que cada pulso de cen_u765 cae sobre un pulso de cen_16, que es la
-- relacion de fase que tienen en el core original (div[2:0]=0 implica div[1:0]=0).
signal cen_16_div : unsigned(2 downto 0) := (others => '0');
signal cen_16     : std_logic := '0';
signal cen_u765   : std_logic := '0';

-- Interfaz de memoria de Amstrad_motherboard hacia el subsistema de memoria (seccion de
-- arriba) - mismos nombres que sus puertos (mem_addr/mem_rd/mem_wr/romen/cpu_din/cpu_addr/
-- cpu_dout), ver rtl/Amstrad_motherboard.v.
signal mb_mem_addr  : std_logic_vector(22 downto 0);
signal mb_mem_rd    : std_logic;
signal mb_mem_wr    : std_logic;
signal mb_romen     : std_logic;
signal mb_cpu_addr  : std_logic_vector(15 downto 0);
signal mb_cpu_dout  : std_logic_vector(7 downto 0);
signal mb_cpu_din   : std_logic_vector(7 downto 0);

-- CPC4MEGA65 M2: bus de E/S del Z80. En M1 estos tres puertos de Amstrad_motherboard estaban
-- a "open" porque nada fuera del propio motherboard hacia E/S; el FDC es el primer periferico
-- externo que los necesita.
signal mb_iorq      : std_logic;
signal mb_rd        : std_logic;
signal mb_wr        : std_logic;

-- CPC4MEGA65 M2: banco de ROM alta seleccionado, extraido de mem_addr (ver mas abajo)
signal mb_rom_bank  : std_logic_vector(7 downto 0);

----------------------------------------------------------------------------------------------
-- CPC4MEGA65 M2: controlador de disquete uPD765 (u765.sv) y su decodificado de bus
--
-- Replica de Amstrad.sv:732-780. Nuestro main.vhd instancia Amstrad_motherboard directamente
-- (no Amstrad.sv), asi que el pegamento que en el core original vive en el modulo "emu" hay
-- que reponerlo aqui. Los valores no son inventados: salen de leer ese bloque.
--
-- Mapa de E/S del FDC en el CPC (Amstrad.sv:732): el chip select se forma con 4 bits sueltos
-- de la direccion del Z80 - A10, A8, A7 y A0. Con fdc_sel[3:1] = "010" (A10=0, A8=1, A7=0) el
-- acceso es al uPD765 (&FB7E/&FB7F), y A0 elige registro de estado (0) o de datos (1). Con
-- fdc_sel[3:1] = "000" (A10=0, A8=0, A7=0) el acceso es al latch del motor (&FA7E).
----------------------------------------------------------------------------------------------

signal fdc_sel      : std_logic_vector(3 downto 0);
signal io_rd        : std_logic;
signal io_wr        : std_logic;
signal io_wr_d      : std_logic := '0';
signal u765_sel     : std_logic;
signal u765_dout    : std_logic_vector(7 downto 0);
signal u765_motor   : std_logic := '0';
signal u765_ready   : std_logic_vector(1 downto 0) := "00";

-- Lado SD del u765 en dominio CORE (lo genera su bloque "sdcontrol", que se queda en dominio
-- core - ver PORTING-PLAN.md 9.3/9.4) antes de sincronizarse hacia QNICE
signal u765_sd_lba  : std_logic_vector(31 downto 0);
signal u765_sd_rd   : std_logic_vector(1 downto 0);
signal u765_sd_wr   : std_logic_vector(1 downto 0);
signal u765_sd_sel  : std_logic_vector(2 downto 0);   -- {sd_buff_type, tinfo_ds0, tinfo_hds}

-- Version en dominio QNICE de los 3 bits de seleccion, y version en dominio core de sd_ack
signal qnice_sd_sel : std_logic_vector(2 downto 0);
signal main_sd_ack  : std_logic;

----------------------------------------------------------------------------------------------
-- CPC4MEGA65 M2 (M2002): zumbido del motor de la disquetera
--
-- Portado del core del QL, que es de donde lo pidio el usuario ("coge ese mismo sonido").
-- Alli es una onda cuadrada sintetizada y mezclada con el audio de la maquina
-- (QL4M65 CORE/vhdl/main.vhd, procesos mdv1_motor_snd/mdv2_motor_snd). No hay ninguna senal
-- de "audio de disquetera" real que reutilizar en el u765, igual que no la habia en el
-- zx8302 del QL: el sonido de una disquetera es mecanico, no electrico.
--
-- Se reutilizan tal cual el tono y la amplitud que el usuario ya afino DE OIDO en hardware
-- real en el QL (~100Hz y amplitud baja, tras pedir "mas grave y mas bajo" en M2021): son
-- valores elegidos por el, no inventados aqui, y no hay razon para que una disquetera suene
-- distinta de la otra en el mismo MEGA65.
--
-- Diferencia real entre las dos maquinas, y por que el ritmo se saca de otro sitio: el
-- microdrive del QL es una cinta sin fin movida por un motor de continua, y el QL ata el tono
-- a su senal de "gap" para que no suene un tono plano (leccion M2020: un tono continuo salio
-- "monotono"). La disquetera de 3" del CPC si tiene un motor que gira de forma continua
-- mientras esta encendido, asi que aqui el tono suena todo el rato que el motor esta en marcha
-- - pero la AMPLITUD sube mientras hay transferencia real de bloques y baja cuando el motor
-- solo esta girando en vacio. Asi se evita el tono plano sin inventarse ningun ritmo: el gate
-- es actividad de verdad del FDC (sd_rd/sd_wr/sd_ack), no un contador decorativo.
----------------------------------------------------------------------------------------------

-- 64MHz / (2*320000) = 100Hz. En el QL era 84MHz/(2*420000), el mismo tono con su reloj.
-- M4015: el zumbido no sonaba NADA desde M4012, y no era cuestion de volumen sino de
-- aritmetica. 320.000 ciclos a 64 MHz son 5 ms de semiperiodo (tono de 100 Hz), dimensionado
-- para cuando el sonido duraba todo lo que el motor girase. Al atarlo a fdc_busy, cada rafaga
-- dura lo que tarda QNICE en bombear un bloque de 512 bytes -medio milisegundo largo- y
-- ademas el contador se reiniciaba en cada rafaga: fdc_snd_tone no llegaba a conmutar ni una
-- vez y se quedaba en '0', justo el valor que la salida exige que sea '1'.
--
-- Arreglo en tres partes: subir a ~2 kHz (mas parecido a una disquetera de verdad ademas),
-- dejar el oscilador LIBRE mientras el motor gira -lo que se enciende y apaga es la salida,
-- no el oscilador- y estirar cada acceso a 20 ms para que se oiga como un "brrp" en vez de
-- como un fragmento de onda. Accesos seguidos se funden en un zumbido continuo.
-- M4016: vuelta a los 100 Hz originales. Los 2 kHz de M4015 sonaban, pero al usuario le
-- resultaron demasiado agudos; pidio "el mismo que tenian las primeras versiones". Ese era
-- este: 320.000 ciclos de semiperiodo, el mismo registro grave que usa QL4M65 para el zumbido
-- del microdrive. (Se busco tambien en AExp por si tenia uno propio que copiar: no lo tiene,
-- lo del Amiga son los clicks de paso del cabezal del propio Minimig, que es otra cosa.)
--
-- Ahora 100 Hz SI suena, que antes no: lo que impedia oirlo no era la frecuencia sino que el
-- oscilador se reiniciaba en cada rafaga. Con el oscilador libre y la retencion, cada acceso
-- deja sonar varios ciclos completos.
constant C_FDC_SND_HALF_PERIOD : natural := 320000;     -- 5 ms -> 100 Hz
constant C_FDC_SND_HOLD        : natural := 3200000;    -- 50 ms: ~5 ciclos completos a 100 Hz
constant C_FDC_SND_AMP_ACTIVE  : natural := 1500;   -- transferiendo bloques
constant C_FDC_SND_AMP_IDLE    : natural := 500;    -- motor girando en vacio

signal fdc_snd_cnt   : natural range 0 to C_FDC_SND_HALF_PERIOD - 1 := 0;
signal fdc_snd_tone  : std_logic := '0';
signal fdc_snd_hold  : natural range 0 to C_FDC_SND_HOLD := 0;
signal fdc_busy      : std_logic;
signal fdc_snd_audio : signed(15 downto 0);

-- Audio de la maquina ya convertido a PCM con signo, antes de mezclar el zumbido
signal mb_audio_l_s  : signed(15 downto 0);
signal mb_audio_r_s  : signed(15 downto 0);
signal audio_mix_l   : signed(16 downto 0);
signal audio_mix_r   : signed(16 downto 0);

-- Interfaz de video de Amstrad_motherboard (crtc_vram_addr, ver Amstrad_motherboard.v:191) -
-- palabra de 16 bits, ensamblada a partir de dos lecturas de 8 bits del puerto B de la RAM
-- (seccion "Ensamblador de video" mas abajo; razonamiento de margen de tiempo en
-- PORTING-PLAN.md seccion 4.5).
signal mb_vram_addr : std_logic_vector(14 downto 0);
signal mb_vram_din  : std_logic_vector(15 downto 0);

-- Salida de video cruda del core (2 bits por componente, "0..3") y audio (8 bits sin signo)
signal mb_red, mb_green, mb_blue : std_logic_vector(1 downto 0);
signal mb_hsync, mb_vsync, mb_hblank, mb_vblank : std_logic;
signal mb_audio_l, mb_audio_r : std_logic_vector(7 downto 0);

-- Teclado: fila seleccionada por el i8255 (Y) / columna leida por el YM2149 (X) - ver
-- CORE/vhdl/keyboard.vhd y doc/m2m/exceptions.md (submodulo "hid" original quitado)
signal mb_kbd_row : std_logic_vector(3 downto 0);
signal mb_kbd_col : std_logic_vector(7 downto 0);

-- CPC4MEGA65 M3: joysticks en activo alto y en el orden de bits de la matriz del CPC
-- (0=Arriba 1=Abajo 2=Izquierda 3=Derecha 4=Fire1 5=Fire2 6=Fire3) - ver seccion "joysticks"
signal joy1_cpc   : std_logic_vector(6 downto 0);
signal joy2_cpc   : std_logic_vector(6 downto 0);

-- CPC4MEGA65 M4A: disquetera fisica
signal floppy_index_pulse : std_logic;
signal floppy_index_blink : std_logic := '0';
signal floppy_ready       : std_logic;   -- se usa dentro (M4B) ademas de salir al LED
signal floppy_seek_track  : std_logic_vector(6 downto 0);
signal floppy_seek_start  : std_logic;
signal floppy_mfm_restart : std_logic;
signal floppy_mfm_done    : std_logic;
signal floppy_sect_cnt    : std_logic_vector(4 downto 0);
signal floppy_id_track    : std_logic_vector(7 downto 0);
signal floppy_id_side     : std_logic_vector(7 downto 0);
signal floppy_id_sector   : std_logic_vector(7 downto 0);
signal floppy_id_size     : std_logic_vector(7 downto 0);
signal floppy_data_byte   : std_logic_vector(7 downto 0);
signal floppy_data_valid  : std_logic;
signal floppy_data_offset : std_logic_vector(10 downto 0);
signal floppy_sec_slot    : std_logic_vector(4 downto 0);
signal floppy_sec_ok      : std_logic;
signal floppy_dsk_start   : std_logic;

-- M4017: REVERTIDO. Lo que sigue documenta un callejon sin salida, para no repetirlo.
--
-- Se intentaron DOS formas de decirle al u765 que la imagen habia cambiado bajo sus pies, y
-- las dos empeoraron las cosas en hardware:
--   * M4014: simular un montaje nuevo (pulso en img_mounted con img_size propio). Colgaba la
--     unidad: image_ready se quedaba a 0 y AMSDOS reintentaba para siempre con el motor
--     girando (LED rojo fijo).
--   * M4015/M4016: invalidar la cache (image_trackinfo_dirty + i_secinfo_valid) desde fuera,
--     manteniendo el pulso ~4 us. Daba "Read fail" con un EDSK montado y, peor, en M4016
--     colgo TAMBIEN el caso que funcionaba (imagen DATA estandar). El mecanismo en si es
--     correcto -desde el estado de reposo, dirty=1 dispara la recarga sin necesidad de seek
--     (u765.sv:557)- pero mantener el pulso interfiere con una secuencia en vuelo:
--     tinfo_lock, o el lector de informacion de sector, se reinician a mitad.
--
-- Se vuelve al comportamiento de M4013, que es el ultimo estado DEMOSTRADO bueno: con una
-- imagen DATA estandar de 194.816 bytes montada, el CAT da 76K libres y todos los ficheros,
-- identico al CPC real.
--
-- LECCION: todo esto son sintomas de un mismo atajo -reescribir la imagen en la RAM por
-- detras de un modulo que esta pensado para leer ficheros de la SD y que cachea estado ligado
-- al montaje. La solucion no es apuntalar el atajo con mas pulsos, es el montaje de verdad:
-- ver PORTING-PLAN.md seccion 12 (M4D). Lo que queda del comentario original explica POR QUE
-- una imagen cualquiera da un CAT a medias, que sigue siendo cierto y sigue sin arreglarse.
--
-- EL FALLO, diagnosticado sobre el .dsk real del usuario el 2026-09-13. Escribimos la imagen
-- en la RAM por detras, sin volver a montarla, y u765 CACHEA la lista de sectores de cada
-- pista (i_secinfo_valid / image_trackinfo_dirty), invalidandola solo al montar. Asi que
-- seguia usando la lista de la imagen ANTERIOR sobre nuestros datos.
--
-- Por que eso corrompe justo "unas entradas si y otras no": un .dsk real del CPC lleva los
-- sectores en ORDEN FISICO, entrelazado. El Bruce Lee del usuario es "C1 C6 C2 C7 C3 C8 C4
-- C9 C5". Nosotros los colocamos en ORDEN LOGICO (C1..C9, ranura = ID-1). Con la lista vieja
-- sobre nuestros datos sale una PERMUTACION FIJA: pide C1 -> ranura 0 -> le damos C1 (bien),
-- pide C6 -> ranura 1 -> le damos C2 (mal). De ahi un CAT identico en cada intento, con
-- entradas correctas y basura mezcladas, y mas espacio libre del real.
-- Con un .dsk en orden logico (el BLANK-DATA-178K que se genero para probar) coincide todo y
-- el CAT sale perfecto: 76K y todos los ficheros, igual que en el CPC real.
--
-- LO QUE NO ERA: la tabla de desplazamientos de pista. Se creyo eso en M4014 y era falso -
-- el Bruce Lee es un EDSK pero con pistas uniformes de 4864 bytes (0x34.. todo 0x13), asi
-- que la rama EDSK de u765 produce exactamente los mismos offsets que la estandar. M4014
-- simulaba un montaje nuevo para reconstruir esa tabla y ADEMAS colgaba la unidad:
-- image_ready se quedaba a 0 y AMSDOS reintentaba para siempre con el motor girando.
--
-- Por eso aqui solo se invalida la cache, que es el camino que el propio modulo usa al
-- cambiar de pista (u765.sv:537) y no puede bloquearse.
--
-- LIMITE CONOCIDO: si el .dsk montado fuese un EDSK de pistas de tamano VARIABLE (juegos con
-- proteccion), los offsets si serian distintos a los nuestros y esto no bastaria. Para ese
-- caso la via segura es montar una imagen DATA estandar de 194.816 bytes como destino.
signal floppy_scan_done   : std_logic;

-- M4019: senales internas para poder ALIMENTAR LA TELEMETRIA ademas de sacarlas por sus
-- puertos. Antes iban directas al puerto de salida y no habia forma de leerlas aqui.
signal floppy_bad_trk     : std_logic_vector(4 downto 0);
signal floppy_pos_code    : std_logic_vector(4 downto 0);
signal floppy_id_cpc      : std_logic;
signal floppy_is_hd       : std_logic;
signal floppy_tlm_seen    : std_logic_vector(31 downto 0);
signal floppy_tlm_revs    : std_logic_vector(3 downto 0);
signal floppy_tlm_idcrc   : std_logic_vector(15 downto 0);
signal floppy_tlm_dtcrc   : std_logic_vector(15 downto 0);
signal floppy_tlm_flags   : std_logic_vector(7 downto 0);
signal floppy_tlm_pll     : std_logic_vector(15 downto 0);   -- M4024
signal floppy_tlm_runts   : std_logic_vector(15 downto 0);   -- M4025
signal floppy_fmt_wgate   : std_logic_vector(31 downto 0);   -- M4026
signal floppy_fmt_wdata   : std_logic_vector(31 downto 0);
signal floppy_fmt_starts  : std_logic_vector(7 downto 0);
signal floppy_fmt_refus   : std_logic_vector(7 downto 0);
signal floppy_fmt_start   : std_logic;   -- M4027
signal floppy_fmt_done    : std_logic;
signal floppy_fmt_refused : std_logic;

-- M4028: invalidacion de la cache de pista del u765, y retardo del volcado.
--
-- El pulso es de UN ciclo: dentro del u765 la peticion se latchea y se aplica sola cuando el
-- modulo esta en reposo. Eso es lo que le faltaba a M4015, que la sostenia ~4 us desde fuera
-- y pisaba secuencias en vuelo.
--
-- Y el volcado se retrasa 3 s respecto al fin del recorrido: asi la telemetria captura el
-- estado del u765 YA ASENTADO despues de la invalidacion, no el del instante en que termina
-- de leerse la ultima pista. Sin esto, el instrumento mediria el momento equivocado.
constant C_TLM_DELAY      : natural := 192_000_000;   -- 3 s a 64 MHz
signal scan_done_d        : std_logic := '0';
signal tinfo_flush_r      : std_logic := '0';
signal tlm_dly_cnt        : natural range 0 to C_TLM_DELAY := 0;
signal scan_done_dly      : std_logic := '0';
signal u765_dbg           : std_logic_vector(15 downto 0);

-- M4030 EXPERIMENTO. Reproduce a proposito el escenario de M4014 -inyectar un montaje falso
-- al u765 para que acepte nuestra imagen sintetizada- pero esta vez CON EL INSTRUMENTO
-- PUESTO. Alli colgaba la unidad (image_ready a 0 para siempre, AMSDOS reintentando con el
-- motor girando) y nunca se supo en que punto se paraba el re-escaneo.
--
-- Se hace con un fichero MONTADO a proposito, aunque el objetivo final sea no necesitarlo:
-- sin fichero no hay volcado, porque FLUSH_CACHE necesita un manejador, y nos quedariamos
-- sin instrumento justo cuando hace falta. Primero entender, despues quitar el fichero.
--
-- ESTA BUILD ROMPE EL CAMINO QUE FUNCIONA. Es un experimento, no una mejora: para trabajar,
-- volver a M4029 (commit 56acb18).
constant C_IMG_SIZE       : natural := 194816;     -- 256 + 40 x 4864
constant C_REMOUNT_CYC    : natural := 63;         -- ~1 us, de sobra para que se vea el flanco
signal remount_cnt        : natural range 0 to C_REMOUNT_CYC := 0;
signal remount            : std_logic := '0';
signal u765_img_mounted   : std_logic_vector(1 downto 0);
signal u765_img_size      : std_logic_vector(31 downto 0);

-- M4031: dos guardas para el volcado automatico, que hasta ahora se disparaba siempre y
-- habia causado tres daños distintos:
--   1. Sobrescribia la imagen montada (el Shell vuelca el buffer ENTERO sobre el fichero).
--   2. Estampaba la telemetria sobre la cabecera de un EDSK, que ahi es la tabla de tamaños
--      de pista, dejandolo inservible.
--   3. Con NADA montado, FLUSH_CACHE aborta con ERR_FATAL_FZERO porque el manejador de
--      fichero vale cero (shell.asm:1208). Encontrado por el usuario al formatear en limpio.
-- Ahora solo se dispara si la unidad destino ha llegado a montarse de verdad Y si venimos de
-- una LECTURA, no de un formateo.
signal img_ever_mnt       : std_logic_vector(1 downto 0) := "00";
signal read_armed         : std_logic := '0';

-- M4020: VOLCADO AUTONOMO A LA SD.
--
-- El problema practico: para que el Shell escriba la imagen a la tarjeta hace falta que la
-- cache este SUCIA, y eso solo ocurria cuando el CPC escribia algo. Pero escribir desde el
-- CPC funciona ANTES de leer el disquete fisico y falla DESPUES (medido en hardware), asi que
-- justo en el caso que queremos volcar no habia forma de disparar el volcado.
--
-- La salida: al terminar el recorrido, el propio core pide UNA escritura a vdrives. El
-- firmware la atiende (HANDLE_DRV_WR), marca la cache sucia, y 2 s despues FLUSH_CACHE vuelca
-- los 194.816 bytes enteros al fichero .dsk montado.
--
-- Y no estropea nada, que es lo bonito: el buffer de montaje son 256 KB (mega65.vhd,
-- ADDR_WIDTH=18) y la imagen ocupa 194.816, asi que sobran 67.328 bytes al final. La peticion
-- apunta al bloque 400 = byte 204.800, muy por encima de la imagen. El firmware copiara ahi
-- 512 bytes del buffer interno del u765, en una zona que NADIE lee y que FLUSH_CACHE nunca
-- escribe a la tarjeta, porque solo vuelca el tamano del fichero.
constant C_DUMP_LBA       : natural := 400;          -- byte 204.800, fuera de la imagen
signal dump_sd_wr         : std_logic_vector(1 downto 0) := "00";
signal dump_sd_lba        : std_logic_vector(31 downto 0);
signal dump_req           : std_logic := '0';
signal dump_done          : std_logic := '0';
signal dump_scan_d        : std_logic := '0';
constant C_DUMP_TMO       : natural := 6_400_000;    -- 100 ms de guarda
signal dump_tmo           : natural range 0 to C_DUMP_TMO := 0;

-- CPC4MEGA65 M4033: MAPA DE PISTAS SUCIAS (paso 1 de la reescritura por pistas)
--
-- Para poder devolver al disquete fisico lo que el CPC ha escrito hacen falta dos cosas que
-- hasta ahora no existian en ningun sitio: saber QUE pistas ha tocado, y saber cuales de ellas
-- se leyeron enteras (solo esas se pueden regrabar sin perder datos; una pista que no se pudo
-- leer no esta completa en la imagen, y grabarla destruiria el original).
--
-- Esta build SOLO MIDE: construye los dos mapas y los saca en la telemetria. No abre WGATE.
--
-- De bloque de 512 bytes a numero de pista: la imagen es 256 de cabecera + 40 x 4864, y 4864
-- no es multiplo de 512, asi que las pistas no caen en frontera de bloque y un bloque puede
-- pisar dos pistas. En vez de dividir, se recorre la tabla sumando 4864 (40 ciclos como mucho,
-- y las escrituras del u765 estan a milisegundos unas de otras).
constant C_DIRTY_TRKSZ    : natural := 4864;
signal dirty_map          : std_logic_vector(39 downto 0) := (others => '0');
signal dirty_wr_d         : std_logic := '0';
signal dirty_state        : natural range 0 to 1 := 0;
signal dirty_addr         : unsigned(31 downto 0) := (others => '0');
signal dirty_last         : unsigned(31 downto 0) := (others => '0');
signal dirty_lim          : unsigned(31 downto 0) := (others => '0');
signal dirty_trk          : natural range 0 to 63 := 0;
signal dirty_snap         : std_logic_vector(39 downto 0) := (others => '0');

-- CPC4MEGA65 M4034: copiar un .dsk al disquete fisico
signal copy_buf_addr      : std_logic_vector(17 downto 0);
signal copy_buf_q         : std_logic_vector(7 downto 0);
signal copy_hold          : std_logic;
signal copy_trk_last      : std_logic_vector(6 downto 0);
signal copy_busy          : std_logic;
signal copy_done          : std_logic;
signal copy_refused       : std_logic;
signal copy_err           : std_logic_vector(3 downto 0);
signal copy_tlm_trk       : std_logic_vector(7 downto 0);
signal copy_w_nsec        : std_logic_vector(4 downto 0);
signal copy_w_id_c        : std_logic_vector(7 downto 0);
signal copy_w_id_h        : std_logic_vector(7 downto 0);
signal copy_w_id_r        : std_logic_vector(7 downto 0);
signal copy_w_id_n        : std_logic_vector(7 downto 0);
signal copy_w_data        : std_logic_vector(7 downto 0);
signal wr_sec             : std_logic_vector(3 downto 0);
signal wr_off             : std_logic_vector(9 downto 0);
signal dsk_buf_addr       : std_logic_vector(17 downto 0);
signal fmt_hold           : std_logic;
signal scan_trk_last      : std_logic_vector(6 downto 0);

-- M4034: contador CRUDO de flancos de escritura del u765, sin filtrar por pista ni por unidad.
-- Existe para que el volcado distinga 'no hubo ninguna escritura' de 'hubo escrituras pero las
-- mapee mal', que en M4033 eran indistinguibles: el mapa salia a cero en los dos casos. Es la
-- misma leccion de M4029 - un instrumento que no separa dos causas no es un instrumento.
signal wr_edges           : unsigned(15 downto 0) := (others => '0');
signal wr_any_d           : std_logic := '0';

-- CPC4MEGA65 M4035: reescritura por pistas
--
-- El disparo automatico copia el patron de M2M/AExp: una cuenta atras de milisegundos que se
-- RECARGA CON CADA ESCRITURA, no con la primera. O sea que no es 'un segundo desde que se
-- ensucio' sino 'un segundo de silencio del controlador'. Un SAVE del CPC toca la misma pista
-- varias veces seguidas; sin esto se reescribiria la pista entera una vez por sector.
--
-- 1 s y no 2 como AExp: alli lo que se vuelca es un fichero en la tarjeta, que no se puede
-- sacar de golpe. Aqui es un disquete que el usuario puede extraer con la mano, asi que cuanto
-- antes llegue el dato, mejor. Lo que de verdad protege no es el plazo sino el LED AMARILLO
-- mientras quede algo pendiente: ningun temporizador puede garantizar que no saquen el disco,
-- una senal de 'todavia no' si.
constant C_WB_IDLE_MS     : natural := 500;   -- M4038: medido, el suelo real son 189 ms
constant C_MS_CYC         : natural := G_CLK_HZ / 1000;
signal wb_ms_pre          : natural range 0 to C_MS_CYC - 1 := 0;
signal wb_cnt             : natural range 0 to C_WB_IDLE_MS := 0;
signal wb_auto_req        : std_logic := '0';
-- M4036: INSTRUMENTO PARA ELEGIR EL PLAZO CON DATOS EN VEZ DE CON GUSTO.
-- El plazo tiene un suelo: el hueco mas largo entre dos escrituras CONSECUTIVAS del u765
-- dentro de una misma operacion del CPC. Si el plazo baja de ahi, se dispara a mitad de un
-- SAVE. Nadie ha medido nunca ese hueco, asi que 1000 ms y 300 ms son igual de inventados.
-- Esto lo mide, y el numero definitivo sale del volcado.
signal wb_gap_ms          : unsigned(15 downto 0) := (others => '0');
signal wb_gap_max         : unsigned(15 downto 0) := (others => '0');
signal wb_fires           : unsigned(7 downto 0) := (others => '0');
-- M4037: y se PUBLICAN fotografiados, no en vivo. El volcado se escribe al final de una lectura
-- y estos contadores se ponen a cero al principio de esa MISMA lectura, asi que en vivo
-- publicaban siempre cero. Es el mismo fallo que ya se arreglo para el mapa de pistas sucias en
-- M4033 (dirty_snap) y que aqui se repitio sin darse cuenta.
signal wb_gap_max_s       : unsigned(15 downto 0) := (others => '0');
signal wb_fires_s         : unsigned(7 downto 0) := (others => '0');
signal wr_edges_s         : unsigned(15 downto 0) := (others => '0');
signal fmt_abort          : std_logic_vector(7 downto 0);   -- M4038
signal fmt_idxend         : std_logic_vector(7 downto 0);
signal fmt_stopst         : std_logic_vector(7 downto 0);
signal fmt_wgmax          : std_logic_vector(31 downto 0);
signal fmt_idxwr          : std_logic_vector(15 downto 0);   -- M4039
signal fmt_blind          : std_logic_vector(15 downto 0);
signal wb_active          : std_logic;
signal wb_mode            : std_logic;
signal wb_skip            : std_logic;
signal copy_wrote         : std_logic;
signal copy_wrote_trk     : std_logic_vector(6 downto 0);
signal copy_blocked       : std_logic_vector(7 downto 0);
signal ok_map             : std_logic_vector(39 downto 0);
signal dchg_d             : std_logic := '1';
signal fmt_skip           : std_logic;
signal floppy_src_en      : std_logic;
signal floppy_cp_on       : std_logic;

-- M4018 fue una build de MEDIDA: retrasaba artificialmente la subida del acuse que ve el u765
-- para averiguar cuanta latencia por bloque tolera la cadena, que es LA pregunta que decidia
-- si M4D (leer pistas bajo demanda) era viable. RESULTADO: falla ya con 100 ms, asi que el
-- diseño bajo demanda queda descartado y no se llego a escribir el traductor de bloques.
-- Medida hecha y anotada en DECISIONES.md; el andamiaje se ha quitado en M4023.

signal floppy_track_done  : std_logic;
signal floppy_done_track  : std_logic_vector(6 downto 0);   -- M4021
signal floppy_expect      : std_logic_vector(4 downto 0);   -- M4022
signal floppy_cur_track   : std_logic_vector(6 downto 0);
signal floppy_wprot       : std_logic;
-- Recorrido de pistas: solo con la lectura, nunca durante un formateo (ver i_floppy_scan)
signal floppy_scan_enable : std_logic;

-- rom_map: mapa de bancos de ROM alta que existen de verdad. La MMU lo usa para filtrar la
-- seleccion de banco que hace el software: "ROMbank <= rom_map[D] ? D : 8'h00"
-- (Amstrad_MMU.v:71), o sea que un banco no declarado cae en el 0 (BASIC).
-- CPC4MEGA65 M2: en M1 este mapa era decorativo (solo existia el banco 0 y nada leia ROMbank).
-- Ahora es funcional: el bit 7 declara AMSDOS, que es donde el CPC6128 real la tiene y donde
-- el core original la carga (Amstrad.sv:343, "2,6: boot_a[22:14] <= 9'h107").
signal mb_rom_map : std_logic_vector(255 downto 0) := (0 => '1', 7 => '1', others => '0');

----------------------------------------------------------------------------------------------
-- Ensamblador de video: 2 lecturas de 8 bits del puerto B de la RAM -> 1 palabra de 16 bits
-- para Amstrad_motherboard.vram_din. Ver PORTING-PLAN.md seccion 4.5: la direccion de video
-- (crtc_vram_addr) esta estable ~64 ciclos de clk_main_i entre cambios, frente a los 3 que
-- necesita este ensamblador - margen amplio, no hace falta ir a la par de cada cambio.
----------------------------------------------------------------------------------------------

type t_vram_fetch_state is (S_ADDR_EVEN, S_ADDR_ODD, S_CAP_EVEN, S_CAP_ODD);
signal vram_fetch_state : t_vram_fetch_state := S_ADDR_EVEN;
signal vram_word_addr   : std_logic_vector(14 downto 0) := (others => '0');
signal vram_even_byte   : std_logic_vector(7 downto 0) := (others => '0');
signal vram_din_reg     : std_logic_vector(15 downto 0) := (others => '0');

begin

   ----------------------------------------------------------------------------------------------
   -- CPC4MEGA65 M1A: instanciacion de los tres bloques de memoria
   ----------------------------------------------------------------------------------------------

   i_cpc_ram : entity work.dualport_2clk_ram
      generic map (
         ADDR_WIDTH => C_CPC_RAM_ADDR_WIDTH,
         DATA_WIDTH => 8,
         FALLING_A  => false,   -- CPU: flanco de subida, clk_main_i
         FALLING_B  => false    -- video CRTC/GA: flanco de subida, mismo clk_main_i (NO es QNICE)
      )
      port map (
         clock_a   => clk_main_i,
         address_a => main_ram_addr_a,
         data_a    => main_ram_data_a,
         wren_a    => main_ram_wren_a,
         q_a       => main_ram_q_a,

         clock_b   => clk_main_i,
         address_b => main_ram_addr_b,
         data_b    => (others => '0'),   -- video nunca escribe
         wren_b    => '0',
         q_b       => main_ram_q_b
      ); -- i_cpc_ram

   i_cpc_rom_os : entity work.dualport_2clk_ram
      generic map (
         ADDR_WIDTH => C_CPC_ROM_ADDR_WIDTH,
         DATA_WIDTH => 8,
         FALLING_A  => false,   -- CPU: flanco de subida, clk_main_i
         FALLING_B  => true     -- QNICE: flanco de bajada (contrato S73 de la Porting Guide)
      )
      port map (
         clock_a   => clk_main_i,
         address_a => main_rom_os_addr_a,
         data_a    => (others => '0'),   -- el Z80 nunca escribe en ROM
         wren_a    => '0',
         q_a       => main_rom_os_q_a,

         clock_b   => qnice_clk_i,
         address_b => qnice_rom_os_addr_i,
         data_b    => qnice_rom_os_data_i,
         wren_b    => qnice_rom_os_we_i,
         q_b       => qnice_rom_os_data_o
      ); -- i_cpc_rom_os

   i_cpc_rom_basic : entity work.dualport_2clk_ram
      generic map (
         ADDR_WIDTH => C_CPC_ROM_ADDR_WIDTH,
         DATA_WIDTH => 8,
         FALLING_A  => false,
         FALLING_B  => true
      )
      port map (
         clock_a   => clk_main_i,
         address_a => main_rom_basic_addr_a,
         data_a    => (others => '0'),
         wren_a    => '0',
         q_a       => main_rom_basic_q_a,

         clock_b   => qnice_clk_i,
         address_b => qnice_rom_basic_addr_i,
         data_b    => qnice_rom_basic_data_i,
         wren_b    => qnice_rom_basic_we_i,
         q_b       => qnice_rom_basic_data_o
      ); -- i_cpc_rom_basic

   -- CPC4MEGA65 M2: AMSDOS. Misma forma que las otras dos ROMs; lo que cambia es el mux de
   -- lectura de mas abajo, que ahora tiene que mirar el banco de ROM alta seleccionado.
   i_cpc_rom_amsdos : entity work.dualport_2clk_ram
      generic map (
         ADDR_WIDTH => C_CPC_ROM_ADDR_WIDTH,
         DATA_WIDTH => 8,
         FALLING_A  => false,
         FALLING_B  => true
      )
      port map (
         clock_a   => clk_main_i,
         address_a => main_rom_amsdos_addr_a,
         data_a    => (others => '0'),
         wren_a    => '0',
         q_a       => main_rom_amsdos_q_a,

         clock_b   => qnice_clk_i,
         address_b => qnice_rom_amsdos_addr_i,
         data_b    => qnice_rom_amsdos_data_i,
         wren_b    => qnice_rom_amsdos_we_i,
         q_b       => qnice_rom_amsdos_data_o
      ); -- i_cpc_rom_amsdos

   ----------------------------------------------------------------------------------------------
   -- CPC4MEGA65 M1B: cen_16 (16MHz desde los 64MHz de clk_main_i, ver Amstrad.sv:119-129)
   ----------------------------------------------------------------------------------------------

   process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         cen_16_div <= cen_16_div + 1;
         if cen_16_div(1 downto 0) = "00" then
            cen_16 <= '1';
         else
            cen_16 <= '0';
         end if;
         if cen_16_div = "000" then
            cen_u765 <= '1';
         else
            cen_u765 <= '0';
         end if;
      end if;
   end process;

   ----------------------------------------------------------------------------------------------
   -- CPC4MEGA65 M1B: arbitraje de memoria (RAM/ROM) para Amstrad_motherboard
   --
   -- Las escrituras SIEMPRE van a RAM, nunca a ROM (romen solo afecta lecturas - igual que en
   -- hardware real, donde el chip de ROM no tiene pin de escritura). Esto es una pequena
   -- mejora deliberada sobre el core original: alli, al compartir una unica SDRAM, una
   -- escritura con romen_n=0 corrompia la copia de la ROM en la SDRAM en vez de no hacer nada
   -- - inofensivo en la practica (ningun software de arranque depende de ese comportamiento)
   -- pero ya no reproducible tal cual con dos BRAMs separadas, y el nuevo comportamiento es
   -- mas fiel al hardware real. Ver DECISIONES.md para el razonamiento completo.
   ----------------------------------------------------------------------------------------------

   main_ram_addr_a <= mb_mem_addr(C_CPC_RAM_ADDR_WIDTH-1 downto 0);
   main_ram_data_a <= mb_cpu_dout;
   main_ram_wren_a <= mb_mem_wr and not mb_romen;

   main_rom_os_addr_a     <= mb_cpu_addr(13 downto 0);
   main_rom_basic_addr_a  <= mb_cpu_addr(13 downto 0);
   main_rom_amsdos_addr_a <= mb_cpu_addr(13 downto 0);

   -- CPC4MEGA65 M2: banco de ROM alta seleccionado. NO hace falta tocar Amstrad_MMU.v ni sacar
   -- un puerto nuevo: la MMU ya publica el banco dentro de la direccion que saca por mem_addr.
   -- Su calculo es "ram_A[22:14] = {9{A[15]}} & {1'b1, ROMbank}" (Amstrad_MMU.v:78), o sea que
   -- con A15=1 (ROM alta) mem_addr(22)='1' y mem_addr(21 downto 14) ES el ROMbank. Ademas la
   -- MMU ya aplica el filtro de rom_map por nosotros: "ROMbank <= rom_map[D] ? D : 8'h00"
   -- (Amstrad_MMU.v:71), asi que un banco no declarado cae solo en el 0 (BASIC), que es el
   -- comportamiento del CPC real.
   mb_rom_bank <= mb_mem_addr(21 downto 14);

   -- CPC4MEGA65 M2: el FDC va PRIMERO, con prioridad sobre ROM y RAM. Razon: las dos ramas de
   -- ROM solo miran romen y cpu_addr(15), no mb_mem_rd, asi que durante un ciclo de E/S con
   -- romen='1' la ROM ganaria el mux y el Z80 leeria basura en vez del registro del uPD765.
   -- (En el core original esto no pasaba porque cpu_din es un AND cableado de buses tipo
   -- colector abierto - Amstrad.sv:955 - donde cada periferico no seleccionado devuelve FF.)
   -- Se prefiere anadir la rama del FDC arriba antes que meter mb_mem_rd en las ramas de ROM:
   -- eso ultimo tocaria el camino de arranque ya validado en hardware en M1.
   mb_cpu_din <= u765_dout           when (u765_sel = '1' and io_rd = '1') else
                 main_rom_os_q_a     when (mb_romen = '1' and mb_cpu_addr(15) = '0') else
                 main_rom_amsdos_q_a when (mb_romen = '1' and mb_cpu_addr(15) = '1'
                                           and mb_rom_bank = x"07") else
                 main_rom_basic_q_a  when (mb_romen = '1' and mb_cpu_addr(15) = '1') else
                 main_ram_q_a        when mb_mem_rd = '1' else
                 x"FF";

   ----------------------------------------------------------------------------------------------
   -- CPC4MEGA65 M1B: ensamblador de video (ver declaracion de tipos/senales mas arriba)
   ----------------------------------------------------------------------------------------------

   process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         -- CPC4MEGA65 (M1B005): la version anterior capturaba los dos bytes un ciclo antes de
         -- tiempo, y el efecto neto era ensamblar {par, impar} en vez de {impar, par}: la
         -- palabra salia con los bytes intercambiados. Sintoma en pantalla, descrito por el
         -- usuario mirando la letra "R" de "Ready": en Modo 1 cada byte son 4 pixeles, asi que
         -- las 4 primeras columnas de cada caracter salian donde van las 4 ultimas y viceversa
         -- (las filas, correctas). Huella exacta de un byte swap en un fetch de 2 bytes.
         --
         -- Contabilidad de latencia (dualport_2clk_ram: direccion registrada en un flanco ->
         -- dato valido durante el ciclo SIGUIENTE, es decir q_b en el ciclo N corresponde a la
         -- direccion que estaba puesta en el ciclo N-1):
         --   S_ADDR_EVEN: pone direccion par     -> q_b la refleja en S_CAP_EVEN
         --   S_ADDR_ODD : pone direccion impar   -> q_b la refleja en S_CAP_ODD
         --   S_CAP_EVEN : captura el byte par
         --   S_CAP_ODD  : captura el byte impar y ensambla
         --
         -- Orden de bytes: {impar, par} en {15:8, 7:0}, igual que hacia sdram.v en el core
         -- original (escribia el byte par por DQML/data[7:0] y el impar por DQMH/data[15:8],
         -- y leia con "ram_dout <= a[0] ? data[15:8] : data[7:0]").
         case vram_fetch_state is
            when S_ADDR_EVEN =>
               vram_word_addr   <= mb_vram_addr;                 -- foto del pedido actual del CRTC/GA
               -- video siempre lee de los primeros 64KB (bit alto a '0') - ver PORTING-PLAN.md
               -- seccion 4.5
               main_ram_addr_b  <= '0' & mb_vram_addr & '0';     -- direccion del byte par
               vram_fetch_state <= S_ADDR_ODD;
            when S_ADDR_ODD =>
               main_ram_addr_b  <= '0' & vram_word_addr & '1';   -- direccion del byte impar
               vram_fetch_state <= S_CAP_EVEN;
            when S_CAP_EVEN =>
               vram_even_byte   <= main_ram_q_b;                 -- byte par, ya valido
               vram_fetch_state <= S_CAP_ODD;
            when S_CAP_ODD =>
               vram_din_reg     <= main_ram_q_b & vram_even_byte; -- {impar, par}
               vram_fetch_state <= S_ADDR_EVEN;
         end case;
      end if;
   end process;

   mb_vram_din <= vram_din_reg;

   ----------------------------------------------------------------------------------------------
   -- CPC4MEGA65 M1B: conversion de video (2 bits/componente -> 8 bits) y audio (8 bits sin
   -- signo -> PCM de 16 bits con signo)
   ----------------------------------------------------------------------------------------------

   -- CPC4MEGA65 (M1B003): los 2 bits por canal que saca el Gate Array NO son un valor binario
   -- de brillo - son un codigo de 3 estados ("00", "X1", "10") que indexa la paleta real de 27
   -- colores del CPC, medida del hardware real (ver rtl/color_mix.sv y
   -- grimware.org/doku.php/documentations/devices/gatearray). La primera version de este port
   -- hacia replicacion de bits (mb_red & mb_red & ...), lo que daba colores muy equivocados:
   -- p.ej. "10" (rojo full, 0xF3 real) salia como 0xAA, y "11" - que la paleta real trata como
   -- MEDIA intensidad (patron "X1") - salia como 0xFF, o sea al reves. De ahi el aspecto raro
   -- del texto del Amstrad en pantalla. Se usa el propio color_mix.sv del core (que ademas
   -- registra sync/blank junto con el color, alineandolos), con mix=0 = paleta GA en color.
   i_color_mix : entity work.color_mix
      port map (
         clk_vid    => clk_main_i,
         ce_pix     => cen_16,
         mix        => "000",         -- 0 = Color (GA); 1 = Color (ASIC); 2..5 = verde/ambar/cian/gris
         R_in       => mb_red,
         G_in       => mb_green,
         B_in       => mb_blue,
         HSync_in   => mb_hsync,
         VSync_in   => mb_vsync,
         HBlank_in  => mb_hblank,
         VBlank_in  => mb_vblank,
         R_out      => video_red_o,
         G_out      => video_green_o,
         B_out      => video_blue_o,
         HSync_out  => video_hs_o,
         VSync_out  => video_vs_o,
         HBlank_out => video_hblank_o,
         VBlank_out => video_vblank_o
      ); -- i_color_mix
   video_ce_o     <= cen_16;   -- reloj de pixel nativo del CPC = 16MHz (modo 640, el mas rapido)
   -- CPC4MEGA65: video_ce_ovl_o NO puede ser igual a video_ce_o salvo que la resolucion
   -- nativa ya sea VGA_DX x VGA_DY (720x576) - no es nuestro caso (max 640 en modo 2). La
   -- wiki de Video Pipeline (S2.5/S4.4) avisa explicitamente de esto: derivar el enable de
   -- overlay del reloj de pixel NATIVO en vez de uno que de suficientes pulsos por linea
   -- "doblada" hace que el mezclador del escalador de linea y el sincronismo regenerado
   -- batan entre si (patron de peine/ondulacion, HSYNC con periodo inestable, monitores
   -- analogicos perdiendo el sync) - sintoma consistente con "ruido" visto en HDMI y "nada"
   -- en VGA. Seguimos el patron de C64MEGA65 para un core con raster real (no panel fijo
   -- como el Game Boy, que necesita enganchar el enable al propio contador del scandoubler):
   -- en modo Estandar (sin retro15kHz, que no soportamos hasta M3), simplemente sin gating -
   -- el mezclador muestrea en cada ciclo de clk_main_i, de sobra para 720 muestras por linea.
   video_ce_ovl_o <= '1';

   -- Descentra la muestra sin signo de 8 bits (0..255, centro 128) a con signo (-128..127)
   -- invirtiendo el bit de signo - identico a restar 128 en aritmetica de complemento a 2 -
   -- y la desplaza a la mitad alta de los 16 bits.
   mb_audio_l_s <= signed((not mb_audio_l(7)) & mb_audio_l(6 downto 0) & x"00");
   mb_audio_r_s <= signed((not mb_audio_r(7)) & mb_audio_r(6 downto 0) & x"00");

   -- CPC4MEGA65 M2 (M2002): mezcla del zumbido de la disquetera (ver seccion de declaraciones).
   -- Se mezcla en 17 bits y se satura antes de volver a 16, exactamente como hace el QL: asi un
   -- pico del PSG coincidiendo con el zumbido nunca puede dar la vuelta y convertirse en un
   -- chasquido. Peor caso 0x7FFF + 1500 = 34267, de sobra dentro del rango de 17 bits con signo.
   -- CPC4MEGA65 (M4011): el zumbido de la disquetera se quita a peticion del usuario. El CPC
   -- ya hace su propio ruido al acceder al disco, y el motor sigue girando varios segundos
   -- despues del acceso (timeout de AMSDOS), asi que el zumbido se alargaba mucho mas que la
   -- lectura real y molestaba. El generador de tono se deja en el fichero pero sin mezclar.
   audio_mix_l <= resize(mb_audio_l_s, 17) + resize(fdc_snd_audio, 17);
   audio_mix_r <= resize(mb_audio_r_s, 17) + resize(fdc_snd_audio, 17);

   audio_left_o  <= to_signed(16#7FFF#, 16)  when audio_mix_l > to_signed(16#7FFF#, 17) else
                    to_signed(-16#8000#, 16) when audio_mix_l < to_signed(-16#8000#, 17) else
                    audio_mix_l(15 downto 0);
   audio_right_o <= to_signed(16#7FFF#, 16)  when audio_mix_r > to_signed(16#7FFF#, 17) else
                    to_signed(-16#8000#, 16) when audio_mix_r < to_signed(-16#8000#, 17) else
                    audio_mix_r(15 downto 0);

   ----------------------------------------------------------------------------------------------
   -- CPC4MEGA65 M1B: Amstrad_motherboard - CPU (T80pa) + Gate Array + CRTC + PSG + PPI + MMU
   --
   -- Instanciado tal cual (sin modificar salvo el teclado, ver doc/m2m/exceptions.md) como
   -- modulo Verilog desde VHDL - frontera de lenguaje mixto estandar del framework (Porting
   -- Guide Parte III seccion 3.E). No se reimplementa el cableado interno CPU<->GA<->CRTC<->
   -- PSG<->PPI<->MMU: ya es correcto en el core original, ver PORTING-PLAN.md seccion "M1B".
   --
   -- Entradas fijadas para el alcance de M1 (arranque nativo, modelo CPC6128, sin cinta/disco/
   -- Dandanator/PlayCity/snapshot/joystick/raton):
   --   ppi_jumpers = "1111"   (Amstrad + 50Hz, igual que Amstrad.sv con status por defecto)
   --   crtc_type   = '1'      (Type 1 = UM6845R, el tipo real del CPC6128 - Amstrad.sv:978,
   --                            status[2] por defecto en 0 -> crtc_type = ~status[2] = 1)
   --   sync_filter = '1'      (fijo en el core original, Amstrad.sv:979)
   --   no_wait     = '0'      (timing de contencion autentico, "CPU timings: Original")
   --   ram64k      = '0'      (modelo CPC6128, Amstrad.sv:1022 - ram64k = model != 0)
   --   sna_*       = inactivos (snapshot .SNA es Milestone 5)
   --   tape_in     = '0', tape_out/tape_motor sin conectar (cinta es Milestone 5)
   --   irq/nmi     = '0'      (ambos vienen de PlayCity en el core original - backlog)
   ----------------------------------------------------------------------------------------------

   i_amstrad_motherboard : entity work.Amstrad_motherboard
      port map (
         reset            => reset_soft_i or reset_hard_i,
         clk              => clk_main_i,
         ce_16            => cen_16,

         kbd_row_o        => mb_kbd_row,
         kbd_col_i        => mb_kbd_col,
         joy1_sel         => open,
         joy2_sel         => open,

         ppi_jumpers      => "1111",
         crtc_type        => '1',
         sync_filter      => '1',
         no_wait          => '0',

         sna_load         => '0',
         sna_cpu_dir      => (others => '0'),
         sna_crtc_addr    => (others => '0'),
         sna_crtc_regs    => (others => '0'),
         sna_ga_inksel    => (others => '0'),
         sna_ga_palette   => (others => '0'),
         sna_ga_config    => (others => '0'),
         sna_ram_config   => (others => '0'),
         sna_rom_select   => (others => '0'),
         sna_ppi_a        => (others => '0'),
         sna_ppi_b        => (others => '0'),
         sna_ppi_c        => (others => '0'),
         sna_ppi_control  => (others => '0'),
         sna_psg_addr     => (others => '0'),
         sna_psg_regs     => (others => '0'),

         tape_in          => '0',
         tape_out         => open,
         tape_motor       => open,

         audio_l          => mb_audio_l,
         audio_r          => mb_audio_r,

         mode             => open,

         red              => mb_red,
         green            => mb_green,
         blue             => mb_blue,
         hblank           => mb_hblank,
         vblank           => mb_vblank,
         hsync            => mb_hsync,
         vsync            => mb_vsync,
         field            => open,

         vram_din         => mb_vram_din,
         vram_addr        => mb_vram_addr,

         rom_map          => mb_rom_map,
         ram64k           => '0',
         mem_addr         => mb_mem_addr,
         mem_rd           => mb_mem_rd,
         mem_wr           => mb_mem_wr,
         romen            => mb_romen,

         phi_n            => open,
         phi_en_n         => open,
         phi_en_p         => open,
         cpu_addr         => mb_cpu_addr,
         cpu_dout         => mb_cpu_dout,
         cpu_din          => mb_cpu_din,
         iorq             => mb_iorq,   -- CPC4MEGA65 M2: necesarios para decodificar el FDC
         mreq             => open,
         rd               => mb_rd,
         wr               => mb_wr,
         m1               => open,
         ga_ready         => open,
         irq              => '0',
         nmi              => '0',
         cursor           => open
      ); -- i_amstrad_motherboard

   ----------------------------------------------------------------------------------------------
   -- CPC4MEGA65: teclado MEGA65-nativo (matriz real del CPC, ver keyboard.vhd y
   -- doc/m2m/exceptions.md)
   ----------------------------------------------------------------------------------------------

   ----------------------------------------------------------------------------------------------
   -- CPC4MEGA65 M3: joysticks
   --
   -- El framework los entrega en ACTIVO BAJO y ya debotados e intercambiados si toca (el
   -- intercambio de puertos lo hace M2M/vhdl/framework.vhd con su propio "debouncer" y la
   -- senal flip_joys_i, alimentada desde el menu - aqui no hay que hacer nada para eso).
   --
   -- El orden de bits es el de la matriz del CPC, sacado de rtl/hid.sv:47-48: alli el core
   -- original reordena el bus de joystick de MiSTer con
   -- "{joystick[6:4], joystick[0], joystick[1], joystick[2], joystick[3]}", que en el bus de
   -- MiSTer ([0]=Derecha [1]=Izquierda [2]=Abajo [3]=Arriba) equivale a
   -- 0=Arriba 1=Abajo 2=Izquierda 3=Derecha 4=Fire1 5=Fire2 6=Fire3. Como aqui partimos de
   -- senales con nombre y no de ese bus, se escribe directamente en el orden del CPC.
   --
   -- Fire2 y Fire3 se dejan a '0' a proposito (decision del usuario, 2026-09-07): el puerto de
   -- joystick del MEGA65 solo expone un boton, y sacar un segundo obligaria a interpretar las
   -- lineas POT, que depende del adaptador concreto. La mayoria de juegos del CPC usan solo
   -- Fire1; si aparece alguno que necesite Fire2 se revisita con ese caso concreto delante.
   ----------------------------------------------------------------------------------------------

   joy1_cpc <= "00" &                    -- Fire3, Fire2: sin mapear
               (not joy_1_fire_n_i)  &   -- Fire1
               (not joy_1_right_n_i) &
               (not joy_1_left_n_i)  &
               (not joy_1_down_n_i)  &
               (not joy_1_up_n_i);

   joy2_cpc <= "00" &
               (not joy_2_fire_n_i)  &
               (not joy_2_right_n_i) &
               (not joy_2_left_n_i)  &
               (not joy_2_down_n_i)  &
               (not joy_2_up_n_i);

   i_keyboard : entity work.keyboard
      port map (
         clk_main_i           => clk_main_i,

         key_num_i            => kb_key_num_i,
         key_pressed_n_i      => kb_key_pressed_n_i,

         cpc_row_i            => mb_kbd_row,
         cpc_col_o            => mb_kbd_col,

         joy1_i               => joy1_cpc,
         joy2_i               => joy2_cpc
      ); -- i_keyboard

   ----------------------------------------------------------------------------------------------
   -- CPC4MEGA65 M2: controlador de disquete uPD765
   ----------------------------------------------------------------------------------------------

   -- El u765 tiene exactamente dos unidades cableadas (sd_rd/sd_wr/ready/motor son de 2 bits).
   -- Si alguien cambia C_VDNUM en globals.vhd, que falle aqui y no de forma silenciosa.
   assert G_VDNUM = 2
      report "CPC4MEGA65: el u765 modela exactamente 2 unidades; C_VDNUM debe ser 2"
      severity failure;

   -- Decodificado de bus (Amstrad.sv:732, 959-960)
   io_rd    <= mb_rd and mb_iorq;
   io_wr    <= mb_wr and mb_iorq;
   fdc_sel  <= mb_cpu_addr(10) & mb_cpu_addr(8) & mb_cpu_addr(7) & mb_cpu_addr(0);
   -- En el original: u765_sel = (fdc_sel[3:1] == 'b010) & ~status[17], donde status[17] es la
   -- opcion de OSD "desactivar el FDC" (para software que se confunde si detecta disquetera).
   -- No exponemos esa opcion en M2, asi que el termino se fija a "activo".
   u765_sel <= '1' when fdc_sel(3 downto 1) = "010" else '0';

   -- Latch del motor: escritura de E/S a &FA7E, bit 0 (Amstrad.sv:735-743). Ambas unidades
   -- comparten el mismo motor, igual que en el CPC real (motor({motor,motor}), Amstrad.sv:763).
   process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         io_wr_d <= io_wr;
         if io_wr_d = '0' and io_wr = '1' and fdc_sel(3 downto 1) = "000" then
            u765_motor <= mb_cpu_dout(0);
         end if;
      end if;
   end process;

   floppy_scan_done_o  <= floppy_scan_done;

   -- M4028: ver el comentario en las declaraciones.
   tinfo_proc : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         tinfo_flush_r <= '0';            -- pulso de un ciclo
         scan_done_d   <= floppy_scan_done;

         -- Al terminar el recorrido: invalidar la cache, inyectar el montaje falso, y armar
         -- la cuenta atras de 3 s para fotografiar el estado ya asentado.
         if floppy_scan_done = '1' and scan_done_d = '0' then
            tinfo_flush_r <= '1';         -- imagen nueva: que el u765 relea las cabeceras
            remount       <= '1';         -- M4030: montaje falso (EXPERIMENTO)
            remount_cnt   <= C_REMOUNT_CYC;
            tlm_dly_cnt   <= C_TLM_DELAY;
            scan_done_dly <= '0';
         else
            if remount_cnt /= 0 then
               remount_cnt <= remount_cnt - 1;
            else
               remount <= '0';
            end if;

            if tlm_dly_cnt /= 0 then
               tlm_dly_cnt <= tlm_dly_cnt - 1;
            elsif floppy_scan_done = '1' then
               scan_done_dly <= '1';      -- 3 s despues: ya se puede fotografiar
            else
               scan_done_dly <= '0';
            end if;
         end if;
      end if;
   end process tinfo_proc;
   floppy_fmt_done_o    <= floppy_fmt_done;      -- M4027
   floppy_fmt_refused_o <= floppy_fmt_refused;

   -- M4019: los puertos se alimentan de las senales internas (ver la declaracion).
   floppy_is_hd_o      <= floppy_is_hd;
   floppy_bad_tracks_o <= floppy_bad_trk;
   floppy_pos_code_o   <= floppy_pos_code;
   floppy_id_is_cpc_o  <= floppy_id_cpc;

   -- M4030: el pulso se inyecta SOLO en la unidad destino de la disquetera fisica. Y durante
   -- el pulso hay que presentar NUESTRO tamano, porque u765 captura img_size en ese mismo
   -- flanco: es lo que le hace reconstruir la tabla con 40 pistas de 4864 bytes.
   u765_img_mounted(0) <= main_img_mounted_i(0) or (remount and not floppy_tgt_b_i);
   u765_img_mounted(1) <= main_img_mounted_i(1) or (remount and     floppy_tgt_b_i);
   u765_img_size       <= std_logic_vector(to_unsigned(C_IMG_SIZE, 32)) when remount = '1'
                          else main_img_size_i;

   floppy_tlm_flags <= "000" & dpll_en_i & floppy_scan_done & floppy_density_i &
                       floppy_is_hd & floppy_id_cpc;

   -- M4020: ver el comentario largo en las declaraciones.
   --
   -- La peticion se mantiene hasta el acuse, que es el protocolo de vdrives (nivel sostenido,
   -- no pulso), y se hace UNA sola vez por recorrido: dump_done lo impide hasta el siguiente
   -- start. Va a la unidad que sea destino de la disquetera fisica, que es la que tiene la
   -- imagen que queremos volcar.
   dump_sd_lba <= std_logic_vector(to_unsigned(C_DUMP_LBA, 32)) when dump_req = '1'
                  else u765_sd_lba;
   dump_sd_wr(0) <= u765_sd_wr(0) or (dump_req and not floppy_tgt_b_i);
   dump_sd_wr(1) <= u765_sd_wr(1) or (dump_req and     floppy_tgt_b_i);

   -- M4033: mapa de pistas que el CPC ha escrito. Se pone a cero al empezar cada lectura
   -- fisica, que es el momento en que la imagen y el disquete vuelven a ser iguales.
   dirty_proc : process (clk_main_i)
      variable wr_v : std_logic;
   begin
      if rising_edge(clk_main_i) then
         if floppy_tgt_b_i = '0' then
            wr_v := u765_sd_wr(0);
         else
            wr_v := u765_sd_wr(1);
         end if;
         dirty_wr_d <= wr_v;

         -- M4035: CAMBIO DE DISQUETE. Primer uso de f_diskchanged_i, que lleva cableado desde
         -- M4A sin gastarse. Si se saca el disquete con pistas pendientes y se mete otro,
         -- escribir esas pistas en el disco nuevo lo destrozaria: eran para un disco que ya no
         -- esta.
         --
         -- HASTA DONDE LLEGA ESTA PROTECCION, que es menos de lo que parece: la linea /DSKCHG
         -- solo la conduce la mecanica MIENTRAS ESTA SELECCIONADA, y nosotros solo la
         -- seleccionamos durante una operacion. Entre operaciones no vemos nada. Encima, el
         -- recalibrado con el que empieza cada operacion da un paso, y un paso con disco dentro
         -- es justo lo que BORRA /DSKCHG, asi que mirarla despues del recalibrado tampoco
         -- serviria. O sea que esto caza que saquen el disquete EN MEDIO de una reescritura, y
         -- nada mas.
         --
         -- Lo que de verdad protege es que la ventana sea corta (1 s de silencio y a escribir)
         -- y que el LED este AMARILLO mientras quede algo pendiente. Ningun temporizador puede
         -- garantizar que no saquen el disco; una senal de 'todavia no' si.
         if floppy_ready = '0' then
            dchg_d <= '1';       -- sin seleccion la linea no significa nada
         else
            dchg_d <= f_diskchanged_i;
         end if;

         if floppy_ready = '1' and f_diskchanged_i = '0' and dchg_d = '1' then
            dirty_map   <= (others => '0');
            dirty_state <= 0;
         elsif copy_wrote = '1' and unsigned(copy_wrote_trk) < 40 then
            -- Pista ya grabada en el disquete: deja de estar pendiente.
            dirty_map(to_integer(unsigned(copy_wrote_trk))) <= '0';
         elsif floppy_dsk_start = '1' then
            -- El volcado de telemetria se escribe al FINAL de un recorrido, asi que si aqui
            -- solo se borrara, el mapa que se publica seria siempre cero. Se fotografia antes
            -- de borrar: lo que se publica es 'lo que el CPC escribio entre la lectura
            -- anterior y esta'. Para verlo: leer el disco, guardar algo desde el CPC, y leer
            -- otra vez; el segundo volcado lleva la foto.
            dirty_snap  <= dirty_map;
            dirty_map   <= (others => '0');
            dirty_state <= 0;
         else
            case dirty_state is

               when 0 =>
                  -- Flanco de subida de la peticion: el protocolo de vdrives sostiene el nivel
                  -- hasta el acuse, asi que sin flanco se contaria la misma escritura mil veces.
                  if wr_v = '1' and dirty_wr_d = '0' then
                     dirty_addr  <= shift_left(unsigned(u765_sd_lba), 9);
                     dirty_last  <= shift_left(unsigned(u765_sd_lba), 9) + 511;
                     dirty_lim   <= to_unsigned(256 + C_DIRTY_TRKSZ, 32);
                     dirty_trk   <= 0;
                     dirty_state <= 1;
                  end if;

               when 1 =>
                  if dirty_addr < dirty_lim then
                     if dirty_trk < 40 then
                        dirty_map(dirty_trk) <= '1';
                     end if;
                     -- El bloque puede acabar dentro de la pista siguiente.
                     if dirty_last >= dirty_lim and dirty_trk < 39 then
                        dirty_map(dirty_trk + 1) <= '1';
                     end if;
                     dirty_state <= 0;
                  elsif dirty_trk = 63 then
                     dirty_state <= 0;        -- fuera de la imagen: no es de ninguna pista
                  else
                     dirty_lim <= dirty_lim + C_DIRTY_TRKSZ;
                     dirty_trk <= dirty_trk + 1;
                  end if;

            end case;
         end if;
      end if;
   end process dirty_proc;

   dump_proc : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         dump_scan_d <= scan_done_dly;

         -- M4031: recordar si la unidad ha llegado a montarse de verdad alguna vez
         for i in 0 to 1 loop
            if main_img_mounted_i(i) = '1' and main_img_size_i /= x"00000000" then
               img_ever_mnt(i) <= '1';
            end if;
         end loop;

         if floppy_dsk_start = '1' then
            dump_done  <= '0';                   -- recorrido nuevo, volcado nuevo
            dump_req   <= '0';
            dump_tmo   <= 0;
            read_armed <= '1';                   -- M4031: venimos de una LECTURA
         elsif scan_done_dly = '1' and dump_scan_d = '0' and dump_done = '0'
               and read_armed = '1'
               and ((floppy_tgt_b_i = '0' and img_ever_mnt(0) = '1') or
                    (floppy_tgt_b_i = '1' and img_ever_mnt(1) = '1')) then
            dump_req  <= '1';
            dump_done <= '1';
            dump_tmo  <= C_DUMP_TMO;
         elsif dump_req = '1' then
            if main_sd_ack = '1' then
               dump_req <= '0';                  -- atendida: soltar el nivel
            elsif dump_tmo /= 0 then
               dump_tmo <= dump_tmo - 1;
            else
               -- Tiempo de guarda: si el firmware no atendiera la peticion, el nivel NO se
               -- puede quedar colgado - sd_wr alto indefinidamente bloquearia la unidad.
               dump_req <= '0';
            end if;
         end if;
      end if;
   end process dump_proc;

   -- "Hay disco dentro": se muestrea el tamano de la imagen en el flanco de montaje
   -- (Amstrad.sv:748-750). img_size = 0 significa "expulsar", no "imagen vacia".
   process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         for i in 0 to 1 loop
            if u765_img_mounted(i) = '1' then
               if u765_img_size = x"00000000" then
                  u765_ready(i) <= '0';
               else
                  u765_ready(i) <= '1';
               end if;
            end if;
         end loop;
      end if;
   end process;

   -- CPC4MEGA65 M2 (M2002): LED de la placa. El motor es literalmente lo que enciende el LED
   -- en un CPC real, asi que es la senal honesta - y ademas cubre las dos unidades de una vez,
   -- porque comparten motor igual que en la maquina original.
   main_drive_active_o <= u765_motor;

   -- "Hay una transferencia de bloque en marcha": desde que el u765 pide (sd_rd/sd_wr, niveles
   -- mantenidos hasta el acuse) hasta que QNICE termina de bombear los bytes (sd_ack alto).
   fdc_busy <= '1' when (u765_sd_rd /= "00" or u765_sd_wr /= "00" or main_sd_ack = '1')
               else '0';

   fdc_motor_snd : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         -- Oscilador libre: solo depende del motor, nunca de la rafaga.
         if u765_motor = '0' then
            fdc_snd_cnt  <= 0;
            fdc_snd_tone <= '0';
         elsif fdc_snd_cnt = C_FDC_SND_HALF_PERIOD - 1 then
            fdc_snd_cnt  <= 0;
            fdc_snd_tone <= not fdc_snd_tone;
         else
            fdc_snd_cnt <= fdc_snd_cnt + 1;
         end if;

         -- Retencion: cualquier transferencia recarga los 20 ms. Esto es lo que hace que un
         -- acceso de medio milisegundo se oiga.
         if fdc_busy = '1' then
            fdc_snd_hold <= C_FDC_SND_HOLD;
         elsif fdc_snd_hold /= 0 then
            fdc_snd_hold <= fdc_snd_hold - 1;
         end if;
      end if;
   end process fdc_motor_snd;

   -- CPC4MEGA65 (M4012): el zumbido suena SOLO mientras hay transferencia real de bloques.
   -- Antes sonaba tambien con el motor girando en vacio, y AMSDOS lo deja girando varios
   -- segundos tras el acceso (su timeout), asi que el ruido se alargaba mucho mas que la
   -- lectura y molestaba. Este es el trozo corto que el usuario si queria conservar.
   fdc_snd_audio <= to_signed(C_FDC_SND_AMP_ACTIVE, 16) when (fdc_snd_tone = '1' and fdc_snd_hold /= 0) else
                    to_signed(0, 16);

   i_u765 : entity work.u765
      port map (
         clk_sys      => clk_main_i,
         ce           => cen_u765,
         -- CPC4MEGA65: puerto anadido al u765 (ver doc/m2m/exceptions.md). Solo alimenta el
         -- puerto A de los dos buffers internos, que es el lado que el firmware QNICE recorre
         -- byte a byte con lectura combinacional de sd_buff_din.
         clk_sd       => qnice_clk_i,
         sd_sel_o     => u765_sd_sel,
         sd_sel_sd_i  => qnice_sd_sel,
         reset        => reset_soft_i or reset_hard_i,

         ready        => u765_ready,
         motor        => u765_motor & u765_motor,
         available    => "11",             -- ambas unidades presentes (Amstrad.sv:764)
         -- "fast" = busqueda y lectura de sector inmediatas. El original lo saca de una opcion
         -- de OSD (status[16]); aqui se deja en modo autentico. Candidato a opcion de menu si
         -- la carga real resulta incomoda, pero primero hay que ver el comportamiento fiel.
         fast         => '0',

         a0           => fdc_sel(0),
         nRD          => not (u765_sel and io_rd),
         nWR          => not (u765_sel and io_wr),
         din          => mb_cpu_dout,
         dout         => u765_dout,

         -- Lado "SD config": dominio del core, vdrives ya lo entrega sincronizado
         tinfo_flush  => tinfo_flush_r,
         dbg_state    => u765_dbg,
         img_mounted  => u765_img_mounted,
         img_wp       => main_img_readonly_i,
         img_size     => u765_img_size,

         -- Lado "SD block": generado en dominio core, sincronizado justo debajo
         sd_lba       => u765_sd_lba,
         sd_rd        => u765_sd_rd,
         sd_wr        => u765_sd_wr,
         -- CPC4MEGA65: el acuse va por DOS puertos, uno por dominio (ver comentario en el
         -- propio u765.sv). El de los buffers se queda en dominio QNICE, que es donde nace y
         -- donde esta el puerto A; el de la maquina de estados llega sincronizado al core.
         --
         -- La cadena de 6 etapas que el u765 tiene para "ack" NO sirve como sincronizador de
         -- dominio: alimentandola directamente desde qnice_clk, Vivado la sintetizo como SRL
         -- (un desplazador en LUT, no FFs adyacentes) y reporto el cruce como violacion
         -- (WNS -4.98 ns, primera build de M2). Con el XPM delante pasa a ser main_clk ->
         -- main_clk y hace lo que siempre hizo: filtrar flancos.
         sd_ack       => qnice_sd_ack_i,
         sd_ack_sys   => main_sd_ack,

         -- Lado "SD byte": dominio de QNICE de punta a punta gracias al clk_sd de arriba
         sd_buff_addr => qnice_sd_buff_addr_i,
         sd_buff_dout => qnice_sd_buff_dout_i,
         sd_buff_din  => qnice_sd_buff_din_o,
         sd_buff_wr   => qnice_sd_buff_wr_i
      ); -- i_u765

   ----------------------------------------------------------------------------------------------
   -- CPC4MEGA65 M2: cruces de dominio del lado SD del u765
   --
   -- TODOS los cruces core<->QNICE del FDC pasan por aqui, con macros XPM, y ninguno queda
   -- dentro del u765. La razon es concreta y medida, no estilistica: la primera build de M2
   -- llevaba los sincronizadores escritos a mano en RTL plano dentro de u765.sv, y Vivado
   -- reporto WNS = -4.98 ns con 8 endpoints fallando - los cuatro caminos grandes eran
   -- exactamente esos sincronizadores. Un par de FFs escritos a mano no lleva restricciones
   -- asociadas, asi que el analizador trata el cruce como si fuera sincrono y exige cumplir
   -- una relacion de fase entre main_clk (64MHz) y qnice_clk (50MHz) que no existe. Los macros
   -- xpm_cdc_* traen sus propias restricciones (set_max_delay -datapath_only sobre el primer
   -- FF de la cadena), que es justo lo que faltaba. En aquella build el unico cruce que NO
   -- aparecio en la lista de violaciones fue el que ya usaba XPM.
   ----------------------------------------------------------------------------------------------

   -- core -> QNICE. AExp y QL4M65 dejan cruzar sd_lba/sd_rd/sd_wr sin sincronizar (sd_card.sv
   -- las genera en su dominio clk_spi y entran directas a vdrives) y funciona porque son
   -- NIVELES mantenidos miles de ciclos que el firmware sondea; aqui se sincronizan igualmente.
   -- Coherencia entre bits: sd_lba se fija en el MISMO ciclo que sd_rd/sd_wr (u765.sv:246-265),
   -- asi que el desfase entre bits sincronizados es como mucho 1 ciclo de QNICE - y el firmware
   -- lee sd_lba decenas de ciclos despues de haber detectado sd_rd=1, no en el mismo acceso.
   -- Los 3 bits de sd_sel (destino de las escrituras del puerto A de los buffers del u765)
   -- viajan en la misma instancia: van en el mismo sentido y con el mismo argumento de
   -- estabilidad (fijados antes de levantar sd_rd, sin cambiar hasta despues del ack).
   i_cdc_u765_main2qnice : xpm_cdc_array_single
      generic map (
         WIDTH => 39
      )
      port map (
         src_clk               => clk_main_i,
         src_in(1 downto 0)    => u765_sd_rd,
         src_in(3 downto 2)    => dump_sd_wr,
         src_in(35 downto 4)   => dump_sd_lba,
         src_in(38 downto 36)  => u765_sd_sel,
         dest_clk              => qnice_clk_i,
         dest_out(1 downto 0)  => qnice_sd_rd_o,
         dest_out(3 downto 2)  => qnice_sd_wr_o,
         dest_out(35 downto 4) => qnice_sd_lba_o,
         dest_out(38 downto 36) => qnice_sd_sel
      ); -- i_cdc_u765_main2qnice

   -- QNICE -> core: el acuse de vdrives. Un solo bit, nivel mantenido durante toda la
   -- transferencia, asi que xpm_cdc_single es exactamente la primitiva adecuada.
   ----------------------------------------------------------------------------------------------
   -- CPC4MEGA65 M4A: disquetera fisica interna del MEGA65
   --
   -- Todavia no lee datos: solo mueve el hierro (motor, seleccion, recalibrado a pista 0) y
   -- detecta el pulso de indice, para confirmar que los 14 pines del interfaz Shugart y sus
   -- polaridades son lo que creemos antes de escribir el separador MFM (fase B).
   -- Ver .research/PORTING-PLAN.md seccion 11.
   ----------------------------------------------------------------------------------------------

   i_floppy_phys : entity work.floppy_phys
      generic map (
         G_CLK_HZ         => G_CLK_HZ
      )
      port map (
         clk_i            => clk_main_i,
         rst_i            => reset_hard_i,

         enable_i         => floppy_enable_i,
         density_i        => floppy_density_i,
         seek_track_i     => floppy_seek_track,
         seek_start_i     => floppy_seek_start,

         busy_o           => floppy_busy_o,
         ready_o          => floppy_ready,
         error_o          => floppy_error_o,
         index_pulse_o    => floppy_index_pulse,
         disk_in_o        => floppy_disk_in_o,
         write_prot_o     => floppy_wprot,
         track_o          => open,

         f_density_o      => f_density_o,
         f_motora_o       => f_motora_o,
         f_motorb_o       => f_motorb_o,
         f_selecta_o      => f_selecta_o,
         f_selectb_o      => f_selectb_o,
         f_side1_o        => f_side1_o,
         f_stepdir_o      => f_stepdir_o,
         f_step_o         => f_step_o,
         -- CPC4MEGA65 M4C1: la escritura la gobierna AHORA floppy_write, no este modulo. Si se
         -- dejaran conectados aqui habria dos fuentes sobre el mismo pin.
         f_wdata_o        => open,
         f_wgate_o        => open,
         f_index_i        => f_index_i,
         f_track0_i       => f_track0_i,
         f_writeprotect_i => f_writeprotect_i,
         f_diskchanged_i  => f_diskchanged_i,
         f_rdata_i        => f_rdata_i
      ); -- i_floppy_phys

   -- Conmutador para hacer visible el indice en el LED (ver el comentario del puerto)
   floppy_blink_proc : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         if floppy_enable_i = '0' then
            floppy_index_blink <= '0';
         elsif floppy_index_pulse = '1' then
            floppy_index_blink <= not floppy_index_blink;
         end if;
      end if;
   end process floppy_blink_proc;

   floppy_index_blink_o <= floppy_index_blink;
   floppy_ready_o       <= floppy_ready;
   -- M4027: el secuenciador corre en LOS DOS modos; fmt_mode_i decide que hace en cada pista.
   floppy_scan_enable   <= floppy_enable_i;

   ----------------------------------------------------------------------------------------------
   -- CPC4MEGA65 M4B: separador de datos MFM y lectura de campos de ID
   --
   -- Cuenta cuantos sectores validos hay en una vuelta de la pista 0. Con formato DATA del CPC
   -- deberian ser 9. Que el CRC cuadre es la prueba de que la decodificacion es exacta bit a
   -- bit: un solo bit mal y el CRC no da cero.
   ----------------------------------------------------------------------------------------------

   i_floppy_mfm : entity work.floppy_mfm
      generic map (
         G_CLK_HZ       => G_CLK_HZ
      )
      port map (
         clk_i          => clk_main_i,
         rst_i          => reset_hard_i,

         enable_i       => floppy_enable_i,
         ready_i        => floppy_ready,
         index_i        => floppy_index_pulse,
         restart_i      => floppy_mfm_restart,
         expect_i       => floppy_expect,
         dpll_en_i      => dpll_en_i,
         f_rdata_i      => f_rdata_i,

         done_o         => floppy_mfm_done,
         sector_count_o => floppy_sect_cnt,
         is_hd_o        => floppy_is_hd,
         id_track_o     => floppy_id_track,
         id_side_o      => floppy_id_side,
         id_sector_o    => floppy_id_sector,
         id_size_o      => floppy_id_size,

         data_byte_o    => floppy_data_byte,
         data_valid_o   => floppy_data_valid,
         data_offset_o  => floppy_data_offset,
         sec_slot_o     => floppy_sec_slot,
         sec_ok_o       => floppy_sec_ok,

         tlm_seen_o     => floppy_tlm_seen,
         tlm_revs_o     => floppy_tlm_revs,
         tlm_idcrc_o    => floppy_tlm_idcrc,
         tlm_dtcrc_o    => floppy_tlm_dtcrc,
         tlm_pllcells_o => floppy_tlm_pll,
         tlm_runts_o    => floppy_tlm_runts
      ); -- i_floppy_mfm

   ----------------------------------------------------------------------------------------------
   -- CPC4MEGA65 M4B2b-ii: construccion de la imagen .DSK en el buffer
   ----------------------------------------------------------------------------------------------

   ----------------------------------------------------------------------------------------------
   -- CPC4MEGA65 M4034: copiar un .dsk al disquete fisico
   ----------------------------------------------------------------------------------------------

   -- Origen de la copia: la unidad que NO sea la disquetera fisica. Si la interna esta puesta
   -- de A:, se copia desde B:, porque si no el origen y el destino serian el mismo sitio.
   -- M4035: DE DONDE SALE LA IMAGEN, que es lo unico que distingue los dos modos aparte de
   -- que pistas se visitan.
   --   copia         : la unidad que NO es la disquetera fisica (si la interna esta de A:, se
   --                   copia desde B:; si no, origen y destino serian el mismo sitio).
   --   reescritura   : la unidad que SI lo es, que es donde esta la imagen que leimos del
   --                   disquete y que el CPC ha ido modificando.
   copy_buf_q <= floppy_buf_qa_i when (wb_mode = '1') = (floppy_tgt_b_i = '0')
                 else floppy_buf_qb_i;

   -- Reescritura en marcha: la pide el boton del menu o el disparo automatico.
   wb_active <= floppy_wb_en_i or wb_auto_req;
   wb_mode   <= wb_active;                 -- copia y reescritura no se solapan nunca
   -- M4035: el modulo trabaja en los DOS modos; wb_mode dice en cual.
   floppy_cp_on  <= floppy_copy_en_i or wb_active;
   floppy_src_en <= floppy_cp_on;

   floppy_wb_active_o  <= wb_active;
   floppy_wb_pending_o <= '1' when dirty_map /= (dirty_map'range => '0') else '0';

   -- Disparo automatico. Ver el comentario largo de las declaraciones: la cuenta se recarga con
   -- CADA escritura, asi que mide silencio del controlador, no antiguedad del dato.
   wb_auto_proc : process (clk_main_i)
      variable pend_v : std_logic;
   begin
      if rising_edge(clk_main_i) then
         -- Solo cuenta lo que se PUEDE escribir. Una pista sucia que no se leyo entera se queda
         -- pendiente para siempre a proposito -no tenemos su contenido verdadero- y si entrara
         -- aqui haria que el automatico recorriera el disco cada segundo sin poder arreglarlo.
         if (dirty_map and ok_map) /= (dirty_map'range => '0') then
            pend_v := '1';
         else
            pend_v := '0';
         end if;

         -- M4036: los contadores de medida se ponen a cero al empezar una LECTURA, que es el
         -- instante de referencia de todo lo demas. Van AQUI y no en dirty_proc: dos procesos
         -- escribiendo la misma senal son dos controladores, y Vivado lo rechaza.
         if floppy_dsk_start = '1' then
               wb_gap_max_s <= wb_gap_max;   -- M4037: foto antes de borrar
               wb_fires_s   <= wb_fires;
            wb_gap_max <= (others => '0');
            wb_fires   <= (others => '0');
            wb_gap_ms  <= (others => '0');
         end if;

         if wb_ms_pre = C_MS_CYC - 1 then
            wb_ms_pre <= 0;
            -- M4036: reloj de milisegundos del hueco en curso
            if wb_gap_ms /= x"FFFF" then
               wb_gap_ms <= wb_gap_ms + 1;
            end if;
            if wb_cnt /= 0 then
               wb_cnt <= wb_cnt - 1;
            end if;
         else
            wb_ms_pre <= wb_ms_pre + 1;
         end if;

         -- Cada escritura del u765 reinicia la espera.
         if u765_sd_wr /= "00" and wr_any_d = '0' then
            wb_cnt    <= C_WB_IDLE_MS;
            -- M4036: cerrar el hueco que acaba de terminar y quedarse con el mayor
            if wb_gap_ms > wb_gap_max then
               wb_gap_max <= wb_gap_ms;
            end if;
            wb_gap_ms <= (others => '0');
            wb_ms_pre <= 0;
         end if;

         if floppy_wb_auto_i = '0' or floppy_copy_en_i = '1' or floppy_wb_en_i = '1' then
            -- Con el automatico apagado, o mientras haya una operacion manual en marcha, este
            -- disparo no existe.
            wb_auto_req <= '0';
         elsif wb_auto_req = '1' then
            -- M4037: se suelta cuando la OPERACION termina, no cuando el mapa se vacia.
            --
            -- Mirar el mapa aqui era un fallo grave y propio: desde M4036 el bit de sucio se
            -- borra al EMPEZAR a grabar cada pista, para no comerse una escritura que llegue
            -- durante los 200 ms que dura. Con una sola pista sucia eso vaciaba el mapa a los
            -- pocos microsegundos de abrir WGATE, este permiso caia, con el caia
            -- main_floppy_fmt_en, y con el el enable_i del propio escritor: la puerta se cerraba
            -- a mitad de pista. En hardware se vio como 22 ciclos de WGATE EN TOTAL (0,34 us)
            -- repartidos en 5 arranques, o sea no se grabo nada.
            --
            -- El mapa es la condicion de DISPARO; la de MANTENIMIENTO es que la operacion siga
            -- viva. Confundirlas quita el permiso por debajo del que esta trabajando.
            if copy_done = '1' or copy_refused = '1' then
               wb_auto_req <= '0';
            end if;
         elsif pend_v = '1' and wb_cnt = 0 then
            wb_auto_req <= '1';
            wb_fires    <= wb_fires + 1;    -- M4036
         end if;
      end if;
   end process wb_auto_proc;

   -- El bus de direcciones del buffer es uno solo. floppy_dsk lo usa para ESCRIBIR mientras se
   -- lee el disquete; el copiador lo usa para LEER mientras se escribe. Nunca a la vez: en modo
   -- copia floppy_scan va en modo formateo y no pulsa dsk_start.
   floppy_buf_addr_o <= copy_buf_addr when (floppy_copy_en_i or wb_active) = '1'
                        else dsk_buf_addr;

   -- M4034: flancos de escritura del u765, sin filtrar. Ver la declaracion.
   wr_edge_proc : process (clk_main_i)
      variable any_v : std_logic;
   begin
      if rising_edge(clk_main_i) then
         any_v := u765_sd_wr(0) or u765_sd_wr(1);
         wr_any_d <= any_v;
         if floppy_dsk_start = '1' then
               wr_edges_s <= wr_edges;       -- M4037: foto antes de borrar
            wr_edges <= (others => '0');
         elsif any_v = '1' and wr_any_d = '0' and wr_edges /= x"FFFF" then
            wr_edges <= wr_edges + 1;
         end if;
      end if;
   end process wr_edge_proc;

   i_floppy_copy : entity work.floppy_copy
      port map (
         clk_i       => clk_main_i,
         rst_i       => reset_hard_i,

         enable_i    => floppy_cp_on,      -- M4035 fix: copia O reescritura

         mode_wb_i   => wb_mode,
         dirty_i     => dirty_map,
         ok_i        => ok_map,
         skip_o      => wb_skip,
         wrote_o     => copy_wrote,
         wrote_trk_o => copy_wrote_trk,
         tlm_blocked_o => copy_blocked,

         buf_addr_o  => copy_buf_addr,
         buf_q_i     => copy_buf_q,

         hold_o      => copy_hold,
         trk_last_o  => copy_trk_last,
         track_i     => floppy_cur_track,
         scan_done_i => floppy_scan_done,

         w_sec_i     => wr_sec,
         w_off_i     => wr_off,
         w_nsec_o    => copy_w_nsec,
         w_id_c_o    => copy_w_id_c,
         w_id_h_o    => copy_w_id_h,
         w_id_r_o    => copy_w_id_r,
         w_id_n_o    => copy_w_id_n,
         w_data_o    => copy_w_data,

         busy_o      => copy_busy,
         done_o      => copy_done,
         refused_o   => copy_refused,
         err_code_o  => copy_err,
         tlm_trk_o   => copy_tlm_trk
      ); -- i_floppy_copy

   -- La sujecion solo existe en modo copia. En un formateo normal no hay cabecera que leer y
   -- floppy_scan tiene que arrancar el escritor en cuanto la cabeza este colocada.
   fmt_hold      <= copy_hold     when (floppy_copy_en_i or wb_active) = '1' else '0';
   fmt_skip      <= wb_skip      when wb_active = '1' else '0';
   scan_trk_last <= copy_trk_last when (floppy_copy_en_i or wb_active) = '1' else
                    std_logic_vector(to_unsigned(39, 7));

   -- Media vuelta = 6,4 M ciclos. Una pista entera son 12,8 M.
   floppy_wrote_ok_o <= '1' when unsigned(fmt_wgmax) > to_unsigned(6_400_000, 32) else '0';

   floppy_copy_busy_o    <= copy_busy;
   floppy_copy_done_o    <= copy_done;
   floppy_copy_refused_o <= copy_refused;

   i_floppy_dsk : entity work.floppy_dsk
      generic map (
         G_CLK_HZ      => G_CLK_HZ
      )
      port map (
         clk_i         => clk_main_i,
         rst_i         => reset_hard_i,

         start_i       => floppy_dsk_start,
         track_i       => floppy_cur_track,
         track_done_i  => floppy_track_done,
         done_track_i  => floppy_done_track,
         sect_count_i  => floppy_sect_cnt,

         data_byte_i   => floppy_data_byte,
         data_valid_i  => floppy_data_valid,
         data_offset_i => floppy_data_offset,
         sec_slot_i    => floppy_sec_slot,
         sec_ok_i      => floppy_sec_ok,
         id_track_i    => floppy_id_track,
         id_side_i     => floppy_id_side,
         id_sector_i   => floppy_id_sector,
         id_size_i     => floppy_id_size,

         buf_addr_o    => dsk_buf_addr,
         buf_data_o    => floppy_buf_data_o,
         buf_we_o      => floppy_buf_we_o,

         img_size_o    => open,
         busy_o        => open,
         wr_code_o     => floppy_wr_code_o,

         -- M4019 telemetria
         finish_i      => scan_done_dly,
         tlm_seen_i    => floppy_tlm_seen,
         tlm_revs_i    => floppy_tlm_revs,
         tlm_idcrc_i   => floppy_tlm_idcrc,
         tlm_dtcrc_i   => floppy_tlm_dtcrc,
         tlm_badtrk_i  => floppy_bad_trk,
         tlm_poscode_i => floppy_pos_code,
         tlm_flags_i   => floppy_tlm_flags,
         tlm_pllcells_i => floppy_tlm_pll,
         tlm_runts_i    => floppy_tlm_runts,
         tlm_u765_i     => u765_dbg,
         tlm_wgate_i    => floppy_fmt_wgate,
         tlm_wdata_i    => floppy_fmt_wdata,
         tlm_dirty_i    => dirty_snap,          -- M4033
         tlm_wredge_i   => std_logic_vector(wr_edges_s),   -- M4037
         tlm_cperr_i    => copy_err,
         tlm_cptrk_i    => copy_tlm_trk,
         tlm_gapmax_i   => std_logic_vector(wb_gap_max_s),   -- M4037
         tlm_fires_i    => std_logic_vector(wb_fires_s),
         tlm_blk_i      => copy_blocked,
         tlm_abort_i    => fmt_abort,       -- M4038
         tlm_idxend_i   => fmt_idxend,
         tlm_stopst_i   => fmt_stopst,
         tlm_wgmax_i    => fmt_wgmax,
         tlm_idxwr_i    => fmt_idxwr,       -- M4039
         tlm_blind_i    => fmt_blind,
         ok_map_o       => ok_map,          -- M4035
         tlm_starts_i   => floppy_fmt_starts,
         tlm_refus_i    => floppy_fmt_refus
      ); -- i_floppy_dsk

   ----------------------------------------------------------------------------------------------
   -- CPC4MEGA65 M4B2b-i: recorrido del disco entero
   --
   -- Encadena la mecanica y la lectura para comprobar que las 40 pistas se leen igual de bien
   -- que la pista 0. Valida la ultima pieza de hardware sin probar: la busqueda de pista.
   ----------------------------------------------------------------------------------------------

   i_floppy_scan : entity work.floppy_scan
      generic map (
         G_TRACKS      => 40         -- formato DATA del CPC: 40 pistas de una cara
      )
      port map (
         clk_i         => clk_main_i,
         rst_i         => reset_hard_i,

         -- CPC4MEGA65 M4C1: el recorrido NO puede correr mientras se formatea. Los dos mueven
         -- la misma cabeza, y al arrancarlos juntos el escritor formateaba una pista cualquiera
         -- (la que tocara cuando phys diera "ready" entre dos busquedas) en vez de la 0.
         -- Con el formateo activo, floppy_phys recalibra a la pista 0 y se queda ahi, que es
         -- justo donde tiene que escribir.
         enable_i      => floppy_scan_enable,

         phys_ready_i  => floppy_ready,
         phys_error_i  => floppy_error_o,
         seek_track_o  => floppy_seek_track,
         seek_start_o  => floppy_seek_start,

         mfm_restart_o  => floppy_mfm_restart,
         mfm_expect_o   => floppy_expect,
         fmt_mode_i     => floppy_fmt_enable_i,
         fmt_start_o    => floppy_fmt_start,
         fmt_done_i     => floppy_fmt_done,
         fmt_refused_i  => floppy_fmt_refused,
         fmt_hold_i     => fmt_hold,        -- M4034
         fmt_skip_i     => fmt_skip,        -- M4035
         trk_last_i     => scan_trk_last,   -- M4034
         mfm_done_i     => floppy_mfm_done,
         mfm_count_i    => floppy_sect_cnt,
         mfm_id_track_i  => floppy_id_track,
         mfm_id_sector_i => floppy_id_sector,

         scan_done_o   => floppy_scan_done,
         bad_tracks_o  => floppy_bad_trk,
         sect_ref_o    => floppy_sector_count_o,
         cur_track_o   => floppy_cur_track,
         dsk_start_o   => floppy_dsk_start,
         track_done_o  => floppy_track_done,
         done_track_o  => floppy_done_track,
         pos_code_o    => floppy_pos_code,
         id_is_cpc_o   => floppy_id_cpc
      ); -- i_floppy_scan

   ----------------------------------------------------------------------------------------------
   -- CPC4MEGA65 M4C1: formateo de pista
   --
   -- Es lo unico de este proyecto que puede destruir datos. Ver la cabecera de floppy_write.vhd
   -- para las cinco condiciones que tienen que cumplirse antes de que f_wgate_o se active.
   ----------------------------------------------------------------------------------------------

   i_floppy_write : entity work.floppy_write
      generic map (
         G_CLK_HZ   => G_CLK_HZ
      )
      port map (
         clk_i      => clk_main_i,
         rst_i      => reset_hard_i,

         enable_i   => floppy_fmt_enable_i,
         start_i    => floppy_fmt_start,      -- M4027: un pulso por pista, desde floppy_scan
         track_i    => floppy_cur_track,      -- M4027: el numero va al campo de ID
         ready_i    => floppy_ready,
         index_i    => floppy_index_pulse,
         wprot_i    => floppy_wprot,

         busy_o     => floppy_fmt_busy_o,
         done_o     => floppy_fmt_done,
         refused_o  => floppy_fmt_refused,
         wrote_full_o => floppy_fmt_full_o,

         -- M4034: modo origen externo. Con la opcion de copia apagada esto vale '0' y el
         -- modulo formatea exactamente igual que hasta ahora.
         src_en_i   => floppy_src_en,
         src_nsec_i => copy_w_nsec,
         src_id_c_i => copy_w_id_c,
         src_id_h_i => copy_w_id_h,
         src_id_r_i => copy_w_id_r,
         src_id_n_i => copy_w_id_n,
         src_data_i => copy_w_data,
         src_sec_o  => wr_sec,
         src_off_o  => wr_off,

         f_wgate_o  => f_wgate_o,
         f_wdata_o  => f_wdata_o,
         tlm_wgate_o  => floppy_fmt_wgate,
         tlm_wdata_o  => floppy_fmt_wdata,
         tlm_starts_o => floppy_fmt_starts,
         tlm_refus_o  => floppy_fmt_refus,
         tlm_abort_o  => fmt_abort,       -- M4038
         tlm_idxend_o => fmt_idxend,
         tlm_stopst_o => fmt_stopst,
         tlm_wgmax_o  => fmt_wgmax,
         tlm_idxwr_o  => fmt_idxwr,       -- M4039
         tlm_blind_o  => fmt_blind
      ); -- i_floppy_write

   -- Lo que sale al LED durante el recorrido es el estado del contador por pista; al terminar,
   -- lo que interesa es el resultado global (ver mega65.vhd).
   floppy_mfm_done_o <= floppy_mfm_done;

   i_cdc_sd_ack : xpm_cdc_single
      generic map (
         -- SRC_INPUT_REG=1: el ack que llega no es una salida de registro limpia, es el OR de
         -- los dos bits por unidad que hace mega65.vhd (mismo criterio que Amstrad.sv:776,
         -- "sd_ack(|sd_ack)"), o sea combinacional. El registro de entrada del XPM lo limpia.
         SRC_INPUT_REG => 1
      )
      port map (
         src_clk  => qnice_clk_i,
         src_in   => qnice_sd_ack_i,
         dest_clk => clk_main_i,
         dest_out => main_sd_ack
      ); -- i_cdc_sd_ack

end architecture synthesis;
