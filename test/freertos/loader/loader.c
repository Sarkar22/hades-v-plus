/* loader.c -- the app loader of the HaDes-V+ FreeRTOS shell: programs built on the host are
 * sent over the UART, kept in RAM and run as a task (test/freertos/loader/SPEC.md).
 *
 * The loader configuration is the shell of test/freertos/shell/ compiled with SHELL_LOADER=1,
 * plus this file, on a simulated RAM of 256 KiB. The shell is linked for the first 128 KiB;
 * the second 128 KiB is the app slot, whose layout is part of the interface with the apps
 * (test/freertos/sdk/hades_app.h, ABI version 1):
 *
 *   0x00060000        the image: a 64-byte header, code, read-only data, data
 *   + image size      .sbss and .bss (zeroed by the app's crt0.S), then the app's free memory
 *   copy - stack      the app task's stack, growing down
 *   copy              the saved copy of the image, from which every run restores it; copy is
 *                     0x00080000 minus the image size rounded up to a multiple of 16
 *
 * Commands
 *   load   receives an Intel HEX file into the slot. Every record line is answered with one
 *          byte, ACK or NAK, and the simulator's console bridge (sim/console.cpp) types the
 *          next line only after that answer; DC2 tells it that a file is wanted. 'load <name>'
 *          names the file, between two DC4 before the DC2: the bridge sends that app's file,
 *          or, if it has none, a line '!<reason>', which ends the load with that reason. The
 *          records are checked as they arrive, the image after the end-of-file record
 *          (header, sizes, entry, CRC-32). Ctrl-C cancels.
 *   run    checks the saved copy, restores the image from it and runs it as the task "app"
 *          (priority 1, below the console task): entry(api, argc, argv). The console task
 *          waits for the end and reports it: a return from main(), app_exit(), Ctrl-C (taken
 *          by the receive interrupt, or found in the receive queue as the run starts), an
 *          exception or a stack overflow (reported whatever else ended the app).
 *   app    the loaded app.
 *
 * Containment. HaDes-V+ runs in machine mode only, so an app can overwrite anything and the
 * shell cannot prevent it. What it contains: an exception raised while the app task runs, in
 * the app's code or in a shell function that the app called, outside critical sections and
 * with the scheduler running; and a stack overflow of the app task that FreeRTOS detects when
 * it switches away from it. In both cases the port's trap handler has saved the app task's
 * context on the app's stack. loader_exception() or the stack overflow hook changes the saved
 * resume address to loader_trampoline, which continues with the shell's gp on a fresh stack
 * and tells the console task, which deletes the app task. Any other exception (in another
 * task, in an interrupt handler, in the trampoline) ends the simulation through hal_fail(), as
 * in the shell.
 */
#include <string.h>
#include "FreeRTOS.h"
#include "task.h"
#include "FreeRTOS_CLI.h"
#include "hades_hal.h"
#include "shell.h"

#if !SHELL_LOADER
    #error "loader.c belongs to the loader configuration: the shell's sources compiled with -DSHELL_LOADER=1 (test/freertos/loader/app.mk)"
#endif
#if FRTOS_RAM_KB < 256
    #error "the loader needs a simulated RAM of 256 KiB (RAM_KB=256): the app slot ends at 0x00080000"
#endif
#if ( configSUPPORT_STATIC_ALLOCATION != 1 ) || ( INCLUDE_vTaskDelete != 1 )
    #error "the loader needs configSUPPORT_STATIC_ALLOCATION and INCLUDE_vTaskDelete (test/freertos/loader/app_config.h)"
#endif

/* The API counts in milliseconds, the kernel in ticks. */
_Static_assert( configTICK_RATE_HZ == 1000, "one tick must be one millisecond" );

/* ------------------------------------------------------------------ settings -- */

#define LOADER_APP_PRIORITY      1      /* below the console task (SHELL_CONSOLE_PRIORITY) */
#define LOADER_MAX_ARGS          8      /* words after 'run' */
#define LOADER_RECORD_MAX        75     /* characters of a record line: ':' and 32 data bytes */
#define LOADER_IDLE_TICKS        2000   /* a pause this long in a file ends the load */
#define LOADER_DOT_BYTES         1024   /* load prints a '.' for every 1024 bytes stored */
#define LOADER_CTRL_C            0x03

/* What ended a run: bits of the console task's notification value. */
#define LOADER_END_EXIT          ( 1u << 0 )
#define LOADER_END_FAULT         ( 1u << 1 )
#define LOADER_END_CTRLC         ( 1u << 2 )
#define LOADER_END_ANY           ( LOADER_END_EXIT | LOADER_END_FAULT | LOADER_END_CTRLC )

/* The context that the port's trap handler saves on the stack of the interrupted task
 * (portable/GCC/RISC-V/portContext.h: RV32, no FPU, no additional registers), 31 words:
 * word 0 the resume address (mepc, plus 4 after an exception), word 1 mstatus, words 2 to 29
 * x1 and x5 to x31, word 30 the task's critical nesting count. */
#define LOADER_FRAME_WORDS       31u
#define LOADER_FRAME_PC          0
#define LOADER_FRAME_MSTATUS     1
#define LOADER_FRAME_RA          2
#define LOADER_FRAME_NESTING     30
#define LOADER_MSTATUS_MPIE      0x00000080u
#define LOADER_MSTATUS_MPP_M     0x00001800u

/* The four words at the bottom of a task's stack that FreeRTOS checks for an overflow
 * (configCHECK_FOR_STACK_OVERFLOW 2, tskSTACK_FILL_BYTE). */
#define LOADER_STACK_CHECK       0xa5a5a5a5u

/* --------------------------------------------------------------------- state -- */

static HadesAppHeader_t xApp;           /* the loaded app's header (valid while ulLoaded) */
static uint32_t ulLoaded;
static volatile uint32_t ulRunning;     /* an app task exists: the receive interrupt takes Ctrl-C */
static TaskHandle_t xConsoleTask;       /* the task that runs the commands */
static TaskHandle_t xAppTask;           /* the app task while it exists, else NULL */
static StaticTask_t xAppTaskBuffer;
static int iAppArgc;
static char ** ppcAppArgv;
static int iExitCode;

typedef enum
{
    FAULT_NONE = 0,
    FAULT_EXCEPTION,
    FAULT_STACK
} FaultKind_t;

