----------------------------------------------------------------------------------
-- MiSTer2MEGA65 Framework
--
-- MEGA65 main file that contains the whole machine
--
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.globals.all;
use work.types_pkg.all;
use work.video_modes_pkg.all;
use work.vdrives_pkg.all;   -- CPC4MEGA65 M2: vd_vec_array/vd_std_array y AW/DW

library xpm;
use xpm.vcomponents.all;

entity MEGA65_Core is
generic (
   G_BOARD : string                                         -- Which platform are we running on.
);
port (
   --------------------------------------------------------------------------------------------------------
   -- QNICE Clock Domain
   --------------------------------------------------------------------------------------------------------

   -- Get QNICE clock from the framework: for the vdrives as well as for RAMs and ROMs
   qnice_clk_i             : in  std_logic;
   qnice_rst_i             : in  std_logic;

   -- Video and audio mode control
   qnice_dvi_o             : out std_logic;              -- 0=HDMI (with sound), 1=DVI (no sound)
   qnice_video_mode_o      : out video_mode_type;        -- Defined in video_modes_pkg.vhd
   qnice_osm_cfg_scaling_o : out std_logic_vector(8 downto 0);
   qnice_scandoubler_o     : out std_logic;              -- 0 = no scandoubler, 1 = scandoubler
   qnice_audio_mute_o      : out std_logic;
   qnice_audio_filter_o    : out std_logic;
   qnice_zoom_crop_o       : out std_logic;
   qnice_ascal_mode_o      : out std_logic_vector(1 downto 0);
   qnice_ascal_polyphase_o : out std_logic;
   qnice_ascal_triplebuf_o : out std_logic;
   qnice_retro15kHz_o      : out std_logic;              -- 0 = normal frequency, 1 = retro 15 kHz frequency
   qnice_csync_o           : out std_logic;              -- 0 = normal HS/VS, 1 = Composite Sync  

   -- Flip joystick ports
   qnice_flip_joyports_o   : out std_logic;

   -- On-Screen-Menu selections
   qnice_osm_control_i     : in  std_logic_vector(255 downto 0);

   -- QNICE general purpose register
   qnice_gp_reg_i          : in  std_logic_vector(255 downto 0);

   -- Core-specific devices
   qnice_dev_id_i          : in  std_logic_vector(15 downto 0);
   qnice_dev_addr_i        : in  std_logic_vector(27 downto 0);
   qnice_dev_data_i        : in  std_logic_vector(15 downto 0);
   qnice_dev_data_o        : out std_logic_vector(15 downto 0);
   qnice_dev_ce_i          : in  std_logic;
   qnice_dev_we_i          : in  std_logic;
   qnice_dev_wait_o        : out std_logic;

   --------------------------------------------------------------------------------------------------------
   -- HyperRAM Clock Domain
   --------------------------------------------------------------------------------------------------------

   hr_clk_i                : in  std_logic;
   hr_rst_i                : in  std_logic;
   hr_core_write_o         : out std_logic;
   hr_core_read_o          : out std_logic;
   hr_core_address_o       : out std_logic_vector(31 downto 0);
   hr_core_writedata_o     : out std_logic_vector(15 downto 0);
   hr_core_byteenable_o    : out std_logic_vector( 1 downto 0);
   hr_core_burstcount_o    : out std_logic_vector( 7 downto 0);
   hr_core_readdata_i      : in  std_logic_vector(15 downto 0);
   hr_core_readdatavalid_i : in  std_logic;
   hr_core_waitrequest_i   : in  std_logic;
   hr_high_i               : in  std_logic;  -- Core is too fast
   hr_low_i                : in  std_logic;  -- Core is too slow

   --------------------------------------------------------------------------------------------------------
   -- Video Clock Domain
   --------------------------------------------------------------------------------------------------------

   video_clk_o             : out std_logic;
   video_rst_o             : out std_logic;
   video_ce_o              : out std_logic;
   video_ce_ovl_o          : out std_logic;
   video_red_o             : out std_logic_vector(7 downto 0);
   video_green_o           : out std_logic_vector(7 downto 0);
   video_blue_o            : out std_logic_vector(7 downto 0);
   video_vs_o              : out std_logic;
   video_hs_o              : out std_logic;
   video_hblank_o          : out std_logic;
   video_vblank_o          : out std_logic;

   --------------------------------------------------------------------------------------------------------
   -- Core Clock Domain
   --------------------------------------------------------------------------------------------------------

   clk_i                   : in  std_logic;              -- 100 MHz clock

   -- Share clock and reset with the framework
   main_clk_o              : out std_logic;              -- CORE's 54 MHz clock
   main_rst_o              : out std_logic;              -- CORE's reset, synchronized

   -- M2M's reset manager provides 2 signals:
   --    m2m:   Reset the whole machine: Core and Framework
   --    core:  Only reset the core
   main_reset_m2m_i        : in  std_logic;
   main_reset_core_i       : in  std_logic;

   main_pause_core_i       : in  std_logic;

   -- On-Screen-Menu selections
   main_osm_control_i      : in  std_logic_vector(255 downto 0);

   -- QNICE general purpose register converted to main clock domain
   main_qnice_gp_reg_i     : in  std_logic_vector(255 downto 0);

   -- Audio output (Signed PCM)
   main_audio_left_o       : out signed(15 downto 0);
   main_audio_right_o      : out signed(15 downto 0);

   -- M2M Keyboard interface (incl. power led and drive led)
   main_kb_key_num_i       : in  integer range 0 to 79;  -- cycles through all MEGA65 keys
   main_kb_key_pressed_n_i : in  std_logic;              -- low active: debounced feedback: is kb_key_num_i pressed right now?
   main_power_led_o        : out std_logic;
   main_power_led_col_o    : out std_logic_vector(23 downto 0);
   main_drive_led_o        : out std_logic;
   main_drive_led_col_o    : out std_logic_vector(23 downto 0);

   -- Joysticks and paddles input
   main_joy_1_up_n_i       : in  std_logic;
   main_joy_1_down_n_i     : in  std_logic;
   main_joy_1_left_n_i     : in  std_logic;
   main_joy_1_right_n_i    : in  std_logic;
   main_joy_1_fire_n_i     : in  std_logic;
   main_joy_1_up_n_o       : out std_logic;
   main_joy_1_down_n_o     : out std_logic;
   main_joy_1_left_n_o     : out std_logic;
   main_joy_1_right_n_o    : out std_logic;
   main_joy_1_fire_n_o     : out std_logic;
   main_joy_2_up_n_i       : in  std_logic;
   main_joy_2_down_n_i     : in  std_logic;
   main_joy_2_left_n_i     : in  std_logic;
   main_joy_2_right_n_i    : in  std_logic;
   main_joy_2_fire_n_i     : in  std_logic;
   main_joy_2_up_n_o       : out std_logic;
   main_joy_2_down_n_o     : out std_logic;
   main_joy_2_left_n_o     : out std_logic;
   main_joy_2_right_n_o    : out std_logic;
   main_joy_2_fire_n_o     : out std_logic;

   main_pot1_x_i           : in  std_logic_vector(7 downto 0);
   main_pot1_y_i           : in  std_logic_vector(7 downto 0);
   main_pot2_x_i           : in  std_logic_vector(7 downto 0);
   main_pot2_y_i           : in  std_logic_vector(7 downto 0);
   main_rtc_i              : in  std_logic_vector(64 downto 0);

   -- CBM-488/IEC serial port
   iec_reset_n_o           : out std_logic;
   iec_atn_n_o             : out std_logic;
   iec_clk_en_o            : out std_logic;
   iec_clk_n_i             : in  std_logic;
   iec_clk_n_o             : out std_logic;
   iec_data_en_o           : out std_logic;
   iec_data_n_i            : in  std_logic;
   iec_data_n_o            : out std_logic;
   iec_srq_en_o            : out std_logic;
   iec_srq_n_i             : in  std_logic;
   iec_srq_n_o             : out std_logic;

   -- C64 Expansion Port (aka Cartridge Port)
   cart_en_o               : out std_logic;  -- Enable port, active high
   cart_phi2_o             : out std_logic;
   cart_dotclock_o         : out std_logic;
   cart_dma_i              : in  std_logic;
   cart_reset_oe_o         : out std_logic;
   cart_reset_i            : in  std_logic;
   cart_reset_o            : out std_logic;
   cart_game_oe_o          : out std_logic;
   cart_game_i             : in  std_logic;
   cart_game_o             : out std_logic;
   cart_exrom_oe_o         : out std_logic;
   cart_exrom_i            : in  std_logic;
   cart_exrom_o            : out std_logic;
   cart_nmi_oe_o           : out std_logic;
   cart_nmi_i              : in  std_logic;
   cart_nmi_o              : out std_logic;
   cart_irq_oe_o           : out std_logic;
   cart_irq_i              : in  std_logic;
   cart_irq_o              : out std_logic;
   cart_roml_oe_o          : out std_logic;
   cart_roml_i             : in  std_logic;
   cart_roml_o             : out std_logic;
   cart_romh_oe_o          : out std_logic;
   cart_romh_i             : in  std_logic;
   cart_romh_o             : out std_logic;
   cart_ctrl_oe_o          : out std_logic; -- 0 : tristate (i.e. input), 1 : output
   cart_ba_i               : in  std_logic;
   cart_rw_i               : in  std_logic;
   cart_io1_i              : in  std_logic;
   cart_io2_i              : in  std_logic;
   cart_ba_o               : out std_logic;
   cart_rw_o               : out std_logic;
   cart_io1_o              : out std_logic;
   cart_io2_o              : out std_logic;
   cart_addr_oe_o          : out std_logic; -- 0 : tristate (i.e. input), 1 : output
   cart_a_i                : in  unsigned(15 downto 0);
   cart_a_o                : out unsigned(15 downto 0);
   cart_data_oe_o          : out std_logic; -- 0 : tristate (i.e. input), 1 : output
   cart_d_i                : in  unsigned( 7 downto 0);
   cart_d_o                : out unsigned( 7 downto 0)
);
end entity MEGA65_Core;

