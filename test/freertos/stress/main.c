/* stress: FreeRTOS stress program for HaDes-V+ (fits the real 32 KiB RAM).
 *
 * Everything runs at the same time, with the timing of interrupts randomised
 * by the run seed (+switches=<hex>) so that interrupts, ECALL yields and
 * critical-section entries meet at arbitrary pipeline phases:
 *
 *   rt1, rt2   official RISC-V port RegTest tasks (RegTest.S), priority 0.
 *              rt2 never yields, so it is only created when preemptive.
 *   rt3        RegTest3 (regtest3.S): registers incl. ra, MIE=1, ECALL yield.
 *   prod->cons queue 1 (len 4), producer low / consumer high priority:
 *              the consumer blocks on every item (ECALL yield with MIE=1).
 *   prod2->cons2 queue 2 (len 2), producer high / consumer low: the producer
 *              blocks on a full queue.
 *   ext IRQ    the wishbone_test down-counter re-armed from its own ISR with a
 *              random delay; the ISR gives a counting semaphore (task "isrsem")
 *              and random direct-to-task notifications (task "ntfy").
 *   crit0/1    enter a critical section, check mstatus.MIE=0, optionally
 *              taskYIELD() inside it (STRESS_CRIT_YIELD) and check MIE=0 again,
 *              spin and check that no interrupt handler ran, leave; plus tight
 *              portDISABLE/ENABLE_INTERRUPTS toggling with the same check.
 *   idle hook  (STRESS_SLOWBUS) writes and reads back a VGA frame-buffer
 *              word and the wishbone_test stall register: interrupts land
 *              during 2..4-cycle bus accesses.
 *   check      every FRTOS_CHECK_TICKS ticks: every task made progress, queue
 *              sequences are intact, ISR/semaphore/notification accounting
 *              balances, the tick count follows mtime; PASS after
 *              FRTOS_NCHECKS periods.
 * Any blocking call with portMAX_DELAY that returns without its item is a
 * failure: it can only happen if the blocking ECALL yield was lost.
 */
#include "FreeRTOS.h"
#include "task.h"
#include "queue.h"
#include "semphr.h"
#include "hades_hal.h"

#define PRIO_CHECK     6
#define PRIO_ISRSEM    5
#define PRIO_NTFY      4
#define PRIO_HIGH      3
#define PRIO_CRIT      2
#define PRIO_LOW       1
#define PRIO_REG       0

enum
{
    C_RT1, C_RT2, C_RT3, C_PROD, C_CONS, C_PROD2, C_CONS2, C_ISRSEM, C_NTFY,
    C_CRIT0, C_CRIT1, C_IDLE, C_TICKHOOK, C_EXTIRQ, C_UART, C_NUM
};
static const char * const pcNames[ C_NUM ] =
{
    "rt1", "rt2", "rt3", "prod", "cons", "prod2", "cons2", "isrsem", "ntfy",
    "crit0", "crit1", "idle", "tick-hook", "ext-irq", "uart-lines"
};

/* Loop counters of the RegTest tasks (names fixed by RegTest.S / regtest3.S). */
volatile uint32_t ulRegTest1LoopCounter, ulRegTest2LoopCounter, ulRegTest3Counter;
extern void vRegTest1Implementation( void );
extern void vRegTest2Implementation( void );
extern void vRegTest3Task( void * pv );

static volatile uint32_t ulCount[ C_NUM ];
static volatile uint32_t ulIrqEvents;          /* tick hook + external ISR */
static volatile uint32_t ulIsrGives, ulIsrGiveFails, ulIsrNotifies;
static volatile uint32_t ulSemTaken, ulNtfyTaken, ulNtfyTaskGives, ulCritYields;
static uint32_t ulIsrSeed, ulIrqMin, ulIrqSpan, ulIrqProfile;

static SemaphoreHandle_t xIsrSem;
static QueueHandle_t xQ1, xQ2;
static TaskHandle_t xNtfyTask;