static struct
{
    uint32_t ulKind;       /* FaultKind_t */
    uint32_t ulCause;      /* mcause */
    uint32_t ulPc;         /* mepc: the instruction that raised the exception */
    uint32_t ulTval;       /* mtval */
    uint32_t ulRa;         /* the app's ra at the exception */
    uint32_t ulOverflow;   /* 1: the app's stack overflowed in this run */
} xFault;

/* The top of the app task's stack in this run (the saved copy's address), where
 * loader_trampoline continues. Not static: the trampoline is written in assembly. */
uint32_t ulLoaderStackTop;

void loader_trampoline( void );
void loader_app_faulted( void ) __attribute__( ( noreturn ) );
void loader_app_exit( int iCode ) __attribute__( ( noreturn ) );

extern uint8_t __ram_start[], __ram_end[];

/* ------------------------------------------------------------------- helpers -- */

/* The address of the saved copy of an image of ulImageSize bytes. */
static uint32_t prvCopyBase( uint32_t ulImageSize )
{
    return HADES_APP_SLOT_END - ( ( ulImageSize + 15u ) & ~15u );
}

/* The image has just been written: let instruction fetch see it. */
static void prvFenceI( void )
{
    __asm volatile ( "fence.i" ::: "memory" );
}

/* "rv32i", "rv32im", "rv32i_zba" or "rv32im_zba": what an image needs (its ulFlags). */
static const char * prvIsa( uint32_t ulFlags )
{
    static const char * const apcIsa[ 4 ] = { "rv32i", "rv32im", "rv32i_zba", "rv32im_zba" };

    return apcIsa[ ulFlags & ( HADES_APP_NEEDS_M | HADES_APP_NEEDS_ZBA ) ];
}

/* Appends to the NUL-terminated text in pcOut (xOutLen bytes). */
static void prvAppend( char * pcOut, size_t xOutLen, const char * pcFormat, ... ) __attribute__( ( format( printf, 3, 4 ) ) );
static void prvAppend( char * pcOut, size_t xOutLen, const char * pcFormat, ... )
{
    const size_t xUsed = strlen( pcOut );
    va_list xArgs;

    va_start( xArgs, pcFormat );
    ( void ) shell_vsnprintf( pcOut + xUsed, xOutLen - xUsed, pcFormat, xArgs );
    va_end( xArgs );
}

/* A line of its own: pcOut starts with a line end if the output is in the middle of a line
 * (after the dots of load, or after an app that did not end its last line). */
static void prvStartLine( char * pcOut, size_t xOutLen )
{
    pcOut[ 0 ] = '\0';

    if( !shell_output_at_line_start() )
    {
        prvAppend( pcOut, xOutLen, "\n" );
    }
}

/* CRC-32 of IEEE 802.3, as zlib.crc32() computes it, of ulLength bytes from ulAddress, with
 * the four bytes of the header's ulCrc32 field read as 0; a 16-entry table, four bits per
 * step. */
static uint32_t prvCrc32( uint32_t ulAddress, uint32_t ulLength )
{
    static const uint32_t aulTable[ 16 ] =
    {
        0x00000000u, 0x1DB71064u, 0x3B6E20C8u, 0x26D930ACu, 0x76DC4190u, 0x6B6B51F4u, 0x4DB26158u, 0x5005713Cu,
        0xEDB88320u, 0xF00F9344u, 0xD6D6A3E8u, 0xCB61B38Cu, 0x9B64C2B0u, 0x86D3D2D4u, 0xA00AE278u, 0xBDBDF21Cu
    };
    const uint8_t * const pucData = ( const uint8_t * ) ( uintptr_t ) ulAddress;
    const uint32_t ulField = offsetof( HadesAppHeader_t, ulCrc32 );
    uint32_t ulCrc = 0xFFFFFFFFu;

    for( uint32_t i = 0; i < ulLength; i++ )
    {
        const uint32_t ulByte = ( ( i - ulField ) < 4u ) ? 0u : pucData[ i ];

        ulCrc = aulTable[ ( ulCrc ^ ulByte ) & 15u ] ^ ( ulCrc >> 4 );
        ulCrc = aulTable[ ( ulCrc ^ ( ulByte >> 4 ) ) & 15u ] ^ ( ulCrc >> 4 );
    }

    return ~ulCrc;
}

/* ---------------------------------------------------------------------- load -- */

typedef struct
{
    uint32_t ulLines;     /* non-empty lines received, the current one included */
    size_t xLen;          /* characters of the current line (counted up to 76) */
    uint32_t ulUpper;     /* the upper 16 bits of the data addresses (type 04) */
    uint32_t ulNext;      /* where the next data record must start */
    uint32_t ulNextDot;   /* bytes stored at which the next '.' is printed */
    uint32_t ulStart;     /* the address of the type 05 record, if ucStart */
    uint8_t ucStart;
} Load_t;

static Load_t xLoad;
static char acRecord[ LOADER_RECORD_MAX + 1 ];   /* the current line, its first 75 characters */
static char acError[ 160 ];                      /* the first error; "" while there is none */

/* Records the first error of a load; later ones are ignored. iLine: the reason refers to the
 * current line ("line <n>: " in front). */
static void prvLoadError( int iLine, const char * pcFormat, ... ) __attribute__( ( format( printf, 2, 3 ) ) );
static void prvLoadError( int iLine, const char * pcFormat, ... )
{
    va_list xArgs;
    int n = 0;

    if( acError[ 0 ] != '\0' )
    {
        return;
    }

    if( iLine )
    {
        n = shell_snprintf( acError, sizeof( acError ), "line %lu: ", xLoad.ulLines );
    }

    va_start( xArgs, pcFormat );
    ( void ) shell_vsnprintf( acError + n, sizeof( acError ) - ( size_t ) n, pcFormat, xArgs );
    va_end( xArgs );
}

static int prvHexValue( char c )
{
    if( ( c >= '0' ) && ( c <= '9' ) )
    {
        return c - '0';
    }

    if( ( c >= 'a' ) && ( c <= 'f' ) )
    {
        return c - 'a' + 10;
    }

    if( ( c >= 'A' ) && ( c <= 'F' ) )
    {
        return c - 'A' + 10;
    }

    return -1;
}

/* A character of a line (not a line end). The first three checks are made as the
 * characters arrive, so the first offending character decides. */
