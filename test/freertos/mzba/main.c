/* mzba: M-extension and Zba code under FreeRTOS on HaDes-V+.
 *
 * The golden reference CPU predates M and Zba, so for -march=rv32im[_zba]
 * builds the oracle is this program's own self-checks: every result computed
 * with the native instructions (hw_*, see kernels.c) is compared with the same
 * computation built for plain rv32i (sw_*: libgcc, no Zba).
 *
 *   quiet check  before the scheduler starts (interrupts off): hw == sw for the
 *                operand table and for every array/matrix salt.
 *   divstorm     (M builds only) back-to-back divides with register integrity,
 *                priority 0 next to the RegTest tasks.
 *   mrand0/1     random operands (with 0, +-1, INT_MIN, INT_MAX, powers of 2),
 *                hw_m_ops vs sw_m_ops.
 *   array        hw_array_mix / hw_matmul (div/rem/mul + scaled indexing ->
 *                sh1add/sh2add/sh3add) vs the quiet-check references.
 *   ext IRQ      random short delays so that interrupts land inside divides;
 *                the ISR itself runs hw divides and checks them.
 *   check        progress of every task each FRTOS_CHECK_TICKS; PASS after
 *                FRTOS_NCHECKS periods.
 */
#include "FreeRTOS.h"
#include "task.h"
#include "hades_hal.h"
#include "kernels.h"

#define PRIO_CHECK    5
#define PRIO_MRAND    2
#define PRIO_ARRAY    1
#define PRIO_REG      0

#define DIVSTORM_N    16
#define NSALTS        8

typedef struct
{
    uint32_t a, b;
    MResult_t r;
} DivEntry_t;

DivEntry_t xDivStormTable[ DIVSTORM_N ];   /* read by divstorm.S */
volatile uint32_t ulDivStormCounter;
volatile uint32_t ulRegTest1LoopCounter, ulRegTest2LoopCounter;
extern void vRegTest1Implementation( void );
extern void vRegTest2Implementation( void );
extern void vDivStormTask( void * pv );

static MData_t xData;
static uint32_t ulArrayRef[ NSALTS ], ulMatRef[ NSALTS ];
static volatile uint32_t ulMrand[ 2 ], ulArrayCount, ulIsrCount, ulIsrChecks;
static uint32_t ulIsrSeed;

#define REGTEST1_PARAM    ( ( void * ) 0x12345678 )
#define REGTEST2_PARAM    ( ( void * ) 0x87654321 )
/* Work bursts: each task sleeps MZBA_SLEEP(+0/1) ticks (about MZBA_PERIOD
 * cycles, whatever the tick period) and works for at most MZBA_BUDGET cycles.
 * Without M every divide is a libgcc call and a single iteration is long, so
 * the period is longer. */
#ifdef __OPTIMIZE__
    #define MZBA_KNEE      3000u
#else
    #define MZBA_KNEE      7500u
#endif
/* back off with very short tick periods (see stress/main.c) */
#define MZBA_SCALE         ( ( FRTOS_TICK_CYCLES >= MZBA_KNEE ) ? 1u : \
                             ( MZBA_KNEE + FRTOS_TICK_CYCLES - 1u ) / FRTOS_TICK_CYCLES )
#if defined( __riscv_mul )
    #define MZBA_PERIOD    ( 8000u * MZBA_SCALE )
#else
    #define MZBA_PERIOD    ( 40000u * MZBA_SCALE )
#endif
#ifdef __OPTIMIZE__
    #define MZBA_SLEEP     ( ( MZBA_PERIOD + FRTOS_TICK_CYCLES - 1u ) / FRTOS_TICK_CYCLES )
#else
    #define MZBA_SLEEP     ( ( 5u * MZBA_PERIOD / 2u + FRTOS_TICK_CYCLES - 1u ) / FRTOS_TICK_CYCLES )
#endif
#define MZBA_BUDGET        ( ( uint32_t ) FRTOS_TICK_CYCLES * MZBA_SLEEP / 8u + 200u )

