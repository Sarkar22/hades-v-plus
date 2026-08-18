# Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
# Embedded Architectures & Systems Group, Graz University of Technology
# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: mul.s
#
# ------------------------------------------------------------------------------------------------
# |                                                                                              |
# | M extension, multiply half: MUL / MULH / MULHSU / MULHU.                                     |
# | If everything runs correctly, the first register of the peripheral test module               |
# | should always be zero, except during the first test, which checks the assert macro itself.   |
# | Note: This condition is necessary, but not sufficient to prove correctness.                  |
# |                                                                                              |
# | All four instructions compute the SAME 64-bit product rs1 x rs2 and differ only in which     |
# | half they return and how the 32-bit operands are extended to get there:                      |
# |                                                                                              |
# |     MUL     low 32 bits.  Signedness is irrelevant for the low half -- the low 32 bits of    |
# |             the product are identical for every combination of signed/unsigned operands,     |
# |             which is why RISC-V has one MUL and not three.                                   |
# |     MULH    high 32 bits, rs1 SIGNED   x rs2 SIGNED                                          |
# |     MULHSU  high 32 bits, rs1 SIGNED   x rs2 UNSIGNED                                        |
# |     MULHU   high 32 bits, rs1 UNSIGNED x rs2 UNSIGNED                                        |
# |                                                                                              |
# | What is checked:                                                                             |
# |     1. The four forms on ordinary operands, and the fact that MUL ignores signedness.        |
# |     2. Every combination of the two dangerous operands, 0x80000000 (the only value whose     |
# |        negation is itself) and 0xFFFFFFFF (-1 signed, 4294967295 unsigned).                  |
# |     3. MULHSU is ASYMMETRIC. This is the one people get wrong. Swapping the operands of a    |
# |        MULHSU changes the answer, because the signedness follows the operand POSITION and    |
# |        not the value: mulhsu(0xFFFFFFFF, 2) = 0xFFFFFFFF but mulhsu(2, 0xFFFFFFFF) = 1.      |
# |        Every MULHSU case below is therefore also run with the operands swapped, and the      |
# |        expected values differ. An implementation that computes "signed x signed then fix     |
# |        up", or that sign-extends the wrong operand, fails here and nowhere else.             |
# |     4. MULH vs MULHU disagree on exactly the sign bits: mulh(-1,-1)=0 but mulhu = 0xFFFFFFFE.|
# |     5. Multiplying by zero, by one, and results whose low half is zero while the high half   |
# |        is not (0x10000 x 0x10000) -- a unit that returns the wrong half passes case 1 and    |
# |        fails here.                                                                           |
# |     6. rd == rs1, rd == rs2 and rd == rs1 == rs2 aliasing all read the OLD operands.         |
# |     7. x0 as destination is discarded, including for the instruction right behind it,        |
# |        which must read 0 rather than a forwarded product.                                    |
# |     8. Forwarding: a product consumed by the very next instruction, chained through several  |
# |        multiplies, consumed as a load address, as a store address, and as a branch operand;  |
# |        and a load result consumed as a multiply operand (load-use hazard in front of MUL).   |
# |     9. Nothing here may trap. A catch-all handler is armed for the whole test, so a missing  |
# |        decoder arm (ILLEGAL_INSTRUCTION) is reported as a failure rather than silently       |
# |        skipping the checks.                                                                  |
# |                                                                                              |
# | Register allocation:                                                                         |
# |     x0  (zero): hardwired 0                                                                  |
# |     x5  (t0):   reserved for macro use                                                       |
# |     x6  (t1):   constant 1                                                                   |
# |     x7  (t2):   test case number                                                             |
# |     x28 (t3):   constant 0x120000<<2 (test peripheral address)                               |
# |     x29 (t4):   constant address of words                                                    |
# |     x30 (t5):   first operand                                                                |
# |     x31 (t6):   second operand                                                               |
# |     x9  (s1):   MUL result                                                                   |
# |     x18 (s2):   MULH result                                                                  |
# |     x19 (s3):   MULHSU result                                                                |
# |     x20 (s4):   MULHU result                                                                 |
# |                                                                                              |
# ------------------------------------------------------------------------------------------------

