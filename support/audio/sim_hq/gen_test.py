#!/usr/bin/env python3
# Builds ARAM image + DSP register script for the HQ renderer testbench.
import sys, math
def clamp16(x): return max(-32768, min(32767, x))
def s16(x):
    x &= 0xFFFF
    return x - 65536 if x & 0x8000 else x

def brr_decode_sample(nib, shift, filt, p1, p2):
    # Exact reference decoder; p1/p2 are the previous two stored (doubled) values
    s = nib - 16 if nib & 8 else nib
    if shift <= 12: s = (s << shift) >> 1
    else: s = -2048 if s < 0 else 0
    q2 = p2 >> 1
    if filt >= 2:
        s += p1; s -= q2
        if filt == 2: s += q2 >> 4; s += (p1 * -3) >> 6
        else: s += (p1 * -13) >> 7; s += (q2 * 3) >> 4
    elif filt == 1:
        s += p1 >> 1; s += (-p1) >> 5
    s = clamp16(s)
    return s16(s * 2)

def encode(samples):
    """Greedy BRR encoder. samples are 15-bit-scale ints, len multiple of 16."""
    out = bytearray(); p1 = p2 = 0
    nblk = len(samples) // 16
    for b in range(nblk):
        blk = samples[b*16:(b+1)*16]
        best = None
        for filt in (range(4) if b else [0]):
            for shift in range(13):
                q1, q2, err, nibs = p1, p2, 0, []
                for x in blk:
                    bn, be, bs = 0, None, 0
                    for n in range(16):
                        s = brr_decode_sample(n, shift, filt, q1, q2)
                        e = (s - 2 * x) ** 2
                        if be is None or e < be: bn, be, bs = n, e, s
                    nibs.append(bn); err += be; q2, q1 = q1, bs
                if best is None or err < best[0]: best = (err, filt, shift, nibs, q1, q2)
        err, filt, shift, nibs, p1, p2 = best
        hdr = (shift << 4) | (filt << 2)
        if b == nblk - 1: hdr |= 3  # loop + end
        out.append(hdr)
        for i in range(0, 16, 2): out.append((nibs[i] << 4) | nibs[i+1])
    return out

test = sys.argv[1] if len(sys.argv) > 1 else "sine"
aram = bytearray(65536)
regs = []
def w(a, v): regs.append((a, v))

# Directory at 0x0200
srcs = []
def add_src(addr, data):
    n = len(srcs)
    aram[addr:addr+len(data)] = data
    aram[0x200+4*n:0x200+4*n+4] = bytes([addr & 255, addr >> 8, addr & 255, addr >> 8])
    srcs.append(addr)

# Source 0: 64-sample sine, 16 cycles in 1024 samples for a cleaner loop (period 64)
N = 1024
sine = [int(round(12000 * math.sin(2*math.pi*16*i/N))) for i in range(N)]
add_src(0x1000, encode(sine))
# Source 1: band-limited saw, 32-sample period, harmonics 1..15
saw = [int(round(sum(5000/k*math.sin(2*math.pi*k*i/32) for k in range(1, 16)))) for i in range(512)]
add_src(0x2000, encode(saw))

sine8 = [int(round(12000 * math.sin(2*math.pi*i/8))) for i in range(128)]
add_src(0x3000, encode(sine8))

w(0x6C, 0x20); w(0x5D, 0x02); w(0x0C, 0x7F); w(0x1C, 0x7F); w(0x2C, 0); w(0x3C, 0)
w(0x4D, 0); w(0x3D, 0); w(0x2D, 0); w(0x5C, 0); w(0x6D, 0x80); w(0x7D, 0); w(0x0D, 0)
for i in range(8): w(0x0F + 16*i, 0x7F if i == 0 else 0)

def voice(v, src, pitch, voll, volr, gain=0x7F, adsr1=0, adsr2=0):
    b = v << 4
    w(b+0, voll & 255); w(b+1, volr & 255); w(b+2, pitch & 255); w(b+3, pitch >> 8)
    w(b+4, src); w(b+5, adsr1); w(b+6, adsr2); w(b+7, gain)

kon = 0
if test == "sine":
    # one sine voice. f = 32000 * P/4096 / 64
    voice(0, 0, int(sys.argv[2], 0) if len(sys.argv) > 2 else 0x1000, 0x60, 0x60)
    kon = 0x01
elif test == "tone":
    voice(0, int(sys.argv[2]), int(sys.argv[3], 0), 0x60, 0x60)
    kon = 0x01
elif test == "mix":
    voice(0, 0, 0x0E31, 0x50, 0x30)
    voice(3, 1, 0x1A00, -0x40, 0x40, adsr1=0x8F, adsr2=0xE0)  # ADSR envelope
    voice(5, 0, 0x0800, 0x30, -0x28)
    voice(6, 0, 0x1000, 0x20, 0x20)
    w(0x3D, 0x40)            # voice 6 noise
    w(0x6C, 0x20 | 0x10)     # noise clock
    w(0x2D, 0x20)            # voice 5 pitch modulated by voice 4 (silent) -> exercises PMON path
    kon = 0x69
elif test == "echo":
    voice(0, 1, 0x0C00, 0x50, 0x50)
    w(0x4D, 0x01); w(0x2C, 0x40); w(0x3C, 0x40); w(0x0D, 0x40); w(0x7D, 0x02); w(0x6D, 0x80)
    w(0x6C, 0x00)            # echo writes enabled
    kon = 0x01
w(0x4C, kon)

with open("aram.hex", "w") as f:
    for b in aram: f.write("%02x\n" % b)
with open("regs.hex", "w") as f:
    for a, v in regs: f.write("%02x%02x\n" % (a, v & 255))
    f.write("ffff\n")
print(test, len(regs), "writes")