static uint32_t prvOperand( uint32_t * pulSeed )
{
    static const uint32_t ulSpecial[] =
    {
        0u, 1u, 0xFFFFFFFFu, 0x80000000u, 0x7FFFFFFFu, 2u, 0xFFFFFFFEu, 0x80000001u
    };
    uint32_t r = hal_rand( pulSeed );

    switch( r & 7u )
    {
        case 0:
            return ulSpecial[ ( r >> 3 ) & 7u ];

        case 1:
            return 1u << ( ( r >> 3 ) & 31u );

        case 2:
            return ( r >> 3 ) & 0xFFu;   /* small */

        case 3:
            return ( uint32_t ) -( int32_t ) ( ( r >> 3 ) & 0xFFu );

        default:
            return hal_rand( pulSeed );
    }
}

static int prvSame( const MResult_t * x, const MResult_t * y, uint32_t * pulWhich )
{
    const uint32_t * px = &x->div, * py = &y->div;

    for( uint32_t i = 0; i < 8u; i++ )
    {
        if( px[ i ] != py[ i ] )
        {
            *pulWhich = i;
            return 0;
        }
    }

    return 1;
}

static const char * const pcOpNames[ 8 ] =
{
    "div", "divu", "rem", "remu", "mul", "mulh", "mulhsu", "mulhu"
};

/* -------------------------------------------------------------- interrupts */

static inline void prvArmIrq( void )
{
    HADES_TEST_IRQ = 1u + ( hal_rand( &ulIsrSeed ) % ( 2u * MZBA_IRQ_MEAN * MZBA_SCALE ) );
}

void app_external_irq( void )
{
    const DivEntry_t * e = &xDivStormTable[ hal_rand( &ulIsrSeed ) % DIVSTORM_N ];
    MResult_t r;
    uint32_t w;

    prvArmIrq();
    ulIsrCount++;
    hw_m_ops( e->a, e->b, &r );

    if( !prvSame( &r, &e->r, &w ) )
    {
        hal_fail( "ISR: M result differs from the software reference (a, b)", pcOpNames[ w ], e->a, e->b );
    }

    ulIsrChecks++;
}

/* ------------------------------------------------------------------- tasks */

static void prvRegTestEntry1( void * pv )
{
    if( pv == REGTEST1_PARAM )
    {
        vRegTest1Implementation();
    }

    hal_fail( "rt1: wrong task parameter", NULL, 0, 0 );
}

static void prvRegTestEntry2( void * pv )
{
    if( pv == REGTEST2_PARAM )
    {
        vRegTest2Implementation();
    }

    hal_fail( "rt2: wrong task parameter", NULL, 0, 0 );
}

static void prvMrand( void * pv )
{
    const uint32_t id = ( uint32_t ) ( uintptr_t ) pv;
    uint32_t seed = hal_seed() ^ ( 0xAB00u + id );

    for( ; ; )
    {
        const uint32_t ulT0 = hal_mtime();

        do
        {
            uint32_t a = prvOperand( &seed ), b = prvOperand( &seed ), w;
            MResult_t h, s;

            hw_m_ops( a, b, &h );
            sw_m_ops( a, b, &s );

            if( !prvSame( &h, &s, &w ) )
            {
                hal_fail( "mrand: M result differs from the software reference (a, b)", pcOpNames[ w ], a, b );
            }

            ulMrand[ id ]++;
        } while( ( hal_mtime() - ulT0 ) < MZBA_BUDGET );

        vTaskDelay( MZBA_SLEEP + ( hal_rand( &seed ) & 1u ) );
    }
}

