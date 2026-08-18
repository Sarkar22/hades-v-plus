# Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
# Embedded Architectures & Systems Group, Graz University of Technology
# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: div.s
#
# ------------------------------------------------------------------------------------------------
# |                                                                                              |
# | M extension, divide half: DIV / DIVU / REM / REMU.                                           |
# | If everything runs correctly, the first register of the peripheral test module               |
# | should always be zero, except during the first test, which checks the assert macro itself.   |
# | Note: This condition is necessary, but not sufficient to prove correctness.                  |
# |                                                                                              |
# | THE THING THAT MAKES DIVISION DIFFERENT: RISC-V NEVER TRAPS ON A DIVIDE.                      |
# | There is no divide-by-zero exception and no overflow exception. Every input pair, including   |
# | the two that have no mathematical answer, produces a defined 32-bit result:                   |
# |                                                                                              |
# |     rs2 == 0                     DIV  -> -1 (0xFFFFFFFF)      REM  -> rs1 unchanged           |
# |                                  DIVU -> 0xFFFFFFFF (2^32-1)  REMU -> rs1 unchanged           |
# |     rs1 == -2^31 and rs2 == -1   DIV  -> 0x80000000 (wraps)   REM  -> 0                       |
# |                                  (DIVU/REMU cannot overflow and get the ordinary answer:      |
# |                                   0x80000000 / 0xFFFFFFFF = 0 remainder 0x80000000)           |
# |                                                                                              |
# | A catch-all trap handler is armed for the whole test, so if any of these DID trap the run     |
# | reports a failure instead of quietly taking the exception path.                               |
# |                                                                                              |
# | ROUNDING IS TOWARD ZERO, which fixes the sign of the remainder to the sign of the DIVIDEND:  |
# |      7 /  2 =  3 r  1        -7 /  2 = -3 r -1                                                |
# |      7 / -2 = -3 r  1        -7 / -2 =  3 r -1                                                |
# | All four quadrants are checked. An implementation that floors instead of truncating gets      |
# | quadrants 2 and 3 wrong; one that takes the remainder's sign from the divisor gets 3 and 4    |
# | wrong.                                                                                        |
# |                                                                                              |
# | What is checked:                                                                             |
# |     1. All four quadrants of signed division, quotient and remainder.                        |
# |     2. Divide by zero for all four instructions, over several dividends including 0,          |
# |        0x80000000 and 0xFFFFFFFF.                                                             |
# |     3. The -2^31 / -1 overflow for DIV and REM, and the fact that DIVU/REMU on the same       |
# |        bit patterns are ordinary unsigned divisions with completely different answers.        |
# |     4. Signed and unsigned disagreeing on the same bits (0xFFFFFFFF / 2 is 0 signed but       |
# |        0x7FFFFFFF unsigned).                                                                  |
# |     5. Exact division, divisor larger than dividend, dividend zero, powers of two.            |
# |     6. rd == rs1, rd == rs2 and rd == rs1 == rs2 aliasing.                                    |
# |     7. x0 as destination is discarded, and the instruction behind it reads a real zero.       |
# |     8. Back-to-back DEPENDENT divides -- the second cannot start until the first retires,     |
# |        so this exercises the execute stall and the forwarding handshake together.             |
# |     9. A quotient used as a load address and as a store address.                              |
# |    10. A divide immediately in front of a taken branch, and in front of a not-taken branch.   |
# |    11. A divide INTERRUPTED by an external interrupt, swept across the whole 34-cycle         |
# |        window so the interrupt lands before, during and after the division. The divide is     |
# |        abandoned when the pipeline is flushed and re-executed after MRET, so the result must  |
# |        be identical every time and the interrupt must be taken exactly once per arming.       |
# |        This is the case that catches a divider which holds STALL through a flush: the core    |
# |        would simply hang and the run would end in "Simulation timeout!".                      |
# |                                                                                              |
# | Register allocation:                                                                         |
# |     x0  (zero): hardwired 0                                                                  |
# |     x5  (t0):   reserved for macro use                                                       |
# |     x6  (t1):   constant 1                                                                   |
# |     x7  (t2):   test case number                                                             |
# |     x28 (t3):   constant 0x120000<<2 (test peripheral address)                               |
# |     x29 (t4):   constant address of words                                                    |
# |     x30 (t5):   dividend                                                                     |
# |     x31 (t6):   divisor                                                                      |
# |     x9  (s1):   DIV result                                                                   |
# |     x18 (s2):   REM result                                                                   |
# |     x19 (s3):   DIVU result                                                                  |
# |     x20 (s4):   REMU result                                                                  |
# |     x21 (s5):   reserved for the interrupt handler                                           |
# |     x22 (s6):   reserved for the interrupt handler                                           |
# |                                                                                              |
# ------------------------------------------------------------------------------------------------

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

