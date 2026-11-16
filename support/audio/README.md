# Native 48 kHz audio

This branch renders the S-DSP voices natively at 48 kHz (`dsp_hq48.sv`, below).
The polyphase resampler described afterwards is still used, but only for the
echo return.

## Native 48 kHz voice rendering (`target/pocket/dsp_hq48.sv`)

Software emulators can render the SNES voices directly at the output rate:
for every output sample they evaluate each voice's Gaussian interpolator at the
exact sample position the pitch counter has reached at that instant. This core
now does the same in hardware.

- The original S-DSP (`rtl/upstream/DSP.vhd`) is unchanged in behaviour. It
  still owns everything a game can observe: ARAM, registers, BRR decoding,
  envelopes, ENDX/ENVX/OUTX, and echo buffer writes.
- A new read-only port `HQ_TAP` exposes, per voice and per DSP period: each
  decoded BRR sample as it enters the DSP's BRR buffer, the pitch counter at
  Gaussian lookup time, the exact pitch counter advance applied that period
  (including pitch modulation and the 0x7FFF clamp), the envelope, noise state,
  voice/main volumes, mute and the echo contribution (FIR * EVOL).
- For every 48 kHz frame the renderer computes the fraction `mu` of the
  measured DSP period that has elapsed, advances each voice's pitch counter by
  `mu * advance`, and runs the DSP's own math at that position: the same
  512-entry Gaussian table, 3+1 tap sum with 16-bit wrap and clamp, envelope
  multiply, voice volume, per-voice saturating mix in the DSP's order (voice 0
  first), main volume and final clamp.
- Each voice moves through its sample data at exactly the DSP's rate, so pitch
  is unchanged. Evaluated at `mu = 0`, the renderer's output is bit-identical to
  the DSP's own output.

What is not rendered at 48 kHz, and why:

- Echo: the echo buffer lives in ARAM, which games can read, so the DSP must
  keep producing it at 32 kHz. The echo return (FIR output * EVOL) is
  band-limited resampled to 48 kHz with `audio_resampler.sv`. The voices are
  rendered 17 DSP periods (~0.53 ms) behind the DSP so the echo lines up with
  them exactly as on the DSP's own output.
- Envelope: interpolated linearly between DSP periods. A value of zero is held,
  so key-on/key-off cuts stay hard.
- Noise: the noise generator is a 32 kHz LFSR on hardware and is held per DSP
  period.
- After a save state load, the renderer's sample history refills within about
  0.5 ms.

Cost: about 200 of the ~447 clk_sys cycles available per 48 kHz frame. Yosys
estimates about 1,000 ALMs, 12 M10K and 9 DSP blocks, including the echo
resampler. This has not been run through Quartus or tested on hardware.

### Verification (`support/audio/sim_hq/run.sh`)

The testbench converts the real `DSP.vhd` to Verilog with GHDL, then runs it in
Verilator alongside `dsp_hq48`, with BRR samples in ARAM and register writes
through the SMP port. `prep_dsp_sim.py` applies two simulation-only rewrites to
work around GHDL synthesis bugs. The converted DSP is first checked
bit-for-bit against native GHDL simulation of the unmodified `DSP.vhd`.

| Check | Result |
|---|---|
| Modified `DSP.vhd` (with `HQ_TAP`) vs upstream `DSP.vhd`, native VHDL, mix and echo (4,544 samples each) | identical |
| Converted DSP vs native VHDL DSP (multi-voice mix and echo, 4,000 samples each) | 0 mismatches |
| Renderer at `mu = 0` vs DSP output, single voice and mix (ADSR, noise, pitch modulation, negative volumes) | 0 mismatches in 4,784 samples each |
| Renderer with echo vs DSP output | max 45 LSB (band-limited echo) |

48 kHz output measured at 48 kHz request timing. "Old" is the original
sample-and-hold, "Resampler" is 32k->48k resampling of the DSP output, and
"Native" is this renderer. Inharmonic content below 20 kHz is relative to the
fundamental; lower is better.

| Test tone | Pitch (expected) | Old | Resampler | Native |
|---|---|---|---|---|
| 64-sample sine, P=0x1000 | 501.094 Hz (all: 501.096) | -30.9 dB | -46.6 dB | -46.5 dB |
| 64-sample sine, P=0x3000 | 1503.281 Hz (all: 1503.286) | -21.4 dB | -47.0 dB | -47.6 dB |
| 8-sample sine, P=0x1000 | 4008.750 Hz (all: 4008.746) | -13.2 dB | -67.4 dB | -57.7 dB |
| 8-sample sine, P=0x2200 | 8518.594 Hz (all: 8518.597) | -9.6 dB | -38.8 dB | -54.1 dB |
| Band-limited saw (15 harmonics), P=0x1800 | 1503.281 Hz | -15.5 dB | -27.1 dB | -44.6 dB |
| Band-limited saw (15 harmonics), P=0x2C00 | 2756.016 Hz | -10.6 dB | -17.1 dB | -25.6 dB |

Native rendering helps most with bright or high-pitched sounds, whose content
above 16 kHz folds back into the audible band when the mix is first rendered
at 32 kHz. For pure low tones it is equivalent to the resampler. In the 4 kHz
case it is somewhat worse, because the Gaussian interpolator's own images
above 24 kHz fold at 48 kHz.

## 32 kHz -> 48 kHz resampler (`audio_resampler.sv`)

The S-DSP generates audio at ~32.07 kHz (32 kHz with `DSP_FREQ`). The Pocket's
I2S DAC runs at 48 kHz. Previously the core sampled-and-held the DSP output once
per 48 kHz frame, which irregularly repeated samples (1 or 2 frames each) and
caused audible aliasing/distortion.

`target/pocket/audio_resampler.sv` now converts the DSP stream to 48 kHz:

- Every DSP sample is captured using the DSP's `SND_RDY` strobe (plumbed out as
  `AUDIO_RDY` / `audio_rdy`).
- The I2S block (`sound_i2s.sv`) requests exactly one sample per 48 kHz frame.
- The resampler measures the real DSP sample period and computes the exact
  fractional position of each output sample, then evaluates a 32 tap, 64 phase
  Kaiser windowed-sinc polyphase filter.

Each input sample is used exactly once and each output sample is produced on
demand by the DAC clock, so pitch and tempo are unchanged.

## Regenerating coefficients

```
python3 support/audio/gen_resampler_coefs.py
```

## Simulation (Icarus Verilog)

```
cd support/audio/sim
P=../../../target/pocket
iverilog -g2012 -o new.vvp -P tb.NEW=1 -P tb.FREQ=3000.0 -P tb.DUR_S=0.3 \
  tb.sv sync_fifo_sim.sv $P/audio_resampler.sv $P/audio_resampler_coefs.sv $P/sound_i2s.sv
vvp -n new.vvp   # writes out.txt (decoded I2S samples at 48 kHz)
```

`an.py` reports the measured tone frequency and THD+N. Results (20000 amplitude tone):

| Tone | Old THD+N | New THD+N | Pitch |
|---|---|---|---|
| 440 Hz | -32.1 dB | -80.9 dB | identical |
| 1 kHz | -24.9 dB | -76.7 dB | identical |
| 3 kHz | -15.3 dB | -68.7 dB | identical |
| 7 kHz | -7.6 dB | -61.4 dB | identical |
| 12 kHz | -2.1 dB | -56.7 dB | identical |
