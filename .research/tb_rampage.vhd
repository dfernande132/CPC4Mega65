-- Banco de pruebas del arreglo M4062: el mapeo de RAMpage a los dos unicos
-- bloques fisicos de 64 KB que tiene un CPC 6128.
--
-- Reproduce LITERALMENTE la asignacion concurrente que entra en main.vhd, con los
-- mismos anchos, y comprueba el comportamiento esperado de un 6128 real:
--   RAMpage = 2  -> bloque 0 (RAM base)
--   RAMpage > 2  -> bloque 1 (el unico banco de expansion), para TODOS los bancos
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_rampage is
end entity;

architecture sim of tb_rampage is
   signal mb_mem_addr     : std_logic_vector(22 downto 0);
   signal main_ram_addr_a : std_logic_vector(16 downto 0);
   signal fallos          : natural := 0;
begin

   -- ---- la linea exacta que va a main.vhd -------------------------------------
   main_ram_addr_a <= '0' & mb_mem_addr(15 downto 0) when mb_mem_addr(20 downto 16) = "00010"
                 else '1' & mb_mem_addr(15 downto 0);
   -- ----------------------------------------------------------------------------

   process
      constant C_OFF : std_logic_vector(15 downto 0) := x"ABCD";  -- desplazamiento testigo
      variable esperado : std_logic;
   begin
      -- RAMpage recorre los 32 valores posibles del campo de 5 bits.
      -- 2 = RAM base. 3..10 = los 8 bancos de expansion del puerto 7F.
      -- 11..18 = los otros 8 que aparecen con A8=0. Todos menos el 2 son expansion.
      for page in 0 to 31 loop
         mb_mem_addr <= "00" & std_logic_vector(to_unsigned(page, 5)) & C_OFF;
         wait for 1 ns;

         if page = 2 then esperado := '0'; else esperado := '1'; end if;

         if main_ram_addr_a(16) /= esperado then
            report "FALLO: RAMpage=" & integer'image(page) &
                   " da bloque " & std_logic'image(main_ram_addr_a(16)) &
                   ", se esperaba " & std_logic'image(esperado) severity error;
            fallos <= fallos + 1;
            wait for 1 ns;
         end if;

         -- los 16 bits bajos tienen que pasar intactos SIEMPRE
         if main_ram_addr_a(15 downto 0) /= C_OFF then
            report "FALLO: RAMpage=" & integer'image(page) &
                   " ha alterado el desplazamiento" severity error;
            fallos <= fallos + 1;
            wait for 1 ns;
         end if;
      end loop;

      -- La prueba de regresion del bug: los bancos 0 y 1 de expansion (RAMpage 3 y 4)
      -- tienen que caer en el MISMO bloque. Antes, el 4 caia sobre la RAM base.
      report "--- comprobacion del bug reportado ---";
      mb_mem_addr <= "00" & std_logic_vector(to_unsigned(3, 5)) & C_OFF;
      wait for 1 ns;
      assert main_ram_addr_a(16) = '1'
         report "banco de expansion 0 no esta en el bloque de expansion" severity error;
      mb_mem_addr <= "00" & std_logic_vector(to_unsigned(4, 5)) & C_OFF;
      wait for 1 ns;
      assert main_ram_addr_a(16) = '1'
         report "banco de expansion 1 NO aliasa con el 0 - el bug sigue ahi" severity error;

      if fallos = 0 then
         report "OK: 32 paginas comprobadas, el mapeo es el de un 6128" severity note;
      else
         report "HAY " & integer'image(fallos) & " FALLOS" severity failure;
      end if;
      wait;
   end process;

end architecture;
