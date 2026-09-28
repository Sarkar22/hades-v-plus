/* stress: settings on top of common/FreeRTOSConfig.h */
#ifdef __OPTIMIZE__
#define configMINIMAL_STACK_SIZE       ( ( unsigned short ) 128 )
#define configTOTAL_HEAP_SIZE          ( ( size_t ) ( 8 * 1024 + 256 ) )
#else   /* -O0: deeper frames */
#define configMINIMAL_STACK_SIZE       ( ( unsigned short ) 200 )
#define configTOTAL_HEAP_SIZE          ( ( size_t ) ( 15 * 1024 ) )
#endif
#define configMAX_PRIORITIES           ( 7 )
#define configUSE_MUTEXES              0
#define configUSE_TICK_HOOK            1
#define configUSE_IDLE_HOOK            1

/* Run length: FRTOS_NCHECKS check periods of FRTOS_CHECK_TICKS ticks each. */
#ifndef FRTOS_NCHECKS
#define FRTOS_NCHECKS                  20
#endif
#ifndef FRTOS_CHECK_TICKS
#define FRTOS_CHECK_TICKS              25
#endif

/* 1: taskYIELD() from inside critical sections (a deterministic probe of
 * mstatus.MPIE handling on a trap taken with MIE=0). 0 leaves only the
 * kernel's own in-critical-section yields, so the timing-dependent checks
 * get a chance to fire first. */
#ifndef STRESS_CRIT_YIELD
#define STRESS_CRIT_YIELD              1
#endif

/* Shortest mean interval (cycles) the external-interrupt generator may use:
 * below this the ISR load alone starves the tasks, on any correct CPU. */
#ifndef STRESS_IRQ_FLOOR
#ifdef __OPTIMIZE__
#define STRESS_IRQ_FLOOR               4000
#else
#define STRESS_IRQ_FLOOR               10000
#endif
#endif

/* 1: the idle hook keeps writing and reading back a VGA frame-buffer word
 * (3-cycle read) and the wishbone_test stall register (4-cycle access) with
 * interrupts enabled, so interrupts land during multi-cycle bus accesses. On
 * a core whose interrupt JUMP is lost while Memory waits for the bus, the idle
 * task continues with MIE=0, which the hook checks. */
#ifndef STRESS_SLOWBUS
#define STRESS_SLOWBUS                 1
#endif
