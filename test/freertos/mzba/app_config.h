/* mzba: settings on top of common/FreeRTOSConfig.h */
#ifdef __OPTIMIZE__
#define configMINIMAL_STACK_SIZE       ( ( unsigned short ) 160 )
#define configTOTAL_HEAP_SIZE          ( ( size_t ) ( 7 * 1024 ) )
#else
#define configMINIMAL_STACK_SIZE       ( ( unsigned short ) 256 )
#define configTOTAL_HEAP_SIZE          ( ( size_t ) ( 10 * 1024 ) )
#endif
#define configMAX_PRIORITIES           ( 6 )
#define configUSE_MUTEXES              0

#ifndef FRTOS_NCHECKS
#define FRTOS_NCHECKS                  20
#endif
#ifndef FRTOS_CHECK_TICKS
#define FRTOS_CHECK_TICKS              25
#endif

/* Mean interval (cycles) of the random external interrupt. Short on purpose:
 * most interrupts should land inside a divide. */
#ifndef MZBA_IRQ_MEAN
#if defined( __riscv_mul ) && defined( __OPTIMIZE__ )
#define MZBA_IRQ_MEAN                  2500
#elif defined( __riscv_mul ) || defined( __OPTIMIZE__ )
#define MZBA_IRQ_MEAN                  6000   /* ISR divides in software, or -O0 */
#else
#define MZBA_IRQ_MEAN                  15000
#endif
#endif
