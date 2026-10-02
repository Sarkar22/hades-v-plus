/* console.c -- the UART console of the HaDes-V+ FreeRTOS shell.
 *
 * Receive path
 *   The UART has a one-byte receive buffer and raises the machine external interrupt
 *   while it is full and RX_IE is set. app_external_irq() reads the buffer (one word
 *   read returns the byte and the status and empties the buffer), sends the byte to a
 *   queue of SHELL_RX_BUFFER characters and wakes the console task. It never prints.
 *   Bytes that find the queue full are counted as dropped; RX_ERR (a byte lost inside
 *   the UART) is counted as an overrun.
 *
 * Console task
 *   Takes characters from the queue and edits one command line:
 *     printable characters   appended and echoed (at most SHELL_LINE_MAX)
 *     Backspace, DEL         delete the last character
 *     Ctrl-C                 cancel the line
 *     Ctrl-U                 erase the line
 *     Up / Down arrow        recall the previous line / clear the line
 *     CR, LF, CR LF          end of line: run the command
 *   A line longer than SHELL_LINE_MAX is rejected with a message; the rest of it, up
 *   to the end of the line, is discarded (so a long paste cannot run half a command).
 *   Other control characters and escape sequences are ignored. An escape sequence
 *   (ESC [ ... final byte, or ESC O and one byte) ends at the first byte that cannot
 *   belong to it, and that byte is then handled as usual: a lone Esc key never
 *   swallows the key typed after it (Enter, Ctrl-C or a letter). A pause of
 *   SHELL_ESC_TIMEOUT_MS after ESC also ends the sequence (a terminal sends the bytes
 *   of a sequence together).
 *
 * Transmit path
 *   shell_write() sends each line of its text (up to and including the '\n') with the
 *   scheduler suspended, so the output of different tasks never interleaves within a
 *   line; interrupts stay enabled, so input is still received. (The same technique as
 *   hal_puts_atomic(). A mutex would not block unrelated tasks, but its code does not
 *   fit in the 32 KiB image next to the rest.) Characters are written by polling
 *   TX_EMPTY (hal_putc()); a lone '\n' is sent as "\r\n". A line of 80 characters
 *   keeps the scheduler suspended for 80 character times: 13k cycles at the
 *   simulation's baud rate, 7 ms at 115200 baud on a board.
 */
#include <string.h>
#include "FreeRTOS.h"
#include "task.h"
#include "queue.h"
#include "FreeRTOS_CLI.h"
#include "hades_hal.h"
#include "shell.h"

static QueueHandle_t xRxQueue;
static char cLastSent;   /* the last character sent (written with the scheduler suspended) */

static volatile uint32_t ulRxReceived, ulRxDropped, ulRxOverruns;

/* ---------------------------------------------------------------- receive -- */

/* Machine external interrupt (called by the FreeRTOS trap handler through
 * common/hades_hal.c, on the interrupt stack, with interrupts disabled). The UART
 * is the only source of this interrupt in the shell. */
void app_external_irq( void )
{
    BaseType_t xWoken = pdFALSE;

    for( ; ; )
    {
        const uint32_t ulWord = SHELL_UART_WORD;   /* byte + status; empties the buffer */
        uint8_t ucByte;

        if( ( ulWord & SHELL_UART_RX_FULL ) == 0u )
        {
            break;
        }

        ucByte = ( uint8_t ) ulWord;
        ulRxReceived++;

        if( ( ulWord & SHELL_UART_RX_ERR ) != 0u )
        {
            ulRxOverruns++;
        }

        #if SHELL_LOADER
            /* While an app runs, Ctrl-C stops it (loader.c) instead of being queued. */
            if( loader_rx_from_isr( ucByte, &xWoken ) != pdFALSE )
            {
                continue;
            }
        #endif

        if( xQueueSendFromISR( xRxQueue, &ucByte, &xWoken ) != pdPASS )
        {
            ulRxDropped++;
        }
    }

    portYIELD_FROM_ISR( xWoken );
}

void shell_rx_stats( ShellRxStats_t * pxStats )
{
    taskENTER_CRITICAL();
    pxStats->ulReceived = ulRxReceived;
    pxStats->ulDropped = ulRxDropped;
    pxStats->ulOverruns = ulRxOverruns;
    taskEXIT_CRITICAL();
}

/* --------------------------------------------------------------- transmit -- */

