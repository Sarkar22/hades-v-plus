/* SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: zbb_diff.c
 *
 * Zbb benchmark (make bench-zbb, see test/bench/README.md): the in-program differential check.
 *
 * Built for -march=rv32i only. Each of the 28 Zbb, Zbs and Zicond instruction forms is issued
 * as an .insn word, czero.eqz and czero.nez through std/include/zicond.h (the assembler then
 * needs no extension, and GCC cannot replace a reference
 * computation by the instruction under test), and its result is compared with a computation
 * in plain RV32I C, written from the ISA text with loops and single-bit steps rather than with
 * the tricks an implementation would use. The operands pass through an empty asm, so GCC
 * cannot fold either side at compile time.
 *
 *   phase A  every pair of a pool of 24 special values, for the 15 register forms; every pool
 *            value for the 8 unary forms; every pool value with every shift amount 0..31 for
 *            the 5 immediate forms
 *   phase B  N_RANDOM pseudo-random pairs (xorshift32 from SEED), every form; the shift
 *            amount of the immediate forms is the pair's index mod 32
 *   phase C  a dependent chain through rol, andn, clz, bset, max and czero.eqz (results
 *            forwarded from Execute to Execute)
 *   phase D  results of rev8 and bset used as load addresses (forwarded into Memory)
 *   phase E  a result of cpop and czero.nez used by a branch
 *   phase F  rd = x0: the result is discarded
 *   phase G  rs1 and rs2 the same register, for every register form
 *
 * Output: CASES, BAD (mismatches of phases A, B and G), EXTRA (a bit per failed phase C-F),
 * CSUM (a checksum of the instruction results), CYCLES, then "ZBB DIFF OK" or
 * "ZBB DIFF FAILED"; up to eight MISMATCH lines name the first mismatches.
 */
#include "peripherals.h"
#include "zicond.h"

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

enum { ANDN, ORN, XNOR, MAX, MAXU, MIN, MINU, ROL, ROR, BCLR, BEXT, BINV, BSET, CZEQZ, CZNEZ, NREG };
enum { CLZ, CTZ, CPOP, SEXTB, SEXTH, ZEXTH, ORCB, REV8, NUN };
enum { RORI, BCLRI, BEXTI, BINVI, BSETI, NIMM };

static const char *const REG_NAME[NREG] = { "andn", "orn", "xnor", "max", "maxu", "min", "minu", "rol",
                                            "ror", "bclr", "bext", "binv", "bset", "czero.eqz", "czero.nez" };
static const char *const UN_NAME[NUN] = { "clz", "ctz", "cpop", "sext.b", "sext.h", "zext.h", "orc.b", "rev8" };
static const char *const IMM_NAME[NIMM] = { "rori", "bclri", "bexti", "binvi", "bseti" };

static uint32_t hw_reg(int op, uint32_t a, uint32_t b) {
    uint32_t r = 0;
    switch (op) {
    case ANDN:  R(7, 0x20, a, b, r); break;
    case ORN:   R(6, 0x20, a, b, r); break;
    case XNOR:  R(4, 0x20, a, b, r); break;
    case MAX:   R(6, 0x05, a, b, r); break;
    case MAXU:  R(7, 0x05, a, b, r); break;
    case MIN:   R(4, 0x05, a, b, r); break;
    case MINU:  R(5, 0x05, a, b, r); break;
    case ROL:   R(1, 0x30, a, b, r); break;
    case ROR:   R(5, 0x30, a, b, r); break;
    case BCLR:  R(1, 0x24, a, b, r); break;
    case BEXT:  R(5, 0x24, a, b, r); break;
    case BINV:  R(1, 0x34, a, b, r); break;
    case BSET:  R(1, 0x14, a, b, r); break;
    case CZEQZ: r = czero_eqz(a, b); break;
    default:    r = czero_nez(a, b); break;
    }
    return r;
}

/* The same, with one register as rs1 and rs2. */
#define RS(F3, F7, a, r) __asm__ (".insn r 0x33, " #F3 ", " #F7 ", %0, %1, %1" : "=r"(r) : "r"(a))

