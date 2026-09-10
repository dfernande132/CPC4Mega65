---------------------------------------------------------------------------------------------------------
-- CPC4MEGA65 - Milestone 4, fase B: separador de datos MFM y lectura de campos de ID
--
-- Convierte el flujo magnetico crudo que sale de f_rdata_i en bytes, se sincroniza con las
-- marcas de direccion del formato IBM/CPC y lee los sectores completos: campo de ID y campo de
-- datos, cada uno con su CRC-16. Si el CRC cuadra, la decodificacion es exacta bit a bit.
--
-- Un sector cuenta como leido solo si cuadran LOS DOS CRC (el del ID y el de los datos) y el ID
-- era el inmediatamente anterior - si no, no se sabe a que sector pertenecen esos datos.
--
-- Los dos campos empiezan igual (A1 A1 A1 + byte de marca) y solo se distinguen por la marca:
-- 0xFE = ID, 0xFB = datos, 0xF8 = datos marcados como borrados. Por eso hay un unico buscador
-- de sincronismo y la bifurcacion se hace al leer la marca, en vez de dos maquinas separadas.
--
-- POR QUE ESTE FICHERO NO SE PARECE A NADA DE AExp, aunque AExp tenga disquetera completa:
-- su motor de pista (adf_track_engine.vhd) trabaja a nivel de PALABRA - Paula le entrega y le
-- recibe palabras de 16 bits ya sincronizadas por una FIFO, y nunca mide tiempos magneticos.
-- Aqui hay que empezar un escalon mas abajo. El reparto queda asi:
--   * Separador de datos (medir intervalos de flujo -> celdas): SIN precedente, es lo nuevo.
--   * Sincronismo + parseo + verificacion: AExp es referencia estructural, y ademas sincroniza
--     con la MISMA palabra 0x4489, que es comun a los formatos Amiga e IBM/CPC.
-- Ver .research/PORTING-PLAN.md seccion 11.4bis.
--
-- COMO FUNCIONA MFM, para que el codigo se lea solo:
-- A 250 kbps cada bit de datos ocupa 4us y se codifica en DOS celdas (reloj + dato) de 2us. Una
-- transicion de flujo marca siempre una celda a 1, y entre transicion y transicion solo puede
-- haber 2, 3 o 4 celdas -> intervalos de 4us, 6us u 8us. A 64MHz eso son 256, 384 y 512 ciclos:
-- resolucion de sobra para clasificarlos con un contador y ventanas fijas, sin PLL. Los discos
-- giran a 300 RPM con una tolerancia de +/-1,5%, muy por debajo del +/-25% que dan las ventanas.
--
-- Los bits de DATOS son las celdas impares. La palabra de sincronismo 0x4489 es una marca A1
-- con un pulso de reloj omitido a proposito, precisamente para que no pueda aparecer en datos
-- normales: sus celdas son 0100 0100 1000 1001, y tomando las impares salen 1010 0001 = 0xA1.
--
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
---------------------------------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity floppy_mfm is
   generic (
      G_CLK_HZ    : natural := 64_000_000
   );
   port (
      clk_i          : in  std_logic;
      rst_i          : in  std_logic;

      -- Arranque: se espera a que floppy_phys diga que la cabeza esta colocada
      enable_i       : in  std_logic;
      ready_i        : in  std_logic;                     -- floppy_phys.ready_o
      index_i        : in  std_logic;                     -- pulso de indice, 1 ciclo

      -- Flujo magnetico crudo (activo bajo, sin sincronizar)
      f_rdata_i      : in  std_logic;

      -- Resultado de la ultima vuelta completa
      done_o         : out std_logic;                     -- ya hay un recuento valido
      sector_count_o : out std_logic_vector(4 downto 0);  -- IDs con CRC correcto (0..31)
      is_hd_o        : out std_logic;                     -- densidad con la que se logro leer
      -- Ultimo campo de ID leido correctamente, para depurar y para la fase siguiente
      id_track_o     : out std_logic_vector(7 downto 0);
      id_side_o      : out std_logic_vector(7 downto 0);
      id_sector_o    : out std_logic_vector(7 downto 0);
      id_size_o      : out std_logic_vector(7 downto 0)
   );
end floppy_mfm;

