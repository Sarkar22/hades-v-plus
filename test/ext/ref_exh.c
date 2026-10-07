/* SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: ref_exh.c
 *
 * Reference model of the Zbb, Zbs, Zicond, Zbkb, Zbkx and Zknh instructions in C,
 * for the host (cc -O2). It prints the digest lines of the vector protocol
 * (test/ext/README.md) so that they can be compared line by line with the RTL
 * harness, including the exhaustive parts: every 32-bit input of the fifteen
 * unary forms.
 *
 * Written from the ratified ISA text, with bit tricks and no compiler built-ins,
 * so that it shares no code and no idiom with ref.py (bit strings) or with
 * test/trapsweep/iss.py (Python integers). ref.py --selftest checks it.
 *
 * usage: ref_exh [--quick] [--no-chunks] [--form M]... [--part P]...
 *        ref_exh --identities      for every 32-bit x: unzip(zip(x)) == x,
 *                                  zip(unzip(x)) == x, brev8(brev8(x)) == x
 *        ref_exh --eval M          stdin: little-endian (rs1, rs2-or-shamt) pairs,
 *                                  stdout: little-endian rd values
 *        ref_exh --dump M P FIRST COUNT   'a b rd' in hex for vectors FIRST.. of part P
 *                                  (for 'shamt', b is the shift amount; for chunks, the
 *                                  rs2 value 0xa5a5a5a5)
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { BIN, IMM, UNA };

struct form {
    const char *name;
    int cls;
    int amount;     /* rs2 is a bit index or rotate amount: part 'amount' */
    int zero;       /* czero: part 'zero' */
};
/* The index forms (part 'index') are xperm4 and xperm8: see index_mask(). */

/* Canonical form order of the protocol. */
static const struct form FORMS[] = {
    { "andn", BIN, 0, 0 },   { "orn", BIN, 0, 0 },    { "xnor", BIN, 0, 0 },
    { "clz", UNA, 0, 0 },    { "ctz", UNA, 0, 0 },    { "cpop", UNA, 0, 0 },
    { "max", BIN, 0, 0 },    { "maxu", BIN, 0, 0 },   { "min", BIN, 0, 0 },    { "minu", BIN, 0, 0 },
    { "sext.b", UNA, 0, 0 }, { "sext.h", UNA, 0, 0 }, { "zext.h", UNA, 0, 0 },
    { "rol", BIN, 1, 0 },    { "ror", BIN, 1, 0 },    { "rori", IMM, 0, 0 },
    { "orc.b", UNA, 0, 0 },  { "rev8", UNA, 0, 0 },
    { "bclr", BIN, 1, 0 },   { "bclri", IMM, 0, 0 },  { "bext", BIN, 1, 0 },   { "bexti", IMM, 0, 0 },
    { "binv", BIN, 1, 0 },   { "binvi", IMM, 0, 0 },  { "bset", BIN, 1, 0 },   { "bseti", IMM, 0, 0 },
    { "czero.eqz", BIN, 0, 1 }, { "czero.nez", BIN, 0, 1 },
    { "pack", BIN, 0, 0 },   { "packh", BIN, 0, 0 },
    { "brev8", UNA, 0, 0 },  { "zip", UNA, 0, 0 },    { "unzip", UNA, 0, 0 },
    { "xperm4", BIN, 0, 0 }, { "xperm8", BIN, 0, 0 },
    { "sha256sig0", UNA, 0, 0 },  { "sha256sig1", UNA, 0, 0 },  { "sha256sum0", UNA, 0, 0 },  { "sha256sum1", UNA, 0, 0 },
    { "sha512sig0h", BIN, 0, 0 }, { "sha512sig0l", BIN, 0, 0 }, { "sha512sig1h", BIN, 0, 0 },
    { "sha512sig1l", BIN, 0, 0 }, { "sha512sum0r", BIN, 0, 0 }, { "sha512sum1r", BIN, 0, 0 },
};
#define NFORMS ((int) (sizeof FORMS / sizeof FORMS[0]))

