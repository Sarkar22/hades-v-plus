/* SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: perf.c
 *
 * perf -- the hardware performance counters from the shell's command line (docs/SHELL.md). It
 * exists only in the loader's configuration built with HPM_PERF=1 (test/freertos/loader/app.mk):
 * the default shell and the default loader do not contain it, and their images are the same
 * with or without this file in the tree.
 *
 *   perf                     the counters: event, count, per 1000 instructions; the window's
 *                            cycles, instructions and IPC; the active preset's ratios
 *   perf preset <name>       cpi | mix | branch | traps | mem | icache | port: select the preset's
 *                            events, clear, start
 *   perf add <event>         give the event (a name or a code) a free counter
 *   perf list                the events this build has
 *   perf clear | start | stop
 *   perf run [args]          clear, start, run the loaded app, stop, show
 *
 * The counts are global: every task, every interrupt handler, the shell and the loader count
 * too. To measure one function inside an app, use std/include/hpm.h around that function.
 * perf never touches the inhibit bits of mcycle and minstret (so `stats`, `counters` and
 * `uptime` keep working); start and stop work on the counters 3..9 and 10..13 only.
 */
#include <string.h>
#include "FreeRTOS.h"
#include "task.h"
#include "FreeRTOS_CLI.h"
#include "hades_hal.h"
#include "shell.h"

#if HPM_PERF

#if !SHELL_LOADER
    #error "perf belongs to the loader configuration: build with APP=loader HPM_PERF=1 (the shell's own image has no room)"
#endif

#define HPM_WITH_NAMES
#include "hpm.h"

/* ---------------------------------------------------------------------- state -- */

typedef struct
{
    uint8_t ucInit;                 /* the counters have been looked for */
    uint8_t ucCounters;             /* 0..HPM_MAX programmable counters */
    uint8_t ucRunning;              /* start was given and stop was not */
    int8_t cPreset;                 /* index of the active preset, -1 for none */
    uint32_t aulEvent[ HPM_MAX ];   /* the event each counter counts, 0: free */
    uint64_t ullBaseCycles, ullBaseInstret;   /* mcycle and minstret at the last clear */
    uint64_t ullEndCycles, ullEndInstret;     /* ... at the last stop (valid when !ucRunning) */
    uint64_t aullValue[ HPM_MAX ];            /* the snapshot of the last 'perf' */
    uint32_t aulPredictor[ 4 ];               /* mhpmcounter10..13 in the snapshot */
    uint64_t ullCycles, ullInstret;           /* the window of the snapshot */
} Perf_t;

static Perf_t xPerf = { 0, 0, 0, -1, { 0 }, 0, 0, 0, 0, { 0 }, { 0 }, 0, 0 };

typedef struct
{
    const char * pcName;
    uint8_t ucCount;
    uint16_t ausCode[ HPM_MAX ];
} Preset_t;

static const Preset_t axPresets[] =
{
    { "cpi",    7, { HPM_EV_FETCH_WAIT, HPM_EV_FRONT_OK, HPM_EV_HAZARD, HPM_EV_MSTALL_ANY, HPM_EV_MEMWAIT_ANY,
                     HPM_EV_REDIRECT_ANY, HPM_EV_BR_MISPREDICT } },
    { "mix",    7, { HPM_EV_LOAD, HPM_EV_STORE, HPM_EV_BRANCH, HPM_EV_JUMP, HPM_EV_MUL, HPM_EV_DIV, HPM_EV_CSR } },
    { "branch", 7, { HPM_EV_BRANCH, HPM_EV_BRANCH_TAKEN, HPM_EV_BR_MISPREDICT, HPM_EV_JUMP, HPM_EV_REDIRECT_BRANCH,
                     HPM_EV_REDIRECT_JUMP, HPM_EV_REDIRECT_ANY } },
    { "traps",  7, { HPM_EV_EXCEPTION, HPM_EV_EXC_ECALL, HPM_EV_EXC_OTHER, HPM_EV_INTERRUPT, HPM_EV_INT_TIMER,
                     HPM_EV_INT_EXT, HPM_EV_MRET } },
    { "mem",    7, { HPM_EV_MEMWAIT_LOAD, HPM_EV_MEMWAIT_STORE, HPM_EV_MEMWAIT_IO, HPM_EV_IO_ACCESS, HPM_EV_LOAD,
                     HPM_EV_STORE, HPM_EV_HAZARD_LOAD } },
    { "icache", 7, { HPM_EV_IC_HIT_USED, HPM_EV_IC_MISS, HPM_EV_IC_FILL, HPM_EV_IC_ABANDON, HPM_EV_IC_MISS_JUMP,
                     HPM_EV_PORT_WAIT_I, HPM_EV_FETCH_WAIT } },
    { "port",   7, { HPM_EV_PORT_WAIT_I, HPM_EV_PORT_WAIT_D, HPM_EV_PORT_GRANT_I, HPM_EV_PORT_GRANT_D,
                     HPM_EV_PORT_LOAD, HPM_EV_PORT_STORE, HPM_EV_IC_SNOOP_INVAL } },
};

