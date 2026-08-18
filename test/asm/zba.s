# Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
# Embedded Architectures & Systems Group, Graz University of Technology
# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: zba.s
#
# ------------------------------------------------------------------------------------------------
# |                                                                                              |
# | Zba extension test (SH1ADD / SH2ADD / SH3ADD).                                               |
# | If everything runs correctly, the first register of the peripheral test module               |
# | should always be zero, except during the first test, which checks the assert macro itself.   |
# | Note: This condition is necessary, but not sufficient to prove coreectness.                  |
# |                                                                                              |
# | The whole extension is one rule: rd = (rs1 << N) + rs2, for N = 1, 2, 3.                     |
# | The subtleties worth testing are all in what that rule does NOT do:                          |
# |                                                                                              |
# | What is checked:                                                                             |
# |     1. The three shift amounts are actually 1, 2 and 3 (basic cases).                        |
# |     2. rs2 = x0 degenerates to a pure shift; rs1 = x0 degenerates to a copy of rs2.          |
# |     3. x0 as destination is discarded — including for the instruction right behind it,       |
# |        which must read 0 rather than a forwarded result.                                     |
# |     4. rd == rs1, rd == rs2 and rd == rs1 == rs2 aliasing all read the OLD operands.         |
# |     5. The shift is LOGICAL over all 32 bits: a negative rs1 has its sign bit shifted        |
# |        clean out and dropped, not replicated, and no bit above 31 ever comes back.           |
# |     6. Both the shift and the add wrap modulo 2^32 — no overflow trap, no flags. A trap      |
# |        handler is armed for the whole test and turns any exception into a failure.           |
# |     7. The 0xFFFFFFFF corner on both operands at once.                                       |
# |     8. Forwarding: a Zba result consumed by the very next instruction, chained through       |
# |        all three, and consumed as a load address and as a store address.                     |
# |                                                                                              |
# | Register allocation:                                                                         |
# |     x0  (zero): hardwired 0                                                                  |
# |     x5  (t0):   reserved for macro use                                                       |
# |     x6  (t1):   constant 1                                                                   |
# |     x7  (t2):   test case number                                                             |
# |     x28 (t3):   constant 0x120000<<2 (test peripheral address)                               |
# |     x29 (t4):   constant address of words (the 4-byte-stride array)                          |
# |     x30 (t5):   temporary register                                                           |
# |     x31 (t6):   temporary register                                                           |
# |     x9  (s1):   temporary register (results)                                                 |
# |     x18 (s2):   temporary register (results)                                                 |
# |     x19 (s3):   temporary register (results)                                                 |
# |     x20 (s4):   constant address of dwords (the 8-byte-stride array)                         |
# |                                                                                              |
# ------------------------------------------------------------------------------------------------

# The toolchain defaults to plain rv32i, so the three mnemonics below would be
# rejected as unknown opcodes. Enabling zba here rather than adding -march to the
# Makefile keeps the flag next to the only file that needs it — every other
# assembly test still assembles as strict rv32i, which is exactly the guarantee
# worth keeping.
.option arch, +zba

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

.macro interrupt delay=1
    lui  t0,     %hi(\delay)
    addi t0, t0, %lo(\delay)
    sw   t0, 4(t3)
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

.macro flush_pipeline
    nop
    nop
    nop
    nop
    nop
.endm

# ------------------------------------------------------------------------------------------------
# |                            Zba operand-setup helper macros                                   |
# ------------------------------------------------------------------------------------------------
# Loading an arbitrary 32-bit constant is the lui/addi pair the assert macros already
# use; giving it a name keeps the test bodies readable when nearly every case starts
# by planting two specific bit patterns in t5 and t6.
.macro li32 reg:req, value:req
    lui  \reg,       %hi(\value)
    addi \reg, \reg, %lo(\value)
.endm

# Run all three shift amounts against the same operand pair and check all three
# results. t5 and t6 are the operands; s1/s2/s3 receive sh1/sh2/sh3.
.macro zba_all_three e1:req, e2:req, e3:req
    sh1add s1, t5, t6
    sh2add s2, t5, t6
    sh3add s3, t5, t6
    assert_value s1, \e1
    assert_value s2, \e2
    assert_value s3, \e3
.endm

.global __reset
__reset:
    beq  zero, zero, test_init
    # jump to reset if this code snipped reached
    flush_pipeline
    beq  zero, zero, __reset

# ------------------------------------------------------------------------------------------------
# |                            Helperfunctions and Interrupt-handlers!                           |
# ------------------------------------------------------------------------------------------------

