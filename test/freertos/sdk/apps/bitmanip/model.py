# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------------------------------
# model.py -- the expected values of the app 'bitmanip' (bitmanip.c), computed independently:
# the same steps with Python's unbounded integers and the 32-bit wrap-around, and the result of
# every Zbb, Zbs and Zicond instruction that the app's comments name taken from the reference
# model of the ISA text, test/ext/ref.py (which does not know the RTL or the C code).
#
#   python3 test/freertos/sdk/apps/bitmanip/model.py
#       prints the constants as bitmanip.c defines them
# ---------------------------------------------------------------------------------------------
import os
import sys

sys.dont_write_bytecode = True     # nothing written into test/ext/
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..', '..', 'ext'))
import ref  # noqa: E402  (test/ext/ref.py)

MASK = 0xFFFFFFFF
N = 64
BITS = 4096


def op(name, a, b=0):
    """rd of the instruction 'name' with rs1 = a and rs2 = b (or the shift amount)."""
    return ref.compute(name, a & MASK, b & MASK) & MASK


def signed(x):
    x &= MASK
    return x - (1 << 32) if x & 0x80000000 else x


def data():
    """d[0..63]: xorshift32 (13, 17, 5) from 0x2545F491."""
    x, out = 0x2545F491, []
    for _ in range(N):
        x ^= (x << 13) & MASK
        x ^= x >> 17
        x ^= (x << 5) & MASK
        out.append(x)
    return out


def section_zbb(d):
    popcount = sum(op('cpop', w) for w in d) & MASK
    log2 = sum(31 - op('clz', w | 1) for w in d) & MASK
    ctz = sum(op('ctz', w | 0x80000000) for w in d) & MASK
    clamp = 0
    for a, b in zip(d, d[1:]):
        x = op('max', a, 0xFF000000)          # -0x01000000
        x = op('min', x, 0x00FFFFFF)
        clamp = (clamp + x) & MASK
        clamp ^= op('minu', a, b)
        clamp = (clamp + op('maxu', a, b)) & MASK
    extend = 0
    for w in d:
        extend += op('sext.b', w >> 8) + op('sext.h', w >> 12) + op('zext.h', w >> 3)
    extend &= MASK
    masks = 0
    for a, b in zip(d, d[1:]):
        masks = (masks + op('andn', a, b)) & MASK
        masks ^= op('orn', a, b)
        masks ^= op('xnor', a, b >> 1)
    h = 0x811C9DC5
    for w in d:
        h ^= w
        h = (op('rori', h, 5) + 0x9E3779B9) & MASK
        h = op('ror', h, w & 31)
    return [popcount, log2, ctz, clamp, extend, masks, h]


HEADER = bytes([0x48, 0x41, 0x44, 0x45, 0x00, 0x00, 0x01, 0x00, 0xDE, 0xAD, 0xBE, 0xEF, 0x80, 0x00, 0x00, 0x01,
                0x12, 0x34, 0x56, 0x78, 0xFF, 0xFF, 0xFF, 0xFE, 0x00, 0x01, 0x00, 0x01, 0x7F, 0x80, 0x01, 0xFE])
STRINGS = ["", "a", "HaDes-V+", "bit manipulation", "rv32im_zba_zbb_zbs", "Zicond", "0123456789abcdef0123456",
           "FreeRTOS app loader, ~31 chars"]


def section_bytes():
    acc = lengths = 0
    for i in range(8):
        word = int.from_bytes(HEADER[4 * i:4 * i + 4], 'little')        # lw on a little-endian CPU
        acc = (((acc << 3) | (acc >> 29)) & MASK) ^ op('rev8', word)
        text = STRINGS[i].encode().ljust(32, b'\0')
        n = 0
        while True:                                                      # one orc.b per word
            orc = op('orc.b', int.from_bytes(text[n:n + 4], 'little'))
            if orc != MASK:
                break
            n += 4
        lengths += n + (op('ctz', ~orc & MASK) >> 3)
    return [acc, lengths & MASK]


def section_zbs(d):
    bitmap = [0] * (BITS // 32)

    def apply(name, n):
        bitmap[n >> 5] = op(name, bitmap[n >> 5], n)

    for n in range(BITS):
        apply('bset', n)
    apply('bclr', 0)
    apply('bclr', 1)
    p = 2
    while p * p < BITS:
        if op('bext', bitmap[p >> 5], p):
            for n in range(p * p, BITS, p):
                apply('bclr', n)
        p += 1
    primes = [n for n in range(BITS) if op('bext', bitmap[n >> 5], n)]
    for n in range(0, BITS, 3):
        apply('binv', n)
    toggled = sum(op('bext', bitmap[n >> 5], n) for n in range(BITS))
    flags = 0
    for w in d:
        f = op('binvi', op('bseti', w, 20), 17)
        f = op('bclri', f, 30)
        flags = (flags + f + op('bexti', w, 25)) & MASK
    return [len(primes), sum(primes) & MASK, toggled, flags]


def select(cond, if_nonzero, if_zero):
    """zicond_select(): czero.eqz, czero.nez, or"""
    return op('czero.eqz', if_nonzero, cond) | op('czero.nez', if_zero, cond)


def section_zicond(d):
    sel = clamp = add_if = 0
    for w in d:
        x = signed(w) >> 20
        sel = (sel + select(w & 1, w, ~w & MASK)) & MASK
        c = x & MASK
        c = select(int(x < -1000), -1000 & MASK, c)
        c = select(int(x > 1000), 1000, c)
        clamp = (clamp + c) & MASK
        add_if = (add_if + op('czero.eqz', w, w >> 31)) & MASK            # zicond_add_if()
    return [sel, clamp, add_if]


def main():
    d = data()
    names = ['POPCOUNT', 'LOG2', 'CTZ', 'CLAMP', 'EXTEND', 'MASKS', 'HASH', 'REV8', 'LENGTHS', 'PRIMES',
             'PRIMESUM', 'TOGGLED', 'FLAGS', 'SELECT', 'CZCLAMP', 'ADDIF']
    values = section_zbb(d) + section_bytes() + section_zbs(d) + section_zicond(d)
    for name, v in zip(names, values):
        print(f'#define BM_{name:<12}0x{v:08x}u')


if __name__ == '__main__':
    main()