#define PRESET_COUNT    ( sizeof( axPresets ) / sizeof( axPresets[ 0 ] ) )
#define PRESET_ICACHE   5
#define PRESET_PORT     6

static const char acNoCounters[] = "perf: no performance counters on this CPU\n";

/* -------------------------------------------------------------------- helpers -- */

static uint64_t prvCsr64( int iWhich )
{
    uint32_t h, l, h2;

    do
    {
        if( iWhich == 0 )
        {
            __asm volatile ( "csrr %0, 0xB80" : "=r" ( h ) );
            __asm volatile ( "csrr %0, 0xB00" : "=r" ( l ) );
            __asm volatile ( "csrr %0, 0xB80" : "=r" ( h2 ) );
        }
        else
        {
            __asm volatile ( "csrr %0, 0xB82" : "=r" ( h ) );
            __asm volatile ( "csrr %0, 0xB02" : "=r" ( l ) );
            __asm volatile ( "csrr %0, 0xB82" : "=r" ( h2 ) );
        }
    } while( h != h2 );

    return ( ( uint64_t ) h << 32 ) | l;
}

/* num / den * scale, rounded, as an integer. */
static uint32_t prvRatio( uint64_t ullNum, uint64_t ullDen, uint32_t ulScale )
{
    return ( ullDen == 0u ) ? 0u : ( uint32_t ) shell_udiv64( ( ullNum * ulScale ) + ( ullDen / 2u ), ullDen, NULL );
}

static void prvAppend( char * pcOut, size_t xOutLen, const char * pcFormat, ... ) __attribute__( ( format( printf, 3, 4 ) ) );
static void prvAppend( char * pcOut, size_t xOutLen, const char * pcFormat, ... )
{
    const size_t xUsed = strlen( pcOut );
    va_list xArgs;

    if( xUsed < xOutLen )
    {
        va_start( xArgs, pcFormat );
        ( void ) shell_vsnprintf( pcOut + xUsed, xOutLen - xUsed, pcFormat, xArgs );
        va_end( xArgs );
    }
}

/* Look for the counters once. */
static unsigned prvCounters( void )
{
    if( xPerf.ucInit == 0u )
    {
        xPerf.ucInit = 1u;
        xPerf.ucCounters = xShellCpu.ucHpm ? ( uint8_t ) hpm_counters() : 0u;
    }

    return xPerf.ucCounters;
}

static uint32_t prvAllMask( void )
{
    uint32_t ulMask = HPM_INH_BP;

    for( unsigned i = 0; i < xPerf.ucCounters; i++ )
    {
        ulMask |= 1u << ( HPM_FIRST + i );
    }

    return ulMask;
}

static void prvClear( void )
{
    hpm_freeze( prvAllMask() );

    for( unsigned i = 0; i < xPerf.ucCounters; i++ )
    {
        hpm_write( HPM_FIRST + i, 0u );
    }

    __asm volatile ( "csrw 0xB0A, zero\n csrw 0xB0B, zero\n csrw 0xB0C, zero\n csrw 0xB0D, zero" );
    xPerf.ullBaseCycles = prvCsr64( 0 );
    xPerf.ullBaseInstret = prvCsr64( 1 );
    xPerf.ullEndCycles = xPerf.ullBaseCycles;
    xPerf.ullEndInstret = xPerf.ullBaseInstret;

    if( xPerf.ucRunning )
    {
        hpm_thaw( prvAllMask() );
    }
}

static void prvStart( void )
{
    xPerf.ucRunning = 1u;
    hpm_thaw( prvAllMask() );
}

