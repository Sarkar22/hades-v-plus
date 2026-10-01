/* SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: zba_bench.c
 *
 * Zba benchmark (make bench-zba, see test/bench/README.md): the timed workload.
 * Recovered from the development log of 2026-08-18; everything after this
 * header is the program exactly as it was first measured.
 */
/* zba_bench.c - clean speedup measurement.
 * Address-generation-heavy workload with NO I/O inside the timed window, so the
 * measured cycles are compute only (zba_arr's window is polluted by UART waits).
 * Compiled twice, -march=rv32i vs -march=rv32i_zba; CHK must match, CYC is the result.
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

static volatile uint32_t seed_v = 0x1234567u;

typedef struct { int32_t a; int16_t b; int8_t c; } s8_t;    /* sizeof 8  */
typedef struct { int32_t a; int32_t b; int32_t c; } s12_t;  /* sizeof 12 */

int main(void) {
    uint32_t seed = seed_v, acc = 0, c0, c1;
    int i, rep;
    int32_t w[32]; int16_t h[32]; uint8_t b[32];
    int64_t d[16]; s8_t s8[16]; s12_t s12[16]; uint8_t idx[64];

    for (i = 0; i < 32; i++) {
        seed = seed * 1103515245u + 12345u;
        w[i] = (int32_t)seed; h[i] = (int16_t)(seed >> 7); b[i] = (uint8_t)(seed >> 11);
    }
    for (i = 0; i < 16; i++) {
        seed = seed * 1103515245u + 12345u;
        d[i] = (int64_t)((uint64_t)seed << 17) ^ (int64_t)(int32_t)seed;
        s8[i].a = (int32_t)seed; s8[i].b = (int16_t)(seed >> 3); s8[i].c = (int8_t)(seed >> 19);
        s12[i].a = (int32_t)~seed; s12[i].b = (int32_t)(seed ^ 0x80000000u);
        s12[i].c = (int32_t)(seed + 0xFFFFFFFFu);
    }
    for (i = 0; i < 64; i++) { seed = seed * 1103515245u + 12345u; idx[i] = (uint8_t)(seed >> 13); }

    __asm__ volatile("csrr %0, 0xB00" : "=r"(c0));
    for (rep = 0; rep < 12; rep++) {
        for (i = 0; i < 64; i++) {
            uint32_t k = idx[i] & 31;
            int64_t  v = d[k & 15];
            s8_t    *p8  = &s8[k & 15];
            s12_t   *p12 = &s12[k & 15];
            acc += (uint32_t)w[k];                    /* sh2add */
            acc ^= (uint32_t)(int32_t)h[k];           /* sh1add */
            acc += (uint32_t)b[(k >> 1) & 31];
            acc ^= (uint32_t)v; acc += (uint32_t)((uint64_t)v >> 32);   /* sh3add */
            acc ^= (uint32_t)p8->a; acc += (uint32_t)(int32_t)p8->b;    /* sh3add */
            acc ^= (uint32_t)p12->a; acc += (uint32_t)p12->c;           /* *12    */
            acc ^= k * 3u; acc += k * 5u; acc ^= k * 9u;                /* sh1/2/3add */
            acc += k * 6u; acc ^= k * 10u; acc += k * 18u;
        }
    }
    __asm__ volatile("csrr %0, 0xB00" : "=r"(c1));

    puts_u("CHK "); hex8(acc);     putc_u('\n');
    puts_u("CYC "); hex8(c1 - c0); putc_u('\n');
    return 0;
}
