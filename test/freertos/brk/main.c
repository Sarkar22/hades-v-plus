/* brk: RTOS-level breaker program for HaDes-V+.
 *
 * Everything below runs at the same time; all timing is randomised by the run
 * seed (+switches=<hex>). Every check is architectural (it must hold on any
 * correct RV32 core running this ELF), so the golden reference CPU is a valid
 * twin for the rv32i builds.
 *
 *   ext IRQ    wishbone_test interrupt re-armed from its own ISR. Profiles:
 *              storms (bursts of 1..150-cycle intervals, far shorter than the
 *              tick), dense, "re-fire inside the handler" (1..8 cycles) and
 *              tick-beating. The ISR writes sequence bytes into a stream buffer
 *              and framed messages into a message buffer (FromISR), drains a
 *              task->ISR stream buffer and checks its sequence, and gives a
 *              counting semaphore.
 *   sbrx/mbrx  receive and check the ISR's stream / message buffer contents.
 *   sbtx       writes a byte sequence into the task->ISR stream buffer.
 *   tpast      mtimecmp written into the past, to 0, or a few cycles into the
 *              future inside a critical section; critical sections that span
 *              1..3 tick periods (the port then programs mtimecmp in the past
 *              and the ticks catch up back to back).
 *   nest       critical sections nested 1..8 deep (checks MIE and
 *              xCriticalNesting at every level, taskYIELD() at random depths),
 *              nested vTaskSuspendAll().
 *   dis        portDISABLE_INTERRUPTS(); taskYIELD(); -- must come back with
 *              MIE=0 and no interrupt handler may run until it re-enables.
 *   spawn      creates 1..4 workers at random priorities (1..7) that work,
 *              yield, block, and end by vTaskDelete(NULL); others are deleted
 *              by the spawner while blocked, and spinners while ready/running.
 *              The heap and the task count must return to their baselines.
 *   pi_l/m/h   priority-inheritance chain: L holds A, M holds B and blocks on
 *              A, H blocks on B (sometimes with a timeout); hogs at 3 and 5.
 *              Priorities checked at every step against FreeRTOS semantics.
 *   fi0/fi1    self-modifying code: write a routine into a RAM buffer,
 *              fence.i, call it (incl. a buffer that starts with fence.i and
 *              whose next word was just patched, and a patched counted loop).
 *   bpdyn      (BRK_BPDYN) random MHPMEVENT10 writes = branch-predictor mode
 *              changes at run time (the golden CPU ignores this CSR).
 *   pipe       pipebrk.S register-integrity task (divides next to CSR/ECALL/
 *              slow bus/fence.i with M).
 *   rt1-3      official port RegTest tasks + RegTest3.
 *   idle hook  VGA / stall-register accesses, checks MIE=1.
 *   check      progress of every task, ISR accounting, tick drift vs mtime.
 */
#include <string.h>
#include "FreeRTOS.h"
#include "task.h"
#include "queue.h"
#include "semphr.h"
#include "stream_buffer.h"
#include "message_buffer.h"
#include "hades_hal.h"

#define PRIO_CHECK    9
#define PRIO_SBRX     8
#define PRIO_MBRX     7
#define PRIO_PIH      6
#define PRIO_SPAWN    5
#define PRIO_HOG5     5
#define PRIO_PIM      4
#define PRIO_HOG3     3
#define PRIO_TPAST    3
#define PRIO_PIL      2
#define PRIO_NEST     2
#define PRIO_DIS      2
#define PRIO_LOW      1
#define PRIO_REG      0

enum
{
    C_RT1, C_RT2, C_RT3, C_SBRX, C_MBRX, C_SBTX, C_TPAST, C_NEST, C_DIS, C_SPAWN,
    C_PI, C_FI0, C_FI1, C_BPDYN, C_PIPE, C_EXC, C_IDLE, C_TICKHOOK, C_EXTIRQ, C_ISRSEM, C_NUM
};
static const char * const pcNames[ C_NUM ] =
{
    "rt1", "rt2", "rt3", "sbrx", "mbrx", "sbtx", "tpast", "nest", "dis", "spawn",
    "pi", "fi0", "fi1", "bpdyn", "pipe", "exc", "idle", "tick-hook", "ext-irq", "isrsem"
};

volatile uint32_t ulRegTest1LoopCounter, ulRegTest2LoopCounter, ulRegTest3Counter;
extern volatile uint32_t ulPipeBrkCounter;
extern void vRegTest1Implementation( void );
extern void vRegTest2Implementation( void );
extern void vRegTest3Task( void * pv );
extern void vPipeBrkTask( void * pv );
extern size_t xCriticalNesting;

static volatile uint32_t ulCount[ C_NUM ];
static volatile uint32_t ulIrqEvents;           /* every ISR entry (tick hook + ext) */
static volatile uint32_t ulIsrGives, ulSemTaken;
static uint32_t ulIsrSeed, ulIrqProfile;

/* ------------------------------------------------------------------ timing */
/* Periodic tasks sleep BRK_SLEEP ticks (about BRK_PERIOD cycles, whatever the
 * tick) and burn at most BRK_BUDGET cycles per burst. */
#ifdef __OPTIMIZE__
    #define BRK_KNEE      6000u
    #define BRK_PERIOD    ( 30000u * BRK_SCALE )
#else
    #define BRK_KNEE      7500u
    #define BRK_PERIOD    ( 75000u * BRK_SCALE )
#endif
#define BRK_SCALE         ( ( FRTOS_TICK_CYCLES >= BRK_KNEE ) ? 1u : \
                            ( BRK_KNEE + FRTOS_TICK_CYCLES - 1u ) / FRTOS_TICK_CYCLES )
#define BRK_SLEEP         ( ( BRK_PERIOD + FRTOS_TICK_CYCLES - 1u ) / FRTOS_TICK_CYCLES )
#define BRK_BUDGET        ( ( uint32_t ) FRTOS_TICK_CYCLES * BRK_SLEEP / 40u + 200u )
#define BRK_UART_PERIOD   ( 150000u * BRK_SCALE )
static inline int prvBudgetLeft( uint32_t ulT0 )
{
    return ( hal_mtime() - ulT0 ) < BRK_BUDGET;
}

/* The longest stretch with interrupts off that tpast creates, in ticks; the
 * tick-drift tolerance of the check task includes it. */
#define TPAST_MAX_TICKS   3u

/* ------------------------------------------------ stream / message buffers */
#define SB_SIZE           64
#define MB_SIZE           128
#define SBIN_SIZE         32
#define MSG_MAX           24
static StreamBufferHandle_t xSb, xSbIn;
static MessageBufferHandle_t xMb;
static uint8_t ucSbSeq;                          /* ISR: next byte to send */
static uint16_t usMbSeq;                         /* ISR: next message number */
static uint8_t ucInSeqExpect;                    /* ISR: next byte expected from sbtx */
static volatile uint32_t ulSbSent, ulSbShort, ulMbSent, ulMbFull, ulInRecv;
static SemaphoreHandle_t xIsrSem;

static uint8_t prvMsgByte( uint16_t seq, uint32_t i )
{
    return ( uint8_t ) ( ( seq * 7u ) ^ ( i * 29u ) ^ 0x5Au );
}

/* ---------------------------------------------------------------- the ISR */
static uint32_t ulStormLeft, ulStorms, ulIrqMin, ulIrqSpan;
#ifdef __OPTIMIZE__
    #define IRQ_CALM_FLOOR    15000u
#else
    #define IRQ_CALM_FLOOR    37000u
#endif

static void prvIrqSite( void );

/* a storm starts after a calm interrupt with probability 1/(BRK_STORM_MASK+1) */
#ifndef BRK_STORM_MASK
    #define BRK_STORM_MASK    0x1Fu
#endif

