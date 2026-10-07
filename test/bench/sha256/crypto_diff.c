/* SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: crypto_diff.c
 *
 * SHA-256 benchmark (make bench-sha256, see test/bench/README.md): the in-program
 * differential check of the Zbkb, Zbkx and Zknh instructions.
 *
 * Built for -march=rv32i only. Each of the 17 instruction forms (pack, packh, brev8, zip,
 * unzip, xperm4, xperm8, the four sha256 and the six sha512 forms) is issued as an .insn
 * word, so the assembler needs no extension and GCC cannot replace a reference computation
 * by the instruction under test, and its result is compared with a computation in plain
 * RV32I C, written from the instruction definitions with loops and single-bit steps (the
 * rotations of the sha256 forms as bit permutations, the sha512 forms term by term). The
 * operands pass through an empty asm, so GCC cannot fold either side at compile time.
 *
 *   phase A  every pair of a pool of 24 special values, for the 10 register forms; every
 *            pool value for the 7 one-operand forms; xperm4 and xperm8 with every pool value
 *            as the table and index words made of every index value (in range and not)
 *   phase B  N_RANDOM pseudo-random pairs (xorshift32 from SEED), every form; xperm8 also
 *            with the indices masked to 0..3 and 128..131
 *   phase C  a dependent chain through pack, sha256sum0, xperm8, sha512sig1l, zip, brev8
 *            and unzip (results forwarded from Execute to Execute)
 *   phase D  results of pack and xperm8 used as load addresses (forwarded into Memory)
 *   phase E  a result of sha256sig0 and of packh used by a branch
 *   phase F  rd = x0: the result is discarded
 *   phase G  rs1 and rs2 the same register, for every register form
 *
 * Output: CASES, BAD (mismatches of phases A, B and G), EXTRA (a bit per failed phase C-F),
 * CSUM (a checksum of the instruction results), CYCLES, then "CRYPTO DIFF OK" or
 * "CRYPTO DIFF FAILED"; up to eight MISMATCH lines name the first mismatches.
 */
#include "peripherals.h"

#ifndef N_RANDOM
#define N_RANDOM 96
#endif
#ifndef SEED
#define SEED 0xACE1u
#endif

static void putc_u(char c) {
    while (!(*UART_TX_STATUS_ADDRESS & (1 << UART_TX_STATUS_IDX_EMPTY)));
    *UART_BUFFER_ADDRESS = (uint8_t)c;
}
static void puts_u(const char *s) { while (*s) putc_u(*s++); }
static void hex8(uint32_t v) {
    int i;
    for (i = 28; i >= 0; i -= 4) {
        uint8_t n = (v >> i) & 0xF;
        putc_u(n < 10 ? (char)('0' + n) : (char)('a' + n - 10));
    }
}

#define OPAQUE(x) __asm__ ("" : "+r"(x))

/* ---- the instructions, as .insn words ---------------------------------------------------- */
#define R(F3, F7, a, b, r) __asm__ (".insn r 0x33, " #F3 ", " #F7 ", %0, %1, %2" : "=r"(r) : "r"(a), "r"(b))
#define U(F3, IMM, a, r)   __asm__ (".insn i 0x13, " #F3 ", %0, %1, " #IMM : "=r"(r) : "r"(a))
#define RS(F3, F7, a, r)   __asm__ (".insn r 0x33, " #F3 ", " #F7 ", %0, %1, %1" : "=r"(r) : "r"(a))

enum { PACK, PACKH, XPERM4, XPERM8, SIG0H, SIG0L, SIG1H, SIG1L, SUM0R, SUM1R, NREG };
enum { BREV8, ZIP, UNZIP, SIG0, SIG1, SUM0, SUM1, NUN };

static const char *const REG_NAME[NREG] = { "pack", "packh", "xperm4", "xperm8", "sha512sig0h",
                                            "sha512sig0l", "sha512sig1h", "sha512sig1l",
                                            "sha512sum0r", "sha512sum1r" };