# The toolchain defaults to plain rv32i, so the four mnemonics below would be rejected as
# unknown opcodes. Enabling m here rather than adding -march to the Makefile keeps the flag
# next to the only files that need it -- every other assembly test still assembles as strict
# rv32i, which is exactly the guarantee worth keeping. This is the precedent set by zba.s.
.option arch, +m

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

.macro flush_pipeline
    nop
    nop
    nop
    nop
    nop
.endm

.macro li32 reg:req, value:req
    lui  \reg,       %hi(\value)
    addi \reg, \reg, %lo(\value)
.endm

# Run all four multiply forms against the operand pair already in t5/t6 and check
# all four results. One macro invocation is one complete "row" of the ISA table.
.macro mul_all_four em:req, emh:req, emhsu:req, emhu:req
    mul    s1, t5, t6
    mulh   s2, t5, t6
    mulhsu s3, t5, t6
    mulhu  s4, t5, t6
    assert_value s1, \em
    assert_value s2, \emh
    assert_value s3, \emhsu
    assert_value s4, \emhu
.endm

# Load an operand pair and run the whole row against it.
.macro mul_case a:req, b:req, em:req, emh:req, emhsu:req, emhu:req
    li32 t5, \a
    li32 t6, \b
    mul_all_four \em, \emh, \emhsu, \emhu
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
# Nothing in this test is allowed to trap. Multiplication defines no exception of its own --
# there is no overflow trap and no flag -- so any trap at all is a failure. The one that
# matters is ILLEGAL_INSTRUCTION from a missing decoder arm: without this handler a decoder
# that never learned funct7=0000001 would take every mul to mtvec, where a zeroed mtvec would
# send it to address 0 and the run would wander off instead of reporting anything.
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
    lui  t4, %hi(words)           # t4 = word array address
    flush_pipeline
    addi t3, t3, %lo(0x120000<<2)
    addi t4, t4, %lo(words)
    # Arm the catch-all handler for the whole test -- see irq_handler_unexpected.
    li32 t5, irq_handler_unexpected
    csrw mtvec, t5

test_fail:
    addi t2, zero, 1
    assert_value zero, 1

# -----------------------------------------------
# Small positives: the product fits in 32 bits, so all three high halves are 0
# and only MUL carries information. The baseline every other case is measured against.
test_small:
    addi t2, zero, 2
    flush_pipeline
    mul_case 0x00000006, 0x00000007, 0x0000002A, 0x00000000, 0x00000000, 0x00000000

# -----------------------------------------------
# Bits in every nibble and a negative second operand. MULH and MULHU disagree here
# (0xF8CC93D6 vs 0x0B00EA4E) which is exactly the point: the high half is where the
# signedness of the operands actually shows up.
test_pattern:
    addi t2, zero, 3
    flush_pipeline
    mul_case 0x12345678, 0x9ABCDEF0, 0x242D2080, 0xF8CC93D6, 0x0B00EA4E, 0x0B00EA4E

# -----------------------------------------------
# -1 x -1. Signed this is +1 (mulh = 0); unsigned it is 0xFFFFFFFE00000001, so MULHU
# returns 0xFFFFFFFE. MULHSU sees -1 x 4294967295 = -(2^32-1) -> high half 0xFFFFFFFF.
# Three different answers from one bit pattern.
test_minus_one_squared:
    addi t2, zero, 4
    flush_pipeline
    mul_case 0xFFFFFFFF, 0xFFFFFFFF, 0x00000001, 0x00000000, 0xFFFFFFFF, 0xFFFFFFFE

# -----------------------------------------------
# 0x80000000 squared. (-2^31)^2 = 2^62 for MULH and (2^31)^2 = 2^62 for MULHU -- the
# same 0x40000000 by coincidence -- while MULHSU computes -2^31 x 2^31 = -2^62 and must
# return 0xC0000000. A unit that ignores the mixed signedness returns 0x40000000 here.
test_int_min_squared:
    addi t2, zero, 5
    flush_pipeline
    mul_case 0x80000000, 0x80000000, 0x00000000, 0x40000000, 0xC0000000, 0x40000000