architecture beh of floppy_mfm is

   ------------------------------------------------------------------------------------------
   -- Ventanas de clasificacion de intervalos, derivadas del reloj
   ------------------------------------------------------------------------------------------
   -- DOS juegos de ventanas, uno por densidad, y se prueban alternativamente hasta que una
   -- enganche. Razon practica: los disquetes de 3,5" que se encuentran hoy son casi todos HD
   -- (1,44 MB = 500 kbps), mientras que el formato del CPC es DD (250 kbps). Fijar solo DD
   -- habria dejado la prueba bloqueada a que el usuario consiguiera un disquete DD. Probar
   -- ambas no cuesta casi nada y ademas dice DE QUE TIPO es el disquete metido.
   --
   -- DD (250 kbps): bit de 4us, celdas de 2us -> intervalos de 4/6/8us
   constant C_DD_T2 : natural := (G_CLK_HZ / 1_000_000) * 4;    -- 256 @64MHz
   constant C_DD_T3 : natural := (G_CLK_HZ / 1_000_000) * 6;    -- 384
   constant C_DD_T4 : natural := (G_CLK_HZ / 1_000_000) * 8;    -- 512
   -- HD (500 kbps): exactamente la mitad -> 2/3/4us
   constant C_HD_T2 : natural := (G_CLK_HZ / 1_000_000) * 2;    -- 128
   constant C_HD_T3 : natural := (G_CLK_HZ / 1_000_000) * 3;    -- 192
   constant C_HD_T4 : natural := (G_CLK_HZ / 1_000_000) * 4;    -- 256

   -- Fronteras a mitad de camino entre nominales, y limites de validez con +/-25%
   constant C_DD_23 : natural := (C_DD_T2 + C_DD_T3) / 2;       -- 320
   constant C_DD_34 : natural := (C_DD_T3 + C_DD_T4) / 2;       -- 448
   constant C_DD_LO : natural := C_DD_T2 - (C_DD_T2 / 4);       -- 192
   constant C_DD_HI : natural := C_DD_T4 + (C_DD_T4 / 4);       -- 640
   constant C_HD_23 : natural := (C_HD_T2 + C_HD_T3) / 2;       -- 160
   constant C_HD_34 : natural := (C_HD_T3 + C_HD_T4) / 2;       -- 224
   constant C_HD_LO : natural := C_HD_T2 - (C_HD_T2 / 4);       -- 96
   constant C_HD_HI : natural := C_HD_T4 + (C_HD_T4 / 4);       -- 320

   -- Densidad que se esta probando ahora mismo: '0' = DD, '1' = HD
   signal rate_hd : std_logic := '0';

   -- Ventanas activas, seleccionadas por rate_hd
   signal lim_23  : natural range 0 to 1023;
   signal lim_34  : natural range 0 to 1023;
   signal lim_lo  : natural range 0 to 1023;
   signal lim_hi  : natural range 0 to 1023;

   constant C_CNT_MAX : natural := 2047;                     -- contador saturante

   -- Marcas del formato IBM/CPC
   constant C_SYNC_CELLS : std_logic_vector(15 downto 0) := x"4489";
   constant C_MARK_IDAM  : std_logic_vector(7 downto 0)  := x"FE";   -- campo de ID
   constant C_MARK_DAM   : std_logic_vector(7 downto 0)  := x"FB";   -- campo de datos
   constant C_MARK_DDAM  : std_logic_vector(7 downto 0)  := x"F8";   -- datos marcados borrados

   ------------------------------------------------------------------------------------------
   -- Sincronizacion de f_rdata_i y medida de intervalos
   ------------------------------------------------------------------------------------------
   signal rdata_sr   : std_logic_vector(2 downto 0) := (others => '1');
   signal gap_cnt    : natural range 0 to C_CNT_MAX := 0;

   signal cell_sr    : std_logic_vector(15 downto 0) := (others => '0');
   signal cell_new   : std_logic := '0';   -- se ha metido al menos una celda este ciclo

   -- Emision de celdas: una transicion emite '1' y luego 1, 2 o 3 ceros
   signal zeros_left : natural range 0 to 3 := 0;
   signal emit_one   : std_logic := '0';

   ------------------------------------------------------------------------------------------
   -- Ensamblado de bytes tras el sincronismo
   ------------------------------------------------------------------------------------------
   type t_state is (ST_IDLE, ST_HUNT, ST_BYTES);
   signal state      : t_state := ST_IDLE;

   signal cell_phase : std_logic := '0';                       -- '1' = la celda que llega es dato
   signal bit_cnt    : natural range 0 to 7 := 0;
   signal byte_sr    : std_logic_vector(7 downto 0) := (others => '0');

   signal field_idx  : natural range 0 to 15 := 0;             -- byte dentro del campo de ID
   signal crc        : std_logic_vector(15 downto 0) := (others => '1');

   -- Se cuentan SECTORES DISTINTOS, no lecturas, y a lo largo de varias vueltas.
   --
   -- La primera version contaba lecturas correctas entre dos pulsos de indice, y eso tiene un
   -- punto ciego: un sector cuyo campo de ID cae justo en la frontera de la ventana se pierde,
   -- y una lectura fallida puntual resta uno sin que se note. Con un mapa de bits indexado por
   -- el numero de sector, cada sector cuenta UNA vez la primera vez que se lee bien, y varias
   -- vueltas recuperan lo que se pierda en una. El resultado converge al numero real de
   -- sectores que tiene la pista, que es lo que se quiere medir.
   --
   -- Se indexa con los 5 bits bajos del ID, que sirve para los dos formatos que nos interesan:
   -- en PC los sectores son 1..9 y en el CPC son &C1..&C9 (193..201), cuyos 5 bits bajos son
   -- tambien 1..9.
   signal seen_map   : std_logic_vector(31 downto 0) := (others => '0');
   signal sect_cnt   : unsigned(4 downto 0) := (others => '0');
   signal rev_cnt    : natural range 0 to 7 := 0;
   signal done_r     : std_logic := '0';
   signal seen_index : std_logic := '0';

   -- Vueltas que se observan antes de dar el recuento por definitivo
   constant C_REVS : natural := 3;

   signal id_c, id_h, id_r, id_n : std_logic_vector(7 downto 0) := (others => '0');

   -- Lectura del campo de DATOS que sigue a cada campo de ID.
   -- id_ok recuerda si el ID inmediatamente anterior tenia el CRC bien: un campo de datos solo
   -- se da por bueno si su ID tambien lo estaba, porque si no, no se sabe a que sector pertenece.
   signal id_ok      : std_logic := '0';
   signal id_r_lat   : std_logic_vector(7 downto 0) := (others => '0');
   signal data_left  : unsigned(10 downto 0) := (others => '0');   -- hasta 1024 bytes

   ------------------------------------------------------------------------------------------
   -- CRC-16-CCITT (x^16+x^12+x^5+1), preset 0xFFFF - el del formato IBM
   ------------------------------------------------------------------------------------------
   function f_crc16(crc_in : std_logic_vector(15 downto 0);
                    data   : std_logic_vector(7 downto 0)) return std_logic_vector is
      variable c : std_logic_vector(15 downto 0) := crc_in;
      variable d : std_logic;
   begin
      for i in 7 downto 0 loop
         d := data(i) xor c(15);
         c := c(14 downto 0) & '0';
         if d = '1' then
            c := c xor x"1021";
         end if;
      end loop;
      return c;
   end function f_crc16;

