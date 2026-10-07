/* SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: sha256_bench.c
 *
 * SHA-256 benchmark (make bench-sha256, see test/bench/README.md): the timed workload.
 *
 * One SHA-256 source, std/include/sha256.h, built for -march=rv32i (plain C, byte loads),
 * rv32im_zba_zbb_zbs (plain C: GCC's rori and rol for the rotations, rev8 for the message words) and
 * rv32im_zba_zbb_zbkb_zbkx_zbs_zknh (one Zknh instruction for each sigma and Sigma, rev8),
 * with the same flags otherwise.
 *
 * Before the timed window it checks the three SHA-256 examples of NIST (the empty message,
 * "abc" and the 448-bit message), each hashed whole and fed in pieces of 1, 3, 5, 7, 11 and
 * 13 bytes in turn, and fills a buffer of 16,384 bytes from a xorshift32 generator. The timed
 * window (mcycle, no I/O) is one sha256() of that buffer, padding block included.
 *
 * Output: NIST <passed>/<checked>, DIGEST (the buffer's digest, which bench.py recomputes
 * with Python's hashlib), CYC, BYTES (hex), then "SHA256 BENCH OK" or "SHA256 BENCH FAILED".
 * Built with -DLONG the timed window hashes 1,000,000 bytes 'a' instead (the long example
 * of FIPS 180-2), in pieces of 1,000 bytes.
 */
#include "peripherals.h"
#include "sha256.h"

#define OPAQUE(x) __asm__ ("" : "+r"(x))

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
static void hexd(const uint8_t *d) {
    int i;
    for (i = 0; i < 32; i += 4)
        hex8((uint32_t)d[i] << 24 | (uint32_t)d[i + 1] << 16 | (uint32_t)d[i + 2] << 8 | d[i + 3]);
}
static void dec(uint32_t v) {
    char s[11];
    int i = 10;
    s[i] = 0;
    do { s[--i] = (char)('0' + v % 10u); v /= 10u; } while (v);
    puts_u(s + i);
}

static const char M448[] = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";

/* the NIST digests (FIPS 180-4 examples; the empty message is CAVP's Len = 0) */
static const uint8_t NIST[3][32] = {
    { 0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14, 0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
      0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c, 0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55 },
    { 0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
      0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c, 0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad },
    { 0x24, 0x8d, 0x6a, 0x61, 0xd2, 0x06, 0x38, 0xb8, 0xe5, 0xc0, 0x26, 0x93, 0x0c, 0x3e, 0x60, 0x39,
      0xa3, 0x3c, 0xe4, 0x59, 0x64, 0xff, 0x21, 0x67, 0xf6, 0xec, 0xed, 0xd4, 0x19, 0xdb, 0x06, 0xc1 }
};

#ifdef LONG
/* 1,000,000 x 'a' */
static const uint8_t MILLION_A[32] = {
    0xcd, 0xc7, 0x6e, 0x5c, 0x99, 0x14, 0xfb, 0x92, 0x81, 0xa1, 0xc7, 0xe2, 0x84, 0xd7, 0x3e, 0x67,
    0xf1, 0x80, 0x9a, 0x48, 0xa4, 0x97, 0x20, 0x0e, 0x04, 0x6d, 0x39, 0xcc, 0xc7, 0x11, 0x2c, 0xd0
};
#define NBUF 1000u
#else
#define NBUF 16384u
#endif

static uint32_t buf_w[NBUF / 4];       /* words, so that the buffer is aligned */

static int same(const uint8_t *a, const uint8_t *b) {
    int i;
    for (i = 0; i < 32; i++)
        if (a[i] != b[i]) return 0;
    return 1;
}

int main(void) {
    static const char *const msg[3] = { "", "abc", M448 };
    static const uint32_t len[3] = { 0, 3, 56 };
    static const uint32_t piece[6] = { 1, 3, 5, 7, 11, 13 };
    uint8_t *buf = (uint8_t *)buf_w, dig[32];
    uint32_t i, seed = 0x2545F491u, c0, c1, passed = 0, checked = 0, ok;
    Sha256_t ctx;

    /* the NIST examples, whole and in pieces */
    for (i = 0; i < 3; i++) {
        uint32_t off = 0, k = 0;
        sha256(msg[i], len[i], dig);
        passed += (uint32_t)same(dig, NIST[i]);
        checked++;
        sha256_init(&ctx);
        while (off < len[i]) {
            uint32_t n = piece[k++ % 6u];
            if (n > len[i] - off) n = len[i] - off;
            sha256_update(&ctx, msg[i] + off, n);
            off += n;
        }
        sha256_final(&ctx, dig);
        passed += (uint32_t)same(dig, NIST[i]);
        checked++;
    }

#ifndef LONG
    for (i = 0; i < NBUF / 4; i++) {
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5;
        buf_w[i] = seed;                  /* little-endian bytes of each word */
    }
    __asm__ volatile("csrr %0, 0xB00" : "=r"(c0));
    sha256(buf, NBUF, dig);
    __asm__ volatile("csrr %0, 0xB00" : "=r"(c1));
    ok = 1;
#else
    (void)seed;
    for (i = 0; i < NBUF / 4; i++) {        /* 'a' in every byte; a word loop, not memset */
        uint32_t w = 0x61616161u;
        OPAQUE(w);
        buf_w[i] = w;
    }
    __asm__ volatile("csrr %0, 0xB00" : "=r"(c0));
    sha256_init(&ctx);
    for (i = 0; i < 1000u; i++) sha256_update(&ctx, buf, NBUF);
    sha256_final(&ctx, dig);
    __asm__ volatile("csrr %0, 0xB00" : "=r"(c1));
    ok = (uint32_t)same(dig, MILLION_A);
#endif

    puts_u("NIST "); dec(passed); putc_u('/'); dec(checked); putc_u('\n');
    puts_u("DIGEST "); hexd(dig); putc_u('\n');
    puts_u("CYC "); hex8(c1 - c0); putc_u('\n');
#ifndef LONG
    puts_u("BYTES "); hex8(NBUF); putc_u('\n');
#else
    puts_u("BYTES "); hex8(1000u * NBUF); putc_u('\n');
#endif
    puts_u((passed == checked && ok) ? "SHA256 BENCH OK\n" : "SHA256 BENCH FAILED\n");
    return 0;
}
