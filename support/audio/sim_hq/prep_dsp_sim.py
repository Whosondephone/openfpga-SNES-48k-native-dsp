#!/usr/bin/env python3
"""
Writes build/DSP_sim.vhd: a simulation-only copy of rtl/upstream/DSP.vhd that
GHDL can convert to Verilog (ghdl --synth) for the Verilator testbench.

Two source-level rewrites work around GHDL synthesis issues. They do not
change behaviour (run_vhdl_check.sh verifies the converted DSP is bit-exact
against native GHDL simulation of the unmodified DSP.vhd):
  * The RAM address process mixes combinational and clocked logic with a
    shared variable; it is split into two processes.
  * `0 - x` (integer minus signed) in the BRR filters is written as `-x`;
    ghdl --synth drops the negation otherwise.
"""
import os, re
here = os.path.dirname(os.path.abspath(__file__))
src = os.path.join(here, "..", "..", "..", "rtl", "upstream", "DSP.vhd")
s = open(src).read()

hdr = "\tprocess(CLK, RST_N, RS, BRR_VOICE"
i = s.index(hdr)
beg = s.index("\tbegin\n", i) + len("\tbegin\n")
decl = "\t\tvariable ADDR_INC : unsigned(1 downto 0);\n\t\tvariable LR: integer range 0 to 1;\n"
j = s.index("\t\tif RST_N = '0' then\n\t\t\tBRR_NEXT_ADDR", beg)
k = s.index("\tend process;", j)
comb, clk = s[beg:j], s[j:k]
clk = re.sub(r"\bLR\b", "LR2", clk)
new = ("\tprocess(all)\n" + decl + "\tbegin\n" + comb + "\tend process;\n\n"
       "\tprocess(CLK, RST_N)\n\t\tvariable LR2: integer range 0 to 1;\n\tbegin\n" + clk)
s = s[:i] + new + s[k:]

for a, b in [("shift_right((0-P0), 5)", "shift_right(-P0, 5)"),
             ("shift_right(0 - (P0 + (P0*2)),6)", "shift_right(-(P0 + (P0*2)),6)"),
             ("shift_right(0 - (P0 + (P0*4) + (P0*8)),7)", "shift_right(-(P0 + (P0*4) + (P0*8)),7)")]:
    assert s.count(a) == 1, a
    s = s.replace(a, b)

os.makedirs(os.path.join(here, "build"), exist_ok=True)
open(os.path.join(here, "build", "DSP_sim.vhd"), "w").write(s)
print("wrote build/DSP_sim.vhd")
