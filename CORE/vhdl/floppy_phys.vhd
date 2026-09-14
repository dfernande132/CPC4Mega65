---------------------------------------------------------------------------------------------------------
-- CPC4MEGA65 - Milestone 4, fase A: control fisico de la disquetera interna del MEGA65
--
-- Esta fase NO lee datos todavia: solo mueve el hierro y comprueba que responde. Es decir,
-- motor, seleccion de unidad, movimiento de cabeza con recalibrado a pista 0, y deteccion del
-- pulso de indice. El separador de datos MFM es la fase B.
--
-- Por que existe este fichero y no se ha portado de ningun sitio: comprobado por busqueda
-- directa, NINGUNO de los cores hermanos (QL4M65, C64MEGA65, AExp) usa las señales f_* - en los
-- tres estan atadas a valor inactivo en top_mega65-r6.vhd y ni siquiera aparecen en
-- framework.vhd. Ver .research/PORTING-PLAN.md seccion 11.
--
-- POLARIDADES: el interfaz Shugart/PC es activo a nivel BAJO en practicamente todo. Las que
-- son seguras (motor, select, step, track0, index, writeprotect activos bajos) van marcadas
-- como tal; las que conviene confirmar contra hardware real (sentido de f_stepdir_o y el
-- criterio de f_density_o) van marcadas con "VERIFICAR". El recalibrado esta escrito para que
-- una polaridad equivocada de stepdir se DETECTE (se acaban los pasos sin encontrar pista 0)
-- en vez de quedarse en silencio: ver el estado S_ERROR y como lo refleja el LED.
--
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
---------------------------------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity floppy_phys is
   generic (
      G_CLK_HZ    : natural := 64_000_000
   );
   port (
      clk_i          : in  std_logic;
      rst_i          : in  std_logic;

      -- Control
      enable_i       : in  std_logic;                     -- '1' = encender motor y recalibrar
      -- Selector de densidad hacia la disquetera (DENSEL/REDWC). SOLO afecta a la ESCRITURA:
      -- controla la corriente de grabacion, no la velocidad de datos, que la genera el core.
      -- Su polaridad varia entre modelos de disquetera y es el unico parametro de M4 que
      -- seguia sin verificar, precisamente porque leer no depende de el. Se saca al menu para
      -- poder probar las dos sin recompilar.
      density_i      : in  std_logic;
      -- Busqueda de pista: se pulsa seek_start_i con la pista deseada en seek_track_i. Solo se
      -- acepta con ready_o a '1' (o sea, ya recalibrado), porque hasta entonces no se sabe
      -- donde esta la cabeza.
      seek_track_i   : in  std_logic_vector(6 downto 0);
      seek_start_i   : in  std_logic;

      -- Estado (dominio del core)
      busy_o         : out std_logic;                     -- girando/buscando, aun sin resultado
      ready_o        : out std_logic;                     -- recalibrado OK, cabeza en pista 0
      error_o        : out std_logic;                     -- recalibrado fallido (ver arriba)
      index_pulse_o  : out std_logic;                     -- 1 ciclo por pulso de indice
      disk_in_o      : out std_logic;                     -- se han visto pulsos de indice hace poco
      write_prot_o   : out std_logic;                     -- disquete protegido contra escritura
      track_o        : out std_logic_vector(6 downto 0);  -- pista actual conocida

      -- Pines de la disquetera (interfaz Shugart de la placa)
      f_density_o    : out std_logic;
      f_motora_o     : out std_logic;
      f_motorb_o     : out std_logic;
      f_selecta_o    : out std_logic;
      f_selectb_o    : out std_logic;
      f_side1_o      : out std_logic;
      f_stepdir_o    : out std_logic;
      f_step_o       : out std_logic;
      f_wdata_o      : out std_logic;
      f_wgate_o      : out std_logic;
      f_index_i      : in  std_logic;
      f_track0_i     : in  std_logic;
      f_writeprotect_i : in std_logic;
      f_diskchanged_i  : in std_logic;
      f_rdata_i        : in std_logic
   );
end floppy_phys;

