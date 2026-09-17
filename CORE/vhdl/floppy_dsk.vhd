---------------------------------------------------------------------------------------------------------
-- CPC4MEGA65 - Milestone 4, fase B2b-ii: construccion de la imagen .DSK en el buffer
--
-- Va escribiendo en el buffer de imagen de M2 una imagen .DSK equivalente al disquete fisico,
-- segun se va leyendo. El u765 y toda la cadena de M2 no se enteran de que el origen es un
-- disco real en vez de un fichero de la SD: ven una imagen normal.
--
-- GEOMETRIA, que cuadra exactamente con el formato DATA del CPC:
--   256 (info de disco) + 40 x (256 info de pista + 9 x 512 datos) = 194.816 bytes
-- que es justo el tamano de un .dsk estandar del CPC.
--
-- POR QUE NO HAY BUFFER DE PISTA INTERMEDIO: cada sector se escribe directamente en su sitio
-- final, calculando la direccion a partir de su identificador (ranura 0..8). El bloque de
-- informacion de pista se escribe al TERMINAR la pista, cuando ya se conoce la lista de
-- sectores, en una direccion que se conoce desde el principio. Efecto util de calcular la
-- direccion por identificador: si un sector falla el CRC y se relee en la vuelta siguiente,
-- sobrescribe exactamente el mismo sitio - es idempotente, sin logica extra.
--
-- Lo que el u765 lee de verdad de estas cabeceras (comprobado en rtl/u765/u765.sv:424-453):
--   byte 0x00      "M" (o "E" para extendido) - solo mira esa primera letra
--   byte 0x30      numero de pistas
--   byte 0x31      numero de caras
--   byte 0x33      tamano de pista en unidades de 256 bytes (0x13 = 19 -> 4864 bytes)
-- y despues, por pista, el bloque "Track-Info" para saber que sectores hay.
--
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
---------------------------------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity floppy_dsk is
   generic (
      G_TRACKS       : natural := 40;
      G_SECTORS      : natural := 9;       -- por pista, en formato DATA del CPC
      G_SECSIZE      : natural := 512;
      G_CLK_HZ       : natural := 64_000_000   -- M4019: para el contador de milisegundos
   );
   port (
      clk_i          : in  std_logic;
      rst_i          : in  std_logic;

      -- Control desde floppy_scan
      start_i        : in  std_logic;                     -- pulso: empieza una imagen nueva
      track_i        : in  std_logic_vector(6 downto 0);  -- pista que se esta leyendo AHORA
      track_done_i   : in  std_logic;                     -- pulso: pista terminada
      -- M4021: la pista a la que corresponde ese pulso. NO es track_i: cuando el pulso llega,
      -- el contador de floppy_scan ya se ha incrementado en el mismo flanco. Usar track_i aqui
      -- escribia cada cabecera en la ranura de la pista SIGUIENTE, dejaba la pista 0 sin
      -- cabecera y tiraba la de la 39 fuera de la imagen.
      done_track_i   : in  std_logic_vector(6 downto 0);
      sect_count_i   : in  std_logic_vector(4 downto 0);  -- sectores validos de esa pista

      -- Flujo de datos desde floppy_mfm
      data_byte_i    : in  std_logic_vector(7 downto 0);
      data_valid_i   : in  std_logic;
      data_offset_i  : in  std_logic_vector(10 downto 0);
      sec_slot_i     : in  std_logic_vector(4 downto 0);
      sec_ok_i       : in  std_logic;
      id_track_i     : in  std_logic_vector(7 downto 0);
      id_side_i      : in  std_logic_vector(7 downto 0);
      id_sector_i    : in  std_logic_vector(7 downto 0);
      id_size_i      : in  std_logic_vector(7 downto 0);

      -- Puerto de escritura del buffer de imagen (puerto B, libre desde M2)
      buf_addr_o     : out std_logic_vector(17 downto 0);
      buf_data_o     : out std_logic_vector(7 downto 0);
      buf_we_o       : out std_logic;

      -- Tamano final de la imagen, para anunciarla al montarla
      img_size_o     : out std_logic_vector(31 downto 0);
      busy_o         : out std_logic;

      -- M4019 TELEMETRIA. Se escribe DENTRO de las zonas no usadas de las cabeceras del
      -- propio .DSK, asi que el volcado a la SD sirve a la vez de diagnostico y de imagen
      -- verificable, y la imagen sigue siendo un .DSK valido que el u765 lee igual.
      --   * cabecera de disco, 0x34..0x47: telemetria global (los bytes 0x34.. solo los usa
      --     el formato EDSK para su tabla de tamanos por pista, y nosotros generamos "MV")
      --   * cabecera de pista, 0x60..0x6B: telemetria de esa pista (la lista de sectores
      --     ocupa 0x18..0x5F con 9 sectores, o sea que de 0x60 en adelante esta libre)
      -- Ver la tabla completa en la cabecera de la arquitectura.
      finish_i       : in  std_logic;                     -- pulso: recorrido terminado
      tlm_seen_i     : in  std_logic_vector(31 downto 0); -- IDs vistos en la pista
      tlm_revs_i     : in  std_logic_vector(3 downto 0);  -- vueltas consumidas
      tlm_idcrc_i    : in  std_logic_vector(15 downto 0); -- CRC de ID fallidos
      tlm_dtcrc_i    : in  std_logic_vector(15 downto 0); -- CRC de datos fallidos
      tlm_badtrk_i   : in  std_logic_vector(4 downto 0);
      tlm_poscode_i  : in  std_logic_vector(4 downto 0);
      tlm_flags_i    : in  std_logic_vector(7 downto 0);
      tlm_pllcells_i : in  std_logic_vector(15 downto 0);   -- M4024
      tlm_runts_i    : in  std_logic_vector(15 downto 0);   -- M4025
      tlm_u765_i     : in  std_logic_vector(15 downto 0);   -- M4028: estado interno del u765
      -- M4026: telemetria del FORMATEO, arrastrada hasta la siguiente lectura
      tlm_wgate_i    : in  std_logic_vector(31 downto 0);
      tlm_wdata_i    : in  std_logic_vector(31 downto 0);
      tlm_starts_i   : in  std_logic_vector(7 downto 0);
      tlm_refus_i    : in  std_logic_vector(7 downto 0);

      -- BUILD DE CONTROL C1: cuantos bytes de DATOS se han llegado a depositar en el buffer.
      -- Es el eslabon sin validar de toda la cadena: sabemos que la lectura MFM es exacta
      -- (el CRC de 512 bytes cuadra 9 veces por pista en 40 pistas) y sabemos que el firmware
      -- sirve los bloques DESDE el buffer (shell.asm:997, HANDLE_DRV_RD), pero nunca se ha
      -- comprobado que los bytes lleguen de uno a otro.
      --
      -- RESULTADO EN HARDWARE (C1, build M4012, 2026-09-13): codigo 5. Los bytes SI llegan al
      -- buffer y en cantidad, asi que el camino nucleo -> puerto B de la RAM de montaje queda
      -- validado. El 5 no era una anomalia: el recorrido hace siempre un minimo de dos vueltas
      -- por pista y floppy_mfm sacaba los datos en CADA decodificacion, o sea 2 x 40 x 9 x 512
      -- = 368.640. (La prediccion de "esperado 4" que se dio al usuario era incorrecta por no
      -- contar la relectura; el rango de la tabla si lo contemplaba.)
      --
      -- M4013: al escribir cada ranura UNA sola vez (ver floppy_mfm.vhd, campo 10) la cuenta
      -- baja a ~184.320 = 40 x 9 x 512. Ahora el codigo sirve de comprobacion del arreglo:
      --   1 = practicamente nada (<1.000)     -> no llega nada al buffer
      --   2 = 1.000 .. 50.000                 -> llega una fraccion
      --   3 = 50.000 .. 150.000               -> faltan sectores
      --   4 = 150.000 .. 250.000              -> ESPERADO a partir de M4013
      --   5 = mas de 250.000                  -> se sigue escribiendo por duplicado
      wr_code_o      : out std_logic_vector(4 downto 0)
   );
