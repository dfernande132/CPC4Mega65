---------------------------------------------------------------------------------------------------------
-- CPC4MEGA65 - Milestone 4, fase C1: formateo de pista (codificador MFM)
--
-- Escribe una pista entera con formato DATA del CPC: huecos, sincronismos, marcas de direccion,
-- campos de ID con su CRC y sectores rellenos de 0xE5. Es la primera vez que este proyecto
-- activa f_wgate_o, o sea la primera vez que puede destruir datos de verdad.
--
-- POR QUE FORMATEAR ANTES QUE ESCRIBIR UN SECTOR: formatear escribe de indice a indice, sin
-- tener que sincronizarse con nada de lo que ya hay en el disco. Escribir un sector concreto
-- obliga a leer hasta su marca de datos y activar la escritura en un punto exacto a mitad de
-- pista, que es bastante mas delicado. Y ademas formatear es AUTOVERIFICABLE: se formatea y se
-- relee con el camino de lectura que ya esta validado.
--
-- SEGURIDAD - f_wgate_o es la señal que puede borrar un disquete:
--   * Solo se activa dentro de los estados que escriben de verdad, nunca por defecto.
--   * Hace falta enable_i Y start_i Y que la mecanica diga ready.
--   * Si el disquete esta protegido contra escritura (f_writeprotect_i), se niega y lo dice.
--     Esa comprobacion es gratis: la da la propia disquetera.
--   * Se arranca SIEMPRE en un pulso de indice, para no empezar a escribir a mitad de pista.
--
-- CODIFICACION MFM: cada bit de datos son DOS celdas de 2us, reloj y dato. La celda de reloj
-- vale 1 solo si el bit anterior Y el actual son 0. Una transicion de flujo por cada celda a 1.
-- A 64 MHz, 2us = 128 ciclos.
--
-- Las marcas de sincronismo NO se codifican con esa regla: llevan un pulso de reloj omitido a
-- proposito para que no puedan aparecer en datos normales, asi que se emiten como patron de
-- celdas literal (0x4489 para A1, 0x5224 para C2). Es la contrapartida exacta de lo que hace
-- el separador de lectura al buscar 0x4489.
--
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
---------------------------------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity floppy_write is
   generic (
      G_CLK_HZ    : natural := 64_000_000;
      G_SECTORS   : natural := 9;
      G_FIRST_ID  : natural := 16#C1#      -- formato DATA del CPC: sectores &C1..&C9
   );
   port (
      clk_i          : in  std_logic;
      rst_i          : in  std_logic;

      enable_i       : in  std_logic;                     -- permiso general (menu)
      start_i        : in  std_logic;                     -- pulso: formatea una pista
      track_i        : in  std_logic_vector(6 downto 0);  -- numero de pista a grabar en los ID
      ready_i        : in  std_logic;                     -- floppy_phys: cabeza colocada
      index_i        : in  std_logic;                     -- pulso de indice
      wprot_i        : in  std_logic;                     -- '1' = disquete protegido

      busy_o         : out std_logic;
      done_o         : out std_logic;
      refused_o      : out std_logic;                     -- no se hizo: protegido contra escritura
      -- '1' = se llegaron a emitir los bytes de una pista entera. Separa "no escribio nada"
      -- (la maquina se atasco) de "escribio pero no se puede leer" (problema de codificacion),
      -- que son dos fallos con causas completamente distintas.
      wrote_full_o   : out std_logic;

      f_wgate_o      : out std_logic;                     -- activo bajo
      f_wdata_o      : out std_logic;                     -- activo bajo, un pulso por transicion

      -- M4026 TELEMETRIA DEL FORMATEO. Hasta ahora la unica salida de este modulo era el LED,
      -- que es exactamente la situacion de la que salimos en la lectura - y que ademas aqui no
      -- informa: el color depende de id_cpc, que lo produce floppy_scan y solo corre al LEER,
      -- asi que justo despues de formatear siempre sale ambar, se haya escrito o no.
      --
      -- Estos contadores SOBREVIVEN a que se apague el item de menu (solo los borra un reset
      -- o un formateo nuevo), asi que la lectura posterior los arrastra hasta el volcado.
      --
      -- Como leerlos: un formateo correcto a 250 kbps es UNA VUELTA de disco = 200 ms =
      -- 12.800.000 ciclos a 64 MHz, con unas 50.000 transiciones. Si wgate_cyc sale muy por
      -- debajo, la maquina de estados se recorre sin respetar la temporizacion de celda; si
      -- sale 0, la puerta no llego a abrirse.
      -- CPC4MEGA65 M4034: MODO ORIGEN EXTERNO.
      --
      -- Con src_en_i a '0' este modulo se comporta EXACTAMENTE como hasta ahora: formatea con
      -- identificadores C1..C9 y sectores de 0xE5. Con src_en_i a '1' los identificadores y los
      -- datos vienen de fuera, que es lo que convierte al formateador en copiador: la
      -- temporizacion, los huecos, los sincronismos y los CRC -lo que ya esta probado en
      -- hardware con 40 pistas- no cambian ni una celda.
      --
      -- Presupuesto de tiempo: un byte son 16 celdas de 2 us = 32 us = 2048 ciclos a 64 MHz, y
      -- una lectura de BRAM es 1 ciclo. La direccion va por delante miles de ciclos, asi que no
      -- hace falta ni peticion ni acuse: basta con presentar el dato.
      src_en_i       : in  std_logic := '0';
      src_nsec_i     : in  std_logic_vector(4 downto 0) := (others => '0');  -- sectores de ESTA pista
      src_id_c_i     : in  std_logic_vector(7 downto 0) := (others => '0');
      src_id_h_i     : in  std_logic_vector(7 downto 0) := (others => '0');
      src_id_r_i     : in  std_logic_vector(7 downto 0) := (others => '0');
      src_id_n_i     : in  std_logic_vector(7 downto 0) := (others => '0');
      src_data_i     : in  std_logic_vector(7 downto 0) := (others => '0');
      src_sec_o      : out std_logic_vector(3 downto 0);   -- sector en curso: elige el ID
      src_off_o      : out std_logic_vector(9 downto 0);   -- byte dentro del sector, 0..511

      tlm_wgate_o    : out std_logic_vector(31 downto 0);  -- ciclos con WGATE abierto
      tlm_wdata_o    : out std_logic_vector(31 downto 0);  -- transiciones emitidas
      tlm_starts_o   : out std_logic_vector(7 downto 0);   -- formateos arrancados
      tlm_refus_o    : out std_logic_vector(7 downto 0);   -- rechazados por proteccion

      -- CPC4MEGA65 M4038: POR QUE SE CIERRA LA PUERTA.
      --
      -- El contador de ciclos de WGATE dice CUANTO se escribio; no dice POR QUE se dejo de
      -- escribir, y son dos preguntas distintas. En M4036 y M4037 salio 22 y 170 -o sea, cero-
      -- y se gastaron dos builds adivinando la causa. Esto responde la segunda pregunta:
      --   tlm_abort_o     cierres con enable_i ya caido = alguien quito el permiso
      --   tlm_idxend_o    cierres por indice = final NORMAL de pista
      --   tlm_stopst_o    en que estado estaba la maquina en el ultimo cierre
      --   tlm_wgmax_o     la apertura mas larga en ciclos (una pista entera son ~12,8 M)
      -- Y ademas los dos primeros contadores NO se reinician en cada arranque, al reves que
      -- wgate_cyc: acumulan durante todo el recorrido, que es lo que hace falta para ver un
      -- patron en vez de una foto del ultimo intento.
      tlm_abort_o    : out std_logic_vector(7 downto 0);
      tlm_idxend_o   : out std_logic_vector(7 downto 0);
      tlm_stopst_o   : out std_logic_vector(7 downto 0);
      tlm_wgmax_o    : out std_logic_vector(31 downto 0);

      -- M4039: pulsos de indice vistos CON WGATE ABIERTO, acumulados en todo el recorrido.
      -- Una pista bien escrita ve EXACTAMENTE UNO: el que la cierra al completar la vuelta.
      -- Si sale el doble que pistas escritas, el acoplamiento del indice queda demostrado en
      -- vez de supuesto. Y tlm_blind_o cuenta los que la ventana ciega ha RECHAZADO, que es la
      -- prueba directa de que el arreglo esta actuando.
      tlm_idxwr_o    : out std_logic_vector(15 downto 0);
      tlm_blind_o    : out std_logic_vector(15 downto 0);

      -- M4052: rechazos por NO VER EL INDICE, o sea por no haber disquete dentro. Van aparte de
      -- tlm_refus_o porque ese cuenta los dos motivos y son diagnosticos opuestos: "protegido"
      -- se arregla moviendo la pestana, "sin disquete" metiendo uno. Con los testers de por
      -- medio, un rechazo sin causa es un informe que no sirve.
      tlm_noidx_o    : out std_logic_vector(7 downto 0)
   );
