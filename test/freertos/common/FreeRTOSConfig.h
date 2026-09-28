/* Shared FreeRTOSConfig.h for the HaDes-V+ FreeRTOS test programs
 * (M-mode only, RV32I/RV32IM/RV32IM_Zba, wishbone_timer as the RISC-V mtime).
 *
 * Build-time knobs, normally passed by test/freertos/freertos.mk as -D flags:
 *   FRTOS_TICK_CYCLES  CPU clock cycles per RTOS tick (mtime counts CPU cycles)
 *   FRTOS_PREEMPT      configUSE_PREEMPTION   (default 1)
 *   FRTOS_SLICE        configUSE_TIME_SLICING (default 1)
 *   FRTOS_HEAP         heap implementation in use: 1 (heap_1.c) or 4 (heap_4.c)
 * Every program provides app_config.h (first on the include path) for its own
 * sizes and features; the values below are only defaults.
 */
#ifndef FREERTOS_CONFIG_H
#define FREERTOS_CONFIG_H

#include "app_config.h"

/* ---------------------------------------------------------------- timing -- */
/* The tick is counted in CPU cycles: the port programs mtimecmp in steps of
 * configCPU_CLOCK_HZ / configTICK_RATE_HZ = FRTOS_TICK_CYCLES. The tick rate
 * stays nominally 1 kHz so that the pdMS_TO_TICKS() constants of the standard
 * demo tasks keep their meaning ("1 ms" = one tick); only the CPU time
 * available per tick changes with FRTOS_TICK_CYCLES. */
#ifndef FRTOS_TICK_CYCLES
#define FRTOS_TICK_CYCLES                       10000
#endif
#define configTICK_RATE_HZ                      ( ( TickType_t ) 1000 )
#define configCPU_CLOCK_HZ                      ( ( unsigned long ) FRTOS_TICK_CYCLES * 1000UL )

/* wishbone_timer: word address TIMER_START = 0x85000 -> byte 0x214000.
 * +0x0 status, +0x4 mtime, +0x8 mtimeh, +0xC mtimecmp, +0x10 mtimecmph */
#define configMTIME_BASE_ADDRESS                ( 0x00214004UL )
#define configMTIMECMP_BASE_ADDRESS             ( 0x0021400CUL )

/* ------------------------------------------------------------ scheduling -- */
#ifndef FRTOS_PREEMPT
#define FRTOS_PREEMPT                           1
#endif
#ifndef FRTOS_SLICE
#define FRTOS_SLICE                             1
#endif
#define configUSE_PREEMPTION                    FRTOS_PREEMPT
#define configUSE_TIME_SLICING                  FRTOS_SLICE
#ifndef configUSE_PORT_OPTIMISED_TASK_SELECTION
#define configUSE_PORT_OPTIMISED_TASK_SELECTION 0
#endif
#ifndef configMAX_PRIORITIES
#define configMAX_PRIORITIES                    ( 7 )
#endif
#ifndef configMINIMAL_STACK_SIZE
#define configMINIMAL_STACK_SIZE                ( ( unsigned short ) 160 )   /* words */
#endif
#ifndef configMAX_TASK_NAME_LEN
#define configMAX_TASK_NAME_LEN                 ( 10 )
#endif
#define configTICK_TYPE_WIDTH_IN_BITS           TICK_TYPE_WIDTH_32_BITS
#ifndef configIDLE_SHOULD_YIELD
#define configIDLE_SHOULD_YIELD                 1
#endif
#define configNUMBER_OF_CORES                   1
#define configUSE_CO_ROUTINES                   0

/* ---------------------------------------------------------------- memory -- */
#ifndef FRTOS_HEAP
#define FRTOS_HEAP                              4
#endif
#ifndef configTOTAL_HEAP_SIZE
#define configTOTAL_HEAP_SIZE                   ( ( size_t ) ( 10 * 1024 ) )
#endif
#define configSUPPORT_DYNAMIC_ALLOCATION        1
#ifndef configSUPPORT_STATIC_ALLOCATION
#define configSUPPORT_STATIC_ALLOCATION         0
#endif
#define configKERNEL_PROVIDED_STATIC_MEMORY     1
/* ISR stack: configISR_STACK_SIZE_WORDS is deliberately left undefined so the
 * port uses __freertos_irq_stack_top from hades-freertos.ld. */

