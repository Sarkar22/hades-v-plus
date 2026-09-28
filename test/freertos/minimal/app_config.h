/* minimal: settings on top of common/FreeRTOSConfig.h */
#define configTOTAL_HEAP_SIZE      ( ( size_t ) ( 5 * 1024 ) )
#define configMAX_PRIORITIES       ( 4 )
#define configUSE_IDLE_HOOK        1

/* Run length in ticks = FRTOS_NCHECKS * FRTOS_CHECK_TICKS (the campaign sets
 * both from the tick period; minimal checks once, at the end). */
#ifndef FRTOS_NCHECKS
#define FRTOS_NCHECKS              1
#endif
#ifndef FRTOS_CHECK_TICKS
#define FRTOS_CHECK_TICKS          300
#endif
#define FRTOS_RUN_TICKS            ( FRTOS_NCHECKS * FRTOS_CHECK_TICKS )