enum {
    F_ANDN, F_ORN, F_XNOR, F_CLZ, F_CTZ, F_CPOP, F_MAX, F_MAXU, F_MIN, F_MINU,
    F_SEXT_B, F_SEXT_H, F_ZEXT_H, F_ROL, F_ROR, F_RORI, F_ORC_B, F_REV8,
    F_BCLR, F_BCLRI, F_BEXT, F_BEXTI, F_BINV, F_BINVI, F_BSET, F_BSETI,
    F_CZERO_EQZ, F_CZERO_NEZ,
    F_PACK, F_PACKH, F_BREV8, F_ZIP, F_UNZIP, F_XPERM4, F_XPERM8,
    F_SHA256SIG0, F_SHA256SIG1, F_SHA256SUM0, F_SHA256SUM1,
    F_SHA512SIG0H, F_SHA512SIG0L, F_SHA512SIG1H, F_SHA512SIG1L, F_SHA512SUM0R, F_SHA512SUM1R
};

/* Part 'index': the mask applied to the random rs2 value, so that half of the indices are in
 * range (nibble indices 0..15; byte indices 0..3 or 0x80..0x83). 0: no such part. */
static uint32_t index_mask( int f ) {
    return f == F_XPERM4 ? 0xFFFFFFFFu : f == F_XPERM8 ? 0x83838383u : 0;
}

/* ------------------------------------------------------------------ model */

static uint32_t clz32( uint32_t x ) {
    uint32_t n = 0;
    if ( x == 0 ) return 32;
    if ( ( x & 0xFFFF0000u ) == 0 ) { n += 16; x <<= 16; }
    if ( ( x & 0xFF000000u ) == 0 ) { n += 8;  x <<= 8;  }
    if ( ( x & 0xF0000000u ) == 0 ) { n += 4;  x <<= 4;  }
    if ( ( x & 0xC0000000u ) == 0 ) { n += 2;  x <<= 2;  }
    if ( ( x & 0x80000000u ) == 0 ) { n += 1; }
    return n;
}

static uint32_t ctz32( uint32_t x ) {
    uint32_t n = 0;
    if ( x == 0 ) return 32;
    if ( ( x & 0x0000FFFFu ) == 0 ) { n += 16; x >>= 16; }
    if ( ( x & 0x000000FFu ) == 0 ) { n += 8;  x >>= 8;  }
    if ( ( x & 0x0000000Fu ) == 0 ) { n += 4;  x >>= 4;  }
    if ( ( x & 0x00000003u ) == 0 ) { n += 2;  x >>= 2;  }
    if ( ( x & 0x00000001u ) == 0 ) { n += 1; }
    return n;
}

static uint32_t cpop32( uint32_t x ) {
    x = x - ( ( x >> 1 ) & 0x55555555u );
    x = ( x & 0x33333333u ) + ( ( x >> 2 ) & 0x33333333u );
    x = ( x + ( x >> 4 ) ) & 0x0F0F0F0Fu;
    return ( x * 0x01010101u ) >> 24;
}

static uint32_t rotr32( uint32_t x, uint32_t s ) {
    s &= 31;
    return s ? ( x >> s ) | ( x << ( 32 - s ) ) : x;
}

static uint32_t orcb32( uint32_t x ) {
    uint32_t r = 0;
    for ( int i = 0; i < 32; i += 8 )
        if ( ( x >> i ) & 0xFFu ) r |= 0xFFu << i;
    return r;
}

/* Zbkb: the bit order of every byte reversed by three swaps (bits, pairs, nibbles). */
static uint32_t brev8_32( uint32_t x ) {
    x = ( ( x >> 1 ) & 0x55555555u ) | ( ( x & 0x55555555u ) << 1 );
    x = ( ( x >> 2 ) & 0x33333333u ) | ( ( x & 0x33333333u ) << 2 );
    return ( ( x >> 4 ) & 0x0F0F0F0Fu ) | ( ( x & 0x0F0F0F0Fu ) << 4 );
}

/* zip is the outer perfect shuffle (bit 16 + i to 2i + 1, bit i to 2i), done as four swaps of
 * the two middle quarters of 32-, 16-, 8- and 4-bit fields; each swap is its own inverse, so
 * unzip is the same four swaps in the opposite order. */
#define SWAP_MID( x, keep, k, m ) \
    ( ( ( x ) & ( keep ) ) | ( ( ( x ) << ( k ) ) & ( m ) ) | ( ( ( x ) >> ( k ) ) & ( ( m ) >> ( k ) ) ) )