# Catch-all trap handler.
# Nothing in this test is allowed to trap. Zba adds no exception of its own: the
# shift cannot fault, the add wraps silently, and the three encodings must decode
# as legal rather than falling through to ILLEGAL. So any trap at all — an illegal
# instruction from a missing decoder arm above all — is a failure, and this handler
# reports it and stops the run instead of letting it limp on with a wrong mepc.
irq_handler_unexpected:
    fail
    halt
    # jump to reset if this code snipped reached
    flush_pipeline
    beq  zero, zero, __reset

# ------------------------------------------------------------------------------------------------
# |                                          Test entry!                                         |
# ------------------------------------------------------------------------------------------------
test_init:
    addi t1, zero, 1              # t1 = 1
    addi t2, zero, 0              # t2 = test case number
    lui  t3, %hi(0x120000<<2)     # t3 = peripheral test address
    lui  t4, %hi(words)           # t4 = 4-byte-stride array address
    lui  s4, %hi(dwords)          # s4 = 8-byte-stride array address
    flush_pipeline
    addi t3, t3, %lo(0x120000<<2)
    addi t4, t4, %lo(words)
    addi s4, s4, %lo(dwords)
    # Arm the catch-all handler for the whole test — see irq_handler_unexpected.
    li32 t5, irq_handler_unexpected
    csrw mtvec, t5

test_fail:
    addi t2, zero, 1
    assert_value zero, 1

# -----------------------------------------------
# The shift amounts really are 1, 2 and 3.
# 0x1000 shifted by one/two/three, plus a small rs2 that is easy to spot.
test_basic:
    addi t2, zero, 2
    flush_pipeline
    li32 t5, 0x00001000
    addi t6, zero, 7
    zba_all_three 0x00002007, 0x00004007, 0x00008007

# -----------------------------------------------
# A pattern with bits in every nibble, so a wrong shift amount cannot coincidentally
# produce the right answer the way a round number like 0x1000 might.
test_basic_pattern:
    addi t2, zero, 3
    flush_pipeline
    li32 t5, 0x12345678
    li32 t6, 0x0000000F
    zba_all_three 0x2468ACFF, 0x48D159EF, 0x91A2B3CF

# -----------------------------------------------
# rs2 = x0 → pure shift, nothing added.
test_rs2_zero:
    addi t2, zero, 4
    flush_pipeline
    li32 t5, 0x12345678
    sh1add s1, t5, zero
    sh2add s2, t5, zero
    sh3add s3, t5, zero
    assert_value s1, 0x2468ACF0
    assert_value s2, 0x48D159E0
    assert_value s3, 0x91A2B3C0

# -----------------------------------------------
# rs1 = x0 → shifting zero is still zero, so the result is a plain copy of rs2,
# identical for all three shift amounts.
test_rs1_zero:
    addi t2, zero, 5
    flush_pipeline
    li32 t6, 0xDEADBEEF
    sh1add s1, zero, t6
    sh2add s2, zero, t6
    sh3add s3, zero, t6
    assert_value s1, 0xDEADBEEF
    assert_value s2, 0xDEADBEEF
    assert_value s3, 0xDEADBEEF

# -----------------------------------------------
# Both sources x0 → 0, for all three.
test_both_zero:
    addi t2, zero, 6
    flush_pipeline
    li32 s1, 0xFFFFFFFF
    li32 s2, 0xFFFFFFFF
    li32 s3, 0xFFFFFFFF
    sh1add s1, zero, zero
    sh2add s2, zero, zero
    sh3add s3, zero, zero
    assert_value s1, 0
    assert_value s2, 0
    assert_value s3, 0

# -----------------------------------------------
# x0 as DESTINATION. The write must be discarded, and — the part a register file
# check alone would miss — the instruction immediately behind it must read x0 as 0
# too. Execute forwards under rd_address, so if x0 were ever allowed to travel the
# forwarding path, this add would pick up 0x2000 instead of 0.
test_rd_is_x0:
    addi t2, zero, 7
    flush_pipeline
    li32 t5, 0x00001000
    li32 t6, 0x00000000
    sh1add zero, t5, t6
    addi   s1, zero, 0            # back-to-back reader of x0
    assert_value s1, 0
    assert_value zero, 0
    sh2add zero, t5, t6
    add    s2, zero, zero         # both operands read x0
    assert_value s2, 0
    sh3add zero, t5, t6
    sub    s3, zero, zero
    assert_value s3, 0
    assert_value zero, 0

