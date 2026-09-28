/* full: the FreeRTOS standard demo task set ("Common/Minimal") as created by
 * the official FreeRTOS/Demo/RISC-V_RV32_QEMU_VIRT_GCC main_full.c, on HaDes-V+.
 *
 * Demo sets: blocktim, dynamic, GenQTest, recmutex, TimerDemo, EventGroupsDemo,
 * TaskNotify, AbortDelay, countsem, MessageBufferDemo, StreamBufferDemo,
 * StreamBufferInterrupt, QueueOverwrite, QueueSet, semtest, BlockQ, PollQ,
 * IntSemTest, plus the RISC-V port RegTest tasks. Their interrupt-side halves
 * run from the tick hook exactly as in the official demo.
 *
 * Unlike the official check task (which only prints), this one FAILS the run
 * the first time any xAre...StillRunning() reports an error or stalled task,
 * or a RegTest loop counter stops, and PASSes after FRTOS_NCHECKS periods.
 * A random external interrupt (wishbone_test) desynchronises interrupt timing.
 */
#include "FreeRTOS.h"
#include "task.h"
#include "queue.h"
#include "semphr.h"
#include "hades_hal.h"

#include "blocktim.h"
#include "dynamic.h"
#include "GenQTest.h"
#include "recmutex.h"
#include "TimerDemo.h"
#include "EventGroupsDemo.h"
#include "TaskNotify.h"
#include "AbortDelay.h"
#include "countsem.h"
#include "MessageBufferDemo.h"
#include "StreamBufferDemo.h"
#include "StreamBufferInterrupt.h"
#include "QueueOverwrite.h"
#include "QueueSet.h"
#include "semtest.h"
#include "BlockQ.h"
#include "PollQ.h"
#include "IntSemTest.h"

/* Priorities as in the official main_full.c. */
#define mainQUEUE_POLL_PRIORITY          ( tskIDLE_PRIORITY + 2 )
#define mainCHECK_TASK_PRIORITY          ( configMAX_PRIORITIES - 1 )
#define mainSEM_TEST_PRIORITY            ( tskIDLE_PRIORITY + 1 )
#define mainBLOCK_Q_PRIORITY             ( tskIDLE_PRIORITY + 2 )
#define mainGEN_QUEUE_TASK_PRIORITY      ( tskIDLE_PRIORITY )
#define mainMESSAGE_BUFFER_STACK_SIZE    ( configMINIMAL_STACK_SIZE + ( configMINIMAL_STACK_SIZE >> 1 ) )
#define mainCHECK_TASK_STACK_SIZE        ( configMINIMAL_STACK_SIZE * 2 )
#define mainREG_TEST_STACK_SIZE_WORDS    90
#define mainTIMER_TEST_PERIOD            ( 50 )

#define mainREG_TEST_TASK_1_PARAMETER    ( ( void * ) 0x12345678 )
#define mainREG_TEST_TASK_2_PARAMETER    ( ( void * ) 0x87654321 )

volatile uint32_t ulRegTest1LoopCounter = 0UL, ulRegTest2LoopCounter = 0UL;
extern void vRegTest1Implementation( void );
extern void vRegTest2Implementation( void );

static uint32_t ulIrqSeed;
static volatile uint32_t ulExtIrqs;

/* ------------------------------------------------------------- interrupts */

void vApplicationTickHook( void )
{
    /* Identical to vFullDemoTickHookFunction() of the official demo, minus the
     * demo sets not built here. */
    vQueueSetAccessQueueSetFromISR();
    vPeriodicEventGroupsProcessing();
    vPeriodicStreamBufferProcessing();
    vQueueOverwritePeriodicISRDemo();
    xNotifyTaskFromISR();
    vTimerPeriodicISRTests();
    vBasicStreamBufferSendFromISR();
    vInterruptSemaphorePeriodicTest();
}

static void prvArmIrq( void )
{
    #if ( FULL_EXT_IRQ_MEAN > 0 )
        HADES_TEST_IRQ = 1u + ( hal_rand( &ulIrqSeed ) % ( 2u * FULL_EXT_IRQ_MEAN ) );
    #endif
}

