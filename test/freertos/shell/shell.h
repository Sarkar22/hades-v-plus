/* shell.h -- interfaces shared by the files of the HaDes-V+ FreeRTOS shell.
 *
 *   main.c      start-up: banner, kernel objects, tasks, scheduler
 *   console.c   UART receive interrupt, console task (line editing), serialised output
 *   commands.c  the FreeRTOS+CLI commands
 *   format.c    shell_snprintf(): a small bounded formatter (the image has no stdio)
 *   swmodel.c   rv32i software model of the M and Zba instructions (always built for rv32i)
 */
#ifndef SHELL_H
#define SHELL_H

#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

/* ------------------------------------------------------------------ settings -- */

/* 1 in the loader configuration (test/freertos/loader/: these sources compiled with
 * -DSHELL_LOADER=1, plus loader.c), which adds the commands load, run and app; 0 for the
 * shell itself, which compiles none of the SHELL_LOADER blocks. */
#ifndef SHELL_LOADER
#define SHELL_LOADER            0
#endif

/* The prompt. The simulation's console bridge (sim/console.cpp) waits for it before it
 * types the next line of a script or of a paste; its +console_prompt= default is the
 * same string. */
#define SHELL_PROMPT            "hades> "

/* Longest command line, in characters. A longer line is rejected as a whole. */
#ifndef SHELL_LINE_MAX
#define SHELL_LINE_MAX          80
#endif

/* An escape sequence (an arrow key) whose next byte has not arrived after this many
 * milliseconds (RTOS ticks) is abandoned: it was a lone Esc key. */
#ifndef SHELL_ESC_TIMEOUT_MS
#define SHELL_ESC_TIMEOUT_MS    100
#endif

/* Receive queue between the UART interrupt and the console task, in characters. */
#ifndef SHELL_RX_BUFFER
#define SHELL_RX_BUFFER         64
#endif

/* Task priorities. blink runs above the console task, so that the console (which
 * produces the task list) always finds it blocked and the list is reproducible. */
#define SHELL_CONSOLE_PRIORITY  2
#define SHELL_BLINK_PRIORITY    3

/* Stacks in words. The command handlers run on the console task's stack. */
#ifdef __OPTIMIZE__
    #define SHELL_CONSOLE_STACK    320
#else
    #define SHELL_CONSOLE_STACK    512
#endif
#define SHELL_BLINK_STACK          128

/* The board's clock (clk_params.sv: 100 MHz / 1 * 10 / 20). */
#define SHELL_BOARD_CLOCK_HZ    50000000u

/* The instruction set and optimisation level this program was compiled for. */
#if defined( __riscv_mul )
    #define SHELL_ISA_M      "m"
#else
    #define SHELL_ISA_M      ""
#endif
#if defined( __riscv_zba )
    #define SHELL_ISA_ZBA    "_zba"
#else
    #define SHELL_ISA_ZBA    ""
#endif
#if defined( __riscv_zbb )
    #define SHELL_ISA_ZBB    "_zbb"
#else
    #define SHELL_ISA_ZBB    ""
#endif
#if defined( __riscv_zbs )
    #define SHELL_ISA_ZBS    "_zbs"
#else
    #define SHELL_ISA_ZBS    ""
#endif
#define SHELL_ISA            "rv32i" SHELL_ISA_M SHELL_ISA_ZBA SHELL_ISA_ZBB SHELL_ISA_ZBS
#if defined( __OPTIMIZE_SIZE__ )
    #define SHELL_OPT        "-Os"
#elif defined( __OPTIMIZE__ )
    #define SHELL_OPT        "-O2"
#else
    #define SHELL_OPT        "-O0"
#endif

/* ------------------------------------------------------------------ hardware -- */

/* UART (lib/wishbone/wishbone_uart.sv): one 32-bit word at byte address 0x210000.
 *   bits  7:0  receive buffer on read, transmit buffer on write (byte lane 0)
 *   bits 23:16 receive status: bit 16 RX_ERR (a byte was lost), 17 RX_IE, 18 RX_FULL
 *   bits 31:24 transmit status: bit 26 TX_EMPTY
 * Reading lane 0 empties the one-byte receive buffer; reading lane 2 clears RX_ERR. */
#define SHELL_UART_WORD         ( *( volatile uint32_t * ) 0x00210000u )
#define SHELL_UART_RXSTAT       ( *( volatile uint8_t * ) 0x00210002u )
#define SHELL_UART_RX_ERR       ( 1u << 16 )
#define SHELL_UART_RX_FULL      ( 1u << 18 )
#define SHELL_UART_RXSTAT_IE    0x02u

/* The 16 board LEDs (word address 0x80000). */
#define SHELL_LEDS              ( *( volatile uint32_t * ) 0x00200000u )

/* ------------------------------------------------------------------- console -- */

/* Output. Each line of the text is sent as one unit (with the scheduler suspended),
 * so the output of different tasks never interleaves within a line. A '\n' that does
 * not follow a '\r' is sent as "\r\n", as serial terminals expect. Callable from any
 * task (and before the scheduler starts); never from an interrupt handler. */
void shell_write( const char * pcText, size_t xLength );
void shell_puts( const char * pcText );
int shell_printf( const char * pcFormat, ... ) __attribute__( ( format( printf, 1, 2 ) ) );