static const char *const UN_NAME[NUN] = { "brev8", "zip", "unzip", "sha256sig0", "sha256sig1",
                                          "sha256sum0", "sha256sum1" };

static uint32_t hw_reg(int op, uint32_t a, uint32_t b) {
    uint32_t r = 0;
    switch (op) {
    case PACK:   R(4, 0x04, a, b, r); break;
    case PACKH:  R(7, 0x04, a, b, r); break;
    case XPERM4: R(2, 0x14, a, b, r); break;
    case XPERM8: R(4, 0x14, a, b, r); break;
    case SIG0H:  R(0, 0x2E, a, b, r); break;
    case SIG0L:  R(0, 0x2A, a, b, r); break;
    case SIG1H:  R(0, 0x2F, a, b, r); break;
    case SIG1L:  R(0, 0x2B, a, b, r); break;
    case SUM0R:  R(0, 0x28, a, b, r); break;
    default:     R(0, 0x29, a, b, r); break;
    }
    return r;
}

static uint32_t hw_same(int op, uint32_t a) {
    uint32_t r = 0;
    switch (op) {
    case PACK:   RS(4, 0x04, a, r); break;
    case PACKH:  RS(7, 0x04, a, r); break;
    case XPERM4: RS(2, 0x14, a, r); break;
    case XPERM8: RS(4, 0x14, a, r); break;
    case SIG0H:  RS(0, 0x2E, a, r); break;
    case SIG0L:  RS(0, 0x2A, a, r); break;
    case SIG1H:  RS(0, 0x2F, a, r); break;
    case SIG1L:  RS(0, 0x2B, a, r); break;
    case SUM0R:  RS(0, 0x28, a, r); break;
    default:     RS(0, 0x29, a, r); break;
    }
    return r;
}

static uint32_t hw_un(int op, uint32_t a) {
    uint32_t r = 0;
    switch (op) {
    case BREV8: U(5, 0x687, a, r); break;
    case ZIP:   U(1, 0x08F, a, r); break;
    case UNZIP: U(5, 0x08F, a, r); break;
    case SIG0:  U(1, 0x102, a, r); break;
    case SIG1:  U(1, 0x103, a, r); break;
    case SUM0:  U(1, 0x100, a, r); break;
    default:    U(1, 0x101, a, r); break;
    }
    return r;
}

/* ---- the reference: RV32I C from the instruction definitions ----------------------------- */
static uint32_t bit(uint32_t x, uint32_t i) { return (x >> i) & 1u; }

/* rotate right by n, one bit at a time: bit i of the result is bit (i + n) mod 32 of x */
static uint32_t rot(uint32_t x, uint32_t n) {
    uint32_t r = 0, i;
    for (i = 0; i < 32; i++) r |= bit(x, (i + n) & 31u) << i;
    return r;
}

/* x shifted right (n > 0) or left (n < 0) with zeros, one bit at a time */
static uint32_t sh(uint32_t x, int n) {
    uint32_t r = 0;
    int i;
    for (i = 0; i < 32; i++) {
        int j = i + n;
        if (j >= 0 && j < 32) r |= bit(x, (uint32_t)j) << i;
    }
    return r;
}

