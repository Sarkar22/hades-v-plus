/* SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: zbb_arr.c
 *
 * Zbb benchmark (make bench-zbb, see test/bench/README.md): the output comparison.
 *
 * Eight phases of bit-manipulation code, each printing a checksum (P1 to P8), then SUM and
 * CYCLES. Built for -march=rv32i, rv32i_zbb_zbs and rv32im_zba_zbb_zbs with the same flags
 * otherwise: the programs are semantically identical, so every line before CYCLES must be
 * equal in all builds; a difference is a fault in the Zbb, Zbs or Zicond hardware (or in the
 * compiler). CYCLES differs, and its window includes waiting for the UART.
 *
 *   P1 cpop     population counts of words, bytes and differences
 *   P2 clz/ctz  log2, leading and trailing zeros, the lowest and highest set bit
 *   P3 min/max  signed and unsigned clamps, running minima and maxima
 *   P4 extend   packed 8- and 16-bit samples, sign- and zero-extended
 *   P5 masks    andn, orn, xnor
 *   P6 rotate   rol, ror and rori in a hash
 *   P7 bits     a bitmap: bset, bclr, binv, bext and their immediate forms
 *   P8 zicond   branch-free select, clamp and conditional add through std/include/zicond.h
 *               (czero.eqz, czero.nez; the rv32i build defines ZICOND_PORTABLE and computes
 *               the same in C)
 */
#include "peripherals.h"
#include "zicond.h"

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
static void line(const char *key, uint32_t v) { puts_u(key); putc_u(' '); hex8(v); putc_u('\n'); }

/* volatile so nothing below can be constant-folded at compile time */
static volatile uint32_t seed_v = 0x0BADC0DEu;

#define N 48
static uint32_t w[N];
static uint32_t map[32];

static inline uint32_t bitno(uint32_t n) {     /* n & 31, the mask hidden from GCC (see zbb_bench.c) */
    uint32_t b = n & 31u;
    __asm__ ("" : "+r"(b));
    return b;
}

int main(void) {
    uint32_t seed = seed_v, p[9], sum = 0, c0, c1, i, zero = 0;
    int k;

    /* zero through an empty asm: a plain clearing loop becomes a call to memset, which this
       program, linked without the C library, does not have */
    __asm__ ("" : "+r"(zero));

    for (i = 0; i < N; i++) {
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5;
        w[i] = seed;
    }
    /* a few edge values among them */
    w[0] = 0; w[1] = 0xFFFFFFFFu; w[2] = 0x80000000u; w[3] = 1; w[4] = 0x7FFFFFFFu; w[5] = 0x00008080u;

    __asm__ volatile("csrr %0, 0xB00" : "=r"(c0));
    for (k = 0; k < 9; k++) p[k] = zero;

    for (i = 0; i < N; i++) {                                /* P1 */
        uint32_t a = w[i], b = w[(i + 7) % N];
        p[1] += (uint32_t)__builtin_popcount(a);
        p[1] += (uint32_t)__builtin_popcount(a & 0xFFu) << 8;
        p[1] ^= (uint32_t)__builtin_popcount(a ^ b) << 16;
    }
    for (i = 0; i < N; i++) {                                /* P2 */
        uint32_t a = w[i];
        p[2] += a ? 31u - (uint32_t)__builtin_clz(a) : 0xFFu;
        p[2] += a ? (uint32_t)__builtin_ctz(a) << 8 : 0x2000u;
        p[2] ^= a & (0u - a);                                /* lowest set bit */
        p[2] += a ? 0x80000000u >> __builtin_clz(a) : 0;     /* highest set bit */
    }
    for (i = 0; i + 1 < N; i++) {                            /* P3 */
        int32_t x = (int32_t)w[i], y = (int32_t)w[i + 1];
        uint32_t u = w[i], v = w[i + 1];
        p[3] += (uint32_t)(x < y ? x : y);
        p[3] ^= (uint32_t)(x > y ? x : y);
        p[3] += u < v ? u : v;
        p[3] ^= u > v ? u : v;
        x = x < -1000 ? -1000 : x > 1000 ? 1000 : x;
        p[3] += (uint32_t)x;
    }
    for (i = 0; i < N; i++) {                                /* P4 */
        uint32_t a = w[i];
        for (k = 0; k < 4; k++) p[4] += (uint32_t)(int32_t)(int8_t)(a >> (8 * k));
        p[4] ^= (uint32_t)(int32_t)(int16_t)a;
        p[4] += (uint32_t)(int32_t)(int16_t)(a >> 16) << 1;
        p[4] ^= (uint16_t)(a >> 5);
    }
    for (i = 0; i + 1 < N; i++) {                            /* P5 */
        uint32_t a = w[i], b = w[i + 1];
        p[5] += a & ~b;
        p[5] ^= a | ~(b >> 1);
        p[5] += ~(a ^ (b << 1));
        p[5] ^= ~a & b;
    }
    {                                                        /* P6 */
        uint32_t h = 0x811C9DC5u;
        for (i = 0; i < N; i++) {
            uint32_t n = w[i] & 31u;
            h ^= w[i];
            h = (h << n) | (h >> ((32u - n) & 31u));
            h = ((h >> 13) | (h << 19)) ^ 0x9E3779B9u;
            h = (h >> (n ^ 7u)) | (h << ((32u - (n ^ 7u)) & 31u));
        }
        p[6] = h;
    }
    for (i = 0; i < 32; i++) map[i] = zero;                  /* P7 */
    for (i = 0; i < N; i++) {
        uint32_t a = w[i];
        map[(a >> 5) & 31u] |= 1u << bitno(a);
        map[(a >> 10) & 31u] ^= 1u << bitno(a >> 15);
        map[(a >> 20) & 31u] &= ~(1u << bitno(a >> 25));
        p[7] += (map[(a >> 3) & 31u] >> bitno(a >> 8)) & 1u;
        p[7] += ((a | (1u << 19)) ^ (1u << 23)) & ~(1u << 29);
        p[7] ^= (a >> 21) & 1u;
    }
    for (i = 0; i < 32; i++) p[7] = (p[7] << 3 | p[7] >> 29) ^ map[i];
    for (i = 0; i < N; i++) {                                /* P8 */
        uint32_t a = w[i], b = w[(i + 5) % N], c;
        int32_t x = (int32_t)a >> 16;
        p[8] += zicond_select(a & 4u, a, b);
        c = zicond_select((uint32_t)(x < -300), (uint32_t)-300, (uint32_t)x);
        c = zicond_select((uint32_t)(x > 300), 300u, c);
        p[8] ^= c;
        p[8] = zicond_add_if(b >> 31, p[8], a);
        p[8] += czero_nez(b, a & 0x10u);
    }
    __asm__ volatile("csrr %0, 0xB00" : "=r"(c1));

    line("P1", p[1]); line("P2", p[2]); line("P3", p[3]); line("P4", p[4]);
    line("P5", p[5]); line("P6", p[6]); line("P7", p[7]); line("P8", p[8]);
    for (k = 1; k <= 8; k++) sum = (sum << 5 | sum >> 27) ^ p[k];
    line("SUM", sum);
    line("CYCLES", c1 - c0);
    return 0;
}
