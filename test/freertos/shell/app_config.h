/* shell: settings on top of common/FreeRTOSConfig.h */
#include <stdint.h>

/* Heap for the console task (320 words of stack at -Os), blink, idle, the receive
 * queue and the CLI's command list; 'mem' shows how much of it is used. */
#define configTOTAL_HEAP_SIZE                  ( ( size_t ) ( 4608 ) )
#define configMAX_PRIORITIES                   ( 4 )
#define configMAX_TASK_NAME_LEN                ( 10 )

/* No mutexes: the console serialises its output by suspending the scheduler per line
 * (console.c), and the mutex code would not fit in 32 KiB. */
#define configUSE_MUTEXES                      0

/* 'tasks' and 'stats': uxTaskGetSystemState() and per-task run-time counters. The
 * run-time clock is the 64-bit mcycle CSR (one count per CPU cycle, implemented by
 * HaDes-V+ and by the golden CPU), counted from the start of the scheduler; 64 bits,
 * so the counters do not wrap. */
#define configUSE_TRACE_FACILITY               1
#define configGENERATE_RUN_TIME_STATS          1
#define configRUN_TIME_COUNTER_TYPE            uint64_t
#define portCONFIGURE_TIMER_FOR_RUN_TIME_STATS()    shell_run_time_start()
#define portGET_RUN_TIME_COUNTER_VALUE()            shell_run_time()
void shell_run_time_start( void );
uint64_t shell_run_time( void );

/* FreeRTOS+CLI: the buffer each command writes its output into (bytes). */
#define configCOMMAND_INT_MAX_OUTPUT_SIZE      512
