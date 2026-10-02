/* SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: zbb_bench.c
 *
 * Zbb benchmark (make bench-zbb, see test/bench/README.md): the timed workload.
 *
 * Bit-manipulation kernels with no I/O inside the timed window, so the measured cycles are
 * compute only. Built for -march=rv32i, rv32i_zbb_zbs and rv32im_zba_zbb_zbs with the same
 * flags otherwise: CHK must be equal in every build, CYC (mcycle) is the result. The kernels
 * are the kinds of code that GCC turns into Zbb and Zbs instructions (named in the comments):
 * population counts, integer log2 and normalisation, bit scans, clamping, packed 8- and 16-bit
 * samples, mask arithmetic, a hash with rotates and a bitmap; rev8 and orc.b, which GCC 12
 * does not emit on RV32, are written by hand in the builds with Zbb (plain C otherwise).
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

static volatile uint32_t seed_v = 0x2545F491u;

#define N    64
static uint32_t d[N];
static uint32_t map[64];               /* 2048 bits */

static inline uint32_t rev8(uint32_t x) {
#if defined(__riscv_zbb)
    __asm__ ("rev8 %0, %1" : "=r"(x) : "r"(x));
    return x;
#else
    return (x >> 24) | ((x >> 8) & 0x0000FF00u) | ((x << 8) & 0x00FF0000u) | (x << 24);
#endif
}

static inline uint32_t orc_b(uint32_t x) {
#if defined(__riscv_zbb)
    __asm__ ("orc.b %0, %1" : "=r"(x) : "r"(x));
    return x;
#else
    /* 0x80 in every non-zero byte (no carries cross a byte), then spread to 0xFF */
    uint32_t t = ((x & 0x7F7F7F7Fu) + 0x7F7F7F7Fu) | x;
    t &= 0x80808080u;
    return (t << 1) - (t >> 7);
#endif
}

/* bit number n & 31 without GCC seeing the mask (it would then use bset and andn/xor, srl
 * and andi rather than bclr, binv, bext); the value is below 32, as C requires */
static inline uint32_t bitno(uint32_t n) {
    uint32_t b = n & 31u;
    __asm__ ("" : "+r"(b));
    return b;
}

static __attribute__((noinline)) uint32_t kernels(uint32_t rep) {
    uint32_t acc = rep, h = 0x811C9DC5u, i;

    for (i = 0; i < N; i++) {
        uint32_t a = d[i], b = d[(i + 1) & (N - 1)], n = a & 31u;
        int32_t  x = (int32_t)a;

        acc += (uint32_t)__builtin_popcount(a ^ b);                      /* cpop */
        acc += 31u - (uint32_t)__builtin_clz(a | 1u);                    /* clz: log2 */
        acc ^= (a | 1u) << __builtin_clz(a | 1u);                        /* clz: normalise */
        acc += (uint32_t)__builtin_ctz(b | 0x80000000u);                 /* ctz */
        x = x < -0x00100000 ? -0x00100000 : x;                           /* max */
        x = x > 0x000FFFFF ? 0x000FFFFF : x;                             /* min */
        acc += (uint32_t)x;
        acc ^= a < b ? a : b;                                            /* minu */
        acc += (uint32_t)(int32_t)(int8_t)(a >> 4);                      /* sext.b */
        acc += (uint32_t)(int32_t)(int16_t)(b >> 9);                     /* sext.h */
        acc += a & ~b;                                                   /* andn */
        acc ^= a | ~(b >> 3);                                            /* orn */
        acc += ~(a ^ (b << 2));                                          /* xnor */
        h ^= a;
        h = ((h >> 7) | (h << 25)) + 0x9E3779B9u;                        /* rori */
        h = (h >> n) | (h << ((32u - n) & 31u));                         /* ror */
        acc ^= rev8(b);                                                  /* rev8 */
        acc += orc_b(a & 0xFF00FF00u);                                   /* orc.b */
        map[(a >> 5) & 63u] |= 1u << bitno(a);                           /* bset */
        map[(b >> 5) & 63u] ^= 1u << bitno(b);                           /* binv */
        map[(a >> 11) & 63u] &= ~(1u << bitno(b));                       /* bclr */
        acc += (map[(b >> 11) & 63u] >> bitno(a)) & 1u;                  /* bext */
    }
    return acc ^ h;
}

int main(void) {
    uint32_t seed = seed_v, chk = 0, c0, c1, i, rep;

    for (i = 0; i < N; i++) {
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5;
        d[i] = seed;
    }

    __asm__ volatile("csrr %0, 0xB00" : "=r"(c0));
    for (rep = 0; rep < 24; rep++)
        chk = (chk << 1 | chk >> 31) ^ kernels(rep);
    for (i = 0; i < 64; i++)
        chk += (uint32_t)__builtin_popcount(map[i]);                     /* cpop */
    __asm__ volatile("csrr %0, 0xB00" : "=r"(c1));

    puts_u("CHK "); hex8(chk);     putc_u('\n');
    puts_u("CYC "); hex8(c1 - c0); putc_u('\n');
    return 0;
}