static void prvStop( void )
{
    hpm_freeze( prvAllMask() );
    xPerf.ucRunning = 0u;
    xPerf.ullEndCycles = prvCsr64( 0 );
    xPerf.ullEndInstret = prvCsr64( 1 );
}

/* The event named or numbered by the word, or -1. */
static int32_t prvParseEvent( const char * pcWord, BaseType_t xLen )
{
    char acName[ 24 ];
    uint32_t ulValue = 0, ulBase = 10;
    BaseType_t i = 0;

    if( ( xLen <= 0 ) || ( xLen >= ( BaseType_t ) sizeof( acName ) ) )
    {
        return -1;
    }

    if( ( pcWord[ 0 ] >= '0' ) && ( pcWord[ 0 ] <= '9' ) )
    {
        if( ( xLen > 2 ) && ( pcWord[ 1 ] == 'x' ) )
        {
            ulBase = 16;
            i = 2;
        }

        for( ; i < xLen; i++ )
        {
            const char c = ( char ) ( pcWord[ i ] | 0x20 );
            uint32_t d;

            if( ( pcWord[ i ] >= '0' ) && ( pcWord[ i ] <= '9' ) )
            {
                d = ( uint32_t ) ( pcWord[ i ] - '0' );
            }
            else if( ( ulBase == 16u ) && ( c >= 'a' ) && ( c <= 'f' ) )
            {
                d = ( uint32_t ) ( c - 'a' + 10 );
            }
            else
            {
                return -1;
            }

            ulValue = ( ulValue * ulBase ) + d;

            if( ulValue > 255u )
            {
                return -1;
            }
        }

        return ( int32_t ) ulValue;
    }

    for( i = 0; i < xLen; i++ )
    {
        acName[ i ] = ( char ) ( ( ( pcWord[ i ] >= 'a' ) && ( pcWord[ i ] <= 'z' ) ) ? ( pcWord[ i ] - 32 ) : pcWord[ i ] );
    }

    acName[ xLen ] = '\0';

    #define PERF_MATCH( name ) if( strcmp( acName, #name ) == 0 ) { return HPM_EV_##name; }
    HPM_EVENT_LIST( PERF_MATCH )
    #undef PERF_MATCH
    return -1;
}

static const char * prvName( uint32_t ulCode )
{
    const char * pc = hpm_event_name( ulCode );
    return ( pc != NULL ) ? pc : "?";
}

/* Select the event on counter i (frozen, cleared). Returns the read-back. */
static uint32_t prvAssign( unsigned uIndex, uint32_t ulCode )
{
    const uint32_t ulRead = hpm_select( HPM_FIRST + uIndex, ulCode );

    hpm_write( HPM_FIRST + uIndex, 0u );
    xPerf.aulEvent[ uIndex ] = ulRead;

    if( xPerf.ucRunning && ( ulRead != 0u ) )
    {
        hpm_thaw( 1u << ( HPM_FIRST + uIndex ) );
    }

    return ulRead;
}

/* ----------------------------------------------------------------- the report -- */

static uint8_t ucRow;     /* the next row of the report, 0: header */
static uint8_t ucList;    /* perf list: the next event to print */
static uint8_t aucHave[ 80 ];   /* perf list: 1 if the event exists, in the order of HPM_EVENT_LIST */

static int64_t prvCount( uint32_t ulCode )
{
    for( unsigned i = 0; i < xPerf.ucCounters; i++ )
    {
        if( xPerf.aulEvent[ i ] == ulCode )
        {
            return ( int64_t ) xPerf.aullValue[ i ];
        }
    }

    return -1;
}

