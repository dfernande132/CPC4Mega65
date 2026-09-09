---------------------------------------------------------------------------------------------------------
-- MiSTer2MEGA65 Framework
--
-- CPC4MEGA65 keyboard controller
--
-- Sustituye el submodulo original `hid` (rtl/hid.sv, dentro de Amstrad_motherboard.v) que
-- traduce codigos PS/2 a la matriz del Amstrad CPC. En vez de sintetizar codigos PS/2 falsos
-- desde las teclas del MEGA65, este modulo habla directamente el protocolo de matriz que
-- Amstrad_motherboard.v expone hacia fuera (fila Y desde el i8255/PPI, columna X hacia el
-- YM2149/PSG) - mismo patron que QL4M65 y C64MEGA65 (su keyboard.vhd tambien sustituye el
-- traductor PS/2 original del core en vez de alimentarlo con PS/2 sintetico).
--
-- Tabla fila/columna extraida directamente de rtl/hid.sv (no de documentacion externa) -
-- ver core/.research/PORTING-PLAN.md seccion "M1B" para el detalle de por que cada tecla
-- va donde va y que se ha dejado fuera de M1 a proposito:
--   - las teclas del teclado numerico dedicado del CPC (Enter/./Copiar propios, distintos
--     de los de la fila principal) no tienen equivalente directo en el MEGA65 - sin mapear.
--   - los simbolos [ ] \ y las F-teclas F0/F2/F4/F6/F8 del keypad del CPC tampoco tienen
--     tecla MEGA65 dedicada - sin mapear (perdida menor, no bloquea arrancar ni escribir).
--   - la superposicion de joystick-como-teclado (filas Y=6/Y=9 en hid.sv) llega en Milestone 3,
--     ver la seccion "Joystick" mas abajo.
--
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
---------------------------------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity keyboard is
   port (
      clk_main_i           : in std_logic;               -- core clock

      -- Interface to the MEGA65 keyboard
      key_num_i            : in integer range 0 to 79;   -- cycles through all MEGA65 keys
      key_pressed_n_i      : in std_logic;               -- low active: debounced feedback: is kb_key_num_i pressed right now?

      -- CPC4MEGA65: matriz de teclado del Amstrad_motherboard (rtl/Amstrad_motherboard.v,
      -- puertos Y/X del submodulo hid original, ahora sustituido)
      cpc_row_i            : in  std_logic_vector(3 downto 0);  -- Y: fila seleccionada (desde i8255 portC[3:0])
      cpc_col_o            : out std_logic_vector(7 downto 0);  -- X: columna leida (hacia YM2149 IOA_in), activo bajo

      -- CPC4MEGA65 M3: joysticks, ya en ACTIVO ALTO (main.vhd invierte lo que da el framework)
      -- y en el orden de bits del CPC: 0=Arriba 1=Abajo 2=Izquierda 3=Derecha 4=Fire1 5=Fire2
      -- 6=Fire3. Fire2/Fire3 se dejan a '0' desde main.vhd: el puerto del MEGA65 solo da un
      -- boton (ver el comentario de la seccion "Joystick" mas abajo).
      joy1_i               : in  std_logic_vector(6 downto 0);  -- joystick 0 del CPC -> fila 9
      joy2_i               : in  std_logic_vector(6 downto 0)   -- joystick 1 del CPC -> fila 6
   );
end keyboard;

architecture beh of keyboard is