/* Each periodic task sleeps STRESS_SLEEP(+0/1) ticks between bursts -- about
 * STRESS_PERIOD cycles whatever the tick period -- and works for at most
 * STRESS_BUDGET cycles (by mtime) per burst, so the total load stays bounded
 * and the priority-0 RegTest tasks always get CPU time on a correct core. */
#ifdef __OPTIMIZE__
    #define STRESS_KNEE      6000u   /* tick period below which the load backs off */
    #define STRESS_PERIOD    ( 9000u * STRESS_SCALE )
#else
    #define STRESS_KNEE      7500u
    #define STRESS_PERIOD    ( 22000u * STRESS_SCALE )
#endif
/* The tick handler (plus a time-slice switch) costs a few hundred cycles per
 * tick, so with very short tick periods everything else backs off by
 * STRESS_SCALE, or the RegTest tasks would starve on any correct CPU. */
#define STRESS_SCALE      ( ( FRTOS_TICK_CYCLES >= STRESS_KNEE ) ? 1u : \
                            ( STRESS_KNEE + FRTOS_TICK_CYCLES - 1u ) / FRTOS_TICK_CYCLES )
#define STRESS_SLEEP      ( ( STRESS_PERIOD + FRTOS_TICK_CYCLES - 1u ) / FRTOS_TICK_CYCLES )
#define STRESS_BUDGET     ( ( uint32_t ) FRTOS_TICK_CYCLES * STRESS_SLEEP / 12u + 200u )
/* "prod" also prints a UART pattern line (hal_pattern_line) about every
 * STRESS_UART_PERIOD cycles, with interrupts enabled: campaign.py checks every
 * such line, which is how a UART store performed twice becomes visible. */
#define STRESS_UART_PERIOD    ( 100000u * STRESS_SCALE )
static inline int prvBudgetLeft( uint32_t ulT0 )
{
    return ( hal_mtime() - ulT0 ) < STRESS_BUDGET;
}

#define REGTEST1_PARAM    ( ( void * ) 0x12345678 )
#define REGTEST2_PARAM    ( ( void * ) 0x87654321 )

/* -------------------------------------------------------------- interrupts */

void vApplicationTickHook( void )
{
    ulIrqEvents++;
    ulCount[ C_TICKHOOK ]++;
}

void vApplicationIdleHook( void )
{
    ulCount[ C_IDLE ]++;

    #if ( STRESS_SLOWBUS == 1 )
    {
        /* Only this hook touches these two registers (see app_config.h). The
         * idle task never runs inside a critical section, so MIE must be 1
         * here; an interrupt whose JUMP was lost leaves it 0 (and a yield
         * taken with MIE=0 saves that into the idle task's context). */
        static uint32_t ulSlow = 0x2545F491u;
        const uint32_t v = hal_rand( &ulSlow );

        if( ( hal_mstatus() & HADES_MSTATUS_MIE ) == 0u )
        {
            hal_fail( "idle: MIE=0 (interrupt JUMP lost?)", NULL, hal_mstatus(), 0 );
        }

        HADES_VGA_WORD0 = v;
        HADES_TEST_STALL = ~v;

        if( ( HADES_VGA_WORD0 != v ) || ( HADES_TEST_STALL != ~v ) )
        {
            hal_fail( "idle: slow-bus read-back (VGA, stall)", NULL, HADES_VGA_WORD0, HADES_TEST_STALL );
        }
    }
    #endif
}

static void prvChooseIrqProfile( uint32_t seed )
{
    const uint32_t T = FRTOS_TICK_CYCLES, F = STRESS_IRQ_FLOOR * STRESS_SCALE;

    ulIrqProfile = seed % 4u;

    switch( ulIrqProfile )
    {
        case 0: /* dense */
            ulIrqMin = 40;
            ulIrqSpan = 2u * F;
            break;

        case 1: /* around the tick rate */
            ulIrqMin = T / 8u;
            ulIrqSpan = T;
            break;

        case 2: /* wide, includes back-to-back interrupts */
            ulIrqMin = 1;
            ulIrqSpan = 4u * F + T;
            break;

        default: /* nearly periodic: beats slowly against the tick */
            ulIrqMin = T / 2u;
            ulIrqSpan = T / 4u + 1u;
            break;
    }

    if( ulIrqMin + ulIrqSpan / 2u < F )   /* keep the mean interval >= F */
    {
        ulIrqSpan = 2u * ( F - ulIrqMin );
    }
}