.macro li32 reg:req, value:req
    lui  \reg,       %hi(\value)
    addi \reg, \reg, %lo(\value)
.endm

# Run all four division forms against the operand pair already in t5/t6 and check
# all four results. One macro invocation is one complete row of the ISA table, and
# the four instructions are issued back to back so each one also exercises starting
# the divider immediately after the previous one retired.
.macro div_all_four eq:req, er:req, equ:req, eru:req
    div  s1, t5, t6
    rem  s2, t5, t6
    divu s3, t5, t6
    remu s4, t5, t6
    assert_value s1, \eq
    assert_value s2, \er
    assert_value s3, \equ
    assert_value s4, \eru
.endm

.macro div_case a:req, b:req, eq:req, er:req, equ:req, eru:req
    li32 t5, \a
    li32 t6, \b
    div_all_four \eq, \er, \equ, \eru
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

# Catch-all trap handler for the arithmetic part of the test.
# Nothing here is allowed to trap. Division by zero and signed overflow are the two
# inputs a naive implementation is most likely to turn into an exception, and RISC-V
# says both must produce a value instead -- so an unexpected trap is exactly the bug
# this handler exists to report.
irq_handler_unexpected:
    fail
    halt
    # jump to reset if this code snipped reached
    flush_pipeline
    beq  zero, zero, __reset

# Handler for the interrupt-during-divide sweep.
# Deliberately touches ONLY s5 and s6, never t0: an interrupt can land anywhere,
# including between the sub and the sw of an assert_equal, and clobbering t0 there
# would turn a passing assert into a spurious failure.
irq_handler_div_interrupt:
    lui  s5,     %hi(0x120000<<2)
    addi s5, s5, %lo(0x120000<<2)
    sw   zero, 4(s5)              # write 0 to the down-counter: deassert the interrupt
    lui  s5,     %hi(interrupt_var)
    addi s5, s5, %lo(interrupt_var)
    lw   s6, 0(s5)
    addi s6, s6, 1                # count this interrupt
    sw   s6, 0(s5)
    mret

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
    # Arm the catch-all handler for the arithmetic part of the test.
    li32 t5, irq_handler_unexpected
    csrw mtvec, t5

test_fail:
    addi t2, zero, 1
    assert_value zero, 1

# -----------------------------------------------
# Quadrant 1: +7 / +2 = +3 remainder +1. The baseline the other three are read against.
test_quadrant_pp:
    addi t2, zero, 2
    flush_pipeline
    div_case 0x00000007, 0x00000002, 0x00000003, 0x00000001, 0x00000003, 0x00000001

# -----------------------------------------------
# Quadrant 2: -7 / +2. Truncating toward zero gives -3 remainder -1. A floor-divide
# implementation gives -4 remainder +1 and fails here.
test_quadrant_np:
    addi t2, zero, 3
    flush_pipeline
    div_case 0xFFFFFFF9, 0x00000002, 0xFFFFFFFD, 0xFFFFFFFF, 0x7FFFFFFC, 0x00000001

# -----------------------------------------------
# Quadrant 3: +7 / -2 = -3 remainder +1. The remainder follows the DIVIDEND, so it is
# positive even though the divisor is negative. Taking the sign from the divisor gives -1.
test_quadrant_pn:
    addi t2, zero, 4
    flush_pipeline
    div_case 0x00000007, 0xFFFFFFFE, 0xFFFFFFFD, 0x00000001, 0x00000000, 0x00000007

