/* mzba compute kernels: hw_* = built with the program's -march (M/Zba
 * instructions), sw_* = the same source built for plain rv32i. */
#ifndef MZBA_KERNELS_H
#define MZBA_KERNELS_H
#include <stdint.h>

#define MZBA_N      16   /* array length */
#define MZBA_MAT    4    /* matrix dimension */

typedef struct
{
    uint32_t div, divu, rem, remu, mul, mulh, mulhsu, mulhu;
} MResult_t;

typedef struct
{
    uint32_t a32[ MZBA_N ];
    uint16_t a16[ MZBA_N ];
    uint64_t a64[ MZBA_N ];
    int32_t ma[ MZBA_MAT ][ MZBA_MAT ];
    int32_t mb[ MZBA_MAT ][ MZBA_MAT ];
} MData_t;

void hw_m_ops( uint32_t a, uint32_t b, MResult_t * r );
void sw_m_ops( uint32_t a, uint32_t b, MResult_t * r );
uint32_t hw_array_mix( const MData_t * d, uint32_t salt );
uint32_t sw_array_mix( const MData_t * d, uint32_t salt );
uint32_t hw_matmul( const MData_t * d, uint32_t salt );
uint32_t sw_matmul( const MData_t * d, uint32_t salt );
#endif
