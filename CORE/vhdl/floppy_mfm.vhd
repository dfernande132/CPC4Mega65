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
      -- Pulso para empezar a contar una pista NUEVA desde cero. Lo usa floppy_scan al cambiar
      -- de pista. Ojo: NO reinicia la densidad detectada - averiguarla otra vez en cada pista
      -- costaria una vuelta perdida por pista, y la densidad es del disquete, no de la pista.
      restart_i      : in  std_logic;

      -- M4022: cuantos sectores se ESPERAN en esta pista (0 = todavia no se sabe, que es el
      -- caso de la pista 0 porque es ella la que fija la referencia). Cambia dos cosas:
      --
      --   * NO abandonar mientras falten sectores. Antes se salia en cuanto una vuelta no
      --     aportaba nada nuevo, y con dos sectores que fallan de forma persistente eso se
      --     cumple en la SEGUNDA vuelta: se abandonaba con el 60% del presupuesto sin usar.
      --     Medido en la pista 7 del disquete del usuario (volcado M4021): revs=1, faltaban
      --     C3 y C7, dtCRC=4. Un disquete de 1988 puede darlos al tercer o cuarto intento.
      --
      --   * TERMINAR ANTES cuando ya estan todos. No hay que esperar al pulso de indice para
      --     cerrar una pista completa, asi que una pista sana se lee en UNA vuelta en vez de
      --     dos: el recorrido de 40 pistas baja de ~16 s a ~8 s.
      expect_i       : in  std_logic_vector(4 downto 0) := (others => '0');

      -- M4023: elige el separador. '0' = clasificador de ventanas fijas (el de siempre),
      -- '1' = DPLL. Conmutable en caliente para poder comparar A/B con el mismo disquete en
      -- la misma sesion, que es como el core del Amiga demostro causalidad en vez de suponerla.
      dpll_en_i      : in  std_logic := '0';

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
      id_size_o      : out std_logic_vector(7 downto 0);

      -- Flujo de bytes del campo de DATOS, para que floppy_scan lo vaya escribiendo en el
      -- buffer de imagen segun llega. Se emiten TODOS los bytes, antes de saber si el CRC
      -- cuadra: si no cuadrara, la vuelta siguiente reescribe el mismo sitio (ver el calculo
      -- de direccion por identificador de sector en floppy_scan), asi que no hace falta
      -- guardar la pista en ningun sitio intermedio.
      data_byte_o    : out std_logic_vector(7 downto 0);
      data_valid_o   : out std_logic;                     -- 1 ciclo por byte de datos
      data_offset_o  : out std_logic_vector(10 downto 0); -- posicion del byte dentro del sector
      -- Ranura del sector dentro de la pista, derivada del identificador: en PC 1..9 y en el
      -- CPC &C1..&C9 dan los dos 1..9, o sea ranuras 0..8.
      sec_slot_o     : out std_logic_vector(4 downto 0);
      -- Pulso al terminar un sector con los DOS CRC correctos: su contenido ya es definitivo
      sec_ok_o       : out std_logic;

      -- M4019 TELEMETRIA. Lo que no sabiamos y nos ha costado tres builds de adivinar:
      -- cuantos CRC fallan y de que tipo, que sectores concretos faltan, y cuantas vueltas
      -- ha hecho falta dar. Todo por pista, y se reinicia con restart_i.
      tlm_seen_o     : out std_logic_vector(31 downto 0); -- que IDs se han visto (bit = ID and 31)
      tlm_revs_o     : out std_logic_vector(3 downto 0);  -- vueltas consumidas en esta pista
      tlm_idcrc_o    : out std_logic_vector(15 downto 0); -- campos de ID con CRC malo
      tlm_dtcrc_o    : out std_logic_vector(15 downto 0); -- campos de DATOS con CRC malo

      -- M4024: celdas emitidas POR EL CAMINO DPLL, saturante. Existe para no volver a
      -- interpretar un resultado sin saber que codigo lo produjo: con el DPLL encendido esto
      -- tiene que ser distinto de cero, y si es cero es que la opcion no llega hasta aqui.
      -- M4023 dio resultados IDENTICOS con y sin DPLL, y "identico" es tambien la firma de
      -- "no se aplico ningun cambio" - hay que poder distinguirlo.
      tlm_pllcells_o : out std_logic_vector(15 downto 0);

      -- M4025: flancos rechazados por llegar antes del minimo fisicamente posible. Si esto
      -- sale 0, la hipotesis del pulso espurio esta muerta y hay que mirar a otro sitio; es
      -- el contador el que hace falsable el arreglo.
      tlm_runts_o    : out std_logic_vector(15 downto 0)
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

   ---------------------------------------------------------------------------------------------
   -- M4023: SEPARADOR DPLL
   --
   -- POR QUE. El clasificador de ventanas fijas de arriba se justificaba asi: "los discos giran
   -- a 300 RPM con +/-1,5% de tolerancia, muy por debajo del +/-25% que dan las ventanas".
   -- El razonamiento tiene un agujero: ese +/-1,5% es de la velocidad MEDIA, pero en un disquete
   -- real las transiciones de flujo adyacentes se repelen magneticamente (desplazamiento de
   -- pico), y ese corrimiento es LOCAL y depende del patron de datos. Por eso los controladores
   -- de verdad llevan precompensacion al escribir y un separador con PLL al leer.
   --
   -- Un intervalo desplazado cerca de una frontera cae en la caja equivocada, y a partir de ahi
   -- el resto del sector es basura. Medido en hardware (volcados M4021/M4022): la pista 7 del
   -- disquete del usuario pierde SIEMPRE los mismos dos sectores, 5 de 5 intentos, con
   -- idCRC=0 y dtCRC=10 - los identificadores (cortos) sobreviven y los campos de datos
   -- (largos) no. Y el CPC real lee ese mismo fichero sin problema.
   --
   -- COMO. Es el diseño de AExp (learning_cores/AExp-dev-hw-fdd, physical_fdd_bits.vhd),
   -- reescrito para nuestro reloj. En vez de clasificar intervalos, se mantiene una fase y un
   -- periodo que siguen al disco y se decide UN BIT POR FRONTERA DE CELDA. Un flanco desplazado
   -- solo tira un poco de la fase en vez de cambiar de clase, asi que los errores se quedan
   -- LOCALES: su banco de pruebas mostro que el mismo evento que con el clasificador corrompe
   -- toda la cola, con DPLL es un solo bit mal.
   --
   -- Coma fija Q4 igual que ellos: 16 unidades = un ciclo de reloj. A 64 MHz una celda DD son
   -- 2 us = 128 ciclos = 2048; HD la mitad. Ganancias: fase err/2, periodo err/64, y el periodo
   -- recortado a +/-10% para que no pueda derivar de una densidad a la otra.
   ---------------------------------------------------------------------------------------------
   constant C_DPLL_PG   : natural := 1;    -- err/2 en la fase
   constant C_DPLL_FG   : natural := 6;    -- err/64 en el periodo
   constant C_DD_CELL   : natural := (G_CLK_HZ / 1_000_000) * 2 * 16;   -- 2 us -> 2048 @64MHz
   constant C_HD_CELL   : natural := (G_CLK_HZ / 1_000_000) * 1 * 16;   -- 1 us -> 1024
   constant C_DD_CMIN   : natural := C_DD_CELL - C_DD_CELL / 10;
   constant C_DD_CMAX   : natural := C_DD_CELL + C_DD_CELL / 10;
   constant C_HD_CMIN   : natural := C_HD_CELL - C_HD_CELL / 10;
   constant C_HD_CMAX   : natural := C_HD_CELL + C_HD_CELL / 10;

   signal cell_nom  : unsigned(12 downto 0);
   signal cell_min  : unsigned(12 downto 0);
   signal cell_max  : unsigned(12 downto 0);
   signal pll_phase : unsigned(13 downto 0) := (others => '0');
   signal pll_cell  : unsigned(12 downto 0) := to_unsigned(C_DD_CELL, 13);
   signal pend_edge : std_logic := '0';
   signal pll_cells : unsigned(15 downto 0) := (others => '0');   -- M4024
   signal runt_cnt  : unsigned(15 downto 0) := (others => '0');   -- M4025

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

   -- CPC4MEGA65 M4057: LA RANURA SALE DEL ORDEN DE APARICION, NO DEL IDENTIFICADOR.
   --
   -- Antes era 'R(3..0) - 1', o sea la convencion DATA del CPC (&C1..&C9 -> 0..8) metida
   -- dentro del separador. Eso deja fuera cualquier disco que no numere asi:
   --   * R-Type Face A tiene diez sectores, &C1..&CA: el decimo cae en la ranura 9 y
   --     floppy_dsk lo descarta, porque su lista es de G_SECTORS = 9 entradas.
   --   * Ocean Dynamite 4 numera R = 0x00..0x0F: el sector R=0 da ranura -1, que envuelve a 31.
   --
   -- Lo correcto en general es el orden en que los sectores aparecen en la pista, que ademas
   -- es como los ordena un .dsk de verdad: la lista del TrackInfo va en orden FISICO. Nuestras
   -- imagenes pasan a parecerse mas a las reales, no menos.
   --
   -- LA RANURA TIENE QUE SER ESTABLE ENTRE VUELTAS. Un sector cuyo CRC de datos falle no entra
   -- en seen_map y se reintenta en la vuelta siguiente: si entonces le tocara otra ranura,
   -- escribiria encima de otro sector. Por eso se guarda la asignacion en una tabla y se
   -- reutiliza, y por eso hace falta slot_set aparte de seen_map: 'ya tiene ranura' no es lo
   -- mismo que 'ya se leyo entero'.
   --
   -- La tabla se indexa con los 5 bits bajos de R, igual que seen_map, asi que hereda su misma
   -- limitacion: dos sectores cuyos R solo difieran por encima del bit 4 colisionarian. No pasa
   -- en ningun formato conocido del CPC (&C1..&CF, y 0x00..0x0F en el caso raro de Dynamite).
   type t_slottab is array (0 to 31) of unsigned(4 downto 0);
   signal slot_tab  : t_slottab := (others => (others => '0'));
   signal slot_set  : std_logic_vector(31 downto 0) := (others => '0');
   signal next_slot : unsigned(4 downto 0) := (others => '0');
   signal cur_slot  : unsigned(4 downto 0) := (others => '0');
   signal sect_cnt   : unsigned(4 downto 0) := (others => '0');
   signal rev_cnt    : natural range 0 to 7 := 0;
   -- Se ha encontrado algun sector NUEVO en la vuelta actual? Si no, no hace falta seguir.
   signal new_in_rev : std_logic := '0';
   signal done_r     : std_logic := '0';
   signal seen_index : std_logic := '0';

   -- Vueltas que se observan antes de dar el recuento por definitivo. Cada vuelta reescribe los
   -- mismos sitios del buffer (la direccion sale del identificador del sector), asi que son
   -- reintentos gratis: un sector que falle el CRC en una vuelta se recupera en la siguiente.
   -- Se suben de 3 a 5 tras ver que en un disquete real se perdian entradas de directorio.
   constant C_REVS : natural := 5;

   -- M4052: un segundo sin ver NINGUN pulso de indice = no hay disquete (ver el uso, al final
   -- de dec_proc). Son cinco vueltas a 300 RPM, y C_REVS vueltas de lectura legitima no lo
   -- disparan porque el contador se rearma con cada indice.
   constant C_NOIDX_TMO : natural := G_CLK_HZ;
   signal   noidx_tmr   : natural range 0 to C_NOIDX_TMO := C_NOIDX_TMO;

   signal id_c, id_h, id_r, id_n : std_logic_vector(7 downto 0) := (others => '0');

   -- Lectura del campo de DATOS que sigue a cada campo de ID.
   -- id_ok recuerda si el ID inmediatamente anterior tenia el CRC bien: un campo de datos solo
   -- se da por bueno si su ID tambien lo estaba, porque si no, no se sabe a que sector pertenece.
   signal id_ok      : std_logic := '0';
   signal id_r_lat   : std_logic_vector(7 downto 0) := (others => '0');
   signal data_len   : unsigned(10 downto 0) := (others => '0');   -- tamano del sector en curso
   signal data_pos   : unsigned(10 downto 0) := (others => '0');   -- byte actual dentro del sector
   signal data_byte  : std_logic_vector(7 downto 0) := (others => '0');
   signal data_off_r : unsigned(10 downto 0) := (others => '0');
   signal data_vld   : std_logic := '0';

   -- M4019: contadores de telemetria por pista
   signal idcrc_err  : unsigned(15 downto 0) := (others => '0');
   signal dtcrc_err  : unsigned(15 downto 0) := (others => '0');
   signal sec_ok_r   : std_logic := '0';

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

   data_byte_o   <= data_byte;
   data_valid_o  <= data_vld;

   -- M4019: telemetria
   tlm_seen_o    <= seen_map;
   tlm_revs_o    <= std_logic_vector(to_unsigned(rev_cnt, 4));
   tlm_idcrc_o   <= std_logic_vector(idcrc_err);
   tlm_dtcrc_o   <= std_logic_vector(dtcrc_err);
   tlm_pllcells_o <= std_logic_vector(pll_cells);   -- M4024
   tlm_runts_o    <= std_logic_vector(runt_cnt);    -- M4025
   data_offset_o <= std_logic_vector(data_off_r);
   -- M4057: ranura = orden de aparicion en la pista. Ver la declaracion de slot_tab.
   sec_slot_o    <= std_logic_vector(cur_slot);
   sec_ok_o      <= sec_ok_r;
   id_track_o     <= id_c;
   id_side_o      <= id_h;
   id_sector_o    <= id_r;
   id_size_o      <= id_n;

   ------------------------------------------------------------------------------------------
   -- Separador de datos: intervalos de flujo -> celdas MFM
   ------------------------------------------------------------------------------------------
   -- M4023: nominal y recorte del DPLL segun la densidad que se este probando
   cell_nom <= to_unsigned(C_HD_CELL, 13) when rate_hd = '1' else to_unsigned(C_DD_CELL, 13);
   cell_min <= to_unsigned(C_HD_CMIN, 13) when rate_hd = '1' else to_unsigned(C_DD_CMIN, 13);
   cell_max <= to_unsigned(C_HD_CMAX, 13) when rate_hd = '1' else to_unsigned(C_DD_CMAX, 13);

   sep_proc : process (clk_i)
      variable interval : natural range 0 to C_CNT_MAX;
      variable edge_v   : boolean;
      variable ph_v     : unsigned(13 downto 0);
      variable err_v    : signed(15 downto 0);
      variable cl_v     : signed(15 downto 0);
      variable bit_v    : std_logic;
   begin
      if rising_edge(clk_i) then
         rdata_sr <= rdata_sr(1 downto 0) & f_rdata_i;
         emit_one <= '0';
         cell_new <= '0';

         if rst_i = '1' or enable_i = '0' then
            gap_cnt    <= 0;
            zeros_left <= 0;
            cell_sr    <= (others => '0');
            pll_phase  <= (others => '0');
            pll_cell   <= cell_nom;
            pend_edge  <= '0';
            runt_cnt   <= (others => '0');
         else
            ------------------------------------------------------------------------------------
            -- M4025: ACONDICIONADO COMUN A LOS DOS SEPARADORES.
            --
            -- Lo que arregla: un flanco espurio (ruido del medio, un bit debil) llega antes del
            -- minimo fisicamente posible - 4 us a DD, y aqui se rechaza por debajo de 3. Eso ya
            -- se detectaba y no se emitia nada, CORRECTO. Pero el contador de intervalo se
            -- reiniciaba IGUALMENTE, asi que la siguiente transicion buena se media desde el
            -- ruido en vez de desde el ultimo flanco valido: intervalo equivocado y sincronismo
            -- de bit perdido. Un solo pulso espurio corrompia DOS intervalos.
            --
            -- Ahora el flanco espurio se ignora del todo y el contador SIGUE corriendo, asi que
            -- la siguiente transicion se mide bien y el ruido no deja rastro.
            --
            -- Por que aqui y no en cada separador: en los volcados de M4024 el clasificador y
            -- el DPLL decodifican los mismos bytes hasta un punto concreto de la pista 7 y a
            -- partir de ahi difieren (507/512 en C3, 144/512 en C7). Que ambos fallen en el
            -- MISMO sitio y de forma distinta señala a lo que comparten, no a ellos.
            --
            -- Un intervalo demasiado LARGO es otra cosa - hueco entre sectores, dropout - y ahi
            -- si hay que reiniciar la medida, que es lo que hace el camino normal.
            ------------------------------------------------------------------------------------
            if gap_cnt /= C_CNT_MAX then
               gap_cnt <= gap_cnt + 1;
            end if;

            edge_v   := false;
            interval := gap_cnt;
            if rdata_sr(2) = '1' and rdata_sr(1) = '0' then
               if gap_cnt < lim_lo then
                  if runt_cnt /= x"FFFF" then
                     runt_cnt <= runt_cnt + 1;
                  end if;
               else
                  edge_v  := true;
                  gap_cnt <= 0;
               end if;
            end if;

            if dpll_en_i = '1' then
            ---------------------------------------------------------------------------------
            -- M4023: separador DPLL. Ver el comentario largo en las declaraciones.
            ---------------------------------------------------------------------------------
            ph_v   := pll_phase + 16;                      -- Q4: 16 unidades = un ciclo
            -- El bit de la celda: '1' si cayo un flanco en ella, ya sea en un ciclo anterior
            -- (pend_edge) o justo en este mismo.
            bit_v  := pend_edge;
            if edge_v then
               bit_v := '1';
            end if;

            if edge_v then
               -- err = fase - celda/2, o sea lo descentrado que viene el flanco respecto al
               -- centro de la ventana. La fase se corrige a la mitad del error y el periodo
               -- una fraccion muy pequeña, que es lo que hace que un flanco suelto no arrastre.
               err_v := signed(resize(ph_v, 16)) -
                        signed(resize(pll_cell(12 downto 1), 16));
               ph_v  := unsigned(resize(signed(resize(ph_v, 16)) -
                                        shift_right(err_v, C_DPLL_PG), 14));
               cl_v  := signed(resize(pll_cell, 16)) + shift_right(err_v, C_DPLL_FG);
               if cl_v < signed(resize(cell_min, 16)) then
                  pll_cell <= cell_min;
               elsif cl_v > signed(resize(cell_max, 16)) then
                  pll_cell <= cell_max;
               else
                  pll_cell <= unsigned(cl_v(12 downto 0));
               end if;
               pend_edge <= '1';
            end if;

            -- Frontera de celda: sale un bit, '1' si en esa celda cayo un flanco. Si no llegan
            -- flancos (hueco entre sectores) el oscilador sigue libre soltando ceros, que es
            -- justo lo que hace un separador real sobre una zona sin formatear.
            if ph_v >= resize(pll_cell, 14) then
               pll_phase <= ph_v - resize(pll_cell, 14);
               cell_sr   <= cell_sr(14 downto 0) & bit_v;
               cell_new  <= '1';
               pend_edge <= '0';
               if pll_cells /= x"FFFF" then
                  pll_cells <= pll_cells + 1;   -- M4024: prueba de que ESTE camino corrio
               end if;
            else
               pll_phase <= ph_v;
            end if;
            else
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

            -- Transicion de flujo ya filtrada arriba (M4025)
            if edge_v then
               if interval > lim_hi then
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
            end if;      -- dpll_en_i
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
         have_v   := false;
         data_vld <= '0';          -- pulsos de un ciclo
         sec_ok_r <= '0';

         if rst_i = '1' or enable_i = '0' then
            state      <= ST_IDLE;
            seen_map   <= (others => '0');
            slot_set   <= (others => '0');   -- M4057
            next_slot  <= (others => '0');
            cur_slot   <= (others => '0');
            sect_cnt   <= (others => '0');
            rev_cnt    <= 0;
            done_r     <= '0';
            seen_index <= '0';
            bit_cnt    <= 0;
            field_idx  <= 0;
            id_ok      <= '0';
            data_pos   <= (others => '0');
            idcrc_err  <= (others => '0');   -- M4019
            dtcrc_err  <= (others => '0');   -- M4019
            rate_hd    <= '0';        -- se empieza probando DD, que es lo que usa el CPC
         elsif restart_i = '1' then
            state      <= ST_IDLE;
            seen_map   <= (others => '0');
            slot_set   <= (others => '0');   -- M4057
            next_slot  <= (others => '0');
            cur_slot   <= (others => '0');
            sect_cnt   <= (others => '0');
            rev_cnt    <= 0;
            done_r     <= '0';
            seen_index <= '0';
            bit_cnt    <= 0;
            field_idx  <= 0;
            id_ok      <= '0';
            idcrc_err  <= (others => '0');   -- M4019: la telemetria es POR PISTA
            dtcrc_err  <= (others => '0');   -- M4019
         else

            -- El recuento se hace sobre UNA vuelta completa: se arranca en un pulso de indice
            -- y se cierra en el siguiente. Antes hay que esperar a que la cabeza este colocada.
            if index_i = '1' and ready_i = '1' and done_r = '0' then
               if seen_index = '0' then
                  seen_index <= '1';
                  rev_cnt    <= 0;
                  new_in_rev <= '0';
                  state      <= ST_HUNT;
               elsif sect_cnt = "00000" then
                  -- Una vuelta entera sin enganchar nada con esta densidad: se prueba la otra.
                  -- Si el disquete no es legible en ninguna, esto alterna indefinidamente y el
                  -- LED nunca llega a contar, que es la señal correcta de "aqui no hay nada".
                  rate_hd <= not rate_hd;
                  state   <= ST_HUNT;
               elsif rev_cnt = C_REVS - 1 then
                  -- Presupuesto agotado: se da la pista por leida con lo que haya.
                  done_r <= '1';
                  state  <= ST_IDLE;
               elsif new_in_rev = '0' and
                     (expect_i = "00000" or sect_cnt >= unsigned(expect_i)) then
                  -- SALIDA ANTICIPADA, pero solo si NO FALTA NADA. Si una vuelta no aporta
                  -- sectores nuevos y ya tenemos los esperados, seguir girando es tiempo
                  -- perdido. Si faltan, en cambio, hay que insistir: es justo el caso de un
                  -- sector marginal que unas veces se lee y otras no. Ver expect_i.
                  --
                  -- expect_i = 0 (pista 0, que fija la referencia) mantiene el criterio
                  -- antiguo, porque ahi no hay contra que comparar.
                  done_r <= '1';
                  state  <= ST_IDLE;
               else
                  rev_cnt    <= rev_cnt + 1;
                  new_in_rev <= '0';
                  state      <= ST_HUNT;
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
                        data_pos  <= (others => '0');
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
                        when "00"   => data_len <= to_unsigned(128, 11);
                        when "01"   => data_len <= to_unsigned(256, 11);
                        when "10"   => data_len <= to_unsigned(512, 11);
                        when others => data_len <= to_unsigned(1024, 11);
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
                        -- M4057: primera vez que se ve este R en la pista -> ranura nueva.
                        if slot_set(to_integer(unsigned(id_r(4 downto 0)))) = '0' then
                           slot_set(to_integer(unsigned(id_r(4 downto 0)))) <= '1';
                           slot_tab(to_integer(unsigned(id_r(4 downto 0)))) <= next_slot;
                           cur_slot <= next_slot;
                           if next_slot /= "11111" then
                              next_slot <= next_slot + 1;
                           end if;
                        else
                           cur_slot <= slot_tab(to_integer(unsigned(id_r(4 downto 0))));
                        end if;
                     elsif idcrc_err /= x"FFFF" then
                        idcrc_err <= idcrc_err + 1;     -- M4019
                     end if;
                     state <= ST_HUNT;        -- ahora toca el campo de datos de este sector

                  -- Campo de datos: los N bytes utiles y despues su propio CRC. Cada byte sale
                  -- hacia fuera con su posicion dentro del sector, para que floppy_scan lo
                  -- escriba en el buffer de imagen sin esperar al final.
                  when 10 =>
                     data_byte  <= byte_v;
                     data_off_r <= data_pos;
                     -- SOLO se sacan los bytes si el campo de ID inmediatamente anterior tenia
                     -- el CRC bien. Si no, NO SE SABE a que sector pertenecen estos datos, y
                     -- sec_slot_o seguiria apuntando al sector anterior: se escribirian encima
                     -- de datos buenos, corrompiendolos. Con un CRC de ID fallando de vez en
                     -- cuando -normal en un disquete con años- eso deja el directorio a medias:
                     -- unas entradas correctas y otras con basura, que es justo lo que se vio.
                     --
                     -- M4013 - Y ADEMAS: solo si ese sector no esta YA VALIDADO (seen_map).
                     --
                     -- El fallo que arregla esto: los 512 bytes se sacan aqui, en el campo 10,
                     -- pero su CRC no se comprueba hasta el campo 12. Un sector con el CRC de
                     -- datos malo YA HA ESCRITO sus bytes corruptos en la imagen cuando se
                     -- descubre. El contador de sectores si respeta el CRC -por eso marcaba 9-
                     -- pero los bytes ya estaban puestos.
                     --
                     -- Normalmente la vuelta siguiente lo reescribiria bien. El problema es
                     -- CUAL ES LA ULTIMA VUELTA: el recorrido para en la primera vuelta que no
                     -- aporta sectores nuevos, o sea que la ultima pasada es siempre una
                     -- RELECTURA COMPLETA, y sus bytes son los que quedan. Un solo sector que
                     -- falle el CRC en esa ultima pasada deja la imagen corrupta mientras
                     -- sect_cnt sigue diciendo 9 y bad_tracks sigue a 0: el LED daba verde de
                     -- "perfecto" sobre una imagen rota.
                     --
                     -- Con seen_map como condicion, cada ranura se escribe UNA sola vez, en la
                     -- primera vuelta que la decodifica. seen_map solo se marca cuando cuadran
                     -- los DOS CRC (campo 12), asi que un sector con CRC malo deja su bit a 0
                     -- y la vuelta siguiente lo vuelve a escribir; y un sector ya validado no
                     -- lo puede estropear ninguna lectura posterior.
                     --
                     -- Efecto medible: los bytes escritos bajan de ~368.640 (dos vueltas) a
                     -- ~184.320 (una), o sea que el codigo de escritura de wr_code_o tiene que
                     -- pasar de 5 a 4. Si sigue dando 5, este cambio no ha entrado.
                     data_vld   <= id_ok and
                                   not seen_map(to_integer(unsigned(id_r_lat(4 downto 0))));
                     data_pos   <= data_pos + 1;
                     if data_pos = data_len - 1 then
                        field_idx <= 11;
                     end if;
                  when 11 => field_idx <= 12;                  -- CRC alto de los datos
                  when 12 =>
                     -- Un sector cuenta como LEIDO DE VERDAD solo si cuadran los dos CRC, el del
                     -- ID y el de los datos, y ademas el ID era el inmediatamente anterior.
                     if f_crc16(crc, byte_v) = x"0000" then
                        if id_ok = '1' then
                           sec_ok_r <= '1';     -- el contenido de este sector ya es definitivo
                           if seen_map(to_integer(unsigned(id_r_lat(4 downto 0)))) = '0' then
                              seen_map(to_integer(unsigned(id_r_lat(4 downto 0)))) <= '1';
                              new_in_rev <= '1';
                              if sect_cnt /= "11111" then
                                 sect_cnt <= sect_cnt + 1;
                              end if;
                              -- M4022: si con este ya estan todos los esperados, la pista se
                              -- cierra AQUI, sin esperar al pulso de indice. No hace falta
                              -- tocar el estado: el bloque del indice ya exige done_r = '0',
                              -- y floppy_scan reinicia en cuanto ve done_o.
                              if expect_i /= "00000" and
                                 (sect_cnt + 1) >= unsigned(expect_i) then
                                 done_r <= '1';
                              end if;
                           end if;
                        end if;
                     elsif dtcrc_err /= x"FFFF" then
                        dtcrc_err <= dtcrc_err + 1;     -- M4019
                     end if;
                     id_ok <= '0';
                     state <= ST_HUNT;

                  when others =>
                     state <= ST_HUNT;
               end case;
            end if;


            -- CPC4MEGA65 M4052: SIN PULSOS DE INDICE, LA PISTA SE DA POR LEIDA Y VACIA.
            --
            -- Todo lo de arriba lo mueve index_i. Sin disquete dentro ese pulso no llega nunca,
            -- asi que done_r no subia JAMAS y floppy_scan se quedaba en SC_READ para siempre:
            -- motor girando, sin scan_done y por tanto sin el bit de estado que desde M4045
            -- desmarca la opcion del menu. "Read disk now" con la unidad vacia era un cuelgue.
            --
            -- El contador se reinicia con CADA indice, no al empezar la pista: una lectura
            -- legitima puede durar C_REVS vueltas -mas de un segundo- y medir desde el arranque
            -- la cortaria por la mitad. Un segundo sin ver NINGUN indice son cinco vueltas: no
            -- hay motor lento que se confunda con eso.
            --
            -- Se sale con lo que haya (normalmente cero sectores), que es la verdad, y floppy_scan
            -- lo trata como una pista ilegible mas. Quien corta el recorrido entero es su propia
            -- comprobacion de disk_in_i; esto es el seguro para que no se quede colgado dentro de
            -- una pista si el disquete se saca a mitad.
            if ready_i = '1' and done_r = '0' then
               if index_i = '1' then
                  noidx_tmr <= C_NOIDX_TMO - 1;
               elsif noidx_tmr = 0 then
                  done_r <= '1';
                  state  <= ST_IDLE;
               else
                  noidx_tmr <= noidx_tmr - 1;
               end if;
            else
               noidx_tmr <= C_NOIDX_TMO - 1;
            end if;
         end if;
      end if;
   end process dec_proc;

end architecture beh;