static void prvSnapshot( void )
{
    uint32_t ulMask = 0;

    for( unsigned i = 0; i < xPerf.ucCounters; i++ )
    {
        if( xPerf.aulEvent[ i ] != 0u )
        {
            ulMask |= 1u << ( HPM_FIRST + i );
        }
    }

    ulMask |= HPM_INH_BP;

    if( xPerf.ucRunning )
    {
        hpm_freeze( ulMask );
        xPerf.ullCycles = prvCsr64( 0 ) - xPerf.ullBaseCycles;
        xPerf.ullInstret = prvCsr64( 1 ) - xPerf.ullBaseInstret;
    }
    else
    {
        xPerf.ullCycles = xPerf.ullEndCycles - xPerf.ullBaseCycles;
        xPerf.ullInstret = xPerf.ullEndInstret - xPerf.ullBaseInstret;
    }

    for( unsigned i = 0; i < xPerf.ucCounters; i++ )
    {
        xPerf.aullValue[ i ] = ( xPerf.aulEvent[ i ] != 0u ) ? hpm_read( HPM_FIRST + i ) : 0u;
    }

    __asm volatile ( "csrr %0, 0xB0A" : "=r" ( xPerf.aulPredictor[ 0 ] ) );
    __asm volatile ( "csrr %0, 0xB0B" : "=r" ( xPerf.aulPredictor[ 1 ] ) );
    __asm volatile ( "csrr %0, 0xB0C" : "=r" ( xPerf.aulPredictor[ 2 ] ) );
    __asm volatile ( "csrr %0, 0xB0D" : "=r" ( xPerf.aulPredictor[ 3 ] ) );

    if( xPerf.ucRunning )
    {
        hpm_thaw( ulMask );
    }
}

/* The count of an event in the snapshot: 0 if no counter has it. */
static uint64_t prvGet( uint32_t ulCode )
{
    const int64_t ll = prvCount( ulCode );
    return ( ll > 0 ) ? ( uint64_t ) ll : 0u;
}

/* "x.y%" of ullNum in ullDen. */
#define PERCENT( num, den )    prvRatio( ( num ), ( den ), 1000u ) / 10u, prvRatio( ( num ), ( den ), 1000u ) % 10u
/* "x.yz" of ullNum per ullDen. */
#define PER( num, den )        prvRatio( ( num ), ( den ), 100u ) / 100u, prvRatio( ( num ), ( den ), 100u ) % 100u

static void prvRatios( char * pcOut, size_t xOutLen )
{
    switch( xPerf.cPreset )
    {
        case 0:   /* cpi: the six classes add up to the cycles counted */
        {
            uint64_t ullSum = 0;

            for( unsigned i = 0; i < 6u; i++ )
            {
                ullSum += prvGet( axPresets[ 0 ].ausCode[ i ] );
            }

            if( ullSum != 0u )
            {
                prvAppend( pcOut, xOutLen, "of the %llu cycles counted:", ullSum );

                for( unsigned i = 0; i < 6u; i++ )
                {
                    prvAppend( pcOut, xOutLen, " %s %lu.%lu%%", prvName( axPresets[ 0 ].ausCode[ i ] ),
                               PERCENT( prvGet( axPresets[ 0 ].ausCode[ i ] ), ullSum ) );
                }

                prvAppend( pcOut, xOutLen, "\n" );
            }

            prvAppend( pcOut, xOutLen, "CPI:       %lu.%02lu (cycles per instruction in the window)\n",
                       PER( xPerf.ullCycles, xPerf.ullInstret ) );
            break;
        }

        case 2:   /* branch */
            prvAppend( pcOut, xOutLen, "mispredict rate: %lu.%lu%% of %llu branches; %lu.%02lu mispredictions per 1000 instructions\n",
                       PERCENT( prvGet( HPM_EV_BR_MISPREDICT ), prvGet( HPM_EV_BRANCH ) ), prvGet( HPM_EV_BRANCH ),
                       PER( prvGet( HPM_EV_BR_MISPREDICT ) * 1000u, xPerf.ullInstret ) );
            prvAppend( pcOut, xOutLen, "predictor counters 10-13 (retired branches): nn %lu, nt %lu, tn %lu, tt %lu\n",
                       xPerf.aulPredictor[ 0 ], xPerf.aulPredictor[ 1 ], xPerf.aulPredictor[ 2 ], xPerf.aulPredictor[ 3 ] );
            break;

        case 3:   /* traps: per million cycles */
            prvAppend( pcOut, xOutLen, "per million cycles: %lu exceptions, %lu interrupts, %lu mret\n",
                       prvRatio( prvGet( HPM_EV_EXCEPTION ), xPerf.ullCycles, 1000000u ),
                       prvRatio( prvGet( HPM_EV_INTERRUPT ), xPerf.ullCycles, 1000000u ),
                       prvRatio( prvGet( HPM_EV_MRET ), xPerf.ullCycles, 1000000u ) );
            break;

        case 4:   /* mem */
            prvAppend( pcOut, xOutLen, "wait cycles per load %lu.%02lu, per store %lu.%02lu\n",
                       PER( prvGet( HPM_EV_MEMWAIT_LOAD ), prvGet( HPM_EV_LOAD ) ), PER( prvGet( HPM_EV_MEMWAIT_STORE ), prvGet( HPM_EV_STORE ) ) );
            break;

        case PRESET_ICACHE:
        {
            const uint64_t ullMiss = prvGet( HPM_EV_IC_MISS ), ullAband = prvGet( HPM_EV_IC_ABANDON );

            prvAppend( pcOut, xOutLen, "miss rate %lu.%lu%% ((misses - abandoned) / hits used); %lu.%02lu refills per 1000 instructions; fetch wait %lu.%lu%% of the cycles\n",
                       PERCENT( ( ullMiss > ullAband ) ? ( ullMiss - ullAband ) : 0u, prvGet( HPM_EV_IC_HIT_USED ) ),
                       PER( prvGet( HPM_EV_IC_FILL ) * 1000u, xPerf.ullInstret ), PERCENT( prvGet( HPM_EV_FETCH_WAIT ), xPerf.ullCycles ) );
            break;
        }

        case PRESET_PORT:
            prvAppend( pcOut, xOutLen, "of the cycles: I-refill waits %lu.%lu%%, data waits %lu.%lu%%, I-refill grants %lu.%lu%%, data grants %lu.%lu%%\n",
                       PERCENT( prvGet( HPM_EV_PORT_WAIT_I ), xPerf.ullCycles ), PERCENT( prvGet( HPM_EV_PORT_WAIT_D ), xPerf.ullCycles ),
                       PERCENT( prvGet( HPM_EV_PORT_GRANT_I ), xPerf.ullCycles ), PERCENT( prvGet( HPM_EV_PORT_GRANT_D ), xPerf.ullCycles ) );
            break;

        default:   /* mix and the loose events: the table's per-1000 column says it */
            break;
    }
}