void shell_write( const char * pcText, size_t xLength )
{
    const int iRunning = ( xTaskGetSchedulerState() == taskSCHEDULER_RUNNING );
    size_t i = 0;

    while( i < xLength )
    {
        if( iRunning )
        {
            vTaskSuspendAll();
        }

        do
        {
            const char c = pcText[ i++ ];

            if( ( c == '\n' ) && ( cLastSent != '\r' ) )
            {
                hal_putc( '\r' );
            }

            hal_putc( c );
            cLastSent = c;
        } while( ( cLastSent != '\n' ) && ( i < xLength ) );

        if( iRunning )
        {
            ( void ) xTaskResumeAll();
        }
    }
}

void shell_puts( const char * pcText )
{
    shell_write( pcText, strlen( pcText ) );
}

int shell_printf( const char * pcFormat, ... )
{
    char acLine[ 160 ];
    va_list xArgs;
    int n;

    va_start( xArgs, pcFormat );
    n = shell_vsnprintf( acLine, sizeof( acLine ), pcFormat, xArgs );
    va_end( xArgs );
    shell_write( acLine, ( size_t ) n );
    return n;
}

/* ------------------------------------------------------------ line editor -- */

typedef enum
{
    ESC_NONE,   /* not in an escape sequence */
    ESC_START,  /* ESC received */
    ESC_CSI,    /* ESC [ received: parameters until a final byte 0x40..0x7E */
    ESC_SS3     /* ESC O received: one more byte */
} EscState_t;

static char acLine[ SHELL_LINE_MAX + 1 ];
static char acHistory[ SHELL_LINE_MAX + 1 ];
static size_t xLen;
static int iDiscarding;      /* an over-long line is being discarded up to its end */
static char cPrevious;       /* for CR LF */
static EscState_t eEsc;

static void prvPrompt( void )
{
    shell_puts( SHELL_PROMPT );
}

/* Replaces the text after the prompt by pcNew (cursor left, erase to end of line). */
static void prvReplaceLine( const char * pcNew )
{
    if( xLen != 0u )
    {
        shell_printf( "\x1b[%zuD\x1b[K", xLen );
    }

    xLen = strlen( pcNew );
    memcpy( acLine, pcNew, xLen + 1u );
    shell_write( acLine, xLen );
}

static void prvExecute( void )
{
    char * pcOut = FreeRTOS_CLIGetOutputBuffer();
    const char * pcCommand = acLine;
    BaseType_t xMore;

    while( *pcCommand == ' ' )
    {
        pcCommand++;
    }

    if( *pcCommand == '\0' )
    {
        return;
    }

    memcpy( acHistory, acLine, xLen + 1u );

    do
    {
        pcOut[ 0 ] = '\0';
        xMore = FreeRTOS_CLIProcessCommand( pcCommand, pcOut, configCOMMAND_INT_MAX_OUTPUT_SIZE );
        shell_puts( pcOut );
    } while( xMore != pdFALSE );
}

static void prvEndOfLine( void )
{
    if( iDiscarding != 0 )
    {
        iDiscarding = 0;   /* the error message already ended its line */
    }
    else
    {
        shell_puts( "\n" );
        acLine[ xLen ] = '\0';
        prvExecute();
    }

    xLen = 0;
    prvPrompt();
}

/* Called while an escape sequence is open. Returns 1 when c belongs to the sequence
 * (and has been handled), 0 when it cannot: the sequence is then abandoned and c is
 * handled as an ordinary character. */
static int prvHandleEscape( char c )
{
    if( eEsc == ESC_START )
    {
        if( ( c == '[' ) || ( c == 'O' ) )
        {
            eEsc = ( c == '[' ) ? ESC_CSI : ESC_SS3;
            return 1;
        }
    }
    else if( ( eEsc == ESC_CSI ) && ( c >= 0x20 ) && ( c <= 0x3F ) )
    {
        return 1;   /* parameter or intermediate byte */
    }
    else if( ( c >= 0x40 ) && ( c <= 0x7E ) )   /* the final byte of CSI or SS3 */
    {
        eEsc = ESC_NONE;

        if( iDiscarding == 0 )
        {
            if( c == 'A' )   /* Up: recall the previous command line */
            {
                prvReplaceLine( acHistory );
            }
            else if( c == 'B' )   /* Down: empty line */
            {
                prvReplaceLine( "" );
            }
        }

        return 1;
    }

    eEsc = ESC_NONE;
    return 0;
}

