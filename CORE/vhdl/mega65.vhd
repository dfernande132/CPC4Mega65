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

   -- CPC4MEGA65 M4: disquetera fisica interna del MEGA65 (interfaz Shugart de 34 pines de la
   -- placa). La plantilla ataba estas salidas a su valor inactivo en top_mega65-r6.vhd y no las
   -- enrutaba a ningun sitio; ver core/doc/m2m/exceptions.md. Todo en dominio del core.
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
-- CPC4MEGA65 (M4A): +1 mas, por "Floppy: motor test".
-- CPC4MEGA65 (M4032): la disquetera fisica se muda a un submenu, asi que todo lo suyo baja y
-- "Swap joystick ports" queda por detras. Comprobado con el script de indices del scratchpad,
-- que cruza cada constante con el TEXTO de la linea que direcciona.
constant C_MENU_FLOPPY_OFF     : natural := 10;    -- radio: la disquetera no se usa
constant C_MENU_FLOPPY_A       : natural := 11;
constant C_MENU_FLOPPY_B       : natural := 12;
constant C_MENU_FLOPPY_TEST    : natural := 14;
constant C_MENU_FLOPPY_FMT     : natural := 16;
constant C_MENU_FLOPPY_COPY    : natural := 17;   -- M4034: copiar la imagen al disquete
constant C_MENU_FLOPPY_WB      : natural := 18;   -- M4035: reescribir pistas sucias, a mano
constant C_MENU_FLOPPY_WBAUTO  : natural := 19;   -- M4035: ...y solo
constant C_MENU_FLOPPY_DUMP    : natural := 20;   -- M4044: volcar telemetria
constant C_MENU_FLIP_JOYS      : natural := 24;
constant C_MENU_HDMI_16_9_50   : natural := 29;
constant C_MENU_HDMI_4_3_50    : natural := 30;
constant C_MENU_HDMI_5_4_50    : natural := 31;
constant C_MENU_CRT_EMULATION  : natural := 35;
constant C_MENU_HDMI_ZOOM      : natural := 36;
constant C_MENU_IMPROVE_AUDIO  : natural := 37;

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

-- CPC4MEGA65 M4A: estado de la disquetera FISICA (no confundir con la de imagen de M2).
-- Todo en dominio del core; el enable viene del menu y hay que cruzarlo desde QNICE.
signal main_floppy_enable     : std_logic;
signal main_floppy_busy       : std_logic;
signal main_floppy_ready      : std_logic;
signal main_floppy_error      : std_logic;
signal main_floppy_blink      : std_logic;
signal main_floppy_disk_in    : std_logic;
signal floppy_led_on          : std_logic;
signal floppy_led_col         : std_logic_vector(23 downto 0);

-- CPC4MEGA65 M4B: recuento de sectores validos leidos de la pista 0
signal main_floppy_mfm_done   : std_logic;
signal main_floppy_sect_cnt   : std_logic_vector(4 downto 0);
signal main_floppy_is_hd      : std_logic;
signal main_floppy_scan_done  : std_logic;
signal main_floppy_bad_trk    : std_logic_vector(4 downto 0);
signal main_floppy_pos_code   : std_logic_vector(4 downto 0);
signal main_floppy_wr_code    : std_logic_vector(4 downto 0);
signal main_floppy_buf_addr   : std_logic_vector(17 downto 0);
signal main_floppy_buf_data   : std_logic_vector(7 downto 0);
signal main_floppy_buf_we     : std_logic;
-- M4034: lectura del buffer de montaje por el lado del core. El puerto ya existia y estaba
-- sin usar (q_b => open en las dos instancias).
signal main_floppy_buf_qa     : std_logic_vector(7 downto 0);
signal main_floppy_buf_qb     : std_logic_vector(7 downto 0);
signal main_floppy_copy_en    : std_logic;
signal main_floppy_copy_busy  : std_logic;
signal main_floppy_copy_done  : std_logic;
signal main_floppy_copy_refus : std_logic;
signal main_floppy_wb_en      : std_logic;
signal main_floppy_wb_auto    : std_logic;
signal main_floppy_wb_active  : std_logic;
signal main_floppy_wb_pending : std_logic;
signal main_floppy_wrote_ok   : std_logic;   -- M4039
signal main_floppy_dump_en    : std_logic;   -- M4044