/* One call of the report; returns pdTRUE while rows remain. */
static BaseType_t prvReport( char * pcOut, size_t xOutLen )
{
    if( ucRow == 0u )
    {
        prvSnapshot();
        shell_snprintf( pcOut, xOutLen,
                        "window:    %llu cycles, %llu instructions, IPC %lu.%03lu (since 'perf clear'; %s)\n"
                        "counter  event              count             per 1000 instr\n",
                        xPerf.ullCycles, xPerf.ullInstret,
                        prvRatio( xPerf.ullInstret, xPerf.ullCycles, 1000u ) / 1000u, prvRatio( xPerf.ullInstret, xPerf.ullCycles, 1000u ) % 1000u,
                        xPerf.ucRunning ? "running" : "stopped" );
        ucRow = 1u;
        return pdTRUE;
    }

    while( ( ucRow <= xPerf.ucCounters ) && ( xPerf.aulEvent[ ucRow - 1u ] == 0u ) )
    {
        ucRow++;
    }

    if( ucRow <= xPerf.ucCounters )
    {
        const unsigned i = ucRow - 1u;

        shell_snprintf( pcOut, xOutLen, "%-8lu %-18s %-17llu %lu.%02lu\n", ( uint32_t ) ( HPM_FIRST + i ), prvName( xPerf.aulEvent[ i ] ),
                        xPerf.aullValue[ i ], PER( xPerf.aullValue[ i ] * 1000u, xPerf.ullInstret ) );
        ucRow++;
        return pdTRUE;
    }

    pcOut[ 0 ] = '\0';
    prvRatios( pcOut, xOutLen );
    ucRow = 0u;
    return pdFALSE;
}

/* ---------------------------------------------------------------- perf list -- */