# -----------------------------------------------
# rd == rs1: the shift must use the OLD rs1, then overwrite it.
test_rd_aliases_rs1:
    addi t2, zero, 8
    flush_pipeline
    li32 t5, 0x00000100
    addi t6, zero, 1
    sh1add t5, t5, t6             # (0x100 << 1) + 1
    assert_value t5, 0x00000201
    li32 t5, 0x00000100
    sh2add t5, t5, t6             # (0x100 << 2) + 1
    assert_value t5, 0x00000401
    li32 t5, 0x00000100
    sh3add t5, t5, t6             # (0x100 << 3) + 1
    assert_value t5, 0x00000801

# -----------------------------------------------
# rd == rs2: the add must use the OLD rs2, then overwrite it.
test_rd_aliases_rs2:
    addi t2, zero, 9
    flush_pipeline
    li32 t5, 0x00000010
    addi t6, zero, 3
    sh1add t6, t5, t6             # (0x10 << 1) + 3
    assert_value t6, 0x00000023
    addi t6, zero, 3
    sh2add t6, t5, t6             # (0x10 << 2) + 3
    assert_value t6, 0x00000043
    addi t6, zero, 3
    sh3add t6, t5, t6             # (0x10 << 3) + 3
    assert_value t6, 0x00000083

# -----------------------------------------------
# rd == rs1 == rs2: one register is read twice and written once.
# (x << N) + x, i.e. x * (2^N + 1): x*3, x*5, x*9.
test_rd_aliases_both:
    addi t2, zero, 10
    flush_pipeline
    addi t5, zero, 5
    sh1add t5, t5, t5
    assert_value t5, 15           # 5 * 3
    addi t5, zero, 5
    sh2add t5, t5, t5
    assert_value t5, 25           # 5 * 5
    addi t5, zero, 5
    sh3add t5, t5, t5
    assert_value t5, 45           # 5 * 9

# -----------------------------------------------
# NEGATIVE rs1. The sign bit is just bit 31: shifting left pushes it out of the
# word and it is DROPPED. 0xC0000001 has its top two bits set, so one shift keeps
# a negative result, two shifts leave only the low bit's contribution, and three
# shifts move it further — an arithmetic or saturating shift would not do this.
test_negative_rs1:
    addi t2, zero, 11
    flush_pipeline
    li32 t5, 0xC0000001
    li32 t6, 0x00000010
    zba_all_three 0x80000012, 0x00000014, 0x00000018

# -----------------------------------------------
# The most negative value: 0x80000000 is nothing but the sign bit, so every shift
# amount pushes it out and leaves exactly rs2 behind. If the shift sign-extended,
# all three would come back 0xFFFFFF..-ish instead.
test_sign_bit_only:
    addi t2, zero, 12
    flush_pipeline
    li32 t5, 0x80000000
    li32 t6, 0x0BADF00D
    zba_all_three 0x0BADF00D, 0x0BADF00D, 0x0BADF00D

# -----------------------------------------------
# NEGATIVE rs2 is simply added; the sum wraps and stays exact.
# 4<<1=8, 8-1=7;  4<<2=16, 16-1=15;  4<<3=32, 32-1=31.
test_negative_rs2:
    addi t2, zero, 13
    flush_pipeline
    addi t5, zero, 4
    li32 t6, 0xFFFFFFFF
    zba_all_three 7, 15, 31

# -----------------------------------------------
# Shift overflow: bits leave the top of the word and never return, and the add
# that follows wraps modulo 2^32. No trap — the handler armed in test_init would
# report one. 0x90000000 << 3 = 0x80000000 (the 100 at the top is discarded).
test_shift_overflow:
    addi t2, zero, 14
    flush_pipeline
    li32 t5, 0x90000000
    addi t6, zero, 5
    zba_all_three 0x20000005, 0x40000005, 0x80000005

# -----------------------------------------------
# The maximum operands on both sides at once: 0xFFFFFFFF << N drops N ones off the
# top and shifts N zeros in at the bottom, then adding 0xFFFFFFFF (i.e. -1) wraps
# the sum back around.
test_max_operands:
    addi t2, zero, 15
    flush_pipeline
    li32 t5, 0xFFFFFFFF
    li32 t6, 0xFFFFFFFF
    zba_all_three 0xFFFFFFFD, 0xFFFFFFFB, 0xFFFFFFF7

# -----------------------------------------------
# Max rs1 with rs2 = 0, isolating the shift half of the corner.
test_max_rs1_only:
    addi t2, zero, 16
    flush_pipeline
    li32 t5, 0xFFFFFFFF
    li32 t6, 0x00000000
    zba_all_three 0xFFFFFFFE, 0xFFFFFFFC, 0xFFFFFFF8