void app_external_irq( void )
{
    prvArmIrq();
    ulExtIrqs++;
}

/* ------------------------------------------------------------------ tasks */

static void prvRegTestTaskEntry1( void * pvParameters )
{
    if( pvParameters == mainREG_TEST_TASK_1_PARAMETER )
    {
        vRegTest1Implementation();
    }

    hal_fail( "Reg1: wrong task parameter", NULL, ( uint32_t ) ( uintptr_t ) pvParameters, 0 );
}

static void prvRegTestTaskEntry2( void * pvParameters )
{
    if( pvParameters == mainREG_TEST_TASK_2_PARAMETER )
    {
        vRegTest2Implementation();
    }

    hal_fail( "Reg2: wrong task parameter", NULL, ( uint32_t ) ( uintptr_t ) pvParameters, 0 );
}

typedef struct
{
    const char * pcName;
    BaseType_t ( * pxCheck )( void );
} DemoCheck_t;

static BaseType_t prvTimerCheck( void )
{
    return xAreTimerDemoTasksStillRunning( FRTOS_CHECK_TICKS );
}

static const DemoCheck_t xChecks[] =
{
    { "StreamBuffer",          xAreStreamBufferTasksStillRunning         },
    { "MessageBuffer",         xAreMessageBufferTasksStillRunning        },
    { "GenQTest",              xAreGenericQueueTasksStillRunning         },
    { "blocktim",              xAreBlockTimeTestTasksStillRunning        },
    { "semtest",               xAreSemaphoreTasksStillRunning            },
    { "PollQ",                 xArePollingQueuesStillRunning             },
    { "BlockQ",                xAreBlockingQueuesStillRunning            },
    { "recmutex",              xAreRecursiveMutexTasksStillRunning       },
    { "QueueSet",              xAreQueueSetTasksStillRunning             },
    { "EventGroups",           xAreEventGroupTasksStillRunning           },
    { "AbortDelay",            xAreAbortDelayTestTasksStillRunning       },
    { "countsem",              xAreCountingSemaphoreTasksStillRunning    },
    { "dynamic",               xAreDynamicPriorityTasksStillRunning      },
    { "QueueOverwrite",        xIsQueueOverwriteTaskStillRunning         },
    { "TaskNotify",            xAreTaskNotificationTasksStillRunning     },
    { "TimerDemo",             prvTimerCheck                             },
    { "StreamBufferInterrupt", xIsInterruptStreamBufferDemoStillRunning  },
    { "IntSemTest",            xAreInterruptSemaphoreTasksStillRunning   },
};