end floppy_write;

architecture beh of floppy_write is

   -- Una celda MFM son 2us a 250 kbps
   constant C_CELL_CYC : natural := (G_CLK_HZ / 1_000_000) * 2;     -- 128 @64MHz
   -- Ancho del pulso de escritura. La especificacion pide del orden de cientos de ns; 250ns
   -- va sobrado y queda lejos de los 2us de la celda siguiente.
   constant C_PULSE_CYC : natural := (G_CLK_HZ / 1_000_000) / 4;    -- 16 ciclos = 250ns

   constant C_GAP      : std_logic_vector(7 downto 0) := x"4E";
   constant C_ZERO     : std_logic_vector(7 downto 0) := x"00";
   constant C_FILLER   : std_logic_vector(7 downto 0) := x"E5";
   constant C_MARK_IAM : std_logic_vector(7 downto 0) := x"FC";
   constant C_MARK_ID  : std_logic_vector(7 downto 0) := x"FE";
   constant C_MARK_DAT : std_logic_vector(7 downto 0) := x"FB";

   -- Patrones de celdas de las marcas con reloj omitido
   constant C_CELLS_A1 : std_logic_vector(15 downto 0) := x"4489";
   constant C_CELLS_C2 : std_logic_vector(15 downto 0) := x"5224";

   -- Longitudes del formato DATA del CPC
   -- CPC4MEGA65 M4039: VENTANA CIEGA DEL INDICE.
   --
   -- Una pista dura una vuelta entera: 200 ms a 300 RPM. No puede terminar legitimamente a los
   -- 4 us de empezar, y sin embargo eso es lo que se midio en hardware una y otra vez (aperturas
   -- de WGATE de 50 a 250 ciclos, en las 40 pistas, en los dos modos y en dos builds separados
   -- por cinco versiones, incluida la que copio Bruce Lee y cuyo disquete arranca en un CPC
   -- real). El indice se ensucia cuando el amplificador de escritura conduce.
   --
   -- Durante los primeros 100 ms tras abrir la puerta se ignora el indice. Es la mitad de una
   -- vuelta: no puede tapar el indice bueno ni con el motor un 20 % rapido, y convierte un
   -- rebote en algo inocuo en vez de fatal.
   constant C_IDX_BLIND : natural := (G_CLK_HZ / 1000) * 100;   -- 100 ms
   -- Con G_CLK_HZ menor que 1000 la constante seria 0, wg_age nunca incrementaria y la
   -- ventana desapareceria EN SILENCIO. De ahi la asercion de mas abajo: lo convierte en un
   -- error de elaboracion en vez de en un comportamiento raro en hardware.
   signal   wg_age      : natural range 0 to C_IDX_BLIND := 0;  -- ciclos con la puerta abierta
   signal   idxwr_cnt   : unsigned(15 downto 0) := (others => '0');
   signal   blind_cnt   : unsigned(15 downto 0) := (others => '0');

   -- CPC4MEGA65 M4052: SIN DISQUETE DENTRO, LA ESCRITURA SE NIEGA EN VEZ DE ESPERAR.
   --
   -- W_WAIT_IDX espera un pulso de indice para arrancar la pista en el sitio bueno. Sin disquete
   -- ese pulso NO LLEGA NUNCA: el motor gira, el plato no. Y no habia salida - ni por tiempo ni
   -- por cancelacion. La cadena entera se quedaba parada: floppy_write en W_WAIT_IDX,
   -- floppy_scan en SC_FMT esperando fmt_done, ningun scan_done, y por tanto tampoco el bit de
   -- estado que desde M4045 desmarca la opcion del menu. Motor girando hasta que el usuario lo
   -- desmarcase a mano, que es justo lo que el desmarcado automatico le ha ensenado a no hacer.
   --
   -- El recalibrado NO lo detecta: el sensor de pista 0 es mecanico y responde igual con la
   -- unidad vacia, asi que phys_ready sube sin disquete. Y disk_in_o, que si lo sabe, solo se
   -- usaba para el color del LED.
   --
   -- 1 s son cinco vueltas a 300 RPM: no puede confundirse con un motor lento.
   --
   -- Se sale por W_REFUSED, que es el camino que ya existe para "no se puede escribir" y que
   -- floppy_scan ya sabe atender (SC_FMT_ARM/SC_FMT -> SC_DONE). O sea que el recorrido termina,
   -- la opcion se desmarca sola y el LED destella, sin tocar nada mas.
   constant C_NOIDX_TMO : natural := G_CLK_HZ;                  -- 1 s
   signal   noidx_tmr   : natural range 0 to C_NOIDX_TMO := 0;
   signal   noidx_cnt   : unsigned(7 downto 0) := (others => '0');

   constant C_GAP4A : natural := 80;
   constant C_SYNC  : natural := 12;
   constant C_GAP1  : natural := 50;
   constant C_GAP2  : natural := 22;
   constant C_GAP3  : natural := 78;
   constant C_SECSZ : natural := 512;

   type t_state is (W_IDLE, W_WAIT_IDX, W_GAP4A, W_SYNC1, W_IAM_A, W_IAM_M, W_GAP1,
                    W_SSYNC, W_IDAM_A, W_IDAM_M, W_ID_C, W_ID_H, W_ID_R, W_ID_N,
                    W_ID_CRC, W_GAP2, W_DSYNC, W_DAM_A, W_DAM_M, W_DATA, W_DAT_CRC,
                    W_GAP3, W_GAP4B, W_DONE, W_REFUSED);
   signal state    : t_state := W_IDLE;

   signal cnt      : natural range 0 to 1023 := 0;      -- repeticiones dentro de un tramo
   signal sec_idx  : natural range 0 to 15 := 0;

   -- Motor de celdas: convierte un byte (o un patron literal) en 16 celdas cronometradas
   signal cells    : std_logic_vector(15 downto 0) := (others => '0');
   signal cell_cnt : natural range 0 to 15 := 0;
   signal cell_tmr : natural range 0 to C_CELL_CYC - 1 := 0;
   signal cell_bsy : std_logic := '0';
   signal cell_last: std_logic := '0';
   signal last_bit : std_logic := '0';                  -- ultimo bit de datos, para el reloj MFM
   signal pulse_tm : natural range 0 to C_PULSE_CYC := 0;

   signal load_req : std_logic := '0';                  -- el estado pide emitir un byte
   signal load_val : std_logic_vector(7 downto 0) := (others => '0');
   signal load_raw : std_logic := '0';                  -- '1' = load_cells es literal (marca)
   signal load_cel : std_logic_vector(15 downto 0) := (others => '0');

   signal crc      : std_logic_vector(15 downto 0) := (others => '1');
   signal crc_rst  : std_logic := '0';

   signal wgate_r  : std_logic := '1';
   signal wdata_r  : std_logic := '1';

   -- M4026: telemetria del formateo
   signal state_d    : t_state;
   signal wdata_d    : std_logic := '1';
   signal wgate_cyc  : unsigned(31 downto 0) := (others => '0');
   signal wdata_cnt  : unsigned(31 downto 0) := (others => '0');
   signal starts_cnt : unsigned(7 downto 0)  := (others => '0');
   signal refus_cnt  : unsigned(7 downto 0)  := (others => '0');
   signal abort_cnt  : unsigned(7 downto 0)  := (others => '0');   -- M4038
   signal idxend_cnt : unsigned(7 downto 0)  := (others => '0');
   signal stop_st    : unsigned(7 downto 0)  := (others => '0');

   -- CPC4MEGA65 M4054: EL RECHAZO SE ENGANCHA. DURABA DOS CICLOS.
   --
   -- refused_o salia de 'state = W_REFUSED', y de W_REFUSED se sale EN CUANTO start_i baja.
   -- start_i es un PULSO de un ciclo que manda floppy_scan, asi que el rechazo vivia dos ciclos
   -- y a los 30 ns ya no existia.
   --
   -- Bastaba mientras el unico que lo miraba era floppy_scan, que esta esperandolo en
   -- SC_FMT_ARM ese mismo ciclo. Pero el LED lo mira MUCHO despues: el destello se dispara
   -- cuando sube scan_done, varios ciclos mas tarde, y para entonces el rechazo ya se habia
   -- evaporado. Resultado en hardware: formatear un disquete PROTEGIDO daba LED VERDE.
   --
   -- Se limpia al EMPEZAR la operacion siguiente, no al terminar esta: asi sobrevive a que
   -- caiga enable_i, que es lo que pasa en cuanto el firmware desmarca la opcion del menu.
   signal en_d2      : std_logic := '0';
   signal refus_lat  : std_logic := '0';
   signal wg_run     : unsigned(31 downto 0) := (others => '0');
   signal wg_max     : unsigned(31 downto 0) := (others => '0');
   signal wgate_d    : std_logic := '1';

   -- El pulso de indice dura UN ciclo, y la maquina de formato solo mira su estado cuando el
   -- motor de celdas esta libre (una vez cada 2048 ciclos). Muestrearlo directamente ahi
   -- perderia casi todos los pulsos, asi que se engancha en una bandera aparte.
   signal idx_seen : std_logic := '0';

   -- Bytes emitidos en el formateo en curso. Una pista entera son ~6250 a 250 kbps.
   signal byte_cnt : unsigned(13 downto 0) := (others => '0');

   -- M4034: desplazamiento dentro del sector para el modo origen externo. W_DATA ya lleva un
   -- contador (cnt) pero cuenta HACIA ATRAS, y la direccion del buffer tiene que ir hacia
   -- delante; se lleva aparte en vez de invertir el que ya funciona.
   signal dat_off  : natural range 0 to 511 := 0;

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

   -- Codifica un byte en sus 16 celdas MFM. prev es el ultimo bit de datos emitido antes.
   function f_mfm(data : std_logic_vector(7 downto 0); prev : std_logic)
                  return std_logic_vector is
      variable c : std_logic_vector(15 downto 0);
      variable p : std_logic := prev;
   begin
      for i in 7 downto 0 loop
         -- celda de reloj: 1 solo si el bit anterior y el actual son 0
         c(i*2 + 1) := (not p) and (not data(i));
         c(i*2)     := data(i);
         p := data(i);
      end loop;
      return c;
   end function f_mfm;

