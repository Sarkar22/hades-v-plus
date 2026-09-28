/* app_config.h -- this program's FreeRTOS settings.
 *
 * test/freertos/common/FreeRTOSConfig.h includes this file first, so a value defined
 * here replaces the shared default. The tick period (TICK=<cycles>), preemption,
 * time slicing and the heap implementation are make knobs, not settings here; see
 * docs/FREERTOS.md.
 */

/* Heap for task stacks, task control blocks, queues and semaphores (bytes). If
 * xTaskCreate() or xQueueCreate() fails, raise it (and APP_RAM_KB in app.mk if the
 * image no longer fits). */
#define configTOTAL_HEAP_SIZE          ( ( size_t ) ( 8 * 1024 ) )

/* Task priorities run from 0 (idle) to configMAX_PRIORITIES - 1. */
#define configMAX_PRIORITIES           ( 5 )

/* Stack size of the idle task and the unit used for task stacks, in 32-bit words.
 * Stack overflow is detected and fails the run ("stack overflow <task>"). */
#define configMINIMAL_STACK_SIZE       ( ( unsigned short ) 160 )

/* 1: call vApplicationIdleHook() from the idle task (define it in main.c). */
#define configUSE_IDLE_HOOK            0

/* ---- this program's own knobs; override them with DEFS=-D<NAME>=<value> ---- */

/* Number of items the producer sends before the program reports PASS. */
#ifndef TEMPLATE_ITEMS
#define TEMPLATE_ITEMS                 20
#endif

/* 1: also demonstrate an interrupt handler (the simulation's test interrupt source). */
#ifndef TEMPLATE_WITH_IRQ
#define TEMPLATE_WITH_IRQ              0
#endif
