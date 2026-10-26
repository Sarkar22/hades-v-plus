/* SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: core_portme.c
 *
 * HaDes-V+ port of CoreMark (third_party/coremark, unmodified upstream
 * sources; guide: test/coremark/README.md).
 *
 * Time base: the cycle counter mcycle (CSR 0xB00, Zicntr; the golden CPU has it too).
 * start_time() and stop_time() also read minstret (0xB02) when HADES_INSTRET is 1 (not
 * on the golden CPU) and the seven programmable counters mhpmcounter3-9 (0xB03-0xB09)
 * when HADES_HPM is 1 (a simulator built with HPM_PRESET). With HADES_BPRED=<0..3> portable_init()
 * selects the branch predictor's algorithm (BPRED=<n> of make coremark). portable_fini() prints what the
 * timed window cost after CoreMark's own report, as HADES lines that
 * test/coremark/coremark.py reads.
 *
 * This is a simulation: the run is far shorter than CoreMark's 10 s rule, so CoreMark
 * itself ends with "ERROR! Must execute for at least 10 secs" and "Errors detected". The
 * figures are estimates (CoreMark/MHz), not scores that may be reported as CoreMark results.
 */
#include <stdarg.h>
#include "coremark.h"
#include "peripherals.h"

#ifndef ITERATIONS
#define ITERATIONS 10
#endif
#ifndef HADES_INSTRET
#define HADES_INSTRET 1
#endif
#ifndef HADES_HPM
#define HADES_HPM 0
#endif

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

ee_u32 default_num_contexts = 1;

/* ---- console ---------------------------------------------------------------------------- */

static void putc_u(char c)
{
    while (!(*UART_TX_STATUS_ADDRESS & (1 << UART_TX_STATUS_IDX_EMPTY)))
        ;
    *UART_BUFFER_ADDRESS = (uint8_t)c;
}

static void put_num(unsigned long v, unsigned base, int upper, int width, int zero, int neg)
{
    char buf[12];
    int  n = 0, i;
    do
    {
        unsigned d = (unsigned)(v % base);
        buf[n++]   = (char)(d < 10 ? '0' + d : (upper ? 'A' : 'a') + d - 10);
        v /= base;
    } while (v != 0);
    if (neg && zero)
        putc_u('-');
    for (i = n + (neg ? 1 : 0); i < width; i++)
        putc_u(zero ? '0' : ' ');
    if (neg && !zero)
        putc_u('-');
    while (n > 0)
        putc_u(buf[--n]);
}

/* ee_printf: %c %s %d %i %u %x %X %%, a field width, the 0 flag and the l modifier
 * (long is 32 bits here). It prints what CoreMark prints and nothing more. */
int ee_printf(const char *fmt, ...)
{
    va_list ap;
    int     count = 0;
    va_start(ap, fmt);
    for (; *fmt; fmt++)
    {
        int width = 0, zero = 0;
        if (*fmt != '%')
        {
            putc_u(*fmt);
            count++;
            continue;
        }
        fmt++;
        if (*fmt == '0')
        {
            zero = 1;
            fmt++;
        }
        while (*fmt >= '0' && *fmt <= '9')
            width = width * 10 + (*fmt++ - '0');
        if (*fmt == 'l')
            fmt++;
        switch (*fmt)
        {
            case 'd':
            case 'i':
            {
                int v = va_arg(ap, int);
                put_num(v < 0 ? 0u - (unsigned)v : (unsigned)v, 10, 0, width, zero, v < 0);
                break;
            }
            case 'u':
                put_num(va_arg(ap, unsigned), 10, 0, width, zero, 0);
                break;
            case 'x':
            case 'X':
                put_num(va_arg(ap, unsigned), 16, *fmt == 'X', width, zero, 0);
                break;
            case 'c':
                putc_u((char)va_arg(ap, int));
                break;
            case 's':
            {
                const char *s = va_arg(ap, const char *);
                while (*s)
                    putc_u(*s++);
                break;
            }
            case '%':
                putc_u('%');
                break;
            default: /* not supported: print it as it stands */
                putc_u('%');
                putc_u(*fmt);
                break;
        }
        count++;
    }
    va_end(ap);
    return count;
}