begin

   assert C_IDX_BLIND > 0
      report "C_IDX_BLIND degenerado: la ventana ciega del indice no existiria"
      severity failure;

   f_wgate_o <= wgate_r;
   f_wdata_o <= wdata_r;

   -- M4026: telemetria del formateo. Proceso APARTE del FSM a proposito: el FSM se reinicia
   -- cuando enable_i baja (o sea al apagar el item de menu), y estos contadores tienen que
   -- sobrevivir a eso para que la lectura posterior los pueda volcar.
   tlm_wgate_o  <= std_logic_vector(wgate_cyc);
   tlm_wdata_o  <= std_logic_vector(wdata_cnt);
   tlm_starts_o <= std_logic_vector(starts_cnt);
   tlm_refus_o  <= std_logic_vector(refus_cnt);
   tlm_abort_o  <= std_logic_vector(abort_cnt);    -- M4038
   tlm_idxend_o <= std_logic_vector(idxend_cnt);
   tlm_stopst_o <= std_logic_vector(stop_st);
   tlm_wgmax_o  <= std_logic_vector(wg_max);
   tlm_idxwr_o  <= std_logic_vector(idxwr_cnt);    -- M4039
   tlm_blind_o  <= std_logic_vector(blind_cnt);
   tlm_noidx_o  <= std_logic_vector(noidx_cnt);    -- M4052

   stats_proc : process (clk_i)
   begin
      if rising_edge(clk_i) then
         state_d <= state;
         en_d2   <= enable_i;                 -- M4054
         wdata_d <= wdata_r;

         if rst_i = '1' then
            wgate_cyc  <= (others => '0');
            wdata_cnt  <= (others => '0');
            starts_cnt <= (others => '0');
            refus_cnt  <= (others => '0');
            refus_lat  <= '0';                -- M4054
         else
            -- Un formateo nuevo empieza de cero
            if state_d = W_IDLE and state = W_WAIT_IDX then
               wgate_cyc <= (others => '0');
               wdata_cnt <= (others => '0');
               if starts_cnt /= x"FF" then
                  starts_cnt <= starts_cnt + 1;
               end if;
            end if;

            -- M4054: pestillo del rechazo y borrado de wg_max al empezar una operacion nueva.
            if enable_i = '1' and en_d2 = '0' then
               refus_lat <= '0';
               wg_max    <= (others => '0');
            elsif state = W_REFUSED then
               refus_lat <= '1';
            end if;

            if state_d /= W_REFUSED and state = W_REFUSED then
               if refus_cnt /= x"FF" then
                  refus_cnt <= refus_cnt + 1;
               end if;
            end if;

            if wgate_r = '0' and wgate_cyc /= x"FFFFFFFF" then
               wgate_cyc <= wgate_cyc + 1;
            end if;

            -- M4038: apertura en curso, la mayor vista, y el motivo del ultimo cierre.
            -- M4039: indices vistos con la puerta abierta
            if index_i = '1' and wgate_r = '0' and idxwr_cnt /= x"FFFF" then
               idxwr_cnt <= idxwr_cnt + 1;
            end if;

            wgate_d <= wgate_r;
            if wgate_r = '0' then
               if wg_run /= x"FFFFFFFF" then
                  wg_run <= wg_run + 1;
               end if;
            elsif wgate_d = '0' then
               if wg_run > wg_max then
                  wg_max <= wg_run;
               end if;
               wg_run   <= (others => '0');
               stop_st  <= to_unsigned(t_state'pos(state), 8);
               if enable_i = '0' then
                  if abort_cnt /= x"FF" then abort_cnt <= abort_cnt + 1; end if;
               else
                  if idxend_cnt /= x"FF" then idxend_cnt <= idxend_cnt + 1; end if;
               end if;
            end if;

            -- Flanco de bajada de WDATA = una transicion de flujo escrita
            if wdata_r = '0' and wdata_d = '1' and wdata_cnt /= x"FFFFFFFF" then
               wdata_cnt <= wdata_cnt + 1;
            end if;
         end if;
      end if;
   end process stats_proc;
   busy_o    <= '0' when (state = W_IDLE or state = W_DONE or state = W_REFUSED) else '1';
   done_o    <= '1' when state = W_DONE else '0';
   refused_o <= '1' when (state = W_REFUSED or refus_lat = '1') else '0';   -- M4054
   wrote_full_o <= '1' when byte_cnt > 5000 else '0';

   -- M4034: el modulo dice en todo momento QUE byte necesita. El que copia solo tiene que
   -- traducirlo a direccion del buffer de montaje y presentar el dato.
   src_sec_o <= std_logic_vector(to_unsigned(sec_idx, 4));
   src_off_o <= std_logic_vector(to_unsigned(dat_off, 10));

   ------------------------------------------------------------------------------------------
   -- Motor de celdas: saca 16 celdas a 2us cada una, con un pulso por celda a '1'
   ------------------------------------------------------------------------------------------
   cell_proc : process (clk_i)
   begin
      if rising_edge(clk_i) then
         -- El pulso de escritura es corto y se apaga solo
         if pulse_tm /= 0 then
            pulse_tm <= pulse_tm - 1;
            if pulse_tm = 1 then
               wdata_r <= '1';
            end if;
         end if;

         if rst_i = '1' or enable_i = '0' then
            cell_bsy <= '0';
            wdata_r  <= '1';
            last_bit <= '0';
         elsif load_req = '1' and cell_bsy = '0' then
            if load_raw = '1' then
               cells    <= load_cel;
               -- Tras una marca de sincronismo, el ultimo bit de datos es el del propio byte
               last_bit <= load_val(0);
            else
               cells    <= f_mfm(load_val, last_bit);
               last_bit <= load_val(0);
            end if;
            cell_cnt <= 15;
            cell_tmr <= 0;
            cell_bsy <= '1';
         elsif cell_bsy = '1' then
            if cell_tmr = 0 then
               -- Emite la celda actual
               if cells(cell_cnt) = '1' then
                  wdata_r  <= '0';
                  pulse_tm <= C_PULSE_CYC;
               end if;
               cell_tmr <= C_CELL_CYC - 1;
               if cell_cnt = 0 then
                  cell_last <= '1';
               else
                  cell_cnt <= cell_cnt - 1;
               end if;
            else
               cell_tmr <= cell_tmr - 1;
               -- cell_bsy NO puede bajar al EMPEZAR la ultima celda, solo al terminarla: si
               -- baja antes, la maquina de formato carga el byte siguiente de inmediato y la
               -- ultima celda de CADA byte sale recortada. Con celdas de 2us eso desplaza todo
               -- el flujo y el disco sale ilegible.
               if cell_tmr = 1 and cell_last = '1' then
                  cell_bsy  <= '0';
                  cell_last <= '0';
               end if;
            end if;
         end if;
      end if;
   end process cell_proc;

   ------------------------------------------------------------------------------------------
   -- Maquina del formato: va pidiendo bytes al motor de celdas
   ------------------------------------------------------------------------------------------
   fmt_proc : process (clk_i)
      variable nxt : std_logic_vector(7 downto 0);
   begin
      if rising_edge(clk_i) then
         load_req <= '0';

         -- M4039: edad de la apertura actual de WGATE
         if wgate_r = '0' then
            if wg_age /= C_IDX_BLIND then
               wg_age <= wg_age + 1;
            end if;
         else
            wg_age <= 0;
         end if;

         if index_i = '1' then
            idx_seen <= '1';
         end if;

         if rst_i = '1' or enable_i = '0' then
            state    <= W_IDLE;
            wgate_r  <= '1';                -- inactivo: NUNCA se escribe por defecto
            cnt      <= 0;
            sec_idx  <= 0;
            idx_seen <= '0';
         else
            case state is

               when W_IDLE =>
                  wgate_r <= '1';
                  if start_i = '1' and ready_i = '1' then
                     if wprot_i = '1' then
                        state <= W_REFUSED;  -- la propia disquetera dice que no se puede
                     else
                        idx_seen  <= '0';     -- solo cuenta un indice a partir de AHORA
                        byte_cnt  <= (others => '0');
                        noidx_tmr <= C_NOIDX_TMO - 1;   -- M4052
                        state     <= W_WAIT_IDX;
                     end if;
                  end if;

               -- Se arranca siempre en indice, para no empezar a mitad de pista
               when W_WAIT_IDX =>
                  if idx_seen = '1' then
                     idx_seen <= '0';
                     wgate_r  <= '0';        -- AQUI empieza a escribirse de verdad
                     cnt      <= C_GAP4A - 1;
                     sec_idx  <= 0;
                     state    <= W_GAP4A;
                  elsif noidx_tmr = 0 then
                     -- M4052: cinco vueltas sin ver el indice. No hay disquete, o no gira.
                     if noidx_cnt /= x"FF" then
                        noidx_cnt <= noidx_cnt + 1;
                     end if;
                     state <= W_REFUSED;
                  else
                     noidx_tmr <= noidx_tmr - 1;
                  end if;

               when others =>
                  -- El resto de estados solo avanzan cuando el motor de celdas esta libre
                  if cell_bsy = '0' and load_req = '0' then
                     load_raw <= '0';
                     crc_rst  <= '0';
                     if byte_cnt /= 16383 then
                        byte_cnt <= byte_cnt + 1;
                     end if;

                     case state is
                        when W_GAP4A =>
                           load_val <= C_GAP; load_req <= '1';
                           if cnt = 0 then cnt <= C_SYNC - 1; state <= W_SYNC1;
                           else cnt <= cnt - 1; end if;

                        when W_SYNC1 =>
                           load_val <= C_ZERO; load_req <= '1';
                           if cnt = 0 then cnt <= 2; state <= W_IAM_A;
                           else cnt <= cnt - 1; end if;

                        when W_IAM_A =>
                           load_cel <= C_CELLS_C2; load_val <= x"C2";
                           load_raw <= '1'; load_req <= '1';
                           if cnt = 0 then state <= W_IAM_M;
                           else cnt <= cnt - 1; end if;

                        when W_IAM_M =>
                           load_val <= C_MARK_IAM; load_req <= '1';
                           cnt <= C_GAP1 - 1; state <= W_GAP1;

                        when W_GAP1 =>
                           load_val <= C_GAP; load_req <= '1';
                           if cnt = 0 then cnt <= C_SYNC - 1; state <= W_SSYNC;
                           else cnt <= cnt - 1; end if;

                        -- ---- campo de ID del sector ----
                        when W_SSYNC =>
                           load_val <= C_ZERO; load_req <= '1';
                           if cnt = 0 then cnt <= 2; crc <= x"FFFF"; state <= W_IDAM_A;
                           else cnt <= cnt - 1; end if;

                        when W_IDAM_A =>
                           load_cel <= C_CELLS_A1; load_val <= x"A1";
                           load_raw <= '1'; load_req <= '1';
                           crc <= f_crc16(crc, x"A1");     -- las 3 marcas entran en el CRC
                           if cnt = 0 then state <= W_IDAM_M;
                           else cnt <= cnt - 1; end if;

                        when W_IDAM_M =>
                           load_val <= C_MARK_ID; load_req <= '1';
                           crc <= f_crc16(crc, C_MARK_ID);
                           state <= W_ID_C;

                        when W_ID_C =>
                           if src_en_i = '1' then
                              nxt := src_id_c_i;
                           else
                              nxt := "0" & track_i;
                           end if;
                           load_val <= nxt; load_req <= '1';
                           crc <= f_crc16(crc, nxt);
                           state <= W_ID_H;

                        when W_ID_H =>
                           if src_en_i = '1' then
                              load_val <= src_id_h_i; load_req <= '1';
                              crc <= f_crc16(crc, src_id_h_i);
                           else
                              load_val <= x"00"; load_req <= '1';    -- cara 0
                              crc <= f_crc16(crc, x"00");
                           end if;
                           state <= W_ID_R;

                        when W_ID_R =>
                           if src_en_i = '1' then
                              nxt := src_id_r_i;
                           else
                              nxt := std_logic_vector(to_unsigned(G_FIRST_ID + sec_idx, 8));
                           end if;
                           load_val <= nxt; load_req <= '1';
                           crc <= f_crc16(crc, nxt);
                           state <= W_ID_N;

                        when W_ID_N =>
                           if src_en_i = '1' then
                              load_val <= src_id_n_i; load_req <= '1';
                              crc <= f_crc16(crc, src_id_n_i);
                           else
                              load_val <= x"02"; load_req <= '1';    -- N=2 -> 512 bytes
                              crc <= f_crc16(crc, x"02");
                           end if;
                           cnt <= 1; state <= W_ID_CRC;

                        when W_ID_CRC =>
                           load_val <= crc(15 downto 8); load_req <= '1';
                           crc <= crc(7 downto 0) & x"00";        -- deja el bajo arriba
                           if cnt = 0 then cnt <= C_GAP2 - 1; state <= W_GAP2;
                           else cnt <= cnt - 1; end if;

                        when W_GAP2 =>
                           load_val <= C_GAP; load_req <= '1';
                           if cnt = 0 then cnt <= C_SYNC - 1; state <= W_DSYNC;
                           else cnt <= cnt - 1; end if;

                        -- ---- campo de datos ----
                        when W_DSYNC =>
                           load_val <= C_ZERO; load_req <= '1';
                           if cnt = 0 then cnt <= 2; crc <= x"FFFF"; state <= W_DAM_A;
                           else cnt <= cnt - 1; end if;

                        when W_DAM_A =>
                           load_cel <= C_CELLS_A1; load_val <= x"A1";
                           load_raw <= '1'; load_req <= '1';
                           crc <= f_crc16(crc, x"A1");
                           if cnt = 0 then state <= W_DAM_M;
                           else cnt <= cnt - 1; end if;

                        when W_DAM_M =>
                           dat_off <= 0;                        -- M4034
                           load_val <= C_MARK_DAT; load_req <= '1';
                           crc <= f_crc16(crc, C_MARK_DAT);
                           cnt <= C_SECSZ - 1; state <= W_DATA;

                        when W_DATA =>
                           -- M4034: en modo copia el byte sale del buffer de montaje.
                           if src_en_i = '1' then
                              load_val <= src_data_i; load_req <= '1';
                              crc <= f_crc16(crc, src_data_i);
                           else
                              load_val <= C_FILLER; load_req <= '1';
                              crc <= f_crc16(crc, C_FILLER);
                           end if;
                           if dat_off < 511 then
                              dat_off <= dat_off + 1;
                           end if;
                           if cnt = 0 then cnt <= 1; state <= W_DAT_CRC;
                           else cnt <= cnt - 1; end if;

                        when W_DAT_CRC =>
                           load_val <= crc(15 downto 8); load_req <= '1';
                           crc <= crc(7 downto 0) & x"00";
                           if cnt = 0 then cnt <= C_GAP3 - 1; state <= W_GAP3;
                           else cnt <= cnt - 1; end if;

                        when W_GAP3 =>
                           load_val <= C_GAP; load_req <= '1';
                           if cnt = 0 then
                              if (src_en_i = '0' and sec_idx = G_SECTORS - 1) or
                                 (src_en_i = '1' and unsigned(src_nsec_i) /= 0 and
                                  sec_idx + 1 >= unsigned(src_nsec_i)) or
                                 (src_en_i = '1' and sec_idx = G_SECTORS - 1) then
                                 state <= W_GAP4B;
                              else
                                 sec_idx <= sec_idx + 1;
                                 cnt     <= C_SYNC - 1;
                                 state   <= W_SSYNC;
                              end if;
                           else
                              cnt <= cnt - 1;
                           end if;

                        -- Relleno hasta el indice siguiente: asi la pista siempre encaja
                        -- exactamente en una vuelta, sin importar la velocidad real del motor.
                        when W_GAP4B =>
                           load_val <= C_GAP; load_req <= '1';

                        when others =>
                           null;
                     end case;
                  end if;

                  -- El indice cierra la escritura pase lo que pase, se este donde se este.
                  -- Cumple dos funciones: es el final normal de la pista (llegando por
                  -- W_GAP4B) y es el seguro contra quedarse escribiendo mas de una vuelta si
                  -- algo se atascara. Va FUERA del bloque de arriba porque ahi solo se mira
                  -- una vez cada 2048 ciclos.
                   if idx_seen = '1' and wg_age = C_IDX_BLIND then
                     idx_seen <= '0';
                     wgate_r  <= '1';
                     state    <= W_DONE;
                   elsif idx_seen = '1' and wgate_r = '0' then
                      -- M4040: el contador solo cuenta con la PUERTA ABIERTA. Antes corria
                      -- tambien con la puerta cerrada -W_DONE y W_REFUSED caen dentro de este
                      -- mismo 'when others', donde wg_age vale 0- asi que sumaba los indices
                      -- normales de entre pistas y no separaba las dos causas.
                      -- M4039: indice DENTRO de la ventana ciega. Se descarta y se cuenta: esto
                      -- es lo que antes mataba la pista a los microsegundos de empezarla.
                      idx_seen  <= '0';
                      if blind_cnt /= x"FFFF" then blind_cnt <= blind_cnt + 1; end if;
                  end if;

            end case;

            if state = W_DONE or state = W_REFUSED then
               wgate_r <= '1';
               -- M4027: REARME. Antes esto era terminal y solo se salia bajando enable_i,
               -- porque start_i era directamente el item de menu, un nivel. Ahora el
               -- secuenciador de 40 pistas manda un PULSO por pista, asi que hay que volver a
               -- reposo en cuanto lo suelta para poder aceptar el siguiente.
               if start_i = '0' then
                  state <= W_IDLE;
               end if;
            end if;
         end if;
      end if;
   end process fmt_proc;

end architecture beh;
