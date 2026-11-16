#!/bin/bash
# Native 48kHz renderer verification. Needs ghdl (>= 4), verilator (>= 5), python3 + numpy.
#   ./run.sh          bit-exactness checks + 48kHz pitch/spectrum measurements
set -e
cd "$(dirname "$0")"
ROOT="$(cd ../../.. && pwd)"
R=$ROOT/rtl/upstream
P=$ROOT/target/pocket
python3 prep_dsp_sim.py
mkdir -p build && cd build
cp ../sim_dpram.vhd ../tb_brr.vhd ../gen_test.py ../an48.py ../cmp.py ../chkbrr.py .

# 1. Native GHDL simulation of the unmodified DSP.vhd (reference)
ghdl -a --std=08 -fsynopsys --workdir=. sim_dpram.vhd $R/CEGen.vhd $R/DSP_PKG.vhd $R/DSP.vhd tb_brr.vhd
# 2. Verilog netlist of the DSP for Verilator
mkdir -p synth && ghdl -a --std=08 -fsynopsys --workdir=synth sim_dpram.vhd $R/CEGen.vhd $R/DSP_PKG.vhd DSP_sim.vhd
ghdl --synth --std=08 -fsynopsys --workdir=synth --out=verilog DSP > dsp.v 2>/dev/null
verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -O3 --top-module tb_hq -o tb -j 8 \
  ../tb_hq.sv dsp.v $P/dsp_hq48.sv $P/dsp_hq48_gauss.sv $P/audio_resampler.sv $P/audio_resampler_coefs.sv >/dev/null

# 3. Upstream DSP.vhd (without HQ_TAP) for the no-behaviour-change check
git -C "$ROOT" show 6877fec:rtl/upstream/DSP.vhd > DSP_upstream.vhd
mkdir -p up && ghdl -a --std=08 -fsynopsys --workdir=up sim_dpram.vhd $R/CEGen.vhd $R/DSP_PKG.vhd DSP_upstream.vhd ../tb_upstream.vhd

echo "== Modified DSP.vhd (with HQ_TAP) vs upstream DSP.vhd, native VHDL"
for t in mix echo; do
  python3 gen_test.py $t >/dev/null
  ghdl -r --std=08 -fsynopsys --workdir=up tb_up --stop-time=140ms --ieee-asserts=disable >/dev/null 2>&1
  ghdl -r --std=08 -fsynopsys --workdir=. tb_brr --stop-time=140ms --ieee-asserts=disable >/dev/null 2>&1
  echo "  $t: $(wc -l < hw_up.txt) samples, $(diff hw_up.txt hw_vhdl.txt | grep -c '^<' || true) differences"
done

echo "== DSP netlist vs native VHDL DSP (validates the testbench DSP)"
for t in mix echo; do
  python3 gen_test.py $t >/dev/null
  ./obj_dir/tb +mode=0 +n=4000 >/dev/null
  ghdl -r --std=08 -fsynopsys --workdir=. tb_brr --stop-time=140ms --ieee-asserts=disable >/dev/null 2>&1
  python3 - $t <<'PY'
import sys
a=[l.split()[1:] for l in open('hw.txt')]; b=[l.split() for l in open('hw_vhdl.txt')]
n=min(len(a),len(b)); print(f"  {sys.argv[1]}: {n} samples, {sum(a[i]!=b[i] for i in range(n))} mismatches")
PY
done

echo "== Native 48kHz renderer evaluated at the DSP's own sample instants (mu = 0) vs DSP output"
for t in sine mix; do
  python3 gen_test.py $t >/dev/null; ./obj_dir/tb +mode=0 +n=5000 | grep latency
  echo "  $t:"; python3 cmp.py | grep "lag 16"
done
python3 gen_test.py echo >/dev/null; ./obj_dir/tb +mode=0 +n=5000 >/dev/null
python3 - <<'PY'
import numpy as np
hw=np.loadtxt('hw.txt')[:,1]; hq=np.loadtxt('hq.txt')[:,1]
j=np.arange(1100,len(hq)); d=hq[j]-hw[j-16]
print(f"  echo: max difference {abs(d).max():.0f} LSB (echo return is band-limited resampled)")
PY

echo "== 48kHz output: pitch and spectrum (old sample-and-hold / 32k->48k resampler / native 48k)"
for cfg in "0 0x1000" "0 0x3000" "2 0x1000" "2 0x2200" "1 0x1800" "1 0x2C00"; do
  set -- $cfg; python3 gen_test.py tone $1 $2 >/dev/null; ./obj_dir/tb +mode=1 +n=36500 >/dev/null; python3 an48.py $1 $2
done
