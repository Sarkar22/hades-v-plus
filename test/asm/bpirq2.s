# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: bpirq2.s
#
# Interrupt return address after correctly-predicted-taken branches, three shapes,
# for every branch-predictor mode (MHPMEVENT10 = 0..3) and IRQ delays 1..32:
#  A: backward counted loop (bnez)                      -> count must be 24
#  B: forward taken branch over a poison instruction     -> poison count must be 0
#  C: taken branch whose target has a load-use stall     -> (bubble right behind the
#     branch in Writeback: the interrupt's mepc comes from the saved next-PC)
# Prints 'M<mismatches> I<irqs>' and fails via the test register on any mismatch.
# The golden CPU ignores MHPMEVENT10 (reads 0, no trap).
.option norelax
.global __reset
__reset:
    li t3, 0x480000
    li t1, 1
    sw t1, 0(t3)
    la t0, handler
    csrw mtvec, t0
    li t0, 0x800
    csrw mie, t0
    la s8, word
    li s0, 0                      # mode
    li s5, 0                      # mismatches
    li s6, 0                      # irqs
m_loop:
    csrw 0x32A, s0
    li s1, 1
d_loop:
    # ---- shape A ----
    li s2, 0
    li a0, 24
    sw s1, 4(t3)
    csrsi mstatus, 8
1:  addi s2, s2, 1
    addi a0, a0, -1
    bnez a0, 1b
    csrci mstatus, 8
    sw zero, 4(t3)
    li t0, 24
    beq s2, t0, 2f
    addi s5, s5, 1
2:
    # ---- shape B ----
    li s3, 0
    li a0, 12
    sw s1, 4(t3)
    csrsi mstatus, 8
3:  beq zero, zero, 4f            # always taken, forward
    addi s3, s3, 1                # poison: must never execute
4:  addi a0, a0, -1
    bnez a0, 3b
    csrci mstatus, 8
    sw zero, 4(t3)
    beqz s3, 5f
    addi s5, s5, 1
5:
    # ---- shape C ----
    li s3, 0
    li s4, 0
    li a0, 12
    sw a0, 0(s8)
    sw s1, 4(t3)
    csrsi mstatus, 8
6:  lw a1, 0(s8)
    bnez a0, 7f                   # taken (forward)
    addi s3, s3, 1                # poison
7:  add s4, s4, a1                # load-use on a1 (stall) at the branch target
    addi a0, a0, -1
    bnez a0, 6b
    csrci mstatus, 8
    sw zero, 4(t3)
    li t0, 144                    # 12 * 12
    bnez s3, 8f
    beq s4, t0, 9f
8:  addi s5, s5, 1
9:
    addi s1, s1, 1
    li t0, 33
    blt s1, t0, d_loop
    addi s0, s0, 1
    li t0, 4
    blt s0, t0, m_loop
    csrwi 0x32A, 0
    li s7, 0x210000
    li a0, 'M'
    call pch
    mv a0, s5
    call phex
    li a0, 'I'
    call pch
    mv a0, s6
    call phex
    li a0, 10
    call pch
    bnez s5, 10f
    sw zero, 0(t3)
    j 11f
10: sw t1, 0(t3)
11: li t0, 2
    sw t0, 0(t3)
12: j 12b
pch:
    lbu t6, 3(s7)
    andi t6, t6, 4
    beqz t6, pch
    sb a0, 0(s7)
    ret
phex:
    mv t2, ra
    mv t4, a0
    li t5, 8
13: srli a0, t4, 28
    slli t4, t4, 4
    addi a0, a0, 48
    li t6, 58
    blt a0, t6, 14f
    addi a0, a0, 39
14: call pch
    addi t5, t5, -1
    bnez t5, 13b
    li a0, 32
    call pch
    mv ra, t2
    ret
.balign 256
handler:
    sw zero, 4(t3)
    addi s6, s6, 1
    mret
.balign 4
word: .word 0
