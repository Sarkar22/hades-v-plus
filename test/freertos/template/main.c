/* main.c -- template FreeRTOS program for HaDes-V+.
 *
 * Copy it into a program of your own and run it:
 *     make freertos-new NAME=myapp            (creates test/freertos/myapp/)
 *     make freertos APP=myapp                 (on the DUT)
 *     make freertos APP=myapp CPU=golden      (the same program on the golden CPU)
 * Every .c and .S file in the program's directory is built (see app.mk); FreeRTOS settings
 * are in app_config.h. docs/FREERTOS.md describes all knobs and the output.
 *
 * What this program does
 *   producer (priority 2)  every 5 ticks, sends 1, 2, 3, ... into a queue of 4 items
 *   consumer (priority 1)  receives the numbers, checks their order, prints one line per
 *                          item, and after TEMPLATE_ITEMS items reports PASS
 *   irq      (priority 3)  only with TEMPLATE_WITH_IRQ=1: counts external interrupts that
 *                          the interrupt handler app_external_irq() signals with a semaphore
 *
 * Rules of the road
 *   - Start main() with hal_begin(). It prints the banner, the build configuration and the
 *     run seed, and writes the test register's "initial" marker (the simulator prints it
 *     as "Test fail!" -- deliberate, it is how the test protocol counts).
 *   - End the run with hal_pass() or hal_fail(why, detail, a, b). They print
 *     "FRTOS-RESULT: PASS" or "FRTOS-RESULT: FAIL <why> [<detail>] a=<hex> b=<hex>" and stop
 *     the simulation. A program that calls neither runs into the cycle limit (TIMEOUT) and
 *     is reported as HANG.
 *   - Output: hal_putc(), hal_puts(), hal_putdec() and hal_puthex() write to the UART, which
 *     the simulator prints to the terminal. Tasks that print at the same time interleave
 *     character by character: print a line inside vTaskSuspendAll()/xTaskResumeAll(), or
 *     with hal_puts_atomic(), or from one task only. Never print from an interrupt handler.
 *     There is no printf() (no stdio in the image).
 *   - Time: one tick is TICK=<cycles> CPU cycles (default 10000). configTICK_RATE_HZ is
 *     1000, so pdMS_TO_TICKS( n ) is n ticks. hal_mtime() reads the cycle counter mtime.
 *   - Randomness: hal_seed() depends on SEED=<hex>; hal_rand( &state ) is a fast PRNG.
 *   - Failures are loud: configASSERT(), a stack overflow, a failed allocation and any
 *     unexpected exception or interrupt end the run with FRTOS-RESULT: FAIL.
 *   - The program runs unchanged on the golden CPU if it is built for rv32i (the default).
 */
#include "FreeRTOS.h"
#include "task.h"
#include "queue.h"
#include "semphr.h"
#include "hades_hal.h"

static QueueHandle_t xQueue;

#if ( TEMPLATE_WITH_IRQ == 1 )
static SemaphoreHandle_t xIrqSemaphore;
static volatile uint32_t ulIrqCount;

/* Cycles from arming the simulation's test interrupt source until it fires. */
#define TEMPLATE_IRQ_CYCLES    7919u

/* Machine external interrupt handler. The FreeRTOS trap handler calls it (through
 * test/freertos/common/hades_hal.c) on the interrupt stack with interrupts disabled.
 * Keep it short and use only the ...FromISR() kernel functions here. */
void app_external_irq( void )
{
    BaseType_t xHigherPriorityTaskWoken = pdFALSE;

    /* The wishbone_test source holds its interrupt line until it is written again:
     * writing N > 0 drops the line and raises it again N cycles later (0 disables it). */
    HADES_TEST_IRQ = TEMPLATE_IRQ_CYCLES;

    xSemaphoreGiveFromISR( xIrqSemaphore, &xHigherPriorityTaskWoken );

    /* Switch to the irq task right away if it has a higher priority than the task that
     * was interrupted. */
    portYIELD_FROM_ISR( xHigherPriorityTaskWoken );
}

