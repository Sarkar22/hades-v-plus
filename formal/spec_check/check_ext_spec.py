#!/usr/bin/env python3
"""Cross-check props/ext_spec.vh (f_spec_ext, simulated with Verilator) against an
independent Python model of the 45 Zbb, Zbs, Zicond, Zbkb, Zbkx and Zknh instructions
(RV32), on corner vectors, every shift amount, bit index and permutation index, and
random vectors.

The model is written differently from ext_spec.vh: bit strings and byte/nibble lists
for the permutations, and the SHA-512 halves taken from the 64-bit functions of
FIPS 180-4 (sigma0, sigma1, Sigma0, Sigma1 of SHA-512) through the identities in the
notes to software developers of the scalar cryptography specification
(sigma0(x) = {sha512sig0h(hi, lo), sha512sig0l(lo, hi)}, likewise sigma1, and
Sigma0(x) = {sha512sum0r(hi, lo), sha512sum0r(lo, hi)}, likewise Sigma1), not from
the instructions' own shift expressions."""
import random, subprocess, sys
M32 = (1 << 32) - 1
NAMES = ["andn", "orn", "xnor", "clz", "ctz", "cpop", "max", "maxu", "min", "minu",
         "sext.b", "sext.h", "zext.h", "rol", "ror", "rori", "orc.b", "rev8",
         "bclr", "bclri", "bext", "bexti", "binv", "binvi", "bset", "bseti",
         "czero.eqz", "czero.nez",
         "pack", "packh", "brev8", "zip", "unzip", "xperm4", "xperm8",
         "sha256sig0", "sha256sig1", "sha256sum0", "sha256sum1",
         "sha512sig0h", "sha512sig0l", "sha512sig1h", "sha512sig1l", "sha512sum0r", "sha512sum1r"]
