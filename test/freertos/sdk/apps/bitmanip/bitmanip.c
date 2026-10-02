/* bitmanip.c -- an app that shows the bit-manipulation extensions: built for them
 * (make freertos-app NAME=bitmanip MARCH=rv32im_zba_zbb_zbs), GCC turns ordinary C into Zbb
 * and Zbs instructions; built for rv32i (the default), the same C runs as RV32I code. Both
 * builds print the same values and pass the same checks; the cycle counts differ.
 *
 * Four sections, each on 64 words d[0..63] from a xorshift32 generator (seed 0x2545F491):
 *   zbb      what GCC emits from plain C: popcount (cpop), integer log2 (clz), trailing zeros
 *            (ctz), clamping (min, max, minu, maxu), packed 8/16-bit samples (sext.b, sext.h,
 *            zext.h), masks (andn, orn, xnor) and a hash with rotates (rori, ror; GCC also
 *            uses rol for some of the steps)
 *   bytes    what GCC 12 does not emit, written by hand when the build has Zbb (C otherwise):
 *            rev8 reads big-endian fields, orc.b finds the end of strings a word at a time
 *   zbs      a sieve of Eratosthenes in a bitmap of 4096 bits (bset, bclr, bext, binv) and
 *            flags at fixed bit numbers (bseti, bclri, bexti, binvi)
 *   zicond   branch-free select, clamp and conditional add (czero.eqz, czero.nez) through
 *            std/include/zicond.h when the build has Zbb and the CPU reports Zicond; the
 *            rv32i build computes the same in portable C
 * The expected values below were computed by model.py in this directory, which takes the
 * result of every instruction from the reference model of test/ext/ref.py.
 *
 * Output: one line per section, "bitmanip: <section> <values>: PASS (<c> cycles)", then
 * "bitmanip: <n> of <m> sections passed"; the exit code is the number of failed sections.
 * A failed section prints FAIL and the expected values. */
#include <stdint.h>
#include "hades_app.h"

#if defined( __riscv_zbb )
    #include "zicond.h"              /* czero.eqz and czero.nez, as .insn words */
    #define BM_ZBB    1
#else
    #define ZICOND_PORTABLE          /* the same functions in branch-free C */
    #include "zicond.h"
    #define BM_ZBB    0
#endif

/* python3 test/freertos/sdk/apps/bitmanip/model.py */
#define BM_POPCOUNT    0x000003fcu
#define BM_LOG2        0x00000773u
#define BM_CTZ         0x0000003eu
#define BM_CLAMP       0x5dd12d14u
#define BM_EXTEND      0x00203fccu
#define BM_MASKS       0x648904fbu
#define BM_HASH        0x200eb485u
#define BM_REV8        0xbb05f113u
#define BM_LENGTHS     0x00000066u
#define BM_PRIMES      0x00000234u
#define BM_PRIMESUM    0x0010540bu
#define BM_TOGGLED     0x00000788u
#define BM_FLAGS       0x7f6b4d42u
#define BM_SELECT      0xb23616d0u
#define BM_CZCLAMP     0x000013b0u
#define BM_ADDIF       0xe806a5c8u

#define N        64
#define BITS     4096u

static uint32_t aulD[ N ];
static uint32_t aulMap[ BITS / 32 ];
static int iRun, iFailed;

/* The aligned word at pv (an access through a char array that is not an aliasing violation;
 * GCC turns it into one lw). */
static inline uint32_t prvWord( const void * pv )
{
    uint32_t ulWord;

    __builtin_memcpy( &ulWord, __builtin_assume_aligned( pv, 4 ), sizeof( ulWord ) );
    return ulWord;
}

static void prvFill( void )
{
    uint32_t x = 0x2545F491u;

    for( int i = 0; i < N; i++ )
    {
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        aulD[ i ] = x;
    }
}

/* Prints the section's line; on a mismatch also the expected values. ulGot and ulWant are
 * the section's values; their count is n. */
