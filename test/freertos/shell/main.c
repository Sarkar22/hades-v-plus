/* main.c -- an interactive command shell for HaDes-V+, on FreeRTOS and FreeRTOS+CLI.
 *
 * Run it in the simulator, typing into the same terminal:
 *     make freertos-shell                    (Ctrl-] quits; see docs/FREERTOS.md)
 *     make freertos-shell PTY=1              (attach screen or picocom to the printed device)
 *     make freertos-shell-test               (a scripted session, checked automatically)
 *
 * Tasks
 *   console (priority 2)  line editing and the commands (console.c, commands.c)
 *   blink   (priority 3)  toggles LED 0 every 500 ticks: a periodic task to look at
 *                         with 'tasks' and 'stats'
 *   IDLE    (priority 0)
 *
 * The same program runs on a board: the UART's RX and TX pins at the board's baud
 * rate, and a terminal program on the other end ('halt' then only stops the shell).
 */
#include "FreeRTOS.h"
#include "task.h"
#include "FreeRTOS_CLI.h"
#include "hades_hal.h"
#include "shell.h"

#define STR_( x )    # x
#define STR( x )     STR_( x )

static volatile uint32_t ulBlinks;

static void prvBlinkTask( void * pvParameters )
{
    TickType_t xWake = xTaskGetTickCount();

    ( void ) pvParameters;

    for( ; ; )
    {
        vTaskDelayUntil( &xWake, pdMS_TO_TICKS( 500 ) );
        ulBlinks++;
        SHELL_LEDS = ulBlinks & 1u;
    }
}

/* Start-up: the test register's "initial" marker (see common/hades_hal.h), the
 * branch-predictor mode given by BPRED=, and the banner. hal_begin() does the same
 * for the other programs; the shell prints its banner with CR LF line ends, as a
 * serial terminal expects. */
static void prvBegin( void )
{
    HADES_TEST_REG = 1;
    #if defined( FRTOS_BPRED ) && ( FRTOS_BPRED != 0 )
        __asm volatile ( "csrw 0x32A, %0" :: "r" ( FRTOS_BPRED ) );
    #endif
    shell_puts( "\nHaDes-V+ shell on FreeRTOS " tskKERNEL_VERSION_NUMBER " with FreeRTOS+CLI\n"
                "  config: tick=" STR( FRTOS_TICK_CYCLES ) "cyc preempt=" STR( FRTOS_PREEMPT )
                " slice=" STR( FRTOS_SLICE ) " heap_" STR( FRTOS_HEAP ) " isa=" SHELL_ISA " opt=" SHELL_OPT
                " ram=" STR( FRTOS_RAM_KB ) "K"
    #if defined( FRTOS_BPRED )
                " bpred=" STR( FRTOS_BPRED )
    #endif
                "\n" );
    #if SHELL_LOADER
        shell_printf( "  apps: 'load' receives an app into the %lu KiB slot at 0x%08lx, 'run' runs it\n",
                      ( uint32_t ) ( HADES_APP_SLOT_SIZE / 1024u ), ( uint32_t ) HADES_APP_SLOT_BASE );
    #endif
}

int main( void )
{
    prvBegin();

    shell_register_commands();
    shell_console_start();

    if( xTaskCreate( prvBlinkTask, "blink", SHELL_BLINK_STACK, NULL, SHELL_BLINK_PRIORITY, NULL ) != pdPASS )
    {
        hal_fail( "shell: xTaskCreate(blink) failed (raise configTOTAL_HEAP_SIZE)", NULL, 0, 0 );
    }

    #if SHELL_LOADER
        loader_init();
    #endif

    vTaskStartScheduler();
    hal_fail( "vTaskStartScheduler returned", NULL, 0, 0 );
}