static void prvIrqTask( void * pvParameters )
{
    ( void ) pvParameters;

    HADES_TEST_IRQ = TEMPLATE_IRQ_CYCLES;   /* first interrupt */

    for( ; ; )
    {
        if( xSemaphoreTake( xIrqSemaphore, portMAX_DELAY ) == pdTRUE )
        {
            ulIrqCount++;
        }
    }
}
#endif /* TEMPLATE_WITH_IRQ */

static void prvProducer( void * pvParameters )
{
    ( void ) pvParameters;

    for( uint32_t ulItem = 1; ; ulItem++ )
    {
        /* Block (let other tasks run) for 5 ticks. */
        vTaskDelay( pdMS_TO_TICKS( 5 ) );

        /* portMAX_DELAY: wait for as long as it takes until the queue has room. */
        if( xQueueSend( xQueue, &ulItem, portMAX_DELAY ) != pdPASS )
        {
            hal_fail( "producer: xQueueSend(portMAX_DELAY) failed", NULL, ulItem, 0 );
        }
    }
}

static void prvConsumer( void * pvParameters )
{
    uint32_t ulExpected = 1;
    uint32_t ulItem;

    ( void ) pvParameters;

    for( ; ; )
    {
        /* With portMAX_DELAY this returns only once an item has arrived. */
        if( xQueueReceive( xQueue, &ulItem, portMAX_DELAY ) != pdPASS )
        {
            hal_fail( "consumer: xQueueReceive(portMAX_DELAY) returned without an item", NULL, ulExpected, 0 );
        }

        if( ulItem != ulExpected )
        {
            hal_fail( "consumer: item out of order (got, expected)", NULL, ulItem, ulExpected );
        }

        /* One line, not interleaved with other tasks' output. */
        vTaskSuspendAll();
        hal_puts( "  consumer: item " );
        hal_putdec( ulItem );
        hal_puts( " at tick " );
        hal_putdec( xTaskGetTickCount() );
        hal_putc( '\n' );
        ( void ) xTaskResumeAll();

        if( ulItem == TEMPLATE_ITEMS )
        {
            hal_puts( "  received " );
            hal_putdec( ulItem );
            hal_puts( " items in order; main/ISR stack used " );
            hal_putdec( hal_isr_stack_peak() );
            hal_putc( '/' );
            hal_putdec( hal_isr_stack_size() );
            hal_puts( " bytes" );
            #if ( TEMPLATE_WITH_IRQ == 1 )
                hal_puts( "; external interrupts " );
                hal_putdec( ulIrqCount );

                if( ulIrqCount == 0u )
                {
                    hal_fail( "no external interrupt was handled", NULL, 0, 0 );
                }
            #endif
            hal_pass();   /* prints FRTOS-RESULT: PASS and stops the simulation */
        }

        ulExpected++;
    }
}

int main( void )
{
    hal_begin( __FILE__ );

    xQueue = xQueueCreate( 4, sizeof( uint32_t ) );

    if( xQueue == NULL )
    {
        hal_fail( "xQueueCreate failed (raise configTOTAL_HEAP_SIZE in app_config.h)", NULL, 0, 0 );
    }

    if( ( xTaskCreate( prvProducer, "producer", configMINIMAL_STACK_SIZE, NULL, 2, NULL ) != pdPASS ) ||
        ( xTaskCreate( prvConsumer, "consumer", configMINIMAL_STACK_SIZE, NULL, 1, NULL ) != pdPASS ) )
    {
        hal_fail( "xTaskCreate failed (raise configTOTAL_HEAP_SIZE in app_config.h)", NULL, 0, 0 );
    }

    #if ( TEMPLATE_WITH_IRQ == 1 )
        xIrqSemaphore = xSemaphoreCreateBinary();

        if( ( xIrqSemaphore == NULL ) ||
            ( xTaskCreate( prvIrqTask, "irq", configMINIMAL_STACK_SIZE, NULL, 3, NULL ) != pdPASS ) )
        {
            hal_fail( "creating the irq task failed", NULL, 0, 0 );
        }
    #endif

    /* Start the tasks. From here on, the kernel runs the program; this call only returns
     * if the idle task could not be created. */
    vTaskStartScheduler();
    hal_fail( "vTaskStartScheduler returned", NULL, 0, 0 );
}