static void prvReport( const char * pcSection, const char * pcValues, const uint32_t * pulGot,
                       const uint32_t * pulWant, int n, uint64_t ullCycles, const char * pcNote )
{
    int iOk = 1;

    iRun++;

    for( int i = 0; i < n; i++ )
    {
        iOk &= pulGot[ i ] == pulWant[ i ];
    }

    if( iOk )
    {
        app_printf( "bitmanip: %-6s %s: PASS (%llu cycles%s)\n", pcSection, pcValues, ullCycles, pcNote );
        return;
    }

    iFailed++;
    app_printf( "bitmanip: %-6s %s: FAIL\n", pcSection, pcValues );

    for( int i = 0; i < n; i++ )
    {
        app_printf( "bitmanip: %-6s value %d is 0x%08lx, expected 0x%08lx\n", pcSection, i, pulGot[ i ], pulWant[ i ] );
    }
}

/* ------------------------------------------------------------------------------- zbb -- */
/* Plain C. With -march=..._zbb GCC 12 emits the instructions named in the comments. The
 * functions are not inlined, so that each idiom stays visible in the disassembly. */

static uint32_t __attribute__( ( noinline ) ) prvPopcount( void )
{
    uint32_t ulSum = 0;

    for( int i = 0; i < N; i++ )
    {
        ulSum += ( uint32_t ) __builtin_popcount( aulD[ i ] );           /* cpop */
    }

    return ulSum;
}

static uint32_t __attribute__( ( noinline ) ) prvLog2( void )
{
    uint32_t ulSum = 0;

    for( int i = 0; i < N; i++ )
    {
        ulSum += 31u - ( uint32_t ) __builtin_clz( aulD[ i ] | 1u );     /* clz */
    }

    return ulSum;
}

static uint32_t __attribute__( ( noinline ) ) prvCtz( void )
{
    uint32_t ulSum = 0;

    for( int i = 0; i < N; i++ )
    {
        ulSum += ( uint32_t ) __builtin_ctz( aulD[ i ] | 0x80000000u );  /* ctz */
    }

    return ulSum;
}

static int32_t prvClampS( int32_t lX, int32_t lLo, int32_t lHi )
{
    lX = ( lX < lLo ) ? lLo : lX;                                        /* max */
    return ( lX > lHi ) ? lHi : lX;                                      /* min */
}

static uint32_t __attribute__( ( noinline ) ) prvClamp( void )
{
    uint32_t ulSum = 0;

    for( int i = 0; i < N - 1; i++ )
    {
        const uint32_t a = aulD[ i ], b = aulD[ i + 1 ];

        ulSum += ( uint32_t ) prvClampS( ( int32_t ) a, -0x01000000, 0x00FFFFFF );
        ulSum ^= ( a < b ) ? a : b;                                      /* minu */
        ulSum += ( a > b ) ? a : b;                                      /* maxu */
    }

    return ulSum;
}

/* A 16-bit sample. A function of its own: in the loop below GCC would keep 0xFFFF in a
 * register and use and instead of zext.h. */
static uint32_t __attribute__( ( noinline ) ) prvSample16( uint32_t w )
{
    return ( uint16_t ) ( w >> 3 );                                      /* zext.h */
}

static uint32_t __attribute__( ( noinline ) ) prvExtend( void )
{
    uint32_t ulSum = 0;

    for( int i = 0; i < N; i++ )
    {
        const uint32_t w = aulD[ i ];

        ulSum += ( uint32_t ) ( int32_t ) ( int8_t ) ( w >> 8 );         /* sext.b */
        ulSum += ( uint32_t ) ( int32_t ) ( int16_t ) ( w >> 12 );       /* sext.h */
        ulSum += prvSample16( w );
    }

    return ulSum;
}