static void prvArray( void * pv )
{
    uint32_t seed = hal_seed() ^ 0xA77Au, ulLastLine = hal_mtime();

    ( void ) pv;

    for( ; ; )
    {
        if( ( hal_mtime() - ulLastLine ) > 100000u * MZBA_SCALE )
        {
            hal_pattern_line();   /* UART transcript check, see hades_hal.h */
            ulLastLine = hal_mtime();
        }

        const uint32_t ulT0 = hal_mtime();

        do
        {
            uint32_t r = hal_rand( &seed ), s = r % NSALTS, v;

            if( ( r & 0x100u ) != 0u )
            {
                if( ( v = hw_array_mix( &xData, s ) ) != ulArrayRef[ s ] )
                {
                    hal_fail( "array: hw_array_mix differs from the rv32i reference (got, expected)", NULL, v, ulArrayRef[ s ] );
                }
            }
            else if( ( v = hw_matmul( &xData, s ) ) != ulMatRef[ s ] )
            {
                hal_fail( "array: hw_matmul differs from the rv32i reference (got, expected)", NULL, v, ulMatRef[ s ] );
            }

            ulArrayCount++;
        } while( ( hal_mtime() - ulT0 ) < MZBA_BUDGET );

        vTaskDelay( MZBA_SLEEP + ( hal_rand( &seed ) & 1u ) );
    }
}

static void prvCheck( void * pv )
{
    enum { N = 7 };
    static const char * const pcNames[ N ] = { "rt1", "rt2", "divstorm", "mrand0", "mrand1", "array", "ext-irq" };
    uint32_t last[ N ] = { 0 };
    TickType_t xWake = xTaskGetTickCount();

    ( void ) pv;

    for( uint32_t n = 1; n <= FRTOS_NCHECKS; n++ )
    {
        uint32_t now[ N ];

        vTaskDelayUntil( &xWake, FRTOS_CHECK_TICKS );
        now[ 0 ] = ulRegTest1LoopCounter;
        now[ 1 ] = ( configUSE_PREEMPTION == 1 ) ? ulRegTest2LoopCounter : n;
        #ifdef __riscv_mul
            now[ 2 ] = ulDivStormCounter;
        #else
            now[ 2 ] = n;
        #endif
        now[ 3 ] = ulMrand[ 0 ];
        now[ 4 ] = ulMrand[ 1 ];
        now[ 5 ] = ulArrayCount;
        now[ 6 ] = ulIsrCount;

        for( int i = 0; i < N; i++ )
        {
            if( now[ i ] == last[ i ] )
            {
                hal_fail( "no progress in a check period (task/counter, period)", pcNames[ i ], ( uint32_t ) i, n );
            }

            last[ i ] = now[ i ];
        }

        hal_pattern_line();
    }

    hal_puts( "  ticks=" );
    hal_putdec( xTaskGetTickCount() );
    hal_puts( " divstorm=" );
    hal_putdec( ulDivStormCounter );
    hal_puts( " mrand=" );
    hal_putdec( ulMrand[ 0 ] + ulMrand[ 1 ] );
    hal_puts( " array=" );
    hal_putdec( ulArrayCount );
    hal_puts( " isr=" );
    hal_putdec( ulIsrCount );
    hal_puts( " rt1=" );
    hal_putdec( ulRegTest1LoopCounter );
    hal_puts( " rt2=" );
    hal_putdec( ulRegTest2LoopCounter );
    hal_puts( "\n  isr-stack-peak=" );
    hal_putdec( hal_isr_stack_peak() );
    hal_putc( '/' );
    hal_putdec( hal_isr_stack_size() );
    hal_pass();
}

/* -------------------------------------------------------------------- main */

static void prvCreate( TaskFunction_t f, const char * name, uint32_t words, void * pv, UBaseType_t prio )
{
    if( xTaskCreate( f, name, ( configSTACK_DEPTH_TYPE ) words, pv, prio, NULL ) != pdPASS )
    {
        hal_fail( "xTaskCreate failed", name, words, 0 );
    }
}