static inline void prvArmIrq( void )
{
    HADES_TEST_IRQ = ulIrqMin + ( hal_rand( &ulIsrSeed ) % ulIrqSpan );
}

/* Machine external interrupt: wishbone_test down-counter reached 0. */
void app_external_irq( void )
{
    BaseType_t xWoken = pdFALSE;
    uint32_t r = hal_rand( &ulIsrSeed );

    prvArmIrq();   /* re-arm; this also drops the (level) interrupt line */
    ulIrqEvents++;
    ulCount[ C_EXTIRQ ]++;

    if( xSemaphoreGiveFromISR( xIsrSem, &xWoken ) == pdTRUE )
    {
        ulIsrGives++;
    }
    else
    {
        ulIsrGiveFails++;
    }

    if( ( r & 0x10000u ) != 0u )
    {
        vTaskNotifyGiveFromISR( xNtfyTask, &xWoken );
        ulIsrNotifies++;
    }

    #if ( configUSE_PREEMPTION == 1 )
        portYIELD_FROM_ISR( xWoken );
    #endif
}

/* ------------------------------------------------------------------- tasks */

static void prvRegTestEntry1( void * pv )
{
    if( pv == REGTEST1_PARAM )
    {
        vRegTest1Implementation();
    }

    hal_fail( "rt1: wrong task parameter", NULL, ( uint32_t ) ( uintptr_t ) pv, 0 );
}

static void prvRegTestEntry2( void * pv )
{
    if( pv == REGTEST2_PARAM )
    {
        vRegTest2Implementation();
    }

    hal_fail( "rt2: wrong task parameter", NULL, ( uint32_t ) ( uintptr_t ) pv, 0 );
}

static void prvProd( void * pv )   /* low priority -> queue 1 -> high priority */
{
    uint32_t seed = hal_seed() ^ 0x1111u, seq = 0, ulLastLine = hal_mtime();

    ( void ) pv;

    for( ; ; )
    {
        if( ( hal_mtime() - ulLastLine ) > STRESS_UART_PERIOD )
        {
            hal_pattern_line();
            ulCount[ C_UART ]++;
            ulLastLine = hal_mtime();
        }

        const uint32_t ulT0 = hal_mtime();
        uint32_t n = 1u + ( hal_rand( &seed ) & 7u );

        do
        {
            if( xQueueSend( xQ1, &seq, portMAX_DELAY ) != pdPASS )
            {
                hal_fail( "prod: xQueueSend(portMAX_DELAY) failed (blocking yield lost?)", NULL, seq, 0 );
            }

            seq++;
            ulCount[ C_PROD ]++;
            hal_spin( hal_rand( &seed ) & 31u );
        } while( --n != 0u && prvBudgetLeft( ulT0 ) );

        vTaskDelay( STRESS_SLEEP + ( hal_rand( &seed ) & 1u ) );
    }
}

static void prvCons( void * pv )
{
    uint32_t seed = hal_seed() ^ 0x2222u, v, expect = 0;

    ( void ) pv;

    for( ; ; )
    {
        if( xQueueReceive( xQ1, &v, portMAX_DELAY ) != pdPASS )
        {
            hal_fail( "cons: xQueueReceive(portMAX_DELAY) returned no item (blocking yield lost?)", NULL, expect, 0 );
        }

        if( v != expect )
        {
            hal_fail( "cons: queue 1 sequence error (got, expected)", NULL, v, expect );
        }

        expect = v + 1u;
        ulCount[ C_CONS ]++;
        hal_spin( hal_rand( &seed ) & 15u );
    }
}

