# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: stores.s
#
# ------------------------------------------------------------------------------------------------
# |                                                                                              |
# | BACK-TO-BACK RAM ACCESSES, for the memory-system checks (test/memsys/programs.py).           |
# |                                                                                              |
# | Every block below issues its loads and stores with no gap between them, so that each data    |
# | access reaches the bus in the cycle after the previous one was acknowledged. A memory path   |
# | that acknowledges an access early, drops, repeats or reorders a write, or answers a load     |
# | with another access's data then changes a value that the program checks, at any latency of   |
# | the slow memory and also without the scoreboard. Most other test programs space their RAM    |
# | accesses out, so such a fault often stays invisible in them at a fixed latency.              |
# |                                                                                              |
# | Every case writes values that differ from what the words held before. The whole body runs    |
# | with the branch predictor off (mode 0) and in mode 3 (the golden CPU ignores the mode). Its  |
# | reports are the same at every latency (no check measures time).                              |
# |                                                                                              |
# | Register allocation:                                                                         |
# |     x5  (t0):   reserved for macro use                                                       |
# |     x6  (t1):   1 (the value a failed check writes)                                          |
# |     x7  (t2):   test case number                                                             |
# |     x28 (t3):   test peripheral address                                                      |
# |     x8  (s0):   buffer address (0x46000: unused RAM above the program)                       |
# |     s1..s10, a0..a7: data    s11: branch-predictor mode    t4: scratch                       |
# |                                                                                              |
# ------------------------------------------------------------------------------------------------

.macro pass
    sw zero, 0(t3)
.endm

.macro fail
    sw t1, 0(t3)
.endm

.macro halt
    addi t0, zero, 2
    sw   t0, 0(t3)
.endm

.macro assert_equal r1:req, r2:req
    sub  t0, \r1, \r2
    sltu t0, zero, t0
    sw   t0, 0(t3)
.endm

.macro assert_value reg:req, value: req
    lui  t0,     %hi(\value)
    addi t0, t0, %lo(\value)
    assert_equal t0, \reg
.endm

.macro li32 reg:req, value:req
    lui  \reg, %hi(\value)
    addi \reg, \reg, %lo(\value)
.endm

.option norelax

# ------------------------------------------------------------------------------------------------
# |                                          Test entry!                                         |
# ------------------------------------------------------------------------------------------------
.global __reset
__reset:

test_init:
    addi t1, zero, 1
    addi t2, zero, 0
    lui  t3, %hi(0x120000<<2)
    addi t3, t3, %lo(0x120000<<2)
    lui  s0, %hi(0x46000)
    addi s0, s0, %lo(0x46000)

# Deliberate first failure: proves the assert macro and the test peripheral work.
test_fail:
    addi t2, zero, 1
    assert_value zero, 1

    addi s11, zero, 0              # branch-predictor mode 0, then 3
test_mode:
    csrw 0x32A, s11                # MHPMEVENT10: branch-predictor mode

# -----------------------------------------------
# Case 2: eight stores to consecutive words, then eight loads of them.
test_store_run:
    addi t2, zero, 2
    li32 a0, 0x11111111
    li32 a1, 0x22222222
    li32 a2, 0x33333333
    li32 a3, 0x44444444
    li32 a4, 0x55555555
    li32 a5, 0x66666666
    li32 a6, 0x77777777
    li32 a7, 0x88888888
    sw   a0, 0(s0)
    sw   a1, 4(s0)
    sw   a2, 8(s0)
    sw   a3, 12(s0)
    sw   a4, 16(s0)
    sw   a5, 20(s0)
    sw   a6, 24(s0)
    sw   a7, 28(s0)
    lw   s1, 0(s0)
    lw   s2, 4(s0)
    lw   s3, 8(s0)
    lw   s4, 12(s0)
    lw   s5, 16(s0)
    lw   s6, 20(s0)
    lw   s7, 24(s0)
    lw   s8, 28(s0)
    assert_equal s1, a0
    assert_equal s2, a1
    assert_equal s3, a2
    assert_equal s4, a3
    assert_equal s5, a4
    assert_equal s6, a5
    assert_equal s7, a6
    assert_equal s8, a7