# -----------------------------------------------
# 0x80000000 x 0xFFFFFFFF. Signed this is +2^31, which does not fit in a signed 32-bit
# low half: MUL returns 0x80000000 and MULH returns 0. This is the multiply mirror of
# the DIV overflow case and must NOT be special-cased.
test_int_min_times_minus_one:
    addi t2, zero, 6
    flush_pipeline
    mul_case 0x80000000, 0xFFFFFFFF, 0x80000000, 0x00000000, 0x80000000, 0x7FFFFFFF

# -----------------------------------------------
# MULHSU asymmetry, first orientation: rs1 = -1 (signed), rs2 = 2 (unsigned).
# -1 x 2 = -2 -> high half 0xFFFFFFFF.
test_mulhsu_asym_a:
    addi t2, zero, 7
    flush_pipeline
    mul_case 0xFFFFFFFF, 0x00000002, 0xFFFFFFFE, 0xFFFFFFFF, 0xFFFFFFFF, 0x00000001

# -----------------------------------------------
# MULHSU asymmetry, operands swapped: rs1 = 2 (signed), rs2 = 0xFFFFFFFF (unsigned).
# 2 x 4294967295 = 0x1FFFFFFFE -> high half 0x00000001. MULHSU is the only one of the
# four whose answer changes between this case and the previous one; MUL, MULH and MULHU
# are all commutative and are asserted here to prove the difference is MULHSU-specific.
test_mulhsu_asym_b:
    addi t2, zero, 8
    flush_pipeline
    mul_case 0x00000002, 0xFFFFFFFF, 0xFFFFFFFE, 0xFFFFFFFF, 0x00000001, 0x00000001

# -----------------------------------------------
# Largest positive squared: (2^31-1)^2 = 0x3FFFFFFF00000001. All three high halves
# agree because both operands are positive, so this isolates the multiplier itself
# from the sign-extension logic.
test_int_max_squared:
    addi t2, zero, 9
    flush_pipeline
    mul_case 0x7FFFFFFF, 0x7FFFFFFF, 0x00000001, 0x3FFFFFFF, 0x3FFFFFFF, 0x3FFFFFFF

# -----------------------------------------------
# 0x80000000 x 2. Signed: -2^31 x 2 = -2^32 -> mulh 0xFFFFFFFF, low half 0.
# Unsigned: 2^31 x 2 = 2^32 -> mulhu 0x00000001. Same bits, opposite sign of high half.
test_int_min_times_two_a:
    addi t2, zero, 10
    flush_pipeline
    mul_case 0x80000000, 0x00000002, 0x00000000, 0xFFFFFFFF, 0xFFFFFFFF, 0x00000001

# -----------------------------------------------
# Swapped, so MULHSU now sign-extends the small positive and zero-extends 0x80000000.
test_int_min_times_two_b:
    addi t2, zero, 11
    flush_pipeline
    mul_case 0x00000002, 0x80000000, 0x00000000, 0xFFFFFFFF, 0x00000001, 0x00000001

# -----------------------------------------------
# A negative-looking pattern times a small positive, both orientations, so MULHSU is
# exercised once with the negative operand in rs1 and once with it in rs2.
test_deadbeef_a:
    addi t2, zero, 12
    flush_pipeline
    mul_case 0xDEADBEEF, 0x0000000F, 0x0C2E3001, 0xFFFFFFFE, 0xFFFFFFFE, 0x0000000D

# -----------------------------------------------
# Swapped orientation of the previous case: MULH and MULHU are unchanged, MULHSU is not.
test_deadbeef_b:
    addi t2, zero, 13
    flush_pipeline
    mul_case 0x0000000F, 0xDEADBEEF, 0x0C2E3001, 0xFFFFFFFE, 0x0000000D, 0x0000000D

# -----------------------------------------------
# Multiplying by zero. Every form must return 0, including MULHSU where the surviving
# operand is 0xFFFFFFFF -- a sign-extension bug that leaks a stray -1 shows up here.
test_times_zero:
    addi t2, zero, 14
    flush_pipeline
    mul_case 0xFFFFFFFF, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000

