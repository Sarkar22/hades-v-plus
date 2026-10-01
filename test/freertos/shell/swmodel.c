/* swmodel.c -- software model of the RISC-V M and Zba instructions used by the shell.
 *
 * app.mk lists this file in APP_REF_SRCS, so it is always compiled for plain rv32i,
 * whatever MARCH the rest of the program uses: it never executes a multiply, divide
 * or shift-add instruction, and it does not call libgcc either. The shell compares
 * the hardware results against it (commands mul, div and zba).
 *
 * The results follow the RISC-V unprivileged specification, chapter "M" (division
 * by zero and signed overflow do not trap):
 *   x / 0            quotient all ones (unsigned 2^32-1, signed -1), remainder x
 *   -2^31 / -1       quotient -2^31, remainder 0
 *   otherwise        quotient rounded toward zero, remainder with the sign of x
 */
#include "shell.h"

/* 32 x 32 -> 64-bit unsigned product, by shift and add. */
static uint64_t prvMulU( uint32_t a, uint32_t b )
{
    uint64_t ullAcc = 0, ullAddend = a;

    while( b != 0u )
    {
        if( ( b & 1u ) != 0u )
        {
            ullAcc += ullAddend;
        }

        ullAddend <<= 1;
        b >>= 1;
    }

    return ullAcc;
}

/* Unsigned division by shift and subtract; d must not be 0. */
static void prvDivU( uint32_t n, uint32_t d, uint32_t * pulQ, uint32_t * pulR )
{
    uint32_t q = 0, r = 0;

    for( int i = 31; i >= 0; i-- )
    {
        const uint32_t ulCarry = r >> 31;   /* r << 1 would lose this bit */

        r = ( r << 1 ) | ( ( n >> i ) & 1u );

        if( ( ulCarry != 0u ) || ( r >= d ) )
        {
            r -= d;
            q |= 1u << i;
        }
    }

    *pulQ = q;
    *pulR = r;
}

void swmodel_mul( uint32_t a, uint32_t b, ShellMulResult_t * pxOut )
{
    const uint64_t ullProduct = prvMulU( a, b );
    const uint32_t ulHighU = ( uint32_t ) ( ullProduct >> 32 );
    const uint32_t ulASigned = ( ( a >> 31 ) != 0u ) ? b : 0u;   /* correction for a < 0 */
    const uint32_t ulBSigned = ( ( b >> 31 ) != 0u ) ? a : 0u;   /* correction for b < 0 */

    pxOut->ulMul = ( uint32_t ) ullProduct;
    pxOut->ulMulhu = ulHighU;
    pxOut->ulMulhsu = ulHighU - ulASigned;
    pxOut->ulMulh = ulHighU - ulASigned - ulBSigned;
}

void swmodel_div( uint32_t a, uint32_t b, ShellDivResult_t * pxOut )
{
    if( b == 0u )
    {
        pxOut->ulDivu = 0xFFFFFFFFu;
        pxOut->ulRemu = a;
        pxOut->ulDiv = 0xFFFFFFFFu;
        pxOut->ulRem = a;
        return;
    }

    prvDivU( a, b, &pxOut->ulDivu, &pxOut->ulRemu );

    if( ( a == 0x80000000u ) && ( b == 0xFFFFFFFFu ) )
    {
        pxOut->ulDiv = 0x80000000u;
        pxOut->ulRem = 0u;
    }
    else
    {
        const int iNegA = ( a >> 31 ) != 0u;
        const int iNegB = ( b >> 31 ) != 0u;
        uint32_t q, r;

        prvDivU( iNegA ? ( 0u - a ) : a, iNegB ? ( 0u - b ) : b, &q, &r );
        pxOut->ulDiv = ( iNegA != iNegB ) ? ( 0u - q ) : q;
        pxOut->ulRem = iNegA ? ( 0u - r ) : r;
    }
}

uint32_t swmodel_shadd( uint32_t a, uint32_t b, unsigned uShift )
{
    return ( a << uShift ) + b;
}