static uint32_t prvNextDelay( void )
{
    uint32_t r = hal_rand( &ulIsrSeed );

    switch( ulIrqProfile )
    {
        case 0: /* storms: bursts far shorter than the tick, then calm */
        case 1:
            if( ulStormLeft != 0u )
            {
                ulStormLeft--;
                return 1u + ( r % ( ( ulIrqProfile == 0 ) ? 150u : 8u ) );   /* 1: re-fire inside the handler */
            }

            if( ( r & BRK_STORM_MASK ) == 0u )
            {
                ulStormLeft = 4u + ( ( r >> 8 ) % 40u );
                ulStorms++;
            }

            return IRQ_CALM_FLOOR * BRK_SCALE + ( ( r >> 12 ) % ( 2u * IRQ_CALM_FLOOR * BRK_SCALE ) );

        case 2: /* dense, uniform */
            return ulIrqMin + ( r % ulIrqSpan );

        default: /* close to a multiple of the tick period: beats slowly against it */
            return ( ( FRTOS_TICK_CYCLES * ( 1u + IRQ_CALM_FLOOR * BRK_SCALE / FRTOS_TICK_CYCLES ) ) - 37u ) + ( r % 75u );
    }
}

void app_external_irq( void )
{
    BaseType_t xWoken = pdFALSE;
    uint32_t r = hal_rand( &ulIsrSeed );
    uint8_t buf[ MSG_MAX ];
    size_t n, k;

    HADES_TEST_IRQ = prvNextDelay();   /* re-arm; also drops the level */
    prvIrqSite();
    ulIrqEvents++;
    ulCount[ C_EXTIRQ ]++;

    /* 1..6 sequence bytes into the stream buffer (partial writes allowed) */
    k = 1u + ( r % 6u );

    for( size_t i = 0; i < k; i++ )
    {
        buf[ i ] = ( uint8_t ) ( ucSbSeq + i );
    }

    n = xStreamBufferSendFromISR( xSb, buf, k, &xWoken );
    ucSbSeq = ( uint8_t ) ( ucSbSeq + n );
    ulSbSent += n;

    if( n < k )
    {
        ulSbShort++;
    }

    /* every other interrupt: one framed message (all or nothing) */
    if( ( r & 0x100u ) != 0u )
    {
        size_t len = 3u + ( ( r >> 10 ) % ( MSG_MAX - 3u ) );
        buf[ 0 ] = ( uint8_t ) len;
        buf[ 1 ] = ( uint8_t ) usMbSeq;
        buf[ 2 ] = ( uint8_t ) ( usMbSeq >> 8 );

        for( size_t i = 3; i < len; i++ )
        {
            buf[ i ] = prvMsgByte( usMbSeq, i );
        }

        if( xMessageBufferSendFromISR( xMb, buf, len, &xWoken ) == len )
        {
            usMbSeq++;
            ulMbSent++;
        }
        else
        {
            ulMbFull++;
        }
    }

    /* drain 1..4 bytes that sbtx wrote */
    n = xStreamBufferReceiveFromISR( xSbIn, buf, 1u + ( ( r >> 20 ) & 3u ), &xWoken );

    for( size_t i = 0; i < n; i++ )
    {
        if( buf[ i ] != ucInSeqExpect )
        {
            hal_fail( "ISR: task->ISR stream buffer sequence error (got, expected)", NULL, buf[ i ], ucInSeqExpect );
        }

        ucInSeqExpect++;
    }

    ulInRecv += n;

    if( xSemaphoreGiveFromISR( xIsrSem, &xWoken ) == pdTRUE )
    {
        ulIsrGives++;
    }

    #if ( configUSE_PREEMPTION == 1 )
        portYIELD_FROM_ISR( xWoken );
    #else
        ( void ) xWoken;
    #endif
}

/* Coverage: interrupts whose return address (mepc) is a divide / an M op,
 * i.e. the divide was abandoned by the trap and is re-executed after mret,
 * or the interrupt was taken right at it. mepc is still the interrupted PC
 * inside the handler. */
static volatile uint32_t ulIrqAtDiv, ulIrqAtMul, ulIrqAtEcall, ulIrqAtCsr, ulIrqAtFenceI;
static void prvIrqSite( void )
{
    uint32_t pc, insn;

    __asm volatile ( "csrr %0, mepc" : "=r" ( pc ) );

    if( ( pc & 3u ) != 0u )
    {
        return;
    }

    insn = *( const volatile uint32_t * ) ( uintptr_t ) pc;

    if( ( ( insn & 0x7Fu ) == 0x33u ) && ( ( insn >> 25 ) == 1u ) )
    {
        if( ( ( insn >> 12 ) & 7u ) >= 4u )
        {
            ulIrqAtDiv++;
        }
        else
        {
            ulIrqAtMul++;
        }
    }
    else if( insn == 0x00000073u )
    {
        ulIrqAtEcall++;
    }
    else if( ( ( insn & 0x7Fu ) == 0x73u ) && ( ( ( insn >> 12 ) & 7u ) != 0u ) )
    {
        ulIrqAtCsr++;
    }
    else if( insn == 0x0000100Fu )
    {
        ulIrqAtFenceI++;
    }
}

void vApplicationTickHook( void )
{
    prvIrqSite();
    ulIrqEvents++;
    ulCount[ C_TICKHOOK ]++;
}

void vApplicationIdleHook( void )
{
    ulCount[ C_IDLE ]++;

    if( ( hal_mstatus() & HADES_MSTATUS_MIE ) == 0u )
    {
        hal_fail( "idle: MIE=0 (interrupt JUMP lost / yield with MIE=0 leaked?)", NULL, hal_mstatus(), 0 );
    }

    #if ( BRK_WFI == 1 )
        __asm volatile ( "wfi" );
    #endif

    #if ( BRK_SLOWBUS == 1 )
    {
        static uint32_t ulSlow = 0x2545F491u;
        const uint32_t v = hal_rand( &ulSlow );

        HADES_VGA_WORD0 = v;
        HADES_TEST_STALL = ~v;

        if( ( HADES_VGA_WORD0 != v ) || ( HADES_TEST_STALL != ~v ) )
        {
            hal_fail( "idle: slow-bus read-back (VGA, stall)", NULL, HADES_VGA_WORD0, HADES_TEST_STALL );
        }
    }
    #endif
}

/* --------------------------------------------------------- buffer tasks */
static void prvSbRx( void * pv )
{
    uint32_t seed = hal_seed() ^ 0xA1u;
    uint8_t expect = 0, buf[ 16 ];

    ( void ) pv;

    for( ; ; )
    {
        size_t n = xStreamBufferReceive( xSb, buf, 1u + ( hal_rand( &seed ) & 15u ), portMAX_DELAY );

        if( n == 0u )
        {
            hal_fail( "sbrx: xStreamBufferReceive(portMAX_DELAY) returned 0 bytes (blocking yield lost?)", NULL, expect, 0 );
        }

        for( size_t i = 0; i < n; i++ )
        {
            if( buf[ i ] != expect )
            {
                hal_fail( "sbrx: stream buffer sequence error (got, expected)", NULL, buf[ i ], expect );
            }

            expect++;
        }

        ulCount[ C_SBRX ] += n;
    }
}

static void prvMbRx( void * pv )
{
    uint16_t expect = 0;
    uint8_t buf[ MSG_MAX ];

    ( void ) pv;

    for( ; ; )
    {
        size_t n = xMessageBufferReceive( xMb, buf, sizeof( buf ), portMAX_DELAY );

        if( n == 0u )
        {
            hal_fail( "mbrx: xMessageBufferReceive(portMAX_DELAY) returned 0 (blocking yield lost?)", NULL, expect, 0 );
        }

        if( ( n < 3u ) || ( buf[ 0 ] != n ) || ( ( uint16_t ) ( buf[ 1 ] | ( buf[ 2 ] << 8 ) ) != expect ) )
        {
            hal_fail( "mbrx: message header error (len/seq word, expected seq)", NULL,
                      ( uint32_t ) n | ( ( uint32_t ) buf[ 0 ] << 8 ) | ( ( uint32_t ) buf[ 1 ] << 16 ) | ( ( uint32_t ) buf[ 2 ] << 24 ), expect );
        }

        for( size_t i = 3; i < n; i++ )
        {
            if( buf[ i ] != prvMsgByte( expect, i ) )
            {
                hal_fail( "mbrx: message payload error (index, seq)", NULL, i, expect );
            }
        }

        expect++;
        ulCount[ C_MBRX ]++;
    }
}

