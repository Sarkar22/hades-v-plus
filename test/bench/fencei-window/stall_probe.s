# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: stall_probe.s
#
# FENCE.I staleness window (make bench-fencei-window, see test/bench/README.md):
# the cycles, read from mcycle, of two nops, of the two loads from the test
# peripheral's stalling register that fill the gap of case S12 in fencei_stale.s,
# and of two loads that do not stall; printed as three hex digits. Recovered from
# the development log of 2026-08-17; everything after this header is the program
# exactly as it was run.
.macro flush_pipeline
    nop
    nop
    nop
    nop
    nop
.endm
.section .text
.option norelax
.global __reset
__reset:
    addi t1, zero, 1
    lui  t3, %hi(0x480000)
    addi t3, t3, %lo(0x480000)
    lui  a7, %hi(0x210000)
    addi a7, a7, %lo(0x210000)
    flush_pipeline
    # baseline: 2 nops between two csrr mcycle
    csrr t5, 0xB00
    nop
    nop
    csrr t6, 0xB00
    sub  s8, t6, t5
    flush_pipeline
    # 2 stalling loads (test peripheral offset 3)
    csrr t5, 0xB00
    lw   t2, 12(t3)
    lw   t2, 12(t3)
    csrr t6, 0xB00
    sub  s9, t6, t5
    flush_pipeline
    # 2 plain RAM loads for reference
    csrr t5, 0xB00
    lw   t2, 0(t3)
    lw   t2, 0(t3)
    csrr t6, 0xB00
    sub  s10, t6, t5
    flush_pipeline
    # print s8, s9, s10 as single hex digits (values are small)
    addi a2, s8, 0
    jal  ra, puthex
    addi a2, s9, 0
    jal  ra, puthex
    addi a2, s10, 0
    jal  ra, puthex
    addi t0, zero, 10
    sb   t0, 0(a7)
    addi t0, zero, 2
    sw   t0, 0(t3)
1:  j 1b

puthex:
    andi t0, a2, 0xf
    addi t5, zero, 10
    blt  t0, t5, 1f
    addi t0, t0, 39
1:  addi t0, t0, 48
    sb   t0, 0(a7)
    addi t0, zero, 32
    sb   t0, 0(a7)
    jalr zero, 0(ra)
