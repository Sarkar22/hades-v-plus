/* loader: settings on top of common/FreeRTOSConfig.h: those of the shell, and what the
 * loader needs. */
#include "../shell/app_config.h"

/* The heap: the shell's tasks, its receive queue and the CLI's command list. The app's TCB
 * and stack are not on it. */
#undef configTOTAL_HEAP_SIZE
#define configTOTAL_HEAP_SIZE              ( ( size_t ) ( 8192 ) )

/* The app task: a static TCB in the shell and a stack in the app slot (xTaskCreateStatic),
 * deleted by the console task when the app ends. */
#define configSUPPORT_STATIC_ALLOCATION    1
#define INCLUDE_vTaskDelete                1