/* Receive statistics of the UART interrupt handler. */
typedef struct
{
    uint32_t ulReceived;   /* bytes read from the UART */
    uint32_t ulDropped;    /* bytes lost because the receive queue was full */
    uint32_t ulOverruns;   /* bytes the UART itself lost (RX_ERR) */
} ShellRxStats_t;
void shell_rx_stats( ShellRxStats_t * pxStats );

/* Creates the console's kernel objects and task, and enables the UART receive
 * interrupt. Called by main() before the scheduler starts. */
void shell_console_start( void );

/* ------------------------------------------------------------------ commands -- */

/* Registers the commands with FreeRTOS+CLI (commands.c). */
void shell_register_commands( void );

/* Probes the CPU for M, Zba, Zbb, Zbs, Zicntr and Zicond (the loader's build: also Zbkb, Zbkx
 * and Zknh) by executing one instruction of each and catching the illegal-instruction trap. Must run in a task (the trap handler
 * saves the context of the running task). */
void shell_probe_cpu( void );

typedef struct
{
    uint8_t ucM;        /* mul/div execute */
    uint8_t ucZba;      /* sh1add/sh2add/sh3add execute */
    uint8_t ucZicntr;   /* the cycle/time/instret CSRs are readable */
    uint8_t ucZbb;      /* clz executes */
    uint8_t ucZbs;      /* bset executes */
    uint8_t ucZicond;   /* czero.eqz executes */
    #if SHELL_LOADER
        /* Only in the loader's build: the shell's own image has no room for these probes
         * in the board's 32 KiB. */
        uint8_t ucZbkb; /* pack executes */
        uint8_t ucZbkx; /* xperm8 executes */
        uint8_t ucZknh; /* sha256sum0 executes */
    #endif
} ShellCpu_t;
extern ShellCpu_t xShellCpu;

/* The run-time statistics clock: mcycle/mcycleh (both CPUs implement them), counted
 * from the start of the scheduler (app_config.h). */
void shell_run_time_start( void );
uint64_t shell_run_time( void );

/* ------------------------------------------------------------------ utilities -- */

/* Bounded formatting (format.c): %d %i %u %x %X %s %c %%, the flags '-' and '0', a
 * field width (digits or '*'), a precision for %s, and the length modifiers 'l' and
 * 'z' (32 bits) and 'll' (64 bits). Always terminates the buffer; returns the number
 * of characters stored (not counting the terminator). */
int shell_vsnprintf( char * pcBuffer, size_t xSize, const char * pcFormat, va_list xArgs );
int shell_snprintf( char * pcBuffer, size_t xSize, const char * pcFormat, ... ) __attribute__( ( format( printf, 3, 4 ) ) );

/* ullN / ullD (and the remainder, if pullRem is not NULL), without libgcc (format.c). */
uint64_t shell_udiv64( uint64_t ullN, uint64_t ullD, uint64_t * pullRem );

/* ------------------------------------------------ software model (swmodel.c) -- */

/* Results of one RISC-V instruction on the operands a and b, computed without the
 * M and Zba instructions (swmodel.c is always compiled for rv32i). */
typedef struct
{
    uint32_t ulMul, ulMulh, ulMulhsu, ulMulhu;
} ShellMulResult_t;
typedef struct
{
    uint32_t ulDiv, ulRem, ulDivu, ulRemu;
} ShellDivResult_t;

void swmodel_mul( uint32_t a, uint32_t b, ShellMulResult_t * pxOut );
void swmodel_div( uint32_t a, uint32_t b, ShellDivResult_t * pxOut );
uint32_t swmodel_shadd( uint32_t a, uint32_t b, unsigned uShift );

#if SHELL_LOADER

/* ------------------------------- app loader (test/freertos/loader/SPEC.md) -- */

#include "FreeRTOS.h"
#include "hades_app.h"

/* For the loader (console.c). shell_rx_byte() returns the next received byte (0..255), or
 * -1 if none arrives within xTicks (portMAX_DELAY: no limit); shell_rx_discard() drops what
 * has been received and not read; shell_rx_holds() tells whether that contains the byte
 * ucWanted, and leaves it as it is; shell_output_at_line_start() tells whether the output of
 * shell_write() is at the start of a line; shell_set_previous() sets the line editor's
 * previous character (a LF right after a CR is the second half of one line end). */
int shell_rx_byte( TickType_t xTicks );
void shell_rx_discard( void );
int shell_rx_holds( uint8_t ucWanted );
int shell_output_at_line_start( void );
void shell_set_previous( char c );

/* The loader (loader.c). main() calls loader_init() before the scheduler starts; the receive
 * interrupt calls loader_rx_from_isr() for every byte (pdTRUE: the byte is a Ctrl-C that
 * stops the running app, and is not queued); the exception handler calls loader_exception()
 * (1: the app raised the exception, and it is contained). */
void loader_init( void );
BaseType_t loader_rx_from_isr( uint8_t ucByte, BaseType_t * pxWoken );
int loader_exception( uint32_t ulCause, uint32_t ulPc );

/* The commands load, run and app (FreeRTOS+CLI callbacks). */
BaseType_t loader_cmd_load( char * pcOut, size_t xOutLen, const char * pcCommand );
BaseType_t loader_cmd_run( char * pcOut, size_t xOutLen, const char * pcCommand );
BaseType_t loader_cmd_app( char * pcOut, size_t xOutLen, const char * pcCommand );

#endif /* SHELL_LOADER */

#endif /* SHELL_H */