static void prvSbTx( void * pv )
{
    uint32_t seed = hal_seed() ^ 0xB2u, ulLastLine = hal_mtime();
    uint8_t seq = 0, buf[ 8 ];

    ( void ) pv;

    for( ; ; )
    {
        size_t k = 1u + ( hal_rand( &seed ) & 7u ), n;

        if( ( hal_mtime() - ulLastLine ) > BRK_UART_PERIOD )
        {
            hal_pattern_line();
            ulLastLine = hal_mtime();
        }

        for( size_t i = 0; i < k; i++ )
        {
            buf[ i ] = ( uint8_t ) ( seq + i );
        }

        /* the ISR is the only reader; with interrupts off for long periods the
         * buffer may stay full for a while -- block with a timeout */
        n = xStreamBufferSend( xSbIn, buf, k, BRK_SLEEP );
        seq = ( uint8_t ) ( seq + n );
        ulCount[ C_SBTX ] += n;

        if( n == 0u )
        {
            vTaskDelay( 1 );
        }
    }
}

/* ------------------------------------------------------------------ tpast */
static volatile uint32_t ulEarlyTicks, ulLongCrit;

static void prvSetMtimecmp( uint32_t hi, uint32_t lo )
{
    volatile uint32_t * const pCmp = ( volatile uint32_t * ) configMTIMECMP_BASE_ADDRESS;

    pCmp[ 0 ] = 0xFFFFFFFFu;
    pCmp[ 1 ] = hi;
    pCmp[ 0 ] = lo;
}

static void prvTPast( void * pv )
{
    uint32_t seed = hal_seed() ^ 0xC3u;

    ( void ) pv;

    for( ; ; )
    {
        uint32_t r = hal_rand( &seed );

        switch( r & 7u )
        {
            case 0: /* a critical section 1..TPAST_MAX_TICKS tick periods long */
               {
                   uint32_t t0, len = FRTOS_TICK_CYCLES * ( 1u + ( ( r >> 3 ) % TPAST_MAX_TICKS ) ) + ( ( r >> 8 ) % FRTOS_TICK_CYCLES );

                   taskENTER_CRITICAL();
                   t0 = hal_mtime();

                   while( ( hal_mtime() - t0 ) < len )
                   {
                   }

                   taskEXIT_CRITICAL();
                   ulLongCrit++;
                   break;
               }

            case 2: /* mtimecmp far in the past (0) */
                taskENTER_CRITICAL();
                prvSetMtimecmp( 0, 0 );
                ulEarlyTicks++;
                taskEXIT_CRITICAL();   /* the timer interrupt is taken right here */
                break;

            case 3: /* mtimecmp a little in the past */
               {
                   taskENTER_CRITICAL();
                   uint32_t hi = HADES_MTIME_HI, lo = HADES_MTIME_LO;

                   if( lo > 5000u )
                   {
                       prvSetMtimecmp( hi, lo - ( ( r >> 4 ) % 5000u ) );
                       ulEarlyTicks++;
                   }

                   taskEXIT_CRITICAL();
                   break;
               }

            case 4: /* mtimecmp a few cycles into the future: the tick lands at
                     * a random point of the code right after the exit */
            case 5:
               {
                   taskENTER_CRITICAL();
                   uint32_t hi = HADES_MTIME_HI, lo = HADES_MTIME_LO, d = 30u + ( ( r >> 4 ) % 90u );

                   if( lo < 0xFFFF0000u )
                   {
                       prvSetMtimecmp( hi, lo + d );
                       ulEarlyTicks++;
                   }

                   taskEXIT_CRITICAL();
                   hal_spin( ( r >> 12 ) & 63u );
                   break;
               }

            default:
                break;
        }

        ulCount[ C_TPAST ]++;
        vTaskDelay( 2u * BRK_SLEEP + ( ( r >> 20 ) % ( 4u * BRK_SLEEP + 1u ) ) );
    }
}

/* ------------------------------------------------------------------- nest */
static void prvNest( void * pv )
{
    uint32_t seed = hal_seed() ^ 0xD4u;

    ( void ) pv;

    for( ; ; )
    {
        const uint32_t ulT0 = hal_mtime();

        do
        {
            uint32_t r = hal_rand( &seed ), depth = 1u + ( r & 7u ), ulSnap;
            const size_t xBase = xCriticalNesting;

            if( xBase != 0u )
            {
                hal_fail( "nest: xCriticalNesting != 0 outside a critical section", NULL, xBase, 0 );
            }

            for( uint32_t d = 1; d <= depth; d++ )
            {
                taskENTER_CRITICAL();

                if( ( hal_mstatus() & HADES_MSTATUS_MIE ) != 0u )
                {
                    hal_fail( "nest: MIE=1 inside a critical section (depth, mstatus)", NULL, d, hal_mstatus() );
                }

                if( xCriticalNesting != d )
                {
                    hal_fail( "nest: xCriticalNesting wrong (got, depth)", NULL, xCriticalNesting, d );
                }

                if( ( ( r >> ( 3 + d ) ) & 3u ) == 0u )
                {
                    taskYIELD();

                    if( ( ( hal_mstatus() & HADES_MSTATUS_MIE ) != 0u ) || ( xCriticalNesting != d ) )
                    {
                        hal_fail( "nest: MIE=1 or nesting changed after taskYIELD() in a critical section (depth, mstatus)", NULL, d, hal_mstatus() );
                    }
                }
            }

            ulSnap = ulIrqEvents;
            hal_spin( ( r >> 16 ) & 31u );

            if( ulIrqEvents != ulSnap )
            {
                hal_fail( "nest: an interrupt handler ran inside a critical section", NULL, depth, ulIrqEvents - ulSnap );
            }

            for( uint32_t d = depth; d >= 1u; d-- )
            {
                taskEXIT_CRITICAL();

                if( d > 1u )
                {
                    if( ( hal_mstatus() & HADES_MSTATUS_MIE ) != 0u )
                    {
                        hal_fail( "nest: MIE=1 before the outermost taskEXIT_CRITICAL (depth)", NULL, d, hal_mstatus() );
                    }
                }
                else if( ( hal_mstatus() & HADES_MSTATUS_MIE ) == 0u )
                {
                    hal_fail( "nest: MIE=0 after the outermost taskEXIT_CRITICAL", NULL, depth, hal_mstatus() );
                }
            }

            /* nested scheduler suspension with a critical section inside */
            if( ( r & 0x3000000u ) == 0u )
            {
                uint32_t k = 1u + ( ( r >> 26 ) & 3u );

                for( uint32_t i = 0; i < k; i++ )
                {
                    vTaskSuspendAll();
                }

                taskENTER_CRITICAL();
                hal_spin( 8 );
                taskEXIT_CRITICAL();

                if( ( hal_mstatus() & HADES_MSTATUS_MIE ) == 0u )
                {
                    hal_fail( "nest: MIE=0 with the scheduler suspended", NULL, k, hal_mstatus() );
                }

                for( uint32_t i = 0; i < k; i++ )
                {
                    ( void ) xTaskResumeAll();
                }
            }

            ulCount[ C_NEST ]++;
        } while( prvBudgetLeft( ulT0 ) );

        vTaskDelay( BRK_SLEEP + ( hal_rand( &seed ) & 1u ) );
    }
}

