/* hades_app.h -- the interface between the HaDes-V+ shell's app loader and the apps it runs
 * (test/freertos/loader/SPEC.md), ABI version 1: the app slot, the image header, the API table
 * and the helpers that apps call. */
#ifndef HADES_APP_H
#define HADES_APP_H

#include <stddef.h>
#include <stdint.h>

/* ---------------------------------------------------------------------- the app slot -- */
#define HADES_APP_SLOT_BASE        0x00060000u
#define HADES_APP_SLOT_SIZE        0x00020000u   /* 128 KiB */
#define HADES_APP_SLOT_END         ( HADES_APP_SLOT_BASE + HADES_APP_SLOT_SIZE )

/* -------------------------------------------------------------------- the image header -- */
#define HADES_APP_MAGIC            0x50504148u   /* the bytes 'H' 'A' 'P' 'P' */
#define HADES_APP_ABI              1u
#define HADES_APP_HEADER_SIZE      64u
#define HADES_APP_NAME_SIZE        16u           /* at most 15 characters and a NUL */
#define HADES_APP_STACK_MIN        1024u
#define HADES_APP_STACK_DEFAULT    4096u
#define HADES_APP_NEEDS_M          ( 1u << 0 )   /* ulFlags: compiled for M */
#define HADES_APP_NEEDS_ZBA        ( 1u << 1 )   /* ulFlags: compiled for Zba */
#define HADES_APP_NEEDS_ZBB        ( 1u << 2 )   /* ulFlags: compiled for Zbb */
#define HADES_APP_NEEDS_ZBS        ( 1u << 3 )   /* ulFlags: compiled for Zbs */

typedef struct
{
    uint32_t ulMagic;                       /*  0: HADES_APP_MAGIC */
    uint16_t usAbi;                         /*  4: HADES_APP_ABI */
    uint16_t usHeaderSize;                  /*  6: HADES_APP_HEADER_SIZE */
    uint32_t ulFlags;                       /*  8: HADES_APP_NEEDS_* */
    uint32_t ulEntry;                       /* 12: the address of _start */
    uint32_t ulImageSize;                   /* 16: bytes loaded, from the slot base */
    uint32_t ulBssSize;                     /* 20: bytes after the image, zeroed by crt0.S */
    uint32_t ulStackSize;                   /* 24: bytes of stack */
    uint32_t ulCrc32;                       /* 28: CRC-32 of the image, this field read as 0 */
    char acName[ HADES_APP_NAME_SIZE ];     /* 32: NUL-terminated and NUL-padded */
    uint32_t aulReserved[ 4 ];              /* 48: 0 */
} HadesAppHeader_t;

_Static_assert( sizeof( HadesAppHeader_t ) == HADES_APP_HEADER_SIZE, "HadesAppHeader_t" );

/* ----------------------------------------------------------------------- the API table -- */
#define HADES_APP_CPU_M            ( 1u << 0 )   /* ulCpu: the CPU executes M */
#define HADES_APP_CPU_ZBA          ( 1u << 1 )   /*        ... Zba */
#define HADES_APP_CPU_ZICNTR       ( 1u << 2 )   /*        ... reads cycle, time, instret */
#define HADES_APP_CPU_ZBB          ( 1u << 3 )   /*        ... Zbb */
#define HADES_APP_CPU_ZBS          ( 1u << 4 )   /*        ... Zbs */
#define HADES_APP_CPU_ZICOND       ( 1u << 5 )   /*        ... Zicond (czero.eqz, czero.nez) */

typedef struct HadesApi
{
    uint32_t ulAbi;                 /* HADES_APP_ABI */
    uint32_t ulSize;                /* sizeof( HadesApi_t ) in the shell */
    uint32_t ulCpu;                 /* HADES_APP_CPU_* */
    uint32_t ulTickHz;              /* RTOS ticks per second (1000) */
    uint32_t ulCyclesPerTick;       /* clock cycles per tick (TICK=) */
    void ( * pxPutc )( char c );
    void ( * pxPuts )( const char * pcText );
    void ( * pxWrite )( const char * pcText, size_t xLength );
    int ( * pxPrintf )( const char * pcFormat, ... ) __attribute__( ( format( printf, 1, 2 ) ) );
    int ( * pxSnprintf )( char * pcBuffer, size_t xSize, const char * pcFormat, ... )
        __attribute__( ( format( printf, 3, 4 ) ) );
    int ( * pxGetc )( int32_t lTimeoutMs );
    void ( * pxDelayMs )( uint32_t ulMs );
    uint32_t ( * pxTicks )( void );
    void ( * pxExit )( int iCode ) __attribute__( ( noreturn ) );
} HadesApi_t;

/* The entry point (_start of crt0.S), called on the app task's stack. Returning from it ends
 * the app, with the returned value as its exit code. */
