#!/usr/bin/env python3
"""Cross-check props/ext_spec.vh (f_spec_ext, simulated with Verilator) against an
independent Python model of the 28 Zbb, Zbs and Zicond instructions (RV32), on corner
vectors, every shift amount and bit index, and random vectors."""
import random, subprocess, sys
M32 = (1 << 32) - 1
NAMES = ["andn", "orn", "xnor", "clz", "ctz", "cpop", "max", "maxu", "min", "minu",
         "sext.b", "sext.h", "zext.h", "rol", "ror", "rori", "orc.b", "rev8",
         "bclr", "bclri", "bext", "bexti", "binv", "binvi", "bset", "bseti",
         "czero.eqz", "czero.nez"]
IMM = {"rori", "bclri", "bexti", "binvi", "bseti"}
def s32(x): return x - (1 << 32) if x & 0x80000000 else x
def model(name, a, b, shamt):
    s = shamt if name in IMM else b % 32           # RV32: the low five bits of rs2
    if name == "andn": return a & (b ^ M32)
    if name == "orn": return (a | (b ^ M32)) & M32
    if name == "xnor": return (a ^ b) ^ M32
    if name == "clz": return 32 - a.bit_length()
    if name == "ctz": return (a & -a).bit_length() - 1 if a else 32
    if name == "cpop": return bin(a).count("1")
    if name == "max": return a if s32(a) >= s32(b) else b
    if name == "maxu": return a if a >= b else b
    if name == "min": return a if s32(a) <= s32(b) else b
    if name == "minu": return a if a <= b else b
    if name == "sext.b": return (((a & 0xFF) ^ 0x80) - 0x80) & M32
    if name == "sext.h": return (((a & 0xFFFF) ^ 0x8000) - 0x8000) & M32
    if name == "zext.h": return a & 0xFFFF
    if name == "rol": return int(format(a, "032b")[s:] + format(a, "032b")[:s], 2)
    if name in ("ror", "rori"): return int(format(a, "032b")[32 - s:] + format(a, "032b")[:32 - s], 2)
    if name == "orc.b": return sum((0xFF if (a >> (8 * k)) & 0xFF else 0) << (8 * k) for k in range(4))
    if name == "rev8": return int.from_bytes(a.to_bytes(4, "little"), "big")
    bits = list(format(a, "032b")[::-1])           # bits[i] = bit i of rs1
    if name in ("bclr", "bclri"): bits[s] = "0"; return int("".join(bits[::-1]), 2)
    if name in ("bext", "bexti"): return int(bits[s])
    if name in ("binv", "binvi"): bits[s] = "1" if bits[s] == "0" else "0"; return int("".join(bits[::-1]), 2)
    if name in ("bset", "bseti"): bits[s] = "1"; return int("".join(bits[::-1]), 2)
    if name == "czero.eqz": return 0 if b == 0 else a
    if name == "czero.nez": return 0 if b != 0 else a
    raise ValueError(name)
N = int(sys.argv[1]) if len(sys.argv) > 1 else 1000000
rng = random.Random(20261002)
corners = [0, 1, 2, 3, 0x7F, 0x80, 0xFF, 0x100, 0x7FFF, 0x8000, 0xFFFF, 0x10000, 0x7FFFFFFF,
           0x80000000, 0x80000001, 0xFFFFFFFF, 0xFFFFFFFE, 0x55555555, 0xAAAAAAAA, 0x00FF00FF,
           0xFF00FF00, 0x12345678, 0x01000000, 0x0000001F, 0x00000020, 0xFFFFFFE0]
vecs = []
for i, n in enumerate(NAMES):
    for a in corners:
        for b in corners:
            vecs.append((i, a, b, rng.getrandbits(5)))
        for s in range(32):                         # every shift amount / bit index
            vecs.append((i, a, (rng.getrandbits(27) << 5) | s, s))
def rnd():
    k = rng.randrange(4)
    if k == 0: return rng.getrandbits(32)
    if k == 1: return rng.getrandbits(rng.randrange(1, 33))
    if k == 2: return (-rng.getrandbits(rng.randrange(1, 32))) & M32
    return rng.choice(corners) ^ (1 << rng.randrange(32))
n_corner = len(vecs)
for i in range(N):
    vecs.append((i % len(NAMES), rnd(), rnd(), rng.getrandbits(5)))
inp = "".join("%x %x %x %x\n" % v for v in vecs)
out = subprocess.run(["./obj_ext/Vext_spec_top"], input=inp, capture_output=True, text=True,
                     check=True).stdout.split("\n")
bad = 0
for (i, a, b, s), line in zip(vecs, out):
    y, exp = int(line, 16), model(NAMES[i], a, b, s)
    if y != exp:
        bad += 1
        if bad <= 10:
            print("MISMATCH %s rs1=%08x rs2=%08x shamt=%d model=%08x spec=%08x" % (NAMES[i], a, b, s, exp, y))
print("ext spec cross-check: %d vectors (%d corner/shift, %d random), %d mismatches" % (len(vecs), n_corner, N, bad))
sys.exit(1 if bad else 0)