static void prvCheckTask( void * pvParameters )
{
    TickType_t xPreviousWakeTime = xTaskGetTickCount();
    const TickType_t xT0 = xPreviousWakeTime;
    const uint32_t ulM0 = hal_mtime();
    uint32_t ulLastRegTest1 = 0, ulLastRegTest2 = 0;

    ( void ) pvParameters;
    hal_puts( "  demo started\n" );

    for( uint32_t n = 1; n <= FRTOS_NCHECKS; n++ )
    {
        vTaskDelayUntil( &xPreviousWakeTime, FRTOS_CHECK_TICKS );

        for( size_t i = 0; i < sizeof( xChecks ) / sizeof( xChecks[ 0 ] ); i++ )
        {
            if( xChecks[ i ].pxCheck() != pdTRUE )
            {
                hal_fail( "demo task set reported an error or stalled (check period, tick)", xChecks[ i ].pcName, n, xTaskGetTickCount() );
            }
        }

        if( ulRegTest1LoopCounter == ulLastRegTest1 )
        {
            hal_fail( "demo task set reported an error or stalled (check period, tick)", "RegTest1", n, xTaskGetTickCount() );
        }

        if( ulRegTest2LoopCounter == ulLastRegTest2 )
        {
            hal_fail( "demo task set reported an error or stalled (check period, tick)", "RegTest2", n, xTaskGetTickCount() );
        }

        ulLastRegTest1 = ulRegTest1LoopCounter;
        ulLastRegTest2 = ulRegTest2LoopCounter;

        {
            uint32_t ulTicks, ulHw;

            taskENTER_CRITICAL();
            ulTicks = xTaskGetTickCount() - xT0;
            ulHw = ( hal_mtime() - ulM0 ) / FRTOS_TICK_CYCLES;
            taskEXIT_CRITICAL();

            if( ( ulTicks + 2u < ulHw ) || ( ulTicks > ulHw + 2u ) )
            {
                hal_fail( "tick drift (sw ticks, mtime ticks)", NULL, ulTicks, ulHw );
            }
        }

        hal_pattern_line();
        hal_puts( "  check " );
        hal_putdec( n );
        hal_puts( ": all demo tasks OK, tick=" );
        hal_putdec( xTaskGetTickCount() );
        hal_puts( " rt1=" );
        hal_putdec( ulRegTest1LoopCounter );
        hal_puts( " rt2=" );
        hal_putdec( ulRegTest2LoopCounter );
        hal_puts( " ext-irqs=" );
        hal_putdec( ulExtIrqs );
        hal_putc( '\n' );
    }

    hal_puts( "  heap free now/min=" );
    hal_putdec( xPortGetFreeHeapSize() );
    hal_putc( '/' );
    hal_putdec( xPortGetMinimumEverFreeHeapSize() );
    hal_puts( " isr-stack-peak=" );
    hal_putdec( hal_isr_stack_peak() );
    hal_putc( '/' );
    hal_putdec( hal_isr_stack_size() );
    hal_pass();
}

int main( void )
{
    hal_begin( "full (FreeRTOS standard demo tasks)" );
    ulIrqSeed = hal_seed() ^ 0xF011u;

    vStartGenericQueueTasks( mainGEN_QUEUE_TASK_PRIORITY );
    vStartRecursiveMutexTasks();
    vCreateBlockTimeTasks();
    vStartSemaphoreTasks( mainSEM_TEST_PRIORITY );
    vStartPolledQueueTasks( mainQUEUE_POLL_PRIORITY );
    vStartBlockingQueueTasks( mainBLOCK_Q_PRIORITY );
    vStartQueueSetTasks();
    vStartEventGroupTasks();
    vStartMessageBufferTasks( mainMESSAGE_BUFFER_STACK_SIZE );
    vStartStreamBufferTasks();
    vCreateAbortDelayTasks();
    vStartCountingSemaphoreTasks();
    vStartDynamicPriorityTasks();
    vStartQueueOverwriteTask( tskIDLE_PRIORITY );
    vStartTaskNotifyTask();
    vStartTimerDemoTask( mainTIMER_TEST_PERIOD );
    vStartStreamBufferInterruptDemo();
    vStartInterruptSemaphoreTasks();

    if( xTaskCreate( prvRegTestTaskEntry1, "Reg1", mainREG_TEST_STACK_SIZE_WORDS, mainREG_TEST_TASK_1_PARAMETER, tskIDLE_PRIORITY, NULL ) != pdPASS ||
        xTaskCreate( prvRegTestTaskEntry2, "Reg2", mainREG_TEST_STACK_SIZE_WORDS, mainREG_TEST_TASK_2_PARAMETER, tskIDLE_PRIORITY, NULL ) != pdPASS ||
        xTaskCreate( prvCheckTask, "Check", mainCHECK_TASK_STACK_SIZE, NULL, mainCHECK_TASK_PRIORITY, NULL ) != pdPASS )
    {
        hal_fail( "xTaskCreate", NULL, 0, 0 );
    }

    hal_puts( "  heap free after create=" );
    hal_putdec( xPortGetFreeHeapSize() );
    hal_putc( '\n' );

    prvArmIrq();
    vTaskStartScheduler();
    hal_fail( "vTaskStartScheduler returned", NULL, 0, 0 );
}