static uint32_t zip32( uint32_t x ) {
    x = SWAP_MID( x, 0xFF0000FFu, 8, 0x00FF0000u );
    x = SWAP_MID( x, 0xF00FF00Fu, 4, 0x0F000F00u );
    x = SWAP_MID( x, 0xC3C3C3C3u, 2, 0x30303030u );
    return SWAP_MID( x, 0x99999999u, 1, 0x44444444u );
}
static uint32_t unzip32( uint32_t x ) {
    x = SWAP_MID( x, 0x99999999u, 1, 0x44444444u );
    x = SWAP_MID( x, 0xC3C3C3C3u, 2, 0x30303030u );
    x = SWAP_MID( x, 0xF00FF00Fu, 4, 0x0F000F00u );
    return SWAP_MID( x, 0xFF0000FFu, 8, 0x00FF0000u );
}

/* Zbkx: a nibble index 8..15 shifts the zero-extended table out entirely (shift < 64). */
static uint32_t xperm4_32( uint32_t lut, uint32_t idx ) {
    uint32_t r = 0;
    for ( int i = 0; i < 32; i += 4 )
        r |= ( uint32_t ) ( ( ( uint64_t ) lut >> ( 4 * ( ( idx >> i ) & 15u ) ) ) & 15u ) << i;
    return r;
}
static uint32_t xperm8_32( uint32_t lut, uint32_t idx ) {
    uint32_t r = 0;
    for ( int i = 0; i < 32; i += 8 ) {
        uint32_t j = ( idx >> i ) & 0xFFu;
        if ( j < 4 ) r |= ( ( lut >> ( 8 * j ) ) & 0xFFu ) << i;
    }
    return r;
}

/* Zknh. SHA-256: FIPS 180-4 sigma and sum functions. SHA-512 on RV32: each instruction is one
 * half of a FIPS 180-4 function of a 64-bit word, which is built here and computed with 64-bit
 * rotates (the pairing of the specification's notes to software developers): the h and r forms
 * give the high half of f({rs1, rs2}), the l forms the low half of f({rs2, rs1}). */
#define ROTR64( x, n ) ( ( ( x ) >> ( n ) ) | ( ( x ) << ( 64 - ( n ) ) ) )
static uint64_t sig0_64( uint64_t x ) { return ROTR64( x, 1 ) ^ ROTR64( x, 8 ) ^ ( x >> 7 ); }
static uint64_t sig1_64( uint64_t x ) { return ROTR64( x, 19 ) ^ ROTR64( x, 61 ) ^ ( x >> 6 ); }
static uint64_t sum0_64( uint64_t x ) { return ROTR64( x, 28 ) ^ ROTR64( x, 34 ) ^ ROTR64( x, 39 ); }
static uint64_t sum1_64( uint64_t x ) { return ROTR64( x, 14 ) ^ ROTR64( x, 18 ) ^ ROTR64( x, 41 ); }
#define HI_OF( fn, h, l ) ( ( uint32_t ) ( fn( ( ( uint64_t ) ( h ) << 32 ) | ( l ) ) >> 32 ) )
#define LO_OF( fn, h, l ) ( ( uint32_t ) fn( ( ( uint64_t ) ( h ) << 32 ) | ( l ) ) )