/* -------------------------------------------------------------------- dis */
static void prvDis( void * pv )
{
    uint32_t seed = hal_seed() ^ 0xE5u;

    ( void ) pv;

    for( ; ; )
    {
        const uint32_t ulT0 = hal_mtime();

        do
        {
            uint32_t r = hal_rand( &seed ), ulSnap;

            portDISABLE_INTERRUPTS();

            if( ( hal_mstatus() & HADES_MSTATUS_MIE ) != 0u )
            {
                hal_fail( "dis: MIE=1 right after portDISABLE_INTERRUPTS()", NULL, r, hal_mstatus() );
            }

            if( ( r & 1u ) != 0u )
            {
                taskYIELD();   /* ECALL with MIE=0, xCriticalNesting=0 */

                if( ( hal_mstatus() & HADES_MSTATUS_MIE ) != 0u )
                {
                    hal_fail( "dis: MIE=1 after taskYIELD() with interrupts disabled", NULL, r, hal_mstatus() );
                }
            }

            ulSnap = ulIrqEvents;
            hal_spin( ( r >> 4 ) & 63u );

            if( ulIrqEvents != ulSnap )
            {
                hal_fail( "dis: an interrupt handler ran with interrupts disabled", NULL, r, ulIrqEvents - ulSnap );
            }

            if( ( r & 6u ) == 0u )
            {
                taskYIELD();   /* twice in a row */

                if( ( hal_mstatus() & HADES_MSTATUS_MIE ) != 0u )
                {
                    hal_fail( "dis: MIE=1 after a second taskYIELD() with interrupts disabled", NULL, r, hal_mstatus() );
                }
            }

            portENABLE_INTERRUPTS();

            if( ( hal_mstatus() & HADES_MSTATUS_MIE ) == 0u )
            {
                hal_fail( "dis: MIE=0 right after portENABLE_INTERRUPTS()", NULL, r, hal_mstatus() );
            }

            ulCount[ C_DIS ]++;
        } while( prvBudgetLeft( ulT0 ) );

        vTaskDelay( BRK_SLEEP + ( hal_rand( &seed ) & 1u ) );
    }
}

/* ------------------------------------------------------------------ churn */
#define MAX_WORKERS    4
static TaskHandle_t xSpawner;
static TaskHandle_t xWorker[ MAX_WORKERS ];
static volatile uint32_t ulWorkerDone[ MAX_WORKERS ];
static volatile uint32_t ulSelfDeletes, ulOtherDeletes, ulRunningDeletes;
static SemaphoreHandle_t xWorkSem;   /* counting, shared by the workers */

typedef enum
{
    W_SELF = 0,   /* works, then vTaskDelete( NULL ) */
    W_BLOCK,      /* works, then blocks forever; the spawner deletes it */
    W_SPIN        /* spins forever (never blocks); the spawner deletes it while ready/running */
} WorkerMode_t;

static void prvWorker( void * pv )
{
    const uint32_t id = ( uint32_t ) ( uintptr_t ) pv & 0xFFu, mode = ( ( uint32_t ) ( uintptr_t ) pv >> 8 ) & 0xFFu;
    uint32_t seed = hal_seed() ^ ( 0xF00u + id + ( hal_mtime() << 8 ) );
    uint32_t n = 1u + ( hal_rand( &seed ) & 7u );

    if( mode == W_SPIN )
    {
        ulWorkerDone[ id ] = 1;
        xTaskNotifyGiveIndexed( xSpawner, 1 );

        for( ; ; )
        {
            hal_spin( 16 );

            if( ( hal_rand( &seed ) & 7u ) == 0u )
            {
                taskYIELD();
            }
        }
    }

    while( n-- != 0u )
    {
        uint32_t r = hal_rand( &seed );

        switch( r & 3u )
        {
            case 0:
                hal_spin( ( r >> 4 ) & 255u );
                break;

            case 1:
                taskYIELD();
                break;

            case 2:
                vTaskDelay( ( r >> 4 ) % 3u );
                break;

            default:
                if( xSemaphoreTake( xWorkSem, ( r >> 4 ) % 3u ) == pdTRUE )
                {
                    hal_spin( ( r >> 8 ) & 31u );
                    xSemaphoreGive( xWorkSem );
                }

                break;
        }
    }

    ulWorkerDone[ id ] = 1;
    xTaskNotifyGiveIndexed( xSpawner, 1 );

    if( mode == W_SELF )
    {
        ulSelfDeletes++;
        vTaskDelete( NULL );
        hal_fail( "worker: vTaskDelete(NULL) returned", NULL, id, 0 );
    }

    ( void ) ulTaskNotifyTakeIndexed( 2, pdTRUE, portMAX_DELAY );
    hal_fail( "worker: woke up from an infinite block (should have been deleted)", NULL, id, mode );
}

static void prvSpawn( void * pv )
{
    uint32_t seed = hal_seed() ^ 0x5A5Au;
    size_t xHeapBase = 0;
    UBaseType_t uxTasksBase = 0;

    ( void ) pv;
    vTaskDelay( 2 );

    for( uint32_t iter = 0; ; iter++ )
    {
        uint32_t r = hal_rand( &seed ), nw = 1u + ( r & 3u ), mode[ MAX_WORKERS ];

        if( iter == 0 )
        {
            xHeapBase = xPortGetFreeHeapSize();
            uxTasksBase = uxTaskGetNumberOfTasks();
        }

        ( void ) ulTaskNotifyValueClearIndexed( NULL, 1, 0xFFFFFFFFu );

        for( uint32_t i = 0; i < nw; i++ )
        {
            uint32_t rr = hal_rand( &seed );
            UBaseType_t prio = 1u + ( rr % 7u );

            mode[ i ] = ( rr >> 8 ) % 3u;

            if( mode[ i ] == W_SPIN )
            {
                prio = 0;   /* a spinner above the other workers (or us) would starve them */
            }

            ulWorkerDone[ i ] = 0;

            if( xTaskCreate( prvWorker, "wrk", configMINIMAL_STACK_SIZE, ( void * ) ( uintptr_t ) ( i | ( mode[ i ] << 8 ) ), prio, &xWorker[ i ] ) != pdPASS )
            {
                hal_fail( "spawn: xTaskCreate failed (worker, free heap)", NULL, i, xPortGetFreeHeapSize() );
            }
        }

        /* wait for every worker to report (spinners report at once) */
        for( uint32_t got = 0; got < nw; )
        {
            uint32_t v = ulTaskNotifyTakeIndexed( 1, pdFALSE, BRK_SLEEP * 40u );

            if( v == 0u )
            {
                hal_fail( "spawn: workers did not report within 40 periods (reported, created)", NULL, got, nw );
            }

            got++;
        }

        for( uint32_t i = 0; i < nw; i++ )
        {
            if( ulWorkerDone[ i ] != 1u )
            {
                hal_fail( "spawn: worker done flag missing", NULL, i, mode[ i ] );
            }

            if( mode[ i ] == W_BLOCK )
            {
                vTaskDelete( xWorker[ i ] );
                ulOtherDeletes++;
            }
            else if( mode[ i ] == W_SPIN )
            {
                hal_spin( hal_rand( &seed ) & 127u );
                vTaskDelete( xWorker[ i ] );   /* ready, never blocked */
                ulRunningDeletes++;
            }
        }

        /* the idle task frees deleted TCBs and stacks: wait for the baseline */
        for( uint32_t w = 0; ; w++ )
        {
            if( ( xPortGetFreeHeapSize() == xHeapBase ) && ( uxTaskGetNumberOfTasks() == uxTasksBase ) )
            {
                break;
            }

            if( w > 200u )
            {
                hal_fail( "spawn: heap/task count did not return to the baseline after vTaskDelete (free, base)", NULL, xPortGetFreeHeapSize(), xHeapBase );
            }

            vTaskDelay( 1 );
        }

        ulCount[ C_SPAWN ]++;
        vTaskDelay( 4u * BRK_SLEEP + ( hal_rand( &seed ) % ( 4u * BRK_SLEEP + 1u ) ) );
    }
}

/* ----------------------------------------------------- priority inheritance */
static SemaphoreHandle_t xMutA, xMutB, xRecMut;
static TaskHandle_t xPiL, xPiM, xPiH;
static volatile uint32_t ulPiHWaiting, ulPiMWaiting, ulPiHTimeout, ulPiTimeouts, ulPiIters;