/* ---- timing ----------------------------------------------------------------------------- */

#define CSR_READ(csr)                                              \
    ({                                                             \
        ee_u32 v_;                                                 \
        __asm__ volatile("csrr %0, " #csr : "=r"(v_));             \
        v_;                                                        \
    })

#define HPM_N 7

typedef struct
{
    ee_u32 cycle, instret, hpm[HPM_N];
} snapshot_t;

static snapshot_t snap_start, snap_stop;

static void take(snapshot_t *s, int start)
{
    /* mcycle is read first at the start and last at the stop, so that the reads of the other
     * counters fall inside the cycle window */
    if (start)
        s->cycle = CSR_READ(0xB00);
#if HADES_HPM
    s->hpm[0] = CSR_READ(0xB03);
    s->hpm[1] = CSR_READ(0xB04);
    s->hpm[2] = CSR_READ(0xB05);
    s->hpm[3] = CSR_READ(0xB06);
    s->hpm[4] = CSR_READ(0xB07);
    s->hpm[5] = CSR_READ(0xB08);
    s->hpm[6] = CSR_READ(0xB09);
#endif
#if HADES_INSTRET
    s->instret = CSR_READ(0xB02);
#endif
    if (!start)
        s->cycle = CSR_READ(0xB00);
}

void start_time(void)
{
    take(&snap_start, 1);
}

void stop_time(void)
{
    take(&snap_stop, 0);
}

CORE_TICKS get_time(void)
{
    return (CORE_TICKS)(snap_stop.cycle - snap_start.cycle);
}

secs_ret time_in_secs(CORE_TICKS ticks)
{
    return ((secs_ret)ticks) / (secs_ret)EE_TICKS_PER_SEC;
}

/* ---- start and end ---------------------------------------------------------------------- */

void portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc;
    (void)argv;
#ifdef HADES_BPRED
    /* the branch predictor's algorithm (MHPMEVENT10, docs/EXTENSIONS.md); reset: 0, never taken */
    __asm__ volatile("csrw 0x32A, %0" : : "r"(HADES_BPRED));
#endif
    if (sizeof(ee_ptr_int) != sizeof(ee_u8 *))
        ee_printf("ERROR! ee_ptr_int must hold a pointer!\n");
    if (sizeof(ee_u32) != 4)
        ee_printf("ERROR! ee_u32 must be a 32-bit unsigned type!\n");
    p->portable_id = 1;
}

void portable_fini(core_portable *p)
{
    int i;
    p->portable_id = 0;
    ee_printf("HADES port: iterations=%u cycles=%u clock_hz=%u\n", (unsigned)ITERATIONS,
              (unsigned)(snap_stop.cycle - snap_start.cycle), (unsigned)HADES_CLOCK_HZ);
#if HADES_INSTRET
    ee_printf("HADES instret: window=%u start=%u stop=%u\n",
              (unsigned)(snap_stop.instret - snap_start.instret), (unsigned)snap_start.instret,
              (unsigned)snap_stop.instret);
#else
    ee_printf("HADES instret: n/a\n");
#endif
#if HADES_HPM
    for (i = 0; i < HPM_N; i++)
        ee_printf("HADES hpm%d: %u\n", i + 3, (unsigned)(snap_stop.hpm[i] - snap_start.hpm[i]));
#else
    (void)i;
#endif
    ee_printf("HADES note: simulation, not a CoreMark score. The 10 s rule is not met "
              "(the ERROR and Errors detected lines above say so); CoreMark/MHz is an "
              "estimate: iterations * 1000000 / cycles.\n");
}

/* GCC calls memset for the block fills of core_init_state (outside the timed window); -nostdlib
 * has none. The attribute keeps GCC from turning this loop into a call of itself. */
__attribute__((optimize("no-tree-loop-distribute-patterns")))
void *memset(void *s, int c, size_t n)
{
    unsigned char *d = (unsigned char *)s;
    while (n--)
        *d++ = (unsigned char)c;
    return s;
}

/* The data block is static (MEM_METHOD); these exist for the porting interface only. */
void *portable_malloc(ee_size_t size)
{
    (void)size;
    return NULL;
}

void portable_free(void *p)
{
    (void)p;
}
