/* minimal: the smallest meaningful FreeRTOS system -- two application tasks
 * and the idle task.
 *
 *   "main"   (priority 2) sleeps a random 1..4 ticks, then gives a
 *            direct-to-task notification to "worker", spins a random while.
 *   "worker" (priority 1) blocks in ulTaskNotifyTake(portMAX_DELAY) and spins.
 *   idle     counts in the idle hook.
 *
 * Checks: every notification is received exactly once (a take with
 * portMAX_DELAY may never return 0 -- that happens only if the blocking ECALL
 * yield was lost), the idle task keeps running, and the tick count follows
 * mtime. PASS after FRTOS_RUN_TICKS ticks. */
#include "FreeRTOS.h"
#include "task.h"
#include "hades_hal.h"

/* Sleep at least ~3000 cycles between notifications, so that with very short
 * tick periods (a few hundred cycles) the tick handler plus the two tasks
 * cannot saturate the CPU and starve the idle task on a correct core. */
#define MINIMAL_MIN_SLEEP    ( ( 3000u + FRTOS_TICK_CYCLES - 1u ) / FRTOS_TICK_CYCLES )

static TaskHandle_t xWorker;
static volatile uint32_t ulIdleCount, ulWorkerCount;

void vApplicationIdleHook( void )
{
    ulIdleCount++;
}

static void prvWorker( void * pv )
{
    uint32_t seed = hal_seed() ^ 0x5A5A5A5Au;

    ( void ) pv;

    for( ; ; )
    {
        uint32_t n = ulTaskNotifyTake( pdTRUE, portMAX_DELAY );

        if( n == 0u )
        {
            hal_fail( "worker: ulTaskNotifyTake(portMAX_DELAY) returned 0 (blocking yield lost)", NULL, ulWorkerCount, 0 );
        }

        ulWorkerCount += n;
        hal_spin( hal_rand( &seed ) & 127u );
    }
}

static void prvMain( void * pv )
{
    uint32_t seed = hal_seed();
    uint32_t ulGiven = 0, ulLastIdle = 0;
    const TickType_t xStart = xTaskGetTickCount();
    const uint32_t ulMtime0 = hal_mtime();

    ( void ) pv;

    while( ( xTaskGetTickCount() - xStart ) < FRTOS_RUN_TICKS )
    {
        vTaskDelay( MINIMAL_MIN_SLEEP + ( hal_rand( &seed ) & 3u ) );
        xTaskNotifyGive( xWorker );
        ulGiven++;
        hal_spin( hal_rand( &seed ) & 63u );

        if( ( ulGiven % 32u ) == 0u )
        {
            if( ulIdleCount == ulLastIdle )
            {
                hal_fail( "idle task made no progress", NULL, ulIdleCount, ulGiven );
            }

            ulLastIdle = ulIdleCount;
            hal_pattern_line();
        }
    }

    /* let the worker drain its last notification (it spins after each one) */
    for( uint32_t i = 0; ( i < 100u ) && ( ulWorkerCount != ulGiven ); i++ )
    {
        vTaskDelay( 8 );
    }

    if( ulWorkerCount != ulGiven )
    {
        hal_fail( "notifications given != taken", NULL, ulGiven, ulWorkerCount );
    }

    /* Tick accounting against the free-running mtime: lost or doubled tick
     * interrupts show up as drift. */
    {
        uint32_t ulTicks = xTaskGetTickCount() - xStart;
        uint32_t ulHwTicks = ( hal_mtime() - ulMtime0 ) / FRTOS_TICK_CYCLES;

        if( ( ulTicks + 2u < ulHwTicks ) || ( ulTicks > ulHwTicks + 2u ) )
        {
            hal_fail( "tick drift (sw ticks, mtime ticks)", NULL, ulTicks, ulHwTicks );
        }
    }

    hal_puts( "  ticks=" );
    hal_putdec( xTaskGetTickCount() );
    hal_puts( " notifications=" );
    hal_putdec( ulGiven );
    hal_puts( " idle=" );
    hal_putdec( ulIdleCount );
    hal_puts( " isr-stack-peak=" );
    hal_putdec( hal_isr_stack_peak() );
    hal_putc( '/' );
    hal_putdec( hal_isr_stack_size() );
    hal_pass();
}

int main( void )
{
    hal_begin( "minimal (2 tasks + idle)" );

    if( xTaskCreate( prvWorker, "worker", configMINIMAL_STACK_SIZE, NULL, 1, &xWorker ) != pdPASS ||
        xTaskCreate( prvMain, "main", configMINIMAL_STACK_SIZE, NULL, 2, NULL ) != pdPASS )
    {
        hal_fail( "xTaskCreate", NULL, 0, 0 );
    }

    vTaskStartScheduler();
    hal_fail( "vTaskStartScheduler returned", NULL, 0, 0 );
}