-- CPC4MEGA65 M4045: ESTADO DEL CORE HACIA EL FIRMWARE.
--
-- Hasta aqui no existia camino core -> QNICE para esto. Los bits del menu los escribe el Shell
-- y el core solo los lee, asi que para que una accion se desmarque sola al terminar hace falta
-- que el firmware SEPA que ha terminado. Este es el unico dato que necesita.
--
-- Solo lectura, cuatro bits, y cruzan de dominio con cdc_stable como todo lo demas.
signal main_floppy_op_end     : std_logic;   -- M4047
signal main_core_status       : std_logic_vector(4 downto 0);   -- M4052: cinco acciones
signal qnice_core_status      : std_logic_vector(4 downto 0);
signal main_floppy_dump_done  : std_logic;   -- M4052
signal main_floppy_no_disk    : std_logic;   -- M4053
signal led_end_col            : std_logic_vector(23 downto 0);   -- M4053
signal led_res_col            : std_logic_vector(23 downto 0) := x"000000";
signal main_floppy_tgt_b      : std_logic;   -- '1' = la disquetera fisica va a la unidad B:
signal main_dpll_en           : std_logic;   -- M4023: separador DPLL
signal floppy_we_a            : std_logic;
signal floppy_we_b            : std_logic;

-- CPC4MEGA65 M4C1: formateo
signal main_floppy_fmt_en     : std_logic;
signal main_floppy_fmt_busy   : std_logic;
signal main_floppy_fmt_done   : std_logic;
signal main_floppy_fmt_refus  : std_logic;
signal main_floppy_refus_now  : std_logic;   -- M4056: rechazo VIGENTE, ver donde se asigna
signal main_floppy_fmt_full   : std_logic;
-- DENSEL: por defecto '1' (doble densidad segun la convencion mas comun); el menu lo invierte
-- para poder probar la otra polaridad sin recompilar. Solo afecta a la escritura.
signal main_floppy_density    : std_logic;
signal main_floppy_id_cpc     : std_logic;
signal blink_count            : std_logic_vector(4 downto 0);

-- M4033: destello unico al terminar
constant C_ONESHOT            : natural := 32_000_000;   -- 0,5 s a 64 MHz
signal oneshot_cnt            : natural range 0 to C_ONESHOT := 0;
signal done_d                 : std_logic := '0';
signal fin_edge               : std_logic := '0';
signal led_finished           : std_logic;
signal floppy_led_own         : std_logic;