-- MEGA65 key codes that kb_key_num_i is using while
-- kb_key_pressed_n_i is signalling (low active) which key is pressed
constant m65_ins_del       : integer := 0;
constant m65_return        : integer := 1;
constant m65_horz_crsr     : integer := 2;   -- cursor right
constant m65_f7            : integer := 3;
constant m65_f1            : integer := 4;
constant m65_f3            : integer := 5;
constant m65_f5            : integer := 6;
constant m65_vert_crsr     : integer := 7;   -- cursor down
constant m65_3             : integer := 8;
constant m65_w             : integer := 9;
constant m65_a             : integer := 10;
constant m65_4             : integer := 11;
constant m65_z             : integer := 12;
constant m65_s             : integer := 13;
constant m65_e             : integer := 14;
constant m65_left_shift    : integer := 15;
constant m65_5             : integer := 16;
constant m65_r             : integer := 17;
constant m65_d             : integer := 18;
constant m65_6             : integer := 19;
constant m65_c             : integer := 20;
constant m65_f             : integer := 21;
constant m65_t             : integer := 22;
constant m65_x             : integer := 23;
constant m65_7             : integer := 24;
constant m65_y             : integer := 25;
constant m65_g             : integer := 26;
constant m65_8             : integer := 27;
constant m65_b             : integer := 28;
constant m65_h             : integer := 29;
constant m65_u             : integer := 30;
constant m65_v             : integer := 31;
constant m65_9             : integer := 32;
constant m65_i             : integer := 33;
constant m65_j             : integer := 34;
constant m65_0             : integer := 35;
constant m65_m             : integer := 36;
constant m65_k             : integer := 37;
constant m65_o             : integer := 38;
constant m65_n             : integer := 39;
constant m65_plus          : integer := 40;
constant m65_p             : integer := 41;
constant m65_l             : integer := 42;
constant m65_minus         : integer := 43;
constant m65_dot           : integer := 44;
constant m65_colon         : integer := 45;
constant m65_at            : integer := 46;
constant m65_comma         : integer := 47;
constant m65_gbp           : integer := 48;
constant m65_asterisk      : integer := 49;
constant m65_semicolon     : integer := 50;
constant m65_clr_home      : integer := 51;
constant m65_right_shift   : integer := 52;
constant m65_equal         : integer := 53;
constant m65_arrow_up      : integer := 54;  -- symbol, not cursor
constant m65_slash         : integer := 55;
constant m65_1             : integer := 56;
constant m65_arrow_left    : integer := 57;  -- symbol, not cursor
constant m65_ctrl          : integer := 58;
constant m65_2             : integer := 59;
constant m65_space         : integer := 60;
constant m65_mega          : integer := 61;
constant m65_q             : integer := 62;
constant m65_run_stop      : integer := 63;
constant m65_no_scrl       : integer := 64;
constant m65_tab           : integer := 65;
constant m65_alt           : integer := 66;
constant m65_help          : integer := 67;
constant m65_f9            : integer := 68;
constant m65_f11           : integer := 69;
constant m65_f13           : integer := 70;
constant m65_esc           : integer := 71;
constant m65_capslock      : integer := 72;
constant m65_up_crsr       : integer := 73;  -- cursor up
constant m65_left_crsr     : integer := 74;  -- cursor left
constant m65_restore       : integer := 75;

-- Un bit por tecla del MEGA65 (1 = pulsada), indexado directamente por key_num_i - igual que
-- el key_pressed_n de la plantilla, solo que aqui en activo alto para que sea directo de
-- combinar con OR (necesario para Left/Right Shift, que comparten una unica posicion en la
-- matriz real del CPC - ver mas abajo).
signal key_state  : std_logic_vector(79 downto 0) := (others => '0');

-- Matriz del CPC: 10 filas x 8 columnas = 80 bits, activo alto (1 = pulsada), misma
-- convencion que el array key[16][8] de rtl/hid.sv. Indice = fila*8 + columna.
signal key_matrix : std_logic_vector(79 downto 0);

-- CPC4MEGA65 M3: joystick colocado ya en la forma de una fila de la matriz (bit 7 = teclado)
signal joy_row9   : std_logic_vector(7 downto 0);
signal joy_row6   : std_logic_vector(7 downto 0);

