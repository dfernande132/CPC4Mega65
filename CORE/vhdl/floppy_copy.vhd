---------------------------------------------------------------------------------------------------------
-- CPC4MEGA65 - Milestone 4, fase D: COPIAR UN .DSK AL DISQUETE FISICO
--
-- Lee la imagen que hay en el buffer de montaje de una unidad virtual y la graba en el disquete
-- de la disquetera interna del MEGA65, pista a pista.
--
-- POR QUE ESTO ANTES QUE DEVOLVER LAS PISTAS SUCIAS: porque NO DEPENDE DEL CAMINO DE LECTURA.
-- El origen es un fichero que ya esta entero y correcto en el buffer, asi que no hace falta
-- haber leido antes el disquete, no hace falta el mapa de pistas buenas, y no existe el caso
-- "grabo una pista que no pude leer". Es la prueba mas limpia posible del motor de escritura, y
-- de paso resuelve un problema practico: hasta ahora, para tener disquetes de prueba con
-- contenido habia que formatear y copiar a mano desde el CPC.
--
-- QUE HACE Y QUE NO
--
-- Los identificadores de sector salen de la CABECERA DE PISTA del .dsk, no de C1..C9 fijos. Asi
-- vale igual para formato DATA, SYSTEM o IBM, y ademas respeta el entrelazado fisico original:
-- un .dsk real guarda los sectores en el orden en que estan en el disco (C1 C6 C2 C7 C3...), de
-- modo que copiarlos en el orden de la lista reproduce el disco tal cual.
--
-- SE NIEGA EN SECO, sin abrir WGATE ni una sola vez, si la imagen no es copiable con este
-- formateador: dos caras, sectores que no sean de 512 bytes, mas de 9 sectores por pista (no
-- cabe en una vuelta), pistas sin formatear, o mas de 45 pistas. Ahi caen los discos protegidos.
-- Que fallen es lo correcto: no se copia "lo que se pueda" y se deja al usuario con un disquete
-- a medias que parece bueno.
--
-- LA VALIDACION VA ENTERA Y ANTES. Se recorren las 40-45 cabeceras de pista en el buffer (unos
-- 2500 ciclos, 40 us) y solo si TODAS pasan se deja escribir. Un disco que se rechaza a mitad de
-- copia seria peor que uno que no se copia.
--
-- COMO SE ACOPLA AL RESTO - Y POR QUE ESTE MODULO NO ARRANCA NADA
--
-- El recorrido de pistas y la busqueda de pista los hace floppy_scan en su modo formateo, que es
-- la parte delicada y ya esta validada en hardware (40 de 40 pistas). La escritura la hace
-- floppy_write en su modo origen externo: misma temporizacion, mismos huecos, mismos
-- sincronismos y mismos CRC que el formateo probado; lo unico que cambia es de donde salen los
-- cuatro bytes del ID y los 512 de datos.
--
-- Este modulo no manda arrancar: lo unico que hace es SUJETAR. Mientras hold_o este alto,
-- floppy_scan no llega a pulsar el arranque del escritor. Se sube al empezar y solo se baja
-- cuando la pista que hay bajo la cabeza esta validada y parseada. Consecuencia buscada: si la
-- validacion falla, hold_o no baja NUNCA y WGATE no se abre ni una vez, sin necesidad de una
-- ruta de aborto aparte. Un nivel no tiene carreras; un pulso de aborto si.
--
-- El puerto de lectura del buffer de montaje por el lado del core ya existia y estaba sin usar
-- (mega65.vhd, q_b => open), asi que esto no cuesta ni un bloque de RAM nuevo.
--
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
---------------------------------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity floppy_copy is
   generic (
      -- M4034b: 45 y no 42. Once de los 26 .dsk de la coleccion del usuario tienen 43 pistas
      -- (0..42), que es una disposicion normalisima en el CPC, y uno tiene 45. La disquetera
      -- del MEGA65 es un mecanismo de PC de 80 pistas: llegar ahi no es ningun problema. El
      -- 42 de la primera version era un limite inventado, no una restriccion real.
      G_MAXTRK    : natural := 45;         -- pistas que aceptamos como mucho
      G_MAXSEC    : natural := 9;          -- sectores por pista que caben en una vuelta
      G_BUFSZ     : natural := 262144      -- tamano del buffer de montaje, 256 KB
   );
   port (
      clk_i          : in  std_logic;
      rst_i          : in  std_logic;

      enable_i       : in  std_logic;                     -- opcion de menu "copiar disco"

      -- M4035: MODO. '0' = copiar la imagen ENTERA (todas las pistas del .dsk).
      -- '1' = REESCRITURA POR PISTAS: solo las que el CPC ha tocado, y solo si se leyeron
      -- enteras. Es el mismo recorrido y el mismo escritor; lo que cambia es que pistas se
      -- visitan y de que unidad sale la imagen (eso lo decide main.vhd).
      mode_wb_i      : in  std_logic := '0';
      dirty_i        : in  std_logic_vector(39 downto 0) := (others => '0');
      ok_i           : in  std_logic_vector(39 downto 0) := (others => '0');
      -- '1' = en esta pista no hay nada que escribir; floppy_scan pasa de largo sin abrir
      -- WGATE. Sin esto habria que darle al secuenciador una lista de pistas, y el recorrido
      -- lineal es justo la parte que ya esta validada.
      skip_o         : out std_logic;
      -- Pulso al terminar una pista, con su numero: main.vhd borra ese bit del mapa de sucias.
      -- Sin esto el modo automatico reescribiria la misma pista para siempre.
      wrote_o        : out std_logic;
      wrote_trk_o    : out std_logic_vector(6 downto 0);
      -- Pistas sucias que NO se pueden regrabar porque no se leyeron enteras. Se cuentan, no
      -- se escriben a medias, y su bit de sucio NO se borra: esos datos no han llegado al
      -- disquete y el LED tiene que seguir diciendolo.
      tlm_blocked_o  : out std_logic_vector(7 downto 0);

      -- Lectura del buffer de montaje de la unidad ORIGEN
      buf_addr_o     : out std_logic_vector(17 downto 0);
      buf_q_i        : in  std_logic_vector(7 downto 0);

      -- Acoplamiento con floppy_scan (modo formateo)
      hold_o         : out std_logic;                     -- '1' = no arranques el escritor aun
      trk_last_o     : out std_logic_vector(6 downto 0);  -- ultima pista del recorrido
      track_i        : in  std_logic_vector(6 downto 0);  -- pista bajo la cabeza AHORA
      scan_done_i    : in  std_logic;

      -- Alimentacion de floppy_write en modo origen externo
      w_sec_i        : in  std_logic_vector(3 downto 0);  -- sector que esta escribiendo
      w_off_i        : in  std_logic_vector(9 downto 0);  -- byte dentro del sector
      w_nsec_o       : out std_logic_vector(4 downto 0);
      w_id_c_o       : out std_logic_vector(7 downto 0);
      w_id_h_o       : out std_logic_vector(7 downto 0);
      w_id_r_o       : out std_logic_vector(7 downto 0);
      w_id_n_o       : out std_logic_vector(7 downto 0);
      w_data_o       : out std_logic_vector(7 downto 0);

      -- Resultado
      busy_o         : out std_logic;
      done_o         : out std_logic;
      refused_o      : out std_logic;
      -- Por que se nego. Va a la telemetria, no al LED: son ocho casos y el LED no los
      -- distingue. El LED solo dice "no".
      --   1 firma desconocida (no hay .dsk montado, o no es un .dsk)
      --   2 dos caras
      --   3 numero de pistas imposible (0 o mas de G_MAXTRK)
      --   4 una pista tiene 0 o mas de G_MAXSEC sectores
      --   5 un sector no es de 512 bytes (N distinto de 2)
      --   6 un sector dice que es de la cara 1
      --   7 LIBRE desde M4051: las pistas sin formatear ya no se rechazan, se saltan
      --   8 la imagen no cabe en el buffer de montaje
      err_code_o     : out std_logic_vector(3 downto 0);
      tlm_trk_o      : out std_logic_vector(7 downto 0)   -- pistas preparadas para escribir
   );