static uint32_t __attribute__( ( noinline ) ) prvMasks( void )
{
    uint32_t ulSum = 0;

    for( int i = 0; i < N - 1; i++ )
    {
        const uint32_t a = aulD[ i ], b = aulD[ i + 1 ];

        ulSum += a & ~b;                                                 /* andn */
        ulSum ^= a | ~b;                                                 /* orn */
        ulSum ^= ~( a ^ ( b >> 1 ) );                                    /* xnor */
    }

    return ulSum;
}

static uint32_t __attribute__( ( noinline ) ) prvHash( void )
{
    uint32_t h = 0x811C9DC5u;

    for( int i = 0; i < N; i++ )
    {
        const uint32_t n = aulD[ i ] & 31u;

        h ^= aulD[ i ];
        h = ( ( h >> 5 ) | ( h << 27 ) ) + 0x9E3779B9u;                  /* rori */
        h = ( h >> n ) | ( h << ( ( 32u - n ) & 31u ) );                 /* ror */
    }

    return h;
}

static void prvSectionZbb( void )
{
    const uint64_t ullStart = app_cycles();
    const uint32_t aulGot[ 7 ] = { prvPopcount(), prvLog2(), prvCtz(), prvClamp(), prvExtend(), prvMasks(), prvHash() };
    const uint64_t ullCycles = app_cycles() - ullStart;
    static const uint32_t aulWant[ 7 ] = { BM_POPCOUNT, BM_LOG2, BM_CTZ, BM_CLAMP, BM_EXTEND, BM_MASKS, BM_HASH };
    char acValues[ 120 ];

    app_snprintf( acValues, sizeof( acValues ), "popcount %lu, log2 %lu, ctz %lu, mix %08lx %08lx %08lx, hash %08lx",
                  aulGot[ 0 ], aulGot[ 1 ], aulGot[ 2 ], aulGot[ 3 ], aulGot[ 4 ], aulGot[ 5 ], aulGot[ 6 ] );
    prvReport( "zbb", acValues, aulGot, aulWant, 7, ullCycles, "" );
}

/* ----------------------------------------------------------------------------- bytes -- */
/* rev8 and orc.b. GCC 12 emits neither on RV32 (__builtin_bswap32 becomes a call to
 * __bswapsi2), so the Zbb build writes them by hand. */

static inline uint32_t prvRev8( uint32_t x )
{
    #if defined( __riscv_zbb )
        __asm__ ( "rev8 %0, %1" : "=r" ( x ) : "r" ( x ) );
        return x;
    #else
        return ( x >> 24 ) | ( ( x >> 8 ) & 0x0000FF00u ) | ( ( x << 8 ) & 0x00FF0000u ) | ( x << 24 );
    #endif
}

/* 0xFF in every byte of x that is not 0, 0x00 in every byte that is */
static inline uint32_t prvOrcB( uint32_t x )
{
    #if defined( __riscv_zbb )
        __asm__ ( "orc.b %0, %1" : "=r" ( x ) : "r" ( x ) );
        return x;
    #else
        uint32_t ulOut = 0;

        for( int k = 0; k < 32; k += 8 )
        {
            ulOut |= ( ( x >> k ) & 0xFFu ) ? ( 0xFFu << k ) : 0u;
        }

        return ulOut;
    #endif
}

/* The length of the string at pcText, which is word-aligned and padded with NULs to a whole
 * word: one orc.b per word; in the word with the NUL, ctz of the inverted orc.b result finds
 * the first 0x00 byte (little-endian: the lowest). */
static uint32_t prvStrlen( const char * pcText )
{
    uint32_t ulLength = 0, ulOrc;

    while( ( ulOrc = prvOrcB( prvWord( pcText + ulLength ) ) ) == 0xFFFFFFFFu )
    {
        ulLength += 4u;
    }

    return ulLength + ( ( uint32_t ) __builtin_ctz( ~ulOrc ) >> 3 );
}