architecture beh of floppy_phys is

   ------------------------------------------------------------------------------------------
   -- Constantes de tiempo, derivadas del reloj para no depender de que sea 64MHz
   ------------------------------------------------------------------------------------------
   -- Arranque del motor: la especificacion de las 3,5" pide de 500ms a 1s hasta velocidad
   -- estable. Se usa 1s, que no molesta (esto ocurre una vez al montar) y evita leer durante
   -- la aceleracion.
   constant C_SPINUP_CYC   : natural := G_CLK_HZ;                 -- 1 s
   -- Ancho del pulso de step: la especificacion pide >= 1us. 4us da margen de sobra.
   constant C_STEP_CYC     : natural := (G_CLK_HZ / 1_000_000) * 4;
   -- Periodo entre pasos: 3ms es el valor conservador que aceptan todas las 3,5".
   constant C_STEPRATE_CYC : natural := (G_CLK_HZ / 1000) * 3;
   -- Asentamiento de la cabeza tras el ultimo paso.
   constant C_SETTLE_CYC   : natural := (G_CLK_HZ / 1000) * 15;   -- 15 ms
   -- Limite de pasos del recalibrado. Una 3,5" tiene 80 pistas; 90 pasos es "mas que de sobra".
   -- Si se agotan sin ver f_track0_i, algo esta mal (sentido de stepdir, cable, sin disquetera)
   -- y se va a S_ERROR en vez de seguir golpeando el tope mecanico.
   constant C_RECAL_MAX    : natural := 90;
   -- "Hay disco": el indice llega cada 200ms a 300 RPM. Si pasan 500ms sin verlo, se considera
   -- que no hay disquete (o no gira).
   constant C_INDEX_TO_CYC : natural := (G_CLK_HZ / 1000) * 500;

   ------------------------------------------------------------------------------------------
   -- Polaridades. El interfaz es activo bajo; se dan nombre para que el codigo se lea solo.
   ------------------------------------------------------------------------------------------
   constant C_ACTIVE   : std_logic := '0';   -- señal activa (motor on, drive select, step...)
   constant C_INACTIVE : std_logic := '1';
   -- VERIFICAR en hardware: en el interfaz PC estandar /DIR a nivel ALTO = paso hacia AFUERA
   -- (hacia la pista 0) y a nivel BAJO = hacia adentro. Si estuviera al reves, el recalibrado
   -- no encontrara nunca la pista 0 y terminara en S_ERROR - que es exactamente el sintoma que
   -- el LED hace visible, asi que se detecta en la primera prueba en vez de quedar oculto.
   constant C_DIR_OUT  : std_logic := '1';   -- hacia pista 0
   constant C_DIR_IN   : std_logic := '0';   -- hacia pistas altas
   -- VERIFICAR en hardware: DENSEL/REDWC. En 3,5", nivel ALTO = doble densidad (250 kbps), que
   -- es lo que necesita el formato del CPC. Es la unica opcion sensata aqui, pero conviene
   -- confirmarla cuando en la fase B se lea flujo de verdad.
   constant C_DENSITY_DD : std_logic := '1';

   type t_state is (S_IDLE, S_SPINUP, S_RECAL_CHK, S_STEP_PULSE, S_STEP_WAIT,
                    S_SETTLE, S_READY, S_ERROR,
                    S_SEEK_CHK, S_SEEK_PULSE, S_SEEK_WAIT, S_SEEK_SETTLE);
   signal state      : t_state := S_IDLE;

   signal timer      : natural range 0 to C_SPINUP_CYC := 0;
   signal step_cnt   : natural range 0 to C_RECAL_MAX  := 0;
   signal track      : unsigned(6 downto 0) := (others => '0');
   signal seek_dest  : unsigned(6 downto 0) := (others => '0');

   -- Sincronizacion de las entradas asincronas que vienen del cable de la disquetera.
   -- No es opcional: son señales de un periferico externo sin ninguna relacion de fase con
   -- clk_i, y ademas f_index_i/f_rdata_i se usan por flanco.
   signal index_sr   : std_logic_vector(2 downto 0) := (others => '1');
   signal track0_sr  : std_logic_vector(2 downto 0) := (others => '1');
   signal wprot_sr   : std_logic_vector(2 downto 0) := (others => '1');

   signal index_pulse : std_logic := '0';
   signal index_timer : natural range 0 to C_INDEX_TO_CYC := C_INDEX_TO_CYC;

   signal step_n     : std_logic := C_INACTIVE;
   signal dir_n      : std_logic := C_DIR_OUT;
   signal motor_n    : std_logic := C_INACTIVE;
   signal select_n   : std_logic := C_INACTIVE;