static BaseType_t prvListStep( char * pcOut, size_t xOutLen )
{
    static const uint16_t ausAll[] =
    {
        #define PERF_CODE( name ) HPM_EV_##name,
        HPM_EVENT_LIST( PERF_CODE )
        #undef PERF_CODE
    };
    const unsigned uTotal = sizeof( ausAll ) / sizeof( ausAll[ 0 ] );

    if( ucList == 0u )
    {
        /* Probe on counter 3, which perf puts back: selector, value, inhibit bit. */
        const uint32_t ulSel = hpm_selector( HPM_FIRST );
        const uint32_t ulWasFrozen = hpm_inhibit_read() & ( 1u << HPM_FIRST );
        uint64_t ullValue;

        hpm_freeze( 1u << HPM_FIRST );
        ullValue = hpm_read( HPM_FIRST );   /* the counter no longer changes */

        for( unsigned i = 0; ( i < uTotal ) && ( i < sizeof( aucHave ) ); i++ )
        {
            hpm_selector_write( HPM_FIRST, ausAll[ i ] );
            aucHave[ i ] = ( hpm_selector( HPM_FIRST ) == ausAll[ i ] ) ? 1u : 0u;
        }

        hpm_selector_write( HPM_FIRST, ulSel );
        hpm_write( HPM_FIRST, ullValue );

        if( ulWasFrozen == 0u )
        {
            hpm_thaw( 1u << HPM_FIRST );
        }

        shell_snprintf( pcOut, xOutLen, "events this build counts (use the name or the code with 'perf add'):\n" );
        ucList = 1u;
        return pdTRUE;
    }

    pcOut[ 0 ] = '\0';

    while( ( ucList <= uTotal ) && ( strlen( pcOut ) < xOutLen - 40u ) )
    {
        const unsigned i = ucList - 1u;

        if( aucHave[ i ] )
        {
            prvAppend( pcOut, xOutLen, "  %-3lu %s\n", ( uint32_t ) ausAll[ i ], prvName( ausAll[ i ] ) );
        }

        ucList++;
    }

    if( ucList > uTotal )
    {
        ucList = 0u;
        return pdFALSE;
    }

    return pdTRUE;
}

/* ------------------------------------------------------------------- command -- */

static uint8_t ucMode;    /* what a later call of the command continues: 0 nothing, 1 report, 2 list */