# -----------------------------------------------
# Quadrant 4: -7 / -2 = +3 remainder -1. Both operands negative: the quotient is
# positive and the remainder is negative, again following the dividend.
test_quadrant_nn:
    addi t2, zero, 5
    flush_pipeline
    div_case 0xFFFFFFF9, 0xFFFFFFFE, 0x00000003, 0xFFFFFFFF, 0x00000000, 0xFFFFFFF9

# -----------------------------------------------
# Divide by zero, dividend 0. DIV/DIVU return all ones, REM/REMU return the dividend.
test_div_zero_by_zero:
    addi t2, zero, 6
    flush_pipeline
    div_case 0x00000000, 0x00000000, 0xFFFFFFFF, 0x00000000, 0xFFFFFFFF, 0x00000000

# -----------------------------------------------
# Divide by zero, dividend 1.
test_div_one_by_zero:
    addi t2, zero, 7
    flush_pipeline
    div_case 0x00000001, 0x00000000, 0xFFFFFFFF, 0x00000001, 0xFFFFFFFF, 0x00000001

# -----------------------------------------------
# Divide by zero, dividend 0xFFFFFFFF -- the case where 'return the dividend' and
# 'return all ones' happen to coincide for every one of the four instructions.
test_div_minus_one_by_zero:
    addi t2, zero, 8
    flush_pipeline
    div_case 0xFFFFFFFF, 0x00000000, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF

# -----------------------------------------------
# Divide by zero, dividend 0x80000000. REM/REMU must hand back 0x80000000 untouched.
test_div_int_min_by_zero:
    addi t2, zero, 9
    flush_pipeline
    div_case 0x80000000, 0x00000000, 0xFFFFFFFF, 0x80000000, 0xFFFFFFFF, 0x80000000

# -----------------------------------------------
# Divide by zero, dividend 0x7FFFFFFF.
test_div_int_max_by_zero:
    addi t2, zero, 10
    flush_pipeline
    div_case 0x7FFFFFFF, 0x00000000, 0xFFFFFFFF, 0x7FFFFFFF, 0xFFFFFFFF, 0x7FFFFFFF

# -----------------------------------------------
# Divide by zero, an arbitrary pattern, to show the remainder really is a copy of rs1
# and not a masked or shifted version of it.
test_div_pattern_by_zero:
    addi t2, zero, 11
    flush_pipeline
    div_case 0xDEADBEEF, 0x00000000, 0xFFFFFFFF, 0xDEADBEEF, 0xFFFFFFFF, 0xDEADBEEF

# -----------------------------------------------
# THE SIGNED OVERFLOW CASE: -2^31 / -1. The true quotient +2^31 is not representable,
# so DIV wraps to 0x80000000 and REM is 0. DIVU and REMU on the same bits are an
# ordinary unsigned divide, 2^31 / (2^32-1) = 0 remainder 2^31, so all four answers
# differ -- an implementation that special-cases the bit patterns without checking
# signedness corrupts DIVU/REMU here.
test_overflow:
    addi t2, zero, 12
    flush_pipeline
    div_case 0x80000000, 0xFFFFFFFF, 0x80000000, 0x00000000, 0x00000000, 0x80000000

# -----------------------------------------------
# -2^31 / 1: the quotient is representable, so nothing special happens.
test_int_min_by_one:
    addi t2, zero, 13
    flush_pipeline
    div_case 0x80000000, 0x00000001, 0x80000000, 0x00000000, 0x80000000, 0x00000000

# -----------------------------------------------
# -2^31 / 2 = -2^30 exactly, remainder 0.
test_int_min_by_two:
    addi t2, zero, 14
    flush_pipeline
    div_case 0x80000000, 0x00000002, 0xC0000000, 0x00000000, 0x40000000, 0x00000000

# -----------------------------------------------
# 2^31-1 / -1 = -(2^31-1). Representable, so this is NOT the overflow case, and it is
# here to make sure the overflow early-out is not triggered by rs2 == -1 alone.
test_int_max_by_minus_one:
    addi t2, zero, 15
    flush_pipeline
    div_case 0x7FFFFFFF, 0xFFFFFFFF, 0x80000001, 0x00000000, 0x00000000, 0x7FFFFFFF