# -----------------------------------------------
# FORWARDING: each Zba consumes the result of the one directly in front of it,
# with no instruction in between, so the value can only come from Execute's
# combinational forwarding path — the register file is three cycles behind.
test_forward_back_to_back:
    addi t2, zero, 17
    flush_pipeline
    addi t5, zero, 3
    sh1add t6, t5, zero           # t6 = 6
    sh1add s1, t6, zero           # s1 = 12, needs t6 forwarded from Execute
    sh1add s2, s1, zero           # s2 = 24, needs s1 forwarded from Execute
    assert_value s2, 24
    assert_value s1, 12
    assert_value t6, 6

# -----------------------------------------------
# The same, chained through all three shift amounts and through rd == rs1 == rs2
# at once — every operand of every instruction is a forwarded value.
# 1 -> (1<<1)+1 = 3 -> (3<<2)+3 = 15 -> (15<<3)+15 = 135.
test_forward_chain:
    addi t2, zero, 18
    flush_pipeline
    addi   t5, zero, 1
    sh1add t5, t5, t5
    sh2add t5, t5, t5
    sh3add t5, t5, t5
    assert_value t5, 135

# -----------------------------------------------
# A Zba result used as a LOAD address by the very next instruction. This is the
# case the extension exists for: sh2add turns a word index into a byte address.
test_forward_load_address:
    addi t2, zero, 19
    flush_pipeline
    addi   t5, zero, 2
    sh2add t6, t5, t4             # &words[2]
    lw     s1, 0(t6)              # back-to-back consumer of t6
    assert_value s1, 0x33333333
    addi   t5, zero, 0
    sh2add t6, t5, t4
    lw     s1, 0(t6)
    assert_value s1, 0x11111111
    addi   t5, zero, 3
    sh2add t6, t5, t4
    lw     s1, 0(t6)
    assert_value s1, 0x44444444

# -----------------------------------------------
# sh3add against an 8-byte stride — the shape a long long index compiles to.
test_forward_load_dword:
    addi t2, zero, 20
    flush_pipeline
    addi   t5, zero, 1
    sh3add t6, t5, s4             # &dwords[1], i.e. +8 bytes
    lw     s1, 0(t6)
    assert_value s1, 0xAAAAAAAA
    lw     s2, 4(t6)
    assert_value s2, 0xBBBBBBBB

# -----------------------------------------------
# A Zba result used as a STORE address by the very next instruction, and the stored
# value itself produced by a Zba directly in front of the store.
test_forward_store_address:
    addi t2, zero, 21
    flush_pipeline
    addi   t5, zero, 1
    sh2add t6, t5, t4             # &words[1]
    li32   s1, 0x0000CAFE
    sh1add s2, s1, zero           # s2 = 0x000195FC, produced right before the store
    sw     s2, 0(t6)              # both address and data are forwarded values
    flush_pipeline
    lw     s3, 4(t4)
    assert_value s3, 0x000195FC
    # put the original value back so the array stays as declared
    li32 s1, 0x22222222
    sw   s1, 4(t4)

# -----------------------------------------------
# A Zba whose operands both come from a load, exercising the load-use stall path
# in front of a Zba rather than behind it.
test_load_use_into_zba:
    addi t2, zero, 22
    flush_pipeline
    lw     t5, 0(t4)              # 0x11111111
    sh1add s1, t5, t5             # load-use hazard on both operands
    assert_value s1, 0x33333333
    lw     t5, 0(t4)
    lw     t6, 4(t4)              # 0x22222222
    sh2add s2, t5, t6
    assert_value s2, 0x66666666

# -----------------------------------------------
# Zba feeding a branch comparison, and the array left exactly as declared.
test_zba_into_branch:
    addi t2, zero, 23
    flush_pipeline
    addi   t5, zero, 4
    sh1add t6, t5, zero           # t6 = 8
    addi   s1, zero, 8
    bne    t6, s1, zba_branch_bad # must not be taken
    beq    zero, zero, zba_branch_ok
    zba_branch_bad:
    fail
    zba_branch_ok:
    assert_value t6, 8
    lw s1, 4(t4)
    assert_value s1, 0x22222222

# ------------------------------------------------------------------------------------------------
# |                                          Test done!                                          |
# ------------------------------------------------------------------------------------------------
test_finish:
    addi t2, zero, 24
    halt
    fail

    .align 4
words:
    .word 0x11111111
    .word 0x22222222
    .word 0x33333333
    .word 0x44444444
    .align 3
dwords:
    .word 0x99999999
    .word 0x88888888
    .word 0xAAAAAAAA
    .word 0xBBBBBBBB