/* b: rs2 value (register forms) or shamt (immediate forms); ignored by the unary forms. */
static uint32_t model( int f, uint32_t a, uint32_t b ) {
    uint32_t s = b & 31;
    switch ( f ) {
    case F_ANDN:      return a & ~b;
    case F_ORN:       return a | ~b;
    case F_XNOR:      return ~( a ^ b );
    case F_CLZ:       return clz32( a );
    case F_CTZ:       return ctz32( a );
    case F_CPOP:      return cpop32( a );
    case F_MAX:       return ( int32_t ) a > ( int32_t ) b ? a : b;
    case F_MAXU:      return a > b ? a : b;
    case F_MIN:       return ( int32_t ) a < ( int32_t ) b ? a : b;
    case F_MINU:      return a < b ? a : b;
    case F_SEXT_B:    return ( a & 0x80u ) ? ( a | 0xFFFFFF00u ) : ( a & 0xFFu );
    case F_SEXT_H:    return ( a & 0x8000u ) ? ( a | 0xFFFF0000u ) : ( a & 0xFFFFu );
    case F_ZEXT_H:    return a & 0xFFFFu;
    case F_ROL:       return rotr32( a, 32 - s );
    case F_ROR:
    case F_RORI:      return rotr32( a, s );
    case F_ORC_B:     return orcb32( a );
    case F_REV8:      return ( a << 24 ) | ( ( a & 0xFF00u ) << 8 ) | ( ( a >> 8 ) & 0xFF00u ) | ( a >> 24 );
    case F_BCLR:
    case F_BCLRI:     return a & ~( 1u << s );
    case F_BEXT:
    case F_BEXTI:     return ( a >> s ) & 1u;
    case F_BINV:
    case F_BINVI:     return a ^ ( 1u << s );
    case F_BSET:
    case F_BSETI:     return a | ( 1u << s );
    case F_CZERO_EQZ: return b == 0 ? 0 : a;
    case F_CZERO_NEZ: return b != 0 ? 0 : a;
    case F_PACK:      return ( b << 16 ) | ( a & 0xFFFFu );
    case F_PACKH:     return ( ( b & 0xFFu ) << 8 ) | ( a & 0xFFu );
    case F_BREV8:     return brev8_32( a );
    case F_ZIP:       return zip32( a );
    case F_UNZIP:     return unzip32( a );
    case F_XPERM4:    return xperm4_32( a, b );
    case F_XPERM8:    return xperm8_32( a, b );
    case F_SHA256SIG0: return rotr32( a, 7 ) ^ rotr32( a, 18 ) ^ ( a >> 3 );
    case F_SHA256SIG1: return rotr32( a, 17 ) ^ rotr32( a, 19 ) ^ ( a >> 10 );
    case F_SHA256SUM0: return rotr32( a, 2 ) ^ rotr32( a, 13 ) ^ rotr32( a, 22 );
    case F_SHA256SUM1: return rotr32( a, 6 ) ^ rotr32( a, 11 ) ^ rotr32( a, 25 );
    case F_SHA512SIG0H: return HI_OF( sig0_64, a, b );
    case F_SHA512SIG0L: return LO_OF( sig0_64, b, a );
    case F_SHA512SIG1H: return HI_OF( sig1_64, a, b );
    case F_SHA512SIG1L: return LO_OF( sig1_64, b, a );
    case F_SHA512SUM0R: return HI_OF( sum0_64, a, b );
    case F_SHA512SUM1R: return HI_OF( sum1_64, a, b );
    }
    return 0;
}

/* --------------------------------------------------------------- protocol */

#define NOISE 0xA5A5A5A5u
#define RANDOM_N ( 1u << 20 )
#define ZERO_N 4096u
#define SHAMT_RANDOM_N 4096u

static uint32_t corner[ 160 ];
static int ncorner;

static int cmp_u32( const void *x, const void *y ) {
    uint32_t a = *( const uint32_t * ) x, b = *( const uint32_t * ) y;
    return a < b ? -1 : a > b;
}

static void make_corner( void ) {
    static const uint32_t extra[] = {
        0x55555555u, 0xAAAAAAAAu, 0x33333333u, 0xCCCCCCCCu, 0x0F0F0F0Fu, 0xF0F0F0F0u, 0x00FF00FFu,
        0xFF00FF00u, 0x01010101u, 0x80808080u, 0x7F7F7F7Fu, 0xFEFEFEFEu, 0x00010001u, 0x80000001u,
        0x7FFFFFFEu, 0x12345678u, 0x87654321u, 0xDEADBEEFu, 0x0000FF00u, 0x00FF0000u, 0xFFFFFF80u,
        0xFFFF8000u, 0x000000FFu };
    uint32_t v[ 200 ];
    int n = 0;
    v[ n++ ] = 0;
    v[ n++ ] = 0xFFFFFFFFu;
    for ( int k = 0; k < 32; k++ ) v[ n++ ] = 1u << k;
    for ( int k = 0; k < 32; k++ ) v[ n++ ] = ~( 1u << k );
    for ( int k = 1; k <= 32; k++ ) v[ n++ ] = ( uint32_t ) ( ( 1ull << k ) - 1 );
    for ( int k = 1; k < 32; k++ ) v[ n++ ] = 0xFFFFFFFFu << k;
    for ( size_t k = 0; k < sizeof extra / sizeof extra[ 0 ]; k++ ) v[ n++ ] = extra[ k ];
    qsort( v, n, sizeof v[ 0 ], cmp_u32 );
    ncorner = 0;
    for ( int i = 0; i < n; i++ )
        if ( ncorner == 0 || corner[ ncorner - 1 ] != v[ i ] ) corner[ ncorner++ ] = v[ i ];
}

