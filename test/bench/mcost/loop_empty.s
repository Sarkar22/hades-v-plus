# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: loop_empty.s
#
# M-unit cycle cost (make bench-mcost, see test/bench/README.md):
# the loop of loop_addi.s, loop_mul.s, loop_div.s and loop_div0.s with an empty
# body, i.e. 100 iterations of `addi t2, t2, -1` and `bne t2, zero, loop` alone,
# between the same two markers. Its time is the loop overhead that make
# bench-mcost subtracts from the other four. Added on 2026-10-01: it was not part
# of the 2026-08-18 measurement, which took the overhead from loop_addi.s by
# assuming that an ALU operation costs one cycle; this program measures it.
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
