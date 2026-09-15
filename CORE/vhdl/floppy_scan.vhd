---------------------------------------------------------------------------------------------------------
-- CPC4MEGA65 - Milestone 4, fase B2b-i: recorrido del disco entero
--
-- Encadena floppy_phys (mecanica) y floppy_mfm (lectura) para recorrer las 40 pistas de un disco
-- con formato CPC y comprobar que TODAS se leen igual de bien que la pista 0. Todavia no
-- escribe nada en el buffer de imagen ni sintetiza el .DSK: esto valida la ultima pieza de
-- hardware que quedaba sin probar, la busqueda de pista.
--
-- Por que 40 pistas: el formato DATA del CPC son 40 pistas de una cara. La disquetera de 3,5"
-- del MEGA65 es de 80, pero AMSDOS pide las pistas 0..39 y la disquetera da un paso por pulso,
-- asi que los datos ocupan las pistas fisicas 0..39 y la mitad interior queda sin usar. No hay
-- doble paso que compensar.
--
-- Criterio de exito: las 40 pistas dan el mismo numero de sectores que la pista 0.
---------------------------------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity floppy_scan is
   generic (
      G_TRACKS    : natural := 40
   );
   port (
      clk_i          : in  std_logic;
      rst_i          : in  std_logic;

      enable_i       : in  std_logic;

      -- Hacia floppy_phys
      phys_ready_i   : in  std_logic;
      phys_error_i   : in  std_logic;
      seek_track_o   : out std_logic_vector(6 downto 0);
      seek_start_o   : out std_logic;

      -- Hacia floppy_mfm
      mfm_restart_o  : out std_logic;
      -- M4022: sectores esperados por pista (la referencia que fija la pista 0). Vale 0 hasta
      -- que la pista 0 termina, que es justo lo que floppy_mfm necesita para no aplicar el
      -- criterio nuevo en la pista que establece la referencia.
      mfm_expect_o   : out std_logic_vector(4 downto 0);
      mfm_done_i     : in  std_logic;
      mfm_count_i    : in  std_logic_vector(4 downto 0);
      -- Numero de pista que viene ESCRITO en la cabecera de los sectores. Es la medida que
      -- dice si la cabeza esta donde creemos, independientemente de cuantos sectores se lean.
      mfm_id_track_i : in  std_logic_vector(7 downto 0);
      -- Numero de SECTOR leido. Distingue de que formato es la pista: el PC numera 1..9 y el
      -- CPC &C1..&C9. Es lo unico que separa "he formateado bien" de "no he escrito nada"
      -- cuando se formatea sobre un disco que ya tenia 9 sectores por pista.
      mfm_id_sector_i : in std_logic_vector(7 downto 0);

      -- Resultado del recorrido
      scan_done_o    : out std_logic;
      -- Pistas cuyo recuento NO coincide con el de la pista 0. Cero = disco entero legible.
      bad_tracks_o   : out std_logic_vector(4 downto 0);
      -- Sectores por pista observados en la pista 0, que es la referencia
      sect_ref_o     : out std_logic_vector(4 downto 0);
      cur_track_o    : out std_logic_vector(6 downto 0);
      -- Hacia floppy_dsk: arranque de imagen nueva y fin de cada pista
      dsk_start_o    : out std_logic;
      track_done_o   : out std_logic;
      -- M4021: la pista que ACABA de terminar, registrada junto con track_done_o.
      -- No vale usar track_o para esto: track_done_o esta registrado, asi que cuando el pulso
      -- llega a floppy_dsk la cuenta de pista YA se ha incrementado en el mismo flanco. El
      -- resultado era que cada cabecera de pista se escribia en la ranura de la SIGUIENTE, la
      -- pista 0 se quedaba sin cabecera y la de la 39 caia fuera de la imagen. Encontrado con
      -- el volcado de telemetria de M4020, no razonando.
      done_track_o   : out std_logic_vector(6 downto 0);
      -- Diagnostico de posicionamiento, pensado para contarse de un vistazo en el LED:
      --   1 = la cabeza esta EXACTAMENTE donde se le pide (id_c = pista pedida)
      --   2 = se mueve el DOBLE de lo pedido (id_c = 2 x pista pedida)
      --   3 = ninguna de las dos, hay que mirarlo de otra forma
      pos_code_o     : out std_logic_vector(4 downto 0);
      -- '1' = los sectores leidos llevan numeracion del CPC (&Cx)
      id_is_cpc_o    : out std_logic
   );
end floppy_scan;

architecture beh of floppy_scan is

   -- SC_READ_ARM existe para cerrar una carrera real: mfm_restart_o se registra, asi que
   -- floppy_mfm no baja su done_o hasta el ciclo siguiente. Sin este estado intermedio,
   -- SC_READ veia el done_o de la pista ANTERIOR, todavia alto, y daba la pista por leida al
   -- instante con el recuento viejo. Aqui se espera a ver done_o bajo antes de esperarlo alto.
   type t_state is (SC_IDLE, SC_WAIT_READY, SC_READ_ARM, SC_READ, SC_EVAL, SC_SEEK, SC_DONE);
   signal state      : t_state := SC_IDLE;
   signal done_trk_r : unsigned(6 downto 0) := (others => '0');   -- M4021

   -- Banderas de posicionamiento: empiezan a '1' y solo se caen si alguna pista las contradice
   signal pos_exact  : std_logic := '1';
   signal pos_double : std_logic := '1';
   signal id_cpc_r   : std_logic := '0';

   signal track      : unsigned(6 downto 0) := (others => '0');
   signal sect_ref   : unsigned(4 downto 0) := (others => '0');
   signal bad_cnt    : unsigned(4 downto 0) := (others => '0');
   signal restart_r  : std_logic := '0';
   signal seek_r     : std_logic := '0';
   signal done_r     : std_logic := '0';
   signal dsk_strt_r : std_logic := '0';
   signal trk_done_r : std_logic := '0';