static uint32_t hw_same(int op, uint32_t a) {
    uint32_t r = 0;
    switch (op) {
    case ANDN:  RS(7, 0x20, a, r); break;
    case ORN:   RS(6, 0x20, a, r); break;
    case XNOR:  RS(4, 0x20, a, r); break;
    case MAX:   RS(6, 0x05, a, r); break;
    case MAXU:  RS(7, 0x05, a, r); break;
    case MIN:   RS(4, 0x05, a, r); break;
    case MINU:  RS(5, 0x05, a, r); break;
    case ROL:   RS(1, 0x30, a, r); break;
    case ROR:   RS(5, 0x30, a, r); break;
    case BCLR:  RS(1, 0x24, a, r); break;
    case BEXT:  RS(5, 0x24, a, r); break;
    case BINV:  RS(1, 0x34, a, r); break;
    case BSET:  RS(1, 0x14, a, r); break;
    case CZEQZ: RS(5, 0x07, a, r); break;
    default:    RS(7, 0x07, a, r); break;
    }
    return r;
}

static uint32_t hw_un(int op, uint32_t a) {
    uint32_t r = 0;
    switch (op) {
    case CLZ:   U(1, 0x600, a, r); break;
    case CTZ:   U(1, 0x601, a, r); break;
    case CPOP:  U(1, 0x602, a, r); break;
    case SEXTB: U(1, 0x604, a, r); break;
    case SEXTH: U(1, 0x605, a, r); break;
    case ZEXTH: __asm__ (".insn r 0x33, 4, 0x04, %0, %1, x0" : "=r"(r) : "r"(a)); break;
    case ORCB:  U(5, 0x287, a, r); break;
    default:    U(5, 0x698, a, r); break;
    }
    return r;
}

/* The immediate forms need the shift amount in the instruction word: one case per amount. */
#define S8(M, F3, B, s) M(F3, B, s) M(F3, B, s + 1) M(F3, B, s + 2) M(F3, B, s + 3) \
                        M(F3, B, s + 4) M(F3, B, s + 5) M(F3, B, s + 6) M(F3, B, s + 7)
#define S32(M, F3, B) S8(M, F3, B, 0) S8(M, F3, B, 8) S8(M, F3, B, 16) S8(M, F3, B, 24)
#define IMM_CASE(F3, B, s) case (s): __asm__ (".insn i 0x13, " #F3 ", %0, %1, (" #B " + " #s ")" \
                                              : "=r"(r) : "r"(a)); break;

static uint32_t hw_imm(int op, uint32_t a, uint32_t s) {
    uint32_t r = 0;
    switch (op) {
    case RORI:  switch (s) { S32(IMM_CASE, 5, 0x600) } break;
    case BCLRI: switch (s) { S32(IMM_CASE, 1, 0x480) } break;
    case BEXTI: switch (s) { S32(IMM_CASE, 5, 0x480) } break;
    case BINVI: switch (s) { S32(IMM_CASE, 1, 0x680) } break;
    default:    switch (s) { S32(IMM_CASE, 1, 0x280) } break;
    }
    return r;
}

/* ---- the reference: RV32I C from the ISA text -------------------------------------------- */
static uint32_t bit(uint32_t x, uint32_t i) { return (x >> i) & 1u; }

static uint32_t ref_reg(int op, uint32_t a, uint32_t b) {
    uint32_t s = b & 31u, i, r;
    int32_t sa = (int32_t)a, sb = (int32_t)b;
    switch (op) {
    case ANDN:  return a & ~b;
    case ORN:   return a | ~b;
    case XNOR:  return ~(a ^ b);
    case MAX:   return sa < sb ? b : a;
    case MAXU:  return a < b ? b : a;
    case MIN:   return sa < sb ? a : b;
    case MINU:  return a < b ? a : b;
    case ROL:   /* bit i of the result is bit (i - s) mod 32 of a */
        for (r = 0, i = 0; i < 32; i++) r |= bit(a, (i - s) & 31u) << i;
        return r;
    case ROR:
        for (r = 0, i = 0; i < 32; i++) r |= bit(a, (i + s) & 31u) << i;
        return r;
    case BCLR:  return a & ~(1u << s);
    case BEXT:  return bit(a, s);
    case BINV:  return a ^ (1u << s);
    case BSET:  return a | (1u << s);
    case CZEQZ: return b == 0 ? 0 : a;
    default:    return b != 0 ? 0 : a;
    }
}

