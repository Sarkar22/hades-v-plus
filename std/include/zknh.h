/* SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: zknh.h
 *
 * The SHA-2 functions of Zknh from C: sigma0, sigma1, Sigma0 and Sigma1 of SHA-256
 * (FIPS 180-4, section 4.1.2), and the six RV32 instructions that compute the halves of
 * the SHA-512 functions from the two 32-bit halves of a 64-bit word.
 *
 * GCC 12.2 has no builtins for these instructions and never emits them from C, so with
 * -march=..._zknh each function is one instruction, written as a mnemonic in inline
 * assembly (not volatile: the result depends only on the operands, so the compiler may
 * merge or drop repeated uses like any other arithmetic). Without Zknh in -march they are
 * the same functions in C, written from FIPS 180-4 and from the instruction definitions of
 * the RISC-V scalar cryptography extensions, so one source serves both builds.
 *
 * The SHA-512 helpers take the high and low words of x = {hi, lo}:
 *   sigma0(x) = { zknh_sha512sig0h(hi, lo), zknh_sha512sig0l(lo, hi) }
 *   sigma1(x) = { zknh_sha512sig1h(hi, lo), zknh_sha512sig1l(lo, hi) }
 *   Sigma0(x) = { zknh_sha512sum0r(hi, lo), zknh_sha512sum0r(lo, hi) }
 *   Sigma1(x) = { zknh_sha512sum1r(hi, lo), zknh_sha512sum1r(lo, hi) }
 */

#ifndef ZKNH_H
#define ZKNH_H

#include <stdint.h>

#if defined( __riscv_zknh )

#define ZKNH_UNARY( name )                                               \
    static inline uint32_t zknh_##name( uint32_t x ) {                   \
        uint32_t rd;                                                     \
        __asm__( #name " %0, %1" : "=r"( rd ) : "r"( x ) );              \
        return rd;                                                       \
    }
#define ZKNH_BINARY( name )                                              \
    static inline uint32_t zknh_##name( uint32_t a, uint32_t b ) {       \
        uint32_t rd;                                                     \
        __asm__( #name " %0, %1, %2" : "=r"( rd ) : "r"( a ), "r"( b ) ); \
        return rd;                                                       \
    }

ZKNH_UNARY( sha256sig0 )
ZKNH_UNARY( sha256sig1 )
ZKNH_UNARY( sha256sum0 )
ZKNH_UNARY( sha256sum1 )
ZKNH_BINARY( sha512sig0h )
ZKNH_BINARY( sha512sig0l )
ZKNH_BINARY( sha512sig1h )
ZKNH_BINARY( sha512sig1l )
ZKNH_BINARY( sha512sum0r )
ZKNH_BINARY( sha512sum1r )

#undef ZKNH_UNARY
#undef ZKNH_BINARY

#else

/* rotate right; n is a constant between 1 and 31 in every use below */
static inline uint32_t zknh_ror( uint32_t x, unsigned n ) {
    return ( x >> n ) | ( x << ( 32u - n ) );
}

static inline uint32_t zknh_sha256sig0( uint32_t x ) {
    return zknh_ror( x, 7 ) ^ zknh_ror( x, 18 ) ^ ( x >> 3 );
}
static inline uint32_t zknh_sha256sig1( uint32_t x ) {
    return zknh_ror( x, 17 ) ^ zknh_ror( x, 19 ) ^ ( x >> 10 );
}
static inline uint32_t zknh_sha256sum0( uint32_t x ) {
    return zknh_ror( x, 2 ) ^ zknh_ror( x, 13 ) ^ zknh_ror( x, 22 );
}
static inline uint32_t zknh_sha256sum1( uint32_t x ) {
    return zknh_ror( x, 6 ) ^ zknh_ror( x, 11 ) ^ zknh_ror( x, 25 );
}

static inline uint32_t zknh_sha512sig0h( uint32_t a, uint32_t b ) {
    return ( a >> 1 ) ^ ( a >> 7 ) ^ ( a >> 8 ) ^ ( b << 31 ) ^ ( b << 24 );
}
static inline uint32_t zknh_sha512sig0l( uint32_t a, uint32_t b ) {
    return ( a >> 1 ) ^ ( a >> 7 ) ^ ( a >> 8 ) ^ ( b << 31 ) ^ ( b << 25 ) ^ ( b << 24 );
}
static inline uint32_t zknh_sha512sig1h( uint32_t a, uint32_t b ) {
    return ( a << 3 ) ^ ( a >> 6 ) ^ ( a >> 19 ) ^ ( b >> 29 ) ^ ( b << 13 );
}
static inline uint32_t zknh_sha512sig1l( uint32_t a, uint32_t b ) {
    return ( a << 3 ) ^ ( a >> 6 ) ^ ( a >> 19 ) ^ ( b >> 29 ) ^ ( b << 26 ) ^ ( b << 13 );
}
static inline uint32_t zknh_sha512sum0r( uint32_t a, uint32_t b ) {
    return ( a << 25 ) ^ ( a << 30 ) ^ ( a >> 28 ) ^ ( b >> 7 ) ^ ( b >> 2 ) ^ ( b << 4 );
}
static inline uint32_t zknh_sha512sum1r( uint32_t a, uint32_t b ) {
    return ( a << 23 ) ^ ( a >> 14 ) ^ ( a >> 18 ) ^ ( b >> 9 ) ^ ( b << 18 ) ^ ( b << 14 );
}

#endif

#endif