/* ------------------------------------------------------ failure detection -- */
/* Every program fails loudly: assertion, stack overflow (pattern check) and
 * malloc failure all end the simulation with "FRTOS-RESULT: FAIL ...". */
#define configCHECK_FOR_STACK_OVERFLOW          2
#define configUSE_MALLOC_FAILED_HOOK            1
void vAssertCalled( const char * pcFile, unsigned long ulLine );
#define configASSERT( x )    do { if( ( x ) == 0 ) vAssertCalled( __FILE_NAME__, __LINE__ ); } while( 0 )

/* --------------------------------------------------------------- features -- */
#ifndef configUSE_IDLE_HOOK
#define configUSE_IDLE_HOOK                     0
#endif
#ifndef configUSE_TICK_HOOK
#define configUSE_TICK_HOOK                     0
#endif
#ifndef configUSE_TIMERS
#define configUSE_TIMERS                        0
#endif
#ifndef configTIMER_TASK_PRIORITY
#define configTIMER_TASK_PRIORITY               ( configMAX_PRIORITIES - 1 )
#endif
#ifndef configTIMER_QUEUE_LENGTH
#define configTIMER_QUEUE_LENGTH                8
#endif
#ifndef configTIMER_TASK_STACK_DEPTH
#define configTIMER_TASK_STACK_DEPTH            ( configMINIMAL_STACK_SIZE * 2 )
#endif
#ifndef configUSE_MUTEXES
#define configUSE_MUTEXES                       1
#endif
#ifndef configUSE_RECURSIVE_MUTEXES
#define configUSE_RECURSIVE_MUTEXES             0
#endif
#ifndef configUSE_COUNTING_SEMAPHORES
#define configUSE_COUNTING_SEMAPHORES           1
#endif
#ifndef configUSE_QUEUE_SETS
#define configUSE_QUEUE_SETS                    0
#endif
#ifndef configQUEUE_REGISTRY_SIZE
#define configQUEUE_REGISTRY_SIZE               0
#endif
#define configUSE_TASK_NOTIFICATIONS            1
#ifndef configTASK_NOTIFICATION_ARRAY_ENTRIES
#define configTASK_NOTIFICATION_ARRAY_ENTRIES   1
#endif
#ifndef configUSE_TRACE_FACILITY
#define configUSE_TRACE_FACILITY                0
#endif
#define configUSE_STATS_FORMATTING_FUNCTIONS    0
#define configGENERATE_RUN_TIME_STATS           0

#ifndef INCLUDE_vTaskPrioritySet
#define INCLUDE_vTaskPrioritySet                0
#endif
#ifndef INCLUDE_uxTaskPriorityGet
#define INCLUDE_uxTaskPriorityGet               0
#endif
#ifndef INCLUDE_vTaskDelete
#define INCLUDE_vTaskDelete                     0
#endif
#define INCLUDE_vTaskSuspend                    1
#define INCLUDE_xTaskDelayUntil                 1
#define INCLUDE_vTaskDelay                      1
#define INCLUDE_uxTaskGetStackHighWaterMark     1
#ifndef INCLUDE_xTaskGetSchedulerState
#define INCLUDE_xTaskGetSchedulerState          1
#endif
#ifndef INCLUDE_xTaskGetCurrentTaskHandle
#define INCLUDE_xTaskGetCurrentTaskHandle       1
#endif
#ifndef INCLUDE_xTaskGetIdleTaskHandle
#define INCLUDE_xTaskGetIdleTaskHandle          0
#endif
#ifndef INCLUDE_xSemaphoreGetMutexHolder
#define INCLUDE_xSemaphoreGetMutexHolder        0
#endif
#ifndef INCLUDE_eTaskGetState
#define INCLUDE_eTaskGetState                   0
#endif
#ifndef INCLUDE_xTimerPendFunctionCall
#define INCLUDE_xTimerPendFunctionCall          0
#endif
#ifndef INCLUDE_xTaskAbortDelay
#define INCLUDE_xTaskAbortDelay                 0
#endif
#ifndef INCLUDE_xTaskGetHandle
#define INCLUDE_xTaskGetHandle                  0
#endif

#endif /* FREERTOS_CONFIG_H */
