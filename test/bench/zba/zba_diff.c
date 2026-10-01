/* SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: zba_diff.c
 *
 * Zba benchmark (make bench-zba, see test/bench/README.md): the in-program differential check.
 * Recovered from the development log of 2026-08-18; everything after this
 * header is the program exactly as it was first measured.
 */
/* zba_diff.c - in-program differential test of SH1ADD/SH2ADD/SH3ADD.
 *
 * Compiled with -march=rv32i ONLY, so:
 *   - the C reference  (a << N) + b  compiles to slli + add (proven baseline ops)
 *   - the Zba instructions are injected with .insn r, which emits the exact words
 *     0x20c5a533 / 0x20c5c533 / 0x20c5e533 without zba in -march.
 * Both operands pass through an empty asm barrier, so GCC cannot constant-fold
 * the reference: both paths really execute on the core.
 *
 * PHASE_A_N / N_RANDOM are tuned to stay inside sim/top.sv's 100000-cycle timeout.
 */
#include "peripherals.h"

#ifndef N_RANDOM
#define N_RANDOM 128
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

#define HW(N3, a, b, r) __asm__ (".insn r 0x33, " #N3 ", 0x10, %0, %1, %2" \
                                 : "=r"(r) : "r"(a), "r"(b))

static uint32_t shown = 0;

static __attribute__((noinline)) void report(uint32_t n, uint32_t a, uint32_t b,
                                             uint32_t ref, uint32_t got) {
    if (shown >= 8) return;
    shown++;
    puts_u("MISMATCH n="); putc_u((char)('0' + n));
    puts_u(" a=");   hex8(a);
    puts_u(" b=");   hex8(b);
    puts_u(" ref="); hex8(ref);
    puts_u(" got="); hex8(got);
    putc_u('\n');
}

/* one operand pair, all three ops, inlined so the loop stays cheap */
#define PAIR(a, b)                                                   \
    do {                                                             \
        uint32_t _a = (a), _b = (b), _r, _g;                         \
        OPAQUE(_a); OPAQUE(_b);                                      \
        _r = (_a << 1) + _b; HW(0x2, _a, _b, _g);                    \
        csum = csum * 31u + _g;                                      \
        if (_r != _g) { bad++; report(1, _a, _b, _r, _g); }          \
        _r = (_a << 2) + _b; HW(0x4, _a, _b, _g);                    \
        csum = csum * 31u + _g;                                      \
        if (_r != _g) { bad++; report(2, _a, _b, _r, _g); }          \
        _r = (_a << 3) + _b; HW(0x6, _a, _b, _g);                    \
        csum = csum * 31u + _g;                                      \
        if (_r != _g) { bad++; report(3, _a, _b, _r, _g); }          \
        cases += 3;                                                  \
    } while (0)

static const uint32_t POOL[32] = {
    0x00000000u, 0x00000001u, 0x00000002u, 0x00000003u,
    0x00000004u, 0x00000007u, 0x0000000Fu, 0x00000010u,
    0x00008000u, 0x0000FFFFu, 0x00010000u, 0x10000000u,
    0x20000000u, 0x40000000u, 0x7FFFFFFEu, 0x7FFFFFFFu,
    0x80000000u, 0x80000001u, 0x9FFFFFFFu, 0xAAAAAAAAu,
    0x55555555u, 0xC0000000u, 0xE0000000u, 0xFFFF0000u,
    0xFFFFFF80u, 0xFFFFFFFDu, 0xFFFFFFFEu, 0xFFFFFFFFu,
    0xDEADBEEFu, 0xCAFEBABEu, 0x12345678u, 0x87654321u
};