static uint32_t ref_reg(int op, uint32_t a, uint32_t b) {
    uint32_t r = 0, i, idx;
    switch (op) {
    case PACK:   /* rs1's low half low, rs2's low half high */
        for (i = 0; i < 16; i++) r |= bit(a, i) << i | bit(b, i) << (i + 16);
        return r;
    case PACKH:
        for (i = 0; i < 8; i++) r |= bit(a, i) << i | bit(b, i) << (i + 8);
        return r;
    case XPERM4: /* rs1 the table of eight nibbles, rs2 the indices; out of range gives 0 */
        for (i = 0; i < 8; i++) {
            idx = (b >> (4 * i)) & 0xFu;
            if (idx < 8) r |= ((a >> (4 * idx)) & 0xFu) << (4 * i);
        }
        return r;
    case XPERM8:
        for (i = 0; i < 4; i++) {
            idx = (b >> (8 * i)) & 0xFFu;
            if (idx < 4) r |= ((a >> (8 * idx)) & 0xFFu) << (8 * i);
        }
        return r;
    case SIG0H:  return sh(a, 1) ^ sh(a, 7) ^ sh(a, 8) ^ sh(b, -31) ^ sh(b, -24);
    case SIG0L:  return sh(a, 1) ^ sh(a, 7) ^ sh(a, 8) ^ sh(b, -31) ^ sh(b, -25) ^ sh(b, -24);
    case SIG1H:  return sh(a, -3) ^ sh(a, 6) ^ sh(a, 19) ^ sh(b, 29) ^ sh(b, -13);
    case SIG1L:  return sh(a, -3) ^ sh(a, 6) ^ sh(a, 19) ^ sh(b, 29) ^ sh(b, -26) ^ sh(b, -13);
    case SUM0R:  return sh(a, -25) ^ sh(a, -30) ^ sh(a, 28) ^ sh(b, 7) ^ sh(b, 2) ^ sh(b, -4);
    default:     return sh(a, -23) ^ sh(a, 14) ^ sh(a, 18) ^ sh(b, 9) ^ sh(b, -18) ^ sh(b, -14);
    }
}

static uint32_t ref_un(int op, uint32_t a) {
    uint32_t r = 0, i, k;
    switch (op) {
    case BREV8:  /* the bits of each byte in reverse order */
        for (k = 0; k < 32; k += 8)
            for (i = 0; i < 8; i++) r |= bit(a, k + 7 - i) << (k + i);
        return r;
    case ZIP:    /* low half to the even bits, high half to the odd bits */
        for (i = 0; i < 16; i++) r |= bit(a, i) << (2 * i) | bit(a, i + 16) << (2 * i + 1);
        return r;
    case UNZIP:
        for (i = 0; i < 16; i++) r |= bit(a, 2 * i) << i | bit(a, 2 * i + 1) << (i + 16);
        return r;
    case SIG0:   return rot(a, 7) ^ rot(a, 18) ^ sh(a, 3);
    case SIG1:   return rot(a, 17) ^ rot(a, 19) ^ sh(a, 10);
    case SUM0:   return rot(a, 2) ^ rot(a, 13) ^ rot(a, 22);
    default:     return rot(a, 6) ^ rot(a, 11) ^ rot(a, 25);
    }
}

/* ---- bookkeeping ------------------------------------------------------------------------- */
static uint32_t cases, bad, csum = 1, shown;

static __attribute__((noinline)) void report(const char *name, uint32_t a, uint32_t b, uint32_t ref,
                                             uint32_t got) {
    bad++;
    if (shown >= 8) return;
    shown++;
    puts_u("MISMATCH "); puts_u(name);
    puts_u(" a=");   hex8(a);
    puts_u(" b=");   hex8(b);
    puts_u(" ref="); hex8(ref);
    puts_u(" got="); hex8(got);
    putc_u('\n');
}

static void check_reg(int op, uint32_t a, uint32_t b) {
    uint32_t g, r;
    OPAQUE(a); OPAQUE(b);
    g = hw_reg(op, a, b); r = ref_reg(op, a, b);
    csum = (csum << 5 | csum >> 27) ^ g;
    cases++;
    if (g != r) report(REG_NAME[op], a, b, r, g);
}

static void check_un(int op, uint32_t a) {
    uint32_t g, r;
    OPAQUE(a);
    g = hw_un(op, a); r = ref_un(op, a);
    csum = (csum << 5 | csum >> 27) ^ g;
    cases++;
    if (g != r) report(UN_NAME[op], a, 0, r, g);
}

/* the words that phase D loads */
static uint32_t mem[8];