static void prvLoadChar( char c )
{
    if( xLoad.xLen == 0u )
    {
        xLoad.ulLines++;
    }

    if( xLoad.xLen < LOADER_RECORD_MAX )
    {
        acRecord[ xLoad.xLen ] = c;
    }

    if( xLoad.xLen <= LOADER_RECORD_MAX )
    {
        xLoad.xLen++;
    }

    if( xLoad.xLen == 1u )
    {
        if( c != ':' )
        {
            prvLoadError( 1, "a record starts with ':'" );
        }
    }
    else if( prvHexValue( c ) < 0 )
    {
        if( ( c >= 0x20 ) && ( c <= 0x7E ) )
        {
            prvLoadError( 1, "'%c' is not a hexadecimal digit", c );
        }
        else
        {
            prvLoadError( 1, "0x%02x is not a hexadecimal digit", ( unsigned ) ( uint8_t ) c );
        }
    }
    else if( xLoad.xLen > LOADER_RECORD_MAX )
    {
        prvLoadError( 1, "record too long (at most 32 data bytes)" );
    }
}

/* The current line is the end-of-file record, in either case. */
static int prvIsEndRecord( void )
{
    static const char acEnd[] = ":00000001ff";

    if( xLoad.xLen != sizeof( acEnd ) - 1u )
    {
        return 0;
    }

    for( size_t i = 0; i < sizeof( acEnd ) - 1u; i++ )
    {
        const char c = acRecord[ i ];

        if( ( c != acEnd[ i ] ) && !( ( acEnd[ i ] == 'f' ) && ( c == 'F' ) ) )
        {
            return 0;
        }
    }

    return 1;
}

/* A data record whose checks so far have passed: stored if it lies in the slot right after
 * the previous one. */
static void prvLoadData( const uint8_t * pucData, uint32_t ulAddress, uint32_t ulLength )
{
    const uint32_t ulFull = ( xLoad.ulUpper << 16 ) + ulAddress;

    if( ulAddress + ulLength > 0x10000u )
    {
        prvLoadError( 1, "record crosses a 64 KiB boundary" );
    }
    else if( ( ulFull < HADES_APP_SLOT_BASE ) || ( ( uint64_t ) ulFull + ulLength > HADES_APP_SLOT_END ) )
    {
        prvLoadError( 1, "address 0x%08lx is outside the app slot (0x%08lx-0x%08lx)", ulFull,
                      ( uint32_t ) HADES_APP_SLOT_BASE, ( uint32_t ) ( HADES_APP_SLOT_END - 1u ) );
    }
    else if( ulFull != xLoad.ulNext )
    {
        prvLoadError( 1, "address 0x%08lx, expected 0x%08lx (data records must be contiguous, from the slot base)",
                      ulFull, xLoad.ulNext );
    }
    else
    {
        /* Written only now, after every check of the record. */
        memcpy( ( void * ) ( uintptr_t ) ulFull, pucData, ulLength );
        xLoad.ulNext += ulLength;

        while( xLoad.ulNext - HADES_APP_SLOT_BASE >= xLoad.ulNextDot )
        {
            shell_puts( "." );
            xLoad.ulNextDot += LOADER_DOT_BYTES;
        }
    }
}

/* The end of a non-empty line: the remaining checks, the record's effect, the answer (one
 * byte, ACK or NAK). Returns 1 when the line was the end-of-file record. */
static int prvLoadLine( void )
{
    uint8_t aucByte[ ( LOADER_RECORD_MAX - 1 ) / 2 ];
    int iEnd = 0;

    if( acError[ 0 ] != '\0' )
    {
        /* After an error every line is rejected unchecked, up to and including an
         * end-of-file record. */
        iEnd = prvIsEndRecord();
        hal_putc( ( char ) HADES_CON_NAK );
        return iEnd;
    }

    /* Here the line starts with ':', is followed only by hexadecimal digits, and has at most
     * 75 characters (checked as they arrived). */
    if( ( xLoad.xLen < 11u ) || ( ( xLoad.xLen & 1u ) == 0u ) )
    {
        prvLoadError( 1, "malformed record" );
    }
    else
    {
        const uint32_t ulCount = ( uint32_t ) ( xLoad.xLen - 1u ) / 2u;
        uint32_t ulSum = 0, ulLength, ulAddress, ulType;

        for( uint32_t i = 0; i < ulCount; i++ )
        {
            aucByte[ i ] = ( uint8_t ) ( ( prvHexValue( acRecord[ 1u + 2u * i ] ) << 4 ) | prvHexValue( acRecord[ 2u + 2u * i ] ) );
            ulSum += aucByte[ i ];
        }

        ulLength = aucByte[ 0 ];
        ulAddress = ( ( uint32_t ) aucByte[ 1 ] << 8 ) | aucByte[ 2 ];
        ulType = aucByte[ 3 ];

        if( ulLength + 5u != ulCount )
        {
            prvLoadError( 1, "malformed record (it announces %lu data bytes and holds %lu)", ulLength, ulCount - 5u );
        }
        else if( ( ulSum & 0xFFu ) != 0u )
        {
            prvLoadError( 1, "checksum mismatch" );
        }
        else if( ( ulType != 0u ) && ( ulType != 1u ) && ( ulType != 4u ) && ( ulType != 5u ) )
        {
            prvLoadError( 1, "record type %02lx is not supported (only 00, 01, 04 and 05)", ulType );
        }
        else if( ( ulType != 0u ) && ( ( ulAddress != 0u ) || ( ulLength != ( ( ulType == 1u ) ? 0u : ( ulType == 4u ) ? 2u : 4u ) ) ) )
        {
            prvLoadError( 1, "malformed type %02lx record", ulType );
        }
        else if( ulType == 0u )
        {
            prvLoadData( &aucByte[ 4 ], ulAddress, ulLength );
        }
        else if( ulType == 1u )
        {
            iEnd = 1;
        }
        else if( ulType == 4u )
        {
            xLoad.ulUpper = ( ( uint32_t ) aucByte[ 4 ] << 8 ) | aucByte[ 5 ];
        }
        else
        {
            xLoad.ulStart = ( ( uint32_t ) aucByte[ 4 ] << 24 ) | ( ( uint32_t ) aucByte[ 5 ] << 16 ) |
                            ( ( uint32_t ) aucByte[ 6 ] << 8 ) | aucByte[ 7 ];
            xLoad.ucStart = 1u;
        }
    }

    hal_putc( ( char ) ( ( acError[ 0 ] == '\0' ) ? HADES_CON_ACK : HADES_CON_NAK ) );
    return iEnd;
}