static void prvPiH( void * pv )
{
    uint32_t seed = hal_seed() ^ 0x1717u;

    ( void ) pv;

    for( ; ; )
    {
        uint32_t r = hal_rand( &seed );

        vTaskDelay( 2u * BRK_SLEEP + ( r & 1u ) );
        ulPiHTimeout = ( ( r >> 1 ) & 3u ) == 0u;
        xTaskNotifyGiveIndexed( xPiL, 1 );                       /* go */

        if( ulTaskNotifyTakeIndexed( 1, pdTRUE, portMAX_DELAY ) == 0u )   /* M: B held */
        {
            hal_fail( "pi_h: notify take returned 0", NULL, 0, 0 );
        }

        if( xSemaphoreGetMutexHolder( xMutB ) != xPiM )
        {
            hal_fail( "pi_h: M does not hold B", NULL, 0, 0 );
        }

        ulPiHWaiting = 1;

        if( xSemaphoreTake( xMutB, ulPiHTimeout ? 1u + ( ( r >> 4 ) % 3u ) : portMAX_DELAY ) == pdTRUE )
        {
            ulPiHWaiting = 0;

            if( uxTaskPriorityGet( NULL ) != PRIO_PIH )
            {
                hal_fail( "pi_h: priority changed", NULL, uxTaskPriorityGet( NULL ), PRIO_PIH );
            }

            xSemaphoreGive( xMutB );
        }
        else
        {
            ulPiHWaiting = 0;

            if( !ulPiHTimeout )
            {
                hal_fail( "pi_h: xSemaphoreTake(B, portMAX_DELAY) failed (blocking yield lost?)", NULL, 0, 0 );
            }

            ulPiTimeouts++;
        }

        if( ulTaskNotifyTakeIndexed( 2, pdTRUE, portMAX_DELAY ) == 0u )   /* L: iteration done */
        {
            hal_fail( "pi_h: done notify take returned 0", NULL, 0, 0 );
        }

        if( ( xSemaphoreGetMutexHolder( xMutA ) != NULL ) || ( xSemaphoreGetMutexHolder( xMutB ) != NULL ) )
        {
            hal_fail( "pi_h: a mutex is still held after the iteration", NULL, ( uint32_t ) ( uintptr_t ) xSemaphoreGetMutexHolder( xMutA ), ( uint32_t ) ( uintptr_t ) xSemaphoreGetMutexHolder( xMutB ) );
        }

        ulPiIters++;
        ulCount[ C_PI ]++;
    }
}

static void prvPiM( void * pv )
{
    ( void ) pv;

    for( ; ; )
    {
        UBaseType_t p;

        ( void ) ulTaskNotifyTakeIndexed( 1, pdTRUE, portMAX_DELAY );   /* L: A held */

        if( xSemaphoreTake( xMutB, 0 ) != pdTRUE )
        {
            hal_fail( "pi_m: B not free", NULL, 0, 0 );
        }

        xTaskNotifyGiveIndexed( xPiH, 1 );   /* H runs, blocks on B: we inherit 6 */
        p = uxTaskPriorityGet( NULL );

        if( ( p != PRIO_PIH ) && !( ulPiHTimeout && ( p == PRIO_PIM ) ) )
        {
            hal_fail( "pi_m: did not inherit H's priority while H waits on B (prio)", NULL, p, ulPiHTimeout );
        }

        /* recursive mutex, nested, while holding B */
        for( int i = 0; i < 3; i++ )
        {
            if( xSemaphoreTakeRecursive( xRecMut, portMAX_DELAY ) != pdTRUE )
            {
                hal_fail( "pi_m: recursive take failed", NULL, i, 0 );
            }
        }

        for( int i = 0; i < 3; i++ )
        {
            xSemaphoreGiveRecursive( xRecMut );
        }

        ulPiMWaiting = 1;

        if( xSemaphoreTake( xMutA, portMAX_DELAY ) != pdTRUE )   /* blocks: L inherits */
        {
            hal_fail( "pi_m: xSemaphoreTake(A, portMAX_DELAY) failed (blocking yield lost?)", NULL, 0, 0 );
        }

        ulPiMWaiting = 0;
        xSemaphoreGive( xMutA );
        xSemaphoreGive( xMutB );   /* H (if still waiting) takes B and runs */
        p = uxTaskPriorityGet( NULL );

        if( p != PRIO_PIM )
        {
            hal_fail( "pi_m: priority not restored after giving both mutexes (prio)", NULL, p, PRIO_PIM );
        }
    }
}

static void prvPiL( void * pv )
{
    uint32_t seed = hal_seed() ^ 0x2727u;

    ( void ) pv;

    for( ; ; )
    {
        UBaseType_t p;
        uint32_t t0, len, ulSeenInherit = 0;

        ( void ) ulTaskNotifyTakeIndexed( 1, pdTRUE, portMAX_DELAY );   /* H: go */

        if( xSemaphoreTake( xMutA, 0 ) != pdTRUE )
        {
            hal_fail( "pi_l: A not free", NULL, 0, 0 );
        }

        xTaskNotifyGiveIndexed( xPiM, 1 );   /* M runs now (prio 4 > 2) */

        /* We only get here once M has blocked on A (it is higher priority and
         * never blocks elsewhere while ready), so we must have inherited. */
        len = BRK_BUDGET / 2u + ( hal_rand( &seed ) % ( BRK_BUDGET / 2u + 1u ) );
        t0 = hal_mtime();

        do   /* at least once, even if interrupts eat the whole budget */
        {
            p = uxTaskPriorityGet( NULL );

            if( ulPiMWaiting && ( p < PRIO_PIM ) )
            {
                hal_fail( "pi_l: M waits on A but L did not inherit (prio)", NULL, p, PRIO_PIM );
            }

            if( ulPiMWaiting && ulPiHWaiting && !ulPiHTimeout && ( p != PRIO_PIH ) )
            {
                hal_fail( "pi_l: H waits (no timeout) but L's inherited priority is not H's (prio)", NULL, p, PRIO_PIH );
            }

            ulSeenInherit |= ( p > PRIO_PIL );
            hal_spin( 8 );
        } while( ( hal_mtime() - t0 ) < len );

        if( !ulSeenInherit )
        {
            hal_fail( "pi_l: never observed an inherited priority", NULL, uxTaskPriorityGet( NULL ), ulPiMWaiting );
        }

        xSemaphoreGive( xMutA );   /* disinherit: M takes A and runs */
        p = uxTaskPriorityGet( NULL );

        if( p != PRIO_PIL )
        {
            hal_fail( "pi_l: priority not restored after giving A (prio)", NULL, p, PRIO_PIL );
        }

        xTaskNotifyGiveIndexed( xPiH, 2 );
    }
}

static void prvHog( void * pv )
{
    uint32_t seed = hal_seed() ^ ( uint32_t ) ( uintptr_t ) pv;

    for( ; ; )
    {
        const uint32_t ulT0 = hal_mtime();

        while( prvBudgetLeft( ulT0 ) )
        {
            hal_spin( 16 );
        }

        vTaskDelay( BRK_SLEEP + ( hal_rand( &seed ) & 1u ) );
    }
}

/* ---------------------------------------------------------------- fence.i */
/* RV32I encodings */
#define RV_LUI( rd, imm20 )           ( ( ( uint32_t ) ( imm20 ) << 12 ) | ( ( rd ) << 7 ) | 0x37u )
#define RV_ADDI( rd, rs1, imm12 )     ( ( ( ( uint32_t ) ( imm12 ) & 0xFFFu ) << 20 ) | ( ( rs1 ) << 15 ) | ( ( rd ) << 7 ) | 0x13u )
#define RV_ADD( rd, rs1, rs2 )        ( ( ( rs2 ) << 20 ) | ( ( rs1 ) << 15 ) | ( ( rd ) << 7 ) | 0x33u )
#define RV_RET                        0x00008067u   /* jalr x0, 0(ra) */
#define RV_FENCEI                     0x0000100Fu
/* bne rs1, rs2, offset (offset in bytes, multiple of 2, |off| < 4096) */
static uint32_t prvBne( uint32_t rs1, uint32_t rs2, int32_t off )
{
    uint32_t o = ( uint32_t ) off;

    return ( ( ( o >> 12 ) & 1u ) << 31 ) | ( ( ( o >> 5 ) & 0x3Fu ) << 25 ) | ( rs2 << 20 ) | ( rs1 << 15 ) |
           ( 1u << 12 ) | ( ( ( o >> 1 ) & 0xFu ) << 8 ) | ( ( ( o >> 11 ) & 1u ) << 7 ) | 0x63u;
}