-- Secuenciador que "dice" el recuento parpadeando (ver el comentario del LED)
signal blink_div              : natural range 0 to 9_599_999 := 0;   -- 0,15 s a 64 MHz
-- 8 bits: con 18 sectores (un 1,44 MB) la secuencia llega a 12 + 18*4 + 9 = 93 ranuras, que no
-- cabe en 6 bits. Con 6 bits el contador daba la vuelta y la cuenta salia sin sentido.
signal blink_slot             : unsigned(7 downto 0) := (others => '0');
signal blink_on               : std_logic := '0';

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
         G_VDNUM              => C_VDNUM,
         G_CLK_HZ             => CORE_CLK_SPEED   -- CPC4MEGA65 M4A, ver main.vhd
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

         -- CPC4MEGA65 M4A: disquetera fisica interna
         floppy_enable_i         => main_floppy_enable,
         floppy_busy_o           => main_floppy_busy,
         floppy_ready_o          => main_floppy_ready,
         floppy_error_o          => main_floppy_error,
         floppy_index_blink_o    => main_floppy_blink,
         floppy_disk_in_o        => main_floppy_disk_in,
         floppy_dump_done_o      => main_floppy_dump_done,   -- M4052
         floppy_no_disk_o        => main_floppy_no_disk,     -- M4053
         floppy_mfm_done_o       => main_floppy_mfm_done,
         floppy_sector_count_o   => main_floppy_sect_cnt,
         floppy_is_hd_o          => main_floppy_is_hd,
         floppy_scan_done_o      => main_floppy_scan_done,
         floppy_bad_tracks_o     => main_floppy_bad_trk,
         floppy_pos_code_o       => main_floppy_pos_code,
         floppy_wr_code_o        => main_floppy_wr_code,
         floppy_buf_addr_o       => main_floppy_buf_addr,
         floppy_buf_data_o       => main_floppy_buf_data,
         floppy_buf_we_o         => main_floppy_buf_we,
          floppy_buf_qa_i         => main_floppy_buf_qa,      -- M4034
          floppy_buf_qb_i         => main_floppy_buf_qb,
          floppy_copy_en_i        => main_floppy_copy_en,
          floppy_copy_busy_o      => main_floppy_copy_busy,
          floppy_copy_done_o      => main_floppy_copy_done,
          floppy_copy_refused_o   => main_floppy_copy_refus,
          floppy_wb_en_i          => main_floppy_wb_en,        -- M4035
          floppy_wb_auto_i        => main_floppy_wb_auto,
          floppy_wb_active_o      => main_floppy_wb_active,
          floppy_wb_pending_o     => main_floppy_wb_pending,
          floppy_wrote_ok_o       => main_floppy_wrote_ok,   -- M4039
          floppy_dump_en_i        => main_floppy_dump_en,      -- M4044
         floppy_tgt_b_i          => main_floppy_tgt_b,
         dpll_en_i               => main_dpll_en,
         floppy_fmt_enable_i     => main_floppy_fmt_en,
         floppy_density_i        => main_floppy_density,
         floppy_fmt_busy_o       => main_floppy_fmt_busy,
         floppy_fmt_done_o       => main_floppy_fmt_done,
         floppy_fmt_refused_o    => main_floppy_fmt_refus,
         floppy_fmt_full_o       => main_floppy_fmt_full,
         floppy_id_is_cpc_o      => main_floppy_id_cpc,

         f_density_o             => f_density_o,
         f_motora_o              => f_motora_o,
         f_motorb_o              => f_motorb_o,
         f_selecta_o             => f_selecta_o,
         f_selectb_o             => f_selectb_o,
         f_side1_o               => f_side1_o,
         f_stepdir_o             => f_stepdir_o,
         f_step_o                => f_step_o,
         f_wdata_o               => f_wdata_o,
         f_wgate_o               => f_wgate_o,
         f_index_i               => f_index_i,
         f_track0_i              => f_track0_i,
         f_writeprotect_i        => f_writeprotect_i,
         f_diskchanged_i         => f_diskchanged_i,
         f_rdata_i               => f_rdata_i,

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

         -- M4045: estado del core, solo lectura. Lo lee HANDLE_CORE_IO en cada iteracion del
         -- bucle del Shell, asi que tiene que ser barato: un mux de cuatro bits ya sincronizados.
         when C_DEV_CPC_STATUS =>
               qnice_dev_data_o     <= "00000000000" & qnice_core_status;

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

   -- CPC4MEGA65 M4B: el PUERTO B de estos buffers estaba libre desde M2 (solo se usaba el A,
   -- el de QNICE). Ahi entra ahora el escritor de imagen de la disquetera fisica, en dominio
   -- del core. Es lo que permite meter un disco fisico sin memoria nueva ni CDC inventado:
   -- leer del disquete no es un modo especial, es otra forma de llenar el MISMO buffer que hoy
   -- llena el Shell desde un .DSK. Todo lo que viene despues (u765, AMSDOS, CAT) no se entera.
   --
   -- Solo escribe la unidad seleccionada en el menu: hay una disquetera fisica, no dos.
   main_floppy_tgt_b <= main_osm_control_i(C_MENU_FLOPPY_B);

   -- M4023: eleccion de separador de datos
   -- M4041: el separador DPLL sale del menu. Se anadio en M4023 para probar que los fallos de
   -- la pista 7 fueran desplazamiento de pico, y la hipotesis quedo FALSADA con medida: el DPLL
   -- corrio de verdad (65.535 celdas encendido, 0 apagado) y dio resultados identicos hasta el
   -- ultimo contador. El RTL se queda en floppy_mfm.vhd -la sintesis lo elimina sola al estar
   -- el enable constante- por si alguna mecanica rara lo necesitase alguna vez.
   main_dpll_en <= '0';
   floppy_we_a       <= main_floppy_buf_we and not main_floppy_tgt_b;
   floppy_we_b       <= main_floppy_buf_we and     main_floppy_tgt_b;

   -- M4045: el estado cruza al dominio de QNICE. Cuatro niveles independientes, cada uno
   -- estable durante milisegundos: cdc_stable es justo lo que pide el caso.
   i_cdc_core_status : entity work.cdc_stable
      generic map (
         G_DATA_SIZE => 5
      )
      port map (
         src_data_i  => main_core_status,
         dst_clk_i   => qnice_clk_i,
         dst_data_o  => qnice_core_status
      ); -- i_cdc_core_status

   i_mount_buf_a : entity work.dualport_2clk_ram
      generic map (
         ADDR_WIDTH        => 18,           -- 256KB
         DATA_WIDTH        => 8,
         FALLING_A         => true          -- contrato de flanco de QNICE (Porting Guide S73)
      )
      port map (
         clock_a           => qnice_clk_i,
         address_a         => qnice_dev_addr_i(17 downto 0),
         data_a            => qnice_dev_data_i(7 downto 0),
         wren_a            => qnice_mount_a_we,
         q_a               => qnice_mount_a_data,

         clock_b           => main_clk,
         address_b         => main_floppy_buf_addr,
         data_b            => main_floppy_buf_data,
         wren_b            => floppy_we_a,
         q_b               => main_floppy_buf_qa
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
         q_a               => qnice_mount_b_data,

         clock_b           => main_clk,
         address_b         => main_floppy_buf_addr,
         data_b            => main_floppy_buf_data,
         wren_b            => floppy_we_b,
         q_b               => main_floppy_buf_qb
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

   ---------------------------------------------------------------------------------------
   -- CPC4MEGA65 M4A: el LED como instrumento de diagnostico de la disquetera fisica
   --
   -- Este proyecto no tiene disponible la consola serie de QNICE, asi que el LED de la placa
   -- es la unica salida de medida para la fase A. En vez de un simple "va / no va", codifica
   -- QUE ha fallado, que es lo que hace util una primera prueba contra un interfaz cuyas
   -- polaridades no estan verificadas todavia (ver floppy_phys.vhd):
   --
   --   LED apagado          -> la prueba esta desactivada en el menu
   --   AMARILLO fijo        -> motor arrancando o cabeza buscando la pista 0
   --   ROJO fijo            -> recalibrado fallido: se agotaron 90 pasos sin ver f_track0_i.
   --                           Sintoma de sentido de f_stepdir_o invertido, cable mal, o
   --                           ausencia de disquetera
   --   VERDE parpadeando    -> TODO BIEN: pista 0 encontrada y el indice llega. El parpadeo
   --      ~2,5 veces/s         es el propio pulso de indice dividido por dos (300 RPM = 5 Hz)
   --   VERDE fijo           -> la mecanica responde pero no llegan pulsos de indice: no hay
   --                           disquete metido, o el disco no gira
   --
   -- Con la prueba desactivada, el LED vuelve a lo que hace desde M2 (rojo = disquetera de
   -- imagen en marcha, azul = queda cache por volcar a la SD).
   ---------------------------------------------------------------------------------------

   -- El formateo necesita la mecanica en marcha, asi que enciende tambien floppy_enable.
   -- M4032: con "Off" seleccionado la disquetera fisica no se usa para nada, ni siquiera si
   -- se activa una accion. Es el estado por defecto: quien no la quiera, ni la enciende.
   -- M4034: la copia usa el MISMO camino que el formateo - floppy_scan en modo formateo y
   -- floppy_write escribiendo - y lo unico que cambia es de donde salen los bytes. Asi que la
   -- copia tiene que encender tambien fmt_en; lo que la distingue es main_floppy_copy_en, que
   -- pone a floppy_write en modo origen externo y da el permiso de sujecion a floppy_copy.
   main_floppy_wb_en   <= main_osm_control_i(C_MENU_FLOPPY_WB) and
                          not main_osm_control_i(C_MENU_FLOPPY_OFF);
   -- El automatico NO se anula con la disquetera en Off: lo que se anula es la disquetera
   -- entera, asi que el interruptor puede quedarse encendido entre sesiones sin efecto.
   -- M4047: cada bit dice 'LA OPERACION DE ESTA OPCION HA TERMINADO', no 'ha pasado algo'.
   --
   -- La version anterior usaba main_floppy_fmt_done para el formateo, y ESE es el 'pista
   -- terminada' del escritor: pulsa 40 veces durante un formateo y acaba en bajo, asi que la
   -- opcion no se desmarcaba nunca. El fin de la OPERACION -de las cuatro- es el fin del
   -- recorrido de floppy_scan, mas el rechazo del copiador, que tambien la termina aunque sea
   -- sin escribir nada.
   --
   -- Y cada bit se cruza con SU propia opcion de menu, para que el firmware sepa cual
   -- desmarcar sin tener que adivinarlo.
   main_floppy_op_end <= main_floppy_scan_done or main_floppy_copy_refus;

    -- M4052: bit 4, el volcado de telemetria. No sale de op_end porque el volcado no recorre
    -- el disco: lo sirve el firmware en cuanto puede, asi que su final es su propio acuse.
    -- Era la unica accion que no se desmarcaba sola, y no por criterio sino por olvido.
    main_core_status <= (main_floppy_dump_done and main_floppy_dump_en) &
                        (main_floppy_op_end and main_floppy_wb_en)   &
                       (main_floppy_op_end and main_floppy_copy_en) &
                       (main_floppy_op_end and main_osm_control_i(C_MENU_FLOPPY_FMT)) &
                       (main_floppy_op_end and main_osm_control_i(C_MENU_FLOPPY_TEST));


   main_floppy_dump_en <= main_osm_control_i(C_MENU_FLOPPY_DUMP) and
                          not main_osm_control_i(C_MENU_FLOPPY_OFF);
   main_floppy_wb_auto <= main_osm_control_i(C_MENU_FLOPPY_WBAUTO) and
                          not main_osm_control_i(C_MENU_FLOPPY_OFF);
   main_floppy_copy_en <= main_osm_control_i(C_MENU_FLOPPY_COPY) and
                          not main_osm_control_i(C_MENU_FLOPPY_OFF);
   main_floppy_fmt_en <= (main_osm_control_i(C_MENU_FLOPPY_FMT) or main_floppy_copy_en or
                          main_floppy_wb_active) and
                         not main_osm_control_i(C_MENU_FLOPPY_OFF);
   -- M4041: el interruptor de polaridad de DENSEL sale del menu. Probado en hardware: los dos
   -- formateos, con y sin invertir, los lee el CPC real. A ESTA mecanica la linea le es
   -- indiferente. OJO con lo que eso demuestra: que es inerte AQUI, no en cualquier unidad; en
   -- otras puede afectar a la corriente de escritura. Se deja la polaridad que funciona, y el
   -- 'VERIFICAR' de M4001 se cierra como 'irrelevante aqui, desconocido en general'.
   main_floppy_density <= '1';
   main_floppy_enable <= (main_osm_control_i(C_MENU_FLOPPY_TEST) and
                          not main_osm_control_i(C_MENU_FLOPPY_OFF)) or main_floppy_fmt_en;

   ---------------------------------------------------------------------------------------
   -- CPC4MEGA65 M4B: el LED "dice" el numero de sectores parpadeando
   --
   -- Un color solo distingue bien / mal, y aqui hace falta saber CUANTOS sectores se han
   -- leido: 9 = perfecto, 3 = el separador funciona pero pierde sincronismo, 0 = no engancha
   -- nada. Asi que cuando la vuelta termina, el LED da tantos destellos como sectores validos
   -- ha encontrado, hace una pausa larga y repite. Se cuentan a simple vista.
   --
   -- 0,15 s por destello y 6 ranuras de pausa. El slot par enciende y el impar apaga, asi que
   -- N sectores ocupan las ranuras 0..2N-1 y la pausa va de 2N a 2N+5.
   ---------------------------------------------------------------------------------------

   -- Va en main_clk, no en qnice_clk: el LED de la placa es dominio del core y las senales
   -- main_floppy_* ya vienen de main.vhd en ese dominio. Usar el reloj de QNICE aqui habria
   -- metido un cruce de dominio gratuito, que es justo el tipo de descuido que costo tres
   -- builds en M2.
   --
   -- Estructura de la secuencia, en ranuras de 0,15 s:
   --   0..5    (0,9 s)  destello LARGO = "empieza la cuenta"
   --   6..11   (0,9 s)  apagado
   --   12..    N destellos de 0,3 s encendido + 0,3 s apagado (4 ranuras cada uno)
   --   ...     1,5 s apagado, y vuelta a empezar
   -- La zona de destellos empieza en la ranura 12 a proposito: es multiplo de 4, asi que el
   -- bit 1 del contador da directamente el encendido/apagado dentro de cada destello sin
   -- tener que restar el desplazamiento.
   --
   -- La primera version usaba destellos de 0,15 s sin marca de inicio, y el usuario no pudo
   -- distinguir 8 de 9 con seguridad. Una medida que no se puede leer sin dudar no sirve como
   -- medida: de ahi el destello largo de referencia y el ritmo al doble de lento.
   -- Que numero se "dice":
   --   * durante el recorrido, los sectores de la pista que se acaba de leer
   --   * al terminar CON FALLOS, el CODIGO DE POSICIONAMIENTO (1, 2 o 3), no el numero de
   --     pistas malas. Contar 20 destellos no aporta nada que no supieramos ya; saber si la
   --     cabeza esta donde creemos si. Ademas 1-3 se cuentan de un vistazo.
   -- Si no hay fallos el LED se queda fijo y este numero no se usa.
   -- BUILD DE CONTROL C1: al terminar el recorrido el LED "dice" el CODIGO DE ESCRITURA
   -- (cuantos bytes han llegado al buffer), que es el unico eslabon de la cadena sin validar.
   -- Ver la cabecera de floppy_dsk.vhd para la tabla de codigos.
   blink_count <= main_floppy_wr_code when main_floppy_scan_done = '1' else main_floppy_sect_cnt;

   blink_proc : process (main_clk)
      variable n_slots : unsigned(7 downto 0);
   begin
      if rising_edge(main_clk) then
         -- 4 ranuras por destello: la cuenta (5 bits) x 4 = 7 bits, mas un cero delante = 8
         n_slots := ("0" & unsigned(blink_count) & "00");

         if main_floppy_enable = '0' or main_floppy_mfm_done = '0' then
            blink_div  <= 0;
            blink_slot <= (others => '0');
            blink_on   <= '0';
         else
            if blink_div = 9_599_999 then      -- 0,15 s a 64 MHz
               blink_div <= 0;
               if blink_slot = (12 + n_slots + 9) then
                  blink_slot <= (others => '0');
               else
                  blink_slot <= blink_slot + 1;
               end if;
            else
               blink_div <= blink_div + 1;
            end if;

            if blink_slot < 6 then
               blink_on <= '1';                          -- marca de inicio
            elsif blink_slot < 12 then
               blink_on <= '0';
            elsif blink_slot < (12 + n_slots) then
               -- 2 ranuras encendido + 2 apagado por cada sector
               blink_on <= not blink_slot(1);
            else
               blink_on <= '0';                          -- pausa final
            end if;
         end if;
      end if;
   end process blink_proc;

   -- Antes de que termine la vuelta, el LED sigue diciendo el estado mecanico de M4A.
   -- Cuando termina, pasa a "decir" el recuento: verde si ha encontrado algo, rojo fijo si no
   -- ha enganchado ni un sector (ahi el separador o la densidad estan mal).
   -- Recorrido terminado y sin pistas malas: LED fijo, que es la señal mas facil de reconocer
   -- para el caso bueno. Con pistas malas, las cuenta parpadeando.
   -- M4033: al TERMINAR, el LED da UN destello de medio segundo y se apaga. Antes repetia el
   -- recuento en bucle indefinidamente, que era util cuando el LED era el unico instrumento
   -- que teniamos; desde que hay volcado de telemetria no aporta nada y solo molesta.
   -- Verde = todo bien, ambar = hubo sectores defectuosos. Durante la operacion se mantiene
   -- el parpadeo por pista, que si informa de que avanza.
   -- CPC4MEGA65 M4053: EL COLOR DEL DESTELLO SE CONGELA, NO SE MIRA EN VIVO.
   --
   -- El destello duraba 0,5 s pero su color salia de senales que para entonces YA HAN CAIDO:
   -- en cuanto el firmware desmarca la opcion se va main_floppy_enable, y con el scan_done,
   -- fmt_done y los rechazos. El color se descolgaba hasta el ultimo 'else' de la cascada, que
   -- es VERDE. O sea que el indicador decia 'todo bien' pasara lo que pasara, incluido un
   -- rechazo. M4051 arreglo el DISPARO del destello; esto arregla lo que el destello DICE.
   --
   -- Y se empeoro solo al hacer que M4052 borrase el bit del menu al instante en vez de esperar
   -- a que el menu volviera: el margen para leer el color en vivo paso de segundos a
   -- milisegundos. Automatizar la limpieza de un estado rompe lo que dependia de que durase;
   -- van cinco veces en este subsistema.
   -- CPC4MEGA65 M4056: EL RECHAZO ENGANCHADO SOLO SIGNIFICA ALGO MIENTRAS SE ESCRIBE.
   --
   -- M4054 hizo refused_o pegajoso hasta la operacion de ESCRITURA siguiente, porque duraba dos
   -- ciclos y el LED lo miraba tarde. Efecto secundario: floppy_write solo ve el enable de
   -- escritura, asi que una LECTURA posterior no lo limpia y se encuentra un rechazo ajeno.
   --
   -- En M4054 tape UN consumidor -el color congelado del destello- y no busque los demas EN EL
   -- MISMO FICHERO. Habia dos mas en la cascada de color en vivo, y el usuario lo vio a la
   -- primera: tras un formateo rechazado, la lectura siguiente PARPADEABA EN ROJO todo el
   -- recorrido y solo al terminar se ponia verde.
   --
   -- Por eso se acota UNA VEZ, aqui, en vez de en cada sitio: el proximo que necesite "se ha
   -- negado" coge esta senal y no puede equivocarse.
   main_floppy_refus_now <= main_floppy_fmt_refus and main_floppy_fmt_en;

   -- M4054: el orden de esta cascada ES la respuesta, y cambia dos cosas respecto a M4053.
   --
   -- 1. LA UNIDAD VACIA MANDA sobre el rechazo. Son dos formas de no escribir, pero "no hay
   --    disquete" es la causa concreta y accionable; "se nego" sin mas no le dice al usuario
   --    que hacer.
   --
   -- 2. El rechazo del formateador solo cuenta SI ESTAMOS ESCRIBIENDO: ver main_floppy_refus_now.
   led_end_col <= x"FF8000" when main_floppy_no_disk = '1' else
                  x"FF0000" when (main_floppy_refus_now = '1' or
                                  main_floppy_copy_refus = '1') else
                  x"FF8000" when main_floppy_bad_trk /= "00000" else
                  x"FF8000" when (main_floppy_fmt_en = '1' and
                                  main_floppy_wrote_ok = '0') else
                  x"00FF00";

   led_oneshot_proc : process (main_clk)
   begin
      if rising_edge(main_clk) then
            -- M4055: EL DESTELLO ES DEL FINAL DE LA OPERACION, Y fmt_done ES POR PISTA.
            --
            -- fmt_done pulsa UNA VEZ POR PISTA - lo dice su propio comentario desde M4047, y aun
            -- asi seguia aqui dentro. No molestaba mientras el destello estaba condicionado a
            -- led_finished, porque entonces se apagaba solo. Al soltarlo en M4053 para que el
            -- color congelado se viera pase lo que pase, cada pista paso a relanzar medio segundo
            -- de destello: con una pista cada ~200 ms el verde NO SE APAGA NUNCA y se come el
            -- BLANCO de "formateando", que es la unica senal de que la cosa avanza.
            --
            -- El final de la OPERACION es main_floppy_op_end, que ya existe desde M4047 y es
            -- exactamente esto. Se usa ese y se acabo la duplicidad.
            done_d     <= main_floppy_op_end;
            fin_edge   <= main_floppy_op_end and not done_d;

         if fin_edge = '1' then
            led_res_col <= led_end_col;   -- M4053: congelar el RESULTADO
            oneshot_cnt <= C_ONESHOT;
         elsif oneshot_cnt /= 0 then
            oneshot_cnt <= oneshot_cnt - 1;
         end if;
      end if;
   end process led_oneshot_proc;

   -- M4034: un rechazo de la copia tambien es un FINAL, y ademas es el que mas falta hace
   -- avisar: llega en microsegundos, antes de que la mecanica se mueva, y sin esto el usuario
   -- marcaria la opcion y no pasaria absolutamente nada.
   -- M4055: fuera fmt_done tambien de aqui, y por el mismo motivo. Con el dentro, "la operacion
   -- ha terminado" era cierto 40 veces durante un formateo, asi que el LED se apagaba entre
   -- pistas ('0' when led_finished) en vez de mostrar el blanco de que se esta escribiendo.
   -- main_floppy_op_end ya dice esto bien.
   led_finished <= main_floppy_op_end;

   floppy_led_on  <= '1' when oneshot_cnt /= 0 else
                     '0' when led_finished = '1' else
                     blink_on                     when main_floppy_mfm_done = '1' and blink_count /= "00000" else
                     '1'                          when main_floppy_mfm_done = '1' else
                     main_floppy_blink            when (main_floppy_ready = '1' and main_floppy_disk_in = '1') else
                     '1';
   -- Cuando hay recuento, el COLOR dice ademas de que densidad es el disquete que se ha
   -- conseguido leer: VERDE = DD (250 kbps, la del CPC), CIAN = HD (500 kbps).
   -- CPC4MEGA65 M4C1: el formateo tiene su propio codigo de colores, y manda sobre el resto.
   --   BLANCO    = formateando (f_wgate_o activo: se esta escribiendo de verdad)
   --   AZUL      = terminado y los sectores leidos llevan numeracion &Cx -> ES NUESTRO FORMATO
   --   NARANJA   = terminado pero los sectores siguen con numeracion de PC -> no se escribio
   --   ROJO fijo = rechazado, el disquete esta protegido contra escritura
   --
   -- M4013: el MAGENTA se cambia por AZUL a peticion del usuario - en el LED RGB de la MEGA65
   -- el magenta tira a blanco rosado y no se distingue con seguridad, y la distincion
   -- "formato CPC / formato PC" es justo la que tiene que leerse sin dudar. El azul que
   -- ocupaba "formateando" pasa a BLANCO (es un estado transitorio, solo hace falta ver que
   -- algo esta pasando) y el blanco que ocupaba "formateado sin mas" pasa a AMARILLO.
   -- La distincion magenta/naranja es la que hace util la prueba: sobre un disco de PC, que
   -- salgan 9 sectores NO distingue "he formateado bien" de "no he escrito nada", porque su
   -- pista 0 ya tenia 9. El numero de sector si lo distingue.
   -- M4033: al terminar, solo dos colores y sin ambiguedad.
   --   VERDE = todo correcto
   --   AMBAR = hubo sectores o pistas defectuosas
   -- Lo demas (densidad, numeracion CPC, estados del formateo) ya lo dice el volcado con
   -- mucho mas detalle; el LED solo tiene que responder "ha ido bien o no".
   floppy_led_col <= led_res_col when oneshot_cnt /= 0 else   -- M4053
                     x"00FF00" when (led_finished = '1' and main_floppy_bad_trk = "00000"
                                     and main_floppy_refus_now = '0'
                                      and main_floppy_copy_refus = '0'
                                      -- M4039: y que se haya ESCRITO de verdad. Sin esto el
                                      -- verde salio 40 veces seguidas con la puerta abierta
                                      -- 50 ciclos. Un indicador que no puede decir que no,
                                      -- no informa.
                                      and (main_floppy_wrote_ok = '1' or
                                           main_floppy_fmt_en = '0')) else
                     x"FF8000" when led_finished = '1' else
                     x"FF0000" when main_floppy_refus_now = '1' else
                     x"FFFFFF" when main_floppy_fmt_busy  = '1' else
                     x"0000FF" when (main_floppy_fmt_done = '1' and main_floppy_id_cpc = '1') else
                     x"FF8000" when (main_floppy_fmt_done = '1' and main_floppy_fmt_full = '1') else
                     x"FFFF00" when main_floppy_fmt_done  = '1' else
                     x"FF0000" when main_floppy_error = '1' else
                     -- Al terminar un recorrido, AZUL si los sectores llevan numeracion del
                     -- CPC (&Cx). Sirve para dos cosas: confirmar que un disquete es formato
                     -- CPC, y -tras formatear y volver a leer- confirmar que lo que escribimos
                     -- se puede leer. Sin esto, el resultado del formateo no era comprobable.
                     x"0000FF" when (main_floppy_scan_done = '1' and main_floppy_bad_trk = "00000"
                                     and main_floppy_id_cpc = '1') else
                     x"00FF00" when (main_floppy_scan_done = '1' and main_floppy_bad_trk = "00000") else
                     x"FF0000" when main_floppy_scan_done = '1' else
                     x"00FFFF" when (main_floppy_mfm_done = '1' and main_floppy_is_hd = '1') else
                     x"00FF00" when main_floppy_mfm_done = '1' else
                     x"FFFF00" when main_floppy_busy  = '1' else
                     x"00FF00";

   -- M4033: el subsistema de la disquetera fisica se queda el LED mientras opera y durante el
   -- destello final; cuando ese destello se apaga lo DEVUELVE al LED normal de unidad. Antes se
   -- lo quedaba para siempre mientras la opcion estuviera marcada en el menu, asi que tras una
   -- lectura ya no se veia la actividad del u765.
   floppy_led_own <= '1' when (main_floppy_enable = '1' and
                               not (led_finished = '1' and oneshot_cnt = 0))
                              -- M4045: el destello se queda con el LED hasta que expire, pase lo
                              -- que pase con la opcion del menu. Hace falta porque desde esta
                              -- build el firmware la DESMARCA SOLA en cuanto la operacion
                              -- termina, y eso tira main_floppy_enable en milisegundos: sin
                              -- esto, la funcion nueva se cargaria la senal de 'ha ido bien o
                              -- mal' que se puso a peticion del usuario en M4033.
                              or oneshot_cnt /= 0 else '0';

   -- M4035: AMARILLO MIENTRAS QUEDE ALGO SIN VOLCAR AL DISQUETE.
   --
   -- Copiado de AExp (mega65.vhd:812-813), que hace lo mismo con sus pistas sucias de .adf. Es
   -- la unica proteccion real contra sacar el disquete con datos a medias: ningun plazo puede
   -- garantizar nada, pero una senal de 'todavia no' si. Apagado = todo escrito.
   --
   -- Manda sobre el LED de unidad normal pero NO sobre el de la disquetera fisica: mientras se
   -- esta escribiendo de verdad, lo que hay que ver es el estado de la operacion.
   --
   -- Si se queda amarillo para siempre es que hay una pista sucia que NO se pudo leer entera y
   -- por tanto no se puede regrabar. Es desagradable a proposito: esos datos no han llegado al
   -- disquete y no van a llegar.
   main_drive_led_o     <= floppy_led_on when floppy_led_own = '1' else
                           '1'           when main_floppy_wb_pending = '1' else
                           (main_drive_active or main_cache_busy);
   main_drive_led_col_o <= floppy_led_col when floppy_led_own = '1' else
                           x"FFFF00"      when main_floppy_wb_pending = '1' else
                           x"0000FF"      when main_cache_busy = '1' else
                           x"FF0000";

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