static uint32_t ref_un(int op, uint32_t a) {
    uint32_t i, r = 0;
    switch (op) {
    case CLZ:   for (i = 0; i < 32 && !bit(a, 31 - i); i++) ; return i;
    case CTZ:   for (i = 0; i < 32 && !bit(a, i); i++) ; return i;
    case CPOP:  for (i = 0; i < 32; i++) r += bit(a, i); return r;
    case SEXTB: return bit(a, 7) ? (a | 0xFFFFFF00u) : (a & 0xFFu);
    case SEXTH: return bit(a, 15) ? (a | 0xFFFF0000u) : (a & 0xFFFFu);
    case ZEXTH: return a & 0xFFFFu;
    case ORCB:  for (i = 0; i < 32; i += 8) if ((a >> i) & 0xFFu) r |= 0xFFu << i; return r;
    default:    for (i = 0; i < 32; i += 8) r |= ((a >> i) & 0xFFu) << (24 - i); return r;
    }
}

static uint32_t ref_imm(int op, uint32_t a, uint32_t s) {
    static const int base[NIMM] = { ROR, BCLR, BEXT, BINV, BSET };
    return ref_reg(base[op], a, s);
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

static void check_imm(int op, uint32_t a, uint32_t s) {
    uint32_t g, r;
    OPAQUE(a);
    g = hw_imm(op, a, s); r = ref_imm(op, a, s);
    csum = (csum << 5 | csum >> 27) ^ g;
    cases++;
    if (g != r) report(IMM_NAME[op], a, s, r, g);
}

/* 8-aligned, so that bit 2 of &mem[2k] is clear (phase D) */
static uint32_t mem[8] __attribute__((aligned(8)));

static const uint32_t POOL[24] = {
    0x00000000u, 0x00000001u, 0x00000002u, 0x0000001Fu, 0x00000020u, 0x0000007Fu,
    0x00000080u, 0x000000FFu, 0x00007FFFu, 0x00008000u, 0x0000FFFFu, 0x00010000u,
    0x7FFFFFFFu, 0x80000000u, 0x80000001u, 0xFFFFFF7Fu, 0xFFFF7FFFu, 0xFFFFFFFEu,
    0xFFFFFFFFu, 0x55555555u, 0xAAAAAAAAu, 0x00FF00FFu, 0x12345678u, 0xDEADBEEFu
};

int main(void) {
    uint32_t i, j, seed = SEED, c0, c1, a, b, extra = 0, x0_probe;
    int op;

    __asm__ volatile("csrr %0, 0xB00" : "=r"(c0));

    /* ---- phase A: the pool ---- */
#ifndef SKIP_POOL
    for (op = 0; op < NREG; op++)
        for (i = 0; i < 24; i++)
            for (j = 0; j < 24; j++)
                check_reg(op, POOL[i], POOL[j]);
    for (op = 0; op < NUN; op++)
        for (i = 0; i < 24; i++)
            check_un(op, POOL[i]);
    for (op = 0; op < NIMM; op++)
        for (i = 0; i < 24; i++)
            for (j = 0; j < 32; j++)
                check_imm(op, POOL[i], j);
#else
    (void)j;
#endif

    /* ---- phase B: pseudo-random operands (xorshift32: no multiply on rv32i) ---- */
    for (i = 0; i < N_RANDOM; i++) {
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; a = seed;
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; b = seed;
        for (op = 0; op < NREG; op++) check_reg(op, a, b);
        /* czero with a zero condition as well */
        check_reg(CZEQZ, a, 0); check_reg(CZNEZ, a, 0);
        for (op = 0; op < NUN; op++) check_un(op, a);
        for (op = 0; op < NIMM; op++) check_imm(op, a, i & 31u);
    }

    /* ---- phase C: a dependent chain, each result the next instruction's operand ---- */
    {
        uint32_t h = 0x13579BDFu, r = 0x13579BDFu, k, t;
        for (i = 0; i < 16; i++) {
            k = i * 3u + 5u;
            OPAQUE(k);
            R(1, 0x30, h, k, t); h = t;            /* rol  */
            R(7, 0x20, h, k, t); h = t;            /* andn */
            U(1, 0x600, h, t);   h = t + k;        /* clz  */
            R(1, 0x14, h, k, t); h = t;            /* bset */
            R(6, 0x05, h, k, t); h = t;            /* max  */
            h = czero_eqz(h, k);                   /* czero.eqz */
            r = ref_reg(ROL, r, k); r = ref_reg(ANDN, r, k); r = ref_un(CLZ, r) + k;
            r = ref_reg(BSET, r, k); r = ref_reg(MAX, r, k); r = ref_reg(CZEQZ, r, k);
            cases += 6;
        }
        if (h != r) { extra |= 1u; puts_u("CHAIN FAIL ref="); hex8(r); puts_u(" got="); hex8(h); putc_u('\n'); }
        csum = (csum << 5 | csum >> 27) ^ h;
    }

    /* ---- phase D: results used as load addresses ---- */
    for (i = 0; i < 8; i++) mem[i] = 0xC0DE0000u + i;
    for (i = 0; i < 8; i++) {
        uint32_t base = (uint32_t)(uintptr_t)mem, swapped, addr, val, sh = i * 4u;
        /* rev8 of the byte-reversed address gives the address back */
        swapped = ref_un(REV8, base + sh);
        OPAQUE(swapped);
        U(5, 0x698, swapped, addr);
        val = *(volatile uint32_t *)(uintptr_t)addr;
        if (val != 0xC0DE0000u + i) { extra |= 2u; puts_u("ADDR FAIL i="); hex8(i); putc_u('\n'); }
        /* bset of bit 2 on an 8-aligned address: the next word */
        if ((i & 1u) == 0) {
            uint32_t two = 2u, base2 = base + sh;
            OPAQUE(two); OPAQUE(base2);
            R(1, 0x14, base2, two, addr);
            val = *(volatile uint32_t *)(uintptr_t)addr;
            if (val != 0xC0DE0000u + i + 1u) { extra |= 2u; puts_u("BSET ADDR FAIL i="); hex8(i); putc_u('\n'); }
        }
        csum = (csum << 5 | csum >> 27) ^ val;
        cases += 2;
    }

    /* ---- phase E: results that decide a branch ---- */
    for (i = 0; i < 16; i++) {
        uint32_t x = i * 0x01010101u, g, z = i & 1u;
        OPAQUE(x); OPAQUE(z);
        U(1, 0x602, x, g);                         /* cpop */
        if (g != 4u * ref_un(CPOP, i)) { extra |= 4u; puts_u("BRANCH FAIL cpop i="); hex8(i); putc_u('\n'); }
        g = czero_nez(x, z);
        if ((g == 0) != (z != 0 || x == 0)) { extra |= 4u; puts_u("BRANCH FAIL czero i="); hex8(i); putc_u('\n'); }
        cases += 2;
    }

    /* ---- phase F: rd = x0 discards the result ---- */
    a = 0xFFFFFFFFu; b = 0x00000003u;
    OPAQUE(a); OPAQUE(b);
    __asm__ volatile(".insn r 0x33, 6, 0x05, zero, %1, %2\n\t"   /* max x0, a, b */
                     ".insn i 0x13, 1, zero, %1, 0x602\n\t"      /* cpop x0, a   */
                     "add %0, zero, zero"
                     : "=r"(x0_probe) : "r"(a), "r"(b));
    if (x0_probe != 0) { extra |= 8u; puts_u("X0 FAIL "); hex8(x0_probe); putc_u('\n'); }
    cases += 2;

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
    puts_u((bad == 0 && extra == 0) ? "ZBB DIFF OK\n" : "ZBB DIFF FAILED\n");
    return 0;
}
