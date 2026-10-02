/* compute.c -- an app that computes: integer arithmetic that uses the M and Zba instructions
 * when it is built for them (make freertos-app NAME=compute MARCH=rv32im_zba), and the
 * libgcc routines of RV32I otherwise, checked against constants.
 *
 * Two 16 x 16 matrices of int32_t, A and B, are filled row by row with a 32-bit linear
 * congruential generator (s = s * 1664525 + 1013904223 from s = 1; each element is
 * ( s >> 16 ) - 32768 of the next s) and multiplied: C = A * B, with the products and sums in
 * uint32_t, so that they wrap without undefined behaviour (mul; the array indexing gives
 * sh2add, see prvElement()). Four sums of C, again in uint32_t, are then compared with the
 * expected values:
 *   trace        the sum of C[i][i]
 *   quotients    the sum of C[i][j] / ( j + 1 ), C's division, rounding toward zero (div)
 *   remainders   the sum of C[i][j] % 7 (rem)
 *   mulhu        the sum of the high halves of the unsigned 64-bit products A[i][j] * B[j][i]
 * The expected values below were computed by model.py in this directory, which models the
 * same arithmetic independently, in Python.
 *
 * Output: "compute: trace <t>, quotients <q>, remainders <r>, mulhu <h>: PASS (<c> cycles)",
 * exit code 0; on a mismatch the line ends in FAIL, the expected values follow on a line of
 * their own, and the exit code is 1. */
#include <stdint.h>
#include "hades_app.h"

/* python3 test/freertos/sdk/apps/compute/model.py */
#define COMPUTE_TRACE         0x413391f6u
#define COMPUTE_QUOTIENTS     0x562e0319u
#define COMPUTE_REMAINDERS    0x00000016u
#define COMPUTE_MULHU         0x00030712u

#define N    16

static int32_t lA[ N ][ N ], lB[ N ][ N ], lC[ N ][ N ];

static void prvFill( int32_t plM[ N ][ N ], uint32_t * pulSeed )
{
    for( int i = 0; i < N; i++ )
    {
        for( int j = 0; j < N; j++ )
        {
            *pulSeed = *pulSeed * 1664525u + 1013904223u;
            plM[ i ][ j ] = ( int32_t ) ( *pulSeed >> 16 ) - 32768;
        }
    }
}

/* One element of C = A * B. It has a function of its own, which receives the row and the
 * column as numbers: the address of column j of B is then B + 4 * j, one sh2add with Zba.
 * (Inlined into the loops, it would let GCC step pointers through the matrices instead.) */
static int32_t __attribute__( ( noinline ) ) prvElement( int i, int j )
{
    uint32_t ulSum = 0;

    for( int k = 0; k < N; k++ )
    {
        ulSum += ( uint32_t ) lA[ i ][ k ] * ( uint32_t ) lB[ k ][ j ];
    }

    return ( int32_t ) ulSum;
}

static void prvMultiply( void )
{
    for( int i = 0; i < N; i++ )
    {
        for( int j = 0; j < N; j++ )
        {
            lC[ i ][ j ] = prvElement( i, j );
        }
    }
}

int main( void )
{
    const uint64_t ullStart = app_cycles();
    uint32_t ulSeed = 1, ulTrace = 0, ulQuotients = 0, ulRemainders = 0, ulMulhu = 0;
    uint64_t ullCycles;
    int iPass;

    prvFill( lA, &ulSeed );
    prvFill( lB, &ulSeed );
    prvMultiply();

    for( int i = 0; i < N; i++ )
    {
        ulTrace += ( uint32_t ) lC[ i ][ i ];

        for( int j = 0; j < N; j++ )
        {
            ulQuotients += ( uint32_t ) ( lC[ i ][ j ] / ( j + 1 ) );
            ulRemainders += ( uint32_t ) ( lC[ i ][ j ] % 7 );
            ulMulhu += ( uint32_t ) ( ( ( uint64_t ) ( uint32_t ) lA[ i ][ j ] * ( uint32_t ) lB[ j ][ i ] ) >> 32 );
        }
    }

    ullCycles = app_cycles() - ullStart;
    iPass = ( ulTrace == COMPUTE_TRACE ) && ( ulQuotients == COMPUTE_QUOTIENTS ) &&
            ( ulRemainders == COMPUTE_REMAINDERS ) && ( ulMulhu == COMPUTE_MULHU );

    if( iPass )
    {
        app_printf( "compute: trace %lu, quotients %lu, remainders %lu, mulhu %lu: PASS (%llu cycles)\n",
                    ulTrace, ulQuotients, ulRemainders, ulMulhu, ullCycles );
        return 0;
    }

    app_printf( "compute: trace %lu, quotients %lu, remainders %lu, mulhu %lu: FAIL\n",
                ulTrace, ulQuotients, ulRemainders, ulMulhu );
    app_printf( "compute: expected trace %lu, quotients %lu, remainders %lu, mulhu %lu\n",
                ( uint32_t ) COMPUTE_TRACE, ( uint32_t ) COMPUTE_QUOTIENTS, ( uint32_t ) COMPUTE_REMAINDERS,
                ( uint32_t ) COMPUTE_MULHU );
    return 1;
}