static const uint32_t POOL[24] = {
    0x00000000u, 0x00000001u, 0x00000002u, 0x0000001Fu, 0x00000020u, 0x0000007Fu,
    0x00000080u, 0x000000FFu, 0x00007FFFu, 0x00008000u, 0x0000FFFFu, 0x00010000u,
    0x7FFFFFFFu, 0x80000000u, 0x80000001u, 0xFFFFFF7Fu, 0xFFFF7FFFu, 0xFFFFFFFEu,
    0xFFFFFFFFu, 0x55555555u, 0xAAAAAAAAu, 0x00FF00FFu, 0x12345678u, 0xDEADBEEFu
};

/* index words for xperm4 (nibbles) and xperm8 (bytes): in range, out of range and mixed */
static const uint32_t IDX4[6] = { 0x01234567u, 0x76543210u, 0x89ABCDEFu, 0xFEDCBA98u, 0x0F1E2D3Cu, 0x80808080u };
static const uint32_t IDX8[6] = { 0x00010203u, 0x03020100u, 0x04050607u, 0xFFFFFFFFu, 0x04FF0100u, 0x80038102u };

int main(void) {
    uint32_t i, j, seed = SEED, c0, c1, a, b, extra = 0, x0_probe;
    int op;

    __asm__ volatile("csrr %0, 0xB00" : "=r"(c0));

    /* ---- phase A: the pool, and the index words ---- */
#ifndef SKIP_POOL
    for (op = 0; op < NREG; op++)
        for (i = 0; i < 24; i++)
            for (j = 0; j < 24; j++)
                check_reg(op, POOL[i], POOL[j]);
    for (op = 0; op < NUN; op++)
        for (i = 0; i < 24; i++)
            check_un(op, POOL[i]);
    for (i = 0; i < 24; i++)
        for (j = 0; j < 6; j++) {
            check_reg(XPERM4, POOL[i], IDX4[j]);
            check_reg(XPERM8, POOL[i], IDX8[j]);
        }
    /* every index value in every element: xperm4 0..15 in each nibble, xperm8 0..255 in byte 0..3 */
    for (i = 0; i < 16; i++)
        check_reg(XPERM4, 0x76543210u, i * 0x11111111u);
    for (i = 0; i < 256; i++)
        check_reg(XPERM8, 0x44332211u, i << (8 * (i & 3u)));
#else
    (void)j;
#endif

    /* ---- phase B: pseudo-random operands (xorshift32: no multiply on rv32i) ---- */
    for (i = 0; i < N_RANDOM; i++) {
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; a = seed;
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; b = seed;
        for (op = 0; op < NREG; op++) check_reg(op, a, b);
        for (op = 0; op < NUN; op++) check_un(op, a);
        /* in-range xperm8 indices are rare in random words */
        check_reg(XPERM8, a, b & 0x03030303u);
        check_reg(XPERM8, a, (b & 0x83838383u));
        check_reg(XPERM4, a, b & 0x77777777u);
    }

    /* ---- phase C: a dependent chain, each result the next instruction's operand ---- */
    {
        uint32_t h = 0x13579BDFu, r = 0x13579BDFu, k, t;
        for (i = 0; i < 16; i++) {
            k = i * 0x9E3779B9u + 5u;
            OPAQUE(k);
            R(4, 0x04, h, k, t); h = t;             /* pack        */
            U(1, 0x100, h, t);   h = t;             /* sha256sum0  */
            R(4, 0x14, k, h, t); h = t ^ k;         /* xperm8      */
            R(0, 0x2B, h, k, t); h = t;             /* sha512sig1l */
            U(1, 0x08F, h, t);   h = t;             /* zip         */
            U(5, 0x687, h, t);   h = t;             /* brev8       */
            U(5, 0x08F, h, t);   h = t;             /* unzip       */
            r = ref_reg(PACK, r, k); r = ref_un(SUM0, r); r = ref_reg(XPERM8, k, r) ^ k;
            r = ref_reg(SIG1L, r, k); r = ref_un(ZIP, r); r = ref_un(BREV8, r); r = ref_un(UNZIP, r);
            cases += 7;
        }
        if (h != r) { extra |= 1u; puts_u("CHAIN FAIL ref="); hex8(r); puts_u(" got="); hex8(h); putc_u('\n'); }
        csum = (csum << 5 | csum >> 27) ^ h;
    }

    /* ---- phase D: results used as load addresses ---- */
    for (i = 0; i < 8; i++) mem[i] = 0xC0DE0000u + i;
    for (i = 0; i < 8; i++) {
        uint32_t base = (uint32_t)(uintptr_t)&mem[i], lo, hi, addr, val, tbl, ix;
        /* pack of the address's two halves gives the address back */
        lo = base & 0xFFFFu; hi = base >> 16;
        OPAQUE(lo); OPAQUE(hi);
        R(4, 0x04, lo, hi, addr);
        val = *(volatile uint32_t *)(uintptr_t)addr;
        if (val != 0xC0DE0000u + i) { extra |= 2u; puts_u("PACK ADDR FAIL i="); hex8(i); putc_u('\n'); }
        /* xperm8 with the identity indices gives the table back */
        tbl = base; ix = 0x03020100u;
        OPAQUE(tbl); OPAQUE(ix);
        R(4, 0x14, tbl, ix, addr);
        val ^= *(volatile uint32_t *)(uintptr_t)addr;
        if (val != 0) { extra |= 2u; puts_u("XPERM8 ADDR FAIL i="); hex8(i); putc_u('\n'); }
        csum = (csum << 5 | csum >> 27) ^ addr;
        cases += 2;
    }

    /* ---- phase E: results that decide a branch ---- */
    for (i = 0; i < 16; i++) {
        uint32_t x = 1u << i, g, z = i & 3u;
        OPAQUE(x); OPAQUE(z);
        U(1, 0x102, x, g);                          /* sha256sig0 of a single bit is not zero */
        if (g == 0 || g != ref_un(SIG0, x)) { extra |= 4u; puts_u("BRANCH FAIL sig0 i="); hex8(i); putc_u('\n'); }
        R(7, 0x04, z, z, g);                        /* packh z, z: zero only for z = 0 */
        if ((g == 0) != (z == 0)) { extra |= 4u; puts_u("BRANCH FAIL packh i="); hex8(i); putc_u('\n'); }
        cases += 2;
    }

    /* ---- phase F: rd = x0 discards the result ---- */
    a = 0xFFFFFFFFu; b = 0x00000003u;
    OPAQUE(a); OPAQUE(b);
    __asm__ volatile(".insn r 0x33, 0, 0x28, zero, %1, %2\n\t"  /* sha512sum0r x0, a, b */
                     ".insn i 0x13, 1, zero, %1, 0x103\n\t"     /* sha256sig1  x0, a    */
                     ".insn r 0x33, 4, 0x04, zero, %1, %2\n\t"  /* pack        x0, a, b */
                     "add %0, zero, zero"
                     : "=r"(x0_probe) : "r"(a), "r"(b));
    if (x0_probe != 0) { extra |= 8u; puts_u("X0 FAIL "); hex8(x0_probe); putc_u('\n'); }
    cases += 3;

    /* ---- phase G: the same register as rs1 and rs2 ---- */
    for (i = 0; i < 24; i += 5) {
        uint32_t x = POOL[i], g;
        OPAQUE(x);
        for (op = 0; op < NREG; op++) {
            g = hw_same(op, x);
            cases++;
            if (g != ref_reg(op, x, x)) report(REG_NAME[op], x, x, ref_reg(op, x, x), g);
        }
    }

    __asm__ volatile("csrr %0, 0xB00" : "=r"(c1));

    puts_u("CASES ");  hex8(cases);   putc_u('\n');
    puts_u("BAD ");    hex8(bad);     putc_u('\n');
    puts_u("EXTRA ");  hex8(extra);   putc_u('\n');
    puts_u("CSUM ");   hex8(csum);    putc_u('\n');
    puts_u("CYCLES "); hex8(c1 - c0); putc_u('\n');
    puts_u((bad == 0 && extra == 0) ? "CRYPTO DIFF OK\n" : "CRYPTO DIFF FAILED\n");
    return 0;
}
