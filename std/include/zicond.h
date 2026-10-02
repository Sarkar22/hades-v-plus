/* SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: zicond.h
 *
 * Zicond (czero.eqz, czero.nez) from C. GCC 12.2 / binutils 2.39 cannot
 * assemble the mnemonics, so the instructions are emitted with .insn and work
 * whatever -march says; the CPU must implement Zicond (HaDes-V+ does; on a CPU
 * without it they raise an illegal-instruction exception). Define
 * ZICOND_PORTABLE before including this file to get branch-free C instead (for
 * a build that must run anywhere).
 */

#ifndef ZICOND_H
#define ZICOND_H

#include <stdint.h>

#ifndef ZICOND_PORTABLE

/* czero.eqz: condition == 0 ? 0 : value */
static inline uint32_t czero_eqz( uint32_t value, uint32_t condition ) {
    uint32_t rd;
    /* Not volatile: the result depends only on the operands, so the compiler may
     * merge or drop repeated uses like any other arithmetic. */
    __asm__( ".insn r 0x33, 5, 7, %0, %1, %2" : "=r"( rd ) : "r"( value ), "r"( condition ) );
    return rd;
}

/* czero.nez: condition != 0 ? 0 : value */
static inline uint32_t czero_nez( uint32_t value, uint32_t condition ) {
    uint32_t rd;
    __asm__( ".insn r 0x33, 7, 7, %0, %1, %2" : "=r"( rd ) : "r"( value ), "r"( condition ) );
    return rd;
}

#else

static inline uint32_t czero_eqz( uint32_t value, uint32_t condition ) {
    return value & ( 0u - ( uint32_t ) ( condition != 0u ) );
}

static inline uint32_t czero_nez( uint32_t value, uint32_t condition ) {
    return value & ( ( uint32_t ) ( condition != 0u ) - 1u );
}

#endif

/* condition != 0 ? if_nonzero : if_zero  (czero.eqz, czero.nez, or). At most one of
 * the two czero results is non-zero, so OR combines them. */
static inline uint32_t zicond_select( uint32_t condition, uint32_t if_nonzero, uint32_t if_zero ) {
    return czero_eqz( if_nonzero, condition ) | czero_nez( if_zero, condition );
}

/* condition != 0 ? a + b : a  (czero.eqz, add) */
static inline uint32_t zicond_add_if( uint32_t condition, uint32_t a, uint32_t b ) {
    return a + czero_eqz( b, condition );
}

#endif
