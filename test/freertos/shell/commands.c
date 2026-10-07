/* commands.c -- the commands of the HaDes-V+ FreeRTOS shell (FreeRTOS+CLI).
 *
 * Each command is a CLI_Command_Definition_t: the command word, its help line, the
 * function that produces the output, and the number of parameters (-1: any number).
 * The function writes its output into pcOut (xOutLen bytes,
 * configCOMMAND_INT_MAX_OUTPUT_SIZE) and returns pdFALSE when it is done, or pdTRUE to
 * be called again for more (the task list does that, one line per call). How to add a
 * command: docs/FREERTOS.md, "Add a command".
 *
 * Lines whose content depends on what the CPU implements (M, Zba, Zbb, Zbs, Zicntr,
 * Zicond, in the loader's build also Zbkb, Zbkx and Zknh, the branch predictor) begin with one of the labels "source:", "cpu:", "mode:"
 * or "accuracy:". test/freertos/shell/session.py relies on that when it compares the
 * transcript of the DUT with that of the golden CPU, which implements none of these.
 */
#include <string.h>
#include "FreeRTOS.h"
#include "task.h"
#include "FreeRTOS_CLI.h"
#include "hades_hal.h"
#include "shell.h"

/* --------------------------------------------------------------- helpers -- */

typedef struct
{
    char * pcBuf;
    size_t xSize;
    size_t xPos;
} Out_t;

static void prvOut( Out_t * pxOut, const char * pcFormat, ... ) __attribute__( ( format( printf, 2, 3 ) ) );
static void prvOut( Out_t * pxOut, const char * pcFormat, ... )
{
    va_list xArgs;

    va_start( xArgs, pcFormat );
    pxOut->xPos += ( size_t ) shell_vsnprintf( pxOut->pcBuf + pxOut->xPos, pxOut->xSize - pxOut->xPos, pcFormat, xArgs );
    va_end( xArgs );
}

/* Parameter uxIndex (1 = first) as a 32-bit number: decimal with an optional sign
 * (-2147483648 to 4294967295) or hexadecimal with a 0x prefix (up to 8 digits). */
static BaseType_t prvNumber( const char * pcCommand, UBaseType_t uxIndex, uint32_t * pulValue )
{
    BaseType_t xLen;
    const char * p = FreeRTOS_CLIGetParameter( pcCommand, uxIndex, &xLen );
    const char * pcEnd;
    uint64_t ullValue = 0;
    uint32_t ulBase = 10;
    int iNegative = 0;

    if( p == NULL )
    {
        return pdFALSE;
    }

    pcEnd = p + xLen;

    if( ( *p == '-' ) || ( *p == '+' ) )
    {
        iNegative = ( *p++ == '-' );
    }

    if( ( ( pcEnd - p ) > 2 ) && ( p[ 0 ] == '0' ) && ( ( p[ 1 ] | 0x20 ) == 'x' ) )
    {
        ulBase = 16;
        p += 2;
    }

    if( p == pcEnd )
    {
        return pdFALSE;
    }

    for( ; p < pcEnd; p++ )
    {
        const char c = ( char ) ( *p | 0x20 );   /* lower case for letters */
        uint32_t d;

        if( ( *p >= '0' ) && ( *p <= '9' ) )
        {
            d = ( uint32_t ) ( *p - '0' );
        }
        else if( ( ulBase == 16u ) && ( c >= 'a' ) && ( c <= 'f' ) )
        {
            d = ( uint32_t ) ( c - 'a' + 10 );
        }
        else
        {
            return pdFALSE;
        }

        ullValue = ( ullValue * ulBase ) + d;

        if( ullValue > 0xFFFFFFFFu )
        {
            return pdFALSE;
        }
    }

    if( iNegative && ( ullValue > 0x80000000u ) )
    {
        return pdFALSE;
    }

    *pulValue = iNegative ? ( 0u - ( uint32_t ) ullValue ) : ( uint32_t ) ullValue;
    return pdTRUE;
}

/* Two numeric parameters, or an error message in pcOut. */
static BaseType_t prvOperands( const char * pcCommand, UBaseType_t uxFirst, UBaseType_t uxSecond,
                               uint32_t * pulA, uint32_t * pulB, char * pcOut, size_t xOutLen )
{
    if( prvNumber( pcCommand, uxFirst, pulA ) && prvNumber( pcCommand, uxSecond, pulB ) )
    {
        return pdTRUE;
    }

    shell_snprintf( pcOut, xOutLen, "error: numbers are decimal (-2147483648 to 4294967295) or hexadecimal (0x...)\n" );
    return pdFALSE;
}

