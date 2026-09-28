# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: bpirq.s
#
# Interrupt landing on / around a correctly-predicted-taken branch.
# For bpred mode m in {0,1,2,3} and IRQ delay d in [1, 80]: arm the
# wishbone_test IRQ, run a 40-iteration counted loop, check the count.
# The handler only disarms the IRQ and returns (mret to mepc).
# Architecturally the loop count must be 40 in every case. Prints the first
# 4 mismatches as 'mode delay count', then 'M<mismatches> I<irqs taken>'.
# The golden CPU ignores MHPMEVENT10 (reads 0, no trap), so it is a valid twin.
.option norelax
.global __reset
__reset:
    li t3, 0x480000
    li t1, 1
    sw t1, 0(t3)                  # "initial test" marker (expected fail)
    la t0, handler
    csrw mtvec, t0
    li t0, 0x800
    csrw mie, t0                  # MEIE
    li s0, 0                      # mode
    li s5, 0                      # mismatches
    li s6, 0                      # total irqs taken
mode_loop:
    csrw 0x32A, s0
    li s1, 1                      # delay
d_loop:
    li s2, 0                      # loop count
    li a0, 40
    sw s1, 4(t3)                  # arm IRQ, fires s1 cycles later
    csrsi mstatus, 8
1:  addi s2, s2, 1
    addi a0, a0, -1
    bnez a0, 1b
    csrci mstatus, 8
    sw zero, 4(t3)                # disarm (in case it did not fire)
    li t0, 40
    beq s2, t0, 2f
    addi s5, s5, 1
    li t0, 5
    bgeu s5, t0, 2f               # print only the first 4 mismatches
    # report: mode, delay, count
    li s7, 0x210000
    mv a0, s0
    call phex
    mv a0, s1
    call phex
    mv a0, s2
    call phex
    li a0, 10
    call pch
2:  addi s1, s1, 1
    li t0, 81
    blt s1, t0, d_loop
    addi s0, s0, 1
    li t0, 4
    blt s0, t0, mode_loop
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
    bnez s5, 3f
    sw zero, 0(t3)                # pass
    j 8f
3:  sw t1, 0(t3)                  # fail: a loop count was wrong
8:  li t0, 2
    sw t0, 0(t3)
9:  j 9b

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
4:  srli a0, t4, 28
    slli t4, t4, 4
    addi a0, a0, 48
    li t6, 58
    blt a0, t6, 5f
    addi a0, a0, 39
5:  call pch
    addi t5, t5, -1
    bnez t5, 4b
    li a0, 32
    call pch
    mv ra, t2
    ret

.balign 256
handler:
    sw zero, 4(t3)                # drop the IRQ line
    addi s6, s6, 1
    mret