end floppy_dsk;

architecture beh of floppy_dsk is

   constant C_TRACK_SIZE : natural := 256 + G_SECTORS * G_SECSIZE;      -- 4864
   constant C_IMG_SIZE   : natural := 256 + G_TRACKS * C_TRACK_SIZE;    -- 194816

   -- CUIDADO CON "unsigned * natural" EN numeric_std. Esta definido como
   -- L * TO_UNSIGNED(R, L'LENGTH), o sea que el entero se convierte al ancho del OTRO operando.
   -- Aqui track_i son 7 bits, y TO_UNSIGNED(4864, 7) se desborda: 4864 mod 128 = 0, asi que
   -- "unsigned(track_i) * C_TRACK_SIZE" valia CERO para todas las pistas y las 40 se escribian
   -- unas encima de otras en la zona de la pista 0. El sintoma era un disco que se leia sin
   -- errores pero salia vacio: el directorio caia sobre datos sin usar, que en un disquete del
   -- CPC estan rellenos de 0xE5, justo el patron de "entrada de directorio libre".
   -- Por eso aqui se multiplica SIEMPRE por una constante con ancho explicito.
   constant C_TRKSZ_U    : unsigned(12 downto 0) := to_unsigned(C_TRACK_SIZE, 13);

   -- Cabecera del bloque de informacion de disco. Los 34 primeros bytes son la firma que
   -- identifica el fichero; el resto de la cabecera va a cero salvo los campos que se rellenan.
   type t_rom is array (natural range <>) of std_logic_vector(7 downto 0);
   constant C_DISK_SIG : t_rom(0 to 33) := (
      x"4D", x"56", x"20", x"2D", x"20", x"43", x"50", x"43",   -- "MV - CPC"
      x"45", x"4D", x"55", x"20", x"44", x"69", x"73", x"6B",   -- "EMU Disk"
      x"2D", x"46", x"69", x"6C", x"65", x"0D", x"0A", x"44",   -- "-File\r\nD"
      x"69", x"73", x"6B", x"2D", x"49", x"6E", x"66", x"6F",   -- "isk-Info"
      x"0D", x"0A");                                            -- "\r\n"

   constant C_TRACK_SIG : t_rom(0 to 11) := (
      x"54", x"72", x"61", x"63", x"6B", x"2D",                 -- "Track-"
      x"49", x"6E", x"66", x"6F", x"0D", x"0A");                -- "Info\r\n"

   -- DS_CLEAR borra la imagen entera a 0xE5 antes de empezar. Dos motivos:
   --   1. CORRECCION: el buffer viene con la imagen .dsk que el Shell cargo antes, y cualquier
   --      zona que no lleguemos a escribir conservaria ESOS datos. El resultado es una mezcla
   --      de dos discos, que es justo lo que se vio en hardware: entradas de directorio con
   --      nombres que no estaban en el disquete fisico y tamanos inflados.
   --   2. DIAGNOSTICO: 0xE5 es el relleno de formateo del CPC, o sea "espacio libre". Lo que no
   --      escribamos se ve como vacio en vez de como datos de otro disco, que es mucho mas
   --      facil de interpretar.
   -- Cuesta 194.816 ciclos = 3 ms. Nada al lado de los segundos que tarda leer el disco.
   type t_state is (DS_IDLE, DS_CLEAR, DS_DISKHDR, DS_RUN, DS_TRKHDR, DS_TLM);
   signal state     : t_state := DS_IDLE;

   -- M4019: telemetria. La leccion viene del core del Amiga (learning_cores/AExp-dev-hw-fdd):
   -- llevan un dispositivo de diagnostico de 29 KB con mapa de registros versionado y volcados
   -- de campo, y descubrieron que SIETE volcados que creian distintos eran en realidad DOS
   -- observaciones repetidas. De ahi el nonce y el tiempo de actividad: dos volcados nunca
   -- pueden confundirse en silencio. Nosotros veniamos contando destellos de un LED.
   constant C_MS_DIV  : natural := G_CLK_HZ / 1000;
   signal ms_div      : natural range 0 to C_MS_DIV - 1 := 0;
   signal uptime_ms   : unsigned(31 downto 0) := (others => '0');
   signal nonce       : unsigned(7 downto 0) := (others => '0');
   signal trk_written : unsigned(7 downto 0) := (others => '0');
   signal fin_pend    : std_logic := '0';
   signal fin_d       : std_logic := '0';   -- finish_i es un NIVEL, no un pulso

   -- Valores latcheados al cerrar la pista: para cuando se escribe su cabecera, floppy_mfm
   -- ya puede haber arrancado la pista siguiente.
   signal t_seen      : std_logic_vector(31 downto 0) := (others => '0');
   signal t_revs      : std_logic_vector(3 downto 0)  := (others => '0');
   signal t_idcrc     : std_logic_vector(15 downto 0) := (others => '0');
   signal t_dtcrc     : std_logic_vector(15 downto 0) := (others => '0');
   signal t_track     : std_logic_vector(6 downto 0)  := (others => '0');

   constant C_TLM_SIG : t_rom(0 to 5) := (x"43", x"50", x"43", x"54", x"4C", x"4D");  -- "CPCTLM"

   signal hdr_idx   : unsigned(8 downto 0) := (others => '0');   -- 0..255 dentro de la cabecera
   signal trk_base  : unsigned(17 downto 0) := (others => '0');  -- inicio del bloque de la pista
   signal sect_cnt  : unsigned(4 downto 0) := (others => '0');

   -- Lista de identificadores de la pista en curso: C,H,R,N por ranura. Son 9 x 4 bytes = 36,
   -- asi que van en registros y no en memoria.
   type t_ids is array (0 to 8) of std_logic_vector(7 downto 0);
   signal id_c_arr, id_h_arr, id_r_arr, id_n_arr : t_ids := (others => (others => '0'));

   signal wr_count  : unsigned(19 downto 0) := (others => '0');
   signal clr_addr  : unsigned(17 downto 0) := (others => '0');
   signal addr_r    : unsigned(17 downto 0) := (others => '0');
   signal data_r    : std_logic_vector(7 downto 0) := (others => '0');
   signal we_r      : std_logic := '0';

begin

   buf_addr_o <= std_logic_vector(addr_r);
   buf_data_o <= data_r;
   buf_we_o   <= we_r;
   img_size_o <= std_logic_vector(to_unsigned(C_IMG_SIZE, 32));
   busy_o     <= '0' when state = DS_IDLE else '1';
   wr_code_o  <= "00001" when wr_count <   1000 else
                 "00010" when wr_count <  50000 else
                 "00011" when wr_count < 150000 else
                 "00100" when wr_count < 250000 else
                 "00101";

   -- M4019: reloj de milisegundos libre desde el arranque. Va aparte del FSM a proposito:
   -- tiene que seguir corriendo entre recorridos para que dos volcados nunca den la misma hora.
   uptime_proc : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if ms_div = C_MS_DIV - 1 then
            ms_div    <= 0;
            uptime_ms <= uptime_ms + 1;
         else
            ms_div <= ms_div + 1;
         end if;
      end if;
   end process uptime_proc;

   main_proc : process (clk_i)
      variable slot : integer range 0 to 15;
      variable fld  : integer range 0 to 7;
      variable tix  : integer range 0 to 31;
   begin
      if rising_edge(clk_i) then
         we_r <= '0';

         -- M4019: el recorrido terminado puede llegar mientras se escribe la cabecera de la
         -- ultima pista, asi que se retiene hasta volver a DS_RUN. Por FLANCO: scan_done es
         -- un nivel que se queda alto, y por nivel reescribiriamos el bloque en bucle.
         fin_d <= finish_i;
         if finish_i = '1' and fin_d = '0' then
            fin_pend <= '1';
         end if;

         if rst_i = '1' then
            state   <= DS_IDLE;
            hdr_idx <= (others => '0');
         else
            case state is

               when DS_IDLE =>
                  if start_i = '1' then
                     clr_addr    <= (others => '0');
                     wr_count    <= (others => '0');
                     nonce       <= nonce + 1;          -- M4019: cada recorrido, uno nuevo
                     trk_written <= (others => '0');
                     fin_pend    <= '0';
                     state       <= DS_CLEAR;
                  end if;

               when DS_CLEAR =>
                  addr_r <= clr_addr;
                  data_r <= x"E5";
                  we_r   <= '1';
                  if clr_addr = C_IMG_SIZE - 1 then
                     hdr_idx <= (others => '0');
                     state   <= DS_DISKHDR;
                  else
                     clr_addr <= clr_addr + 1;
                  end if;

               -- Bloque de informacion de disco: 256 bytes, uno por ciclo
               when DS_DISKHDR =>
                  addr_r <= resize(hdr_idx, 18);
                  we_r   <= '1';
                  if hdr_idx < 34 then
                     data_r <= C_DISK_SIG(to_integer(hdr_idx));
                  elsif hdr_idx = 16#30# then
                     data_r <= std_logic_vector(to_unsigned(G_TRACKS, 8));
                  elsif hdr_idx = 16#31# then
                     data_r <= x"01";                                    -- una cara
                  elsif hdr_idx = 16#33# then
                     -- Tamano de pista en unidades de 256 bytes: 4864 / 256 = 19
                     data_r <= std_logic_vector(to_unsigned(C_TRACK_SIZE / 256, 8));
                  else
                     data_r <= x"00";
                  end if;

                  if hdr_idx = 255 then
                     state <= DS_RUN;
                  else
                     hdr_idx <= hdr_idx + 1;
                  end if;

               -- Mientras se lee una pista: cada byte de datos va directo a su sitio final, y
               -- se van apuntando los identificadores segun se confirman los sectores.
               when DS_RUN =>
                  if data_valid_i = '1' then
                     slot := to_integer(unsigned(sec_slot_i));
                     if slot < G_SECTORS then
                        -- base de la pista + 256 de su cabecera + ranura*512 + posicion
                        addr_r <= resize(
                           to_unsigned(512, 18) +
                           resize(unsigned(track_i) * C_TRKSZ_U, 18) +
                           to_unsigned(slot * G_SECSIZE, 18) +
                           unsigned(data_offset_i), 18);
                        data_r <= data_byte_i;
                        we_r   <= '1';
                        if wr_count /= 1048575 then
                           wr_count <= wr_count + 1;
                        end if;
                     end if;
                  end if;

                  if sec_ok_i = '1' then
                     slot := to_integer(unsigned(sec_slot_i));
                     if slot < G_SECTORS then
                        id_c_arr(slot) <= id_track_i;
                        id_h_arr(slot) <= id_side_i;
                        id_r_arr(slot) <= id_sector_i;
                        id_n_arr(slot) <= id_size_i;
                     end if;
                  end if;

                  if track_done_i = '1' then
                     trk_base <= resize(to_unsigned(256, 18) +
                                        resize(unsigned(done_track_i) * C_TRKSZ_U, 18), 18);
                     sect_cnt <= unsigned(sect_count_i);
                     -- M4019: latchear la telemetria AQUI. Cuando se escriba la cabecera,
                     -- floppy_mfm ya puede haber reiniciado sus contadores para la pista
                     -- siguiente, asi que leerlos alli daria ceros.
                     t_seen   <= tlm_seen_i;
                     t_revs   <= tlm_revs_i;
                     t_idcrc  <= tlm_idcrc_i;
                     t_dtcrc  <= tlm_dtcrc_i;
                     t_track  <= done_track_i;   -- M4021
                     hdr_idx  <= (others => '0');
                     state    <= DS_TRKHDR;
                  elsif fin_pend = '1' then
                     -- M4019: recorrido terminado -> reescribir el bloque global
                     fin_pend <= '0';
                     hdr_idx  <= (others => '0');
                     state    <= DS_TLM;
                  end if;

               -- Bloque de informacion de pista: 256 bytes. Se escribe al final porque hasta
               -- aqui no se sabe que sectores tiene la pista.
               when DS_TRKHDR =>
                  addr_r <= trk_base + resize(hdr_idx, 18);
                  we_r   <= '1';
                  if hdr_idx < 12 then
                     data_r <= C_TRACK_SIG(to_integer(hdr_idx));
                  elsif hdr_idx = 16#10# then
                     data_r <= "0" & t_track;                            -- M4021: la pista real
                  elsif hdr_idx = 16#11# then
                     data_r <= x"00";                                    -- cara 0
                  elsif hdr_idx = 16#14# then
                     data_r <= x"02";                                    -- N=2, sectores de 512
                  elsif hdr_idx = 16#15# then
                     data_r <= "000" & std_logic_vector(sect_cnt);
                  elsif hdr_idx = 16#16# then
                     data_r <= x"4E";                                    -- GAP#3, valor habitual
                  elsif hdr_idx = 16#17# then
                     data_r <= x"E5";                                    -- byte de relleno
                  elsif hdr_idx >= 16#18# and hdr_idx < 16#18# + G_SECTORS * 8 then
                     -- Lista de sectores: 8 bytes por sector (C,H,R,N,ST1,ST2,sin usar x2)
                     slot := to_integer(hdr_idx - 16#18#) / 8;
                     fld  := to_integer(hdr_idx - 16#18#) mod 8;
                     -- M4016: los bytes 6-7 llevan la LONGITUD REAL del sector, en little
                     -- endian. En un .DSK estandar no se usan (ahi la longitud sale de N), y
                     -- por eso estaban a cero - pero si la imagen que el usuario tiene
                     -- montada es un EDSK, u765 pone image_edsk=1 al montarla, ese flag NO se
                     -- recalcula al invalidar la cache de pista, y entonces la longitud sale
                     -- EXCLUSIVAMENTE de estos dos bytes (u765.sv:701 vs 722-724):
                     --    if (!image_edsk) sector_length <= 16'h80 << tinfo_data[2:0];
                     --    6: if (image_edsk) sector_length[7:0]  <= tinfo_data;
                     --       if (image_edsk) sector_length[15:8] <= tinfo_data;
                     -- Con ceros, todos los sectores median 0 -> "Read fail" tras reintentar,
                     -- que es exactamente lo que dio M4015 con un EDSK montado (Bruce Lee) y
                     -- no daba con una imagen estandar. Rellenarlos hace que nuestra cabecera
                     -- sea valida leida de las dos maneras, sin depender de que flag tenga
                     -- puesto el u765.
                     case fld is
                        when 0      => data_r <= id_c_arr(slot);
                        when 1      => data_r <= id_h_arr(slot);
                        when 2      => data_r <= id_r_arr(slot);
                        when 3      => data_r <= id_n_arr(slot);
                        when 6      => data_r <= std_logic_vector(to_unsigned(G_SECSIZE mod 256, 8));
                        when 7      => data_r <= std_logic_vector(to_unsigned(G_SECSIZE / 256, 8));
                        when others => data_r <= x"00";   -- ST1/ST2 a cero = sin errores
                     end case;

                  -- M4019: telemetria de esta pista, en 0x60..0x6B (libre: la lista de 9
                  -- sectores acaba en 0x5F). Todo little endian.
                  elsif hdr_idx >= 16#60# and hdr_idx <= 16#6B# then
                     tix := to_integer(hdr_idx - 16#60#);
                     case tix is
                        when 0      => data_r <= t_seen(7 downto 0);
                        when 1      => data_r <= t_seen(15 downto 8);
                        when 2      => data_r <= t_seen(23 downto 16);
                        when 3      => data_r <= t_seen(31 downto 24);
                        when 4      => data_r <= "0000" & t_revs;
                        when 5      => data_r <= "000" & std_logic_vector(sect_cnt);
                        when 6      => data_r <= t_idcrc(7 downto 0);
                        when 7      => data_r <= t_idcrc(15 downto 8);
                        when 8      => data_r <= t_dtcrc(7 downto 0);
                        when 9      => data_r <= t_dtcrc(15 downto 8);
                        when 10     => data_r <= "0" & t_track;
                        when others => data_r <= x"00";
                     end case;
                  else
                     data_r <= x"00";
                  end if;

                  if hdr_idx = 255 then
                     -- M4013: limpiar la lista de identificadores antes de la pista siguiente.
                     -- Si una pista da menos de 9 sectores, las ranuras que no se rellenen
                     -- conservarian los identificadores de la pista ANTERIOR y acabarian
                     -- escritos en su bloque de informacion como si fueran suyos. A 0x00 el
                     -- u765 ve un sector invalido, que es la verdad, en vez de uno plausible
                     -- pero de otra pista.
                     id_c_arr <= (others => (others => '0'));
                     id_h_arr <= (others => (others => '0'));
                     id_r_arr <= (others => (others => '0'));
                     id_n_arr    <= (others => (others => '0'));
                     trk_written <= trk_written + 1;     -- M4019
                     state       <= DS_RUN;
                  else
                     hdr_idx <= hdr_idx + 1;
                  end if;

               -- M4019: bloque global, reescrito sobre 0x34..0x47 de la cabecera de disco al
               -- terminar el recorrido. En un .DSK "MV" estandar esos bytes no se usan (la
               -- tabla de tamanos por pista de 0x34 en adelante es cosa del EDSK), asi que la
               -- imagen sigue siendo perfectamente valida.
               when DS_TLM =>
                  addr_r <= resize(to_unsigned(16#34#, 18) + resize(hdr_idx, 18), 18);
                  we_r   <= '1';
                  tix    := to_integer(hdr_idx);
                  case tix is
                     when 0 to 5 => data_r <= C_TLM_SIG(tix);          -- "CPCTLM"
                     when 6      => data_r <= x"01";                   -- version del mapa
                     when 7      => data_r <= std_logic_vector(nonce);
                     when 8      => data_r <= std_logic_vector(wr_count(7 downto 0));
                     when 9      => data_r <= std_logic_vector(wr_count(15 downto 8));
                     when 10     => data_r <= "0000" & std_logic_vector(wr_count(19 downto 16));
                     when 11     => data_r <= x"00";
                     when 12     => data_r <= std_logic_vector(trk_written);
                     when 13     => data_r <= "000" & tlm_badtrk_i;
                     when 14     => data_r <= tlm_flags_i;
                     when 15     => data_r <= "000" & tlm_poscode_i;
                     when 16     => data_r <= std_logic_vector(uptime_ms(7 downto 0));
                     when 17     => data_r <= std_logic_vector(uptime_ms(15 downto 8));
                     when 18     => data_r <= std_logic_vector(uptime_ms(23 downto 16));
                     when 19     => data_r <= std_logic_vector(uptime_ms(31 downto 24));
                     -- M4024: celdas emitidas por el DPLL. Cero con el DPLL encendido
                     -- significa que la opcion no llega al separador.
                     when 20     => data_r <= tlm_pllcells_i(7 downto 0);
                     when 21     => data_r <= tlm_pllcells_i(15 downto 8);
                     -- M4025: flancos espurios rechazados. Si sale 0, la hipotesis del
                     -- pulso espurio esta muerta.
                     when 22     => data_r <= tlm_runts_i(7 downto 0);
                     when 23     => data_r <= tlm_runts_i(15 downto 8);
                     -- M4026: formateo. 0x4C..0x53 los dos contadores de 32 bits.
                     when 24     => data_r <= tlm_wgate_i(7 downto 0);
                     when 25     => data_r <= tlm_wgate_i(15 downto 8);
                     when 26     => data_r <= tlm_wgate_i(23 downto 16);
                     when 27     => data_r <= tlm_wgate_i(31 downto 24);
                     when 28     => data_r <= tlm_wdata_i(7 downto 0);
                     when 29     => data_r <= tlm_wdata_i(15 downto 8);
                     when 30     => data_r <= tlm_wdata_i(23 downto 16);
                     when 31     => data_r <= tlm_wdata_i(31 downto 24);
                     when 32     => data_r <= tlm_starts_i;
                     when 33     => data_r <= tlm_refus_i;
                     -- M4028: estado del u765 en 0x56..0x57, fotografiado 3 s despues de
                     -- terminar el recorrido para que este ya asentado.
                     when 34     => data_r <= tlm_u765_i(7 downto 0);
                     when 35     => data_r <= tlm_u765_i(15 downto 8);
                     when others => data_r <= x"00";
                  end case;

                  if hdr_idx = 35 then
                     -- M4024: volver a REPOSO, no a DS_RUN. Si no, una segunda lectura no
                     -- vuelve a pasar por DS_IDLE: no se limpia la imagen, no se renueva el
                     -- nonce y los contadores se acumulan. El volcado B de M4023 salio con
                     -- 80 pistas y el doble de bytes justo por esto.
                     state <= DS_IDLE;
                  else
                     hdr_idx <= hdr_idx + 1;
                  end if;

            end case;
         end if;
      end if;
   end process main_proc;

end architecture beh;