end floppy_copy;

architecture beh of floppy_copy is

   -- Desplazamientos dentro de la cabecera de disco de un .dsk
   constant C_H_TRACKS : natural := 16#30#;
   constant C_H_SIDES  : natural := 16#31#;
   constant C_H_TSIZE  : natural := 16#32#;   -- solo .dsk estandar: 16 bits, tamano de pista
   constant C_H_TTAB   : natural := 16#34#;   -- solo EDSK: tamano/256 de cada pista

   -- Desplazamientos dentro de la cabecera de pista
   constant C_T_SIDE   : natural := 16#11#;
   constant C_T_NSEC   : natural := 16#15#;
   constant C_T_LIST   : natural := 16#18#;   -- 8 bytes por sector: C H R N ST1 ST2 len_lo len_hi

   constant C_SECSZ    : natural := 512;

   type t_state is (
      CP_IDLE,
      CP_RD,                                             -- lector de un byte del buffer
      CP_SIG, CP_TRACKS, CP_SIDES, CP_TSZ_LO, CP_TSZ_HI, -- cabecera de disco
      CP_V_TSZ, CP_V_SIDE, CP_V_NSEC, CP_V_SEC_H, CP_V_SEC_N, CP_V_NEXT,  -- validacion
      CP_ARM, CP_P_NSEC, CP_P_C, CP_P_H, CP_P_R, CP_P_N, CP_P_NEXT, CP_FEED, CP_SKIP,
      CP_DONE, CP_REFUSED);

   signal state    : t_state := CP_IDLE;
   signal ret      : t_state := CP_IDLE;

   signal addr_r   : unsigned(17 downto 0) := (others => '0');
   signal rd_wait  : natural range 0 to 3 := 0;
   signal rd_data  : std_logic_vector(7 downto 0) := (others => '0');

   signal extended : std_logic := '0';       -- '1' = EDSK
   signal ntracks  : unsigned(6 downto 0) := (others => '0');
   signal tsize    : unsigned(15 downto 0) := (others => '0');

   -- Desplazamiento de la pista que se esta validando. Se acumula al recorrer las pistas en
   -- orden, que es como va la pasada, asi que la tabla solo hace falta para volver luego.
   signal v_off    : unsigned(18 downto 0) := (others => '0');
   signal v_trk    : unsigned(6 downto 0) := (others => '0');
   signal v_sec    : natural range 0 to 15 := 0;
   signal v_nsec   : unsigned(4 downto 0) := (others => '0');

   -- Desplazamiento de la pista que se esta COPIANDO
   signal t_off    : unsigned(17 downto 0) := (others => '0');

   -- Tabla de desplazamientos por pista: en la pasada de copia hay que volver a ellos, y en un
   -- EDSK las pistas no son todas del mismo tamano. 42 x 18 bits.
   type t_offtab is array (0 to G_MAXTRK - 1) of unsigned(17 downto 0);
   signal off_tab  : t_offtab := (others => (others => '0'));

   -- M4051: que pistas del .dsk estan FORMATEADAS. En un EDSK una pista sin formatear se marca
   -- con tamano 0 y no ocupa ni un byte. Antes se rechazaba la imagen entera; resulta que 12 de
   -- los 26 .dsk de la coleccion del usuario las tienen -y algunos EN MEDIO, no solo al final-,
   -- asi que rechazar dejaba la copia inservible para media coleccion.
   --
   -- Lo fiel es SALTARLAS: 'sin formatear' significa literalmente que ahi no hay nada, y no
   -- escribir esa pista deja el disquete como estaba, que es exactamente lo que dice el origen.
   signal trk_fmt  : std_logic_vector(G_MAXTRK - 1 downto 0) := (others => '0');
   signal fmt_ix   : integer range 0 to G_MAXTRK - 1;
   signal trk_unf  : std_logic;    -- la pista bajo la cabeza no esta formateada en el origen

   -- Identificadores de los sectores de la pista que se esta copiando AHORA
   type t_idarr is array (0 to G_MAXSEC - 1) of std_logic_vector(7 downto 0);
   signal id_c     : t_idarr := (others => (others => '0'));
   signal id_h     : t_idarr := (others => (others => '0'));
   signal id_r     : t_idarr := (others => (others => '0'));
   signal id_n     : t_idarr := (others => (others => '0'));
   signal p_nsec   : unsigned(4 downto 0) := (others => '0');
   signal p_trk    : unsigned(6 downto 0) := (others => '1');   -- pista que hay parseada
   signal p_ok     : std_logic := '0';
   signal p_sec    : natural range 0 to G_MAXSEC - 1 := 0;

   signal err_r    : unsigned(3 downto 0) := (others => '0');
   signal trk_cnt  : unsigned(7 downto 0) := (others => '0');
   signal scan_d   : std_logic := '0';
   signal blk_cnt  : unsigned(7 downto 0) := (others => '0');
   signal wrote_r  : std_logic := '0';
   signal skip_r   : std_logic := '0';

   -- M4052: el fin del recorrido se ENGANCHA en vez de mirarse en vivo.
   --
   -- 'scan_done_i = 1 y scan_d = 0' es una ventana de UN ciclo, y este modulo no siempre esta
   -- mirando: pasa ratos en los estados que leen del buffer la cabecera de pista. Mientras el
   -- recorrido solo podia terminar estando nosotros sujetando, la ventana no se podia perder.
   -- Desde que floppy_scan puede cortar por su cuenta al no haber disquete (M4052), si. Y
   -- perderla dejaba a este modulo sujetando para siempre.
   --
   -- Mismo arreglo, y mismo motivo, que el pestillo de la telemetria de M4049.
   signal scan_end : std_logic := '0';
   signal cur_ix   : integer range 0 to 39;
   signal wb_todo  : std_logic;    -- hay que escribir la pista que hay bajo la cabeza
   signal wb_blk   : std_logic;    -- ...pero no se leyo entera
   signal wb_in_r  : std_logic;
   signal en_d     : std_logic := '0';

   -- Direccion del byte de datos que pide el escritor
   signal feed_addr : unsigned(17 downto 0);
   signal sec_ix    : integer range 0 to G_MAXSEC - 1;

