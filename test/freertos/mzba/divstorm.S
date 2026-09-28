/* divstorm -- M-extension storm task for the mzba program (built only with M).
 *
 * Runs table-driven div/divu/rem/remu/mul/mulh/mulhsu/mulhu back to back (the
 * expected values come from the rv32i software reference, computed before the
 * scheduler starts), plus quotient/remainder invariants on chains of dependent
 * divides, while ra, s0-s11 hold fixed values that must survive every
 * interrupt and context switch. A divide occupies Execute for 34 cycles and
 * about 90 % of this loop is divides, so the tick and the external interrupt
 * almost always land inside one (the stall is abandoned by the trap and the
 * divide re-executed after MRET). Fails at once through hal_fail().
 * Table: xDivStormTable[DIVSTORM_N] of {a, b, div, divu, rem, remu, mul, mulh,
 * mulhsu, mulhu} (40 bytes each); loop counter ulDivStormCounter.
 */
#ifdef __riscv_mul
    .equ DS_BASE, 0x44440000
    .equ DIVSTORM_N, 16

    .section .text.vDivStormTask, "ax"
    .globl vDivStormTask
vDivStormTask:
    li   x1, DS_BASE + 1
    li   x8, DS_BASE + 8
    li   x9, DS_BASE + 9
    li   x18, DS_BASE + 18
    li   x19, DS_BASE + 19
    li   x20, DS_BASE + 20
    li   x21, DS_BASE + 21
    li   x22, DS_BASE + 22
    li   x23, DS_BASE + 23
    li   x24, DS_BASE + 24
    li   x25, DS_BASE + 25
    li   x26, DS_BASE + 26
    li   x27, DS_BASE + 27

ds_loop:
    la   t6, xDivStormTable
    li   t5, DIVSTORM_N
ds_entry:
    lw   a0, 0(t6)
    lw   a1, 4(t6)
    div    a2, a0, a1
    lw   a3, 8(t6)
    bne  a2, a3, ds_bad_div
    divu   a2, a0, a1
    lw   a3, 12(t6)
    bne  a2, a3, ds_bad_divu
    rem    a2, a0, a1
    lw   a3, 16(t6)
    bne  a2, a3, ds_bad_rem
    remu   a2, a0, a1
    lw   a3, 20(t6)
    bne  a2, a3, ds_bad_remu
    mul    a2, a0, a1
    lw   a3, 24(t6)
    bne  a2, a3, ds_bad_mul
    mulh   a2, a0, a1
    lw   a3, 28(t6)
    bne  a2, a3, ds_bad_mulh
    mulhsu a2, a0, a1
    lw   a3, 32(t6)
    bne  a2, a3, ds_bad_mulhsu
    mulhu  a2, a0, a1
    lw   a3, 36(t6)
    bne  a2, a3, ds_bad_mulhu
    /* q*b + r == a holds for every input under the RISC-V rules */
    div  a4, a0, a1
    rem  a5, a0, a1
    mul  a6, a4, a1
    add  a6, a6, a5
    bne  a6, a0, ds_bad_inv
    divu a4, a0, a1
    remu a5, a0, a1
    mul  a6, a4, a1
    add  a6, a6, a5
    bne  a6, a0, ds_bad_inv
    /* a quotient used at once as the next divisor */
    divu a4, a0, a1
    ori  a4, a4, 1
    divu a5, a0, a4
    remu a6, a0, a4
    mul  a7, a5, a4
    add  a7, a7, a6
    mv   a6, a7
    bne  a7, a0, ds_bad_inv
    addi t6, t6, 40
    addi t5, t5, -1
    bnez t5, ds_entry

    li   t4, DS_BASE + 1
    bne  x1, t4, ds_bad_reg
    li   t4, DS_BASE + 8
    bne  x8, t4, ds_bad_reg
    li   t4, DS_BASE + 9
    bne  x9, t4, ds_bad_reg
    li   t4, DS_BASE + 18
    bne  x18, t4, ds_bad_reg
    li   t4, DS_BASE + 19
    bne  x19, t4, ds_bad_reg
    li   t4, DS_BASE + 20
    bne  x20, t4, ds_bad_reg
    li   t4, DS_BASE + 21
    bne  x21, t4, ds_bad_reg
    li   t4, DS_BASE + 22
    bne  x22, t4, ds_bad_reg
    li   t4, DS_BASE + 23
    bne  x23, t4, ds_bad_reg
    li   t4, DS_BASE + 24
    bne  x24, t4, ds_bad_reg
    li   t4, DS_BASE + 25
    bne  x25, t4, ds_bad_reg
    li   t4, DS_BASE + 26
    bne  x26, t4, ds_bad_reg
    li   t4, DS_BASE + 27
    bne  x27, t4, ds_bad_reg
    la   t4, ulDivStormCounter
    lw   t3, 0(t4)
    addi t3, t3, 1
    sw   t3, 0(t4)
    ecall                           /* portYIELD() */
    j    ds_loop

ds_bad_div:
    la   a0, ds_msg_div
    j    ds_fail
ds_bad_divu:
    la   a0, ds_msg_divu
    j    ds_fail
ds_bad_rem:
    la   a0, ds_msg_rem
    j    ds_fail
ds_bad_remu:
    la   a0, ds_msg_remu
    j    ds_fail
ds_bad_mul:
    la   a0, ds_msg_mul
    j    ds_fail
ds_bad_mulh:
    la   a0, ds_msg_mulh
    j    ds_fail
ds_bad_mulhsu:
    la   a0, ds_msg_mulhsu
    j    ds_fail
ds_bad_mulhu:
    la   a0, ds_msg_mulhu
    j    ds_fail
ds_bad_inv:
    la   a0, ds_msg_inv
    mv   a2, a6
    j    ds_fail
ds_bad_reg:
    la   a0, ds_msg_reg
    li   a2, 0
    j    ds_fail
ds_fail:                            /* a0 = message, a2 = value found */
    mv   a3, a2
    li   a2, DIVSTORM_N
    sub  a2, a2, t5
    li   a1, 0
    call hal_fail

    .section .rodata.divstorm_msgs, "a"
ds_msg_div:
    .asciz "divstorm: div result differs from the rv32i software reference (a=table entry, b=result)"
ds_msg_divu:
    .asciz "divstorm: divu result differs from the rv32i software reference (a=table entry, b=result)"
ds_msg_rem:
    .asciz "divstorm: rem result differs from the rv32i software reference (a=table entry, b=result)"
ds_msg_remu:
    .asciz "divstorm: remu result differs from the rv32i software reference (a=table entry, b=result)"
ds_msg_mul:
    .asciz "divstorm: mul result differs from the rv32i software reference (a=table entry, b=result)"
ds_msg_mulh:
    .asciz "divstorm: mulh result differs from the rv32i software reference (a=table entry, b=result)"
ds_msg_mulhsu:
    .asciz "divstorm: mulhsu result differs from the rv32i software reference (a=table entry, b=result)"
ds_msg_mulhu:
    .asciz "divstorm: mulhu result differs from the rv32i software reference (a=table entry, b=result)"
ds_msg_inv:
    .asciz "divstorm: q*b+r != a on a dependent divide chain (a=table entry, b=value)"
ds_msg_reg:
    .asciz "divstorm: a callee-saved register (ra/s0-s11) was corrupted"
#endif