/* The name field: 1 to 15 of A-Z a-z 0-9 _ -, then NULs up to its end. */
static int prvNameValid( const char * pcName )
{
    size_t n = 0;

    while( ( n < HADES_APP_NAME_SIZE ) &&
           ( ( ( pcName[ n ] >= 'A' ) && ( pcName[ n ] <= 'Z' ) ) || ( ( pcName[ n ] >= 'a' ) && ( pcName[ n ] <= 'z' ) ) ||
             ( ( pcName[ n ] >= '0' ) && ( pcName[ n ] <= '9' ) ) || ( pcName[ n ] == '_' ) || ( pcName[ n ] == '-' ) ) )
    {
        n++;
    }

    if( ( n == 0u ) || ( n == HADES_APP_NAME_SIZE ) )
    {
        return 0;
    }

    for( ; n < HADES_APP_NAME_SIZE; n++ )
    {
        if( pcName[ n ] != '\0' )
        {
            return 0;
        }
    }

    return 1;
}

/* The checks of the image received, in the order of SPEC.md, section 4.3. Returns 1 and the
 * header in *pxHeader if the image is valid; otherwise records the reason. */
static int prvCheckImage( HadesAppHeader_t * pxHeader )
{
    const uint32_t ulBytes = xLoad.ulNext - HADES_APP_SLOT_BASE;
    const uint32_t ulKnown = HADES_APP_NEEDS_M | HADES_APP_NEEDS_ZBA;
    HadesAppHeader_t xH;
    uint64_t ullNeed;
    uint32_t ulCrc;

    if( ulBytes < HADES_APP_HEADER_SIZE )
    {
        prvLoadError( 0, "the file holds %lu bytes, less than a %lu-byte header", ulBytes, ( uint32_t ) HADES_APP_HEADER_SIZE );
        return 0;
    }

    memcpy( &xH, ( const void * ) HADES_APP_SLOT_BASE, sizeof( xH ) );
    ullNeed = ( uint64_t ) xH.ulImageSize + xH.ulBssSize + xH.ulStackSize + ( ( xH.ulImageSize + 15u ) & ~15u );

    if( xH.ulMagic != HADES_APP_MAGIC )
    {
        prvLoadError( 0, "bad magic 0x%08lx (an app image starts with 0x%08lx, \"HAPP\")", xH.ulMagic, ( uint32_t ) HADES_APP_MAGIC );
    }
    else if( xH.usAbi != HADES_APP_ABI )
    {
        prvLoadError( 0, "ABI version %u (this shell runs ABI version %u)", ( unsigned ) xH.usAbi, ( unsigned ) HADES_APP_ABI );
    }
    else if( xH.usHeaderSize != HADES_APP_HEADER_SIZE )
    {
        prvLoadError( 0, "header size %u (%u expected)", ( unsigned ) xH.usHeaderSize, ( unsigned ) HADES_APP_HEADER_SIZE );
    }
    else if( xH.ulImageSize != ulBytes )
    {
        prvLoadError( 0, "the header says %lu bytes, the file holds %lu", xH.ulImageSize, ulBytes );
    }
    else if( ( xH.ulFlags & ~ulKnown ) != 0u )
    {
        prvLoadError( 0, "unknown flags 0x%08lx", xH.ulFlags & ~ulKnown );
    }
    else if( !prvNameValid( xH.acName ) )
    {
        prvLoadError( 0, "bad name (1 to 15 letters, digits, '_' or '-', then NULs)" );
    }
    else if( ( ( xH.ulImageSize | xH.ulBssSize ) & 3u ) != 0u )
    {
        prvLoadError( 0, "image and bss sizes must be multiples of 4" );
    }
    else if( ( xH.ulStackSize < HADES_APP_STACK_MIN ) || ( ( xH.ulStackSize & 15u ) != 0u ) )
    {
        prvLoadError( 0, "stack of %lu bytes (at least %lu, a multiple of 16)", xH.ulStackSize, ( uint32_t ) HADES_APP_STACK_MIN );
    }
    else if( ( xH.ulEntry < HADES_APP_SLOT_BASE + HADES_APP_HEADER_SIZE ) || ( xH.ulEntry >= HADES_APP_SLOT_BASE + xH.ulImageSize ) ||
             ( ( xH.ulEntry & 3u ) != 0u ) )
    {
        prvLoadError( 0, "entry 0x%08lx is not a word of the image after its header (0x%08lx-0x%08lx)", xH.ulEntry,
                      ( uint32_t ) ( HADES_APP_SLOT_BASE + HADES_APP_HEADER_SIZE ), HADES_APP_SLOT_BASE + xH.ulImageSize - 1u );
    }
    else if( ullNeed > HADES_APP_SLOT_SIZE )
    {
        prvLoadError( 0, "%s needs %llu bytes of the slot (image %lu, bss %lu, stack %lu, saved copy %lu); the slot has %lu",
                      xH.acName, ullNeed, xH.ulImageSize, xH.ulBssSize, xH.ulStackSize, ( xH.ulImageSize + 15u ) & ~15u,
                      ( uint32_t ) HADES_APP_SLOT_SIZE );
    }
    else if( ( xLoad.ucStart != 0u ) && ( xLoad.ulStart != xH.ulEntry ) )
    {
        prvLoadError( 0, "the start address record says 0x%08lx, the entry is 0x%08lx", xLoad.ulStart, xH.ulEntry );
    }
    else if( ( ulCrc = prvCrc32( HADES_APP_SLOT_BASE, xH.ulImageSize ) ) != xH.ulCrc32 )
    {
        prvLoadError( 0, "CRC32 mismatch: the image has 0x%08lx, its header says 0x%08lx", ulCrc, xH.ulCrc32 );
    }
    else
    {
        *pxHeader = xH;
        return 1;
    }

    return 0;
}