begin

   -- El indice llega del escritor en 4 bits y el array tiene 9 entradas: se acota aqui una sola
   -- vez en vez de repetir la guarda en los cinco sitios que lo usan.
   sec_ix <= to_integer(unsigned(w_sec_i)) when unsigned(w_sec_i) < G_MAXSEC else 0;

   -- t_off + 256 (la cabecera de pista) + 512 por sector ya escrito + el byte en curso.
   -- Solo es valido porque la validacion ya ha exigido que TODOS los sectores sean de 512: si
   -- no, harian falta desplazamientos acumulados y esto seria otra tabla.
   feed_addr <= t_off + to_unsigned(256, 18) +
                to_unsigned(sec_ix * C_SECSZ, 18) +
                resize(unsigned(w_off_i), 18);

   -- El buffer tiene un solo puerto por este lado: mientras se prepara una pista lo usa el
   -- parser, y mientras se escribe lo usa el escritor. Nunca a la vez.
   buf_addr_o <= std_logic_vector(feed_addr) when state = CP_FEED
                 else std_logic_vector(addr_r);

   w_data_o   <= buf_q_i;
   w_nsec_o   <= std_logic_vector(p_nsec);
   w_id_c_o   <= id_c(sec_ix);
   w_id_h_o   <= id_h(sec_ix);
   w_id_r_o   <= id_r(sec_ix);
   w_id_n_o   <= id_n(sec_ix);

   -- hold_o es un NIVEL, no un evento: "esta pista todavia no esta preparada". Asi no hay
   -- carrera posible con el instante en que floppy_scan cambia de pista, y un fallo de
   -- validacion se traduce solo en que no baja nunca.
   hold_o     <= '0' when (state = CP_FEED and p_ok = '1' and p_trk = unsigned(track_i))
                 else '1';

   -- Hasta que la cabecera este leida se anuncia el recorrido de 40 pistas de siempre. Da igual
   -- lo que valga mientras hold_o esta alto, pero no conviene publicar un 0 que pararia el
   -- recorrido en la pista 0 si alguna vez se soltara antes de tiempo.
   trk_last_o <= std_logic_vector(ntracks - 1) when ntracks /= 0
                 else std_logic_vector(to_unsigned(39, 7));

   busy_o     <= '0' when (state = CP_IDLE or state = CP_DONE or state = CP_REFUSED) else '1';
   done_o     <= '1' when state = CP_DONE else '0';
   refused_o  <= '1' when state = CP_REFUSED else '0';
   err_code_o <= std_logic_vector(err_r);
   tlm_trk_o  <= std_logic_vector(trk_cnt);
   tlm_blocked_o <= std_logic_vector(blk_cnt);
   wrote_o       <= wrote_r;
   -- M4036: la pista que se VA a grabar, no la que acaba de terminar (ver CP_P_NEXT).
   wrote_trk_o   <= track_i;
   skip_o        <= skip_r;

   -- Decision por pista en modo reescritura, combinacional sobre los dos mapas medidos.
   cur_ix  <= to_integer(unsigned(track_i)) when unsigned(track_i) < 40 else 0;

    -- M4051: track_i tiene 7 bits (0..127) y trk_fmt solo G_MAXTRK, asi que el indice hay que
    -- recortarlo APARTE. No vale con protegerlo dentro de la condicion: VHDL no cortocircuita
    -- el 'and' y evaluaria el indice de todas formas. Como ntracks <= G_MAXTRK esta validado
    -- (rechazo 3), cuando track_i < ntracks el recorte no llega a actuar nunca.
    fmt_ix  <= to_integer(unsigned(track_i)) when unsigned(track_i) < G_MAXTRK else 0;
    trk_unf <= '1' when (unsigned(track_i) < ntracks and trk_fmt(fmt_ix) = '0') else '0';
   wb_in_r <= '1' when unsigned(track_i) < 40 else '0';
   wb_todo <= '1' when (mode_wb_i = '1' and wb_in_r = '1' and
                        dirty_i(cur_ix) = '1' and ok_i(cur_ix) = '1') else '0';
   wb_blk  <= '1' when (mode_wb_i = '1' and wb_in_r = '1' and
                        dirty_i(cur_ix) = '1' and ok_i(cur_ix) = '0') else '0';

   main_proc : process (clk_i)
      variable nxt_off : unsigned(18 downto 0);
   begin
      if rising_edge(clk_i) then
         en_d   <= enable_i;
         scan_d <= scan_done_i;
         if scan_done_i = '1' and scan_d = '0' then
            scan_end <= '1';                     -- M4052
         end if;
         wrote_r <= '0';      -- M4035: pulso de un ciclo

         if rst_i = '1' then
            state   <= CP_IDLE;
            err_r   <= (others => '0');
            trk_cnt <= (others => '0');
            p_ok    <= '0';
            ntracks <= (others => '0');
            scan_end <= '0';                     -- M4052
         elsif enable_i = '0' then
            -- OJO: al desmarcar la opcion NO se borran err_r ni trk_cnt. Durante una copia
            -- floppy_dsk no corre, asi que el volcado de telemetria no se escribe y el motivo
            -- de un rechazo no tendria por donde salir. Sobreviviendo aqui, basta con hacer una
            -- LECTURA despues para que el volcado lo lleve. Mismo criterio que los contadores
            -- del formateo desde M4026.
            state   <= CP_IDLE;
            p_ok    <= '0';
            ntracks <= (others => '0');
            scan_end <= '0';                     -- M4052
         else

            case state is

               -- Arranca al MARCAR la opcion del menu. No hace falta un pulso aparte: el propio
               -- flanco de enable_i es el disparo, y mientras este marcada no se repite.
               when CP_IDLE =>
                  if en_d = '0' then
                     err_r    <= (others => '0');
                     trk_cnt  <= (others => '0');
                     blk_cnt  <= (others => '0');
                     skip_r   <= '0';
                     p_ok     <= '0';
                     p_trk    <= (others => '1');
                     extended <= '0';
                     ntracks  <= (others => '0');
                     addr_r   <= (others => '0');
                     rd_wait  <= 2;
                     ret      <= CP_SIG;
                     state    <= CP_RD;
                  end if;

               -- ---- lector de un byte del buffer -------------------------------------------
               when CP_RD =>
                  if rd_wait = 0 then
                     rd_data <= buf_q_i;
                     state   <= ret;
                  else
                     rd_wait <= rd_wait - 1;
                  end if;

               -- ---- cabecera de disco ------------------------------------------------------
               when CP_SIG =>
                  -- 'M' de "MV - CPCEMU" = .dsk estandar; 'E' de "EXTENDED" = EDSK.
                  if rd_data = x"4D" or rd_data = x"45" then
                     if rd_data = x"45" then
                        extended <= '1';
                     end if;
                     addr_r  <= to_unsigned(C_H_TRACKS, 18);
                     rd_wait <= 2; ret <= CP_TRACKS; state <= CP_RD;
                  else
                     err_r <= x"1"; state <= CP_REFUSED;
                  end if;

               when CP_TRACKS =>
                  if unsigned(rd_data) = 0 or unsigned(rd_data) > G_MAXTRK then
                     err_r <= x"3"; state <= CP_REFUSED;
                  else
                     ntracks <= unsigned(rd_data(6 downto 0));
                     addr_r  <= to_unsigned(C_H_SIDES, 18);
                     rd_wait <= 2; ret <= CP_SIDES; state <= CP_RD;
                  end if;

               when CP_SIDES =>
                  if rd_data /= x"01" then
                     err_r <= x"2"; state <= CP_REFUSED;
                  else
                     addr_r  <= to_unsigned(C_H_TSIZE, 18);
                     rd_wait <= 2; ret <= CP_TSZ_LO; state <= CP_RD;
                  end if;

               when CP_TSZ_LO =>
                  tsize(7 downto 0) <= unsigned(rd_data);
                  addr_r  <= to_unsigned(C_H_TSIZE + 1, 18);
                  rd_wait <= 2; ret <= CP_TSZ_HI; state <= CP_RD;

               when CP_TSZ_HI =>
                  tsize(15 downto 8) <= unsigned(rd_data);
                  -- Empieza la validacion por la pista 0, que arranca justo tras la cabecera.
                  -- M4035: sin lectura previa no hay mapa de pistas buenas, o sea que no hay
                  -- forma de saber que pistas tenemos completas. Negarse es lo unico honesto.
                  if mode_wb_i = '1' and ok_i = (ok_i'range => '0') then
                     err_r <= x"9"; state <= CP_REFUSED;
                  end if;
                  v_trk <= (others => '0');
                  v_off <= to_unsigned(256, 19);
                   trk_fmt <= (others => '1');   -- M4051: un .dsk estandar no tiene huecos
                  if extended = '1' then
                     addr_r  <= to_unsigned(C_H_TTAB, 18);
                     rd_wait <= 2; ret <= CP_V_TSZ; state <= CP_RD;
                  else
                     addr_r  <= to_unsigned(256 + C_T_SIDE, 18);
                     rd_wait <= 2; ret <= CP_V_SIDE; state <= CP_RD;
                  end if;

               -- ---- validacion pista a pista ----------------------------------------------
               -- En un EDSK cada pista puede medir distinto, y una pista SIN FORMATEAR se marca
               -- con tamano 0: no ocupa ni un byte del fichero y ahi literalmente no hay nada.
               -- Se marca en trk_fmt y se SALTA al escribir (M4051).
               when CP_V_TSZ =>
                  if unsigned(rd_data) = 0 then
                     trk_fmt(to_integer(v_trk)) <= '0';
                     tsize <= (others => '0');      -- no ocupa ni un byte
                     state <= CP_V_NEXT;            -- M4051: saltarla, no rechazar
                  else
                     trk_fmt(to_integer(v_trk)) <= '1';
                     tsize   <= unsigned(rd_data) & x"00";
                     addr_r  <= v_off(17 downto 0) + to_unsigned(C_T_SIDE, 18);
                     rd_wait <= 2; ret <= CP_V_SIDE; state <= CP_RD;
                  end if;

               when CP_V_SIDE =>
                  if rd_data /= x"00" then
                     err_r <= x"2"; state <= CP_REFUSED;
                  else
                     addr_r  <= v_off(17 downto 0) + to_unsigned(C_T_NSEC, 18);
                     rd_wait <= 2; ret <= CP_V_NSEC; state <= CP_RD;
                  end if;

               when CP_V_NSEC =>
                  if unsigned(rd_data) = 0 or unsigned(rd_data) > G_MAXSEC then
                     err_r <= x"4"; state <= CP_REFUSED;
                  else
                     v_nsec  <= unsigned(rd_data(4 downto 0));
                     v_sec   <= 0;
                     addr_r  <= v_off(17 downto 0) + to_unsigned(C_T_LIST + 1, 18);
                     rd_wait <= 2; ret <= CP_V_SEC_H; state <= CP_RD;
                  end if;

               when CP_V_SEC_H =>
                  if rd_data /= x"00" then
                     err_r <= x"6"; state <= CP_REFUSED;
                  else
                     addr_r  <= v_off(17 downto 0) + to_unsigned(C_T_LIST + 3, 18) +
                                to_unsigned(v_sec * 8, 18);
                     rd_wait <= 2; ret <= CP_V_SEC_N; state <= CP_RD;
                  end if;

               when CP_V_SEC_N =>
                  -- N=2 son 512 bytes. Exigirlo aqui es lo que permite que el calculo de la
                  -- direccion de datos sea una multiplicacion y no una tabla acumulada.
                  if rd_data /= x"02" then
                     err_r <= x"5"; state <= CP_REFUSED;
                  elsif v_sec + 1 >= to_integer(v_nsec) then
                     state <= CP_V_NEXT;
                  else
                     v_sec   <= v_sec + 1;
                     addr_r  <= v_off(17 downto 0) + to_unsigned(C_T_LIST + 1, 18) +
                                to_unsigned((v_sec + 1) * 8, 18);
                     rd_wait <= 2; ret <= CP_V_SEC_H; state <= CP_RD;
                  end if;

               when CP_V_NEXT =>
                  off_tab(to_integer(v_trk)) <= v_off(17 downto 0);
                  nxt_off := v_off + resize(tsize, 19);
                  if nxt_off > to_unsigned(G_BUFSZ, 19) then
                     err_r <= x"8"; state <= CP_REFUSED;
                  elsif v_trk + 1 >= ntracks then
                     -- Todas validas. A partir de aqui hold_o ya puede bajar.
                     state <= CP_ARM;
                  else
                     v_off <= nxt_off;
                     v_trk <= v_trk + 1;
                     if extended = '1' then
                        addr_r  <= to_unsigned(C_H_TTAB, 18) + resize(v_trk + 1, 18);
                        rd_wait <= 2; ret <= CP_V_TSZ; state <= CP_RD;
                     else
                        addr_r  <= nxt_off(17 downto 0) + to_unsigned(C_T_SIDE, 18);
                        rd_wait <= 2; ret <= CP_V_SIDE; state <= CP_RD;
                     end if;
                  end if;

               -- ---- preparacion de la pista que hay bajo la cabeza -------------------------
               when CP_ARM =>
                  p_ok  <= '0';
                  -- M4037: si el secuenciador termina estando nosotros aqui, es que la mecanica
                  -- no respondio (phys_error: normalmente, ningun disquete dentro). Sin esta
                  -- salida nos quedariamos sujetando para siempre, con el motor girando y el LED
                  -- amarillo, porque la peticion automatica no se suelta mientras queden pistas
                  -- pendientes. No es un cuelgue, pero tampoco se sale solo.
                  if scan_end = '1' then
                     state <= CP_DONE;
                   elsif (mode_wb_i = '1' and wb_todo = '0') or trk_unf = '1' then
                     -- Nada que escribir en esta pista. Si es que esta sucia pero no se leyo
                     -- entera, se cuenta y su bit de sucio se queda: esos datos no han llegado
                     -- al disquete y hay que seguir diciendolo.
                     if wb_blk = '1' then
                        blk_cnt <= blk_cnt + 1;
                     end if;
                     p_trk <= unsigned(track_i);
                     state <= CP_SKIP;
                  elsif unsigned(track_i) < ntracks then
                     t_off   <= off_tab(to_integer(unsigned(track_i)));
                     addr_r  <= off_tab(to_integer(unsigned(track_i))) +
                                to_unsigned(C_T_NSEC, 18);
                     rd_wait <= 2; ret <= CP_P_NSEC; state <= CP_RD;
                  end if;
                  -- Si la cabeza esta en una pista que la imagen no tiene, se queda aqui con
                  -- hold_o alto: nunca se escribe fuera de la imagen.

               when CP_P_NSEC =>
                  p_nsec  <= unsigned(rd_data(4 downto 0));
                  p_sec   <= 0;
                  addr_r  <= t_off + to_unsigned(C_T_LIST, 18);
                  rd_wait <= 2; ret <= CP_P_C; state <= CP_RD;

               when CP_P_C =>
                  id_c(p_sec) <= rd_data;
                  addr_r  <= t_off + to_unsigned(C_T_LIST + 1, 18) + to_unsigned(p_sec * 8, 18);
                  rd_wait <= 2; ret <= CP_P_H; state <= CP_RD;

               when CP_P_H =>
                  id_h(p_sec) <= rd_data;
                  addr_r  <= t_off + to_unsigned(C_T_LIST + 2, 18) + to_unsigned(p_sec * 8, 18);
                  rd_wait <= 2; ret <= CP_P_R; state <= CP_RD;

               when CP_P_R =>
                  id_r(p_sec) <= rd_data;
                  addr_r  <= t_off + to_unsigned(C_T_LIST + 3, 18) + to_unsigned(p_sec * 8, 18);
                  rd_wait <= 2; ret <= CP_P_N; state <= CP_RD;

               when CP_P_N =>
                  id_n(p_sec) <= rd_data;
                  state <= CP_P_NEXT;

               when CP_P_NEXT =>
                  -- El tope de G_MAXSEC lo garantiza ya la validacion, pero p_sec indexa cuatro
                  -- arrays: si alguna vez se leyera un numero de sectores mayor, aqui se saldria
                  -- de rango en vez de parar. La guarda cuesta un comparador.
                  if p_sec + 1 >= to_integer(p_nsec) or p_sec = G_MAXSEC - 1 then
                     p_trk <= unsigned(track_i);
                     p_ok  <= '1';
                     -- M4036: el bit de sucio se borra AQUI, al empezar, no al terminar. Si se
                     -- borrara al terminar, una escritura del CPC en esta misma pista durante
                     -- los 200 ms que dura la grabacion volveria a marcarla sucia y el borrado
                     -- posterior se la comeria: esos datos no llegarian nunca al disquete y
                     -- nada lo indicaria. Borrando al empezar, esa escritura vuelve a marcar la
                     -- pista y la recoge la pasada siguiente. Grabar una pista de mas es
                     -- barato; perder una escritura en silencio, no.
                     wrote_r <= '1';
                     state <= CP_FEED;
                  else
                     p_sec   <= p_sec + 1;
                     addr_r  <= t_off + to_unsigned(C_T_LIST, 18) +
                                to_unsigned((p_sec + 1) * 8, 18);
                     rd_wait <= 2; ret <= CP_P_C; state <= CP_RD;
                  end if;

               -- Pista preparada: hold_o cae, floppy_scan arranca el escritor y este va pidiendo
               -- bytes por w_sec_i/w_off_i. Aqui solo se vigila el cambio de pista y el final.
               when CP_FEED =>
                  if scan_end = '1' then
                     trk_cnt <= trk_cnt + 1;
                     state   <= CP_DONE;
                  elsif unsigned(track_i) /= p_trk then
                     trk_cnt <= trk_cnt + 1;
                     p_ok    <= '0';
                     state   <= CP_ARM;
                  end if;

               -- Pista que no hay que escribir: se le dice al secuenciador que pase de largo.
               -- WGATE no se abre, la cabeza solo se mueve.
               when CP_SKIP =>
                  skip_r <= '1';
                  if scan_end = '1' then
                     state <= CP_DONE;
                  elsif unsigned(track_i) /= p_trk then
                     skip_r <= '0';
                     state  <= CP_ARM;
                  end if;

               when CP_DONE =>
                  null;   -- se sale desmarcando la opcion del menu (enable_i)

               when CP_REFUSED =>
                  null;

            end case;
         end if;
      end if;
   end process main_proc;

end architecture beh;
