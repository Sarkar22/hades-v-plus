#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""ref.py -- reference model of the Zbb, Zbs, Zicond, Zbkb, Zbkx and Zknh instructions (RV32).

Written from the ratified ISA text (unprivileged manual, chapters "'B' Extension for Bit
Manipulation", "'Zicond' Extension for Integer Conditional Operations" and "Cryptography
Extensions", scalar instructions, Version 1.0.1), not from the RTL. It is deliberately a
different implementation from the two other models of these instructions, so that a shared
mistake is unlikely:
  * test/trapsweep/iss.py computes on Python integers with shifts and masks;
  * test/ext/ref_exh.c computes in C with bit tricks (and is fast enough for 2^32 inputs);
  * this file computes on 32-character bit strings, most significant bit first: rotates are
    string slices, clz/ctz are searches for the first/last '1', cpop counts '1's, sign and
    zero extension repeat or prepend characters, pack/zip/unzip/brev8 join, interleave or
    reverse slices, xperm indexes a list of slices, exclusive or counts '1's per column. The
    logic forms use arithmetic identities.

It also holds the encoding table of the 45 instruction forms (MATCH/MASK, as in
riscv-opcodes) and the vector protocol shared with the RTL harness: corner set, PRNG,
digest and the parts of every form (test/ext/README.md). The SHA-256 and SHA-512 forms are
also checked against FIPS 180-4 and the NIST examples (whole hashes built on them).

usage: ref.py --selftest [--quick] [--jobs N]   known answers, encodings, sweep counts, FIPS 180-4,
                                                cross-checks against iss.py and ref_exh
       ref.py --lines [--form M ...]            digest lines of the non-chunk parts
       ref.py --sweep-counts                    expected new-instruction hits of the
                                                decoder sweeps A, B, D, E and F
"""
import os, sys, random, struct, subprocess, tempfile, shutil
from concurrent.futures import ProcessPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.dont_write_bytecode = True     # no __pycache__ in the source tree

M32 = 0xFFFFFFFF

# ------------------------------------------------------------------------------------------
# Encodings. Columns: mnemonic, extension, class, opcode, funct7 (imm[11:5]), fixed rs2 field
# (imm[4:0]) or None, funct3. Class: 'bin' = rd, rs1, rs2; 'imm' = rd, rs1, shamt;
# 'una' = rd, rs1. The list order is the canonical form order of the vector protocol. The seven
# Zbkb instructions that Zbb also has (rol, ror, rori, andn, orn, xnor, rev8) are Zbb's forms.
OP, OP_IMM = 0b0110011, 0b0010011
FORMS = [
    ("andn",      "Zbb",    "bin", OP,     0b0100000, None,    0b111),
    ("orn",       "Zbb",    "bin", OP,     0b0100000, None,    0b110),
    ("xnor",      "Zbb",    "bin", OP,     0b0100000, None,    0b100),
    ("clz",       "Zbb",    "una", OP_IMM, 0b0110000, 0b00000, 0b001),
    ("ctz",       "Zbb",    "una", OP_IMM, 0b0110000, 0b00001, 0b001),
    ("cpop",      "Zbb",    "una", OP_IMM, 0b0110000, 0b00010, 0b001),
    ("max",       "Zbb",    "bin", OP,     0b0000101, None,    0b110),
    ("maxu",      "Zbb",    "bin", OP,     0b0000101, None,    0b111),
    ("min",       "Zbb",    "bin", OP,     0b0000101, None,    0b100),
    ("minu",      "Zbb",    "bin", OP,     0b0000101, None,    0b101),
    ("sext.b",    "Zbb",    "una", OP_IMM, 0b0110000, 0b00100, 0b001),
    ("sext.h",    "Zbb",    "una", OP_IMM, 0b0110000, 0b00101, 0b001),
    ("zext.h",    "Zbb",    "una", OP,     0b0000100, 0b00000, 0b100),
    ("rol",       "Zbb",    "bin", OP,     0b0110000, None,    0b001),
    ("ror",       "Zbb",    "bin", OP,     0b0110000, None,    0b101),
    ("rori",      "Zbb",    "imm", OP_IMM, 0b0110000, None,    0b101),
    ("orc.b",     "Zbb",    "una", OP_IMM, 0b0010100, 0b00111, 0b101),
    ("rev8",      "Zbb",    "una", OP_IMM, 0b0110100, 0b11000, 0b101),
    ("bclr",      "Zbs",    "bin", OP,     0b0100100, None,    0b001),
    ("bclri",     "Zbs",    "imm", OP_IMM, 0b0100100, None,    0b001),
    ("bext",      "Zbs",    "bin", OP,     0b0100100, None,    0b101),
    ("bexti",     "Zbs",    "imm", OP_IMM, 0b0100100, None,    0b101),
    ("binv",      "Zbs",    "bin", OP,     0b0110100, None,    0b001),
    ("binvi",     "Zbs",    "imm", OP_IMM, 0b0110100, None,    0b001),
    ("bset",      "Zbs",    "bin", OP,     0b0010100, None,    0b001),
    ("bseti",     "Zbs",    "imm", OP_IMM, 0b0010100, None,    0b001),
    ("czero.eqz", "Zicond", "bin", OP,     0b0000111, None,    0b101),
    ("czero.nez", "Zicond", "bin", OP,     0b0000111, None,    0b111),
    ("pack",        "Zbkb", "bin", OP,     0b0000100, None,    0b100),
    ("packh",       "Zbkb", "bin", OP,     0b0000100, None,    0b111),
    ("brev8",       "Zbkb", "una", OP_IMM, 0b0110100, 0b00111, 0b101),
    ("zip",         "Zbkb", "una", OP_IMM, 0b0000100, 0b01111, 0b001),
    ("unzip",       "Zbkb", "una", OP_IMM, 0b0000100, 0b01111, 0b101),
    ("xperm4",      "Zbkx", "bin", OP,     0b0010100, None,    0b010),
    ("xperm8",      "Zbkx", "bin", OP,     0b0010100, None,    0b100),
    ("sha256sig0",  "Zknh", "una", OP_IMM, 0b0001000, 0b00010, 0b001),
    ("sha256sig1",  "Zknh", "una", OP_IMM, 0b0001000, 0b00011, 0b001),
    ("sha256sum0",  "Zknh", "una", OP_IMM, 0b0001000, 0b00000, 0b001),
    ("sha256sum1",  "Zknh", "una", OP_IMM, 0b0001000, 0b00001, 0b001),
    ("sha512sig0h", "Zknh", "bin", OP,     0b0101110, None,    0b000),
    ("sha512sig0l", "Zknh", "bin", OP,     0b0101010, None,    0b000),
    ("sha512sig1h", "Zknh", "bin", OP,     0b0101111, None,    0b000),
    ("sha512sig1l", "Zknh", "bin", OP,     0b0101011, None,    0b000),
    ("sha512sum0r", "Zknh", "bin", OP,     0b0101000, None,    0b000),
    ("sha512sum1r", "Zknh", "bin", OP,     0b0101001, None,    0b000),
]
NAMES = [f[0] for f in FORMS]
INDEX = {n: i for i, n in enumerate(NAMES)}
CLASS = {f[0]: f[2] for f in FORMS}
# Register forms whose rs2 value is a bit index or rotate amount (protocol part 'amount').
AMOUNT_FORMS = ("rol", "ror", "bclr", "bext", "binv", "bset")
# Register forms whose rs2 value is a list of indices (protocol part 'index'), with the mask that
# keeps half of the indices in range: nibble indices 0..15 (8..15 out of range), byte indices
# 0..3 or 0x80..0x83.
INDEX_FORMS = {"xperm4": 0xFFFFFFFF, "xperm8": 0x83838383}
# Immediate form -> the register form with the same operation.
IMM_BASE = {"rori": "ror", "bclri": "bclr", "bexti": "bext", "binvi": "binv", "bseti": "bset"}

# MATCH/MASK as published in riscv-opcodes (written out, then checked against the fields above).
MATCH_MASK = {
    "andn": (0x40007033, 0xFE00707F), "orn": (0x40006033, 0xFE00707F), "xnor": (0x40004033, 0xFE00707F),
    "clz": (0x60001013, 0xFFF0707F), "ctz": (0x60101013, 0xFFF0707F), "cpop": (0x60201013, 0xFFF0707F),
    "max": (0x0A006033, 0xFE00707F), "maxu": (0x0A007033, 0xFE00707F),
    "min": (0x0A004033, 0xFE00707F), "minu": (0x0A005033, 0xFE00707F),
    "sext.b": (0x60401013, 0xFFF0707F), "sext.h": (0x60501013, 0xFFF0707F), "zext.h": (0x08004033, 0xFFF0707F),
    "rol": (0x60001033, 0xFE00707F), "ror": (0x60005033, 0xFE00707F), "rori": (0x60005013, 0xFE00707F),
    "orc.b": (0x28705013, 0xFFF0707F), "rev8": (0x69805013, 0xFFF0707F),
    "bclr": (0x48001033, 0xFE00707F), "bclri": (0x48001013, 0xFE00707F),
    "bext": (0x48005033, 0xFE00707F), "bexti": (0x48005013, 0xFE00707F),
    "binv": (0x68001033, 0xFE00707F), "binvi": (0x68001013, 0xFE00707F),
    "bset": (0x28001033, 0xFE00707F), "bseti": (0x28001013, 0xFE00707F),
    "czero.eqz": (0x0E005033, 0xFE00707F), "czero.nez": (0x0E007033, 0xFE00707F),
    "pack": (0x08004033, 0xFE00707F), "packh": (0x08007033, 0xFE00707F),
    "brev8": (0x68705013, 0xFFF0707F), "zip": (0x08F01013, 0xFFF0707F), "unzip": (0x08F05013, 0xFFF0707F),
    "xperm4": (0x28002033, 0xFE00707F), "xperm8": (0x28004033, 0xFE00707F),
    "sha256sig0": (0x10201013, 0xFFF0707F), "sha256sig1": (0x10301013, 0xFFF0707F),
    "sha256sum0": (0x10001013, 0xFFF0707F), "sha256sum1": (0x10101013, 0xFFF0707F),
    "sha512sig0h": (0x5C000033, 0xFE00707F), "sha512sig0l": (0x54000033, 0xFE00707F),
    "sha512sig1h": (0x5E000033, 0xFE00707F), "sha512sig1l": (0x56000033, 0xFE00707F),
    "sha512sum0r": (0x50000033, 0xFE00707F), "sha512sum1r": (0x52000033, 0xFE00707F),
}


def encode(name, rd, rs1, rs2=0):
    """Instruction word; rs2 is the register (bin), the shift amount (imm) or ignored (una)."""
    _, _, cls, opc, f7, fixed, f3 = FORMS[INDEX[name]]
    if fixed is not None:
        rs2 = fixed
    return (f7 << 25) | ((rs2 & 31) << 20) | ((rs1 & 31) << 15) | (f3 << 12) | ((rd & 31) << 7) | opc


def classify(word):
    """Name of the form `word` encodes, or None. Exactly the MATCH/MASK test, first match in form
    order: the one overlap is zext.h, which is pack with rs2 = x0 (same result), named zext.h."""
    hit = [n for n in NAMES if word & MATCH_MASK[n][1] == MATCH_MASK[n][0]]
    assert len(hit) <= 1 or hit == ["zext.h", "pack"], f"{word:#010x} matches {hit}"
    return hit[0] if hit else None


# ------------------------------------------------------------------------------------------
# The model, on bit strings (index 0 = bit 31).
def bits(x):
    return format(x & M32, "032b")

def val(s):
    return int(s, 2)

def m_andn(a, b): return a - (a & b)                 # the bits of a that are not in b
def m_orn(a, b):  return M32 - (b - (a & b))         # complement of (b and not a)
def m_xnor(a, b): return M32 - (a ^ b)

def m_clz(a):
    i = bits(a).find("1")
    return 32 if i < 0 else i

def m_ctz(a):
    i = bits(a).rfind("1")
    return 32 if i < 0 else 31 - i

def m_cpop(a): return bits(a).count("1")

def _key(x, signed):
    s = bits(x)                                      # signed order = unsigned order with the
    return val(("1" if s[0] == "0" else "0") + s[1:]) if signed else x   # sign bit inverted

def m_min(a, b):  return a if _key(a, True) <= _key(b, True) else b
def m_max(a, b):  return a if _key(a, True) >= _key(b, True) else b
def m_minu(a, b): return a if a <= b else b
def m_maxu(a, b): return a if a >= b else b

def m_sext_b(a):
    s = bits(a); return val(s[24] * 24 + s[24:])

def m_sext_h(a):
    s = bits(a); return val(s[16] * 16 + s[16:])

def m_zext_h(a): return val("0" * 16 + bits(a)[16:])

def _amount(b): return val(bits(b)[27:])             # rs2[4:0]

def m_rol(a, b):
    k = _amount(b); s = bits(a); return val(s[k:] + s[:k])

def m_ror(a, b):
    k = _amount(b); s = bits(a); return val(s[32 - k:] + s[:32 - k])

def m_orc_b(a):
    s = bits(a)
    return val("".join("11111111" if "1" in s[i:i + 8] else "00000000" for i in range(0, 32, 8)))

def m_rev8(a):
    s = bits(a); return val(s[24:32] + s[16:24] + s[8:16] + s[0:8])

def _setbit(a, b, c):
    i = 31 - _amount(b); s = bits(a)
    return val(s[:i] + (c if c in "01" else "10"[int(s[i])]) + s[i + 1:])

def m_bclr(a, b): return _setbit(a, b, "0")
def m_bset(a, b): return _setbit(a, b, "1")
def m_binv(a, b): return _setbit(a, b, "~")
def m_bext(a, b): return int(bits(a)[31 - _amount(b)])

def m_czero_eqz(a, b): return 0 if b == 0 else a
def m_czero_nez(a, b): return a if b == 0 else 0

# Zbkb, Zbkx, Zknh ("Cryptography Extensions", scalar instructions, Version 1.0.1): bit strings
# again. Exclusive or is character-wise, rotates are slices, shifts drop and pad characters.
def _xor(*ss):
    return "".join("1" if col.count("1") % 2 else "0" for col in zip(*ss))

def _rotr(s, k): return s[32 - k:] + s[:32 - k]
def _srl(s, k):  return "0" * k + s[:32 - k]
def _sll(s, k):  return s[k:] + "0" * k

def m_pack(a, b):  return val(bits(b)[16:] + bits(a)[16:])            # rs2 low half above rs1 low half
def m_packh(a, b): return val("0" * 16 + bits(b)[24:] + bits(a)[24:])

def m_brev8(a):
    s = bits(a); return val("".join(s[i:i + 8][::-1] for i in range(0, 32, 8)))

def m_zip(a):      # low half to the even bits, high half to the odd bits
    s = bits(a); return val("".join(h + l for h, l in zip(s[:16], s[16:])))

def m_unzip(a):    # odd bits to the high half, even bits to the low half
    s = bits(a); return val(s[0::2] + s[1::2])

def _xperm(a, b, w):
    """Elements of w bits: rd element i = rs1 element (rs2 element i), or 0 past the end."""
    n = 32 // w
    lut = [bits(a)[32 - w * (i + 1):32 - w * i] for i in range(n)]       # element i of rs1
    idx = [val(bits(b)[32 - w * (i + 1):32 - w * i]) for i in range(n)]  # element i of rs2
    return val("".join(lut[idx[i]] if idx[i] < n else "0" * w for i in reversed(range(n))))

def m_xperm4(a, b): return _xperm(a, b, 4)
def m_xperm8(a, b): return _xperm(a, b, 8)

def m_sha256sig0(a): s = bits(a); return val(_xor(_rotr(s, 7), _rotr(s, 18), _srl(s, 3)))
def m_sha256sig1(a): s = bits(a); return val(_xor(_rotr(s, 17), _rotr(s, 19), _srl(s, 10)))
def m_sha256sum0(a): s = bits(a); return val(_xor(_rotr(s, 2), _rotr(s, 13), _rotr(s, 22)))
def m_sha256sum1(a): s = bits(a); return val(_xor(_rotr(s, 6), _rotr(s, 11), _rotr(s, 25)))

def m_sha512sig0h(a, b):
    x, y = bits(a), bits(b); return val(_xor(_srl(x, 1), _srl(x, 7), _srl(x, 8), _sll(y, 31), _sll(y, 24)))
def m_sha512sig0l(a, b):
    x, y = bits(a), bits(b); return val(_xor(_srl(x, 1), _srl(x, 7), _srl(x, 8), _sll(y, 31), _sll(y, 25), _sll(y, 24)))
def m_sha512sig1h(a, b):
    x, y = bits(a), bits(b); return val(_xor(_sll(x, 3), _srl(x, 6), _srl(x, 19), _srl(y, 29), _sll(y, 13)))
def m_sha512sig1l(a, b):
    x, y = bits(a), bits(b); return val(_xor(_sll(x, 3), _srl(x, 6), _srl(x, 19), _srl(y, 29), _sll(y, 26), _sll(y, 13)))
def m_sha512sum0r(a, b):
    x, y = bits(a), bits(b); return val(_xor(_sll(x, 25), _sll(x, 30), _srl(x, 28), _srl(y, 7), _srl(y, 2), _sll(y, 4)))
def m_sha512sum1r(a, b):
    x, y = bits(a), bits(b); return val(_xor(_sll(x, 23), _srl(x, 14), _srl(x, 18), _srl(y, 9), _sll(y, 18), _sll(y, 14)))

MODEL = {
    "andn": m_andn, "orn": m_orn, "xnor": m_xnor, "clz": m_clz, "ctz": m_ctz, "cpop": m_cpop,
    "max": m_max, "maxu": m_maxu, "min": m_min, "minu": m_minu,
    "sext.b": m_sext_b, "sext.h": m_sext_h, "zext.h": m_zext_h, "rol": m_rol, "ror": m_ror,
    "orc.b": m_orc_b, "rev8": m_rev8, "bclr": m_bclr, "bext": m_bext, "binv": m_binv, "bset": m_bset,
    "czero.eqz": m_czero_eqz, "czero.nez": m_czero_nez,
    "pack": m_pack, "packh": m_packh, "brev8": m_brev8, "zip": m_zip, "unzip": m_unzip,
    "xperm4": m_xperm4, "xperm8": m_xperm8, "sha256sig0": m_sha256sig0, "sha256sig1": m_sha256sig1,
    "sha256sum0": m_sha256sum0, "sha256sum1": m_sha256sum1, "sha512sig0h": m_sha512sig0h,
    "sha512sig0l": m_sha512sig0l, "sha512sig1h": m_sha512sig1h, "sha512sig1l": m_sha512sig1l,
    "sha512sum0r": m_sha512sum0r, "sha512sum1r": m_sha512sum1r,
}
for _i, _r in IMM_BASE.items():
    MODEL[_i] = MODEL[_r]       # the shift amount is the immediate (always < 32)


def compute(name, a, b=0):
    """rd for operands a (rs1 value) and b (rs2 value for 'bin', shamt for 'imm', ignored for 'una')."""
    f = MODEL[name]
    return f(a) if CLASS[name] == "una" else f(a, b)


# ------------------------------------------------------------------------------------------
# Vector protocol.
CORNER = sorted(set(
    [0, M32]
    + [1 << k for k in range(32)]
    + [M32 ^ (1 << k) for k in range(32)]
    + [(1 << k) - 1 for k in range(1, 33)]
    + [(M32 << k) & M32 for k in range(1, 32)]
    + [0x55555555, 0xAAAAAAAA, 0x33333333, 0xCCCCCCCC, 0x0F0F0F0F, 0xF0F0F0F0, 0x00FF00FF,
       0xFF00FF00, 0x01010101, 0x80808080, 0x7F7F7F7F, 0xFEFEFEFE, 0x00010001, 0x80000001,
       0x7FFFFFFE, 0x12345678, 0x87654321, 0xDEADBEEF, 0x0000FF00, 0x00FF0000, 0xFFFFFF80,
       0xFFFF8000, 0x000000FF]))
M64 = (1 << 64) - 1
FNV0, FNVP = 0xCBF29CE484222325, 0x100000001B3
RANDOM_N, ZERO_N, SHAMT_RANDOM_N, INDEX_N = 1 << 20, 4096, 4096, 256
NOISE = 0xA5A5A5A5        # rs2 value of the immediate and unary forms


class SplitMix64:
    def __init__(self, state):
        self.state = state & M64

    def next(self):
        self.state = (self.state + 0x9E3779B97F4A7C15) & M64
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & M64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & M64
        return z ^ (z >> 31)


def fnv(values, h=FNV0):
    for v in values:
        h = ((h ^ v) * FNVP) & M64
    return h


def parts(name):
    cls = CLASS[name]
    if cls == "bin":
        return ["corner", "random"] + (["amount"] if name in AMOUNT_FORMS else []) + \
               (["zero"] if name.startswith("czero") else []) + (["index"] if name in INDEX_FORMS else [])
    if cls == "imm":
        return ["shamt"]
    return [f"c{n:03d}" for n in range(256)]


def vectors(name, part, rng):
    """Yields (digested values) of one part; consumes rng exactly as the protocol says.
    Each item is (a, b) for 'bin' parts, (s, a, noise) for 'shamt', (x,) for chunks."""
    if part == "corner":
        for a in CORNER:
            for b in CORNER:
                yield a, b
    elif part == "random":
        for _ in range(RANDOM_N):
            z = rng.next(); yield z & M32, z >> 32
    elif part == "amount":
        for a in CORNER:
            for s in range(32):
                z = rng.next(); yield a, s | ((z & ((1 << 27) - 1)) << 5)
    elif part == "zero":
        for _ in range(ZERO_N):
            yield rng.next() & M32, 0
    elif part == "index":
        for a in CORNER:
            for _ in range(INDEX_N):
                yield a, (rng.next() >> 32) & INDEX_FORMS[name]
    elif part == "shamt":
        for s in range(32):
            for a in CORNER:
                yield s, a, NOISE
            for _ in range(SHAMT_RANDOM_N):
                z = rng.next(); yield s, z & M32, z >> 32
    else:
        n = int(part[1:])
        for x in range(n << 24, (n + 1) << 24):
            yield (x,)


def is_chunk(part):
    return part[0] == "c" and part[1:].isdigit()


def part_count(name, part):
    return {"corner": len(CORNER) ** 2, "random": RANDOM_N, "amount": len(CORNER) * 32, "zero": ZERO_N,
            "shamt": 32 * (len(CORNER) + SHAMT_RANDOM_N), "index": len(CORNER) * INDEX_N}.get(part, 1 << 24)


def digest_lines(name, chunks=False):
    """Protocol lines of one form: '<mnemonic> <part> <vectors> <digest>' (chunks only if asked:
    2^24 values each are slow in Python; ref_exh computes them)."""
    rng = SplitMix64(0x0123456789ABCDEF + INDEX[name])
    f = MODEL[name]; cls = CLASS[name]; out = []
    for p in parts(name):
        if is_chunk(p) and not chunks:
            continue
        h = FNV0; n = 0
        if cls == "bin":
            for a, b in vectors(name, p, rng):
                rd = f(a, b)
                h = ((((((h ^ a) * FNVP) & M64 ^ b) * FNVP) & M64 ^ rd) * FNVP) & M64; n += 1
        elif cls == "imm":
            for s, a, _ in vectors(name, p, rng):
                rd = f(a, s)
                h = ((((((h ^ s) * FNVP) & M64 ^ a) * FNVP) & M64 ^ rd) * FNVP) & M64; n += 1
        else:
            for (x,) in vectors(name, p, rng):
                h = ((h ^ f(x)) * FNVP) & M64; n += 1
        assert n == part_count(name, p)
        out.append(f"{name} {p} {n} {h:016x}")
    return out


# ------------------------------------------------------------------------------------------
# Self-test.
KNOWN = [   # (form, rs1, rs2 or shamt, rd): the spec's known answers, then further hand-worked ones
    ("clz", 0, 0, 32), ("clz", 1, 0, 31), ("clz", 0x80000000, 0, 0), ("ctz", 0, 0, 32), ("ctz", 0x80000000, 0, 31),
    ("cpop", M32, 0, 32), ("orc.b", 0x00010080, 0, 0x00FF00FF), ("rev8", 0x12345678, 0, 0x78563412),
    ("sext.b", 0x80, 0, 0xFFFFFF80), ("sext.h", 0x12348000, 0, 0xFFFF8000), ("zext.h", 0xFFFF8000, 0, 0x00008000),
    ("rol", 0x80000001, 1, 0x00000003), ("ror", 3, 1, 0x80000001), ("min", M32, 1, M32), ("minu", M32, 1, 1),
    ("bext", 0x80000000, 31, 1), ("bset", 0, 37, 0x20), ("czero.eqz", 5, 0, 0), ("czero.nez", 5, 0, 5),
    ("andn", 0xFF, 0x0F, 0xF0), ("andn", 0x0F, 0xFF, 0), ("orn", 0, 0xFFFFFFFE, 1), ("orn", 0x10, M32, 0x10),
    ("xnor", 0x0F0F0F0F, 0x00FF00FF, 0xF00FF00F), ("xnor", 0, 0, M32),
    ("clz", 0x00010000, 0, 15), ("ctz", 1, 0, 0), ("ctz", 0x00010000, 0, 16), ("cpop", 0, 0, 0),
    ("cpop", 0x80000001, 0, 2), ("cpop", 0xDEADBEEF, 0, 24),
    ("max", M32, 1, 1), ("max", 0x80000000, 0x7FFFFFFF, 0x7FFFFFFF), ("min", 0x80000000, 0x7FFFFFFF, 0x80000000),
    ("maxu", M32, 1, M32), ("minu", 0x80000000, 0x7FFFFFFF, 0x7FFFFFFF), ("maxu", 0x80000000, 0x7FFFFFFF, 0x80000000),
    ("sext.b", 0x7F, 0, 0x7F), ("sext.b", 0xFFFFFF7F, 0, 0x7F), ("sext.h", 0x7FFF, 0, 0x7FFF),
    ("sext.h", 0x0000FF80, 0, 0xFFFFFF80), ("zext.h", 0x12345678, 0, 0x5678),
    ("rol", 0x12345678, 4, 0x23456781), ("ror", 0x12345678, 4, 0x81234567), ("rol", 0x12345678, 32, 0x12345678),
    ("ror", 0x12345678, 0xFFFFFFE4, 0x81234567), ("rori", 0x12345678, 4, 0x81234567), ("rori", 1, 31, 2),
    ("orc.b", 1, 0, 0xFF), ("orc.b", 0x80000000, 0, 0xFF000000), ("orc.b", 0, 0, 0), ("rev8", 1, 0, 0x01000000),
    ("bclr", M32, 0, 0xFFFFFFFE), ("bclr", M32, 63, 0x7FFFFFFF), ("bclri", M32, 31, 0x7FFFFFFF),
    ("bext", 0x10, 4, 1), ("bext", 0x10, 36, 1), ("bext", 0x10, 3, 0), ("bext", M32, 5, 1), ("bexti", 0x80000000, 31, 1),
    ("binv", 0, 31, 0x80000000), ("binv", M32, 0, 0xFFFFFFFE), ("binvi", 0x80000000, 31, 0),
    ("bset", 0x80000000, 31, 0x80000000), ("bseti", 0, 31, 0x80000000),
    ("czero.eqz", 5, 7, 5), ("czero.nez", 5, 7, 0), ("czero.eqz", 0, 7, 0), ("czero.nez", M32, 0x80000000, 0),
    # Zbkb, Zbkx, Zknh with A = 0x12345678, B = 0x9ABCDEF0, then further hand-worked ones
    ("pack", 0x12345678, 0x9ABCDEF0, 0xDEF05678), ("packh", 0x12345678, 0x9ABCDEF0, 0x0000F078),
    ("pack", 0x12345678, 0, 0x00005678), ("brev8", 0x12345678, 0, 0x482C6A1E), ("brev8", 0x01020304, 0, 0x8040C020),
    ("zip", 0x0000FFFF, 0, 0x55555555), ("zip", 0xFFFF0000, 0, 0xAAAAAAAA), ("zip", 0x12345678, 0, 0x131C1F60),
    ("unzip", 0x12345678, 0, 0x141646EC), ("unzip", 0x55555555, 0, 0x0000FFFF),
    ("xperm8", 0x44332211, 0x00010203, 0x11223344), ("xperm8", 0x44332211, 0x04FF0100, 0x00002211),
    ("xperm4", 0x76543210, 0x01234567, 0x01234567), ("xperm4", 0x76543210, 0x89ABCDEF, 0x00000000),
    ("xperm4", 0xFEDCBA98, 0xF0F0F0F0, 0x08080808),
    ("sha256sig0", 1, 0, 0x02004000), ("sha256sig1", 1, 0, 0x0000A000), ("sha256sum0", 1, 0, 0x40080400),
    ("sha256sum1", 1, 0, 0x04200080), ("sha256sig0", 0x12345678, 0, 0xE7FCE6EE), ("sha256sig1", 0x12345678, 0, 0xA1F78649),
    ("sha256sum0", 0x12345678, 0, 0x66146474), ("sha256sum1", 0x12345678, 0, 0x3561ABDA),
    ("sha512sig0h", 0x12345678, 0x9ABCDEF0, 0xF92C77C6), ("sha512sig0l", 0x12345678, 0x9ABCDEF0, 0x192C77C6),
    ("sha512sig1h", 0x12345678, 0x9ABCDEF0, 0x0A3460DB), ("sha512sig1l", 0x12345678, 0x9ABCDEF0, 0xCA3460DB),
    ("sha512sum0r", 0x12345678, 0x9ABCDEF0, 0x7C57A100), ("sha512sum1r", 0x12345678, 0x9ABCDEF0, 0x70311233),
    ("sha512sig0h", 0, 1, 0x81000000), ("sha512sig0l", 0, 1, 0x83000000), ("sha512sig1h", 0, 1, 0x00002000),
    ("sha512sig1l", 0, 1, 0x04002000), ("sha512sum0r", 0, 1, 0x00000010), ("sha512sum1r", 0, 1, 0x00044000),
    ("pack", 0xFFFF0000, 0x0000FFFF, 0xFFFF0000), ("packh", 0x000001FF, 0x000002FE, 0x0000FEFF),
    ("brev8", 0x00000080, 0, 0x00000001), ("brev8", M32, 0, M32), ("zip", 0x00000001, 0, 0x00000001),
    ("zip", 0x00010000, 0, 0x00000002), ("unzip", 0x00000002, 0, 0x00010000), ("unzip", 0x80000000, 0, 0x80000000),
    ("xperm8", 0x44332211, 0x80808080, 0), ("xperm8", 0x44332211, 0x03030303, 0x44444444),
    ("xperm4", 0x76543210, 0x00000008, 0x00000000), ("xperm4", 0x76543210, 0x00000007, 0x00000007),
    ("sha256sig0", 0x80000000, 0, 0x11002000), ("sha256sum1", 0x80000000, 0, 0x02100040),
    ("sha512sig0h", 1, 0, 0), ("sha512sig1h", 1, 0, 0x00000008), ("sha512sum0r", 1, 0, 0x42000000),
    ("sha512sum1r", 1, 0, 0x00800000),
]
# Words written by binutils 2.39 for rd=a0, rs1=a1, rs2=a2 (operand 31 for the shift forms).
BINUTILS = {"andn": 0x40C5F533, "clz": 0x60059513, "zext.h": 0x0805C533, "rori": 0x61F5D513, "orc.b": 0x2875D513,
            "rev8": 0x6985D513, "bseti": 0x29F59513, "czero.eqz": 0x0EC5D533, "czero.nez": 0x0EC5F533,
            "pack": 0x08C5C533, "packh": 0x08C5F533, "brev8": 0x6875D513, "zip": 0x08F59513, "unzip": 0x08F5D513,
            "xperm4": 0x28C5A533, "xperm8": 0x28C5C533, "sha256sig0": 0x10259513, "sha256sig1": 0x10359513,
            "sha256sum0": 0x10059513, "sha256sum1": 0x10159513, "sha512sig0h": 0x5CC58533,
            "sha512sig0l": 0x54C58533, "sha512sig1h": 0x5EC58533, "sha512sig1l": 0x56C58533,
            "sha512sum0r": 0x50C58533, "sha512sum1r": 0x52C58533}
# Neighbours that must stay illegal: RV32-reserved shamt[5]=1, other extensions, unused funct3/funct7.
NEIGHBOURS = [0x6205D513, 0x4A059513, 0x4A05D513, 0x6A059513, 0x2A059513, 0x6B85D513, 0x6865D513, 0x2865D513,
              0x28F5D513, 0x6995D513, 0x60359513, 0x60659513, 0x61F59513, 0x08E59513, 0x08E5D513, 0x08C5D533,
              0x08C5E533, 0x0AC59533, 0x0AC5A533, 0x0AC5B533, 0x0AC58533, 0x28C58533, 0x28C5E533, 0x40C59533,
              0x40C5A533, 0x40C5B533, 0x60C58533, 0x60C5A533, 0x60C5C533, 0x60C5E533, 0x60C5F533, 0x48C58533,
              0x48C5F533, 0x68C5D533, 0x28C5D533, 0x0EC58533, 0x0EC59533, 0x0EC5E533, 0x0CC5D533, 0x1EC5D533,
              0x0805C53B, 0x60C5953B, 0x6005951B,
              # the hand-written encodings of test/asm/zbaadv.s and the illegal words of fuzz.py/probes.py
              0x20C58533, 0x20C59533, 0x20C5B533, 0x20C5D533, 0x20C5F533, 0x10C5A533, 0x30C5A533, 0x22C5A533,
              0x60C5A533, 0x28C5B533, 0x20059513, 0x00000000, 0xFFFFFFFF,
              # next to Zbkb, Zbkx and Zknh: RV64-only forms (sha512sum0/sum1/sig0/sig1 in the sha256
              # group, aes64im, aes64ks1i, packw, the OP-32 zext.h), Zksh, Zkne, Zknd, Zksed and Zbkc
              # forms, unused funct3/funct7 and rs2-field values, inst[25] or inst[31] set
              0x10459513, 0x10559513, 0x10659513, 0x10759513, 0x10859513, 0x10959513, 0x11F59513, 0x1025D513,
              0x12259513, 0x30059513, 0x31059513, 0x6885D513, 0x6A75D513, 0x09F59513, 0x0AF59513, 0x0AF5D513,
              0x08059513, 0x08C58533, 0x08C59533, 0x08C5A533, 0x08C5B533, 0x28C5F533, 0x58C58533, 0x5AC58533,
              0x50C59533, 0x5CC5C533, 0xD6C58533, 0x10C58533, 0x22C58533, 0x26C58533, 0x2AC58533, 0x2EC58533,
              0xE2C58533, 0x30C58533, 0x34C58533, 0x08C5C53B]


def sweep_words():
    """The deterministic words of the decoder sweeps A, B, D, E and F (sweep C is random)."""
    A = [(f7 << 25) | (12 << 20) | (11 << 15) | (f3 << 12) | (10 << 7) | oc
         for oc in range(128) for f3 in range(8) for f7 in range(128)]
    B = []
    for k in range(8):
        rd, rs1, rs2 = (k * 3 + 1) % 32, (k * 7 + 2) % 32, (k * 11 + 5) % 32
        B += [(f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | OP for f3 in range(8) for f7 in range(128)]
    D = [(f7 << 25) | (12 << 20) | (11 << 15) | (f3 << 12) | (10 << 7) | OP_IMM for f3 in range(8) for f7 in range(128)]
    pairs = [(10, 11), (0, 31)]
    E = [(imm << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | OP_IMM
         for rd, rs1 in pairs for f3 in range(8) for imm in range(4096)]
    F = [(f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | OP
         for rd, rs1 in pairs for f7 in range(128) for rs2 in range(32) for f3 in range(8)]
    return {"A": A, "B": B, "D": D, "E": E, "F": F}


def sweep_counts(verbose=True):
    W = sweep_words()
    per = {}; tot = dict.fromkeys(NAMES, 0); shamts = {n: set() for n in IMM_BASE}
    for sw, words in W.items():
        n = 0
        for w in words:
            c = classify(w)
            if c:
                n += 1; tot[c] += 1
                if c in IMM_BASE: shamts[c].add((w >> 20) & 31)
        per[sw] = (len(words), n)
    zba = sum(1 for w in W["F"] if (w >> 25) == 0x10 and (w >> 12) & 7 in (2, 4, 6)) // 2
    m = sum(1 for w in W["F"] if (w >> 25) == 1) // 2
    if verbose:
        print("words / new-instruction hits per sweep: " + "  ".join(f"{k}={v[0]}/{v[1]}" for k, v in per.items()))
        print("hits per form over A+B+D+E+F: " + " ".join(f"{k}={v}" for k, v in tot.items()))
        print(f"total {sum(tot.values())}; per (rd, rs1) pair in F: {zba} Zba, {m} M words")
    exp = {"A": (131072, 30), "B": (8192, 200), "D": (1024, 5), "E": (65536, 348), "F": (65536, 1600)}
    ok = per == exp and sum(tot.values()) == 2183 and zba == 96 and m == 256
    # pack loses the two F words with rs2 field 0 (zext.h) and sweep C's word; every other register
    # form: 1 in A, 8 in B, 32 per pair in F
    ok &= all(tot[n] == (71 if n == "pack" else {"bin": 73, "imm": 66, "una": 2}[CLASS[n]]) for n in NAMES)
    ok &= all(len(s) == 32 for s in shamts.values())
    return ok


# ------------------------------------------------------------------------------------------
# SHA-256 and SHA-512 as FIPS 180-4 defines them, on Python integers, for the self-test: the
# model's Zknh forms must give the same sigma and sum functions, and complete hashes built on
# them must reproduce the NIST examples.
def _r32(x, n): return ((x >> n) | (x << (32 - n))) & M32
def _r64(x, n): return ((x >> n) | (x << (64 - n))) & M64

FIPS256 = {"sig0": lambda x: _r32(x, 7) ^ _r32(x, 18) ^ (x >> 3), "sig1": lambda x: _r32(x, 17) ^ _r32(x, 19) ^ (x >> 10),
           "sum0": lambda x: _r32(x, 2) ^ _r32(x, 13) ^ _r32(x, 22), "sum1": lambda x: _r32(x, 6) ^ _r32(x, 11) ^ _r32(x, 25)}
FIPS512 = {"sig0": lambda x: _r64(x, 1) ^ _r64(x, 8) ^ (x >> 7), "sig1": lambda x: _r64(x, 19) ^ _r64(x, 61) ^ (x >> 6),
           "sum0": lambda x: _r64(x, 28) ^ _r64(x, 34) ^ _r64(x, 39), "sum1": lambda x: _r64(x, 14) ^ _r64(x, 18) ^ _r64(x, 41)}

def zknh512(fn, x):
    """A SHA-512 function of a 64-bit word from two RV32 instructions, as the specification's notes
    to software developers pair them: high half (rs1 = high, rs2 = low), low half (operands swapped)."""
    hi, lo = x >> 32, x & M32
    h = {"sig0": "sha512sig0h", "sig1": "sha512sig1h", "sum0": "sha512sum0r", "sum1": "sha512sum1r"}[fn]
    l = {"sig0": "sha512sig0l", "sig1": "sha512sig1l", "sum0": "sha512sum0r", "sum1": "sha512sum1r"}[fn]
    return (compute(h, hi, lo) << 32) | compute(l, lo, hi)

def _primes(n):
    p = []; k = 2
    while len(p) < n:
        if all(k % q for q in p): p.append(k)
        k += 1
    return p

def _iroot(v, r):
    """floor(v ** (1/r)) for integers"""
    x = int(round(v ** (1.0 / r)))
    while x ** r > v: x -= 1
    while (x + 1) ** r <= v: x += 1
    return x

def sha2(msg, wide, f):
    """SHA-256 (wide False) or SHA-512 of bytes msg, with the four functions f[name](x). The
    constants are derived as FIPS 180-4 defines them (fractional parts of square and cube roots of
    the first primes) rather than typed in."""
    w = 64 if wide else 32; mask = (1 << w) - 1; rounds = 80 if wide else 64
    P = _primes(rounds)
    H = [_iroot(p << (2 * w), 2) & mask for p in P[:8]]
    K = [_iroot(p << (3 * w), 3) & mask for p in P]
    blk = 128 if wide else 64
    ml = len(msg) * 8
    m = msg + b"\x80" + b"\0" * ((blk - (len(msg) + 1 + 2 * w // 8)) % blk) + ml.to_bytes(2 * w // 8, "big")
    for o in range(0, len(m), blk):
        W = [int.from_bytes(m[o + i:o + i + w // 8], "big") for i in range(0, blk, w // 8)]
        for t in range(16, rounds):
            W.append((f["sig1"](W[t - 2]) + W[t - 7] + f["sig0"](W[t - 15]) + W[t - 16]) & mask)
        a, b, c, d, e, g, h, k = H
        for t in range(rounds):
            t1 = (k + f["sum1"](e) + ((e & g) ^ (~e & h)) + K[t] + W[t]) & mask
            t2 = (f["sum0"](a) + ((a & b) ^ (a & c) ^ (b & c))) & mask
            a, b, c, d, e, g, h, k = (t1 + t2) & mask, a, b, c, (d + t1) & mask, e, g, h
        H = [(x + y) & mask for x, y in zip(H, [a, b, c, d, e, g, h, k])]
    return b"".join(x.to_bytes(w // 8, "big") for x in H)

# The examples of the NIST Cryptographic Standards and Guidelines (SHA-256 and SHA-512).
NIST_MSG = [b"abc", b"", b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
            b"abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"]
NIST256 = ["ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
           "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
           "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
           "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"]
NIST512 = ["ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
           "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
           "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce"
           "47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e",
           "204a8fc6dda82f0a0ced7beb8e08a41657c16ef468b228a8279be331a703c335"
           "96fd15c13b1b07f9aa1d3bea57789ca031ad85c7a71dd70354ec631238ca3445",
           "8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018"
           "501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909"]


def sha_selftest(ck, n):
    """The Zknh forms against FIPS 180-4: function by function on n random values, and whole
    hashes of the NIST examples (also checked against hashlib when it is there)."""
    f0 = ck.fail
    R = random.Random(180_4)
    xs = [R.getrandbits(32) for _ in range(n)] + list(CORNER)
    for fn in FIPS256:
        bad = [x for x in xs if compute("sha256" + fn, x) != FIPS256[fn](x)]
        ck(not bad, f"sha256{fn} differs from FIPS 180-4 for {len(bad)} values, first {bad[:1]}")
    xs = [R.getrandbits(64) for _ in range(n)] + [(a << 32) | b for a in CORNER[::9] for b in CORNER[::9]]
    for fn in FIPS512:
        bad = [x for x in xs if zknh512(fn, x) != FIPS512[fn](x)]
        ck(not bad, f"sha512 {fn} from the sha512* pairs differs from FIPS 180-4 for {len(bad)} values")
    z256 = {fn: (lambda x, fn=fn: compute("sha256" + fn, x)) for fn in FIPS256}
    z512 = {fn: (lambda x, fn=fn: zknh512(fn, x)) for fn in FIPS512}
    try:
        import hashlib
    except ImportError:
        hashlib = None
    for msg, d256, d512 in zip(NIST_MSG, NIST256, NIST512):
        ck(sha2(msg, False, FIPS256).hex() == d256, f"SHA-256 (FIPS functions) of {msg[:8]!r}")
        ck(sha2(msg, False, z256).hex() == d256, f"SHA-256 (sha256* forms) of {msg[:8]!r}")
        ck(sha2(msg, True, FIPS512).hex() == d512, f"SHA-512 (FIPS functions) of {msg[:8]!r}")
        ck(sha2(msg, True, z512).hex() == d512, f"SHA-512 (sha512* pairs) of {msg[:8]!r}")
        if hashlib:
            ck(hashlib.sha256(msg).hexdigest() == d256 and hashlib.sha512(msg).hexdigest() == d512,
               f"hashlib disagrees with the NIST digest of {msg[:8]!r}")
    print(f"Zknh against FIPS 180-4 ({n} random values per function, NIST examples hashed with the "
          f"sha256* forms and the sha512* pairs{', also hashlib' if hashlib else ''}): {'ok' if ck.fail == f0 else 'FAIL'}")


class Check:
    def __init__(self):
        self.fail = 0; self.n = 0

    def __call__(self, cond, what):
        self.n += 1
        if not cond:
            self.fail += 1
            if self.fail <= 30: print(f"   FAIL: {what}")


def _iss_cross(args):
    """Worker: compare the model with iss.py on one form; returns (form, vectors, mismatches, first)."""
    name, n, seed = args
    sys.path.insert(0, os.path.join(REPO, "test", "trapsweep"))
    import iss
    fd, path = tempfile.mkstemp(suffix=".bin"); os.close(fd)
    try:
        open(path, "wb").write(b"\0" * 4)
        s = iss.ISS(path)
    finally:
        os.unlink(path)
    R = random.Random(seed)
    edge = CORNER
    bad = 0; first = None
    for i in range(n):
        a = R.choice(edge) if i % 4 == 0 else R.getrandbits(32)
        b = R.choice(edge) if i % 4 == 1 else R.getrandbits(32)
        if CLASS[name] == "imm": b &= 31
        if name in INDEX_FORMS and i % 4 == 3: b &= INDEX_FORMS[name]
        if i % 16 == 2: b = 0
        w = encode(name, 10, 11, b if CLASS[name] == "imm" else 12)
        s.ram[0:4] = w.to_bytes(4, "little")
        s.pc = iss.RAM0; s.x[11] = a; s.x[12] = b; s.x[10] = 0xBAD
        e = s.step()
        got = s.x[10] if e is None else ("exception", e)
        exp = compute(name, a, b)
        if got != exp:
            bad += 1
            if first is None: first = f"{name} a={a:#010x} b={b:#010x}: iss {got} model {exp:#010x}"
    return name, n, bad, first


def _py_lines(name):
    return digest_lines(name)


def assemble_forms():
    """{form: word} as the RISC-V assembler encodes 'm a0, a1, a2' / 'm a0, a1, 31' / 'm a0, a1',
    or None without a toolchain. czero.* are not known to binutils 2.39 and are skipped."""
    tc = os.environ.get("RISCV_PREFIX", "/opt/riscv32i/bin/riscv32-unknown-elf-")
    if not shutil.which(tc + "as"):
        return None
    forms = [n for n in NAMES if not n.startswith("czero")]
    ops = {"bin": "a0, a1, a2", "imm": "a0, a1, 31", "una": "a0, a1"}
    src = ".option arch, +zbb, +zbs, +zbkb, +zbkx, +zknh\n" + "".join(f"    {n} {ops[CLASS[n]]}\n" for n in forms)
    d = tempfile.mkdtemp(prefix="ref_as.")
    try:
        open(os.path.join(d, "f.s"), "w").write(src)
        subprocess.run([tc + "as", "-march=rv32i", "-o", os.path.join(d, "f.o"), os.path.join(d, "f.s")], check=True)
        subprocess.run([tc + "objcopy", "-O", "binary", "-j", ".text", os.path.join(d, "f.o"), os.path.join(d, "f.bin")],
                       check=True)
        data = open(os.path.join(d, "f.bin"), "rb").read()
    finally:
        shutil.rmtree(d)
    return dict(zip(forms, struct.unpack(f"<{len(forms)}I", data)))


def build_c(outdir):
    exe = os.path.join(outdir, "ref_exh")
    cc = os.environ.get("CC", "cc")
    subprocess.run([cc, "-O2", "-Wall", "-Wextra", "-o", exe, os.path.join(HERE, "ref_exh.c")], check=True)
    return exe


def _c_eval(exe, name, pairs):
    data = struct.pack(f"<{2 * len(pairs)}I", *[v for p in pairs for v in p])
    r = subprocess.run([exe, "--eval", name], input=data, capture_output=True, check=True)
    return list(struct.unpack(f"<{len(pairs)}I", r.stdout))


def _c_values(args):
    """Worker: value-by-value comparison of the C model with this one on one form."""
    exe, name = args
    cls = CLASS[name]
    if cls == "una":
        rng = SplitMix64(0x5EED0000 + INDEX[name])
        xs = list(CORNER) + list(range(0x10000)) + [0xFFFF0000 | k for k in range(0x10000)] + \
             [rng.next() & M32 for _ in range(1_000_000)]
        pairs = [(x, NOISE) for x in xs]
    else:
        rng = SplitMix64(0x5EED0000 + INDEX[name])
        pairs = [(a, b) for a in CORNER for b in CORNER] if cls == "bin" else \
                [(a, s) for a in CORNER for s in range(32)]
        for _ in range(100_000):
            z = rng.next(); pairs.append((z & M32, (z >> 32) & (31 if cls == "imm" else M32)))
        if name in INDEX_FORMS:
            pairs += [(a, rng.next() & INDEX_FORMS[name]) for a in CORNER for _ in range(256)]
    got = _c_eval(exe, name, pairs)
    bad = 0; first = None
    for (a, b), g in zip(pairs, got):
        e = compute(name, a, b)
        if g != e:
            bad += 1
            if first is None: first = f"{name} a={a:#010x} b={b:#010x}: ref_exh {g:#010x} model {e:#010x}"
    return name, len(pairs), bad, first


def selftest(quick=False, jobs=4):
    ck = Check()
    # 1. protocol constants
    ck(len(CORNER) == 144, f"corner set has {len(CORNER)} values, not 144")
    ck(SplitMix64(0x0123456789ABCDEF).next() == 0x157A3807A48FAA9D, "splitmix64 known answer")
    ck(fnv([]) == 0xCBF29CE484222325 and fnv([0, 1, 2]) == 0xD949AA186C0C4928, "FNV-1a known answers")
    print(f"protocol constants: {'ok' if not ck.fail else 'FAIL'}")
    # 2. encodings
    f0 = ck.fail
    for name, ext, cls, opc, f7, fixed, f3 in FORMS:
        match = (f7 << 25) | ((fixed or 0) << 20) | (f3 << 12) | opc
        mask = 0xFE00707F | (0x01F00000 if fixed is not None else 0)
        ck(MATCH_MASK[name] == (match, mask), f"{name}: MATCH/MASK {MATCH_MASK[name]} vs fields {match:#x}/{mask:#x}")
        ck(classify(encode(name, 10, 11, 12 if cls == "bin" else 31)) == name, f"{name}: encode/classify")
    for name, w in BINUTILS.items():
        ck(encode(name, 10, 11, 31 if CLASS[name] == "imm" else 12) == w, f"{name}: binutils word {w:#010x}")
    for w in NEIGHBOURS:
        ck(classify(w) is None, f"neighbour {w:#010x} classified as {classify(w)}")
    ck(classify(0x6005D513) == "rori", "0x6005D513 is rori a0, a1, 0")
    asm = assemble_forms()
    if asm is None:
        print("   (no RISC-V toolchain: the encodings were not re-assembled)")
    else:
        for name, w in asm.items():
            ck(encode(name, 10, 11, 31 if CLASS[name] == "imm" else 12) == w, f"{name}: assembler gives {w:#010x}")
    print(f"encodings (MATCH/MASK, binutils words{', all forms re-assembled' if asm else ''}, "
          f"{len(NEIGHBOURS)} illegal neighbours): {'ok' if ck.fail == f0 else 'FAIL'}")
    # 3. known answers
    f0 = ck.fail
    for name, a, b, rd in KNOWN:
        got = compute(name, a, b)
        ck(got == rd, f"{name}({a:#x}, {b:#x}) = {got:#x}, expected {rd:#x}")
    ck(set(n for n, *_ in KNOWN) == set(NAMES), "every form has a known answer")
    print(f"known answers ({len(KNOWN)}): {'ok' if ck.fail == f0 else 'FAIL'}")
    # 4. expected decoder-sweep hits
    ck(sweep_counts(verbose=False), "decoder sweep hit counts differ from the expected table")
    print(f"decoder sweep hits (A=30 B=200 D=5 E=348 F=1600, 2183 in all): {'ok' if not ck.fail else 'FAIL'}")
    # 4b. FIPS 180-4 and the NIST examples; the inverse pairs of Zbkb
    sha_selftest(ck, 10_000 if quick else 100_000)
    f0 = ck.fail
    R = random.Random(8)
    for x in list(CORNER) + [R.getrandbits(32) for _ in range(10_000 if quick else 100_000)]:
        ck(compute("unzip", compute("zip", x)) == x and compute("zip", compute("unzip", x)) == x,
           f"zip/unzip are not inverse at {x:#010x}")
        ck(compute("brev8", compute("brev8", x)) == x, f"brev8 is not an involution at {x:#010x}")
        ck(compute("brev8", x) == compute("rev8", int.from_bytes(bytes(int(f"{v:08b}"[::-1], 2) for v in x.to_bytes(4, "big")), "little")),
           f"brev8 differs from bytes reversed bit by bit at {x:#010x}")
    print(f"zip/unzip inverse, brev8 involution: {'ok' if ck.fail == f0 else 'FAIL'}")
    # 5. iss.py: the extended ISS against this model; the golden-CPU configuration rejects the words
    f0 = ck.fail
    sys.path.insert(0, os.path.join(REPO, "test", "trapsweep"))
    import iss
    fd, path = tempfile.mkstemp(suffix=".bin"); os.close(fd)
    open(path, "wb").write(b"\0" * 4)
    base = iss.ISS(path, has_zbb=False, has_zbs=False, has_zicond=False, has_zbkb=False, has_zbkx=False, has_zknh=False)
    zbkb = iss.ISS(path, has_zbb=False, has_zbs=False, has_zicond=False, has_zbkb=True, has_zbkx=False, has_zknh=False)
    full = iss.ISS(path); os.unlink(path)
    def iss_cause(s, w):
        s.ram[0:4] = w.to_bytes(4, "little"); s.pc = iss.RAM0
        return s.step()
    words = [w for ws in sweep_words().values() for w in ws if (w & 0x7F) in (OP, OP_IMM)]
    nnew = 0
    for w in words + NEIGHBOURS:
        new = classify(w) is not None
        nnew += new
        if new:
            ck(iss_cause(base, w) == 2, f"{w:#010x}: legal in the ISS without the extensions")
            ck(iss_cause(full, w) is None, f"{w:#010x}: illegal in the ISS")
        elif w in NEIGHBOURS:
            ck(iss_cause(full, w) == 2, f"neighbour {w:#010x}: not illegal in the ISS")
        else:
            ck(iss_cause(full, w) == iss_cause(base, w), f"{w:#010x}: ISS legality changed")
    print(f"iss.py legality on {len(words) + len(NEIGHBOURS)} OP/OP-IMM words ({nnew} new): {'ok' if ck.fail == f0 else 'FAIL'}")
    # Zbkb alone: its twelve RV32 instructions (seven shared with Zbb, zext.h being pack rd, rs1, x0)
    f0 = ck.fail
    ZBKB = {"rol", "ror", "rori", "andn", "orn", "xnor", "pack", "packh", "brev8", "rev8", "zip", "unzip"}
    for w in words + NEIGHBOURS:
        c = classify(w)
        legal_zbkb = c in ZBKB or c == "zext.h"
        ck((iss_cause(zbkb, w) is None) == (legal_zbkb or (c is None and iss_cause(base, w) is None)),
           f"{w:#010x} ({c}): legality with Zbkb alone")
    print(f"iss.py with Zbkb alone: the {len(ZBKB)} Zbkb instructions and nothing else of the 45 forms: "
          f"{'ok' if ck.fail == f0 else 'FAIL'}")
    for name, a, b, rd in KNOWN:
        w = encode(name, 10, 11, b if CLASS[name] == "imm" else 12)
        full.x[11] = a; full.x[12] = b
        e = iss_cause(full, w)
        ck(e is None and full.x[10] == rd, f"iss.py: {name}({a:#x}, {b:#x}) = {full.x[10]:#x}, expected {rd:#x}")
    n = 10_000 if quick else 100_000
    with ProcessPoolExecutor(max_workers=jobs) as ex:
        res = list(ex.map(_iss_cross, [(m, n, 1000 + i) for i, m in enumerate(NAMES)]))
    bad = sum(r[2] for r in res)
    for r in res:
        if r[3]: print(f"   FAIL: {r[3]}")
    ck.fail += bad > 0; ck.n += 1
    print(f"iss.py vs model: {sum(r[1] for r in res)} vectors, {bad} mismatches")
    # 6. ref_exh.c: identical digest lines for every non-chunk part, values one by one
    tmp = tempfile.mkdtemp(prefix="ref_exh.")
    try:
        exe = build_c(tmp)
        with ProcessPoolExecutor(max_workers=jobs) as ex:
            pyl = [l for ls in ex.map(_py_lines, NAMES) for l in ls]
            vals = list(ex.map(_c_values, [(exe, m) for m in NAMES]))
        cl = subprocess.run([exe, "--no-chunks"], capture_output=True, text=True, check=True).stdout.split("\n")
        cl = [l for l in cl if l]
        ck(pyl == cl, "ref_exh digest lines differ from ref.py's")
        if pyl != cl:
            for a, b in zip(pyl, cl):
                if a != b: print(f"   ref.py : {a}\n   ref_exh: {b}")
        print(f"ref_exh vs model, digest lines of the non-chunk parts: {len(pyl)} lines, "
              f"{'identical' if pyl == cl else 'DIFFERENT'}")
        bad = sum(v[2] for v in vals)
        for v in vals:
            if v[3]: print(f"   FAIL: {v[3]}")
        ck.fail += bad > 0; ck.n += 1
        print(f"ref_exh vs model, value by value: {sum(v[1] for v in vals)} vectors, {bad} mismatches")
        if not quick:
            r = subprocess.run([exe, "--identities"], capture_output=True, text=True)
            ck(r.returncode == 0, "ref_exh --identities failed")
            print(r.stdout.strip().splitlines()[-1] if r.stdout.strip() else "ref_exh --identities: no output")
    finally:
        shutil.rmtree(tmp)
    print(f"REF SELFTEST: {'PASS' if not ck.fail else 'FAIL'} ({ck.n} checks, {ck.fail} failed)")
    return ck.fail == 0


def main(argv):
    jobs = int(argv[argv.index("--jobs") + 1]) if "--jobs" in argv else 4
    if "--selftest" in argv:
        return 0 if selftest(quick="--quick" in argv, jobs=jobs) else 1
    if "--sweep-counts" in argv:
        return 0 if sweep_counts() else 1
    if "--lines" in argv:
        forms = [argv[i + 1] for i, a in enumerate(argv) if a == "--form"] or NAMES
        for m in forms:
            print("\n".join(digest_lines(m)))
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