int main(void) {
    uint32_t i, j, seed = SEED, c0, c1;
    uint32_t cases = 0, bad = 0, csum = 1, extra_fail = 0;
    uint32_t chain_hw, chain_ref, x0_probe = 0xDEADu, a, b;
    uint32_t mem[16];

    __asm__ volatile("csrr %0, 0xB00" : "=r"(c0));

    /* ---- phase A: full 32x32 cross product of special values, all 3 ops ---- */
#ifndef SKIP_POOL
    for (i = 0; i < 32; i++)
        for (j = 0; j < 32; j++)
            PAIR(POOL[i], POOL[j]);
#else
    (void)j;
#endif

    /* ---- phase B: pseudo-random operands ---- */
    /* xorshift32: no multiply (rv32i has no M extension, a software __mulsi3
       call per operand would dominate the loop and blow the cycle budget) */
    for (i = 0; i < N_RANDOM; i++) {
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; a = seed;
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; b = seed;
        PAIR(a, b);
    }

    /* ---- phase C: dependent chain (back-to-back EX->EX forwarding) ---- */
    chain_hw = 1; chain_ref = 1;
    for (i = 0; i < 32; i++) {
        uint32_t k = i * 7u + 1u, t = chain_ref, g;
        OPAQUE(t);
        HW(0x2, chain_hw, k, g); chain_hw = g;
        HW(0x4, chain_hw, k, g); chain_hw = g;
        HW(0x6, chain_hw, k, g); chain_hw = g;
        chain_ref = (t << 1) + k;         OPAQUE(chain_ref);
        chain_ref = (chain_ref << 2) + k; OPAQUE(chain_ref);
        chain_ref = (chain_ref << 3) + k;
        cases += 3;
    }
    if (chain_hw != chain_ref) {
        extra_fail |= 1u;
        puts_u("CHAIN FAIL ref="); hex8(chain_ref); puts_u(" got="); hex8(chain_hw); putc_u('\n');
    }
    csum = csum * 31u + chain_hw;

    /* ---- phase D: Zba result used as a load address (EX->MEM forwarding) ---- */
    for (i = 0; i < 16; i++) mem[i] = 0xA5A50000u + i;
    for (i = 0; i < 16; i++) {
        uint32_t base = (uint32_t)(uintptr_t)mem, idx = i, addr, val;
        OPAQUE(base); OPAQUE(idx);
        HW(0x4, idx, base, addr);                 /* addr = &mem[i] */
        val = *(volatile uint32_t *)(uintptr_t)addr;
        if (val != 0xA5A50000u + i) {
            extra_fail |= 2u;
            puts_u("ADDR FAIL i="); hex8(i); puts_u(" val="); hex8(val); putc_u('\n');
        }
        csum = csum * 31u + val;
        cases++;
    }

    /* ---- phase E: Zba result feeding a branch compare ---- */
    for (i = 0; i < 16; i++) {
        uint32_t x = i, y = 3u, g;
        OPAQUE(x); OPAQUE(y);
        HW(0x6, x, y, g);
        if (g != (i << 3) + 3u) { extra_fail |= 4u; puts_u("BRANCH FAIL i="); hex8(i); putc_u('\n'); }
        cases++;
    }

    /* ---- phase G: rs1 == rs2 (same source register twice) ---- */
    for (i = 0; i < 32; i += 3) {
        uint32_t x = POOL[i], g;
        OPAQUE(x);
        HW(0x2, x, x, g); if (g != (x << 1) + x) { extra_fail |= 16u; report(1, x, x, (x << 1) + x, g); }
        HW(0x4, x, x, g); if (g != (x << 2) + x) { extra_fail |= 16u; report(2, x, x, (x << 2) + x, g); }
        HW(0x6, x, x, g); if (g != (x << 3) + x) { extra_fail |= 16u; report(3, x, x, (x << 3) + x, g); }
        cases += 3;
    }

    /* ---- phase F: rd = x0 must be discarded ---- */
    a = 0x11111111u; b = 0x22222222u;
    OPAQUE(a); OPAQUE(b);
    __asm__ volatile(".insn r 0x33, 0x2, 0x10, zero, %1, %2\n\t"
                     "add %0, zero, zero"
                     : "=r"(x0_probe) : "r"(a), "r"(b));
    if (x0_probe != 0) { extra_fail |= 8u; puts_u("X0 FAIL "); hex8(x0_probe); putc_u('\n'); }
    cases++;

    __asm__ volatile("csrr %0, 0xB00" : "=r"(c1));

    puts_u("CASES ");  hex8(cases);      putc_u('\n');
    puts_u("BAD ");    hex8(bad);        putc_u('\n');
    puts_u("EXTRA ");  hex8(extra_fail); putc_u('\n');
    puts_u("CSUM ");   hex8(csum);       putc_u('\n');
    puts_u("CYCLES "); hex8(c1 - c0);    putc_u('\n');
    puts_u((bad == 0 && extra_fail == 0) ? "ZBA DIFF OK\n" : "ZBA DIFF FAILED\n");
    return 0;
}