BaseType_t loader_cmd_load( char * pcOut, size_t xOutLen, const char * pcCommand )
{
    enum { LOAD_END, LOAD_CANCEL, LOAD_IDLE } eHow;
    int iStarted = 0, iRead = 0, iReason = 0;
    size_t xReason = 0;
    char cLast = '\0';
    HadesAppHeader_t xH;
    BaseType_t xNameLen = 0, xMoreLen = 0;
    const char * const pcName = FreeRTOS_CLIGetParameter( pcCommand, 1, &xNameLen );

    if( FreeRTOS_CLIGetParameter( pcCommand, 2, &xMoreLen ) != NULL )
    {
        shell_snprintf( pcOut, xOutLen, "usage: load [name]\n" );
        return pdFALSE;
    }

    /* From here on no app is loaded; nothing of an older image may pass for part of the new
     * one. */
    ulLoaded = 0u;
    memset( ( void * ) HADES_APP_SLOT_BASE, 0, HADES_APP_SLOT_SIZE );
    memset( &xLoad, 0, sizeof( xLoad ) );
    xLoad.ulNext = HADES_APP_SLOT_BASE;
    xLoad.ulNextDot = LOADER_DOT_BYTES;
    acError[ 0 ] = '\0';

    if( pcName == NULL )
    {
        shell_puts( "load: waiting for an Intel HEX file (Ctrl-C cancels)\n" );
    }
    else
    {
        /* The name, between two DC4, tells the console bridge which file to send. */
        shell_printf( "load: waiting for %c%.*s%c (Ctrl-C cancels)\n", ( int ) HADES_CON_NAME, ( int ) xNameLen,
                      pcName, ( int ) HADES_CON_NAME );
    }

    hal_putc( ( char ) HADES_CON_FILE );

    /* The file, one byte at a time, without echo and without line editing. Before its first
     * character there is no time limit. */
    for( ; ; )
    {
        const int c = shell_rx_byte( iStarted ? ( TickType_t ) LOADER_IDLE_TICKS : portMAX_DELAY );

        if( c < 0 )
        {
            eHow = LOAD_IDLE;
            break;
        }

        iRead = 1;
        cLast = ( char ) c;

        if( c == LOADER_CTRL_C )
        {
            if( iReason )
            {
                acError[ 0 ] = '\0';   /* a cancel, not a reason cut short */
            }

            eHow = LOAD_CANCEL;
            break;
        }

        if( ( c == '\r' ) || ( c == '\n' ) )
        {
            if( iReason )
            {
                /* The end of the sender's reason; answered, as every line. */
                prvLoadError( 0, "the sender has no file" );   /* if the reason is empty */
                hal_putc( ( char ) HADES_CON_NAK );
                eHow = LOAD_END;
                break;
            }

            if( ( xLoad.xLen != 0u ) && ( prvLoadLine() != 0 ) )
            {
                eHow = LOAD_END;
                break;
            }

            xLoad.xLen = 0;   /* an empty line, or the LF of CR LF, is ignored */
            continue;
        }

        if( iReason )
        {
            if( ( xReason + 1u < sizeof( acError ) ) && ( c >= 0x20 ) && ( c <= 0x7E ) )
            {
                acError[ xReason++ ] = ( char ) c;
                acError[ xReason ] = '\0';
            }

            continue;
        }

        if( !iStarted && ( c == '!' ) )
        {
            /* Instead of a file, the sender says why it has none: the rest of the line. */
            iStarted = 1;
            iReason = 1;
            continue;
        }

        iStarted = 1;
        prvLoadChar( ( char ) c );
    }

    /* Back to the command line: a LF that follows the CR of the last line is the second half
     * of that line end (as for a command line ended with CR LF). */
    if( iRead )
    {
        shell_set_previous( cLast );
    }

    prvStartLine( pcOut, xOutLen );

    if( ( eHow == LOAD_CANCEL ) && ( acError[ 0 ] == '\0' ) )
    {
        prvAppend( pcOut, xOutLen, "load cancelled\n" );
    }
    else if( eHow == LOAD_IDLE )
    {
        prvLoadError( 1, "no input for %d ticks (the file stopped)", LOADER_IDLE_TICKS );
        prvAppend( pcOut, xOutLen, "load failed: %s\n", acError );
    }
    else if( ( acError[ 0 ] != '\0' ) || !prvCheckImage( &xH ) )
    {
        /* Also a Ctrl-C after a rejected line (a file that is not Intel HEX may hold the
         * byte 0x03): the first error is the more useful answer. */
        prvAppend( pcOut, xOutLen, "load failed: %s\n", acError );
    }
    else
    {
        /* The saved copy at the top of the slot, from which every run restores the image. */
        xApp = xH;
        memcpy( ( void * ) prvCopyBase( xApp.ulImageSize ), ( const void * ) HADES_APP_SLOT_BASE, xApp.ulImageSize );
        prvFenceI();
        ulLoaded = 1u;
        prvAppend( pcOut, xOutLen, "loaded %s: %lu bytes at 0x%08lx, entry 0x%08lx, CRC32 0x%08lx\n", xApp.acName,
                   xApp.ulImageSize, ( uint32_t ) HADES_APP_SLOT_BASE, xApp.ulEntry, xApp.ulCrc32 );
    }

    return pdFALSE;
}

/* ----------------------------------------------------------------------- API -- */

static void prvApiPutc( char c )
{
    shell_write( &c, 1 );
}

static void prvApiWrite( const char * pcText, size_t xLength )
{
    const volatile char * const pcByte = pcText;

    /* Every byte is read once here, with the scheduler running: a bad pointer then faults
     * here, where the exception is contained, and not in shell_write(), which sends each
     * line with the scheduler suspended. (shell_puts() reads the text first as well.) */
    for( size_t i = 0; i < xLength; i++ )
    {
        ( void ) pcByte[ i ];
    }

    shell_write( pcText, xLength );
}

static void prvAppEnd( uint32_t ulWhy ) __attribute__( ( noreturn ) );

static int prvApiGetc( int32_t lTimeoutMs )
{
    int c = shell_rx_byte( 0 );

    if( ( c < 0 ) && ( lTimeoutMs != 0 ) )
    {
        hal_putc( ( char ) HADES_CON_INPUT );   /* DC1: the console bridge may type now */
        c = shell_rx_byte( ( lTimeoutMs < 0 ) ? portMAX_DELAY : ( TickType_t ) lTimeoutMs );
    }

    if( c == LOADER_CTRL_C )
    {
        /* Not expected: run takes a Ctrl-C that was queued before the app started, and the
         * receive interrupt every later one. Should one arrive here, it stops the app all
         * the same. */
        prvAppEnd( LOADER_END_CTRLC );
    }

    return c;
}

/* The table passed to every app (hades_app.h). ulCpu is filled in by run. */
static HadesApi_t xApi =
{
    .ulAbi           = HADES_APP_ABI,
    .ulSize          = sizeof( HadesApi_t ),
    .ulCpu           = 0,
    .ulTickHz        = configTICK_RATE_HZ,
    .ulCyclesPerTick = FRTOS_TICK_CYCLES,
    .pxPutc          = prvApiPutc,
    .pxPuts          = shell_puts,
    .pxWrite         = prvApiWrite,
    .pxPrintf        = shell_printf,
    .pxSnprintf      = shell_snprintf,
    .pxGetc          = prvApiGetc,
    .pxDelayMs       = vTaskDelay,          /* one tick per millisecond */
    .pxTicks         = xTaskGetTickCount,
    .pxExit          = loader_app_exit
};