begin

   ---------------------------------------------------------------------------------------
   -- Captura el estado de cada tecla del MEGA65 (igual que el keyboard.vhd de la plantilla)
   ---------------------------------------------------------------------------------------
   keyboard_state : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         key_state(key_num_i) <= not key_pressed_n_i;
      end if;
   end process keyboard_state;

   ---------------------------------------------------------------------------------------
   -- Traduce a la matriz del CPC (combinacional). Left y Right Shift se combinan con OR
   -- porque ambos ocupan la misma posicion (fila 2, columna 5) en la matriz real del CPC.
   ---------------------------------------------------------------------------------------
   cpc_matrix : process (key_state)
   begin
      key_matrix <= (others => '0');

      -- Fila 0
      key_matrix(0)  <= key_state(m65_up_crsr);    -- Up
      key_matrix(1)  <= key_state(m65_horz_crsr);  -- Right
      key_matrix(2)  <= key_state(m65_vert_crsr);  -- Down
      key_matrix(3)  <= key_state(m65_f9);         -- F9
      key_matrix(5)  <= key_state(m65_f3);         -- F3
      -- bit4 (F6) y bits 6/7 (Enter/. del keypad dedicado del CPC): sin tecla MEGA65, no mapeados

      -- Fila 1
      key_matrix(8)  <= key_state(m65_left_crsr);  -- Left
      key_matrix(10) <= key_state(m65_f7);         -- F7
      key_matrix(12) <= key_state(m65_f5);         -- F5
      key_matrix(13) <= key_state(m65_f1);         -- F1
      -- bit1 (Copy/Insert del keypad), bit3 (F8), bit6 (F2), bit7 (F0): sin mapear

      -- Fila 2
      key_matrix(18) <= key_state(m65_return);     -- Enter (principal)
      key_matrix(21) <= key_state(m65_left_shift) or key_state(m65_right_shift); -- Shift
      key_matrix(23) <= key_state(m65_ctrl);       -- Ctrl
      -- bits 1/3/4/6 ([, ], F4, \): simbolos sin tecla MEGA65 dedicada, sin mapear

      -- Fila 3
      key_matrix(24) <= key_state(m65_arrow_up);   -- ^ (potencia en BASIC)
      key_matrix(25) <= key_state(m65_minus);      -- -
      key_matrix(26) <= key_state(m65_at);         -- @
      key_matrix(27) <= key_state(m65_p);          -- P
      key_matrix(28) <= key_state(m65_semicolon);  -- ;
      key_matrix(29) <= key_state(m65_colon);      -- :
      key_matrix(30) <= key_state(m65_slash);      -- /
      key_matrix(31) <= key_state(m65_dot);        -- .

      -- Fila 4
      key_matrix(32) <= key_state(m65_0);
      key_matrix(33) <= key_state(m65_9);
      key_matrix(34) <= key_state(m65_o);
      key_matrix(35) <= key_state(m65_i);
      key_matrix(36) <= key_state(m65_l);
      key_matrix(37) <= key_state(m65_k);
      key_matrix(38) <= key_state(m65_m);
      key_matrix(39) <= key_state(m65_comma);

      -- Fila 5
      key_matrix(40) <= key_state(m65_8);
      key_matrix(41) <= key_state(m65_7);
      key_matrix(42) <= key_state(m65_u);
      key_matrix(43) <= key_state(m65_y);
      key_matrix(44) <= key_state(m65_h);
      key_matrix(45) <= key_state(m65_j);
      key_matrix(46) <= key_state(m65_n);
      key_matrix(47) <= key_state(m65_space);

      -- Fila 6
      key_matrix(48) <= key_state(m65_6);
      key_matrix(49) <= key_state(m65_5);
      key_matrix(50) <= key_state(m65_r);
      key_matrix(51) <= key_state(m65_t);
      key_matrix(52) <= key_state(m65_g);
      key_matrix(53) <= key_state(m65_f);
      key_matrix(54) <= key_state(m65_b);
      key_matrix(55) <= key_state(m65_v);

      -- Fila 7
      key_matrix(56) <= key_state(m65_4);
      key_matrix(57) <= key_state(m65_3);
      key_matrix(58) <= key_state(m65_e);
      key_matrix(59) <= key_state(m65_w);
      key_matrix(60) <= key_state(m65_s);
      key_matrix(61) <= key_state(m65_d);
      key_matrix(62) <= key_state(m65_c);
      key_matrix(63) <= key_state(m65_x);

      -- Fila 8
      key_matrix(64) <= key_state(m65_1);
      key_matrix(65) <= key_state(m65_2);
      key_matrix(66) <= key_state(m65_esc);
      key_matrix(67) <= key_state(m65_q);
      key_matrix(68) <= key_state(m65_tab);
      key_matrix(69) <= key_state(m65_a);
      key_matrix(70) <= key_state(m65_capslock);
      key_matrix(71) <= key_state(m65_z);

      -- Fila 9: solo Delete/Backspace (bit 7). Los bits 0..6 son el joystick 0 del CPC y se
      -- superponen en el multiplexor de abajo, no aqui.
      key_matrix(79) <= key_state(m65_ins_del);
   end process cpc_matrix;

   ---------------------------------------------------------------------------------------
   -- CPC4MEGA65 M3: Joystick
   --
   -- En el CPC el joystick NO es un periferico aparte: son dos filas de la propia matriz de
   -- teclado, y el core original lo resuelve con un OR antes de invertir
   -- (rtl/hid.sv:41-48, "X = ~(key[Y] | joy1 | joy2 | mouse)"). Se replica igual.
   --
   --   Joystick 0 del CPC -> fila 9. Ahi solo teniamos mapeado el bit 7 (Delete), asi que los
   --                         bits 0..6 estaban libres: no pisa ninguna tecla.
   --   Joystick 1 del CPC -> fila 6. Esa fila SI tiene teclas reales (6 5 R T G F B V) y el
   --                         joystick se superpone encima, en paralelo. Eso no es un descuido:
   --                         es como esta cableado el CPC de verdad, y es la razon de que el
   --                         segundo joystick del CPC sea conocido por provocar pulsaciones
   --                         fantasma en esas teclas. Se reproduce tal cual.
   --
   -- Bit 7 a '0' en los dos casos: el joystick del CPC son 7 lineas (4 direcciones + 3 botones)
   -- y el bit 7 pertenece al teclado. Es lo mismo que hace hid.sv, donde joy1/joy2 son de 7
   -- bits y Verilog los extiende con cero al OR-earlos contra los 8 bits de X.
   ---------------------------------------------------------------------------------------

   joy_row9 <= '0' & joy1_i;
   joy_row6 <= '0' & joy2_i;

   ---------------------------------------------------------------------------------------
   -- Selecciona la fila pedida por el i8255 y la devuelve activa a nivel bajo (mismo
   -- convenio que "X = ~(key[Y] | ...)" en rtl/hid.sv). Filas >9 no existen en el CPC real
   -- (el array original tampoco las escribe nunca) - se devuelven como "nada pulsado".
   ---------------------------------------------------------------------------------------
   row_mux : process (cpc_row_i, key_matrix, joy_row6, joy_row9)
   begin
      case to_integer(unsigned(cpc_row_i)) is
         when 0      => cpc_col_o <= not key_matrix( 7 downto  0);
         when 1      => cpc_col_o <= not key_matrix(15 downto  8);
         when 2      => cpc_col_o <= not key_matrix(23 downto 16);
         when 3      => cpc_col_o <= not key_matrix(31 downto 24);
         when 4      => cpc_col_o <= not key_matrix(39 downto 32);
         when 5      => cpc_col_o <= not key_matrix(47 downto 40);
         when 6      => cpc_col_o <= not (key_matrix(55 downto 48) or joy_row6);
         when 7      => cpc_col_o <= not key_matrix(63 downto 56);
         when 8      => cpc_col_o <= not key_matrix(71 downto 64);
         when 9      => cpc_col_o <= not (key_matrix(79 downto 72) or joy_row9);
         when others => cpc_col_o <= (others => '1');
      end case;
   end process row_mux;

end beh;