static void prvProd2( void * pv )   /* high priority -> queue 2 (len 2) -> low priority */
{
    uint32_t seed = hal_seed() ^ 0x3333u, seq = 0;

    ( void ) pv;

    for( ; ; )
    {
        const uint32_t ulT0 = hal_mtime();
        uint32_t n = 1u + ( hal_rand( &seed ) % 6u );

        do
        {
            if( xQueueSend( xQ2, &seq, portMAX_DELAY ) != pdPASS )
            {
                hal_fail( "prod2: xQueueSend(portMAX_DELAY) failed (blocking yield lost?)", NULL, seq, 0 );
            }

            seq++;
            ulCount[ C_PROD2 ]++;
        } while( --n != 0u && prvBudgetLeft( ulT0 ) );

        vTaskDelay( STRESS_SLEEP + ( hal_rand( &seed ) & 1u ) );
    }
}

static void prvCons2( void * pv )
{
    uint32_t seed = hal_seed() ^ 0x4444u, v, expect = 0;

    ( void ) pv;

    for( ; ; )
    {
        if( xQueueReceive( xQ2, &v, portMAX_DELAY ) != pdPASS )
        {
            hal_fail( "cons2: xQueueReceive(portMAX_DELAY) returned no item (blocking yield lost?)", NULL, expect, 0 );
        }

        if( v != expect )
        {
            hal_fail( "cons2: queue 2 sequence error (got, expected)", NULL, v, expect );
        }

        expect = v + 1u;
        ulCount[ C_CONS2 ]++;
        hal_spin( hal_rand( &seed ) & 127u );
    }
}

static void prvIsrSem( void * pv )   /* takes what the external ISR gives */
{
    ( void ) pv;

    for( ; ; )
    {
        if( xSemaphoreTake( xIsrSem, portMAX_DELAY ) != pdTRUE )
        {
            hal_fail( "isrsem: xSemaphoreTake(portMAX_DELAY) failed (blocking yield lost?)", NULL, ulSemTaken, 0 );
        }

        ulSemTaken++;
        ulCount[ C_ISRSEM ]++;
    }
}

static void prvNtfy( void * pv )   /* notified by the ISR and by the crit tasks */
{
    ( void ) pv;

    for( ; ; )
    {
        if( ulTaskNotifyTake( pdFALSE, portMAX_DELAY ) == 0u )
        {
            hal_fail( "ntfy: ulTaskNotifyTake(portMAX_DELAY) returned 0 (blocking yield lost)", NULL, ulNtfyTaken, 0 );
        }

        ulNtfyTaken++;
        ulCount[ C_NTFY ]++;
    }
}

static void prvCrit( void * pv )
{
    const uint32_t id = ( uint32_t ) ( uintptr_t ) pv;
    uint32_t seed = hal_seed() ^ ( 0x5555u + id );

    for( ; ; )
    {
        const uint32_t ulT0 = hal_mtime();
        uint32_t n = 4u + ( hal_rand( &seed ) & 15u );

        do
        {
            uint32_t r = hal_rand( &seed );
            uint32_t ulSnap;

            taskENTER_CRITICAL();

            if( ( hal_mstatus() & HADES_MSTATUS_MIE ) != 0u )
            {
                hal_fail( "crit: mstatus.MIE=1 right after taskENTER_CRITICAL()", NULL, id, hal_mstatus() );
            }

            #if ( STRESS_CRIT_YIELD == 1 )
                if( ( r & 1u ) != 0u )
                {
                    taskYIELD();   /* legal on this port: ECALL with MIE=0 */

                    if( ( hal_mstatus() & HADES_MSTATUS_MIE ) != 0u )
                    {
                        hal_fail( "crit: mstatus.MIE=1 after taskYIELD() inside a critical section (MPIE not cleared by the trap?)", NULL, id, hal_mstatus() );
                    }

                    ulCritYields++;
                }
            #endif

            ulSnap = ulIrqEvents;
            hal_spin( ( r >> 8 ) & 63u );

            if( ulIrqEvents != ulSnap )
            {
                hal_fail( "crit: an interrupt handler ran inside a critical section", NULL, id, ulIrqEvents - ulSnap );
            }

            taskEXIT_CRITICAL();

            /* Tight disable/enable toggling: many csrc mstatus,8 at random
             * phases relative to the interrupt edges. */
            for( uint32_t k = ( r >> 16 ) & 15u; k != 0u; k-- )
            {
                portDISABLE_INTERRUPTS();

                if( ( hal_mstatus() & HADES_MSTATUS_MIE ) != 0u )
                {
                    hal_fail( "crit: mstatus.MIE=1 right after portDISABLE_INTERRUPTS() (csrc mstatus lost)", NULL, id, hal_mstatus() );
                }

                portENABLE_INTERRUPTS();
            }

            if( ( r & 0x3000000u ) == 0u )
            {
                xTaskNotifyGive( xNtfyTask );   /* may switch to "ntfy" at once */
                taskENTER_CRITICAL();
                ulNtfyTaskGives++;
                taskEXIT_CRITICAL();
            }

            ulCount[ C_CRIT0 + id ]++;
        } while( --n != 0u && prvBudgetLeft( ulT0 ) );

        vTaskDelay( STRESS_SLEEP + ( hal_rand( &seed ) & 1u ) );
    }
}

