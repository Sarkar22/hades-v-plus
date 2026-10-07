/* SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: sha256.h
 *
 * A small SHA-256 (FIPS 180-4) for the benchmarks and the apps, with no library calls:
 *
 *   Sha256_t ctx;  sha256_init(&ctx);  sha256_update(&ctx, data, n); ...;
 *   sha256_final(&ctx, digest);        or, in one call, sha256(data, n, digest)
 *
 * digest is 32 bytes. sigma0, sigma1, Sigma0 and Sigma1 come from zknh.h: one Zknh
 * instruction each when -march names Zknh, plain C otherwise; with Zbb or Zbkb in -march
 * the big-endian message words are read with lw and rev8 (GCC 12.2 does not emit rev8 on
 * RV32: __builtin_bswap32 stays a library call), otherwise with byte loads. Everything else
 * is the same C in every build, so a comparison of builds measures those instructions.
 * Every function is static: include this file in one source file of a program.
 */

#ifndef SHA256_H
#define SHA256_H

#include <stddef.h>
#include <stdint.h>
#include "zknh.h"

#define SHA256_FN static __attribute__( ( unused ) )

typedef struct {
    uint32_t h[ 8 ];        /* the hash value */
    uint32_t buf[ 16 ];     /* a partial block (words, so that it is aligned for lw) */
    uint32_t used;          /* bytes in buf */
    uint32_t len_lo;        /* message length in bytes, 64 bits */
    uint32_t len_hi;
} Sha256_t;

static const uint32_t sha256_k[ 64 ] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u, 0x3956c25bu, 0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u,
    0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u, 0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u,
    0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu, 0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
    0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u, 0xc6e00bf3u, 0xd5a79147u, 0x06ca6351u, 0x14292967u,
    0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u, 0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
    0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u, 0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
    0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u, 0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu, 0x682e6ff3u,
    0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u, 0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u
};

/* The big-endian word at p (4-byte aligned). */
static inline uint32_t sha256_be32( const uint8_t * p ) {
#if defined( __riscv_zbb ) || defined( __riscv_zbkb )
    uint32_t w, r;
    /* one lw (a copy, not a cast: the bytes may belong to a char array) */
    __builtin_memcpy( &w, __builtin_assume_aligned( p, 4 ), sizeof( w ) );
    __asm__( "rev8 %0, %1" : "=r"( r ) : "r"( w ) );
    return r;
#else
    return ( ( uint32_t ) p[ 0 ] << 24 ) | ( ( uint32_t ) p[ 1 ] << 16 ) | ( ( uint32_t ) p[ 2 ] << 8 ) | p[ 3 ];
#endif
}

/* One 64-byte block at p (4-byte aligned). */
SHA256_FN void sha256_block( uint32_t h[ 8 ], const uint8_t * p ) {
    uint32_t w[ 64 ], a, b, c, d, e, f, g, hh, t1, t2;
    int t;

    for( t = 0; t < 16; t++ )
        w[ t ] = sha256_be32( p + 4 * t );
    for( t = 16; t < 64; t++ )
        w[ t ] = zknh_sha256sig1( w[ t - 2 ] ) + w[ t - 7 ] + zknh_sha256sig0( w[ t - 15 ] ) + w[ t - 16 ];

    a = h[ 0 ]; b = h[ 1 ]; c = h[ 2 ]; d = h[ 3 ];
    e = h[ 4 ]; f = h[ 5 ]; g = h[ 6 ]; hh = h[ 7 ];
    for( t = 0; t < 64; t++ ) {
        t1 = hh + zknh_sha256sum1( e ) + ( ( e & f ) ^ ( ~e & g ) ) + sha256_k[ t ] + w[ t ];
        t2 = zknh_sha256sum0( a ) + ( ( a & b ) ^ ( a & c ) ^ ( b & c ) );
        hh = g; g = f; f = e; e = d + t1;
        d = c; c = b; b = a; a = t1 + t2;
    }
    h[ 0 ] += a; h[ 1 ] += b; h[ 2 ] += c; h[ 3 ] += d;
    h[ 4 ] += e; h[ 5 ] += f; h[ 6 ] += g; h[ 7 ] += hh;
}

SHA256_FN void sha256_init( Sha256_t * ctx ) {
    static const uint32_t h0[ 8 ] = { 0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
                                      0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u };
    int i;

    for( i = 0; i < 8; i++ )
        ctx->h[ i ] = h0[ i ];
    ctx->used = 0;
    ctx->len_lo = 0;
    ctx->len_hi = 0;
}

SHA256_FN void sha256_update( Sha256_t * ctx, const void * data, size_t n ) {
    const uint8_t * p = ( const uint8_t * ) data;
    uint8_t * buf = ( uint8_t * ) ctx->buf;

    ctx->len_lo += ( uint32_t ) n;
    if( ctx->len_lo < ( uint32_t ) n )
        ctx->len_hi++;
    while( n > 0 ) {
        if( ( ctx->used == 0 ) && ( n >= 64 ) && ( ( ( uintptr_t ) p & 3u ) == 0 ) ) {
            /* whole aligned blocks straight from the message */
            sha256_block( ctx->h, p );
            p += 64;
            n -= 64;
            continue;
        }
        buf[ ctx->used++ ] = *p++;
        n--;
        if( ctx->used == 64 ) {
            sha256_block( ctx->h, buf );
            ctx->used = 0;
        }
    }
}

SHA256_FN void sha256_final( Sha256_t * ctx, uint8_t digest[ 32 ] ) {
    uint8_t * buf = ( uint8_t * ) ctx->buf;
    uint32_t bits_hi = ( ctx->len_hi << 3 ) | ( ctx->len_lo >> 29 ), bits_lo = ctx->len_lo << 3;
    int i;

    /* the 1 bit, zeros up to 56 bytes of the last block, the length in bits (big-endian) */
    buf[ ctx->used++ ] = 0x80;
    if( ctx->used > 56 ) {
        while( ctx->used < 64 )
            buf[ ctx->used++ ] = 0;
        sha256_block( ctx->h, buf );
        ctx->used = 0;
    }
    while( ctx->used < 56 )
        buf[ ctx->used++ ] = 0;
    for( i = 0; i < 4; i++ ) {
        buf[ 56 + i ] = ( uint8_t ) ( bits_hi >> ( 24 - 8 * i ) );
        buf[ 60 + i ] = ( uint8_t ) ( bits_lo >> ( 24 - 8 * i ) );
    }
    sha256_block( ctx->h, buf );
    for( i = 0; i < 32; i++ )
        digest[ i ] = ( uint8_t ) ( ctx->h[ i / 4 ] >> ( 24 - 8 * ( i % 4 ) ) );
    ctx->used = 0;
}

/* The digest of n bytes at data. */
SHA256_FN void sha256( const void * data, size_t n, uint8_t digest[ 32 ] ) {
    Sha256_t ctx;

    sha256_init( &ctx );
    sha256_update( &ctx, data, n );
    sha256_final( &ctx, digest );
}

#endif
