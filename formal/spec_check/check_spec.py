#!/usr/bin/env python3
"""Cross-check props/spec.vh (both f_spec_m and f_spec_ref, simulated with Verilator)
against an independent Python model of RV32M, on corner cases + random vectors."""
import random, subprocess, sys
M32 = (1 << 32) - 1
def s32(x): return x - (1 << 32) if x & 0x80000000 else x
def trunc_div(a, b):
    # truncation toward zero WITHOUT using magnitudes: floor division, then step
    # one toward zero when the exact quotient is negative and inexact
    q = a // b
    if q < 0 and q * b != a:
        q += 1
    return q
def model(op, a, b):
    sa, sb = s32(a), s32(b)
    if op == 53: return (sa * sb) & M32
    if op == 54: return ((sa * sb) >> 32) & M32
    if op == 55: return ((sa * b) >> 32) & M32
    if op == 56: return ((a * b) >> 32) & M32
    if op == 57:
        if b == 0: return M32
        if sa == -2**31 and sb == -1: return 0x80000000
        q = trunc_div(sa, sb); assert -2**31 <= q < 2**31; return q & M32
    if op == 58: return M32 if b == 0 else a // b
    if op == 59:
        if b == 0: return a
        if sa == -2**31 and sb == -1: return 0
        q = trunc_div(sa, sb); r = sa - q * sb
        assert abs(r) < abs(sb) and (r == 0 or (r < 0) == (sa < 0))
        return r & M32
    if op == 60: return a if b == 0 else a % b
    raise ValueError(op)
N = int(sys.argv[1]) if len(sys.argv) > 1 else 1000000
rng = random.Random(20260926)
corners = [0, 1, 2, 3, 5, 7, 0x7FFFFFFE, 0x7FFFFFFF, 0x80000000, 0x80000001,
           0xFFFFFFFF, 0xFFFFFFFE, 0xFFFFFFFD, 0xFFFFFFFB, 0x55555555, 0xAAAAAAAA, 0x10000, 0xFFFF]
vecs = []
for op in range(53, 61):
    for a in corners:
        for b in corners:
            vecs.append((op, a, b))
def rnd():
    k = rng.randrange(4)
    if k == 0: return rng.getrandbits(32)
    if k == 1: return rng.getrandbits(rng.randrange(1, 33))          # small magnitudes
    if k == 2: return (-rng.getrandbits(rng.randrange(1, 32))) & M32  # small negatives
    return rng.choice(corners) ^ (1 << rng.randrange(32))
for i in range(N):
    vecs.append((53 + (i % 8), rnd(), rnd()))
inp = "".join("%x %x %x\n" % v for v in vecs)
out = subprocess.run(["./obj/Vspec_top"], input=inp, capture_output=True, text=True, check=True).stdout.split("\n")
bad = 0
for (op, a, b), line in zip(vecs, out):
    ym, yr = (int(x, 16) for x in line.split())
    exp = model(op, a, b)
    if ym != exp or yr != exp:
        bad += 1
        if bad <= 10: print("MISMATCH op=%d a=%08x b=%08x model=%08x spec_m=%08x spec_ref=%08x" % (op, a, b, exp, ym, yr))
print("spec cross-check: %d vectors (%d corner, %d random), %d mismatches" % (len(vecs), len(vecs) - N, N, bad))
sys.exit(1 if bad else 0)