/* ------------------------------------------------------------------ app task -- */

/* Every ending of the app task wakes the console task, which deletes the app task (a task
 * that deleted itself would be freed later, by the idle task, and its static TCB could not
 * be used again by a run typed right after). */
static void prvAppEnd( uint32_t ulWhy )
{
    ( void ) xTaskNotify( xConsoleTask, ulWhy, eSetBits );

    for( ; ; )
    {
        vTaskSuspend( NULL );
    }
}

void loader_app_exit( int iCode )
{
    iExitCode = iCode;
    prvAppEnd( LOADER_END_EXIT );
}

static void prvAppTask( void * pvParameters )
{
    const HadesAppEntry_t pxEntry = ( HadesAppEntry_t ) ( uintptr_t ) xApp.ulEntry;

    ( void ) pvParameters;
    loader_app_exit( pxEntry( &xApi, iAppArgc, ppcAppArgv ) );
}

/* After a contained exception or stack overflow the app task resumes here, with interrupts
 * disabled, and continues at loader_app_faulted() on the top of its stack. Neither the app's
 * sp nor its gp is trusted: gp is set to the shell's value again (without relaxation, as in
 * start.S), sp to the top of the app's stack. */
__asm__ (
    "    .pushsection .text.loader_trampoline, \"ax\", @progbits\n"
    "    .globl  loader_trampoline\n"
    "    .type   loader_trampoline, @function\n"
    "    .p2align 2\n"
    "loader_trampoline:\n"
    "    .option push\n"
    "    .option norelax\n"
    "    lui     gp, %hi(__global_pointer$)\n"
    "    addi    gp, gp, %lo(__global_pointer$)\n"
    "    lui     sp, %hi(ulLoaderStackTop)\n"
    "    lw      sp, %lo(ulLoaderStackTop)(sp)\n"
    "    .option pop\n"
    "    j       loader_app_faulted\n"
    "    .size   loader_trampoline, . - loader_trampoline\n"
    "    .popsection\n" );

/* The four words at the bottom of the app task's stack in this run, which FreeRTOS checks
 * for an overflow. */
static uint32_t * prvStackCheck( void )
{
    return ( uint32_t * ) ( uintptr_t ) ( ulLoaderStackTop - xApp.ulStackSize );
}

/* 1 if those words have changed: the app's stack has overflowed (or the app wrote there). */
static int prvStackLost( void )
{
    const uint32_t * const pulCheck = prvStackCheck();

    for( int i = 0; i < 4; i++ )
    {
        if( pulCheck[ i ] != LOADER_STACK_CHECK )
        {
            return 1;
        }
    }

    return 0;
}

void loader_app_faulted( void )
{
    uint32_t * const pulCheck = prvStackCheck();

    /* FreeRTOS checks these words whenever it switches away from the task: after an
     * overflow they are lost, and the switch that the notification below causes would
     * report the overflow again. An overflow before an exception is part of the report.
     * Interrupts are still disabled, so no switch comes first; the notification's critical
     * section enables them. */
    if( prvStackLost() )
    {
        xFault.ulOverflow = 1u;
    }

    for( int i = 0; i < 4; i++ )
    {
        pulCheck[ i ] = LOADER_STACK_CHECK;
    }

    prvAppEnd( LOADER_END_FAULT );
}

/* The app task's saved context, if a fault of xTask can be contained: xTask is the app task,
 * no fault has been recorded in this run (a fault in the trampoline is not contained), and
 * the context lies in the app slot (an exception in an interrupt handler would have saved it
 * on the interrupt stack). NULL otherwise. */
static uint32_t * prvAppFrame( TaskHandle_t xTask )
{
    uint32_t * pulFrame;

    if( ( xAppTask == NULL ) || ( xTask != xAppTask ) || ( xFault.ulKind != FAULT_NONE ) )
    {
        return NULL;
    }

    pulFrame = *( uint32_t ** ) xTask;   /* pxTopOfStack, the first member of the TCB */

    if( ( ( uintptr_t ) pulFrame < HADES_APP_SLOT_BASE ) ||
        ( ( uintptr_t ) pulFrame + LOADER_FRAME_WORDS * 4u > HADES_APP_SLOT_END ) )
    {
        return NULL;
    }

    return pulFrame;
}

/* The task resumes in loader_trampoline, in machine mode, with interrupts disabled. (Enabled,
 * an interrupt could switch tasks before the trampoline has moved sp and restored the
 * stack's check words, and FreeRTOS would report the overflow a second time.) */
static void prvRedirect( uint32_t * pulFrame )
{
    pulFrame[ LOADER_FRAME_PC ] = ( uint32_t ) ( uintptr_t ) loader_trampoline;
    pulFrame[ LOADER_FRAME_MSTATUS ] = ( pulFrame[ LOADER_FRAME_MSTATUS ] & ~LOADER_MSTATUS_MPIE ) | LOADER_MSTATUS_MPP_M;
}

/* Called by the exception handler (commands.c) on the interrupt stack, for every exception
 * other than ECALL and the CPU probe's; ulPc is mepc. Returns 1 if the exception is
 * contained. Besides the conditions of prvAppFrame(), the scheduler must be running (an
 * exception between vTaskSuspendAll() and xTaskResumeAll() is not contained) and no critical
 * section may be open in the app task: in both cases the kernel's data may be half updated. */
int loader_exception( uint32_t ulCause, uint32_t ulPc )
{
    uint32_t * const pulFrame = prvAppFrame( xTaskGetCurrentTaskHandle() );
    uint32_t ulTval;

    if( ( pulFrame == NULL ) || ( xTaskGetSchedulerState() != taskSCHEDULER_RUNNING ) ||
        ( pulFrame[ LOADER_FRAME_NESTING ] != 0u ) )
    {
        return 0;
    }

    __asm volatile ( "csrr %0, mtval" : "=r" ( ulTval ) );
    xFault.ulKind = FAULT_EXCEPTION;
    xFault.ulCause = ulCause;
    xFault.ulPc = ulPc;
    xFault.ulTval = ulTval;
    xFault.ulRa = pulFrame[ LOADER_FRAME_RA ];
    prvRedirect( pulFrame );
    return 1;
}

