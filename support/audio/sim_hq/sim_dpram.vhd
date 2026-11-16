-- Simulation model of the altsyncram based dpram (registered address, unregistered output)
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
entity dpram is
  generic (addr_width : integer := 8; data_width : integer := 8; mem_init_file : string := " ");
  port (clock : in std_logic;
    address_a : in std_logic_vector(addr_width-1 downto 0); data_a : in std_logic_vector(data_width-1 downto 0) := (others => '0');
    enable_a : in std_logic := '1'; wren_a : in std_logic := '0'; q_a : out std_logic_vector(data_width-1 downto 0); cs_a : in std_logic := '1';
    address_b : in std_logic_vector(addr_width-1 downto 0) := (others => '0'); data_b : in std_logic_vector(data_width-1 downto 0) := (others => '0');
    enable_b : in std_logic := '1'; wren_b : in std_logic := '0'; q_b : out std_logic_vector(data_width-1 downto 0); cs_b : in std_logic := '1');
end entity;
architecture sim of dpram is
  type mem_t is array(0 to 2**addr_width-1) of std_logic_vector(data_width-1 downto 0);
  signal mem : mem_t := (others => (others => '0'));
begin
  process(clock) begin
    if rising_edge(clock) then
      if wren_a = '1' then
        mem(to_integer(unsigned(address_a))) <= data_a;
        q_a <= data_a;
      else
        q_a <= mem(to_integer(unsigned(address_a)));
      end if;
      if wren_a = '1' and address_b = address_a then
        q_b <= data_a;
      else
        q_b <= mem(to_integer(unsigned(address_b)));
      end if;
    end if;
  end process;
end architecture;