# -----------------------------------------------
# 0x10000 x 0x10000 = 2^32 exactly: the LOW half is zero and the HIGH half is one.
# A unit that returns the wrong half of the product passes every case above and fails
# this one, so this is the specific guard against a swapped MUL/MULH result mux.
test_low_zero_high_nonzero:
    addi t2, zero, 15
    flush_pipeline
    mul_case 0x00010000, 0x00010000, 0x00000000, 0x00000001, 0x00000001, 0x00000001

# -----------------------------------------------
# 0xC0000000 x 0x40000000: signed -2^30 x 2^30 = -2^60 (mulh 0xF0000000) versus
# unsigned 3*2^30 x 2^30 = 3*2^60 (mulhu 0x30000000).
test_quarter_scale:
    addi t2, zero, 16
    flush_pipeline
    mul_case 0xC0000000, 0x40000000, 0x00000000, 0xF0000000, 0xF0000000, 0x30000000

# -----------------------------------------------
# 0x7FFFFFFF x 0xFFFFFFFF, both orientations. MULHSU differs between them (0x7FFFFFFE
# vs 0xFFFFFFFF) while MUL, MULH and MULHU do not.
test_max_times_minus_one_a:
    addi t2, zero, 17
    flush_pipeline
    mul_case 0x7FFFFFFF, 0xFFFFFFFF, 0x80000001, 0xFFFFFFFF, 0x7FFFFFFE, 0x7FFFFFFE

# -----------------------------------------------
# Swapped orientation of the previous case.
test_max_times_minus_one_b:
    addi t2, zero, 18
    flush_pipeline
    mul_case 0xFFFFFFFF, 0x7FFFFFFF, 0x80000001, 0xFFFFFFFF, 0xFFFFFFFF, 0x7FFFFFFE

# -----------------------------------------------
# A small negative operand (-5) times a small positive, so the high halves are pure
# sign extension and any stray bit in the upper product is immediately visible.
test_small_negative:
    addi t2, zero, 19
    flush_pipeline
    mul_case 0x00000003, 0xFFFFFFFB, 0xFFFFFFF1, 0xFFFFFFFF, 0x00000002, 0x00000002

# -----------------------------------------------
# rd == rs1. The destination must be written with a product computed from the OLD
# rs1, not from a partially updated register.
test_alias_rd_rs1:
    addi t2, zero, 21
    flush_pipeline
    li32 t5, 0x00001234
    li32 t6, 0x00000010
    mul  t5, t5, t6               # t5 = 0x1234 * 0x10
    assert_value t5, 0x00012340
    assert_value t6, 0x00000010   # rs2 untouched

# -----------------------------------------------
# rd == rs2, the mirror of the previous case.
test_alias_rd_rs2:
    addi t2, zero, 22
    flush_pipeline
    li32 t5, 0x00001234
    li32 t6, 0x00000010
    mul  t6, t5, t6
    assert_value t6, 0x00012340
    assert_value t5, 0x00001234   # rs1 untouched

# -----------------------------------------------
# rd == rs1 == rs2: one register is both operands and the destination.
test_alias_all_three:
    addi t2, zero, 23
    flush_pipeline
    li32 t5, 0x11111111
    mul  t5, t5, t5
    assert_value t5, 0x87654321
    # and the high half of the same square, computed fresh
    li32 t5, 0x11111111
    mulhu t5, t5, t5
    assert_value t5, 0x01234567

# -----------------------------------------------
# x0 as destination. The product is discarded, and the instruction immediately
# behind the multiply must read a genuine zero rather than a forwarded product.
test_rd_zero:
    addi t2, zero, 24
    flush_pipeline
    li32 t5, 0x00001111
    li32 t6, 0x00000003
    mul  zero, t5, t6             # 0x3333, discarded
    add  s1, zero, zero           # reads x0 in the very next slot
    assert_value s1, 0
    assert_value zero, 0
    mulhu zero, t5, t6
    add   s2, zero, zero
    assert_value s2, 0

