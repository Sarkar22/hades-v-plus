/* SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: core_portme.h
 *
 * HaDes-V+ port of CoreMark (third_party/coremark, unmodified upstream
 * sources; guide: test/coremark/README.md). Written against the porting
 * interface that coremark.h declares. Make passes the build's settings
 * (ITERATIONS, FLAGS_STR, PERFORMANCE_RUN or VALIDATION_RUN, HADES_*).
 */
#ifndef CORE_PORTME_H
#define CORE_PORTME_H

#include <stddef.h>
#include <stdint.h>

/* No floating point, no libc: results are integers, the console is the UART. */
#define HAS_FLOAT  0
#define HAS_TIME_H 0
#define USE_CLOCK  0
#define HAS_STDIO  0
#define HAS_PRINTF 0

#ifndef FLAGS_STR
#define FLAGS_STR "(flags not given)"
#endif
#define COMPILER_VERSION "GCC" __VERSION__
#define COMPILER_FLAGS   FLAGS_STR
#define MEM_LOCATION     "Static data in RAM (.bss)"

typedef signed short   ee_s16;
typedef unsigned short ee_u16;
typedef signed int     ee_s32;
typedef double         ee_f32;
typedef unsigned char  ee_u8;
typedef unsigned int   ee_u32;
typedef ee_u32         ee_ptr_int;
typedef size_t         ee_size_t;

/* align_mem: align an offset to a 32-bit value (used by the matrix algorithm) */
#define align_mem(x) (void *)(4 + (((ee_ptr_int)(x)-1) & ~3))

/* Time is counted in clock cycles of mcycle (the 32 low bits are enough for a
 * difference of two readings). The design runs at 50 MHz (SYS_CLK_FREQUENCY_MHZ in
 * defines/clk_params.sv), so one second is 50,000,000 ticks. This is an assumption
 * about the board, not something the simulation measures. */
#ifndef HADES_CLOCK_HZ
#define HADES_CLOCK_HZ 50000000u
#endif
#define EE_TICKS_PER_SEC HADES_CLOCK_HZ
#define CORETIMETYPE     ee_u32
typedef ee_u32 CORE_TICKS;

#ifndef SEED_METHOD
#define SEED_METHOD SEED_VOLATILE
#endif

/* The data block is a static array: the stack (the top 4 KiB of the 32 KiB RAM,
 * std/hades-v.ld) stays free for the call chain. */
#ifndef MEM_METHOD
#define MEM_METHOD MEM_STATIC
#endif

#define MULTITHREAD 1
#define USE_PTHREAD 0
#define USE_FORK    0
#define USE_SOCKET  0

#define MAIN_HAS_NOARGC    1
#define MAIN_HAS_NORETURN  0

extern ee_u32 default_num_contexts;

typedef struct CORE_PORTABLE_S
{
    ee_u8 portable_id;
} core_portable;

void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);

/* TOTAL_DATA_SIZE 2000 is the performance and validation run (the seeds differ). */
#if !defined(PROFILE_RUN) && !defined(PERFORMANCE_RUN) && !defined(VALIDATION_RUN)
#if (TOTAL_DATA_SIZE == 1200)
#define PROFILE_RUN 1
#elif (TOTAL_DATA_SIZE == 2000)
#define PERFORMANCE_RUN 1
#else
#define VALIDATION_RUN 1
#endif
#endif

int ee_printf(const char *fmt, ...);

#endif /* CORE_PORTME_H */
