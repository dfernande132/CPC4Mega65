----------------------------------------------------------------------------------
-- MiSTer2MEGA65 Framework
--
-- Global constants
--
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library work;
use work.qnice_tools.all;
use work.video_modes_pkg.all;

package globals is

----------------------------------------------------------------------------------------------------------
-- QNICE Firmware
----------------------------------------------------------------------------------------------------------

-- QNICE Firmware: Use the regular QNICE "operating system" called "Monitor" while developing and
-- debugging the firmware/ROM itself. If you are using the M2M ROM (the "Shell") as provided by the
-- framework, then always use the release version of the M2M firmware: QNICE_FIRMWARE_M2M
--
-- Hint: You need to run QNICE/tools/make-toolchain.sh to obtain "monitor.rom" and
-- you need to run CORE/m2m-rom/make_rom.sh to obtain the .rom file
constant QNICE_FIRMWARE_MONITOR   : string  := "../../../M2M/QNICE/monitor/monitor.rom";    -- debug/development
constant QNICE_FIRMWARE_M2M       : string  := "../../../CORE/m2m-rom/m2m-rom.rom";         -- release

-- Select firmware here
constant QNICE_FIRMWARE           : string  := QNICE_FIRMWARE_M2M;

----------------------------------------------------------------------------------------------------------
-- Clock Speed(s)
--
-- Important: Make sure that you use very exact numbers - down to the actual Hertz - because some cores
-- rely on these exact numbers. By default M2M supports one core clock speed. In case you need more,
-- then add all the clocks speeds here by adding more constants.
----------------------------------------------------------------------------------------------------------

-- CPC4MEGA65: clk_sys del core original es 64MHz (rtl/pll/pll_0002.v, wizard Altera PLL v17.0,
-- referencia 50MHz -> 64MHz). Ver core/.research/PORTING-PLAN.md seccion 3.
constant CORE_CLK_SPEED       : natural := 64_000_000;

-- System clock speed (crystal that is driving the FPGA) and QNICE clock speed
-- !!! Do not touch !!!
constant BOARD_CLK_SPEED      : natural := 100_000_000;
constant QNICE_CLK_SPEED      : natural := 50_000_000;   -- a change here has dependencies in qnice_globals.vhd

----------------------------------------------------------------------------------------------------------
-- Video Mode
----------------------------------------------------------------------------------------------------------