static uint64_t sm_state;

static uint64_t sm_next( void ) {
    uint64_t z;
    sm_state += 0x9E3779B97F4A7C15ull;
    z = sm_state;
    z = ( z ^ ( z >> 30 ) ) * 0xBF58476D1CE4E5B9ull;
    z = ( z ^ ( z >> 27 ) ) * 0x94D049BB133111EBull;
    return z ^ ( z >> 31 );
}

#define FNV0 0xCBF29CE484222325ull
#define FNVP 0x100000001B3ull
#define FOLD( h, v ) ( ( h ) = ( ( h ) ^ ( uint32_t ) ( v ) ) * FNVP )

/* One part: either digest it, or (dump) print vectors [first, first + count). */
struct sink {
    int digest;           /* 1: digest; 0: skip (still consumes the PRNG) */
    long first, count;    /* dump window, count < 0: no dump */
    uint64_t h;
    long n;
};

static void emit( struct sink *k, uint32_t x, uint32_t y, uint32_t rd, int nvals ) {
    if ( k->count >= 0 && k->n >= k->first && k->n < k->first + k->count )
        printf( "%08x %08x %08x\n", x, y, rd );
    if ( nvals == 3 ) { FOLD( k->h, x ); FOLD( k->h, y ); }
    FOLD( k->h, rd );
    k->n++;
}

static int want_values( const struct sink *k ) { return k->digest || k->count >= 0; }

static void part_corner( int f, struct sink *k ) {
    if ( !want_values( k ) ) return;
    for ( int i = 0; i < ncorner; i++ )
        for ( int j = 0; j < ncorner; j++ )
            emit( k, corner[ i ], corner[ j ], model( f, corner[ i ], corner[ j ] ), 3 );
}

static void part_random( int f, struct sink *k ) {
    int on = want_values( k );
    for ( uint32_t i = 0; i < RANDOM_N; i++ ) {
        uint64_t z = sm_next();
        uint32_t a = ( uint32_t ) z, b = ( uint32_t ) ( z >> 32 );
        if ( on ) emit( k, a, b, model( f, a, b ), 3 );
    }
}

static void part_amount( int f, struct sink *k ) {
    int on = want_values( k );
    for ( int i = 0; i < ncorner; i++ )
        for ( uint32_t s = 0; s < 32; s++ ) {
            uint64_t z = sm_next();
            uint32_t b = s | ( ( ( uint32_t ) z & 0x07FFFFFFu ) << 5 );
            if ( on ) emit( k, corner[ i ], b, model( f, corner[ i ], b ), 3 );
        }
}

static void part_zero( int f, struct sink *k ) {
    int on = want_values( k );
    for ( uint32_t i = 0; i < ZERO_N; i++ ) {
        uint32_t a = ( uint32_t ) sm_next();
        if ( on ) emit( k, a, 0, model( f, a, 0 ), 3 );
    }
}

static void part_index( int f, struct sink *k ) {
    int on = want_values( k );
    uint32_t mask = index_mask( f );
    for ( int i = 0; i < ncorner; i++ )
        for ( int j = 0; j < 256; j++ ) {
            uint32_t b = ( uint32_t ) ( sm_next() >> 32 ) & mask;
            if ( on ) emit( k, corner[ i ], b, model( f, corner[ i ], b ), 3 );
        }
}

/* Digested values: s, a, rd. The rs2 value (not digested) must not matter; the model
 * never sees it, which is the point: rd depends on s and a only. */
static void part_shamt( int f, struct sink *k ) {
    int on = want_values( k );
    for ( uint32_t s = 0; s < 32; s++ ) {
        for ( int i = 0; i < ncorner; i++ )
            if ( on ) emit( k, s, corner[ i ], model( f, corner[ i ], s ), 3 );
        for ( uint32_t i = 0; i < SHAMT_RANDOM_N; i++ ) {
            uint64_t z = sm_next();
            if ( on ) emit( k, s, ( uint32_t ) z, model( f, ( uint32_t ) z, s ), 3 );
        }
    }
}

