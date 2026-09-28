/* full: settings on top of common/FreeRTOSConfig.h, mirroring the official
 * FreeRTOS/Demo/RISC-V_RV32_QEMU_VIRT_GCC/FreeRTOSConfig.h where it matters. */
#define configMAX_PRIORITIES                    ( 9UL )
#define configUSE_PORT_OPTIMISED_TASK_SELECTION 1
#ifdef __OPTIMIZE__
#define configMINIMAL_STACK_SIZE                ( ( unsigned short ) 160 )
#else
#define configMINIMAL_STACK_SIZE                ( ( unsigned short ) 256 )
#endif
#define configTOTAL_HEAP_SIZE                   ( ( size_t ) ( 120 * 1024 ) )
#define configMAX_TASK_NAME_LEN                 ( 12 )
#define configIDLE_SHOULD_YIELD                 0
#define configUSE_TICK_HOOK                     1
#define configUSE_TRACE_FACILITY                1
#define configUSE_RECURSIVE_MUTEXES             1
#define configUSE_QUEUE_SETS                    1
#define configQUEUE_REGISTRY_SIZE               10
#define configSUPPORT_STATIC_ALLOCATION         1
#define configTASK_NOTIFICATION_ARRAY_ENTRIES   3

#define configUSE_TIMERS                        1
#define configTIMER_TASK_PRIORITY               ( configMAX_PRIORITIES - 3 )
#define configTIMER_QUEUE_LENGTH                20
#define configTIMER_TASK_STACK_DEPTH            ( configMINIMAL_STACK_SIZE * 2 )

#define INCLUDE_vTaskPrioritySet                1
#define INCLUDE_uxTaskPriorityGet               1
#define INCLUDE_vTaskDelete                     1
#define INCLUDE_xTaskGetSchedulerState          1
#define INCLUDE_xTimerGetTimerDaemonTaskHandle  1
#define INCLUDE_xTaskGetIdleTaskHandle          1
#define INCLUDE_xSemaphoreGetMutexHolder        1
#define INCLUDE_eTaskGetState                   1
#define INCLUDE_xTimerPendFunctionCall          1
#define INCLUDE_xTaskAbortDelay                 1
#define INCLUDE_xTaskGetCurrentTaskHandle       1
#define INCLUDE_xTaskGetHandle                  1

/* The official demo sets this to 1; its only effect is MessageBufferDemo's
 * "space available coherence" tasks. Off here: that test trips on a genuine
 * race in xStreamBufferSpacesAvailable() on any CPU -- the tester is preempted
 * twice inside its re-read loop while the actor completes exactly 7 cycles
 * (9 bytes each on a 21-byte ring), so xTail reads back unchanged (ABA) and an
 * inconsistent size is accepted. Seen on the golden CPU (slicing off) and on
 * the DUT (-O0) with every bus access to xHead/xTail returning the last value
 * written, i.e. not a CPU fault. */
#define configRUN_ADDITIONAL_TESTS              0
#define configSTREAM_BUFFER_TRIGGER_LEVEL_TEST_MARGIN   2
#define intqHIGHER_PRIORITY                     ( configMAX_PRIORITIES - 5 )
#define bktPRIMARY_PRIORITY                     ( configMAX_PRIORITIES - 4 )
#define bktSECONDARY_PRIORITY                   ( configMAX_PRIORITIES - 5 )

/* Check task: every FRTOS_CHECK_TICKS ticks (5000 as in the official demo;
 * TimerDemo needs at least ~3000), PASS after FRTOS_NCHECKS clean periods. */
#ifndef FRTOS_NCHECKS
#define FRTOS_NCHECKS                           3
#endif
#ifndef FRTOS_CHECK_TICKS
#define FRTOS_CHECK_TICKS                       5000
#endif

/* Random external interrupts (wishbone_test) on top of the demo, only to
 * desynchronise interrupt timing; mean interval in cycles. 0 = off. */
#ifndef FULL_EXT_IRQ_MEAN
#define FULL_EXT_IRQ_MEAN                       6000
#endif