typedef int ( * HadesAppEntry_t )( const HadesApi_t * pxApi, int iArgc, char ** ppcArgv );

/* ------------------------------------------------- console control bytes (SPEC.md 5.2) -- */
/* Sent by the shell to pace the simulator's console bridge; a terminal does not show them.
 * An app must not send them. */
#define HADES_CON_ACK              0x06u         /* a record line was accepted */
#define HADES_CON_INPUT            0x11u         /* DC1: waiting for input */
#define HADES_CON_FILE             0x12u         /* DC2: waiting for a file */
#define HADES_CON_NAME             0x14u         /* DC4: around the name of the file wanted */
#define HADES_CON_NAK              0x15u         /* a record line was rejected */

/* ------------------------------------------------------------------------- for apps -- */
/* The functions of the shell that an app calls, through the table that crt0.S receives
 * (SPEC.md, section 6.2). Call them only from the app's own task (an app has no other). The
 * devices (LEDs, switches, buttons, 7-segment display, VGA) are reached directly, with the
 * addresses of peripherals.h (std/include/, on the SDK's include path); the shell's blink
 * task rewrites the whole LED register every 500 ticks. */
extern const HadesApi_t * hades_api;            /* set by crt0.S before main() runs */

/* Output. Every '\n' is sent as "\r\n", and each line is sent as one unit, so that it never
 * interleaves with the output of other tasks. app_puts() adds no newline; app_write() sends
 * n characters. */
#define app_putc( c )              ( hades_api->pxPutc( c ) )
#define app_puts( s )              ( hades_api->pxPuts( s ) )
#define app_write( s, n )          ( hades_api->pxWrite( ( s ), ( n ) ) )

/* The shell's formatter: %d %i %u %x %X %s %c %%, the flags '-' and '0', a width (digits or
 * '*'), a precision for %s, the length modifiers l and z (32 bits) and ll (64 bits); no
 * floating point. app_printf() prints at most 159 characters per call (the rest is cut);
 * app_snprintf( buf, n, fmt, ... ) stores at most n - 1 and a NUL. Both return the number of
 * characters printed or stored. */
#define app_printf( ... )          ( hades_api->pxPrintf( __VA_ARGS__ ) )
#define app_snprintf( ... )        ( hades_api->pxSnprintf( __VA_ARGS__ ) )

/* Input. The next byte typed (0 to 255), or -1 if none arrives within ms milliseconds; ms < 0
 * waits for ever, 0 does not wait. Bytes arrive as typed: no echo, no line editing (CR, LF,
 * Backspace and DEL arrive as such). Ctrl-C never arrives: it stops the app. */
#define app_getc( ms )             ( hades_api->pxGetc( ms ) )

/* Time. app_delay_ms() blocks for ms milliseconds (one RTOS tick each; 0 yields);
 * app_ticks() is the tick count since the scheduler started (ticks of 1 ms at the nominal
 * 1 kHz; one tick is ulCyclesPerTick clock cycles). */
#define app_delay_ms( ms )         ( hades_api->pxDelayMs( ms ) )
#define app_ticks()                ( hades_api->pxTicks() )

/* Ends the app with this exit code, as returning it from main() does; does not return. */
#define app_exit( code )           ( hades_api->pxExit( code ) )

/* What the CPU executes: HADES_APP_CPU_M, _ZBA, _ZICNTR, _ZBB, _ZBS and _ZICOND. Zicond has no
 * -march of its own (std/include/zicond.h emits its instructions): an app that uses it checks
 * HADES_APP_CPU_ZICOND first. */
#define app_cpu()                  ( hades_api->ulCpu )

/* mcycle as 64 bits (high, low, high read); both CPUs implement it. */
static inline uint64_t app_cycles( void )
{
    uint32_t ulHi, ulLo, ulHi2;

    do
    {
        __asm volatile ( "csrr %0, mcycleh" : "=r" ( ulHi ) );
        __asm volatile ( "csrr %0, mcycle" : "=r" ( ulLo ) );
        __asm volatile ( "csrr %0, mcycleh" : "=r" ( ulHi2 ) );
    } while( ulHi != ulHi2 );

    return ( ( uint64_t ) ulHi << 32 ) | ulLo;
}

/* The app's free memory, after its .bss and below its stack (app.ld): there is no malloc. */
extern char __app_heap_start[], __app_heap_end[];

/* HADES_APP_STACK_SIZE( 8192 ); at file scope sets the app's stack size in bytes (default
 * HADES_APP_STACK_DEFAULT): at least HADES_APP_STACK_MIN and a multiple of 16, written as a
 * plain integer literal (it becomes an assembler symbol, which app.ld reads and checks). */
#define HADES_APP_STACK_SIZE( n )  __asm__( ".globl __app_stack_size\n\t.set __app_stack_size, " #n )

#endif /* HADES_APP_H */