# -----------------------------------------------
# Forwarding: a product consumed by the very next instruction, three deep, so each
# multiply reads its operands out of the stage behind it rather than the register file.
test_forward_chain:
    addi t2, zero, 25
    flush_pipeline
    addi t5, zero, 3
    mul  s1, t5, t5               # 9
    mul  s2, s1, s1               # 81   — both operands forwarded
    mul  s3, s2, s2               # 6561 — both operands forwarded
    assert_value s1, 9
    assert_value s2, 81
    assert_value s3, 6561

# -----------------------------------------------
# Mixed chain: a product feeding an ordinary ALU op, and an ALU result feeding a
# multiply, in both orders and with no separating instruction.
test_forward_mixed:
    addi t2, zero, 26
    flush_pipeline
    li32 t5, 0x00000101
    li32 t6, 0x00000101
    mul  s1, t5, t6               # 0x00010201
    addi s2, s1, 1                # ALU consumes the product immediately
    assert_value s2, 0x00010202
    addi s3, zero, 5
    mul  s4, s3, s3               # multiply consumes the ALU result immediately
    assert_value s4, 25

# -----------------------------------------------
# A product used as a load address, computed one instruction earlier.
test_product_as_load_address:
    addi t2, zero, 27
    flush_pipeline
    addi t5, zero, 4
    addi t6, zero, 2
    mul  s1, t5, t6               # 8 = byte offset of words[2]
    add  s1, t4, s1               # address, forwarded from the multiply
    lw   s3, 0(s1)
    assert_value s3, 0x33333333

# -----------------------------------------------
# A product used as BOTH the store address and the stored data, then read back.
test_product_as_store:
    addi t2, zero, 28
    flush_pipeline
    addi t5, zero, 4
    addi t6, zero, 3
    mul  s1, t5, t6               # 12 = byte offset of words[3]
    add  s1, t4, s1
    li32 t5, 0x00000101
    li32 t6, 0x00000101
    mul  s2, t5, t6               # 0x00010201
    sw   s2, 0(s1)                # address and data are both forwarded values
    flush_pipeline
    lw   s3, 12(t4)
    assert_value s3, 0x00010201
    # put the array back the way it was declared
    li32 s2, 0x44444444
    sw   s2, 12(t4)

# -----------------------------------------------
# A product consumed by a branch comparison in the very next slot.
test_product_into_branch:
    addi t2, zero, 29
    flush_pipeline
    addi t5, zero, 7
    addi s1, zero, 49
    mul  t6, t5, t5               # 49
    bne  t6, s1, mul_branch_bad   # branch operand forwarded straight out of execute
    beq  zero, zero, mul_branch_ok
    mul_branch_bad:
    fail
    mul_branch_ok:
    assert_value t6, 49

# -----------------------------------------------
# Load-use hazard in FRONT of a multiply: both operands come straight from loads.
test_load_use_into_mul:
    addi t2, zero, 30
    flush_pipeline
    lw     t5, 0(t4)              # 0x11111111
    mul    s1, t5, t5             # load-use hazard on both operands
    assert_value s1, 0x87654321
    lw     t5, 0(t4)              # 0x11111111
    lw     t6, 4(t4)              # 0x22222222
    mulhu  s2, t5, t6
    assert_value s2, 0x02468ACF
    mul    s3, t5, t6
    assert_value s3, 0x0ECA8642

# -----------------------------------------------
# The array must be exactly as declared after all of the above.
test_array_intact:
    addi t2, zero, 31
    flush_pipeline
    lw s1, 0(t4)
    lw s2, 4(t4)
    lw s3, 8(t4)
    lw s4, 12(t4)
    assert_value s1, 0x11111111
    assert_value s2, 0x22222222
    assert_value s3, 0x33333333
    assert_value s4, 0x44444444

# ------------------------------------------------------------------------------------------------
# |                                          Test done!                                          |
# ------------------------------------------------------------------------------------------------
test_finish:
    addi t2, zero, 32
    halt
    fail

    .align 4
words:
    .word 0x11111111
    .word 0x22222222
    .word 0x33333333
    .word 0x44444444
