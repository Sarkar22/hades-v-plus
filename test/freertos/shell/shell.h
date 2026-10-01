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
#define SHELL_ISA            "rv32i" SHELL_ISA_M SHELL_ISA_ZBA
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

/* Probes the CPU for M, Zba and Zicntr by executing one instruction of each and
 * catching the illegal-instruction trap. Must run in a task (the trap handler
 * saves the context of the running task). */
void shell_probe_cpu( void );

typedef struct
{
    uint8_t ucM;        /* mul/div execute */
    uint8_t ucZba;      /* sh1add/sh2add/sh3add execute */
    uint8_t ucZicntr;   /* the cycle/time/instret CSRs are readable */
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

#endif /* SHELL_H */
