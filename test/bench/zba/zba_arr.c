/* SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: zba_arr.c
 *
 * Zba benchmark (make bench-zba, see test/bench/README.md): the output comparison.
 * Recovered from the development log of 2026-08-18; everything after this
 * header is the program exactly as it was first measured.
 */
/* zba_arr.c - address-generation workload.
 * Compiled TWICE with identical flags except -march:
 *   (a) -march=rv32i        -> GCC emits slli + add
 *   (b) -march=rv32i_zba    -> GCC emits sh1add / sh2add / sh3add
 * The two binaries are semantically identical, so their UART output must be
 * byte-identical. Any difference is a hardware bug in the Zba implementation.
 * The trailing CYCLES line is expected to differ (that is the speedup measurement).
 */
#include "peripherals.h"

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

/* volatile so nothing below can be constant-folded at compile time */
static volatile uint32_t seed_v = 0x1234567u;

typedef struct { int32_t a; int16_t b; int8_t c; } s8_t;    /* sizeof == 8  -> sh3add */
typedef struct { int32_t a; int32_t b; int32_t c; } s12_t;  /* sizeof == 12 -> *3 then sh2add */

int main(void) {
    uint32_t seed = seed_v;
    uint32_t acc  = 0;
    uint32_t c0, c1;
    int i;

    int32_t  w[32];
    int16_t  h[32];
    uint8_t  b[32];
    int64_t  d[16];
    s8_t     s8[16];
    s12_t    s12[16];
    uint8_t  idx[64];

    /* ---- fill everything from an LCG (no .bss reliance) ---- */
    for (i = 0; i < 32; i++) {
        seed = seed * 1103515245u + 12345u;
        w[i] = (int32_t)seed;
        h[i] = (int16_t)(seed >> 7);
        b[i] = (uint8_t)(seed >> 11);
    }
    for (i = 0; i < 16; i++) {
        seed = seed * 1103515245u + 12345u;
        d[i]      = (int64_t)((uint64_t)seed << 17) ^ (int64_t)(int32_t)seed;
        s8[i].a   = (int32_t)seed;
        s8[i].b   = (int16_t)(seed >> 3);
        s8[i].c   = (int8_t)(seed >> 19);
        s12[i].a  = (int32_t)~seed;
        s12[i].b  = (int32_t)(seed ^ 0x80000000u);
        s12[i].c  = (int32_t)(seed + 0xFFFFFFFFu);
    }
    for (i = 0; i < 64; i++) {
        seed = seed * 1103515245u + 12345u;
        idx[i] = (uint8_t)(seed >> 13);
    }

    __asm__ volatile("csrr %0, 0xB00" : "=r"(c0));

    /* ---- phase 1: plain int array indexing (sh2add) ---- */
    for (i = 0; i < 64; i++) acc += (uint32_t)w[idx[i] & 31];
    puts_u("P1 "); hex8(acc); putc_u('\n');

    /* ---- phase 2: short + byte array indexing (sh1add / plain add) ---- */
    for (i = 0; i < 64; i++) {
        acc ^= (uint32_t)(int32_t)h[idx[i] & 31];
        acc += (uint32_t)b[(idx[i] >> 1) & 31];
    }
    puts_u("P2 "); hex8(acc); putc_u('\n');

    /* ---- phase 3: 64-bit array indexing (sh3add) ---- */
    for (i = 0; i < 64; i++) {
        int64_t v = d[idx[i] & 15];
        acc += (uint32_t)v;
        acc ^= (uint32_t)((uint64_t)v >> 32);
    }
    puts_u("P3 "); hex8(acc); putc_u('\n');

    /* ---- phase 4: struct-array access, sizeof 8 (sh3add) ---- */
    for (i = 0; i < 64; i++) {
        s8_t *p = &s8[idx[i] & 15];
        acc += (uint32_t)p->a;
        acc ^= (uint32_t)(int32_t)p->b;
        acc += (uint32_t)(int32_t)p->c;
    }
    puts_u("P4 "); hex8(acc); putc_u('\n');

    /* ---- phase 5: struct-array access, sizeof 12 (mul-by-3 via sh1add + sh2add) ---- */
    for (i = 0; i < 64; i++) {
        s12_t *p = &s12[idx[i] & 15];
        acc ^= (uint32_t)p->a;
        acc += (uint32_t)p->b;
        acc ^= (uint32_t)p->c;
    }
    puts_u("P5 "); hex8(acc); putc_u('\n');

    /* ---- phase 6: pointer arithmetic and scaled-index offsets ---- */
    for (i = 0; i < 64; i++) {
        uint32_t k = idx[i] & 31;
        int32_t *p = w + k;
        acc += (uint32_t)*p;
        acc ^= (uint32_t)((char *)&w[k]   - (char *)w);   /* k*4  */
        acc += (uint32_t)((char *)&h[k]   - (char *)h);   /* k*2  */
        acc ^= (uint32_t)((char *)&d[k&15] - (char *)d);  /* k*8  */
        acc += (uint32_t)((char *)&s12[k&15] - (char *)s12); /* k*12 */
    }
    puts_u("P6 "); hex8(acc); putc_u('\n');

    /* ---- phase 7: constant multiplies that map onto shNadd (x3, x5, x9, x6, x10, x18) ---- */
    for (i = 0; i < 64; i++) {
        uint32_t k = (uint32_t)idx[i] ^ (uint32_t)w[i & 31];
        acc += k * 3u;  acc ^= k * 5u;  acc += k * 9u;
        acc ^= k * 6u;  acc += k * 10u; acc ^= k * 18u;
        acc += k * 36u; acc ^= k * 20u; acc += k * 12u;
    }
    puts_u("P7 "); hex8(acc); putc_u('\n');

    /* ---- phase 8: dependent chain, exercises EX->EX forwarding of the new op ---- */
    {
        uint32_t r = acc;
        for (i = 0; i < 64; i++) {
            uint32_t k = idx[i] & 31;
            r = (uint32_t)w[(r ^ k) & 31] + r;          /* load feeds the index (MEM->EX) */
            r = (r << 1) + (uint32_t)h[(r >> 3) & 31];
            r = (r << 2) + (uint32_t)b[(r >> 5) & 31];
            r = (r << 3) + k;
        }
        acc ^= r;
    }
    puts_u("P8 "); hex8(acc); putc_u('\n');

    __asm__ volatile("csrr %0, 0xB00" : "=r"(c1));

    puts_u("SUM "); hex8(acc); putc_u('\n');
    puts_u("CYCLES "); hex8(c1 - c0); putc_u('\n');
    return 0;
}