# -----------------------------------------------
# (-2^31 + 1) / -1 = 2^31-1. Not the overflow case either: the early-out must test
# rs1 == 0x80000000 exactly.
test_int_min_plus_one_by_minus_one:
    addi t2, zero, 16
    flush_pipeline
    div_case 0x80000001, 0xFFFFFFFF, 0x7FFFFFFF, 0x00000000, 0x00000000, 0x80000001

# -----------------------------------------------
# The same bits read two ways: signed -1 / 2 truncates to 0 remainder -1, while
# unsigned 4294967295 / 2 is 0x7FFFFFFF remainder 1.
test_signed_vs_unsigned_small:
    addi t2, zero, 17
    flush_pipeline
    div_case 0xFFFFFFFF, 0x00000002, 0x00000000, 0xFFFFFFFF, 0x7FFFFFFF, 0x00000001

# -----------------------------------------------
# -1 / -1 = 1 remainder 0 signed; 4294967295 / 4294967295 = 1 remainder 0 unsigned.
# The one case where signed and unsigned agree on operands that both have bit 31 set.
test_minus_one_by_minus_one:
    addi t2, zero, 18
    flush_pipeline
    div_case 0xFFFFFFFF, 0xFFFFFFFF, 0x00000001, 0x00000000, 0x00000001, 0x00000000

# -----------------------------------------------
# -1 / 2^31-1 is 0 signed but 2 remainder 1 unsigned.
test_minus_one_by_int_max:
    addi t2, zero, 19
    flush_pipeline
    div_case 0xFFFFFFFF, 0x7FFFFFFF, 0x00000000, 0xFFFFFFFF, 0x00000002, 0x00000001

# -----------------------------------------------
# -2 / 3 = 0 remainder -2 signed; unsigned it is a full-width quotient 0x55555554.
# The unsigned answer needs all 32 quotient bits, so a divider that iterates too few
# times fails here and passes every small case above.
test_minus_two_by_three:
    addi t2, zero, 20
    flush_pipeline
    div_case 0xFFFFFFFE, 0x00000003, 0x00000000, 0xFFFFFFFE, 0x55555554, 0x00000002

# -----------------------------------------------
# -6 / 3 = -2 remainder 0: an exact signed division with a negative dividend, so the
# remainder's sign fix-up is applied to a zero and must not turn it into anything else.
test_minus_six_by_three:
    addi t2, zero, 21
    flush_pipeline
    div_case 0xFFFFFFFA, 0x00000003, 0xFFFFFFFE, 0x00000000, 0x55555553, 0x00000001

# -----------------------------------------------
# Exact division, no remainder.
test_exact:
    addi t2, zero, 22
    flush_pipeline
    div_case 0x00000064, 0x0000000A, 0x0000000A, 0x00000000, 0x0000000A, 0x00000000

# -----------------------------------------------
# 100 / 7 = 14 remainder 2.
test_inexact:
    addi t2, zero, 23
    flush_pipeline
    div_case 0x00000064, 0x00000007, 0x0000000E, 0x00000002, 0x0000000E, 0x00000002

# -----------------------------------------------
# Divisor larger than dividend: quotient 0, remainder = dividend.
test_divisor_bigger:
    addi t2, zero, 24
    flush_pipeline
    div_case 0x00000001, 0x00000064, 0x00000000, 0x00000001, 0x00000000, 0x00000001

# -----------------------------------------------
# Dividend zero: quotient 0, remainder 0, for a non-zero divisor.
test_dividend_zero:
    addi t2, zero, 25
    flush_pipeline
    div_case 0x00000000, 0x00000005, 0x00000000, 0x00000000, 0x00000000, 0x00000000

# -----------------------------------------------
# Division by a power of two, which a synthesiser is entitled to strength-reduce
# for constants but which the hardware divider must do the long way here.
test_power_of_two:
    addi t2, zero, 26
    flush_pipeline
    div_case 0x12345678, 0x00001000, 0x00012345, 0x00000678, 0x00012345, 0x00000678