#define A0    10u
#define T0    5u
static uint32_t ulCode[ 2 ][ 16 ] __attribute__( ( aligned( 64 ) ) );
typedef uint32_t ( * CodeFn_t )( void );

static void prvFenceI( void * pv )
{
    const uint32_t id = ( uint32_t ) ( uintptr_t ) pv;
    uint32_t * const c = ulCode[ id ];
    uint32_t seed = hal_seed() ^ ( 0x3131u + id );
    const CodeFn_t fn = ( CodeFn_t ) ( uintptr_t ) c;

    for( ; ; )
    {
        const uint32_t ulT0 = hal_mtime();

        do
        {
            uint32_t r = hal_rand( &seed ), k = hal_rand( &seed ), expect, got;
            uint32_t hi = ( k + 0x800u ) >> 12, lo = k & 0xFFFu;

            switch( r & 3u )
            {
                case 0: /* li a0, k; ret -- then fence.i and call */
                case 1: /* ... with a yield or a spin between the stores and fence.i */
                    c[ 0 ] = RV_LUI( A0, hi );
                    c[ 1 ] = RV_ADDI( A0, A0, lo );
                    c[ 2 ] = RV_RET;
                    expect = k;

                    if( ( r & 3u ) == 1u )
                    {
                        if( ( r & 4u ) != 0u )
                        {
                            taskYIELD();
                        }
                        else
                        {
                            hal_spin( ( r >> 3 ) & 31u );
                        }
                    }

                    __asm volatile ( "fence.i" ::: "memory" );
                    break;

                case 2: /* the buffer itself starts with fence.i; the word right after it was just patched */
                    c[ 0 ] = RV_FENCEI;
                    c[ 1 ] = RV_LUI( A0, hi );
                    c[ 2 ] = RV_ADDI( A0, A0, lo );
                    c[ 3 ] = RV_RET;
                    expect = k;
                    break;

                default: /* a patched counted loop: a0 = n * imm (branch inside new code) */
                   {
                       uint32_t n = 1u + ( ( r >> 2 ) & 15u );
                       int32_t imm = ( int32_t ) ( ( k & 0x7FFu ) ) - 0x400;

                       c[ 0 ] = RV_ADDI( A0, 0u, 0 );
                       c[ 1 ] = RV_ADDI( T0, 0u, n );
                       c[ 2 ] = RV_ADDI( A0, A0, ( uint32_t ) imm );
                       c[ 3 ] = RV_ADDI( T0, T0, 0xFFFu );          /* t0 -= 1 */
                       c[ 4 ] = prvBne( T0, 0u, -8 );
                       c[ 5 ] = RV_RET;
                       expect = n * ( uint32_t ) imm;
                       __asm volatile ( "fence.i" ::: "memory" );
                       break;
                   }
            }

            got = fn();

            if( got != expect )
            {
                hal_fail( "fencei: patched code returned a stale/wrong value (got, expected)", NULL, got, expect );
            }

            ulCount[ C_FI0 + id ]++;
        } while( prvBudgetLeft( ulT0 ) );

        vTaskDelay( BRK_SLEEP + ( hal_rand( &seed ) & 1u ) );
    }
}

/* ------------------------------------------------------------- exceptions */
/* The task publishes the cause and PC it expects, executes one faulting
 * instruction, and checks that the handler saw exactly that trap once and that
 * the instruction had no architectural effect (rd / memory unchanged). The
 * port returns from a synchronous trap to mepc + 4. */
static volatile uint32_t ulExpCause, ulExpPc, ulExcSeen, ulExcTotal;
static volatile uint32_t ulExcScratch[ 2 ] __attribute__( ( aligned( 8 ) ) );

void freertos_risc_v_application_exception_handler( uint32_t mcause, uint32_t mepc_plus_4 )
{
    const uint32_t mepc = mepc_plus_4 - 4u;

    if( ( ulExcSeen != 0u ) || ( mcause != ulExpCause ) || ( mepc != ulExpPc ) )
    {
        hal_fail( "exc: unexpected exception (mcause, mepc)", NULL, mcause, mepc );
    }

    ulExcSeen = 1;
    ulExcTotal++;
}

#define HADES_TEST_COUNTER    ( *( volatile uint32_t * ) 0x00480008u )   /* every read returns +1 */

/* EXC(cause, insn): expect `insn` (which must not write a5 or memory) to trap with `cause` */
#define EXC( cause, insn )                                            \
    __asm volatile ( "la   t0, 1f\n"                                  \
                     "sw   t0, 0(%1)\n"                               \
                     "li   t0, " #cause "\n"                          \
                     "sw   t0, 0(%2)\n"                               \
                     "li   a5, 0x11111111\n"                          \
                     "1:   " insn "\n"                                \
                     "mv   %0, a5\n"                                  \
                     : "=r" ( out )                                   \
                     : "r" ( &ulExpPc ), "r" ( &ulExpCause ), "r" ( pS ), "r" ( pBad ), "r" ( pErr ), "r" ( pMis ) \
                     : "t0", "a5", "memory" )

static void prvExc( void * pv )
{
    uint32_t seed = hal_seed() ^ 0x6161u;
    volatile uint32_t * const pS = ulExcScratch;
    volatile uint32_t * const pBad = ( volatile uint32_t * ) 0x00300000u;   /* unmapped */
    volatile uint32_t * const pErr = ( volatile uint32_t * ) 0x00480010u;   /* wishbone_test: error after 3 stall cycles */
    const uint32_t pMis = ( uint32_t ) ( uintptr_t ) &&mis_target + 2u;     /* misaligned jump target */

    ( void ) pv;

    for( ; ; )
    {
        const uint32_t ulT0 = hal_mtime();

        do
        {
            uint32_t r = hal_rand( &seed ), out = 0, k = r % 11u, ulSnap = 0;
            const int crit = ( ( r >> 28 ) & 3u ) == 0u;   /* 1 in 4: trap taken with MIE=0 */

            ulExcScratch[ 0 ] = r;
            ulExcScratch[ 1 ] = ~r;
            ulExcSeen = 0;

            if( crit )
            {
                taskENTER_CRITICAL();
                ulSnap = ulIrqEvents;
            }

            switch( k )
            {
                case 0:  EXC( 2, ".word 0" ); break;                 /* illegal */
                case 1:  EXC( 3, "ebreak" ); break;
                case 2:  EXC( 4, "lw a5, 2(%3)" ); break;            /* misaligned load */
                case 3:  EXC( 6, "sh a5, 1(%3)" ); break;            /* misaligned store */
                case 4:  EXC( 5, "lw a5, 0(%4)" ); break;            /* load access fault */
                case 5:  EXC( 7, "sw a5, 0(%4)" ); break;            /* store access fault */
                case 6:  EXC( 5, "lw a5, 0(%5)" ); break;            /* load fault after a 3-cycle stall */
                case 7:  EXC( 7, "sw a5, 0(%5)" ); break;            /* store fault after a 3-cycle stall */
                case 8:  EXC( 0, "jalr a5, 0(%6)" ); break;          /* misaligned jump: rd not written */
                case 9:  EXC( 2, "csrr a5, 0x7C0" ); break;          /* no such CSR */
                default: EXC( 2, "csrw cycle, a5" ); break;          /* read-only CSR */
            }

            if( crit )
            {
                /* the trap was taken with MIE=0: its mret must restore MIE=0
                 * (MPIE <= MIE on trap entry), and no interrupt may have run */
                if( ( hal_mstatus() & HADES_MSTATUS_MIE ) != 0u )
                {
                    hal_fail( "exc: MIE=1 after an exception taken inside a critical section (kind, mstatus)", NULL, k, hal_mstatus() );
                }

                if( ulIrqEvents != ulSnap )
                {
                    hal_fail( "exc: an interrupt handler ran inside a critical section around an exception", NULL, k, ulIrqEvents - ulSnap );
                }

                taskEXIT_CRITICAL();
            }

            if( ulExcSeen != 1u )
            {
                hal_fail( "exc: the expected exception was not taken (kind, seen)", NULL, k, ulExcSeen );
            }

            if( out != 0x11111111u )
            {
                hal_fail( "exc: faulting instruction wrote its rd (kind, rd)", NULL, k, out );
            }

            if( ( ulExcScratch[ 0 ] != r ) || ( ulExcScratch[ 1 ] != ~r ) )
            {
                hal_fail( "exc: faulting store changed memory (kind, word0)", NULL, k, ulExcScratch[ 0 ] );
            }

            /* side-effecting reads: every read of the counter returns the
             * previous value + 1, so a load that is performed twice (or not at
             * all) is visible */
            {
                uint32_t n = 1u + ( ( r >> 8 ) & 31u ), prev = HADES_TEST_COUNTER, v;

                while( n-- != 0u )
                {
                    v = HADES_TEST_COUNTER;

                    if( v != prev + 1u )
                    {
                        hal_fail( "exc: side-effecting counter read performed twice or lost (got, expected)", NULL, v, prev + 1u );
                    }

                    prev = v;
                }
            }

            ulCount[ C_EXC ]++;
        } while( ( hal_mtime() - ulT0 ) < 3u * BRK_BUDGET );   /* 3 budgets: traps are the point */

        vTaskDelay( BRK_SLEEP + ( hal_rand( &seed ) & 1u ) );
    }

mis_target:
    hal_fail( "exc: reached the misaligned-jump target", NULL, 0, 0 );
}

