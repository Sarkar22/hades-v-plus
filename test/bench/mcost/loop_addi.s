# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: loop_addi.s
#
# M-unit cycle cost (make bench-mcost, see test/bench/README.md):
# 100 iterations of eight back-to-back `addi s1, t5, 0` (an RV32I ALU operation),
# between two stores to the test peripheral (markers A and B) whose times
# the simulator prints. Recovered from the development log of 2026-08-18,
# where it was zz_meas_nop.s; everything after this header is the program
# exactly as it was measured.
.option arch, +m
.global __reset
__reset:
    lui  t3, %hi(0x120000<<2)
    addi t3, t3, %lo(0x120000<<2)
    li   t5, 1000003
    li   t6, 7
    li   t2, 100
    nop
    nop
    nop
    nop
    nop
    sw   zero, 0(t3)          # marker A
loop:
    addi s1, t5, 0
    addi s1, t5, 0
    addi s1, t5, 0
    addi s1, t5, 0
    addi s1, t5, 0
    addi s1, t5, 0
    addi s1, t5, 0
    addi s1, t5, 0
    addi t2, t2, -1
    bne  t2, zero, loop
    sw   zero, 0(t3)          # marker B
    nop
    nop
    nop
    nop
    nop
    addi t0, zero, 2
    sw   t0, 0(t3)
    beq zero, zero, __reset
