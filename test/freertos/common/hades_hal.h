/* Minimal board support for the HaDes-V+ FreeRTOS test programs.
 *
 * Result protocol (sim/top.sv + wishbone_test): hal_begin() writes the usual
 * "initial" 1 to the test register; hal_pass() writes 0 then 2, hal_fail()
 * writes 1 then 2. So a passing program ends with
 *     "All tests passed! (# Errors: 1 = initial test)"
 * and every program also prints exactly one line starting with
 *     "FRTOS-RESULT: PASS" or "FRTOS-RESULT: FAIL <reason> ..."
 * which is what test/freertos/campaign.py parses.
 *
 * Nothing here depends on the Zicntr TIME CSR (it reads 0 on the golden
 * reference CPU); wall-clock time comes from the memory-mapped mtime.
 */
#ifndef HADES_HAL_H
#define HADES_HAL_H

#include <stdint.h>

/* Byte addresses (wishbone word address << 2), see defines/constants.sv. */
#define HADES_UART_DATA     ( *( volatile uint8_t  * ) 0x00210000u )
#define HADES_UART_TXSTAT   ( *( volatile uint8_t  * ) 0x00210003u )   /* bit 2 = TX_EMPTY */
#define HADES_SWITCHES      ( *( volatile uint32_t * ) 0x00208000u )
#define HADES_MTIME_LO      ( *( volatile uint32_t * ) 0x00214004u )
#define HADES_MTIME_HI      ( *( volatile uint32_t * ) 0x00214008u )
#define HADES_TEST_REG      ( *( volatile uint32_t * ) 0x00480000u )
/* wishbone_test interrupt register: writing N > 0 raises the external
 * interrupt N cycles later and holds it until the register is rewritten;
 * writing 0 disables it. */
#define HADES_TEST_IRQ      ( *( volatile uint32_t * ) 0x00480004u )
/* Peripherals with a multi-cycle bus response, for interrupt-during-access
 * coverage: a VGA frame-buffer word (write 2 cycles, read 3) and the
 * wishbone_test stall-acknowledge register (4 cycles; plain read/write storage). */
#define HADES_VGA_WORD0     ( *( volatile uint32_t * ) 0x00240000u )
#define HADES_TEST_STALL    ( *( volatile uint32_t * ) 0x0048000Cu )

#define HADES_MSTATUS_MIE   0x8u

void hal_putc( char c );
void hal_puts( const char * s );
void hal_puthex( uint32_t v );
void hal_putdec( uint32_t v );

/* Print the banner, the run seed and the build configuration; write the
 * "initial test" marker. Call first thing in main(). */
void hal_begin( const char * pcAppName );

/* Run seed: FRTOS_SEED_SALT (compile time) mixed with the 16 board switches,
 * which the simulator drives from +switches=<hex>. Never 0. */
uint32_t hal_seed( void );

static inline uint32_t hal_rand( uint32_t * pulState )   /* xorshift32 */
{
    uint32_t x = *pulState;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *pulState = x;
    return x;
}

static inline uint32_t hal_mstatus( void )
{
    uint32_t v;
    __asm volatile ( "csrr %0, mstatus" : "=r" ( v ) );
    return v;
}

static inline uint32_t hal_mtime( void )
{
    return HADES_MTIME_LO;
}

/* Busy-wait for roughly n loop iterations (not optimised away). */
static inline void hal_spin( uint32_t n )
{
    for( volatile uint32_t i = n; i != 0; i-- )
    {
    }
}

/* UART transcript integrity: hal_pattern_line() prints HADES_PATTERN_LINE as
 * one line, with the scheduler suspended (so no other task's output can
 * interleave) but interrupts enabled. campaign.py checks that every such line
 * arrives intact -- the only way a program can "see" a UART store that the
 * core performed twice or dropped. */
#define HADES_PATTERN_LINE  "~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz~"
void hal_pattern_line( void );

/* Like hal_puts(), but with the scheduler suspended (no interleaving). */
void hal_puts_atomic( const char * s );

/* Bytes of the main/ISR stack that have ever been written (painted by start.S). */
uint32_t hal_isr_stack_peak( void );
uint32_t hal_isr_stack_size( void );

/* End the run. hal_fail() disables interrupts and does not touch the kernel,
 * so it is safe from tasks, hooks and interrupt handlers. */
void hal_pass( void ) __attribute__( ( noreturn ) );
void hal_fail( const char * pcWhy, const char * pcDetail, uint32_t a, uint32_t b ) __attribute__( ( noreturn ) );

/* Called for machine external interrupts (mcause 0x8000000B). A program that
 * enables the wishbone_test interrupt must define it; the default fails. */
void app_external_irq( void );

#endif /* HADES_HAL_H */