# -----------------------------------------------
# Case 3: the same word written twice in a row, then read; then store, load, store, load.
test_same_word:
    addi t2, zero, 3
    li32 a0, 0x0BADF00D
    li32 a1, 0x600DCAFE
    sw   a0, 32(s0)
    sw   a1, 32(s0)
    lw   s1, 32(s0)
    sw   a0, 36(s0)
    lw   s2, 36(s0)
    sw   a1, 36(s0)
    lw   s3, 36(s0)
    lw   s4, 32(s0)
    assert_equal s1, a1
    assert_equal s2, a0
    assert_equal s3, a1
    assert_equal s4, a1

# -----------------------------------------------
# Case 4: byte and halfword stores into one word in a row (each selects other lanes).
test_lanes:
    addi t2, zero, 4
    li32 a0, 0xFFFFFFFF
    addi a1, zero, 0x12
    addi a2, zero, 0x34
    addi a3, zero, 0x56
    addi a4, zero, 0x78
    li32 a5, 0x9ABC
    sw   a0, 40(s0)
    sb   a1, 40(s0)
    sb   a2, 41(s0)
    sb   a3, 42(s0)
    sb   a4, 43(s0)
    lw   s1, 40(s0)
    sw   a0, 44(s0)
    sh   a5, 46(s0)
    sb   a1, 44(s0)
    lw   s2, 44(s0)
    lbu  s3, 41(s0)
    lhu  s4, 46(s0)
    assert_value s1, 0x78563412
    assert_value s2, 0x9ABCFF12
    assert_value s3, 0x34
    assert_value s4, 0x9ABC

# -----------------------------------------------
# Case 5: a load between stores to other words must see the older value of its own word.
test_interleaved:
    addi t2, zero, 5
    li32 a0, 0xA5A5A5A5
    li32 a1, 0x5A5A5A5A
    li32 a2, 0xC3C3C3C3
    sw   a0, 48(s0)
    sw   a1, 52(s0)
    lw   s1, 48(s0)
    sw   a2, 48(s0)
    lw   s2, 52(s0)
    lw   s3, 48(s0)
    sw   a0, 52(s0)
    lw   s4, 52(s0)
    assert_equal s1, a0
    assert_equal s2, a1
    assert_equal s3, a2
    assert_equal s4, a0

# -----------------------------------------------
# Case 6: 64 iterations of two stores and two loads with no gap, over a 16-word window;
# each iteration writes values that differ from the previous ones. A checksum of all
# loaded values is compared once at the end.
test_loop:
    addi t2, zero, 6
    addi s1, zero, 0               # i
    addi s2, zero, 64              # iterations
    addi s3, zero, 0               # checksum of the loaded values
    addi s4, zero, 0               # expected checksum
    li32 s5, 0x9E3779B9            # value step
    addi s6, zero, 0               # value
1:
    add  s6, s6, s5                # v1
    add  a2, s6, s5                # v2
    andi a0, s1, 15
    slli a0, a0, 2
    add  a0, a0, s0                # word i mod 16
    xori a1, a0, 32                # word (i + 8) mod 16
    sw   s6, 64(a0)
    sw   a2, 64(a1)
    lw   a3, 64(a0)
    lw   a4, 64(a1)
    add  s3, s3, a3
    xor  s3, s3, a4
    add  s4, s4, s6
    xor  s4, s4, a2
    mv   s6, a2
    addi s1, s1, 1
    bne  s1, s2, 1b
    assert_equal s3, s4

    addi s11, s11, 3
    addi t4, zero, 6
    bne  s11, t4, test_mode

# ------------------------------------------------------------------------------------------------
# |                                          Test done!                                          |
# ------------------------------------------------------------------------------------------------
test_finish:
    csrwi 0x32A, 0
    addi t2, zero, 9
    halt
    fail
