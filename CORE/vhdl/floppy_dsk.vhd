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
      G_SECSIZE      : natural := 512
   );
   port (
      clk_i          : in  std_logic;
      rst_i          : in  std_logic;

      -- Control desde floppy_scan
      start_i        : in  std_logic;                     -- pulso: empieza una imagen nueva
      track_i        : in  std_logic_vector(6 downto 0);  -- pista que se esta leyendo
      track_done_i   : in  std_logic;                     -- pulso: pista terminada
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
   type t_state is (DS_IDLE, DS_CLEAR, DS_DISKHDR, DS_RUN, DS_TRKHDR);
   signal state     : t_state := DS_IDLE;

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

   main_proc : process (clk_i)
      variable slot : integer range 0 to 15;
      variable fld  : integer range 0 to 7;
   begin
      if rising_edge(clk_i) then
         we_r <= '0';

         if rst_i = '1' then
            state   <= DS_IDLE;
            hdr_idx <= (others => '0');
         else
            case state is

               when DS_IDLE =>
                  if start_i = '1' then
                     clr_addr <= (others => '0');
                     wr_count <= (others => '0');
                     state    <= DS_CLEAR;
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
                                        resize(unsigned(track_i) * C_TRKSZ_U, 18), 18);
                     sect_cnt <= unsigned(sect_count_i);
                     hdr_idx  <= (others => '0');
                     state    <= DS_TRKHDR;
                  end if;

               -- Bloque de informacion de pista: 256 bytes. Se escribe al final porque hasta
               -- aqui no se sabe que sectores tiene la pista.
               when DS_TRKHDR =>
                  addr_r <= trk_base + resize(hdr_idx, 18);
                  we_r   <= '1';
                  if hdr_idx < 12 then
                     data_r <= C_TRACK_SIG(to_integer(hdr_idx));
                  elsif hdr_idx = 16#10# then
                     data_r <= "0" & track_i;                            -- numero de pista
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
                     id_n_arr <= (others => (others => '0'));
                     state    <= DS_RUN;
                  else
                     hdr_idx <= hdr_idx + 1;
                  end if;

            end case;
         end if;
      end if;
   end process main_proc;

end architecture beh;