/* ullPart / ullTotal * ulScale, rounded. With ulScale 1000: a share in tenths of a
 * per cent, or an IPC in thousandths. */
static uint32_t prvRatio( uint64_t ullPart, uint64_t ullTotal, uint32_t ulScale )
{
    return ( ullTotal == 0u ) ? 0u : ( uint32_t ) shell_udiv64( ( ullPart * ulScale ) + ( ullTotal / 2u ), ullTotal, NULL );
}

/* The 64-bit counters: a high/low/high read so that a carry between the two halves
 * is never seen. */
#define CSR64( hi, lo )                                                \
    do {                                                               \
        __asm volatile ( "csrr %0, " #hi : "=r" ( h ) );               \
        __asm volatile ( "csrr %0, " #lo : "=r" ( l ) );               \
        __asm volatile ( "csrr %0, " #hi : "=r" ( h2 ) );              \
    } while( h != h2 )

enum { CNT_MCYCLE, CNT_MINSTRET, CNT_CYCLE, CNT_TIME, CNT_INSTRET };

static uint64_t prvCounter( int iWhich )
{
    uint32_t h, l, h2;

    switch( iWhich )
    {
        case CNT_MCYCLE:   CSR64( 0xB80, 0xB00 ); break;
        case CNT_MINSTRET: CSR64( 0xB82, 0xB02 ); break;
        case CNT_CYCLE:    CSR64( 0xC80, 0xC00 ); break;   /* Zicntr only */
        case CNT_TIME:     CSR64( 0xC81, 0xC01 ); break;   /* Zicntr only */
        default:           CSR64( 0xC82, 0xC02 ); break;   /* Zicntr only: instret */
    }

    return ( ( uint64_t ) h << 32 ) | l;
}

/* The run-time statistics clock (app_config.h): mcycle, counted from the start of
 * the scheduler, so that the boot is not charged to the first task that runs. */
static uint64_t ullRunTimeBase;

void shell_run_time_start( void )
{
    ullRunTimeBase = prvCounter( CNT_MCYCLE );
}

uint64_t shell_run_time( void )
{
    return prvCounter( CNT_MCYCLE ) - ullRunTimeBase;
}

/* --------------------------- CPU probe (M, Zba, Zbb, Zbs, Zicntr, Zicond) -- */

ShellCpu_t xShellCpu;
static volatile uint32_t ulProbeArmed, ulProbeTrapped;

/* The port calls this for every synchronous exception other than ECALL, and then
 * resumes after the faulting instruction. Only an illegal instruction during a probe
 * is expected; anything else ends the run. */
void freertos_risc_v_application_exception_handler( uint32_t mcause, uint32_t mepc_plus_4 )
{
    if( ( ulProbeArmed != 0u ) && ( mcause == 2u ) )
    {
        ulProbeTrapped = 1u;
        return;
    }

    #if SHELL_LOADER
        /* An exception raised by a running app ends the app, not the shell (loader.c). */
        if( loader_exception( mcause, mepc_plus_4 - 4u ) != 0 )
        {
            return;
        }
    #endif

    hal_fail( "unexpected exception (mcause, mepc)", NULL, mcause, mepc_plus_4 - 4u );
}

#define PROBE( insn )                                                  \
    ( { uint32_t v_ = 0;                                               \
        ulProbeTrapped = 0u;                                           \
        ulProbeArmed = 1u;                                             \
        __asm volatile ( insn : "+r" ( v_ ) : : "memory" );            \
        ulProbeArmed = 0u;                                             \
        ( uint8_t ) ( ulProbeTrapped == 0u ); } )

void shell_probe_cpu( void )
{
    xShellCpu.ucM = PROBE( ".insn r 0x33, 0, 1, %0, %0, %0" );        /* mul    */
    xShellCpu.ucZba = PROBE( ".insn r 0x33, 2, 0x10, %0, %0, %0" );   /* sh1add */
    xShellCpu.ucZbb = PROBE( ".insn i 0x13, 1, %0, %0, 0x600" );      /* clz       */
    xShellCpu.ucZbs = PROBE( ".insn r 0x33, 1, 0x14, %0, %0, %0" );   /* bset      */
    xShellCpu.ucZicntr = PROBE( "csrr %0, 0xC00" );                     /* cycle     */
    xShellCpu.ucZicond = PROBE( ".insn r 0x33, 5, 7, %0, %0, %0" );   /* czero.eqz */
    #if SHELL_LOADER
        /* the loader's build only (shell.h) */
        xShellCpu.ucZbkb = PROBE( ".insn r 0x33, 4, 4, %0, %0, %0" );    /* pack       */
        xShellCpu.ucZbkx = PROBE( ".insn r 0x33, 4, 0x14, %0, %0, %0" ); /* xperm8     */
        xShellCpu.ucZknh = PROBE( ".insn i 0x13, 1, %0, %0, 0x100" );    /* sha256sum0 */
    #endif
}

static const char * prvYesNo( uint8_t ucHave )
{
    return ucHave ? "yes" : "no";
}

/* ------------------------------------------------------------------ version -- */

static BaseType_t prvVersion( char * pcOut, size_t xOutLen, const char * pcCommand )
{
    ( void ) pcCommand;
    shell_snprintf( pcOut, xOutLen,
                    "HaDes-V+ shell: FreeRTOS %s, FreeRTOS+CLI\n"
                    "build:     %s %s, GCC %s; heap_%d, tick %d cycles, RAM %d KiB, bpred %d\n"
                    "cpu:       M %s, Zba %s, Zbb %s, Zbs %s, Zicntr %s, Zicond %s"
                    #if SHELL_LOADER
                        ", Zbkb %s, Zbkx %s, Zknh %s"
                    #endif
                    "\n",
                    tskKERNEL_VERSION_NUMBER, SHELL_ISA, SHELL_OPT, __VERSION__, FRTOS_HEAP, FRTOS_TICK_CYCLES,
                    FRTOS_RAM_KB, FRTOS_BPRED, prvYesNo( xShellCpu.ucM ), prvYesNo( xShellCpu.ucZba ),
                    prvYesNo( xShellCpu.ucZbb ), prvYesNo( xShellCpu.ucZbs ), prvYesNo( xShellCpu.ucZicntr ),
                    prvYesNo( xShellCpu.ucZicond )
                    #if SHELL_LOADER
                        , prvYesNo( xShellCpu.ucZbkb ), prvYesNo( xShellCpu.ucZbkx ), prvYesNo( xShellCpu.ucZknh )
                    #endif
                    );
    return pdFALSE;
}

/* -------------------------------------------------------------- tasks, stats -- */

#define SHELL_MAX_TASKS    8
static TaskStatus_t axTasks[ SHELL_MAX_TASKS ];
static UBaseType_t uxTasks, uxRow;
static uint64_t ullTasksTotal;

/* Multi-call helper of 'tasks' and 'stats'. The first call (uxRow 0) takes a
 * snapshot of all tasks, ordered by task number (creation order); the command
 * prints its header. Every later call returns the next row, NULL after the last. */
static const TaskStatus_t * prvNextTask( void )
{
    if( uxRow == 0u )
    {
        uxTasks = uxTaskGetSystemState( axTasks, SHELL_MAX_TASKS, NULL );
        ullTasksTotal = 0;

        for( UBaseType_t i = 0; i < uxTasks; i++ )
        {
            ullTasksTotal += axTasks[ i ].ulRunTimeCounter;

            for( UBaseType_t j = i; ( j > 0u ) && ( axTasks[ j - 1u ].xTaskNumber > axTasks[ j ].xTaskNumber ); j-- )
            {
                const TaskStatus_t xTmp = axTasks[ j ];
                axTasks[ j ] = axTasks[ j - 1u ];
                axTasks[ j - 1u ] = xTmp;
            }
        }

        uxRow = 1;
        return NULL;
    }

    if( uxRow <= uxTasks )
    {
        return &axTasks[ uxRow++ - 1u ];
    }

    uxRow = 0;
    return NULL;
}

static BaseType_t prvTasks( char * pcOut, size_t xOutLen, const char * pcCommand )
{
    static const char * const apcState[] = { "running", "ready", "blocked", "suspended", "deleted", "invalid" };
    const int iHeader = ( uxRow == 0u );
    const TaskStatus_t * pxTask = prvNextTask();

    ( void ) pcCommand;

    if( iHeader )
    {
        shell_snprintf( pcOut, xOutLen, "task        state      priority  stack free (min)\n" );
        return pdTRUE;
    }

    if( pxTask == NULL )
    {
        shell_snprintf( pcOut, xOutLen, ( uxTasks != 0u ) ? "%lu tasks\n" : "more than %lu tasks: raise SHELL_MAX_TASKS\n",
                        ( uint32_t ) ( ( uxTasks != 0u ) ? uxTasks : SHELL_MAX_TASKS ) );
        return pdFALSE;
    }

    shell_snprintf( pcOut, xOutLen, "%-10s  %-9s  %8lu  %10lu words\n", pxTask->pcTaskName,
                    apcState[ ( pxTask->eCurrentState <= eInvalid ) ? pxTask->eCurrentState : eInvalid ],
                    ( uint32_t ) pxTask->uxCurrentPriority, ( uint32_t ) pxTask->usStackHighWaterMark );
    return pdTRUE;
}

static BaseType_t prvStats( char * pcOut, size_t xOutLen, const char * pcCommand )
{
    const int iHeader = ( uxRow == 0u );
    const TaskStatus_t * pxTask = prvNextTask();

    ( void ) pcCommand;

    if( iHeader )
    {
        shell_snprintf( pcOut, xOutLen, "task            CPU cycles    share\n" );
        return pdTRUE;
    }

    if( pxTask == NULL )
    {
        shell_snprintf( pcOut, xOutLen, "total       %14llu   since the scheduler started (clock: mcycle)\n", ullTasksTotal );
        return pdFALSE;
    }

    {
        const uint32_t ulShare = prvRatio( pxTask->ulRunTimeCounter, ullTasksTotal, 1000u );
        shell_snprintf( pcOut, xOutLen, "%-10s  %14llu   %3lu.%lu%%\n", pxTask->pcTaskName,
                        ( uint64_t ) pxTask->ulRunTimeCounter, ulShare / 10u, ulShare % 10u );
    }
    return pdTRUE;
}

/* ---------------------------------------------------------------------- mem -- */

extern uint8_t __ram_start[], __ram_end[], __bss_end[], __isr_stack_bottom[];

static BaseType_t prvMem( char * pcOut, size_t xOutLen, const char * pcCommand )
{
    ( void ) pcCommand;
    shell_snprintf( pcOut, xOutLen,
                    "heap:      %zu of %zu bytes free, %zu at the lowest (heap_%d)\n"
                    "RAM:       %zu bytes: program and data %zu (with the heap), unused %zu,\n"
                    "           interrupt stack %lu (%lu used at most)\n",
                    xPortGetFreeHeapSize(),
                    ( size_t ) configTOTAL_HEAP_SIZE,
    #if ( FRTOS_HEAP == 4 )
                    xPortGetMinimumEverFreeHeapSize(),
    #else
                    xPortGetFreeHeapSize(),   /* heap_1 never frees */
    #endif
                    FRTOS_HEAP, ( size_t ) ( __ram_end - __ram_start ), ( size_t ) ( __bss_end - __ram_start ),
                    ( size_t ) ( __isr_stack_bottom - __bss_end ), hal_isr_stack_size(), hal_isr_stack_peak() );
    #if SHELL_LOADER
        {
            const size_t xUsed = strlen( pcOut );

            shell_snprintf( pcOut + xUsed, xOutLen - xUsed, "apps:      %lu-byte app slot at 0x%08lx ('app' shows what it holds)\n",
                            ( uint32_t ) HADES_APP_SLOT_SIZE, ( uint32_t ) HADES_APP_SLOT_BASE );
        }
    #endif
    return pdFALSE;
}

/* ------------------------------------------------------------------- uptime -- */

/* "12.345": ullCycles at ulHz, in seconds with three decimals. */
static void prvSeconds( char * pcBuf, uint64_t ullCycles, uint32_t ulHz )
{
    uint64_t ullMs = shell_udiv64( ullCycles, ulHz / 1000u, NULL ), ullFrac;

    ullMs = shell_udiv64( ullMs, 1000u, &ullFrac );
    shell_snprintf( pcBuf, 24, "%llu.%03lu", ullMs, ( uint32_t ) ullFrac );
}

static BaseType_t prvUptime( char * pcOut, size_t xOutLen, const char * pcCommand )
{
    const TickType_t xTicks = xTaskGetTickCount();
    uint32_t ulHi, ulLo;
    uint64_t ullMtime;
    char acRtos[ 24 ], acBoard[ 24 ];

    ( void ) pcCommand;

    do
    {
        ulHi = HADES_MTIME_HI;
        ulLo = HADES_MTIME_LO;
    } while( ulHi != HADES_MTIME_HI );

    ullMtime = ( ( uint64_t ) ulHi << 32 ) | ulLo;
    prvSeconds( acRtos, ullMtime, configCPU_CLOCK_HZ );
    prvSeconds( acBoard, ullMtime, SHELL_BOARD_CLOCK_HZ );
    shell_snprintf( pcOut, xOutLen,
                    "ticks:     %lu (%d cycles per tick)\n"
                    "mtime:     %llu cycles since reset\n"
                    "uptime:    %s s at configCPU_CLOCK_HZ = %lu Hz; %s s at the board's %lu MHz\n",
                    ( uint32_t ) xTicks, FRTOS_TICK_CYCLES, ullMtime, acRtos, ( uint32_t ) configCPU_CLOCK_HZ,
                    acBoard, ( uint32_t ) ( SHELL_BOARD_CLOCK_HZ / 1000000u ) );
    return pdFALSE;
}

/* ----------------------------------------------------------------- counters -- */

static BaseType_t prvCounters( char * pcOut, size_t xOutLen, const char * pcCommand )
{
    static uint64_t ullLastCycles, ullLastInstret;
    Out_t xOut = { pcOut, xOutLen, 0 };
    const uint64_t ullCycles = prvCounter( CNT_MCYCLE );
    const uint64_t ullInstret = prvCounter( CNT_MINSTRET );
    const uint32_t ulIpc = prvRatio( ullInstret, ullCycles, 1000u );

    ( void ) pcCommand;
    prvOut( &xOut, "cycles:    %llu (mcycle)\ninstret:   %llu (minstret)\nIPC:       %lu.%03lu since reset",
            ullCycles, ullInstret, ulIpc / 1000u, ulIpc % 1000u );

    if( ullLastCycles != 0u )
    {
        const uint32_t ulIpcLast = prvRatio( ullInstret - ullLastInstret, ullCycles - ullLastCycles, 1000u );
        prvOut( &xOut, ", %lu.%03lu since the last 'counters'", ulIpcLast / 1000u, ulIpcLast % 1000u );
    }

    ullLastCycles = ullCycles;
    ullLastInstret = ullInstret;

    if( xShellCpu.ucZicntr )
    {
        prvOut( &xOut, "\ncpu:       Zicntr: cycle %llu, time %llu, instret %llu\n",
                prvCounter( CNT_CYCLE ), prvCounter( CNT_TIME ), prvCounter( CNT_INSTRET ) );
    }
    else
    {
        prvOut( &xOut, "\ncpu:       no Zicntr (reading cycle, time, instret traps)\n" );
    }

    return pdFALSE;
}

/* -------------------------------------------------------------------- bpred -- */

static BaseType_t prvBpred( char * pcOut, size_t xOutLen, const char * pcCommand )
{
    static const char * const apcMode[ 4 ] = { "off: predict not taken", "predict taken",
                                              "backward taken, forward not taken", "bimodal, 2-bit counters" };
    Out_t xOut = { pcOut, xOutLen, 0 };
    BaseType_t xLen;
    const char * pcArg = FreeRTOS_CLIGetParameter( pcCommand, 1, &xLen );
    uint32_t ulMode, ulWanted = 0xFFFFFFFFu, nn, nt, tn, tt;
    uint64_t ullTotal;

    if( pcArg != NULL )
    {
        if( ( xLen == 1 ) && ( pcArg[ 0 ] >= '0' ) && ( pcArg[ 0 ] <= '3' ) )
        {
            ulWanted = ( uint32_t ) ( pcArg[ 0 ] - '0' );
            __asm volatile ( "csrw 0x32A, %0" :: "r" ( ulWanted ) );   /* MHPMEVENT10 */
        }
        else if( ( xLen != 5 ) || ( strncmp( pcArg, "reset", 5 ) != 0 ) )
        {
            shell_snprintf( pcOut, xOutLen, "usage: bpred [0|1|2|3|reset]\n" );
            return pdFALSE;
        }

        __asm volatile ( "csrw 0xB0A, zero\n csrw 0xB0B, zero\n csrw 0xB0C, zero\n csrw 0xB0D, zero" );
        prvOut( &xOut, "counters cleared\n" );
    }

    __asm volatile ( "csrr %0, 0x32A" : "=r" ( ulMode ) );
    __asm volatile ( "csrr %0, 0xB0A" : "=r" ( nn ) );   /* predicted not taken, not taken */
    __asm volatile ( "csrr %0, 0xB0B" : "=r" ( nt ) );   /* predicted not taken, taken */
    __asm volatile ( "csrr %0, 0xB0C" : "=r" ( tn ) );   /* predicted taken, not taken */
    __asm volatile ( "csrr %0, 0xB0D" : "=r" ( tt ) );   /* predicted taken, taken */
    ullTotal = ( uint64_t ) nn + nt + tn + tt;

    prvOut( &xOut, "mode:      %lu (%s)\n", ulMode, ( ulMode < 4u ) ? apcMode[ ulMode ] : "unknown" );

    if( ( ulWanted != 0xFFFFFFFFu ) && ( ulMode != ulWanted ) )
    {
        prvOut( &xOut, "cpu:       mode %lu not taken: no branch predictor\n", ulWanted );
    }

    prvOut( &xOut, "branches:  predicted not taken: %lu right (nn), %lu wrong (nt)\n"
                   "           predicted taken:     %lu right (tt), %lu wrong (tn)\n", nn, nt, tt, tn );

    if( ullTotal != 0u )
    {
        const uint32_t ulPm = prvRatio( ( uint64_t ) nn + tt, ullTotal, 1000u );
        prvOut( &xOut, "accuracy:  %lu.%lu%% of %llu\n", ulPm / 10u, ulPm % 10u, ullTotal );
    }
    else
    {
        prvOut( &xOut, "accuracy:  none counted\n" );
    }

    return pdFALSE;
}

/* ------------------------------------------------------------ mul, div, zba -- */

/* The M and Zba instructions, encoded with .insn so that they assemble whatever
 * -march the program is built for. Executed only when the probe found them. */
#define MOP( f3, a, b )                                                                        \
    ( { uint32_t r_;                                                                           \
        __asm volatile ( ".insn r 0x33, " #f3 ", 1, %0, %1, %2" : "=r" ( r_ ) : "r" ( a ), "r" ( b ) ); \
        r_; } )
#define SHADD( f3, a, b )                                                                      \
    ( { uint32_t r_;                                                                           \
        __asm volatile ( ".insn r 0x33, " #f3 ", 0x10, %0, %1, %2" : "=r" ( r_ ) : "r" ( a ), "r" ( b ) ); \
        r_; } )

/* The results of mul, mulh, mulhsu, mulhu, div, rem, divu and remu: from the CPU's
 * instructions where it has M, from the software model otherwise. *piMatch tells
 * whether the two agree (always 1 without M). */
typedef struct
{
    ShellMulResult_t xMul;
    ShellDivResult_t xDiv;
} Arith_t;

static void prvArith( uint32_t a, uint32_t b, Arith_t * pxRes, int * piMatch )
{
    Arith_t xSw;

    swmodel_mul( a, b, &xSw.xMul );
    swmodel_div( a, b, &xSw.xDiv );
    *pxRes = xSw;

    if( xShellCpu.ucM )
    {
        pxRes->xMul.ulMul = MOP( 0, a, b );
        pxRes->xMul.ulMulh = MOP( 1, a, b );
        pxRes->xMul.ulMulhsu = MOP( 2, a, b );
        pxRes->xMul.ulMulhu = MOP( 3, a, b );
        pxRes->xDiv.ulDiv = MOP( 4, a, b );
        pxRes->xDiv.ulDivu = MOP( 5, a, b );
        pxRes->xDiv.ulRem = MOP( 6, a, b );
        pxRes->xDiv.ulRemu = MOP( 7, a, b );
    }

    *piMatch = ( memcmp( pxRes, &xSw, sizeof( xSw ) ) == 0 );
}

static void prvSource( Out_t * pxOut, uint8_t ucHave, int iMatch, const char * pcExt )
{
    prvOut( pxOut, "source:    %s %s%s\n", ucHave ? "the CPU's" : "rv32i software model: the CPU has no", pcExt,
            !ucHave ? "" : ( iMatch ? " instructions, equal to the rv32i software model"
                                    : " instructions, DIFFERENT from the rv32i software model" ) );
}

/* The rows of mul/div/zba: ppcName holds (name, note) pairs, pulValue the results and,
 * at [4] and [5], the operands. Row i is printed signed, or unsigned when bit i of
 * ulUnsigned is set, and in hexadecimal. */
static BaseType_t prvRows( char * pcOut, size_t xOutLen, const char * pcHead, const char * const * ppcName,
                           const uint32_t * pulValue, uint32_t ulUnsigned, uint8_t ucHave, int iMatch, const char * pcExt )
{
    Out_t xOut = { pcOut, xOutLen, 0 };

    prvOut( &xOut, "%s", pcHead );

    for( int i = 0; ( i < 4 ) && ( ppcName[ 2 * i ] != NULL ); i++ )
    {
        prvOut( &xOut, ( ( ulUnsigned >> i ) & 1u ) ? "  %-7s%11lu  0x%08lx  %s\n" : "  %-7s%11ld  0x%08lx  %s\n",
                ppcName[ 2 * i ], pulValue[ i ], pulValue[ i ], ppcName[ 2 * i + 1 ] );
    }

    if( ulUnsigned == 0xCu )   /* div */
    {
        const uint32_t a = pulValue[ 4 ], b = pulValue[ 5 ];

        if( b == 0u )
        {
            prvOut( &xOut, "note:      x / 0 does not trap: quotient all ones, remainder x\n" );
        }
        else if( ( a == 0x80000000u ) && ( b == 0xFFFFFFFFu ) )
        {
            prvOut( &xOut, "note:      -2^31 / -1 overflows without a trap: quotient -2^31, remainder 0\n" );
        }
    }

    prvSource( &xOut, ucHave, iMatch, pcExt );
    return pdFALSE;
}

/* mul <a> <b>, div <a> <b>, zba <a> <b>: the command word selects the table. */
static BaseType_t prvArithCommand( char * pcOut, size_t xOutLen, const char * pcCommand )
{
    static const char * const apcMul[] = { "mul", "low 32 bits", "mulh", "high 32, signed x signed",
                                           "mulhsu", "high 32, signed x unsigned", "mulhu", "high 32, unsigned x unsigned" };
    static const char * const apcDiv[] = { "div", "quotient, signed", "rem", "remainder, signed",
                                           "divu", "quotient, unsigned", "remu", "remainder, unsigned" };
    static const char * const apcZba[] = { "sh1add", "(a << 1) + b", "sh2add", "(a << 2) + b",
                                           "sh3add", "(a << 3) + b", NULL, NULL };
    uint32_t a, b, aulValue[ 6 ], aulSw[ 3 ];
    char acHead[ 64 ];
    Arith_t xRes;
    int iMatch;

    if( !prvOperands( pcCommand, 1, 2, &a, &b, pcOut, xOutLen ) )
    {
        return pdFALSE;
    }

    aulValue[ 4 ] = a;
    aulValue[ 5 ] = b;
    shell_snprintf( acHead, sizeof( acHead ), "a = %ld (0x%08lx), b = %ld (0x%08lx)\n", ( int32_t ) a, a, ( int32_t ) b, b );

    if( pcCommand[ 0 ] == 'z' )
    {
        for( unsigned i = 0; i < 3u; i++ )
        {
            aulSw[ i ] = swmodel_shadd( a, b, i + 1u );
            aulValue[ i ] = aulSw[ i ];
        }

        if( xShellCpu.ucZba )
        {
            aulValue[ 0 ] = SHADD( 2, a, b );
            aulValue[ 1 ] = SHADD( 4, a, b );
            aulValue[ 2 ] = SHADD( 6, a, b );
        }

        return prvRows( pcOut, xOutLen, acHead, apcZba, aulValue, 0u, xShellCpu.ucZba,
                        memcmp( aulValue, aulSw, sizeof( aulSw ) ) == 0, "Zba" );
    }

    prvArith( a, b, &xRes, &iMatch );

    if( pcCommand[ 0 ] == 'm' )
    {
        aulValue[ 0 ] = xRes.xMul.ulMul;
        aulValue[ 1 ] = xRes.xMul.ulMulh;
        aulValue[ 2 ] = xRes.xMul.ulMulhsu;
        aulValue[ 3 ] = xRes.xMul.ulMulhu;
        return prvRows( pcOut, xOutLen, acHead, apcMul, aulValue, 0x8u, xShellCpu.ucM, iMatch, "M" );
    }

    aulValue[ 0 ] = xRes.xDiv.ulDiv;
    aulValue[ 1 ] = xRes.xDiv.ulRem;
    aulValue[ 2 ] = xRes.xDiv.ulDivu;
    aulValue[ 3 ] = xRes.xDiv.ulRemu;
    return prvRows( pcOut, xOutLen, acHead, apcDiv, aulValue, 0xCu, xShellCpu.ucM, iMatch, "M" );
}

/* --------------------------------------------------------------------- uart -- */

static BaseType_t prvUart( char * pcOut, size_t xOutLen, const char * pcCommand )
{
    ShellRxStats_t xStats;

    ( void ) pcCommand;
    shell_rx_stats( &xStats );
    shell_snprintf( pcOut, xOutLen, "received:  %lu\ndropped:   %lu (receive queue full)\noverruns:  %lu (lost in the UART)\n",
                    xStats.ulReceived, xStats.ulDropped, xStats.ulOverruns );
    return pdFALSE;
}

/* --------------------------------------------------------------- echo, halt -- */

static BaseType_t prvEcho( char * pcOut, size_t xOutLen, const char * pcCommand )
{
    BaseType_t xLen;
    const char * pcText = FreeRTOS_CLIGetParameter( pcCommand, 1, &xLen );

    shell_snprintf( pcOut, xOutLen, "%s\n", ( pcText != NULL ) ? pcText : "" );
    return pdFALSE;
}

static BaseType_t prvHalt( char * pcOut, size_t xOutLen, const char * pcCommand )
{
    ( void ) pcOut;
    ( void ) xOutLen;
    ( void ) pcCommand;
    shell_puts( "halted\n" );
    hal_pass();   /* FRTOS-RESULT: PASS, then the test register ends the simulation */
}

/* ------------------------------------------------------------- registration -- */

static const CLI_Command_Definition_t axCommands[] =
{
    { "version",  "version            Software, build and CPU extensions\r\n", prvVersion, 0 },
    { "tasks",    "tasks              Tasks: state, priority, free stack\r\n", prvTasks, 0 },
    { "stats",    "stats              CPU cycles used by each task\r\n", prvStats, 0 },
    { "mem",      "mem                Heap and RAM use\r\n", prvMem, 0 },
    { "uptime",   "uptime             Ticks, mtime, seconds since reset\r\n", prvUptime, 0 },
    { "counters", "counters           Cycles, instructions, IPC\r\n", prvCounters, 0 },
    { "bpred",    "bpred [0-3|reset]  Branch predictor mode and counters\r\n", prvBpred, -1 },
    { "mul",      "mul <a> <b>        mul, mulh, mulhsu, mulhu\r\n", prvArithCommand, 2 },
    { "div",      "div <a> <b>        div, rem, divu, remu\r\n", prvArithCommand, 2 },
    { "zba",      "zba <a> <b>        sh1add, sh2add, sh3add\r\n", prvArithCommand, 2 },
    { "uart",     "uart               UART receive statistics\r\n", prvUart, 0 },
    { "echo",     "echo <text>        Print the text\r\n", prvEcho, -1 },
#if SHELL_LOADER
    { "load",     "load [name]        Receive an app (Intel HEX) into the app slot\r\n", loader_cmd_load, -1 },
    { "run",      "run [args...]      Run the loaded app (Ctrl-C stops it)\r\n", loader_cmd_run, -1 },
    { "app",      "app                The loaded app: name, size, entry, CRC32\r\n", loader_cmd_app, 0 },
#endif
    { "halt",     "halt               Stop (ends the simulation)\r\n", prvHalt, 0 },
    { "exit",     "exit               The same as halt\r\n", prvHalt, 0 },
};

void shell_register_commands( void )
{
    for( size_t i = 0; i < sizeof( axCommands ) / sizeof( axCommands[ 0 ] ); i++ )
    {
        ( void ) FreeRTOS_CLIRegisterCommand( &axCommands[ i ] );   /* configASSERT()s success */
    }
}
