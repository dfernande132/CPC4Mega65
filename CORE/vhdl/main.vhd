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

entity main is
   generic (
      G_VDNUM                 : natural                     -- amount of virtual drives
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

----------------------------------------------------------------------------------------------
-- CPC4MEGA65 M1B: Amstrad_motherboard (CPU+GA+CRTC+PSG+PPI+MMU reales) y su interfaz externa
----------------------------------------------------------------------------------------------

-- cen_16: equivalente a "ce_16" en Amstrad.sv (Amstrad.sv:119-129) - 16MHz derivados de los
-- 64MHz de clk_main_i por clock-enable (divide por 4), sin PLL adicional. Ritmo del
-- secuenciador S[7:0] del Gate Array - ver PORTING-PLAN.md seccion 4.4.
signal cen_16_div : unsigned(1 downto 0) := (others => '0');
signal cen_16     : std_logic := '0';

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

-- rom_map: mapa de bancos de ROM validos para Amstrad_MMU (solo importa si algo llega a leer
-- ROMbank, lo cual no ocurre en M1 - ver comentario de la seccion de memoria de arriba). Bit0
-- (BASIC banco 0, el que arranca por defecto) marcado por claridad aunque no sea necesario.
signal mb_rom_map : std_logic_vector(255 downto 0) := (0 => '1', others => '0');

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

   ----------------------------------------------------------------------------------------------
   -- CPC4MEGA65 M1B: cen_16 (16MHz desde los 64MHz de clk_main_i, ver Amstrad.sv:119-129)
   ----------------------------------------------------------------------------------------------

   process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         cen_16_div <= cen_16_div + 1;
         if cen_16_div = "00" then
            cen_16 <= '1';
         else
            cen_16 <= '0';
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

   main_rom_os_addr_a    <= mb_cpu_addr(13 downto 0);
   main_rom_basic_addr_a <= mb_cpu_addr(13 downto 0);

   mb_cpu_din <= main_rom_os_q_a    when (mb_romen = '1' and mb_cpu_addr(15) = '0') else
                 main_rom_basic_q_a when (mb_romen = '1' and mb_cpu_addr(15) = '1') else
                 main_ram_q_a       when mb_mem_rd = '1' else
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
   audio_left_o  <= signed((not mb_audio_l(7)) & mb_audio_l(6 downto 0) & x"00");
   audio_right_o <= signed((not mb_audio_r(7)) & mb_audio_r(6 downto 0) & x"00");

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
         iorq             => open,
         mreq             => open,
         rd               => open,
         wr               => open,
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

   i_keyboard : entity work.keyboard
      port map (
         clk_main_i           => clk_main_i,

         key_num_i            => kb_key_num_i,
         key_pressed_n_i      => kb_key_pressed_n_i,

         cpc_row_i            => mb_kbd_row,
         cpc_col_o            => mb_kbd_col
      ); -- i_keyboard

end architecture synthesis;