static void prvCheck( void * pv )
{
    uint32_t last[ C_NUM ] = { 0 };
    TickType_t xWake = xTaskGetTickCount();
    const TickType_t xT0 = xWake;
    const uint32_t ulM0 = hal_mtime();

    ( void ) pv;

    for( uint32_t n = 1; n <= FRTOS_NCHECKS; n++ )
    {
        uint32_t now[ C_NUM ], ulTicks, ulHw;
        int32_t d;

        vTaskDelayUntil( &xWake, FRTOS_CHECK_TICKS );

        now[ C_RT1 ] = ulRegTest1LoopCounter;
        now[ C_RT2 ] = ( configUSE_PREEMPTION == 1 ) ? ulRegTest2LoopCounter : n;
        now[ C_RT3 ] = ulRegTest3Counter;

        for( int i = C_PROD; i < C_NUM; i++ )
        {
            now[ i ] = ( i == C_UART ) ? ulCount[ i ] + n : ulCount[ i ];   /* not per period */
        }

        for( int i = 0; i < C_NUM; i++ )
        {
            if( now[ i ] == last[ i ] )
            {
                hal_fail( "no progress in a check period (task/counter, period)", pcNames[ i ], ( uint32_t ) i, n );
            }

            last[ i ] = now[ i ];
        }

        taskENTER_CRITICAL();
        {
            /* The ISR counts a give atomically with the give; "isrsem" (lower
             * priority than this task) may have taken one and not counted it. */
            d = ( int32_t ) ( ulIsrGives - ulSemTaken - ( uint32_t ) uxSemaphoreGetCount( xIsrSem ) );

            if( ( d < 0 ) || ( d > 1 ) || ( ulIsrGiveFails != 0u ) )
            {
                taskEXIT_CRITICAL();
                hal_fail( "ISR semaphore accounting (gives - taken - pending, give failures)", NULL, ( uint32_t ) d, ulIsrGiveFails );
            }

            /* Notifications: the two crit tasks may have given one each and not
             * counted it yet; "ntfy" may have taken one and not counted it. */
            d = ( int32_t ) ( ulIsrNotifies + ulNtfyTaskGives - ulNtfyTaken - ulTaskNotifyValueClear( xNtfyTask, 0 ) );

            if( ( d < -2 ) || ( d > 1 ) )
            {
                taskEXIT_CRITICAL();
                hal_fail( "task notification accounting (given - taken - pending)", NULL, ( uint32_t ) d, n );
            }

            ulTicks = xTaskGetTickCount() - xT0;
            ulHw = ( hal_mtime() - ulM0 ) / FRTOS_TICK_CYCLES;
        }
        taskEXIT_CRITICAL();

        if( ( ulTicks + 2u < ulHw ) || ( ulTicks > ulHw + 2u ) )
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
    hal_puts( " sem=" );
    hal_putdec( ulSemTaken );
    hal_puts( " ntfy=" );
    hal_putdec( ulNtfyTaken );
    hal_puts( " crit-yields=" );
    hal_putdec( ulCritYields );
    hal_puts( " uart-lines=" );
    hal_putdec( ulCount[ C_UART ] );
    hal_puts( "\n  rt1=" );
    hal_putdec( ulRegTest1LoopCounter );
    hal_puts( " rt2=" );
    hal_putdec( ulRegTest2LoopCounter );
    hal_puts( " rt3=" );
    hal_putdec( ulRegTest3Counter );
    hal_puts( " q1=" );
    hal_putdec( ulCount[ C_CONS ] );
    hal_puts( " q2=" );
    hal_putdec( ulCount[ C_CONS2 ] );
    hal_puts( "\n  isr-stack-peak=" );
    hal_putdec( hal_isr_stack_peak() );
    hal_putc( '/' );
    hal_putdec( hal_isr_stack_size() );
    hal_puts( " heap-free=" );
    hal_putdec( xPortGetFreeHeapSize() );
    hal_pass();
}

/* -------------------------------------------------------------------- main */

static void prvCreate( TaskFunction_t f, const char * name, uint32_t words, void * pv, UBaseType_t prio, TaskHandle_t * ph )
{
    if( xTaskCreate( f, name, ( configSTACK_DEPTH_TYPE ) words, pv, prio, ph ) != pdPASS )
    {
        hal_fail( "xTaskCreate failed", name, words, 0 );
    }
}

int main( void )
{
    const uint32_t seed = hal_seed();

    hal_begin( "stress" );
    ulIsrSeed = seed ^ 0xC0FFEEu;
    prvChooseIrqProfile( seed >> 8 );

    xQ1 = xQueueCreate( 4, sizeof( uint32_t ) );
    xQ2 = xQueueCreate( 2, sizeof( uint32_t ) );
    xIsrSem = xSemaphoreCreateCounting( 0xFFFF, 0 );

    if( ( xQ1 == NULL ) || ( xQ2 == NULL ) || ( xIsrSem == NULL ) )
    {
        hal_fail( "queue/semaphore create failed", NULL, 0, 0 );
    }

    prvCreate( prvCheck, "check", configMINIMAL_STACK_SIZE + configMINIMAL_STACK_SIZE / 2, NULL, PRIO_CHECK, NULL );
    prvCreate( prvIsrSem, "isrsem", configMINIMAL_STACK_SIZE, NULL, PRIO_ISRSEM, NULL );
    prvCreate( prvNtfy, "ntfy", configMINIMAL_STACK_SIZE, NULL, PRIO_NTFY, &xNtfyTask );
    prvCreate( prvCons, "cons", configMINIMAL_STACK_SIZE, NULL, PRIO_HIGH, NULL );
    prvCreate( prvProd2, "prod2", configMINIMAL_STACK_SIZE, NULL, PRIO_HIGH, NULL );
    prvCreate( prvCrit, "crit0", configMINIMAL_STACK_SIZE, ( void * ) 0, PRIO_CRIT, NULL );
    prvCreate( prvCrit, "crit1", configMINIMAL_STACK_SIZE, ( void * ) 1, PRIO_CRIT, NULL );
    prvCreate( prvProd, "prod", configMINIMAL_STACK_SIZE, NULL, PRIO_LOW, NULL );
    prvCreate( prvCons2, "cons2", configMINIMAL_STACK_SIZE, NULL, PRIO_LOW, NULL );
    prvCreate( prvRegTestEntry1, "rt1", 90, REGTEST1_PARAM, PRIO_REG, NULL );
    #if ( configUSE_PREEMPTION == 1 )
        prvCreate( prvRegTestEntry2, "rt2", 90, REGTEST2_PARAM, PRIO_REG, NULL );
    #endif
    prvCreate( vRegTest3Task, "rt3", 64, NULL, PRIO_REG, NULL );

    hal_puts( "  irq: profile=" );
    hal_putdec( ulIrqProfile );
    hal_puts( " delay=" );
    hal_putdec( ulIrqMin );
    hal_puts( "+[0," );
    hal_putdec( ulIrqSpan );
    hal_puts( ") cycles, heap free after create=" );
    hal_putdec( xPortGetFreeHeapSize() );
    hal_putc( '\n' );

    prvArmIrq();   /* pends until the scheduler enables interrupts */
    vTaskStartScheduler();
    hal_fail( "vTaskStartScheduler returned", NULL, 0, 0 );
}