static void prvHandleChar( char c )
{
    const char cBefore = cPrevious;

    cPrevious = c;

    if( ( eEsc != ESC_NONE ) && ( prvHandleEscape( c ) != 0 ) )
    {
        return;
    }

    switch( c )
    {
        case '\n':

            if( cBefore == '\r' )
            {
                return;   /* the LF of CR LF */
            }

            prvEndOfLine();
            return;

        case '\r':
            prvEndOfLine();
            return;

        case 0x03:   /* Ctrl-C: cancel the line */
            shell_puts( "^C\n" );
            iDiscarding = 0;
            xLen = 0;
            prvPrompt();
            return;

        case 0x15:   /* Ctrl-U: erase the line */

            if( iDiscarding == 0 )
            {
                prvReplaceLine( "" );
            }

            return;

        case 0x08:   /* Backspace */
        case 0x7F:   /* DEL */

            if( ( iDiscarding == 0 ) && ( xLen > 0u ) )
            {
                xLen--;
                shell_puts( "\b \b" );
            }

            return;

        case 0x1B:
            eEsc = ESC_START;
            return;

        default:
            break;
    }

    if( ( c < 0x20 ) || ( c > 0x7E ) || ( iDiscarding != 0 ) )
    {
        return;   /* other control characters; the rest of a rejected line */
    }

    if( xLen >= SHELL_LINE_MAX )
    {
        shell_printf( "\nerror: line too long (at most %d characters); it is discarded up to its end\n",
                      SHELL_LINE_MAX );
        iDiscarding = 1;
        xLen = 0;
        return;
    }

    acLine[ xLen++ ] = c;
    shell_write( &c, 1 );
}

static void prvConsoleTask( void * pvParameters )
{
    ( void ) pvParameters;

    shell_probe_cpu();
    shell_puts( "Type 'help' for the list of commands.\n" );
    prvPrompt();

    for( ; ; )
    {
        uint8_t ucByte;

        /* Inside an escape sequence, a pause ends it (a lone Esc key). */
        if( xQueueReceive( xRxQueue, &ucByte, ( eEsc == ESC_NONE ) ? portMAX_DELAY : pdMS_TO_TICKS( SHELL_ESC_TIMEOUT_MS ) ) == pdPASS )
        {
            prvHandleChar( ( char ) ucByte );
        }
        else
        {
            eEsc = ESC_NONE;
        }
    }
}

void shell_console_start( void )
{
    xRxQueue = xQueueCreate( SHELL_RX_BUFFER, 1 );

    if( ( xRxQueue == NULL ) ||
        ( xTaskCreate( prvConsoleTask, "console", SHELL_CONSOLE_STACK, NULL, SHELL_CONSOLE_PRIORITY, NULL ) != pdPASS ) )
    {
        hal_fail( "shell: cannot create the console (raise configTOTAL_HEAP_SIZE)", NULL, 0, 0 );
    }

    /* Receive interrupt on. A byte that arrived before this point is still in the
     * UART's buffer and raises the interrupt as soon as the scheduler enables
     * interrupts. (Only the receive-status byte is written: a word store would also
     * write the transmit buffer and send a character.) */
    SHELL_UART_RXSTAT = SHELL_UART_RXSTAT_IE;
}

#if SHELL_LOADER

/* ------------------------------------------------------- for the app loader -- */

/* The commands of loader.c run in the console task, which is then the only reader of the
 * receive queue; while an app runs, the app task is. */
int shell_rx_byte( TickType_t xTicks )
{
    uint8_t ucByte;

    return ( xQueueReceive( xRxQueue, &ucByte, xTicks ) == pdPASS ) ? ( int ) ucByte : -1;
}

void shell_rx_discard( void )
{
    uint8_t ucByte;

    while( xQueueReceive( xRxQueue, &ucByte, 0 ) == pdPASS )
    {
    }
}

int shell_rx_holds( uint8_t ucWanted )
{
    int iFound = 0;

    /* Every byte is taken from the front and put back at the end, in a critical section, so
     * that the receive interrupt adds nothing in between: the order stays as it was. */
    taskENTER_CRITICAL();
    {
        for( UBaseType_t n = uxQueueMessagesWaiting( xRxQueue ); n > 0u; n-- )
        {
            uint8_t ucByte;

            if( xQueueReceive( xRxQueue, &ucByte, 0 ) != pdPASS )
            {
                break;
            }

            iFound |= ( ucByte == ucWanted );
            ( void ) xQueueSend( xRxQueue, &ucByte, 0 );
        }
    }
    taskEXIT_CRITICAL();

    return iFound;
}

int shell_output_at_line_start( void )
{
    return ( cLastSent == '\n' ) || ( cLastSent == '\0' );
}

void shell_set_previous( char c )
{
    cPrevious = c;
}

#endif /* SHELL_LOADER */
