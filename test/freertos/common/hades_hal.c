/* Board support + FreeRTOS hooks shared by the HaDes-V+ FreeRTOS test programs. */
#include <stdarg.h>
#include <stddef.h>
#include "FreeRTOS.h"
#include "task.h"
#include "hades_hal.h"

#ifndef FRTOS_SEED_SALT
#define FRTOS_SEED_SALT    0x9E3779B9u
#endif

#define STR_( x )    # x
#define STR( x )     STR_( x )

void hal_putc( char c )
{
    while( ( HADES_UART_TXSTAT & 4u ) == 0u )
    {
    }

    HADES_UART_DATA = ( uint8_t ) c;
}

void hal_puts( const char * s )
{
    while( *s != '\0' )
    {
        hal_putc( *s++ );
    }
}

void hal_puthex( uint32_t v )
{
    for( int i = 28; i >= 0; i -= 4 )
    {
        hal_putc( "0123456789abcdef"[ ( v >> i ) & 15u ] );
    }
}

void hal_putdec( uint32_t v )
{
    char buf[ 11 ];
    int n = 0;

    do
    {
        buf[ n++ ] = ( char ) ( '0' + ( v % 10u ) );
        v /= 10u;
    } while( v != 0u );

    while( n > 0 )
    {
        hal_putc( buf[ --n ] );
    }
}

void hal_puts_atomic( const char * s )
{
    const int running = ( xTaskGetSchedulerState() == taskSCHEDULER_RUNNING );

    if( running )
    {
        vTaskSuspendAll();
    }

    hal_puts( s );

    if( running )
    {
        ( void ) xTaskResumeAll();
    }
}

void hal_pattern_line( void )
{
    hal_puts_atomic( HADES_PATTERN_LINE "\n" );
}

uint32_t hal_seed( void )
{
    uint32_t s = FRTOS_SEED_SALT ^ ( ( HADES_SWITCHES & 0xFFFFu ) * 0x01000193u );

    s ^= s >> 16;
    s *= 0x7FEB352Du;
    s ^= s >> 15;
    return ( s != 0u ) ? s : 1u;
}

#if defined( __riscv_zba )
    #define HAL_ISA    "rv32im_zba"
#elif defined( __riscv_mul )
    #define HAL_ISA    "rv32im"
#else
    #define HAL_ISA    "rv32i"
#endif
#if defined( __OPTIMIZE_SIZE__ )
    #define HAL_OPT    "s"
#elif defined( __OPTIMIZE__ )
    #define HAL_OPT    "2"
#else
    #define HAL_OPT    "0"
#endif

void hal_begin( const char * pcAppName )
{
    HADES_TEST_REG = 1;   /* the "initial test" marker, see hades_hal.h */
    #if defined( FRTOS_BPRED ) && ( FRTOS_BPRED != 0 )
        /* Branch-predictor mode (MHPMEVENT10: 1 always-taken, 2 backward-taken,
         * 3 bimodal). Architecturally invisible; the golden CPU reads the CSR
         * as 0 and ignores the write (no trap), so it stays a valid twin. */
        __asm volatile ( "csrw 0x32A, %0" :: "r" ( FRTOS_BPRED ) );
    #endif
    hal_puts( "\nFreeRTOS " tskKERNEL_VERSION_NUMBER " on HaDes-V+: " );
    hal_puts( pcAppName );
    hal_puts( "\n  config: tick=" STR( FRTOS_TICK_CYCLES ) "cyc preempt=" STR( FRTOS_PREEMPT )
              " slice=" STR( FRTOS_SLICE ) " heap_" STR( FRTOS_HEAP ) " isa=" HAL_ISA " opt=" HAL_OPT
              " ram=" STR( FRTOS_RAM_KB ) "K"
    #if defined( FRTOS_BPRED )
              " bpred=" STR( FRTOS_BPRED )
    #endif
              "\n  seed: switches=" );
    hal_puthex( HADES_SWITCHES & 0xFFFFu );
    hal_puts( " seed=" );
    hal_puthex( hal_seed() );
    hal_putc( '\n' );
}

extern uint32_t __isr_stack_bottom[], __ram_end[];

uint32_t hal_isr_stack_size( void )
{
    return ( uint32_t ) ( ( uintptr_t ) __ram_end - ( uintptr_t ) __isr_stack_bottom );
}

uint32_t hal_isr_stack_peak( void )
{
    const uint32_t * p = __isr_stack_bottom;

    while( ( p < __ram_end ) && ( *p == 0xDEADBEEFu ) )
    {
        p++;
    }

    return ( uint32_t ) ( ( uintptr_t ) __ram_end - ( uintptr_t ) p );
}

static void prvEnd( uint32_t ulCode ) __attribute__( ( noreturn ) );
static void prvEnd( uint32_t ulCode )
{
    hal_puts( " mtime=" );
    hal_puthex( HADES_MTIME_HI );
    hal_puthex( HADES_MTIME_LO );
    hal_putc( '\n' );
    HADES_TEST_REG = ulCode;   /* 0 = pass, 1 = fail */
    HADES_TEST_REG = 2;        /* stop the simulation */

    for( ; ; )
    {
    }
}

