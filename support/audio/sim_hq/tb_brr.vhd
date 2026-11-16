library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all; use std.textio.all; use work.DSP_PKG.all;
entity tb_brr is end;
architecture t of tb_brr is
  signal clk, rst_n : std_logic := '0';
  signal smp_a : std_logic_vector(15 downto 0) := x"00F0";
  signal smp_do : std_logic_vector(7 downto 0) := x"00";
  signal smp_we : std_logic := '1';
  signal smp_en_f : std_logic;
  signal ram_a : std_logic_vector(15 downto 0);
  signal ram_d, ram_q : std_logic_vector(7 downto 0);
  signal ce_n, oe_n, we_n, rdy : std_logic;
  signal al, ar : std_logic_vector(15 downto 0);
  signal tap : std_logic_vector(127 downto 0);
  type mem_t is array(0 to 65535) of std_logic_vector(7 downto 0);
  signal aram : mem_t;
  signal loaded : boolean := false;
  type regs_t is array(0 to 255) of std_logic_vector(15 downto 0);
begin
  clk <= not clk after 23 ns;
  ram_q <= aram(to_integer(unsigned(ram_a)));
  dut: entity work.DSP port map (CLK=>clk, RST_N=>rst_n, ENABLE=>'1', PAL=>'0', FREQ=>'0',
    SMP_A=>smp_a, SMP_DO=>smp_do, SMP_WE=>smp_we, RAM_Q=>ram_q, IO_ADDR=>(others=>'0'), IO_DAT=>(others=>'0'), IO_WR=>'0',
    SS_ADDR=>(others=>'0'), SS_REGS_SEL=>'0', SS_WR=>'0', SS_DI=>(others=>'0'),
    SMP_EN_F=>smp_en_f, SMP_EN_R=>open, SMP_DI=>open, SMP_CE=>open, RAM_A=>ram_a, RAM_D=>ram_d,
    RAM_CE_N=>ce_n, RAM_OE_N=>oe_n, RAM_WE_N=>we_n, LRCK=>open, BCK=>open, SDAT=>open, SS_DO=>open,
    AUDIO_L=>al, AUDIO_R=>ar, SND_RDY=>rdy, HQ_TAP=>tap);
  process
    file f : text; variable l : line; variable v : std_logic_vector(7 downto 0); variable i : integer := 0;
  begin
    file_open(f, "aram.hex", read_mode);
    while not endfile(f) loop readline(f, l); hread(l, v); aram(i) <= v; i := i + 1; end loop;
    loop
      wait until rising_edge(clk);
      if ce_n = '0' and we_n = '0' then aram(to_integer(unsigned(ram_a))) <= ram_d; end if;
    end loop;
  end process;
  process
    file f : text; variable l : line; variable w : std_logic_vector(15 downto 0);
    procedure wr(a : std_logic_vector(15 downto 0); d : std_logic_vector(7 downto 0)) is begin
      wait until rising_edge(clk); while smp_en_f = '0' loop wait until rising_edge(clk); end loop;
      smp_a <= a; smp_do <= d; smp_we <= '0';
      wait until rising_edge(clk); while smp_en_f = '1' loop wait until rising_edge(clk); end loop;
      smp_a <= x"00F0"; smp_we <= '1';
      for k in 1 to 30 loop wait until rising_edge(clk); end loop;
    end procedure;
  begin
    for k in 1 to 20 loop wait until rising_edge(clk); end loop;
    rst_n <= '1';
    for k in 1 to 2000 loop wait until rising_edge(clk); end loop;
    file_open(f, "regs.hex", read_mode);
    loop readline(f, l); hread(l, w); exit when w = x"FFFF"; wr(x"00F2", w(15 downto 8)); wr(x"00F3", w(7 downto 0)); end loop;
    wait;
  end process;
  process(clk) file o3 : text open write_mode is "hw_vhdl.txt"; variable l3 : line; begin
    if rising_edge(clk) and rdy = '1' then write(l3, to_integer(signed(al))); write(l3, string'(" ")); write(l3, to_integer(signed(ar))); writeline(o3, l3); end if;
  end process;
  process(clk) file o : text open write_mode is "brr_vhdl.txt"; variable l : line; begin
    if rising_edge(clk) then
      if tap(0) = '1' and tap(3 downto 1) = "000" then write(l, to_integer(signed(tap(19 downto 4)))); writeline(o, l); end if;
    end if;
  end process;
end;