# -----------------------------------------------
# A wide pattern with a 16-bit divisor: signed and unsigned quotients differ in every bit.
test_wide_pattern:
    addi t2, zero, 27
    flush_pipeline
    div_case 0xDEADBEEF, 0x0000FFFF, 0xFFFFDEAE, 0xFFFF9D9D, 0x0000DEAE, 0x00009D9D

# -----------------------------------------------
# rd == rs1: the quotient must be computed from the OLD rs1.
test_alias_rd_rs1:
    addi t2, zero, 28
    flush_pipeline
    li32 t5, 0x00000064           # 100
    li32 t6, 0x00000007           # 7
    div  t5, t5, t6
    assert_value t5, 0x0000000E   # 14
    assert_value t6, 0x00000007   # rs2 untouched

# -----------------------------------------------
# rd == rs2, the mirror of the previous case, using REM so the sign fix-up path
# is the one reading the aliased register.
test_alias_rd_rs2:
    addi t2, zero, 29
    flush_pipeline
    li32 t5, 0xFFFFFFF9           # -7
    li32 t6, 0x00000002
    rem  t6, t5, t6
    assert_value t6, 0xFFFFFFFF   # -1
    assert_value t5, 0xFFFFFFF9   # rs1 untouched

# -----------------------------------------------
# rd == rs1 == rs2: x / x is 1 remainder 0 for any non-zero x.
test_alias_all_three:
    addi t2, zero, 30
    flush_pipeline
    li32 t5, 0xDEADBEEF
    div  t5, t5, t5
    assert_value t5, 0x00000001
    li32 t5, 0xDEADBEEF
    rem  t5, t5, t5
    assert_value t5, 0x00000000

# -----------------------------------------------
# x0 as destination. The quotient is discarded and the instruction behind the
# divide must read a real zero, not a forwarded quotient — and it must not read
# it early, i.e. the stall must not let the following instruction slip past.
test_rd_zero:
    addi t2, zero, 31
    flush_pipeline
    li32 t5, 0x00000064
    li32 t6, 0x00000007
    div  zero, t5, t6             # 14, discarded
    add  s1, zero, zero
    assert_value s1, 0
    assert_value zero, 0
    rem  zero, t5, t6
    add  s2, zero, zero
    assert_value s2, 0
    # divide by zero into x0: the early-out path with a discarded destination
    div  zero, t5, zero
    add  s3, zero, zero
    assert_value s3, 0

# -----------------------------------------------
# Back-to-back DEPENDENT divides. The second cannot begin until the first has
# retired and forwarded its quotient, so this is the execute stall and the
# forwarding handshake being exercised together, three deep.
test_dependent_chain:
    addi t2, zero, 32
    flush_pipeline
    li32 t5, 0x000186A0           # 100000
    li32 t6, 0x0000000A           # 10
    div  s1, t5, t6               # 10000
    div  s2, s1, t6               # 1000  — dividend forwarded from the divide behind it
    div  s3, s2, t6               # 100
    div  s4, s3, t6               # 10
    assert_value s1, 10000
    assert_value s2, 1000
    assert_value s3, 100
    assert_value s4, 10

# -----------------------------------------------
# A divide whose DIVISOR is the result of the divide in front of it, which is the
# other half of the forwarding handshake.
test_dependent_divisor:
    addi t2, zero, 33
    flush_pipeline
    li32 t5, 0x00000064           # 100
    li32 t6, 0x00000019           # 25
    div  s1, t5, t6               # 4
    div  s2, t5, s1               # 100 / 4 = 25 — divisor forwarded
    rem  s3, t5, s1               # 0
    assert_value s1, 4
    assert_value s2, 25
    assert_value s3, 0

# -----------------------------------------------
# A divide feeding a multiply and a multiply feeding a divide, so the two halves
# of the M unit hand results to each other with no intervening instruction.
test_mul_div_interlock:
    addi t2, zero, 34
    flush_pipeline
    li32 t5, 0x00000064           # 100
    li32 t6, 0x00000007
    div  s1, t5, t6               # 14
    mul  s2, s1, s1               # 196 — multiply starts the cycle the divide retires
    assert_value s2, 196
    li32 t5, 0x0000000C
    li32 t6, 0x0000000C
    mul  s3, t5, t6               # 144
    div  s4, s3, t6               # 12 — divide starts the cycle the multiply retires
    assert_value s3, 144
    assert_value s4, 12