begin

   seek_track_o  <= std_logic_vector(track);
   seek_start_o  <= seek_r;
   mfm_restart_o <= restart_r;
   mfm_expect_o  <= std_logic_vector(sect_ref);
   scan_done_o   <= done_r;
   bad_tracks_o  <= std_logic_vector(bad_cnt);
   sect_ref_o    <= std_logic_vector(sect_ref);
   cur_track_o   <= std_logic_vector(track);
   id_is_cpc_o   <= id_cpc_r;
   dsk_start_o   <= dsk_strt_r;
   done_track_o  <= std_logic_vector(done_trk_r);
   track_done_o  <= trk_done_r;
   pos_code_o    <= "00001" when pos_exact  = '1' else
                    "00010" when pos_double = '1' else
                    "00011";

   fsm_proc : process (clk_i)
   begin
      if rising_edge(clk_i) then
         restart_r  <= '0';
         seek_r     <= '0';
         dsk_strt_r <= '0';
         trk_done_r <= '0';

         if rst_i = '1' or enable_i = '0' then
            state      <= SC_IDLE;
            track      <= (others => '0');
            sect_ref   <= (others => '0');
            bad_cnt    <= (others => '0');
            done_r     <= '0';
            pos_exact  <= '1';
            pos_double <= '1';
            id_cpc_r   <= '0';
         else
            case state is

               when SC_IDLE =>
                  -- floppy_phys arranca solo con enable_i: aqui se espera a que recalibre.
                  track      <= (others => '0');
                  bad_cnt    <= (others => '0');
                  dsk_strt_r <= '1';        -- empieza una imagen nueva
                  state      <= SC_WAIT_READY;

               when SC_WAIT_READY =>
                  if phys_error_i = '1' then
                     state <= SC_DONE;          -- la mecanica no responde, no hay nada que leer
                  elsif phys_ready_i = '1' then
                     restart_r <= '1';          -- empieza a contar esta pista
                     state     <= SC_READ_ARM;
                  end if;

               when SC_READ_ARM =>
                  -- Ver el comentario del tipo t_state: hay que ver done_o BAJO antes de
                  -- ponerse a esperarlo alto, o se lee el resultado de la pista anterior.
                  if mfm_done_i = '0' then
                     state <= SC_READ;
                  end if;

               when SC_READ =>
                  if mfm_done_i = '1' then
                     state <= SC_EVAL;
                  end if;

               when SC_EVAL =>
                  -- Pista terminada: floppy_dsk escribe ahora su bloque de informacion, que ya
                  -- conoce la lista de sectores. OJO: tiene que usar done_track_o, NO track_o -
                  -- ver el comentario de ese puerto.
                  --
                  -- Lo que ponia aqui antes era FALSO y costo cinco builds: "track_i todavia
                  -- vale la pista actual en este ciclo (el incremento de abajo no surte efecto
                  -- hasta el siguiente)". Cierto dentro de ESTE proceso, pero trk_done_r
                  -- tambien esta registrado, asi que el consumidor ve las dos cosas a la vez -
                  -- el pulso Y la pista ya incrementada.
                  trk_done_r <= '1';
                  done_trk_r <= track;      -- M4021: la pista que se acaba de leer

                  if track = 0 then
                     -- La pista 0 fija la referencia de cuantos sectores tiene este disco
                     sect_ref <= unsigned(mfm_count_i);
                  elsif unsigned(mfm_count_i) /= sect_ref then
                     if bad_cnt /= "11111" then
                        bad_cnt <= bad_cnt + 1;
                     end if;
                  end if;

                  -- Diagnostico de posicionamiento: solo tiene sentido en pistas que se han
                  -- leido bien (si no hay sectores, id_c es el de la pista anterior) y a partir
                  -- de la 1 (en la 0 no se distingue N de 2N).
                  -- Numeracion &Cx = formato del CPC. Se mira en cualquier pista leida.
                  if unsigned(mfm_count_i) /= 0 and mfm_id_sector_i(7 downto 4) = "1100" then
                     id_cpc_r <= '1';
                  end if;

                  if track /= 0 and unsigned(mfm_count_i) = sect_ref and sect_ref /= 0 then
                     if unsigned(mfm_id_track_i) /= track then
                        pos_exact <= '0';
                     end if;
                     if unsigned(mfm_id_track_i) /= (track & '0') then
                        pos_double <= '0';
                     end if;
                  end if;

                  if track = G_TRACKS - 1 then
                     state <= SC_DONE;
                  else
                     track  <= track + 1;
                     seek_r <= '1';
                     state  <= SC_SEEK;
                  end if;

               when SC_SEEK =>
                  -- phys_ready_i baja en cuanto floppy_phys acepta la busqueda; se espera a que
                  -- vuelva a subir, que es cuando la cabeza esta colocada y asentada.
                  if phys_ready_i = '0' then
                     state <= SC_WAIT_READY;
                  end if;

               when SC_DONE =>
                  done_r <= '1';

            end case;
         end if;
      end if;
   end process fsm_proc;

end architecture beh;