/* Called by vTaskSwitchContext() when the task it switches away from has overflowed its stack
 * (configCHECK_FOR_STACK_OVERFLOW 2), inside the trap handler. Replaces the weak one of
 * common/hades_hal.c. A task switch happens only at a consistent point of the kernel, so the
 * app task can also be stopped when it yielded inside a critical section (in
 * xTaskResumeAll(), for instance): its nesting count is set to 0 with the redirection. The
 * switch may also be the one that the end of the app causes (it returned, or Ctrl-C stopped
 * it, after an overflow without a switch in between): the overflow is then reported instead
 * of that ending. */
void vApplicationStackOverflowHook( TaskHandle_t xTask, char * pcTaskName )
{
    uint32_t * const pulFrame = prvAppFrame( xTask );

    if( pulFrame != NULL )
    {
        xFault.ulKind = FAULT_STACK;
        xFault.ulOverflow = 1u;
        pulFrame[ LOADER_FRAME_NESTING ] = 0u;
        prvRedirect( pulFrame );
        return;
    }

    hal_fail( "stack overflow", pcTaskName, ( uint32_t ) ( uintptr_t ) xTask, 0 );
}

/* Called by the receive interrupt (console.c) for every byte. */
BaseType_t loader_rx_from_isr( uint8_t ucByte, BaseType_t * pxWoken )
{
    if( ( ucByte != LOADER_CTRL_C ) || ( ulRunning == 0u ) )
    {
        return pdFALSE;
    }

    ( void ) xTaskNotifyFromISR( xConsoleTask, LOADER_END_CTRLC, eSetBits, pxWoken );
    return pdTRUE;
}

/* ----------------------------------------------------------------------- run -- */

static const char * prvCause( uint32_t ulCause )
{
    static const char * const apcCause[ 8 ] =
    {
        "instruction address misaligned", "instruction access fault", "illegal instruction", "breakpoint",
        "load address misaligned",        "load access fault",        "store address misaligned", "store access fault"
    };

    return ( ulCause < 8u ) ? apcCause[ ulCause ] : "exception";
}

static int prvInSlot( uint32_t ulAddress )
{
    return ( ulAddress >= HADES_APP_SLOT_BASE ) && ( ulAddress < HADES_APP_SLOT_END );
}

/* The report of a run that has ended (SPEC.md, section 7.3). A stack overflow is reported
 * whatever bits arrived: FreeRTOS may find it only at the switch that the end of the app
 * causes, after the EXIT or CTRLC bit has been sent. */
static void prvReport( char * pcOut, size_t xOutLen, uint32_t ulEnd, uint64_t ullCycles )
{
    const int iException = ( ( ulEnd & LOADER_END_FAULT ) != 0u ) && ( xFault.ulKind == FAULT_EXCEPTION );

    prvStartLine( pcOut, xOutLen );

    if( !iException && ( xFault.ulOverflow != 0u ) )
    {
        prvAppend( pcOut, xOutLen, "app: %s stopped by a stack overflow after %llu cycles (its stack is %lu bytes)\n",
                   xApp.acName, ullCycles, xApp.ulStackSize );
    }
    else if( iException )
    {
        prvAppend( pcOut, xOutLen, "app: %s stopped by an exception after %llu cycles: %s (mcause %lu) at 0x%08lx",
                   xApp.acName, ullCycles, prvCause( xFault.ulCause ), xFault.ulCause, xFault.ulPc );

        if( prvInSlot( xFault.ulPc ) )
        {
            prvAppend( pcOut, xOutLen, " in %s", xApp.acName );
        }
        else if( ( xFault.ulPc >= ( uint32_t ) ( uintptr_t ) __ram_start ) && ( xFault.ulPc < ( uint32_t ) ( uintptr_t ) __ram_end ) )
        {
            prvAppend( pcOut, xOutLen, " in the shell" );
        }

        if( xFault.ulTval != 0u )
        {
            prvAppend( pcOut, xOutLen, ", mtval 0x%08lx", xFault.ulTval );
        }

        /* A fetch from a bad address (a call through a bad pointer, a bad return address):
         * mepc is the target, ra may name the call. */
        if( ( xFault.ulCause <= 1u ) && !prvInSlot( xFault.ulPc ) && prvInSlot( xFault.ulRa ) )
        {
            prvAppend( pcOut, xOutLen, ", ra 0x%08lx in %s", xFault.ulRa, xApp.acName );
        }

        if( xFault.ulOverflow != 0u )
        {
            prvAppend( pcOut, xOutLen, ", after a stack overflow (its stack is %lu bytes)", xApp.ulStackSize );
        }

        prvAppend( pcOut, xOutLen, "\n" );
    }
    else if( ( ulEnd & LOADER_END_EXIT ) != 0u )
    {
        prvAppend( pcOut, xOutLen, "app: %s exited with code %d after %llu cycles\n", xApp.acName, iExitCode, ullCycles );
    }
    else
    {
        prvAppend( pcOut, xOutLen, "app: %s stopped by Ctrl-C after %llu cycles\n", xApp.acName, ullCycles );
    }
}