# -----------------------------------------------
# A quotient used as a load address, computed one instruction earlier.
test_quotient_as_load_address:
    addi t2, zero, 35
    flush_pipeline
    li32 t5, 0x00000020           # 32
    li32 t6, 0x00000004
    div  s1, t5, t6               # 8 = byte offset of words[2]
    add  s1, t4, s1               # address, forwarded straight out of the divide
    lw   s3, 0(s1)
    assert_value s3, 0x33333333
    # and with the address arithmetic folded into the load's own offset
    li32 t5, 0x0000000C
    li32 t6, 0x00000003
    div  s2, t5, t6               # 4
    add  s2, t4, s2
    lw   s4, 0(s2)
    assert_value s4, 0x22222222

# -----------------------------------------------
# A remainder used as BOTH the store address offset and the stored data.
test_quotient_as_store:
    addi t2, zero, 36
    flush_pipeline
    li32 t5, 0x0000001C           # 28
    li32 t6, 0x00000010           # 16
    rem  s1, t5, t6               # 12 = byte offset of words[3]
    add  s1, t4, s1
    li32 t5, 0x0007A120           # 500000
    li32 t6, 0x00000064           # 100
    div  s2, t5, t6               # 5000
    sw   s2, 0(s1)                # address and data are both forwarded values
    flush_pipeline
    lw   s3, 12(t4)
    assert_value s3, 5000
    # put the array back the way it was declared
    li32 s2, 0x44444444
    sw   s2, 12(t4)

# -----------------------------------------------
# A divide immediately in front of a TAKEN branch whose condition depends on it.
# The branch resolves in Execute the cycle after the divide finally retires, so
# this is the case where a stale forwarded operand would send the branch the
# wrong way.
test_divide_before_taken_branch:
    addi t2, zero, 37
    flush_pipeline
    li32 t5, 0x00000064           # 100
    li32 t6, 0x00000007
    addi s2, zero, 14
    div  s1, t5, t6               # 14
    beq  s1, s2, div_branch_taken # must be taken, operand forwarded out of Execute
    fail
    div_branch_taken:
    assert_value s1, 14

# -----------------------------------------------
# The same shape with a NOT-taken branch, so a divider that left the branch
# comparing against a partial remainder is caught in both directions.
test_divide_before_not_taken_branch:
    addi t2, zero, 38
    flush_pipeline
    li32 t5, 0x00000064
    li32 t6, 0x00000007
    addi s2, zero, 14
    div  s1, t5, t6               # 14
    bne  s1, s2, div_branch_bad   # must NOT be taken
    beq  zero, zero, div_branch_ok
    div_branch_bad:
    fail
    div_branch_ok:
    assert_value s1, 14

# -----------------------------------------------
# A divide immediately in front of an unconditional jump, and one in the delay
# shadow of a taken branch (i.e. on the not-taken path) which must be discarded.
test_divide_and_jump:
    addi t2, zero, 39
    flush_pipeline
    li32 t5, 0x000003E8           # 1000
    li32 t6, 0x00000007
    div  s1, t5, t6               # 142
    beq  zero, zero, div_jump_target
    div  s1, t5, zero             # flushed: must never write s1
    div  s1, t5, t5               # flushed
    div_jump_target:
    assert_value s1, 142

# -----------------------------------------------
# A load-use hazard in FRONT of a divide: both operands come straight from loads,
# so Decode stalls for the load and then Execute stalls for the divide.
test_load_use_into_div:
    addi t2, zero, 40
    flush_pipeline
    lw     t5, 0(t4)              # 0x11111111
    lw     t6, 4(t4)              # 0x22222222
    divu   s1, t6, t5             # 2
    remu   s2, t6, t5             # 0
    assert_value s1, 2
    assert_value s2, 0
    lw     t5, 0(t4)
    divu   s3, t5, t5             # load-use on both operands of one divide
    assert_value s3, 1

