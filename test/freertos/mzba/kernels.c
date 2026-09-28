/* mzba compute kernels, compiled twice (see app.mk):
 *   hw_*  with the program's -march: the M instructions are issued explicitly
 *         (inline asm) and the array code lets GCC use mul/div/rem and, with
 *         Zba, sh1add/sh2add/sh3add for the scaled indexing;
 *   sw_*  with -march=rv32i -DFRTOS_REF_BUILD: pure C with the RISC-V
 *         division semantics spelled out, libgcc helpers, no Zba.
 * With -march=rv32i both builds are software, which keeps the program
 * runnable on the golden reference CPU. */
#include "kernels.h"

#ifdef FRTOS_REF_BUILD
    #define K( name )    sw_ ## name
#else
    #define K( name )    hw_ ## name
#endif

#if defined( __riscv_mul ) && !defined( FRTOS_REF_BUILD )
#define RV_OP( op, a, b ) \
    ( { uint32_t _r; __asm volatile ( #op " %0, %1, %2" : "=r" ( _r ) : "r" ( a ), "r" ( b ) ); _r; } )

void K( m_ops )( uint32_t a, uint32_t b, MResult_t * r )
{
    r->div = RV_OP( div, a, b );
    r->divu = RV_OP( divu, a, b );
    r->rem = RV_OP( rem, a, b );
    r->remu = RV_OP( remu, a, b );
    r->mul = RV_OP( mul, a, b );
    r->mulh = RV_OP( mulh, a, b );
    r->mulhsu = RV_OP( mulhsu, a, b );
    r->mulhu = RV_OP( mulhu, a, b );
}
#else /* software reference with the RISC-V M semantics */
void K( m_ops )( uint32_t a, uint32_t b, MResult_t * r )
{
    const int32_t sa = ( int32_t ) a, sb = ( int32_t ) b;
    const uint64_t pu = ( uint64_t ) a * ( uint64_t ) b;

    if( b == 0u )
    {
        r->div = 0xFFFFFFFFu;
        r->rem = a;
    }
    else if( ( a == 0x80000000u ) && ( b == 0xFFFFFFFFu ) )
    {
        r->div = 0x80000000u;
        r->rem = 0u;
    }
    else
    {
        r->div = ( uint32_t ) ( sa / sb );
        r->rem = ( uint32_t ) ( sa % sb );
    }

    r->divu = ( b == 0u ) ? 0xFFFFFFFFu : a / b;
    r->remu = ( b == 0u ) ? a : a % b;
    r->mul = ( uint32_t ) pu;
    r->mulhu = ( uint32_t ) ( pu >> 32 );
    r->mulh = ( uint32_t ) ( ( uint64_t ) ( ( int64_t ) sa * ( int64_t ) sb ) >> 32 );
    /* signed x unsigned: a_s = a_u - 2^32*[a<0], so hi = mulhu - (a<0 ? b : 0) */
    r->mulhsu = r->mulhu - ( ( sa < 0 ) ? b : 0u );
}
#endif

/* Scaled-index array code (16-, 32- and 64-bit elements -> sh1add, sh2add,
 * sh3add with Zba) mixed with data-dependent div/rem/mul. */
uint32_t K( array_mix )( const MData_t * d, uint32_t salt )
{
    uint32_t acc = salt;

    for( uint32_t i = 0; i < MZBA_N; i++ )
    {
        uint32_t j = ( acc ^ ( i * 2654435761u ) ) % MZBA_N;
        uint32_t k = ( i * 7u + j ) % MZBA_N;
        int32_t den = ( int32_t ) ( d->a32[ k ] | 1u );

        acc += d->a32[ j ] * 2246822519u;
        acc ^= ( uint32_t ) d->a16[ k ] << ( i & 15u );
        acc += ( uint32_t ) ( d->a64[ ( j + k ) % MZBA_N ] >> ( acc & 31u ) );
        acc = ( acc << 5 ) | ( acc >> 27 );
        acc += ( uint32_t ) ( ( int32_t ) acc / den );
        acc ^= ( uint32_t ) ( ( int32_t ) acc % ( int32_t ) ( ( d->a16[ j ] & 0x7FFu ) + 1u ) );
    }

    return acc;
}

uint32_t K( matmul )( const MData_t * d, uint32_t salt )
{
    uint32_t sum = salt;

    for( int i = 0; i < MZBA_MAT; i++ )
    {
        for( int j = 0; j < MZBA_MAT; j++ )
        {
            int64_t c = 0;

            for( int k = 0; k < MZBA_MAT; k++ )
            {
                c += ( int64_t ) d->ma[ i ][ k ] * d->mb[ k ][ j ];
            }

            sum = sum * 31u + ( ( uint32_t ) c % 1000003u ) + ( uint32_t ) ( c >> 32 );
        }
    }

    return sum;
}