/* ------------------------------------------------------------- bpred mode */
static void prvBpDyn( void * pv )
{
    uint32_t seed = hal_seed() ^ 0x4141u;

    ( void ) pv;

    for( ; ; )
    {
        uint32_t m = hal_rand( &seed ) & 3u;

        __asm volatile ( "csrw 0x32A, %0" :: "r" ( m ) );
        ulCount[ C_BPDYN ]++;
        vTaskDelay( 1u + ( hal_rand( &seed ) % ( BRK_SLEEP + 1u ) ) );
    }
}

/* ------------------------------------------------------------------ check */
static void prvRegTestEntry1( void * pv )
{
    if( pv == ( void * ) 0x12345678 )
    {
        vRegTest1Implementation();
    }

    hal_fail( "rt1: wrong task parameter", NULL, ( uint32_t ) ( uintptr_t ) pv, 0 );
}

static void prvRegTestEntry2( void * pv )
{
    if( pv == ( void * ) 0x87654321 )
    {
        vRegTest2Implementation();
    }

    hal_fail( "rt2: wrong task parameter", NULL, ( uint32_t ) ( uintptr_t ) pv, 0 );
}

static uint32_t prvCounter( int i, uint32_t n )
{
    switch( i )
    {
        case C_RT1:  return ulRegTest1LoopCounter;
        case C_RT2:  return ( configUSE_PREEMPTION == 1 ) ? ulRegTest2LoopCounter : n;
        case C_RT3:  return ulRegTest3Counter;
        case C_PIPE: return ( BRK_PIPE == 1 ) ? ulPipeBrkCounter : n;
        case C_ISRSEM: return ulSemTaken;
        default:     return ulCount[ i ];
    }
}

static int prvEnabled( int i )
{
    switch( i )
    {
        case C_SBRX: case C_MBRX: case C_SBTX: case C_EXTIRQ: case C_ISRSEM: return BRK_STORM;
        case C_TPAST: return BRK_TPAST;
        case C_NEST:  return BRK_NEST;
        case C_DIS:   return BRK_DIS;
        case C_SPAWN: return BRK_CHURN;
        case C_PI:    return BRK_PI;
        case C_FI0: case C_FI1: return BRK_FENCEI;
        case C_BPDYN: return BRK_BPDYN;
        case C_EXC:   return BRK_EXC;
        default: return 1;
    }
}

static void prvIsrSem( void * pv )
{
    ( void ) pv;

    for( ; ; )
    {
        if( xSemaphoreTake( xIsrSem, portMAX_DELAY ) != pdTRUE )
        {
            hal_fail( "isrsem: xSemaphoreTake(portMAX_DELAY) failed (blocking yield lost?)", NULL, ulSemTaken, 0 );
        }

        ulSemTaken++;
    }
}

static void prvCheck( void * pv )
{
    uint32_t last[ C_NUM ] = { 0 };
    TickType_t xWake = xTaskGetTickCount();
    const TickType_t xT0 = xWake;
    const uint32_t ulM0 = hal_mtime();
    uint32_t ulMaxDrift = 0;

    ( void ) pv;

    for( uint32_t n = 1; n <= FRTOS_NCHECKS; n++ )
    {
        uint32_t ulTicks, ulHw, ulDrift;
        int32_t d;

        vTaskDelayUntil( &xWake, FRTOS_CHECK_TICKS );

        #ifdef BRK_VERBOSE
            hal_puts_atomic( "  chk" );
            for( int i = 0; i < C_NUM; i++ )
            {
                hal_putc( ' ' );
                hal_puts( pcNames[ i ] );
                hal_putc( '=' );
                hal_putdec( prvCounter( i, n ) - last[ i ] );
            }
            hal_putc( '\n' );
        #endif

        for( int i = 0; i < C_NUM; i++ )
        {
            uint32_t v = prvCounter( i, n );

            if( prvEnabled( i ) && ( v == last[ i ] ) )
            {
                hal_fail( "no progress in a check period (task/counter, period)", pcNames[ i ], ( uint32_t ) i, n );
            }

            last[ i ] = v;
        }

        taskENTER_CRITICAL();
        {
            d = ( int32_t ) ( ulIsrGives - ulSemTaken - ( uint32_t ) uxSemaphoreGetCount( xIsrSem ) );

            if( ( d < 0 ) || ( d > 1 ) )
            {
                taskEXIT_CRITICAL();
                hal_fail( "ISR semaphore accounting (gives - taken - pending)", NULL, ( uint32_t ) d, n );
            }

            ulTicks = xTaskGetTickCount() - xT0;
            ulHw = ( hal_mtime() - ulM0 ) / FRTOS_TICK_CYCLES;
        }
        taskEXIT_CRITICAL();

        ulDrift = ( ulTicks > ulHw ) ? ulTicks - ulHw : ulHw - ulTicks;
        ulMaxDrift = ( ulDrift > ulMaxDrift ) ? ulDrift : ulMaxDrift;

        if( ulDrift > 3u + TPAST_MAX_TICKS )
        {
            hal_fail( "tick drift (sw ticks, mtime ticks)", NULL, ulTicks, ulHw );
        }

        hal_pattern_line();
    }

    hal_puts( "  ticks=" );
    hal_putdec( xTaskGetTickCount() );
    hal_puts( " irq-profile=" );
    hal_putdec( ulIrqProfile );
    hal_puts( " ext-irqs=" );
    hal_putdec( ulCount[ C_EXTIRQ ] );
    hal_puts( " storms=" );
    hal_putdec( ulStorms );
    hal_puts( " sb=" );
    hal_putdec( ulSbSent );
    hal_puts( "/short" );
    hal_putdec( ulSbShort );
    hal_puts( " mb=" );
    hal_putdec( ulMbSent );
    hal_puts( "/full" );
    hal_putdec( ulMbFull );
    hal_puts( " in=" );
    hal_putdec( ulInRecv );
    hal_puts( "\n  early-ticks=" );
    hal_putdec( ulEarlyTicks );
    hal_puts( " long-crit=" );
    hal_putdec( ulLongCrit );
    hal_puts( " max-drift=" );
    hal_putdec( ulMaxDrift );
    hal_puts( " nest=" );
    hal_putdec( ulCount[ C_NEST ] );
    hal_puts( " dis=" );
    hal_putdec( ulCount[ C_DIS ] );
    hal_puts( " spawn=" );
    hal_putdec( ulCount[ C_SPAWN ] );
    hal_puts( " del(self/blk/run)=" );
    hal_putdec( ulSelfDeletes );
    hal_putc( '/' );
    hal_putdec( ulOtherDeletes );
    hal_putc( '/' );
    hal_putdec( ulRunningDeletes );
    hal_puts( "\n  pi=" );
    hal_putdec( ulPiIters );
    hal_puts( "/timeouts" );
    hal_putdec( ulPiTimeouts );
    hal_puts( " fencei=" );
    hal_putdec( ulCount[ C_FI0 ] );
    hal_putc( '+' );
    hal_putdec( ulCount[ C_FI1 ] );
    hal_puts( " bpdyn=" );
    hal_putdec( ulCount[ C_BPDYN ] );
    hal_puts( " pipe=" );
    hal_putdec( ulPipeBrkCounter );
    hal_puts( " exc=" );
    hal_putdec( ulExcTotal );
    hal_puts( " rt1=" );
    hal_putdec( ulRegTest1LoopCounter );
    hal_puts( " rt2=" );
    hal_putdec( ulRegTest2LoopCounter );
    hal_puts( " rt3=" );
    hal_putdec( ulRegTest3Counter );
    hal_puts( "\n  irq-at: div=" );
    hal_putdec( ulIrqAtDiv );
    hal_puts( " mul=" );
    hal_putdec( ulIrqAtMul );
    hal_puts( " ecall=" );
    hal_putdec( ulIrqAtEcall );
    hal_puts( " csr=" );
    hal_putdec( ulIrqAtCsr );
    hal_puts( " fence.i=" );
    hal_putdec( ulIrqAtFenceI );
    hal_puts( "\n  isr-stack-peak=" );
    hal_putdec( hal_isr_stack_peak() );
    hal_putc( '/' );
    hal_putdec( hal_isr_stack_size() );
    hal_puts( " heap-free=" );
    hal_putdec( xPortGetFreeHeapSize() );
    hal_puts( " min-ever=" );
    hal_putdec( xPortGetMinimumEverFreeHeapSize() );
    hal_pass();
}