BaseType_t perf_command( char * pcOut, size_t xOutLen, const char * pcCommand )
{
    BaseType_t xLen, xLen2;
    const char * pcSub;

    /* a command that printed rows continues where it stopped */
    if( ucMode == 1u )
    {
        if( prvReport( pcOut, xOutLen ) == pdFALSE )
        {
            ucMode = 0u;
            return pdFALSE;
        }

        return pdTRUE;
    }

    if( ucMode == 2u )
    {
        if( prvListStep( pcOut, xOutLen ) == pdFALSE )
        {
            ucMode = 0u;
            return pdFALSE;
        }

        return pdTRUE;
    }

    if( prvCounters() == 0u )
    {
        shell_snprintf( pcOut, xOutLen, "%s", acNoCounters );
        return pdFALSE;
    }

    pcSub = FreeRTOS_CLIGetParameter( pcCommand, 1, &xLen );

    if( pcSub == NULL )
    {
        ucMode = 1u;
        ucRow = 0u;
        ( void ) prvReport( pcOut, xOutLen );   /* the header; the rows follow */
        return pdTRUE;
    }

    if( ( xLen == 5 ) && ( strncmp( pcSub, "clear", 5 ) == 0 ) )
    {
        prvClear();
        shell_snprintf( pcOut, xOutLen, "counters cleared\n" );
    }
    else if( ( xLen == 5 ) && ( strncmp( pcSub, "start", 5 ) == 0 ) )
    {
        prvStart();
        shell_snprintf( pcOut, xOutLen, "counters running\n" );
    }
    else if( ( xLen == 4 ) && ( strncmp( pcSub, "stop", 4 ) == 0 ) )
    {
        prvStop();
        shell_snprintf( pcOut, xOutLen, "counters stopped (mcycle and minstret keep counting)\n" );
    }
    else if( ( xLen == 4 ) && ( strncmp( pcSub, "list", 4 ) == 0 ) )
    {
        ucMode = 2u;
        ucList = 0u;
        ( void ) prvListStep( pcOut, xOutLen );   /* the heading; the events follow */
        return pdTRUE;
    }
    else if( ( xLen == 3 ) && ( strncmp( pcSub, "add", 3 ) == 0 ) )
    {
        const char * pcEv = FreeRTOS_CLIGetParameter( pcCommand, 2, &xLen2 );
        const int32_t lEvent = ( pcEv != NULL ) ? prvParseEvent( pcEv, xLen2 ) : -1;
        unsigned uFree = 0;

        if( lEvent <= 0 )
        {
            shell_snprintf( pcOut, xOutLen, "usage: perf add <event name or code>  (see 'perf list')\n" );
            return pdFALSE;
        }

        while( ( uFree < xPerf.ucCounters ) && ( xPerf.aulEvent[ uFree ] != 0u ) )
        {
            uFree++;
        }

        if( uFree == xPerf.ucCounters )
        {
            shell_snprintf( pcOut, xOutLen, "perf: all %u counters are in use ('perf preset <name>' loads a set afresh)\n",
                            ( unsigned ) xPerf.ucCounters );
            return pdFALSE;
        }

        if( prvAssign( uFree, ( uint32_t ) lEvent ) == 0u )
        {
            shell_snprintf( pcOut, xOutLen, "perf: %s (%ld) is not in this build\n", prvName( ( uint32_t ) lEvent ), ( long ) lEvent );
        }
        else
        {
            xPerf.cPreset = -1;
            shell_snprintf( pcOut, xOutLen, "counter %u counts %s\n", HPM_FIRST + uFree, prvName( ( uint32_t ) lEvent ) );
        }
    }
    else if( ( xLen == 6 ) && ( strncmp( pcSub, "preset", 6 ) == 0 ) )
    {
        const char * pcName = FreeRTOS_CLIGetParameter( pcCommand, 2, &xLen2 );
        int iPreset = -1;

        for( unsigned i = 0; ( pcName != NULL ) && ( i < PRESET_COUNT ); i++ )
        {
            if( ( ( BaseType_t ) strlen( axPresets[ i ].pcName ) == xLen2 ) && ( strncmp( pcName, axPresets[ i ].pcName, ( size_t ) xLen2 ) == 0 ) )
            {
                iPreset = ( int ) i;
            }
        }

        if( iPreset < 0 )
        {
            shell_snprintf( pcOut, xOutLen, "usage: perf preset cpi|mix|branch|traps|mem|icache|port\n" );
            return pdFALSE;
        }

        hpm_freeze( prvAllMask() );

        for( unsigned i = 0; i < xPerf.ucCounters; i++ )
        {
            xPerf.aulEvent[ i ] = 0u;
            ( void ) hpm_select( HPM_FIRST + i, HPM_EV_NONE );
        }

        for( unsigned i = 0; ( i < axPresets[ iPreset ].ucCount ) && ( i < xPerf.ucCounters ); i++ )
        {
            if( prvAssign( i, axPresets[ iPreset ].ausCode[ i ] ) == 0u )
            {
                for( unsigned j = 0; j < xPerf.ucCounters; j++ )
                {
                    xPerf.aulEvent[ j ] = 0u;
                }

                xPerf.cPreset = -1;
                shell_snprintf( pcOut, xOutLen, "perf: preset %s needs %s (%ld), which is not in this build\n", axPresets[ iPreset ].pcName,
                                prvName( axPresets[ iPreset ].ausCode[ i ] ), ( long ) axPresets[ iPreset ].ausCode[ i ] );
                return pdFALSE;
            }
        }

        xPerf.cPreset = ( int8_t ) iPreset;
        xPerf.ucRunning = 1u;
        prvClear();
        shell_snprintf( pcOut, xOutLen, "preset %s: %u events%s, cleared and running\n", axPresets[ iPreset ].pcName,
                        ( unsigned ) ( ( axPresets[ iPreset ].ucCount < xPerf.ucCounters ) ? axPresets[ iPreset ].ucCount : xPerf.ucCounters ),
                        ( axPresets[ iPreset ].ucCount > xPerf.ucCounters ) ? " (this CPU has fewer counters than the preset)" : "" );
    }
    else if( ( xLen == 3 ) && ( strncmp( pcSub, "run", 3 ) == 0 ) )
    {
        /* loader_cmd_run() skips the first word of the string it is given and takes the rest as the app's
         * arguments: hand it the line from the word 'run' on. It writes the app's report into pcOut;
         * the counters stop as soon as the app has ended, and the next calls show them. */
        prvClear();
        prvStart();
        ( void ) loader_cmd_run( pcOut, xOutLen, pcSub );
        prvStop();
        ucMode = 1u;
        ucRow = 0u;
        return pdTRUE;
    }
    else
    {
        shell_snprintf( pcOut, xOutLen, "usage: perf [preset <name> | add <event> | list | clear | start | stop | run [args]]\n" );
    }

    return pdFALSE;
}

#endif /* HPM_PERF */