void hal_pass( void )
{
    __asm volatile ( "csrc mstatus, 8" );
    HADES_TEST_IRQ = 0;

    /* The ISR stack sits right above .bss with no guard: insist on a margin. */
    if( hal_isr_stack_peak() + 64u > hal_isr_stack_size() )
    {
        hal_fail( "main/ISR stack (almost) exhausted (peak, size)", NULL, hal_isr_stack_peak(), hal_isr_stack_size() );
    }

    hal_puts( "\nFRTOS-RESULT: PASS" );
    prvEnd( 0 );
}

void hal_fail( const char * pcWhy, const char * pcDetail, uint32_t a, uint32_t b )
{
    __asm volatile ( "csrc mstatus, 8" );
    HADES_TEST_IRQ = 0;
    hal_puts( "\nFRTOS-RESULT: FAIL " );
    hal_puts( pcWhy );

    if( pcDetail != NULL )
    {
        hal_puts( " [" );
        hal_puts( pcDetail );
        hal_putc( ']' );
    }

    hal_puts( " a=" );
    hal_puthex( a );
    hal_puts( " b=" );
    hal_puthex( b );
    prvEnd( 1 );
}

/* ------------------------------------------------------------ FreeRTOS hooks */

void vAssertCalled( const char * pcFile, unsigned long ulLine )
{
    hal_fail( "configASSERT", pcFile, ( uint32_t ) ulLine, 0 );
}

/* Weak: a program that handles the overflow of one of its tasks provides its own (the
 * shell's app loader, test/freertos/loader/loader.c). */
__attribute__( ( weak ) ) void vApplicationStackOverflowHook( TaskHandle_t xTask, char * pcTaskName )
{
    hal_fail( "stack overflow", pcTaskName, ( uint32_t ) ( uintptr_t ) xTask, 0 );
}

void vApplicationMallocFailedHook( void )
{
    hal_fail( "malloc failed", NULL, 0, 0 );
}

/* Called by portASM.S for synchronous traps other than ECALL. Weak: a program
 * that raises exceptions on purpose provides its own. */
__attribute__( ( weak ) ) void freertos_risc_v_application_exception_handler( uint32_t mcause, uint32_t mepc_plus_4 )
{
    hal_fail( "unexpected exception (mcause, mepc)", NULL, mcause, mepc_plus_4 - 4u );
}

__attribute__( ( weak ) ) void app_external_irq( void )
{
    hal_fail( "unexpected external interrupt", NULL, 0x8000000Bu, 0 );
}

/* Called by portASM.S for interrupts other than the machine timer. */
void freertos_risc_v_application_interrupt_handler( uint32_t mcause )
{
    if( mcause == 0x8000000Bu )
    {
        app_external_irq();
    }
    else
    {
        hal_fail( "unexpected interrupt", NULL, mcause, 0 );
    }
}

/* ------------------------------------------------------- tiny sprintf ------ */
/* The standard demo tasks (MessageBufferDemo) format numbers with sprintf();
 * this replaces newlib's (which would pull in stdio and its reentrancy data).
 * Supports %d %i %u %x %s %c %% with an optional 'l'. */
static char * prvUtoa( char * p, uint32_t v, uint32_t base )
{
    char tmp[ 11 ];
    int n = 0;

    do
    {
        tmp[ n++ ] = "0123456789abcdef"[ v % base ];
        v /= base;
    } while( v != 0u );

    while( n > 0 )
    {
        *p++ = tmp[ --n ];
    }

    return p;
}

int sprintf( char * pcOut, const char * pcFmt, ... )
{
    va_list ap;
    char * p = pcOut;

    va_start( ap, pcFmt );

    for( ; *pcFmt != '\0'; pcFmt++ )
    {
        if( *pcFmt != '%' )
        {
            *p++ = *pcFmt;
            continue;
        }

        pcFmt++;

        if( *pcFmt == 'l' )
        {
            pcFmt++;
        }

        switch( *pcFmt )
        {
            case 'd':
            case 'i':
               {
                   int32_t v = va_arg( ap, int32_t );

                   if( v < 0 )
                   {
                       *p++ = '-';
                       p = prvUtoa( p, ( uint32_t ) ( -( v + 1 ) ) + 1u, 10 );
                   }
                   else
                   {
                       p = prvUtoa( p, ( uint32_t ) v, 10 );
                   }

                   break;
               }

            case 'u':
                p = prvUtoa( p, va_arg( ap, uint32_t ), 10 );
                break;

            case 'x':
                p = prvUtoa( p, va_arg( ap, uint32_t ), 16 );
                break;

            case 's':
               {
                   const char * s = va_arg( ap, const char * );

                   while( *s != '\0' )
                   {
                       *p++ = *s++;
                   }

                   break;
               }

            case 'c':
                *p++ = ( char ) va_arg( ap, int );
                break;

            case '%':
                *p++ = '%';
                break;

            default:
                hal_fail( "sprintf: unsupported format", pcFmt, 0, 0 );
        }
    }

    *p = '\0';
    va_end( ap );
    return ( int ) ( p - pcOut );
}