begin

   ------------------------------------------------------------------------------------------
   -- Sincronizadores de entrada y deteccion del pulso de indice
   ------------------------------------------------------------------------------------------
   sync_proc : process (clk_i)
   begin
      if rising_edge(clk_i) then
         index_sr  <= index_sr(1 downto 0)  & f_index_i;
         track0_sr <= track0_sr(1 downto 0) & f_track0_i;
         wprot_sr  <= wprot_sr(1 downto 0)  & f_writeprotect_i;

         -- Flanco de bajada del indice (activo bajo) = una vuelta completa del disco
         if index_sr(2) = '1' and index_sr(1) = '0' then
            index_pulse <= '1';
            index_timer <= C_INDEX_TO_CYC;
         else
            index_pulse <= '0';
            if index_timer /= 0 then
               index_timer <= index_timer - 1;
            end if;
         end if;
      end if;
   end process sync_proc;

   index_pulse_o <= index_pulse;
   disk_in_o     <= '1' when index_timer /= 0 else '0';
   write_prot_o  <= '1' when wprot_sr(2) = C_ACTIVE else '0';
   track_o       <= std_logic_vector(track);

   ------------------------------------------------------------------------------------------
   -- Maquina de estados: arranque de motor y recalibrado a pista 0
   ------------------------------------------------------------------------------------------
   fsm_proc : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if rst_i = '1' then
            state    <= S_IDLE;
            timer    <= 0;
            step_cnt <= 0;
            track    <= (others => '0');
            motor_n  <= C_INACTIVE;
            select_n <= C_INACTIVE;
            step_n   <= C_INACTIVE;
            dir_n    <= C_DIR_OUT;
         else
            step_n <= C_INACTIVE;          -- el pulso de step dura solo lo que dice S_RECAL_STEP

            case state is

               when S_IDLE =>
                  motor_n  <= C_INACTIVE;
                  select_n <= C_INACTIVE;
                  step_cnt <= 0;
                  if enable_i = '1' then
                     -- Seleccion y motor a la vez: la unidad interna del MEGA65 es la A.
                     select_n <= C_ACTIVE;
                     motor_n  <= C_ACTIVE;
                     timer    <= C_SPINUP_CYC - 1;
                     state    <= S_SPINUP;
                  end if;

               when S_SPINUP =>
                  if enable_i = '0' then
                     state <= S_IDLE;
                  elsif timer = 0 then
                     dir_n    <= C_DIR_OUT;      -- recalibrar = ir hacia la pista 0
                     step_cnt <= 0;
                     state    <= S_RECAL_CHK;
                  else
                     timer <= timer - 1;
                  end if;

               -- Decide si hace falta otro paso. La pista 0 se comprueba ANTES de cada paso,
               -- para no golpear el tope mecanico cuando la cabeza ya esta en el extremo.
               when S_RECAL_CHK =>
                  if enable_i = '0' then
                     state <= S_IDLE;
                  elsif track0_sr(2) = C_ACTIVE then
                     track <= (others => '0');
                     timer <= C_SETTLE_CYC - 1;
                     state <= S_SETTLE;
                  elsif step_cnt = C_RECAL_MAX then
                     -- Pasos agotados sin ver la pista 0. Ver el comentario de C_DIR_OUT: es el
                     -- sintoma de una polaridad de stepdir equivocada, de un cable mal, o de que
                     -- no hay disquetera. Se para aqui en vez de seguir empujando la cabeza.
                     state <= S_ERROR;
                  else
                     step_cnt <= step_cnt + 1;
                     timer    <= C_STEP_CYC - 1;
                     state    <= S_STEP_PULSE;
                  end if;

               -- Pulso de step activo durante C_STEP_CYC
               when S_STEP_PULSE =>
                  step_n <= C_ACTIVE;
                  if timer = 0 then
                     timer <= C_STEPRATE_CYC - 1;
                     state <= S_STEP_WAIT;
                  else
                     timer <= timer - 1;
                  end if;

               -- Espera entre pasos (step_n vuelve solo a inactivo por el valor por defecto)
               when S_STEP_WAIT =>
                  if timer = 0 then
                     state <= S_RECAL_CHK;
                  else
                     timer <= timer - 1;
                  end if;

               when S_SETTLE =>
                  if enable_i = '0' then
                     state <= S_IDLE;
                  elsif timer = 0 then
                     state <= S_READY;
                  else
                     timer <= timer - 1;
                  end if;

               when S_READY =>
                  if enable_i = '0' then
                     state <= S_IDLE;
                  elsif seek_start_i = '1' then
                     seek_dest <= unsigned(seek_track_i);
                     state     <= S_SEEK_CHK;
                  end if;

               -- Busqueda: se dan pasos de uno en uno hasta llegar a la pista pedida. La
               -- direccion se decide en cada paso comparando con el destino, no de una vez,
               -- para que el contador de pista y el movimiento real no puedan desincronizarse.
               when S_SEEK_CHK =>
                  if enable_i = '0' then
                     state <= S_IDLE;
                  elsif track = seek_dest then
                     timer <= C_SETTLE_CYC - 1;
                     state <= S_SEEK_SETTLE;
                  elsif track0_sr(2) = C_ACTIVE and seek_dest = 0 then
                     -- Ya en el tope exterior: la pista 0 fisica manda sobre el contador
                     track <= (others => '0');
                     timer <= C_SETTLE_CYC - 1;
                     state <= S_SEEK_SETTLE;
                  else
                     if track < seek_dest then
                        dir_n <= C_DIR_IN;
                        track <= track + 1;
                     else
                        dir_n <= C_DIR_OUT;
                        track <= track - 1;
                     end if;
                     timer <= C_STEP_CYC - 1;
                     state <= S_SEEK_PULSE;
                  end if;

               when S_SEEK_PULSE =>
                  step_n <= C_ACTIVE;
                  if timer = 0 then
                     timer <= C_STEPRATE_CYC - 1;
                     state <= S_SEEK_WAIT;
                  else
                     timer <= timer - 1;
                  end if;

               when S_SEEK_WAIT =>
                  if timer = 0 then
                     state <= S_SEEK_CHK;
                  else
                     timer <= timer - 1;
                  end if;

               when S_SEEK_SETTLE =>
                  if enable_i = '0' then
                     state <= S_IDLE;
                  elsif timer = 0 then
                     state <= S_READY;
                  else
                     timer <= timer - 1;
                  end if;

               when S_ERROR =>
                  -- Se queda aqui, con el motor girando, hasta que se desactive: asi el LED
                  -- puede mostrar el fallo de forma estable en vez de un parpadeo que se escape.
                  if enable_i = '0' then
                     state <= S_IDLE;
                  end if;

            end case;
         end if;
      end if;
   end process fsm_proc;

   busy_o  <= '1' when (state = S_SPINUP or state = S_RECAL_CHK or state = S_STEP_PULSE or
                        state = S_STEP_WAIT or state = S_SETTLE or state = S_SEEK_CHK or
                        state = S_SEEK_PULSE or state = S_SEEK_WAIT or
                        state = S_SEEK_SETTLE) else '0';
   -- ready_o solo en S_READY: durante una busqueda vale '0', que es lo que usa el orquestador
   -- para saber cuando la cabeza ya esta colocada.
   ready_o <= '1' when state = S_READY else '0';
   error_o <= '1' when state = S_ERROR else '0';

   ------------------------------------------------------------------------------------------
   -- Salidas hacia el cable
   ------------------------------------------------------------------------------------------
   f_motora_o  <= motor_n;
   f_selecta_o <= select_n;
   f_step_o    <= step_n;
   f_stepdir_o <= dir_n;

   -- La unidad B no existe en el MEGA65: se deja inactiva.
   f_motorb_o  <= C_INACTIVE;
   f_selectb_o <= C_INACTIVE;

   -- Cara 0 mientras no haya lectura de datos (fase B). Activo bajo, asi que '1' = cara 0.
   f_side1_o   <= C_INACTIVE;

   f_density_o <= density_i;

   -- Escritura desactivada por completo en esta fase (es la fase C). Dejar wgate inactivo no es
   -- cosmetico: con wgate activo por accidente la disquetera borraria el disquete.
   f_wgate_o   <= C_INACTIVE;
   f_wdata_o   <= C_INACTIVE;

end architecture beh;