IMM = {"rori", "bclri", "bexti", "binvi", "bseti"}
def s32(x): return x - (1 << 32) if x & 0x80000000 else x
M64 = (1 << 64) - 1
def rotr(x, n, w): return ((x >> n) | (x << (w - n))) & ((1 << w) - 1)
# FIPS 180-4, 4.1.2 (SHA-256) and 4.1.3 (SHA-512)
def big_sigma0_256(x): return rotr(x, 2, 32) ^ rotr(x, 13, 32) ^ rotr(x, 22, 32)
def big_sigma1_256(x): return rotr(x, 6, 32) ^ rotr(x, 11, 32) ^ rotr(x, 25, 32)
def small_sigma0_256(x): return rotr(x, 7, 32) ^ rotr(x, 18, 32) ^ (x >> 3)
def small_sigma1_256(x): return rotr(x, 17, 32) ^ rotr(x, 19, 32) ^ (x >> 10)
def big_sigma0_512(x): return rotr(x, 28, 64) ^ rotr(x, 34, 64) ^ rotr(x, 39, 64)
def big_sigma1_512(x): return rotr(x, 14, 64) ^ rotr(x, 18, 64) ^ rotr(x, 41, 64)
def small_sigma0_512(x): return rotr(x, 1, 64) ^ rotr(x, 8, 64) ^ (x >> 7)
def small_sigma1_512(x): return rotr(x, 19, 64) ^ rotr(x, 61, 64) ^ (x >> 6)
def hi(x): return x >> 32
def lo(x): return x & M32
def crypto(name, a, b):
    if name == "pack": return int.from_bytes(a.to_bytes(4, "little")[:2] + b.to_bytes(4, "little")[:2], "little")
    if name == "packh": return int.from_bytes(bytes([a & 0xFF, b & 0xFF, 0, 0]), "little")
    if name == "brev8": return int.from_bytes(bytes(int(format(y, "08b")[::-1], 2) for y in a.to_bytes(4, "little")), "little")
    bits = format(a, "032b")[::-1]                 # bits[i] = bit i of rs1
    if name == "zip": return int("".join(bits[i // 2 + 16 * (i % 2)] for i in range(32))[::-1], 2)
    if name == "unzip": return int((bits[0::2] + bits[1::2])[::-1], 2)
    if name == "xperm4":
        table = [(a >> (4 * k)) & 0xF for k in range(8)]
        return sum((table[n] if n < len(table) else 0) << (4 * k)
                   for k, n in enumerate((b >> (4 * k)) & 0xF for k in range(8)))
    if name == "xperm8":
        table = list(a.to_bytes(4, "little"))
        return int.from_bytes(bytes(table[n] if n < len(table) else 0 for n in b.to_bytes(4, "little")), "little")
    if name == "sha256sig0": return small_sigma0_256(a)
    if name == "sha256sig1": return small_sigma1_256(a)
    if name == "sha256sum0": return big_sigma0_256(a)
    if name == "sha256sum1": return big_sigma1_256(a)
    # RV32 halves: a = X(rs1), b = X(rs2); the h forms and sum*r(hi, lo) give the
    # high word of the 64-bit function of {a, b}, the l forms the low word of {b, a}
    if name == "sha512sig0h": return hi(small_sigma0_512(a << 32 | b))
    if name == "sha512sig0l": return lo(small_sigma0_512(b << 32 | a))
    if name == "sha512sig1h": return hi(small_sigma1_512(a << 32 | b))
    if name == "sha512sig1l": return lo(small_sigma1_512(b << 32 | a))
    if name == "sha512sum0r": return hi(big_sigma0_512(a << 32 | b))
    if name == "sha512sum1r": return hi(big_sigma1_512(a << 32 | b))
    raise ValueError(name)
def model(name, a, b, shamt):
    if NAMES.index(name) >= 28: return crypto(name, a, b)
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
           0xFF00FF00, 0x12345678, 0x01000000, 0x0000001F, 0x00000020, 0xFFFFFFE0,
           0x9ABCDEF0, 0x76543210, 0x01234567, 0x89ABCDEF, 0x00010203, 0x04FF0100,
           0x0F0F0F0F, 0xF0F0F0F0, 0x08080808, 0x03020100, 0x07060504]
vecs = []
for i, n in enumerate(NAMES):
    for a in corners:
        for b in corners:
            vecs.append((i, a, b, rng.getrandbits(5)))
        for s in range(32):                         # every shift amount / bit index
            vecs.append((i, a, (rng.getrandbits(27) << 5) | s, s))
        if n in ("xperm4", "xperm8"):               # every index value in every element
            w = 4 if n == "xperm4" else 8
            for k in range(32 // w):
                for v in range(1 << w):
                    vecs.append((i, a, (rng.getrandbits(32) & ~(((1 << w) - 1) << (w * k))) | (v << (w * k)),
                                 rng.getrandbits(5)))
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
# known answers of the scalar cryptography notes (A = 0x12345678, B = 0x9ABCDEF0): the
# model must reproduce them, which anchors it outside this file
A, B = 0x12345678, 0x9ABCDEF0
KAT = [("pack", A, B, 0xDEF05678), ("packh", A, B, 0x0000F078), ("brev8", 0x01020304, 0, 0x8040C020),
       ("zip", 0x0000FFFF, 0, 0x55555555), ("zip", 0xFFFF0000, 0, 0xAAAAAAAA), ("unzip", 0x55555555, 0, 0x0000FFFF),
       ("xperm8", 0x44332211, 0x00010203, 0x11223344), ("xperm8", 0x44332211, 0x04FF0100, 0x00002211),
       ("xperm4", 0x76543210, 0x01234567, 0x01234567), ("xperm4", 0x76543210, 0x89ABCDEF, 0),
       ("xperm4", 0xFEDCBA98, 0xF0F0F0F0, 0x08080808),
       ("sha256sig0", 1, 0, 0x02004000), ("sha256sig1", 1, 0, 0x0000A000),
       ("sha256sum0", 1, 0, 0x40080400), ("sha256sum1", 1, 0, 0x04200080),
       ("sha512sig0h", 0, 1, 0x81000000), ("sha512sig0l", 0, 1, 0x83000000),
       ("sha512sig1h", 0, 1, 0x00002000), ("sha512sig1l", 0, 1, 0x04002000),
       ("sha512sum0r", 0, 1, 0x00000010), ("sha512sum1r", 0, 1, 0x00044000)]
kat_bad = [k for k in KAT if model(k[0], k[1], k[2], 0) != k[3]]
for n in ("brev8", "zip", "unzip"):                 # the model's own involution/inverse identities
    for a in corners:
        if (n == "brev8" and model(n, model(n, a, 0, 0), 0, 0) != a) or \
           (n == "zip" and model("unzip", model("zip", a, 0, 0), 0, 0) != a):
            kat_bad.append((n, a))
for k in kat_bad[:10]:
    print("MODEL KNOWN-ANSWER MISMATCH", k)
bad += len(kat_bad)
print("ext spec cross-check: %d vectors (%d corner/shift, %d random), %d mismatches" % (len(vecs), n_corner, N, bad))
sys.exit(1 if bad else 0)