/* Unary chunk N: x = N * 2^24 ... N * 2^24 + 2^24 - 1; digests rd only. The loop is
 * written per form so that the exhaustive run takes seconds, not minutes. */
#define CHUNK_LOOP( EXPR )                                              \
    for ( uint32_t i = 0; i < ( 1u << 24 ); i++ ) {                     \
        uint32_t x = base + i;                                          \
        uint32_t rd = ( EXPR );                                         \
        h = ( h ^ rd ) * FNVP;                                          \
    }

static uint64_t chunk_digest( int f, uint32_t n ) {
    uint64_t h = FNV0;
    uint32_t base = n << 24;
    switch ( f ) {
    case F_CLZ:    CHUNK_LOOP( clz32( x ) ); break;
    case F_CTZ:    CHUNK_LOOP( ctz32( x ) ); break;
    case F_CPOP:   CHUNK_LOOP( cpop32( x ) ); break;
    case F_SEXT_B: CHUNK_LOOP( model( F_SEXT_B, x, NOISE ) ); break;
    case F_SEXT_H: CHUNK_LOOP( model( F_SEXT_H, x, NOISE ) ); break;
    case F_ZEXT_H: CHUNK_LOOP( model( F_ZEXT_H, x, NOISE ) ); break;
    case F_ORC_B:  CHUNK_LOOP( orcb32( x ) ); break;
    case F_REV8:   CHUNK_LOOP( model( F_REV8, x, NOISE ) ); break;
    default: CHUNK_LOOP( model( f, x, NOISE ) ); break;
    }
    return h;
}

/* ------------------------------------------------------------------- main */

static int find_form( const char *m ) {
    for ( int i = 0; i < NFORMS; i++ )
        if ( strcmp( FORMS[ i ].name, m ) == 0 ) return i;
    fprintf( stderr, "ref_exh: unknown form '%s'\n", m );
    exit( 2 );
}

static int eval_stream( int f ) {
    uint32_t in[ 2 * 4096 ], out[ 4096 ];
    size_t n;
    while ( ( n = fread( in, 8, 4096, stdin ) ) > 0 ) {
        for ( size_t i = 0; i < n; i++ ) out[ i ] = model( f, in[ 2 * i ], in[ 2 * i + 1 ] );
        fwrite( out, 4, n, stdout );
    }
    return 0;
}

/* Every 32-bit x: the inverse pairs of Zbkb. */
static int identities( void ) {
    unsigned long long bad[ 3 ] = { 0, 0, 0 };
    for ( uint64_t i = 0; i <= 0xFFFFFFFFull; i++ ) {
        uint32_t x = ( uint32_t ) i;
        bad[ 0 ] += unzip32( zip32( x ) ) != x;
        bad[ 1 ] += zip32( unzip32( x ) ) != x;
        bad[ 2 ] += brev8_32( brev8_32( x ) ) != x;
    }
    printf( "identities over all 4294967296 values: unzip(zip(x)) != x %llu, zip(unzip(x)) != x %llu, "
            "brev8(brev8(x)) != x %llu: %s\n", bad[ 0 ], bad[ 1 ], bad[ 2 ],
            bad[ 0 ] + bad[ 1 ] + bad[ 2 ] ? "FAIL" : "ok" );
    return bad[ 0 ] + bad[ 1 ] + bad[ 2 ] ? 1 : 0;
}

static int listed( const char *name, char **list, int n ) {
    if ( n == 0 ) return 1;
    for ( int i = 0; i < n; i++ )
        if ( strcmp( list[ i ], name ) == 0 ) return 1;
    return 0;
}