architecture synthesis of MEGA65_Core is

---------------------------------------------------------------------------------------------
-- Clocks and active high reset signals for each clock domain
---------------------------------------------------------------------------------------------

signal main_clk               : std_logic;               -- Core main clock
signal main_rst               : std_logic;

---------------------------------------------------------------------------------------------
-- main_clk (MiSTer core's clock)
---------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------
-- qnice_clk
---------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------
-- OSD video mode menu items (infraestructura generica del framework, no especifica del core)
---------------------------------------------------------------------------------------------

-- CPC4MEGA65 (M1B003): numeros de linea (base 0) del menu de config.vhd/OPTM_ITEMS. Nada
-- comprueba automaticamente que sigan cuadrando - si se reordena el menu, hay que reajustar
-- esto a mano (Video Pipeline wiki S3.4: "el foot-gun mas comun de este fichero").
-- CPC4MEGA65 (M1B006): solo modos de 50Hz (maquina PAL), y ademas ninguno con H_PIXELS < 720,
-- porque hdmi_shift = H_PIXELS - VGA_DX se mete en un 'natural' y se iria a negativo - ver el
-- comentario largo en config.vhd/OPTM_ITEMS.
-- CPC4MEGA65 (M2): +3 respecto a M1B006, por las tres lineas nuevas (Drive A:, Drive B: y
-- separador) al principio de OPTM_ITEMS. Justo el reajuste manual del que avisa la wiki.
-- CPC4MEGA65 (M3): +2 mas, por "Swap joystick ports" y su separador.
constant C_MENU_FLIP_JOYS      : natural := 5;
constant C_MENU_HDMI_16_9_50   : natural := 10;
constant C_MENU_HDMI_4_3_50    : natural := 11;
constant C_MENU_HDMI_5_4_50    : natural := 12;
constant C_MENU_CRT_EMULATION  : natural := 16;
constant C_MENU_HDMI_ZOOM      : natural := 17;
constant C_MENU_IMPROVE_AUDIO  : natural := 18;

---------------------------------------------------------------------------------------------
-- CPC4MEGA65 M1A: senales QNICE para las dos ROMs de arranque (ver main.vhd)
---------------------------------------------------------------------------------------------

signal qnice_rom_os_we        : std_logic;
signal qnice_rom_os_data_o    : std_logic_vector(7 downto 0);
signal qnice_rom_basic_we     : std_logic;
signal qnice_rom_basic_data_o : std_logic_vector(7 downto 0);
-- CPC4MEGA65 M2: AMSDOS (ROM alta banco 7) - sin ella no hay comandos de disco en el CPC
signal qnice_rom_amsdos_we     : std_logic;
signal qnice_rom_amsdos_data_o : std_logic_vector(7 downto 0);

---------------------------------------------------------------------------------------------
-- CPC4MEGA65 M2: disquetera .DSK/EDSK (vdrives + buffers de imagen + lado SD del u765)
---------------------------------------------------------------------------------------------

-- Buffers de imagen de disco: RAM solo-QNICE, una por unidad. El firmware carga la imagen
-- entera aqui al montarla y luego sirve los bloques que pide el u765 desde RAM, en vez de ir
-- a la SD en tiempo real (vdrives.vhd:69-71 lo pide explicitamente por rendimiento).
signal qnice_mount_a_we       : std_logic;
signal qnice_mount_a_data     : std_logic_vector(7 downto 0);
signal qnice_mount_b_we       : std_logic;
signal qnice_mount_b_data     : std_logic_vector(7 downto 0);

-- Bus QNICE del propio vdrives
signal qnice_vd_ce            : std_logic;
signal qnice_vd_we            : std_logic;
signal qnice_vd_data          : std_logic_vector(15 downto 0);

-- Lado "SD config" de vdrives -> main.vhd (dominio del core; vdrives ya hace el CDC)
signal main_img_mounted       : std_logic_vector(C_VDNUM - 1 downto 0);
signal main_img_readonly      : std_logic;
signal main_img_size          : std_logic_vector(31 downto 0);
signal main_drive_mounted     : std_logic_vector(C_VDNUM - 1 downto 0);
signal main_cache_dirty       : std_logic_vector(C_VDNUM - 1 downto 0);
signal main_cache_flushing    : std_logic_vector(C_VDNUM - 1 downto 0);
signal main_cache_busy        : std_logic;   -- cualquier unidad con datos sin volcar a la SD

-- CPC4MEGA65 M2 (M2002): "la disquetera esta girando", desde main.vhd (latch del motor del
-- CPC). Dominio del core, un solo nivel: para un LED de placa no hace falta CDC.
signal main_drive_active      : std_logic;

-- Lado "SD block/byte" main.vhd <-> vdrives (dominio de QNICE)
signal qnice_sd_lba           : std_logic_vector(31 downto 0);
signal qnice_sd_rd            : std_logic_vector(C_VDNUM - 1 downto 0);
signal qnice_sd_wr            : std_logic_vector(C_VDNUM - 1 downto 0);
signal qnice_sd_ack           : vd_std_array(C_VDNUM - 1 downto 0);
signal qnice_sd_buff_addr     : std_logic_vector(AW downto 0);
signal qnice_sd_buff_dout     : std_logic_vector(DW downto 0);
signal qnice_sd_buff_din      : std_logic_vector(7 downto 0);
signal qnice_sd_buff_wr       : std_logic;

-- Adaptadores a los tipos de array de vdrives_pkg (un elemento por unidad)
signal qnice_sd_lba_arr       : vd_vec_array(C_VDNUM - 1 downto 0)(31 downto 0);
signal qnice_sd_blk_cnt_arr   : vd_vec_array(C_VDNUM - 1 downto 0)(5 downto 0);
signal qnice_sd_rd_arr        : vd_std_array(C_VDNUM - 1 downto 0);
signal qnice_sd_wr_arr        : vd_std_array(C_VDNUM - 1 downto 0);
signal qnice_sd_buff_din_arr  : vd_vec_array(C_VDNUM - 1 downto 0)(DW downto 0);

begin

   hr_core_write_o      <= '0';
   hr_core_read_o       <= '0';
   hr_core_address_o    <= (others => '0');
   hr_core_writedata_o  <= (others => '0');
   hr_core_byteenable_o <= (others => '0');
   hr_core_burstcount_o <= (others => '0');

   -- Tristate all expansion port drivers that we can directly control
   -- @TODO: As soon as we support modules that can act as busmaster, we need to become more flexible here
   cart_ctrl_oe_o       <= '0';
   cart_addr_oe_o       <= '0';
   cart_data_oe_o       <= '0';

   -- Due to a bug in the R5/R6 boards, the cartridge port needs to be enabled for joystick port 2 to work 
   cart_en_o            <= '1';

   cart_reset_oe_o      <= '0';
   cart_game_oe_o       <= '0';
   cart_exrom_oe_o      <= '0';
   cart_nmi_oe_o        <= '0';
   cart_irq_oe_o        <= '0';
   cart_roml_oe_o       <= '0';
   cart_romh_oe_o       <= '0';

   -- Default values for all signals
   cart_phi2_o          <= '0';
   cart_reset_o         <= '1';
   cart_dotclock_o      <= '0';
   cart_game_o          <= '1';
   cart_exrom_o         <= '1';
   cart_nmi_o           <= '1';
   cart_irq_o           <= '1';
   cart_roml_o          <= '0';
   cart_romh_o          <= '0';
   cart_ba_o            <= '0';
   cart_rw_o            <= '0';
   cart_io1_o           <= '0';
   cart_io2_o           <= '0';
   cart_a_o             <= (others => '0');
   cart_d_o             <= (others => '0');

   main_joy_1_up_n_o    <= '1';
   main_joy_1_down_n_o  <= '1';
   main_joy_1_left_n_o  <= '1';
   main_joy_1_right_n_o <= '1';
   main_joy_1_fire_n_o  <= '1';
   main_joy_2_up_n_o    <= '1';
   main_joy_2_down_n_o  <= '1';
   main_joy_2_left_n_o  <= '1';
   main_joy_2_right_n_o <= '1';
   main_joy_2_fire_n_o  <= '1';


   -- MMCME2_ADV clock generators:
   --   CPC4MEGA65: clk_sys del core original es 64MHz (ver globals.vhd/CORE_CLK_SPEED) -
   --   @TODO M1B: ajustar clk.vhd para generar 64MHz reales desde los 100MHz de la placa
   clk_gen : entity work.clk
      port map (
         sys_clk_i         => clk_i,           -- expects 100 MHz
         main_clk_o        => main_clk,        -- CORE's clock (@TODO M1B: 64 MHz, ver arriba)
         main_rst_o        => main_rst         -- CORE's reset, synchronized
      ); -- clk_gen

   main_clk_o  <= main_clk;
   main_rst_o  <= main_rst;
   video_clk_o <= main_clk;
   video_rst_o <= main_rst;

   ---------------------------------------------------------------------------------------------
   -- main_clk (MiSTer core's clock)
   ---------------------------------------------------------------------------------------------

   -- MEGA65's power led: By default, it is on and glows green when the MEGA65 is powered on.
   -- We switch it to blue when a long reset is detected and as long as the user keeps pressing the preset button
   main_power_led_o     <= '1';
   main_power_led_col_o <= x"0000FF" when main_reset_m2m_i else x"00FF00";

   -- main.vhd contains the actual MiSTer core
   i_main : entity work.main
      generic map (
         G_VDNUM              => C_VDNUM
      )
      port map (
         clk_main_i           => main_clk,
         reset_soft_i         => main_reset_core_i,
         reset_hard_i         => main_reset_m2m_i,
         pause_i              => main_pause_core_i,

         -- CPC4MEGA65 M1A: puerto QNICE de las dos ROMs de arranque (ver main.vhd)
         qnice_clk_i             => qnice_clk_i,
         qnice_rom_os_we_i       => qnice_rom_os_we,
         qnice_rom_os_addr_i     => qnice_dev_addr_i(13 downto 0),
         qnice_rom_os_data_i     => qnice_dev_data_i(7 downto 0),
         qnice_rom_os_data_o     => qnice_rom_os_data_o,
         qnice_rom_basic_we_i    => qnice_rom_basic_we,
         qnice_rom_basic_addr_i  => qnice_dev_addr_i(13 downto 0),
         qnice_rom_basic_data_i  => qnice_dev_data_i(7 downto 0),
         qnice_rom_basic_data_o  => qnice_rom_basic_data_o,
         qnice_rom_amsdos_we_i   => qnice_rom_amsdos_we,
         qnice_rom_amsdos_addr_i => qnice_dev_addr_i(13 downto 0),
         qnice_rom_amsdos_data_i => qnice_dev_data_i(7 downto 0),
         qnice_rom_amsdos_data_o => qnice_rom_amsdos_data_o,

         -- CPC4MEGA65 M2: disquetera. Ojo al reparto de dominios (ver main.vhd y
         -- PORTING-PLAN.md 9.1): main_img_* son de dominio core, qnice_sd_* de dominio QNICE.
         main_img_mounted_i      => main_img_mounted,
         main_img_readonly_i     => main_img_readonly,
         main_img_size_i         => main_img_size,
         qnice_sd_lba_o          => qnice_sd_lba,
         qnice_sd_rd_o           => qnice_sd_rd,
         qnice_sd_wr_o           => qnice_sd_wr,
         -- El u765 tiene una sola entrada de ack para las dos unidades (Amstrad.sv:776 hace
         -- exactamente esto: sd_ack(|sd_ack)), porque solo hay una transferencia en vuelo.
         qnice_sd_ack_i          => qnice_sd_ack(0) or qnice_sd_ack(1),
         -- Con BLKSZ=2 (bloques de 512B) y sd_blk_cnt=0, el firmware solo usa las direcciones
         -- 0..511 del bus de 14 bits de vdrives: los 9 bits bajos son la direccion completa,
         -- no un recorte. Ver PORTING-PLAN.md 9.1.
         qnice_sd_buff_addr_i    => qnice_sd_buff_addr(8 downto 0),
         qnice_sd_buff_dout_i    => qnice_sd_buff_dout,
         qnice_sd_buff_din_o     => qnice_sd_buff_din,
         qnice_sd_buff_wr_i      => qnice_sd_buff_wr,
         main_drive_active_o     => main_drive_active,

         clk_main_speed_i     => CORE_CLK_SPEED,

         -- Video output
         -- This is PAL 720x576 @ 50 Hz (pixel clock 27 MHz), but synchronized to main_clk (54 MHz).
         video_ce_o           => video_ce_o,
         video_ce_ovl_o       => video_ce_ovl_o,
         video_red_o          => video_red_o,
         video_green_o        => video_green_o,
         video_blue_o         => video_blue_o,
         video_vs_o           => video_vs_o,
         video_hs_o           => video_hs_o,
         video_hblank_o       => video_hblank_o,
         video_vblank_o       => video_vblank_o,

         -- audio output (pcm format, signed values)
         audio_left_o         => main_audio_left_o,
         audio_right_o        => main_audio_right_o,

         -- M2M Keyboard interface
         kb_key_num_i         => main_kb_key_num_i,
         kb_key_pressed_n_i   => main_kb_key_pressed_n_i,

         -- MEGA65 joysticks and paddles/mouse/potentiometers
         joy_1_up_n_i         => main_joy_1_up_n_i ,
         joy_1_down_n_i       => main_joy_1_down_n_i,
         joy_1_left_n_i       => main_joy_1_left_n_i,
         joy_1_right_n_i      => main_joy_1_right_n_i,
         joy_1_fire_n_i       => main_joy_1_fire_n_i,

         joy_2_up_n_i         => main_joy_2_up_n_i,
         joy_2_down_n_i       => main_joy_2_down_n_i,
         joy_2_left_n_i       => main_joy_2_left_n_i,
         joy_2_right_n_i      => main_joy_2_right_n_i,
         joy_2_fire_n_i       => main_joy_2_fire_n_i,

         pot1_x_i             => main_pot1_x_i,
         pot1_y_i             => main_pot1_y_i,
         pot2_x_i             => main_pot2_x_i,
         pot2_y_i             => main_pot2_y_i
      ); -- i_main

   ---------------------------------------------------------------------------------------------
   -- Audio and video settings (QNICE clock domain)
   ---------------------------------------------------------------------------------------------

   -- Due to a discussion on the MEGA65 discord (https://discord.com/channels/719326990221574164/794775503818588200/1039457688020586507)
   -- we decided to choose a naming convention for the PAL modes that might be more intuitive for the end users than it is
   -- for the programmers: "4:3" means "meant to be run on a 4:3 monitor", "5:4 on a 5:4 monitor".
   -- The technical reality is though, that in our "5:4" mode we are actually doing a 4/3 aspect ratio adjustment
   -- while in the 4:3 mode we are outputting a 5:4 image. This is kind of odd, but it seemed that our 4/3 aspect ratio
   -- adjusted image looks best on a 5:4 monitor and the other way round.
   -- Not sure if this will stay forever or if we will come up with a better naming convention.
   qnice_video_mode_o <= C_VIDEO_HDMI_5_4_50   when qnice_osm_control_i(C_MENU_HDMI_5_4_50)    = '1' else
                         C_VIDEO_HDMI_4_3_50   when qnice_osm_control_i(C_MENU_HDMI_4_3_50)    = '1' else
                         C_VIDEO_HDMI_16_9_50;

   -- Use On-Screen-Menu selections to configure several audio and video settings
   -- Video and audio mode control
   qnice_dvi_o                <= '0';                                         -- 0=HDMI (with sound), 1=DVI (no sound)
   -- CPC4MEGA65: activado (la plantilla trae '0' por defecto). Sin esto, VGA no muestra
   -- nada: un monitor VGA no sincroniza con la senal nativa de 15kHz del CPC sin doblar
   -- lineas primero (Video Pipeline wiki, S1.4/S4.2 - "scandoubler off" y "retro15kHz off"
   -- a la vez no es ninguno de los 3 modos analogicos soportados). M1 exige HDMI Y VGA
   -- funcionando (ver PORTING-PLAN.md), asi que esto es obligatorio, no opcional.
   qnice_scandoubler_o        <= '1';
   qnice_audio_mute_o         <= '0';                                         -- audio is not muted
   qnice_audio_filter_o       <= qnice_osm_control_i(C_MENU_IMPROVE_AUDIO);   -- 0 = raw audio, 1 = use filters from globals.vhd
   qnice_zoom_crop_o          <= qnice_osm_control_i(C_MENU_HDMI_ZOOM);       -- 0 = no zoom/crop
   
   -- These two signals are often used as a pair (i.e. both '1'), particularly when
   -- you want to run old analog cathode ray tube monitors or TVs (via SCART)
   -- If you want to provide your users a choice, then a good choice is:
   --    "Standard VGA":                     qnice_retro15kHz_o=0 and qnice_csync_o=0
   --    "Retro 15 kHz with HSync and VSync" qnice_retro15kHz_o=1 and qnice_csync_o=0
   --    "Retro 15 kHz with CSync"           qnice_retro15kHz_o=1 and qnice_csync_o=1
   qnice_retro15kHz_o         <= '0';
   qnice_csync_o              <= '0';
   qnice_osm_cfg_scaling_o    <= (others => '1');

   -- ascal filters that are applied while processing the input
   -- 00 : Nearest Neighbour
   -- 01 : Bilinear
   -- 10 : Sharp Bilinear
   -- 11 : Bicubic
   qnice_ascal_mode_o         <= "00";

   -- If polyphase is '1' then the ascal filter mode is ignored and polyphase filters are used instead
   -- @TODO: Right now, the filters are hardcoded in the M2M framework, we need to make them changeable inside m2m-rom.asm
   qnice_ascal_polyphase_o    <= qnice_osm_control_i(C_MENU_CRT_EMULATION);

   -- ascal triple-buffering
   -- @TODO: Right now, the M2M framework only supports OFF, so do not touch until the framework is upgraded
   qnice_ascal_triplebuf_o    <= '0';

   -- Flip joystick ports (i.e. the joystick in port 2 is used as joystick 1 and vice versa)
   -- CPC4MEGA65 M3: el intercambio lo hace entero el framework (M2M/vhdl/framework.vhd, su
   -- "debouncer" con flip_joys_i), asi que basta con enganchar el item de menu. Merece la pena
   -- tenerlo en un core de CPC: la maquina real solo trae UN conector de joystick (el 0), el
   -- segundo necesita una Y, asi que quien juegue va a querer elegir en que puerto del MEGA65
   -- enchufa sin tener que acordarse de cual es "el primero".
   qnice_flip_joyports_o      <= qnice_osm_control_i(C_MENU_FLIP_JOYS);

   ---------------------------------------------------------------------------------------------
   -- Core specific device handling (QNICE clock domain)
   ---------------------------------------------------------------------------------------------

   core_specific_devices : process(all)
   begin
      -- make sure that this is x"EEEE" by default and avoid a register here by having this default value
      qnice_dev_data_o     <= x"EEEE";
      qnice_dev_wait_o     <= '0';

      qnice_rom_os_we      <= '0';
      qnice_rom_basic_we   <= '0';
      qnice_rom_amsdos_we  <= '0';

      qnice_vd_ce          <= '0';
      qnice_vd_we          <= '0';
      qnice_mount_a_we     <= '0';
      qnice_mount_b_we     <= '0';

      case qnice_dev_id_i is

         -- CPC4MEGA65 M1A: las dos ROMs de arranque, cargadas por el Shell via CRTROM
         -- (globals.vhd). Direccionamiento byte a byte simple (bus de 8 bits del Z80,
         -- igual que la RAM plana del C64 - S72/S3.I.1 de la Porting Guide, sin reparto
         -- par/impar en carriles como necesitan los cores de 16 bits).
         when C_DEV_CPC_ROM_OS =>
            qnice_rom_os_we      <= qnice_dev_we_i;
            qnice_dev_data_o     <= x"00" & qnice_rom_os_data_o;

         when C_DEV_CPC_ROM_BASIC =>
            qnice_rom_basic_we   <= qnice_dev_we_i;
            qnice_dev_data_o     <= x"00" & qnice_rom_basic_data_o;

         -- CPC4MEGA65 M2: AMSDOS (ROM alta banco 7)
         when C_DEV_CPC_ROM_AMSDOS =>
            qnice_rom_amsdos_we  <= qnice_dev_we_i;
            qnice_dev_data_o     <= x"00" & qnice_rom_amsdos_data_o;

         -- CPC4MEGA65 M2: sistema de unidades virtuales (registros de vdrives.vhd)
         when C_VD_DEVICE =>
            qnice_vd_ce          <= qnice_dev_ce_i;
            qnice_vd_we          <= qnice_dev_we_i;
            qnice_dev_data_o     <= qnice_vd_data;

         -- CPC4MEGA65 M2: buffers de imagen de disco, uno por unidad
         when C_DEV_CPC_MOUNT_A =>
            qnice_mount_a_we     <= qnice_dev_we_i;
            qnice_dev_data_o     <= x"00" & qnice_mount_a_data;

         when C_DEV_CPC_MOUNT_B =>
            qnice_mount_b_we     <= qnice_dev_we_i;
            qnice_dev_data_o     <= x"00" & qnice_mount_b_data;

         when others => null;
      end case;
   end process core_specific_devices;

   ---------------------------------------------------------------------------------------------
   -- Dual Clocks
   ---------------------------------------------------------------------------------------------

   -- CPC4MEGA65: las dos ROMs de arranque (dualport_2clk_ram con puerto QNICE) viven dentro
   -- de main.vhd en vez de aqui - mismo patron que el Kernal ROM de C64MEGA65
   -- (CORE/vhdl/main.vhd, puertos qnice_c64rom_*), con las senales QNICE pasadas a traves
   -- de la entidad main (ver i_main mas arriba y core_specific_devices).

   ---------------------------------------------------------------------------------------
   -- CPC4MEGA65 M2: buffers de imagen de disco (RAM solo-QNICE, una por unidad)
   --
   -- Tamano: 256KB por unidad. Cubre cualquier disco de una cara del CPC, incluidos los de 42
   -- pistas y los EDSK con sectores no estandar: el formato DATA tipico son 194.816 bytes
   -- (40 pistas x 9 sectores x 512 + cabeceras) y el mayor de la biblioteca de pruebas es de
   -- 261.120. LIMITE CONOCIDO: una imagen de DOS CARAS (~390KB o mas) no cabe; si hace falta,
   -- habra que llevar estos buffers a HyperRAM en vez de BRAM. Coste: ~57 tiles RAMB36 por
   -- unidad; M1B006 usaba 97 de 365, asi que las dos caben con holgura (~58% del total).
   ---------------------------------------------------------------------------------------

   i_mount_buf_a : entity work.dualport_2clk_ram
      generic map (
         ADDR_WIDTH        => 18,           -- 256KB
         DATA_WIDTH        => 8,
         FALLING_A         => true          -- contrato de flanco de QNICE (Porting Guide S73)
      )
      port map (
         -- solo QNICE
         clock_a           => qnice_clk_i,
         address_a         => qnice_dev_addr_i(17 downto 0),
         data_a            => qnice_dev_data_i(7 downto 0),
         wren_a            => qnice_mount_a_we,
         q_a               => qnice_mount_a_data
      ); -- i_mount_buf_a

   i_mount_buf_b : entity work.dualport_2clk_ram
      generic map (
         ADDR_WIDTH        => 18,
         DATA_WIDTH        => 8,
         FALLING_A         => true
      )
      port map (
         clock_a           => qnice_clk_i,
         address_a         => qnice_dev_addr_i(17 downto 0),
         data_a            => qnice_dev_data_i(7 downto 0),
         wren_a            => qnice_mount_b_we,
         q_a               => qnice_mount_b_data
      ); -- i_mount_buf_b

   ---------------------------------------------------------------------------------------
   -- Virtual drive handler
   --
   -- CPC4MEGA65 M2: dos unidades (A: y B:), las que modela el u765 dentro de main.vhd.
   -- BLKSZ=2 (bloques de 512 bytes) = el tamano de sector natural de un .DSK del CPC y lo
   -- que el propio u765 asume (su sd_buff_addr es de 9 bits, y no tiene puerto sd_blk_cnt,
   -- o sea que siempre pide exactamente un bloque).
   ---------------------------------------------------------------------------------------

   -- CPC4MEGA65 M2 (M2002): LED de disquetera, mismo criterio que QL4M65
   -- (learning_cores/QL4M65/CORE/vhdl/mega65.vhd:1184-1185).
   --
   -- ROJO = la disquetera esta en marcha. La senal es el latch del motor que llega de main.vhd,
   -- que es literalmente lo que enciende el LED en un CPC real, y cubre A: y B: a la vez porque
   -- comparten motor igual que en la maquina original. Ojo al comportamiento autentico: AMSDOS
   -- apaga el motor con unos segundos de retardo, asi que el LED se queda encendido un rato
   -- despues de acabar el acceso - eso es lo que hace un CPC de verdad, no un fallo.
   --
   -- AZUL = hay datos escritos que todavia no se han volcado a la SD ("no apagues aun"). El
   -- color no es arbitrario: el QL usa azul para esto mismo, asi que el usuario ya tiene el
   -- codigo aprendido de su otro core. (C64MEGA65 usa ambar y AExp amarillo para lo mismo; lo
   -- que importa es que sea distinto del rojo de actividad.)
   --
   -- En reposo el LED se apaga. Antes se quedaba verde fijo con solo tener un disco montado,
   -- que no aportaba informacion: montado es el estado normal, no un aviso.
   main_cache_busy      <= '1' when (main_cache_dirty    /= (main_cache_dirty'range    => '0') or
                                     main_cache_flushing /= (main_cache_flushing'range => '0'))
                           else '0';

   main_drive_led_o     <= main_drive_active or main_cache_busy;
   main_drive_led_col_o <= x"0000FF" when main_cache_busy = '1' else x"FF0000";

   -- Adaptadores a los tipos de array de vdrives_pkg. sd_lba y sd_buff_din se replican a las
   -- dos unidades porque el u765 solo tiene un juego (Amstrad.sv:193/199 hace lo mismo con
   -- '{sd_lba,sd_lba} y '{sd_buff_din,sd_buff_din}): quien selecciona la unidad es sd_rd/sd_wr.
   gen_vd_fanout : for i in 0 to C_VDNUM - 1 generate
      qnice_sd_lba_arr(i)      <= qnice_sd_lba;
      qnice_sd_blk_cnt_arr(i)  <= (others => '0');   -- 0 = "un bloque" (vdrives suma 1)
      qnice_sd_rd_arr(i)       <= qnice_sd_rd(i);
      qnice_sd_wr_arr(i)       <= qnice_sd_wr(i);
      qnice_sd_buff_din_arr(i) <= qnice_sd_buff_din;
   end generate gen_vd_fanout;

   i_vdrives : entity work.vdrives
      generic map (
         VDNUM       => C_VDNUM,
         BLKSZ       => 2                   -- 2 = bloques de 512 bytes
      )
      port map
      (
         clk_qnice_i       => qnice_clk_i,
         clk_core_i        => main_clk,
         reset_core_i      => main_reset_core_i,

         -- Core clock domain
         img_mounted_o     => main_img_mounted,
         img_readonly_o    => main_img_readonly,
         img_size_o        => main_img_size,
         img_type_o        => open,             -- el u765 no distingue tipos de imagen
         drive_mounted_o   => main_drive_mounted,

         -- Cache output signals: The dirty flags can be used to enforce data consistency
         -- (for example by ignoring/delaying a reset or delaying a drive unmount/mount, etc.)
         -- The flushing flags can be used to signal the fact that the caches are currently
         -- flushing to the user, for example using a special color/signal for example
         -- at the drive led
         cache_dirty_o     => main_cache_dirty,
         cache_flushing_o  => main_cache_flushing,

         -- QNICE clock domain
         sd_lba_i          => qnice_sd_lba_arr,
         sd_blk_cnt_i      => qnice_sd_blk_cnt_arr,
         sd_rd_i           => qnice_sd_rd_arr,
         sd_wr_i           => qnice_sd_wr_arr,
         sd_ack_o          => qnice_sd_ack,

         sd_buff_addr_o    => qnice_sd_buff_addr,
         sd_buff_dout_o    => qnice_sd_buff_dout,
         sd_buff_din_i     => qnice_sd_buff_din_arr,
         sd_buff_wr_o      => qnice_sd_buff_wr,

         -- QNICE interface (MMIO, 4k-segmented)
         -- qnice_addr is 28-bit because we have a 16-bit window selector and a 4k window: 65536*4096 = 268.435.456 = 2^28
         qnice_addr_i      => qnice_dev_addr_i,
         qnice_data_i      => qnice_dev_data_i,
         qnice_data_o      => qnice_vd_data,
         qnice_ce_i        => qnice_vd_ce,
         qnice_we_i        => qnice_vd_we
      ); -- i_vdrives

end architecture synthesis;