# -----------------------------------------------
# The array must be exactly as declared after all of the above.
test_array_intact:
    addi t2, zero, 41
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
# |                          Interrupt landing on top of a divide                                |
# ------------------------------------------------------------------------------------------------
# A divide occupies Execute for 34 cycles. If an interrupt arrives during that window the
# pipeline is flushed from Writeback, the divide is ABANDONED, and it is re-executed when
# MRET returns to mepc. Two things have to hold for every arrival time:
#
#   * the core must not hang. A divider that keeps asserting its backwards STALL through the
#     JUMP would never let Decode and Fetch see the redirect, and the run would end in
#     "Simulation timeout!" rather than a failed assert.
#   * the answer must be identical whether or not the divide was interrupted, because the
#     abandoned attempt left no state behind.
#
# The arming delay is swept from before the divide to well past the end of it, so the
# interrupt lands at many different points of the 34-cycle window. Each arming must be taken
# exactly once, which the running counter checks.

.macro div_with_interrupt delay:req, count:req
    interrupt \delay
    li32 t5, 0xFFFFFFF9           # -7
    li32 t6, 0x00000002
    div  s1, t5, t6
    rem  s2, t5, t6
    divu s3, t5, t6
    # Let the interrupt land and the handler finish before touching t0-based macros.
    flush_pipeline
    flush_pipeline
    flush_pipeline
    flush_pipeline
    flush_pipeline
    flush_pipeline
    flush_pipeline
    flush_pipeline
    assert_value s1, 0xFFFFFFFD   # -3
    assert_value s2, 0xFFFFFFFF   # -1
    assert_value s3, 0x7FFFFFFC
    li32 s5, interrupt_var
    lw   s6, 0(s5)
    assert_value s6, \count
.endm

test_interrupt_during_divide:
    addi t2, zero, 42
    flush_pipeline
    # swap in the counting handler and zero the counter
    li32 t5, irq_handler_div_interrupt
    csrw mtvec, t5
    li32 s5, interrupt_var
    sw   zero, 0(s5)
    flush_pipeline
    # enable external interrupts (MIE.MEIE = bit 11, MSTATUS.MIE = bit 3)
    slli t5, t1, 11
    csrs mie, t5
    slli t5, t1, 3
    csrs mstatus, t5
    flush_pipeline

    div_with_interrupt 1,  1
    div_with_interrupt 2,  2
    div_with_interrupt 3,  3
    div_with_interrupt 4,  4
    div_with_interrupt 5,  5
    div_with_interrupt 6,  6
    div_with_interrupt 7,  7
    div_with_interrupt 8,  8
    div_with_interrupt 10, 9
    div_with_interrupt 12, 10
    div_with_interrupt 14, 11
    div_with_interrupt 16, 12
    div_with_interrupt 18, 13
    div_with_interrupt 20, 14
    div_with_interrupt 24, 15
    div_with_interrupt 28, 16
    div_with_interrupt 32, 17
    div_with_interrupt 36, 18
    div_with_interrupt 40, 19
    div_with_interrupt 44, 20
    div_with_interrupt 48, 21
    div_with_interrupt 56, 22

    # disable interrupts again and put the catch-all handler back
    slli t5, t1, 11
    csrc mie, t5
    slli t5, t1, 3
    csrc mstatus, t5
    flush_pipeline
    li32 t5, irq_handler_unexpected
    csrw mtvec, t5
    flush_pipeline

# -----------------------------------------------
# One more ordinary divide after all that, to show the unit is still healthy.
test_after_interrupts:
    addi t2, zero, 43
    flush_pipeline
    div_case 0x000003E8, 0x00000007, 0x0000008E, 0x00000006, 0x0000008E, 0x00000006

# ------------------------------------------------------------------------------------------------
# |                                          Test done!                                          |
# ------------------------------------------------------------------------------------------------
test_finish:
    addi t2, zero, 44
    halt
    fail

    .align 4
words:
    .word 0x11111111
    .word 0x22222222
    .word 0x33333333
    .word 0x44444444
interrupt_var:
    .word 0x00000000
