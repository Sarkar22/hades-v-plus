/* crash.c -- an app that fails on purpose, to show how the shell contains it: the shell stops
 * the app, reports why and carries on (test/freertos/loader/SPEC.md, section 7).
 *
 *   crash [illegal]   executes the word 0                    illegal instruction (mcause 2)
 *   crash ebreak      executes ebreak                         breakpoint (mcause 3)
 *   crash misaligned  loads a word 2 bytes past a word        load address misaligned (4)
 *   crash load        loads from 0x00300000 (no device)       load access fault (5)
 *   crash store       stores to 0x00300000                    store access fault (7)
 *   crash null        calls a null function pointer           instruction access fault (1)
 *   crash stack       recurses with 256 bytes of locals per level and yields at every level,
 *                     so that FreeRTOS finds the overflow at the next task switch
 *   crash deep        recurses in the same way 32 levels deep (about 9 KiB on the stack of
 *                     4 KiB) without yielding, then returns 0: FreeRTOS finds the overflow
 *                     only at the task switch that the end of the app causes
 *   crash loop        waits for input once (which tells the console bridge that it may type
 *                     on), then spins for ever with interrupts enabled: Ctrl-C stops it
 *   crash spin        spins for ever without reading input: Ctrl-C stops it, also one typed
 *                     before the app started (right after the Enter of 'run')
 * brk (test/freertos/brk) and test/asm/trap.s provoke the same exceptions the same way. Any
 * other argument prints the usage and returns 2. */
#include <stdint.h>
#include <string.h>
#include "hades_app.h"

#define CRASH_NO_DEVICE    ( ( volatile uint32_t * ) 0x00300000u )

static uint32_t ulWord;

#define CRASH_DEEP_LEVELS  32u

/* Each level of the recursion fills 256 bytes of its own stack frame and, if xYield, yields,
 * so that the task switch checks the stack. The bytes are read again after the call, which
 * keeps the call from becoming a jump. (The default depth limit is far beyond any stack in
 * the slot.) */
static uint32_t prvRecurse( uint32_t ulDepth, uint32_t ulLimit, int xYield )
{
    volatile uint8_t aucLocals[ 256 ];
    uint32_t ulSum = 0;

    for( uint32_t i = 0; i < sizeof( aucLocals ); i++ )
    {
        aucLocals[ i ] = ( uint8_t ) ( ulDepth + i );
    }

    if( xYield )
    {
        app_delay_ms( 0 );
    }

    if( ulDepth < ulLimit )
    {
        ulSum = prvRecurse( ulDepth + 1, ulLimit, xYield );
    }

    for( uint32_t i = 0; i < sizeof( aucLocals ); i++ )
    {
        ulSum += aucLocals[ i ];
    }

    return ulSum;
}

int main( int argc, char ** argv )
{
    const char * pcMode = ( argc > 1 ) ? argv[ 1 ] : "illegal";
    uint32_t ulValue = 0;

    app_printf( "crash: %s\n", pcMode );

    if( strcmp( pcMode, "illegal" ) == 0 )
    {
        __asm volatile ( ".word 0" );
    }
    else if( strcmp( pcMode, "ebreak" ) == 0 )
    {
        __asm volatile ( "ebreak" );
    }
    else if( strcmp( pcMode, "misaligned" ) == 0 )
    {
        __asm volatile ( "lw %0, 2(%1)" : "=r" ( ulValue ) : "r" ( &ulWord ) : "memory" );
    }
    else if( strcmp( pcMode, "load" ) == 0 )
    {
        ulValue = *CRASH_NO_DEVICE;
    }
    else if( strcmp( pcMode, "store" ) == 0 )
    {
        *CRASH_NO_DEVICE = ulValue;
    }
    else if( strcmp( pcMode, "null" ) == 0 )
    {
        void ( * volatile pxFunction )( void ) = NULL;

        pxFunction();
    }
    else if( strcmp( pcMode, "stack" ) == 0 )
    {
        ulValue = prvRecurse( 0, 0x100000u, 1 );
    }
    else if( strcmp( pcMode, "deep" ) == 0 )
    {
        /* Nothing is printed after the recursion: the output would depend on whether a task
         * switch (the tick waking another task) found the overflow before the end. */
        ( void ) prvRecurse( 0, CRASH_DEEP_LEVELS, 0 );
        return 0;
    }
    else if( strcmp( pcMode, "loop" ) == 0 )
    {
        ( void ) app_getc( 1 );

        for( ; ; )
        {
        }
    }
    else if( strcmp( pcMode, "spin" ) == 0 )
    {
        for( ; ; )
        {
        }
    }
    else
    {
        app_printf( "crash: usage: crash [illegal|ebreak|misaligned|load|store|null|stack|deep|loop|spin]\n" );
        return 2;
    }

    /* Only reached if the CPU did not raise the exception. */
    app_printf( "crash: %s did not stop the app (value 0x%08lx)\n", pcMode, ulValue );
    return 1;
}
