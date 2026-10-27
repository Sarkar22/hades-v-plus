// SPDX-License-Identifier: MIT
// memlat.c: what a cache miss costs in CVA6's Verilator testharness (for the CoreMark comparison of
// docs/PERFORMANCE.md; not part of CoreMark).
// Built and run like CoreMark through verif/sim/cva6.py (crt.S, syscalls.c, uart.c of the CVA6 tree).
//  D side: a dependent pointer chase over 4096 nodes 64 bytes apart in pseudo-random order (256 KiB,
//          far larger than either data cache), so every load misses; the same chase over 16 nodes
//          (1 KiB, resident) gives the cost of a hit. Cycles per load, measured with mcycle.
//  I side: a straight run of 8192 four-byte NOPs (32 KiB, larger than either instruction cache) executed
//          twice; the second pass still misses on every line. A run of 256 NOPs (1 KiB) executed many
//          times gives the cost of a hit. Cycles per 16-byte line = 4 NOPs.
#include <stdint.h>
#include <stdio.h>
#include "uart.h"

int sprintf(char *str, const char *fmt, ...);

static inline uintptr_t mcycle(void)
{
    uintptr_t v;
    __asm__ volatile("csrr %0, mcycle" : "=r"(v));
    return v;
}

#define STRIDE 64
#define NBIG   4096
#define NSMALL 16
static uintptr_t buf[NBIG * STRIDE / sizeof(uintptr_t)] __attribute__((aligned(64)));
static uint32_t perm[NBIG];

static void build_chain(int n)
{
    uint32_t s = 12345;
    for (int i = 0; i < n; i++)
        perm[i] = i;
    for (int i = n - 1; i > 0; i--) {  // Fisher-Yates with an LCG
        s = s * 1103515245u + 12345u;
        int j = (s >> 8) % (i + 1);
        uint32_t t = perm[i]; perm[i] = perm[j]; perm[j] = t;
    }
    for (int i = 0; i < n; i++) {
        uintptr_t *from = &buf[perm[i] * (STRIDE / sizeof(uintptr_t))];
        uintptr_t *to = &buf[perm[(i + 1) % n] * (STRIDE / sizeof(uintptr_t))];
        *from = (uintptr_t)to;
    }
}

static __attribute__((noinline)) uintptr_t chase(uintptr_t p, int n)
{
    for (int i = 0; i < n; i++)
        p = *(volatile uintptr_t *)p;
    return p;
}

#define NOP4 "nop\n nop\n nop\n nop\n"
#define NOP16 NOP4 NOP4 NOP4 NOP4
#define NOP64 NOP16 NOP16 NOP16 NOP16
#define NOP256 NOP64 NOP64 NOP64 NOP64
#define NOP1K NOP256 NOP256 NOP256 NOP256

static __attribute__((noinline, aligned(64))) void nops_big(void)
{
    __asm__ volatile(".option push\n.option norvc\n"
                     NOP1K NOP1K NOP1K NOP1K NOP1K NOP1K NOP1K NOP1K
                     ".option pop\n");
}

static __attribute__((noinline, aligned(64))) void nops_small(void)
{
    __asm__ volatile(".option push\n.option norvc\n" NOP256 ".option pop\n");
}

static char line[160];

int main(void)
{
    uintptr_t t0, t1, p;

    build_chain(NBIG);
    p = chase((uintptr_t)&buf[perm[0] * (STRIDE / sizeof(uintptr_t))], NBIG);  // first pass: warm what can be warmed
    t0 = mcycle();
    p = chase(p, NBIG);
    t1 = mcycle();
    sprintf(line, "MEMLAT dside_miss_chase loads=%d cycles=%ld per_load_x100=%ld\n", NBIG, (long)(t1 - t0),
            (long)((t1 - t0) * 100 / NBIG));
    print_uart(line);

    build_chain(NSMALL);
    p = chase((uintptr_t)&buf[perm[0] * (STRIDE / sizeof(uintptr_t))], NSMALL * 8);
    t0 = mcycle();
    p = chase(p, NBIG);
    t1 = mcycle();
    sprintf(line, "MEMLAT dside_hit_chase loads=%d cycles=%ld per_load_x100=%ld\n", NBIG, (long)(t1 - t0),
            (long)((t1 - t0) * 100 / NBIG));
    print_uart(line);

    nops_big();
    t0 = mcycle();
    nops_big();
    t1 = mcycle();
    sprintf(line, "MEMLAT iside_miss_nops nops=8192 lines16=2048 cycles=%ld per_line_x100=%ld\n", (long)(t1 - t0),
            (long)((t1 - t0) * 100 / 2048));
    print_uart(line);

    nops_small();
    t0 = mcycle();
    for (int i = 0; i < 32; i++)
        nops_small();
    t1 = mcycle();
    sprintf(line, "MEMLAT iside_hit_nops nops=8192 lines16=2048 cycles=%ld per_line_x100=%ld\n", (long)(t1 - t0),
            (long)((t1 - t0) * 100 / 2048));
    print_uart(line);
    sprintf(line, "MEMLAT end %ld\n", (long)(p & 1));
    print_uart(line);
    return 0;
}