begin

   lim_23 <= C_HD_23 when rate_hd = '1' else C_DD_23;
   lim_34 <= C_HD_34 when rate_hd = '1' else C_DD_34;
   lim_lo <= C_HD_LO when rate_hd = '1' else C_DD_LO;
   lim_hi <= C_HD_HI when rate_hd = '1' else C_DD_HI;

   sector_count_o <= std_logic_vector(sect_cnt);
   is_hd_o        <= rate_hd;
   done_o         <= done_r;
   id_track_o     <= id_c;
   id_side_o      <= id_h;
   id_sector_o    <= id_r;
   id_size_o      <= id_n;

   ------------------------------------------------------------------------------------------
   -- Separador de datos: intervalos de flujo -> celdas MFM
   ------------------------------------------------------------------------------------------
   sep_proc : process (clk_i)
      variable interval : natural range 0 to C_CNT_MAX;
   begin
      if rising_edge(clk_i) then
         rdata_sr <= rdata_sr(1 downto 0) & f_rdata_i;
         emit_one <= '0';
         cell_new <= '0';

         if rst_i = '1' or enable_i = '0' then
            gap_cnt    <= 0;
            zeros_left <= 0;
            cell_sr    <= (others => '0');
         else
            -- Contador de tiempo entre transiciones, saturante
            if gap_cnt /= C_CNT_MAX then
               gap_cnt <= gap_cnt + 1;
            end if;

            -- ORDEN IMPORTANTE: primero el '1' de la transicion, despues sus ceros. Al reves
            -- (que es como estaba escrito en el primer intento) la palabra de sincronismo sale
            -- desplazada y no se encuentra nunca. Se emite una celda por ciclo de reloj: no hay
            -- prisa, la siguiente transicion no llega hasta 256 ciclos como minimo, asi que la
            -- rafaga de 4 celdas como mucho termina de sobra antes.
            if emit_one = '1' then
               cell_sr  <= cell_sr(14 downto 0) & '1';
               cell_new <= '1';
            elsif zeros_left /= 0 then
               cell_sr    <= cell_sr(14 downto 0) & '0';
               zeros_left <= zeros_left - 1;
               cell_new   <= '1';
            end if;

            -- Flanco de bajada de f_rdata_i = transicion de flujo
            if rdata_sr(2) = '1' and rdata_sr(1) = '0' then
               interval := gap_cnt;
               gap_cnt  <= 0;

               if interval < lim_lo or interval > lim_hi then
                  -- Intervalo imposible: hueco entre sectores, arranque del motor o dropout.
                  -- No se emite nada; el buscador de sincronismo se quedara sin encontrar
                  -- 0x4489 y seguira buscando, que es el comportamiento correcto.
                  zeros_left <= 0;
               elsif interval < lim_23 then
                  zeros_left <= 1;              -- 2T -> "10"
                  emit_one   <= '1';
               elsif interval < lim_34 then
                  zeros_left <= 2;              -- 3T -> "100"
                  emit_one   <= '1';
               else
                  zeros_left <= 3;              -- 4T -> "1000"
                  emit_one   <= '1';
               end if;
            end if;
         end if;
      end if;
   end process sep_proc;

   ------------------------------------------------------------------------------------------
   -- Sincronismo, ensamblado de bytes y verificacion del campo de ID
   ------------------------------------------------------------------------------------------
   -- El byte completo se procesa EN EL MISMO CICLO en que entra su ultimo bit, usando una
   -- variable. La primera version usaba un flag registrado de un ciclo, y eso es fragil aqui:
   -- las celdas no llegan espaciadas sino en rafagas de hasta 4 ciclos seguidos (ver el
   -- separador), asi que un byte puede completarse y llegar la celda siguiente de inmediato.
   dec_proc : process (clk_i)
      variable byte_v : std_logic_vector(7 downto 0);
      variable have_v : boolean;
   begin
      if rising_edge(clk_i) then
         have_v := false;

         if rst_i = '1' or enable_i = '0' then
            state      <= ST_IDLE;
            seen_map   <= (others => '0');
            sect_cnt   <= (others => '0');
            rev_cnt    <= 0;
            done_r     <= '0';
            seen_index <= '0';
            bit_cnt    <= 0;
            field_idx  <= 0;
            id_ok      <= '0';
            data_left  <= (others => '0');
            rate_hd    <= '0';        -- se empieza probando DD, que es lo que usa el CPC
         else

            -- El recuento se hace sobre UNA vuelta completa: se arranca en un pulso de indice
            -- y se cierra en el siguiente. Antes hay que esperar a que la cabeza este colocada.
            if index_i = '1' and ready_i = '1' and done_r = '0' then
               if seen_index = '0' then
                  seen_index <= '1';
                  rev_cnt    <= 0;
                  state      <= ST_HUNT;
               elsif sect_cnt = "00000" then
                  -- Una vuelta entera sin enganchar nada con esta densidad: se prueba la otra.
                  -- Si el disquete no es legible en ninguna, esto alterna indefinidamente y el
                  -- LED nunca llega a contar, que es la señal correcta de "aqui no hay nada".
                  rate_hd <= not rate_hd;
                  state   <= ST_HUNT;
               elsif rev_cnt = C_REVS - 1 then
                  -- Suficientes vueltas observadas: el mapa ya no va a crecer mas.
                  done_r <= '1';
                  state  <= ST_IDLE;
               else
                  rev_cnt <= rev_cnt + 1;
                  state   <= ST_HUNT;
               end if;
            end if;

            case state is

               when ST_IDLE =>
                  null;

               when ST_HUNT =>
                  -- Busca la palabra de sincronismo celda a celda
                  if cell_new = '1' and cell_sr = C_SYNC_CELLS then
                     -- Sincronizado. La siguiente celda que llegue es de RELOJ, asi que la
                     -- fase arranca en '0' y el primer dato sera la celda siguiente.
                     cell_phase <= '0';
                     bit_cnt    <= 0;
                     field_idx  <= 0;
                     -- El CRC del formato IBM incluye las TRES marcas A1. El buscador acaba de
                     -- consumir la primera, asi que se inyecta a mano; las otras dos llegaran
                     -- ya como bytes decodificados.
                     crc        <= f_crc16(x"FFFF", x"A1");
                     state      <= ST_BYTES;
                  end if;

               when ST_BYTES =>
                  if cell_new = '1' then
                     cell_phase <= not cell_phase;
                     if cell_phase = '1' then
                        -- Celda de datos
                        byte_v := byte_sr(6 downto 0) & cell_sr(0);
                        byte_sr <= byte_v;
                        if bit_cnt = 7 then
                           bit_cnt <= 0;
                           have_v  := true;
                        else
                           bit_cnt <= bit_cnt + 1;
                        end if;
                     end if;
                  end if;
            end case;

            -- Un byte completo: alimentar el CRC y avanzar por el campo
            if have_v then
               crc <= f_crc16(crc, byte_v);

               case field_idx is
                  when 0 | 1 =>
                     -- Las otras dos marcas A1. Si no lo son, el sincronismo era espurio.
                     if byte_v /= x"A1" then
                        state <= ST_HUNT;
                     end if;
                     field_idx <= field_idx + 1;

                  when 2 =>
                     -- Byte de marca: decide si lo que sigue es un campo de ID o uno de datos.
                     -- Los dos empiezan igual (A1 A1 A1 + marca), asi que un solo buscador de
                     -- sincronismo sirve para ambos y aqui se bifurca.
                     if byte_v = C_MARK_IDAM then
                        id_ok     <= '0';       -- un ID nuevo invalida el anterior
                        field_idx <= 3;
                     elsif byte_v = C_MARK_DAM or byte_v = C_MARK_DDAM then
                        field_idx <= 10;
                     else
                        state <= ST_HUNT;
                     end if;

                  when 3 => id_c <= byte_v; field_idx <= 4;
                  when 4 => id_h <= byte_v; field_idx <= 5;
                  when 5 => id_r <= byte_v; field_idx <= 6;
                  when 6 =>
                     id_n <= byte_v;
                     -- Tamano del sector = 128 << N. En el CPC N siempre es 2 (512 bytes); se
                     -- aceptan 0..3 y cualquier otro valor se considera un ID corrupto.
                     case byte_v(1 downto 0) is
                        when "00"   => data_left <= to_unsigned(128, 11);
                        when "01"   => data_left <= to_unsigned(256, 11);
                        when "10"   => data_left <= to_unsigned(512, 11);
                        when others => data_left <= to_unsigned(1024, 11);
                     end case;
                     if unsigned(byte_v) > 3 then
                        state <= ST_HUNT;
                     else
                        field_idx <= 7;
                     end if;
                  when 7 => field_idx <= 8;                    -- CRC alto del ID
                  when 8 =>
                     -- Tras meter los dos bytes de CRC en el propio CRC, el resultado tiene que
                     -- ser cero. Es la comprobacion que demuestra que la decodificacion es
                     -- exacta bit a bit: un solo bit mal y esto no cuadra.
                     if f_crc16(crc, byte_v) = x"0000" then
                        id_ok    <= '1';
                        id_r_lat <= id_r;
                     end if;
                     state <= ST_HUNT;        -- ahora toca el campo de datos de este sector

                  -- Campo de datos: los N bytes utiles y despues su propio CRC
                  when 10 =>
                     if data_left = 1 then
                        field_idx <= 11;
                     else
                        data_left <= data_left - 1;
                     end if;
                  when 11 => field_idx <= 12;                  -- CRC alto de los datos
                  when 12 =>
                     -- Un sector cuenta como LEIDO DE VERDAD solo si cuadran los dos CRC, el del
                     -- ID y el de los datos, y ademas el ID era el inmediatamente anterior.
                     if f_crc16(crc, byte_v) = x"0000" and id_ok = '1' then
                        if seen_map(to_integer(unsigned(id_r_lat(4 downto 0)))) = '0' then
                           seen_map(to_integer(unsigned(id_r_lat(4 downto 0)))) <= '1';
                           if sect_cnt /= "11111" then
                              sect_cnt <= sect_cnt + 1;
                           end if;
                        end if;
                     end if;
                     id_ok <= '0';
                     state <= ST_HUNT;

                  when others =>
                     state <= ST_HUNT;
               end case;
            end if;

         end if;
      end if;
   end process dec_proc;

end architecture beh;