BaseType_t loader_cmd_run( char * pcOut, size_t xOutLen, const char * pcCommand )
{
    static char acArgs[ HADES_APP_NAME_SIZE + SHELL_LINE_MAX + 1 ];   /* argv's strings */
    static char * apcArgv[ 1 + LOADER_MAX_ARGS + 1 ];
    const char * p = pcCommand;
    uint32_t ulWords = 0, ulCopy, ulCrc, ulEnd = 0;
    uint64_t ullStart, ullCycles;
    char * pcArg;

    if( ulLoaded == 0u )
    {
        shell_snprintf( pcOut, xOutLen, "error: no app loaded (try 'load hello')\n" );
        return pdFALSE;
    }

    /* The words after the command word, separated by blanks. */
    while( ( *p != '\0' ) && ( *p != ' ' ) )
    {
        p++;
    }

    for( const char * q = p; *q != '\0'; )
    {
        while( *q == ' ' )
        {
            q++;
        }

        if( *q != '\0' )
        {
            ulWords++;

            while( ( *q != '\0' ) && ( *q != ' ' ) )
            {
                q++;
            }
        }
    }

    if( ulWords > LOADER_MAX_ARGS )
    {
        shell_snprintf( pcOut, xOutLen, "error: at most %d arguments\n", LOADER_MAX_ARGS );
        return pdFALSE;
    }

    /* What the image needs and the CPU lacks (the start-up probe). */
    {
        const int iNoM = ( ( xApp.ulFlags & HADES_APP_NEEDS_M ) != 0u ) && !xShellCpu.ucM;
        const int iNoZba = ( ( xApp.ulFlags & HADES_APP_NEEDS_ZBA ) != 0u ) && !xShellCpu.ucZba;

        if( iNoM || iNoZba )
        {
            shell_snprintf( pcOut, xOutLen, "error: %s was built for %s, but this CPU has no %s\n", xApp.acName,
                            prvIsa( xApp.ulFlags ), iNoM ? ( iNoZba ? "M and no Zba" : "M" ) : "Zba" );
            return pdFALSE;
        }
    }

    /* The saved copy, as it was loaded: restore the image from it. */
    ulCopy = prvCopyBase( xApp.ulImageSize );
    ulCrc = prvCrc32( ulCopy, xApp.ulImageSize );

    if( ulCrc != xApp.ulCrc32 )
    {
        ulLoaded = 0u;
        shell_snprintf( pcOut, xOutLen, "error: the saved copy of %s is damaged (CRC32 0x%08lx instead of 0x%08lx); load it again\n",
                        xApp.acName, ulCrc, xApp.ulCrc32 );
        return pdFALSE;
    }

    memcpy( ( void * ) HADES_APP_SLOT_BASE, ( const void * ) ulCopy, xApp.ulImageSize );
    prvFenceI();

    /* argv: the name, the words, NULL; writable copies in the shell's memory. */
    pcArg = acArgs;
    apcArgv[ 0 ] = pcArg;
    strcpy( pcArg, xApp.acName );
    pcArg += strlen( pcArg ) + 1u;
    iAppArgc = 1;

    while( *p != '\0' )
    {
        while( *p == ' ' )
        {
            p++;
        }

        if( *p != '\0' )
        {
            apcArgv[ iAppArgc++ ] = pcArg;

            while( ( *p != '\0' ) && ( *p != ' ' ) )
            {
                *pcArg++ = *p++;
            }

            *pcArg++ = '\0';
        }
    }

    apcArgv[ iAppArgc ] = NULL;
    ppcAppArgv = apcArgv;

    /* Start. From here on the receive interrupt takes Ctrl-C. */
    xConsoleTask = xTaskGetCurrentTaskHandle();
    ( void ) xTaskNotifyWait( ~0u, ~0u, NULL, 0 );   /* no earlier notification counts */
    memset( &xFault, 0, sizeof( xFault ) );
    iExitCode = 0;
    ulLoaderStackTop = ulCopy;
    xApi.ulCpu = ( xShellCpu.ucM ? HADES_APP_CPU_M : 0u ) | ( xShellCpu.ucZba ? HADES_APP_CPU_ZBA : 0u ) |
                 ( xShellCpu.ucZicntr ? HADES_APP_CPU_ZICNTR : 0u );
    ullStart = shell_run_time();
    ulRunning = 1u;

    /* A Ctrl-C that arrived before this point (typed right after the Enter of 'run', for
     * instance) is in the receive queue, where an app that reads no input would never see
     * it: it stops the app all the same. Every later one is taken by the receive interrupt. */
    if( shell_rx_holds( LOADER_CTRL_C ) )
    {
        ( void ) xTaskNotify( xConsoleTask, LOADER_END_CTRLC, eSetBits );
    }

    xAppTask = xTaskCreateStatic( prvAppTask, "app", xApp.ulStackSize / sizeof( StackType_t ), NULL, LOADER_APP_PRIORITY,
                                  ( StackType_t * ) ( uintptr_t ) ( ulCopy - xApp.ulStackSize ), &xAppTaskBuffer );
    configASSERT( xAppTask != NULL );

    /* The app task runs (it has the CPU whenever the console task and blink wait) until it
     * ends: EXIT, FAULT or CTRLC. */
    while( ( ulEnd & LOADER_END_ANY ) == 0u )
    {
        uint32_t ulBits = 0;

        ( void ) xTaskNotifyWait( 0, ~0u, &ulBits, portMAX_DELAY );
        ulEnd |= ulBits;
    }

    ullCycles = shell_run_time() - ullStart;
    ulRunning = 0u;

    if( prvStackLost() )   /* (the switch away from the app task has checked this already) */
    {
        xFault.ulOverflow = 1u;
    }

    /* The app task is not running (this task is), so it is removed at once, wherever it
     * was: its TCB and stack can be used again by the next run. */
    vTaskDelete( xAppTask );
    xAppTask = NULL;
    shell_rx_discard();   /* input the app did not read */
    prvReport( pcOut, xOutLen, ulEnd, ullCycles );
    return pdFALSE;
}

/* ----------------------------------------------------------------------- app -- */

BaseType_t loader_cmd_app( char * pcOut, size_t xOutLen, const char * pcCommand )
{
    ( void ) pcCommand;

    if( ulLoaded == 0u )
    {
        shell_snprintf( pcOut, xOutLen, "no app loaded\n" );
    }
    else
    {
        const uint32_t ulCopy = ( xApp.ulImageSize + 15u ) & ~15u;

        shell_snprintf( pcOut, xOutLen,
                        "name:      %s (ABI %u)\n"
                        "image:     %lu bytes at 0x%08lx, entry 0x%08lx, CRC32 0x%08lx\n"
                        "isa:       %s\n"
                        "memory:    image %lu + bss %lu + stack %lu + saved copy %lu = %lu of %lu bytes\n",
                        xApp.acName, ( unsigned ) xApp.usAbi,
                        xApp.ulImageSize, ( uint32_t ) HADES_APP_SLOT_BASE, xApp.ulEntry, xApp.ulCrc32,
                        prvIsa( xApp.ulFlags ),
                        xApp.ulImageSize, xApp.ulBssSize, xApp.ulStackSize, ulCopy,
                        xApp.ulImageSize + xApp.ulBssSize + xApp.ulStackSize + ulCopy, ( uint32_t ) HADES_APP_SLOT_SIZE );
    }

    return pdFALSE;
}

/* ---------------------------------------------------------------------- init -- */

void loader_init( void )
{
    /* The shell must end where the slot begins (linked for 128 KiB: APP_LINK_KB). */
    if( ( uint32_t ) ( uintptr_t ) __ram_end != HADES_APP_SLOT_BASE )
    {
        hal_fail( "loader: the shell's RAM does not end at the app slot (__ram_end, slot)", NULL,
                  ( uint32_t ) ( uintptr_t ) __ram_end, HADES_APP_SLOT_BASE );
    }
}