/* Eight big-endian 32-bit fields, as a network header stores them, and eight strings. */
static const uint8_t aucHeader[ 32 ] __attribute__( ( aligned( 4 ) ) ) =
{
    0x48, 0x41, 0x44, 0x45, 0x00, 0x00, 0x01, 0x00, 0xDE, 0xAD, 0xBE, 0xEF, 0x80, 0x00, 0x00, 0x01,
    0x12, 0x34, 0x56, 0x78, 0xFF, 0xFF, 0xFF, 0xFE, 0x00, 0x01, 0x00, 0x01, 0x7F, 0x80, 0x01, 0xFE
};
static const char acStrings[ 8 ][ 32 ] __attribute__( ( aligned( 4 ) ) ) =
{
    "", "a", "HaDes-V+", "bit manipulation", "rv32im_zba_zbb_zbs", "Zicond", "0123456789abcdef0123456",
    "FreeRTOS app loader, ~31 chars"
};

static void prvSectionBytes( void )
{
    const uint64_t ullStart = app_cycles();
    uint32_t aulGot[ 2 ] = { 0, 0 };
    uint64_t ullCycles;
    static const uint32_t aulWant[ 2 ] = { BM_REV8, BM_LENGTHS };
    char acValues[ 64 ];

    for( int i = 0; i < 8; i++ )
    {
        aulGot[ 0 ] = ( ( aulGot[ 0 ] << 3 ) | ( aulGot[ 0 ] >> 29 ) ) ^ prvRev8( prvWord( &aucHeader[ 4 * i ] ) );
        aulGot[ 1 ] += prvStrlen( acStrings[ i ] );
    }

    ullCycles = app_cycles() - ullStart;
    app_snprintf( acValues, sizeof( acValues ), "rev8 %08lx, string lengths %lu", aulGot[ 0 ], aulGot[ 1 ] );
    prvReport( "bytes", acValues, aulGot, aulWant, 2, ullCycles, BM_ZBB ? ", rev8 and orc.b" : ", C" );
}

/* ------------------------------------------------------------------------------- zbs -- */
/* A bitmap of BITS bits, one per number: GCC emits bset, bclr, bext and binv for these.
 * The bit number within the word is n & 31. GCC 12 emits bclr, bext and binv only when it
 * cannot see that mask (with it, bset and andn, srl and andi, bset and xor), so the empty asm
 * hides it; the shift amount is still below 32, as C requires. */
static inline uint32_t prvBit( uint32_t n )
{
    uint32_t b = n & 31u;

    __asm__ ( "" : "+r" ( b ) );
    return b;
}

static inline void prvClear( uint32_t n )
{
    aulMap[ n >> 5 ] &= ~( 1u << prvBit( n ) );                          /* bclr */
}

static inline void prvSet( uint32_t n )
{
    aulMap[ n >> 5 ] |= 1u << prvBit( n );                               /* bset */
}

static inline uint32_t prvTest( uint32_t n )
{
    return ( aulMap[ n >> 5 ] >> prvBit( n ) ) & 1u;                     /* bext */
}

static inline void prvToggle( uint32_t n )
{
    aulMap[ n >> 5 ] ^= 1u << prvBit( n );                               /* binv */
}

/* Flags at fixed bit numbers: the immediate forms. */
static uint32_t __attribute__( ( noinline ) ) prvFlags( void )
{
    uint32_t ulSum = 0;

    for( int i = 0; i < N; i++ )
    {
        uint32_t f = aulD[ i ] | ( 1u << 20 );                           /* bseti */

        f ^= 1u << 17;                                                   /* binvi (bit 7 would be xori) */
        f &= ~( 1u << 30 );                                              /* bclri */
        ulSum += f + ( ( aulD[ i ] >> 25 ) & 1u );                       /* bexti */
    }

    return ulSum;
}