-- Rendering constants (in pixels)
--    VGA_*   size of the core's target output post scandoubler
--    If in doubt, use twice the values found in this link:
--    https://mister-devel.github.io/MkDocs_MiSTer/advanced/nativeres/#arcade-core-default-native-resolutions
-- CPC4MEGA65: VGA_DX/VGA_DY son el LIENZO DEL OSM (rejilla de caracteres CHARS_DX x CHARS_DY
-- que el firmware usa para menu/navegador/ayuda), NO el area activa de video que mide el
-- framework. Un mismo global alimenta los DOS pipelines (analogico y digital), asi que no se
-- puede "apuntar" al tamaño analogico sin romper el digital.
--
-- *** VGA_DX ESTA CLAVADO A 720 - NO SUBIRLO ***
-- digital_pipeline.vhd:250 hace  hdmi_shift <= hdmi_video_mode.H_PIXELS - VGA_DX  y lo mete
-- en video_overlay.vhd:28,  vga_cfg_shift_i : in natural.  Con VGA_DX=768 y el modo HDMI
-- 576p (H_PIXELS=720) eso da -48 en un natural: violacion de rango, OSM de HDMI roto. AExp
-- documenta exactamente esta trampa en su propio globals.vhd, y C64MEGA65 llega a 720 por el
-- mismo sitio ("we need to go for 720x540 so that in the 5:4 and 4:3 modes everything looks
-- correctly") aunque su lienzo analogico real sea 768x540.
--
-- Para referencia, el raster REAL de este core (derivado de rtl/crt_filter.v, bloque
-- "blankgen", que es quien genera HBLANK/VBLANK porque usamos sync_filter='1'; sus contadores
-- corren a CE_4 = phi_en_n = 4MHz):
--   - Ancho activo = END_HBORDER(241) - BEGIN_HBORDER(49) = 192 ticks de 4MHz = 48us
--                    -> a 16MHz de video_ce_o = 768 pixeles
--   - Alto activo  = END_VBORDER(37*8+6=302) - BEGIN_VBORDER(4*8-2=30) = 272 lineas
--   => nativo 768x272 (los 640x200 del modo 2 mas ~4 caracteres de borde por lado),
--      lienzo analogico post-scandoubler 768x544.
-- El desajuste entre ese 768 real y el 720 de aqui es el mismo que tiene AExp (su analogico
-- real es ~754x574 y tambien deja VGA_DX en 720): la colocacion del OSM analogico se resuelve
-- en el camino analogico, no tocando esta constante.
--
-- VGA_DY si se ajusta al alto real del lienzo analogico (272*2=544), igual que hace C64MEGA65
-- con su 540 en vez del 576 de la plantilla: no hay ningun "shift" vertical equivalente en el
-- pipeline digital, asi que aqui no aplica la restriccion de arriba. 544/16 = 34 filas exactas.
constant VGA_DX               : natural := 720;
constant VGA_DY               : natural := 544;

--    FONT_*  size of one OSM character
constant FONT_FILE            : string  := "../font/Anikki-16x16-m2m.rom";
constant FONT_DX              : natural := 16;
constant FONT_DY              : natural := 16;

-- Constants for the OSM screen memory
constant CHARS_DX             : natural := VGA_DX / FONT_DX;
constant CHARS_DY             : natural := VGA_DY / FONT_DY;
constant CHAR_MEM_SIZE        : natural := CHARS_DX * CHARS_DY;
constant VRAM_ADDR_WIDTH      : natural := f_log2(CHAR_MEM_SIZE);

----------------------------------------------------------------------------------------------------------
-- HyperRAM memory map (in units of 4kW)
----------------------------------------------------------------------------------------------------------

constant C_HMAP_M2M           : std_logic_vector(15 downto 0) := x"0000";     -- Reserved for the M2M framework
constant C_HMAP_DEMO          : std_logic_vector(15 downto 0) := x"0200";     -- Start address reserved for core

----------------------------------------------------------------------------------------------------------
-- Virtual Drive Management System
----------------------------------------------------------------------------------------------------------

-- CPC4MEGA65: sin disquetera todavia (Milestone 2) -> sin vdrives en M1.
type vd_buf_array is array(natural range <>) of std_logic_vector;
constant C_VDNUM              : natural := 0;
constant C_VD_DEVICE          : std_logic_vector(15 downto 0) := x"EEEE";
constant C_VD_BUFFER          : vd_buf_array := (x"EEEE", x"EEEE");

----------------------------------------------------------------------------------------------------------
-- System for handling simulated cartridges and ROM loaders
----------------------------------------------------------------------------------------------------------

type crtrom_buf_array is array(natural range<>) of std_logic_vector;
constant ENDSTR : character := character'val(0);

-- Cartridges and ROMs can be stored into QNICE devices, HyperRAM and SDRAM
constant C_CRTROMTYPE_DEVICE     : std_logic_vector(15 downto 0) := x"0000";
constant C_CRTROMTYPE_HYPERRAM   : std_logic_vector(15 downto 0) := x"0001";
constant C_CRTROMTYPE_SDRAM      : std_logic_vector(15 downto 0) := x"0002";           -- @TODO/RESERVED for future R4 boards

-- Types of automatically loaded ROMs:
-- If a mandatory file is missing, then the core outputs the missing file and goes fatal
constant C_CRTROMTYPE_MANDATORY  : std_logic_vector(15 downto 0) := x"0003";
constant C_CRTROMTYPE_OPTIONAL   : std_logic_vector(15 downto 0) := x"0004";


-- CPC4MEGA65: sin cargas manuales de ROM/cartucho en M1 (Dandanator es backlog).
constant C_CRTROMS_MAN_NUM       : natural := 0;
constant C_CRTROMS_MAN           : crtrom_buf_array := (x"EEEE", x"EEEE", x"EEEE");

-- CPC4MEGA65: device IDs para los bloques de ROM (ver core/.research/PORTING-PLAN.md
-- seccion 4.2). Las direcciones QNICE de dispositivo empiezan en 0x0100 (0x0000-0x00FF
-- estan reservadas al framework).
constant C_DEV_CPC_ROM_OS        : std_logic_vector(15 downto 0) := x"0100";  -- ROM baja (firmware/OS), 16KB
constant C_DEV_CPC_ROM_BASIC     : std_logic_vector(15 downto 0) := x"0101";  -- ROM alta banco 0 (BASIC), 16KB

-- ROMs cargadas automaticamente por el Shell antes de arrancar el core.
-- @TODO: nombres de fichero provisionales (ver PORTING-PLAN.md seccion 8, decision
-- pendiente de que imagenes de ROM concretas usar) - confirmar antes de la primera build.
-- Ambas son C_CRTROMTYPE_MANDATORY: sin firmware el CPC no arranca, igual que kick.rom
-- en el port de Amiga.
constant CPC_ROM_OS              : string := "/cpc4mega65/os6128.rom" & ENDSTR;
constant CPC_ROM_BASIC           : string := "/cpc4mega65/basic6128.rom" & ENDSTR;
constant CPC_ROM_BASIC_START     : std_logic_vector(15 downto 0) :=
   std_logic_vector(to_unsigned(CPC_ROM_OS'length, 16));

constant C_CRTROMS_AUTO_NUM      : natural := 2;
constant C_CRTROMS_AUTO_NAMES    : string  := CPC_ROM_OS & CPC_ROM_BASIC;
constant C_CRTROMS_AUTO          : crtrom_buf_array := (
   C_CRTROMTYPE_DEVICE, C_DEV_CPC_ROM_OS,    C_CRTROMTYPE_MANDATORY, x"0000",
   C_CRTROMTYPE_DEVICE, C_DEV_CPC_ROM_BASIC, C_CRTROMTYPE_MANDATORY, CPC_ROM_BASIC_START,
   x"EEEE");

----------------------------------------------------------------------------------------------------------
-- Audio filters
--
-- If you use audio filters, then you need to copy the correct values from the MiSTer core
-- that you are porting: sys/sys_top.v
----------------------------------------------------------------------------------------------------------

-- Sample values from the C64: @TODO: Adjust to your needs
constant audio_flt_rate : std_logic_vector(31 downto 0) := std_logic_vector(to_signed(7056000, 32));
constant audio_cx       : std_logic_vector(39 downto 0) := std_logic_vector(to_signed(4258969, 40));
constant audio_cx0      : std_logic_vector( 7 downto 0) := std_logic_vector(to_signed(3, 8));
constant audio_cx1      : std_logic_vector( 7 downto 0) := std_logic_vector(to_signed(2, 8));
constant audio_cx2      : std_logic_vector( 7 downto 0) := std_logic_vector(to_signed(1, 8));
constant audio_cy0      : std_logic_vector(23 downto 0) := std_logic_vector(to_signed(-6216759, 24));
constant audio_cy1      : std_logic_vector(23 downto 0) := std_logic_vector(to_signed( 6143386, 24));
constant audio_cy2      : std_logic_vector(23 downto 0) := std_logic_vector(to_signed(-2023767, 24));
constant audio_att      : std_logic_vector( 4 downto 0) := "00000";
constant audio_mix      : std_logic_vector( 1 downto 0) := "00"; -- 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

end package globals;

