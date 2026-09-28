/* brk: settings on top of common/FreeRTOSConfig.h */
#ifdef __OPTIMIZE__
#define configMINIMAL_STACK_SIZE                ( ( unsigned short ) 160 )
#define configTOTAL_HEAP_SIZE                   ( ( size_t ) ( 22 * 1024 ) )
#else
#define configMINIMAL_STACK_SIZE                ( ( unsigned short ) 256 )
#define configTOTAL_HEAP_SIZE                   ( ( size_t ) ( 60 * 1024 ) )
#endif
#define configMAX_PRIORITIES                    ( 10 )
#define configUSE_MUTEXES                       1
#define configUSE_RECURSIVE_MUTEXES             1
#define configUSE_TICK_HOOK                     1
#define configUSE_IDLE_HOOK                     1
#define configTASK_NOTIFICATION_ARRAY_ENTRIES   3
#define INCLUDE_vTaskDelete                     1
#define INCLUDE_uxTaskPriorityGet               1
#define INCLUDE_vTaskPrioritySet                1
#define INCLUDE_xSemaphoreGetMutexHolder        1

/* Run length: FRTOS_NCHECKS check periods of FRTOS_CHECK_TICKS ticks each. */
#ifndef FRTOS_NCHECKS
#define FRTOS_NCHECKS                           8
#endif
#ifndef FRTOS_CHECK_TICKS
#define FRTOS_CHECK_TICKS                       100
#endif

/* Scenario switches (all on by default). */
#ifndef BRK_STORM
#define BRK_STORM          1   /* external-interrupt storms + ISR stream/message buffers */
#endif
#ifndef BRK_TPAST
#define BRK_TPAST          1   /* mtimecmp in the past / near future, multi-tick critical sections */
#endif
#ifndef BRK_NEST
#define BRK_NEST           1   /* nested critical sections (+ yields inside), nested suspend-all */
#endif
#ifndef BRK_DIS
#define BRK_DIS            1   /* taskYIELD() with interrupts disabled outside critical sections */
#endif
#ifndef BRK_CHURN
#define BRK_CHURN          1   /* create / vTaskDelete(NULL) / vTaskDelete(other) churn */
#endif
#ifndef BRK_PI
#if ( FRTOS_PREEMPT == 1 )
#define BRK_PI             1   /* priority-inheritance chain L<-M<-H (+ timeouts) and hogs */
#else
#define BRK_PI             0   /* its step-by-step checks assume preemption */
#endif
#endif
#ifndef BRK_FENCEI
#define BRK_FENCEI         1   /* self-modifying code + fence.i from two tasks */
#endif
#ifndef BRK_BPDYN
#define BRK_BPDYN          0   /* random MHPMEVENT10 (branch predictor mode) writes at run time */
#endif
#ifndef BRK_PIPE
#define BRK_PIPE           1   /* pipebrk.S register-integrity task (divides with M) */
#endif
#ifndef BRK_EXC
#define BRK_EXC            1   /* deliberate exceptions (illegal, ebreak, misaligned, access faults,
                                * misaligned jalr, bad CSR) from a task + side-effecting counter reads */
#endif
#ifndef BRK_WFI
#define BRK_WFI            1   /* wfi in the idle hook */
#endif
#ifndef BRK_SLOWBUS
#define BRK_SLOWBUS        1   /* idle hook: VGA / stall-register accesses */
#endif