int main( void )
{
    uint32_t seed = hal_seed();

    hal_begin( "mzba (M + Zba under the RTOS)" );
    ulIsrSeed = seed ^ 0xD1D1u;

    /* Operand table (fixed corner cases first, then random) and array data. */
    {
        static const uint32_t ulA[ 6 ] = { 0x80000000u, 0x80000000u, 7u, 0xFFFFFFF9u, 0u, 0x7FFFFFFFu };
        static const uint32_t ulB[ 6 ] = { 0xFFFFFFFFu, 0u, 0u, 2u, 0xFFFFFFFFu, 0x80000000u };

        for( uint32_t i = 0; i < DIVSTORM_N; i++ )
        {
            xDivStormTable[ i ].a = ( i < 6u ) ? ulA[ i ] : prvOperand( &seed );
            xDivStormTable[ i ].b = ( i < 6u ) ? ulB[ i ] : prvOperand( &seed );
            sw_m_ops( xDivStormTable[ i ].a, xDivStormTable[ i ].b, &xDivStormTable[ i ].r );
        }

        for( uint32_t i = 0; i < MZBA_N; i++ )
        {
            xData.a32[ i ] = hal_rand( &seed );
            xData.a16[ i ] = ( uint16_t ) hal_rand( &seed );
            xData.a64[ i ] = ( ( uint64_t ) hal_rand( &seed ) << 32 ) | hal_rand( &seed );
        }

        for( uint32_t i = 0; i < MZBA_MAT; i++ )
        {
            for( uint32_t j = 0; j < MZBA_MAT; j++ )
            {
                xData.ma[ i ][ j ] = ( int32_t ) hal_rand( &seed );
                xData.mb[ i ][ j ] = ( int32_t ) hal_rand( &seed );
            }
        }
    }

    /* Quiet check: native instructions vs software, no interrupts yet. */
    for( uint32_t i = 0; i < DIVSTORM_N; i++ )
    {
        MResult_t r;
        uint32_t w;

        hw_m_ops( xDivStormTable[ i ].a, xDivStormTable[ i ].b, &r );

        if( !prvSame( &r, &xDivStormTable[ i ].r, &w ) )
        {
            hal_fail( "quiet check: M result differs from the software reference (a, b)", pcOpNames[ w ], xDivStormTable[ i ].a, xDivStormTable[ i ].b );
        }
    }

    for( uint32_t s = 0; s < NSALTS; s++ )
    {
        ulArrayRef[ s ] = sw_array_mix( &xData, s );
        ulMatRef[ s ] = sw_matmul( &xData, s );

        if( hw_array_mix( &xData, s ) != ulArrayRef[ s ] )
        {
            hal_fail( "quiet check: hw_array_mix differs from the rv32i reference (salt, expected)", NULL, s, ulArrayRef[ s ] );
        }

        if( hw_matmul( &xData, s ) != ulMatRef[ s ] )
        {
            hal_fail( "quiet check: hw_matmul differs from the rv32i reference (salt, expected)", NULL, s, ulMatRef[ s ] );
        }
    }

    hal_puts( "  quiet check passed\n" );

    prvCreate( prvCheck, "check", 2 * configMINIMAL_STACK_SIZE, NULL, PRIO_CHECK );
    prvCreate( prvMrand, "mrand0", configMINIMAL_STACK_SIZE, ( void * ) 0, PRIO_MRAND );
    prvCreate( prvMrand, "mrand1", configMINIMAL_STACK_SIZE, ( void * ) 1, PRIO_ARRAY );
    prvCreate( prvArray, "array", configMINIMAL_STACK_SIZE, NULL, PRIO_ARRAY );
    prvCreate( prvRegTestEntry1, "rt1", 90, REGTEST1_PARAM, PRIO_REG );
    #if ( configUSE_PREEMPTION == 1 )
        prvCreate( prvRegTestEntry2, "rt2", 90, REGTEST2_PARAM, PRIO_REG );
    #endif
    #ifdef __riscv_mul
        prvCreate( vDivStormTask, "divstorm", 64, NULL, PRIO_REG );
    #endif

    prvArmIrq();
    vTaskStartScheduler();
    hal_fail( "vTaskStartScheduler returned", NULL, 0, 0 );
}