static void prvSectionZbs( void )
{
    const uint64_t ullStart = app_cycles();
    uint32_t aulGot[ 4 ] = { 0, 0, 0, 0 };
    uint64_t ullCycles;
    static const uint32_t aulWant[ 4 ] = { BM_PRIMES, BM_PRIMESUM, BM_TOGGLED, BM_FLAGS };
    char acValues[ 100 ];

    /* every number a candidate, then 0, 1 and the multiples of each prime struck out */
    for( uint32_t n = 0; n < BITS; n++ )
    {
        prvSet( n );
    }

    prvClear( 0 );
    prvClear( 1 );

    for( uint32_t p = 2; p * p < BITS; p++ )
    {
        if( prvTest( p ) )
        {
            for( uint32_t n = p * p; n < BITS; n += p )
            {
                prvClear( n );
            }
        }
    }

    for( uint32_t n = 0; n < BITS; n++ )
    {
        if( prvTest( n ) )
        {
            aulGot[ 0 ]++;
            aulGot[ 1 ] += n;
        }
    }

    /* toggle every multiple of 3: the primes other than 3 stay, 3 goes, the composite
     * multiples of 3 (and 0) arrive */
    for( uint32_t n = 0; n < BITS; n += 3 )
    {
        prvToggle( n );
    }

    for( uint32_t n = 0; n < BITS; n++ )
    {
        aulGot[ 2 ] += prvTest( n );
    }

    aulGot[ 3 ] = prvFlags();
    ullCycles = app_cycles() - ullStart;
    app_snprintf( acValues, sizeof( acValues ), "primes below %u: %lu (sum %lu), after toggling %lu, flags %08lx",
                  BITS, aulGot[ 0 ], aulGot[ 1 ], aulGot[ 2 ], aulGot[ 3 ] );
    prvReport( "zbs", acValues, aulGot, aulWant, 4, ullCycles, "" );
}

/* ---------------------------------------------------------------------------- zicond -- */

static void prvSectionZicond( void )
{
    uint64_t ullStart, ullCycles;
    uint32_t aulGot[ 3 ] = { 0, 0, 0 };
    static const uint32_t aulWant[ 3 ] = { BM_SELECT, BM_CZCLAMP, BM_ADDIF };
    char acValues[ 64 ];

    if( BM_ZBB && ( ( app_cpu() & HADES_APP_CPU_ZICOND ) == 0u ) )
    {
        app_printf( "bitmanip: zicond skipped: this CPU has no Zicond\n" );
        return;
    }

    ullStart = app_cycles();

    for( int i = 0; i < N; i++ )
    {
        const uint32_t w = aulD[ i ];
        const int32_t lX = ( int32_t ) w >> 20;     /* -2048 .. 2047 */

        /* odd words as they are, even words inverted */
        aulGot[ 0 ] += zicond_select( w & 1u, w, ~w );
        /* lX clamped to -1000 .. 1000 without a branch: each bound replaces lX when crossed */
        {
            uint32_t ulC = ( uint32_t ) lX;

            ulC = zicond_select( ( uint32_t ) ( lX < -1000 ), ( uint32_t ) -1000, ulC );
            ulC = zicond_select( ( uint32_t ) ( lX > 1000 ), 1000u, ulC );
            aulGot[ 1 ] += ulC;
        }
        /* add w only when its top bit is set */
        aulGot[ 2 ] = zicond_add_if( w >> 31, aulGot[ 2 ], w );
    }

    ullCycles = app_cycles() - ullStart;
    app_snprintf( acValues, sizeof( acValues ), "select %08lx, clamp %08lx, add-if %08lx", aulGot[ 0 ], aulGot[ 1 ],
                  aulGot[ 2 ] );
    prvReport( "zicond", acValues, aulGot, aulWant, 3, ullCycles, BM_ZBB ? ", czero" : ", C" );
}

int main( void )
{
    prvFill();
    prvSectionZbb();
    prvSectionBytes();
    prvSectionZbs();
    prvSectionZicond();
    app_printf( "bitmanip: %d of %d sections passed\n", iRun - iFailed, iRun );
    return iFailed;
}