/* -------------------------------------------------------------------- main */
static void prvCreate( TaskFunction_t f, const char * name, uint32_t words, void * pv, UBaseType_t prio, TaskHandle_t * ph )
{
    if( xTaskCreate( f, name, ( configSTACK_DEPTH_TYPE ) words, pv, prio, ph ) != pdPASS )
    {
        hal_fail( "xTaskCreate failed", name, words, xPortGetFreeHeapSize() );
    }
}

int main( void )
{
    const uint32_t seed = hal_seed();
    const uint32_t S = configMINIMAL_STACK_SIZE;

    hal_begin( "brk" );
    ulIsrSeed = seed ^ 0xC0FFEEu;
    ulIrqProfile = ( seed >> 8 ) % 4u;
    ulIrqMin = 40u;
    ulIrqSpan = 4u * IRQ_CALM_FLOOR * BRK_SCALE;

    xSb = xStreamBufferCreate( SB_SIZE, 1 );
    xSbIn = xStreamBufferCreate( SBIN_SIZE, 1 );
    xMb = xMessageBufferCreate( MB_SIZE );
    xIsrSem = xSemaphoreCreateCounting( 0xFFFF, 0 );
    xWorkSem = xSemaphoreCreateCounting( 2, 2 );
    xMutA = xSemaphoreCreateMutex();
    xMutB = xSemaphoreCreateMutex();
    xRecMut = xSemaphoreCreateRecursiveMutex();

    if( !xSb || !xSbIn || !xMb || !xIsrSem || !xWorkSem || !xMutA || !xMutB || !xRecMut )
    {
        hal_fail( "object create failed", NULL, 0, 0 );
    }

    prvCreate( prvCheck, "check", S + S / 2, NULL, PRIO_CHECK, NULL );
    #if ( BRK_STORM == 1 )
        prvCreate( prvSbRx, "sbrx", S, NULL, PRIO_SBRX, NULL );
        prvCreate( prvMbRx, "mbrx", S, NULL, PRIO_MBRX, NULL );
        prvCreate( prvSbTx, "sbtx", S, NULL, PRIO_LOW, NULL );
        prvCreate( prvIsrSem, "isrsem", S, NULL, PRIO_SBRX, NULL );
    #endif
    #if ( BRK_PI == 1 )
        prvCreate( prvPiH, "pi_h", S, NULL, PRIO_PIH, &xPiH );
        prvCreate( prvPiM, "pi_m", S, NULL, PRIO_PIM, &xPiM );
        prvCreate( prvPiL, "pi_l", S, NULL, PRIO_PIL, &xPiL );
        prvCreate( prvHog, "hog5", S, ( void * ) 5, PRIO_HOG5, NULL );
        prvCreate( prvHog, "hog3", S, ( void * ) 3, PRIO_HOG3, NULL );
    #endif
    #if ( BRK_CHURN == 1 )
        prvCreate( prvSpawn, "spawn", S, NULL, PRIO_SPAWN, &xSpawner );
    #endif
    #if ( BRK_TPAST == 1 )
        prvCreate( prvTPast, "tpast", S, NULL, PRIO_TPAST, NULL );
    #endif
    #if ( BRK_NEST == 1 )
        prvCreate( prvNest, "nest", S, NULL, PRIO_NEST, NULL );
    #endif
    #if ( BRK_DIS == 1 )
        prvCreate( prvDis, "dis", S, NULL, PRIO_DIS, NULL );
    #endif
    #if ( BRK_FENCEI == 1 )
        prvCreate( prvFenceI, "fi0", S, ( void * ) 0, PRIO_LOW, NULL );
        prvCreate( prvFenceI, "fi1", S, ( void * ) 1, PRIO_LOW, NULL );
    #endif
    #if ( BRK_EXC == 1 )
        prvCreate( prvExc, "exc", S, NULL, PRIO_LOW, NULL );
    #endif
    #if ( BRK_BPDYN == 1 )
        prvCreate( prvBpDyn, "bpdyn", S, NULL, PRIO_LOW, NULL );
    #endif
    #if ( BRK_PIPE == 1 )
        prvCreate( vPipeBrkTask, "pipe", 100, ( void * ) ( uintptr_t ) ( seed | 1u ), PRIO_REG, NULL );
    #endif
    prvCreate( prvRegTestEntry1, "rt1", 90, ( void * ) 0x12345678, PRIO_REG, NULL );
    #if ( configUSE_PREEMPTION == 1 )
        prvCreate( prvRegTestEntry2, "rt2", 90, ( void * ) 0x87654321, PRIO_REG, NULL );
    #endif
    prvCreate( vRegTest3Task, "rt3", 64, NULL, PRIO_REG, NULL );

    hal_puts( "  irq-profile=" );
    hal_putdec( ulIrqProfile );
    hal_puts( " sleep=" );
    hal_putdec( BRK_SLEEP );
    hal_puts( " budget=" );
    hal_putdec( BRK_BUDGET );
    hal_puts( " heap free after create=" );
    hal_putdec( xPortGetFreeHeapSize() );
    hal_putc( '\n' );

    #if ( BRK_STORM == 1 )
        HADES_TEST_IRQ = 1000;   /* pends until the scheduler enables interrupts */
    #endif
    vTaskStartScheduler();
    hal_fail( "vTaskStartScheduler returned", NULL, 0, 0 );
}