int main( int argc, char **argv ) {
    char *forms[ 64 ], *parts[ 300 ];
    int nforms = 0, nparts = 0, quick = 0, chunks = 1;
    const char *dump_part = NULL;
    long dump_first = 0, dump_count = -1;

    {
        /* --eval exchanges words in host order, which ref.py reads as little-endian. */
        uint32_t one = 1;
        if ( *( uint8_t * ) &one != 1 ) { fprintf( stderr, "ref_exh: big-endian host\n" ); return 2; }
    }
    make_corner();
    if ( ncorner != 144 ) { fprintf( stderr, "ref_exh: corner set has %d values\n", ncorner ); return 2; }

    for ( int i = 1; i < argc; i++ ) {
        if ( !strcmp( argv[ i ], "--quick" ) ) quick = 1;
        else if ( !strcmp( argv[ i ], "--no-chunks" ) ) chunks = 0;
        else if ( !strcmp( argv[ i ], "--form" ) && i + 1 < argc && nforms < 64 ) forms[ nforms++ ] = argv[ ++i ];
        else if ( !strcmp( argv[ i ], "--part" ) && i + 1 < argc && nparts < 300 ) parts[ nparts++ ] = argv[ ++i ];
        else if ( !strcmp( argv[ i ], "--eval" ) && i + 1 < argc ) return eval_stream( find_form( argv[ i + 1 ] ) );
        else if ( !strcmp( argv[ i ], "--identities" ) ) return identities();
        else if ( !strcmp( argv[ i ], "--dump" ) && i + 4 < argc ) {
            forms[ 0 ] = argv[ i + 1 ]; nforms = 1;
            dump_part = argv[ i + 2 ];
            dump_first = strtol( argv[ i + 3 ], NULL, 0 );
            dump_count = strtol( argv[ i + 4 ], NULL, 0 );
            i += 4;
        } else {
            fprintf( stderr, "usage: ref_exh [--quick] [--no-chunks] [--form M]... [--part P]...\n"
                             "       ref_exh --eval M | --dump M PART FIRST COUNT | --identities\n" );
            return 2;
        }
    }
    for ( int i = 0; i < nforms; i++ ) find_form( forms[ i ] );

    for ( int f = 0; f < NFORMS; f++ ) {
        const struct form *F = &FORMS[ f ];
        if ( !listed( F->name, forms, nforms ) ) continue;
        sm_state = 0x0123456789ABCDEFull + ( uint64_t ) f;
        if ( F->cls == UNA ) {
            if ( !chunks && !dump_part ) continue;
            for ( uint32_t n = 0; n < 256; n++ ) {
                char name[ 8 ];
                snprintf( name, sizeof name, "c%03u", n );
                if ( dump_part ) {
                    if ( strcmp( dump_part, name ) ) continue;
                    for ( long j = dump_first; j < dump_first + dump_count && j < ( 1l << 24 ); j++ ) {
                        uint32_t x = ( n << 24 ) + ( uint32_t ) j;
                        printf( "%08x %08x %08x\n", x, NOISE, model( f, x, NOISE ) );
                    }
                    continue;
                }
                if ( quick && n != 0 && n != 127 && n != 128 && n != 255 ) continue;
                if ( !listed( name, parts, nparts ) ) continue;
                printf( "%s %s %u %016llx\n", F->name, name, 1u << 24, ( unsigned long long ) chunk_digest( f, n ) );
                fflush( stdout );
            }
            continue;
        }
        static const char *const bin_parts[] = { "corner", "random", "amount", "zero", "index" };
        int np = F->cls == IMM ? 1 : 5;
        for ( int p = 0; p < np; p++ ) {
            const char *pn = F->cls == IMM ? "shamt" : bin_parts[ p ];
            if ( p == 2 && !F->amount ) continue;
            if ( p == 3 && !F->zero ) continue;
            if ( p == 4 && !index_mask( f ) ) continue;
            struct sink k = { 0, 0, -1, FNV0, 0 };
            if ( dump_part ) {
                if ( !strcmp( dump_part, pn ) ) { k.first = dump_first; k.count = dump_count; }
            } else {
                k.digest = listed( pn, parts, nparts );
            }
            switch ( F->cls == IMM ? 5 : p ) {
            case 0: part_corner( f, &k ); break;
            case 1: part_random( f, &k ); break;
            case 2: part_amount( f, &k ); break;
            case 3: part_zero( f, &k ); break;
            case 4: part_index( f, &k ); break;
            case 5: part_shamt( f, &k ); break;
            }
            if ( k.digest ) printf( "%s %s %ld %016llx\n", F->name, pn, k.n, ( unsigned long long ) k.h );
        }
    }
    return 0;
}
