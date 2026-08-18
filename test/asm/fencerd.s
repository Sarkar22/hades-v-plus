# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: fencerd.s
#
# ------------------------------------------------------------------------------------------------
# |                                                                                              |
# | FENCE / FENCE.I RESERVED-rd-FIELD test.                                                      |
# |                                                                                              |
# | RISC-V unpriv. spec: the rd / rs1 (and for FENCE.I also imm) fields of FENCE and FENCE.I are  |
# | RESERVED. "For forward compatibility, base implementations shall IGNORE these fields."        |
# | A compiler never emits nonzero rd, but a hand-encoded .word can.                              |
# |                                                                                              |
# | This test hand-encodes a FENCE whose reserved rd field = x9 and whose reserved rs1 field and  |
# | imm[4:0] (which land in the rs1/rs2 decode positions) point at two registers holding known    |
# | values.  If the pipeline forwards a result for that bogus rd, a DEPENDENT instruction reading |
# | x9 will observe rs1+rs2 instead of the architectural x9.                                      |
# |                                                                                              |
# | Encodings used (verified with riscv32-unknown-elf-as):                                        |
# |   0x01FF048F = imm=0x01F | rs1=x30 | funct3=000 | rd=x9 | opcode=0001111  -> FENCE  , rd=x9   |
# |   0x01FF148F = imm=0x01F | rs1=x30 | funct3=001 | rd=x9 | opcode=0001111  -> FENCE.I, rd=x9   |
# |   imm[4:0]=0x1F lands in the rs2 decode position -> rs2 = x31.                                |
# |   Execute's ALU default arm for FENCE is ADD(rs1,rs2) = x30 + x31 = 0x111 + 0x222 = 0x333.    |
# |                                                                                              |
# | Register allocation:                                                                         |
# |     x0  (zero): hardwired 0                                                                  |
# |     x5  (t0):   reserved for macro use                                                       |
# |     x6  (t1):   constant 1                                                                   |
# |     x7  (t2):   test case number                                                             |
# |     x28 (t3):   constant 0x120000<<2 (test peripheral address)                               |
# |     x9  (s1):   VICTIM register named by the fence's reserved rd field, holds 0xABC          |
# |     x30 (t5):   fence rs1 field  -> 0x111                                                    |
# |     x31 (t6):   fence rs2 field  -> 0x222                                                    |
# |     x11 (a1):   destination of the dependent instruction (add a1, s1, zero)                  |
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

.macro flush_pipeline
    nop
    nop
    nop
    nop
    nop
.endm

# Set up the three operand registers used by every case below.
.macro setup_operands
    lui  s1, %hi(0xABC)
    addi s1, s1, %lo(0xABC)       # s1 (x9)  = 0xABC   <- architectural victim value
    lui  t5, %hi(0x111)
    addi t5, t5, %lo(0x111)       # t5 (x30) = 0x111   <- fence rs1 field
    lui  t6, %hi(0x222)
    addi t6, t6, %lo(0x222)       # t6 (x31) = 0x222   <- fence rs2 field
    addi a1, zero, 0              # a1 (x11) = 0       <- clear the observation register
    flush_pipeline
.endm

# Keep instruction distances deterministic: no linker relaxation of %hi/%lo pairs.
.option norelax

# ------------------------------------------------------------------------------------------------
# |                                          Test entry!                                         |
# ------------------------------------------------------------------------------------------------
.global __reset
__reset:

test_init:
    addi t1, zero, 1              # t1 = 1
    addi t2, zero, 0              # t2 = test case number
    lui  t3, %hi(0x120000<<2)     # t3 = peripheral test address
    flush_pipeline
    addi t3, t3, %lo(0x120000<<2)

# -----------------------------------------------
# Deliberate first failure: proves the assert macro and the test peripheral work.
test_fail:
    addi t2, zero, 1
    assert_value zero, 1

# -----------------------------------------------
# Test 2: FENCE with reserved rd = x9, dependent instruction at DISTANCE 1.
test_fence_rd_dist1:
    addi t2, zero, 2
    flush_pipeline
    setup_operands
    .word 0x01FF048F              # FENCE (rd=x9 RESERVED, rs1=x30, rs2-pos=x31)
    add  a1, s1, zero             # distance 1: reads x9
    flush_pipeline
    assert_value a1, 0xABC        # a1 must be the architectural x9
    assert_value s1, 0xABC        # regfile itself must be untouched

# -----------------------------------------------
# Test 3: FENCE with reserved rd = x9, dependent instruction at DISTANCE 2.
test_fence_rd_dist2:
    addi t2, zero, 3
    flush_pipeline
    setup_operands
    .word 0x01FF048F              # FENCE (rd=x9 RESERVED)
    nop
    add  a1, s1, zero             # distance 2: reads x9
    flush_pipeline
    assert_value a1, 0xABC
    assert_value s1, 0xABC

# -----------------------------------------------
# Test 4: FENCE with reserved rd = x9, dependent instruction at DISTANCE 3.
test_fence_rd_dist3:
    addi t2, zero, 4
    flush_pipeline
    setup_operands
    .word 0x01FF048F              # FENCE (rd=x9 RESERVED)
    nop
    nop
    add  a1, s1, zero             # distance 3: reads x9
    flush_pipeline
    assert_value a1, 0xABC
    assert_value s1, 0xABC

# -----------------------------------------------
# Test 5: FENCE.I with reserved rd = x9, dependent instruction at DISTANCE 1.
test_fencei_rd_dist1:
    addi t2, zero, 5
    flush_pipeline
    setup_operands
    .word 0x01FF148F              # FENCE.I (rd=x9 RESERVED, rs1=x30, rs2-pos=x31)
    add  a1, s1, zero             # distance 1: reads x9
    flush_pipeline
    assert_value a1, 0xABC
    assert_value s1, 0xABC

# -----------------------------------------------
# Test 6: FENCE.I with reserved rd = x9, dependent instruction at DISTANCE 2.
test_fencei_rd_dist2:
    addi t2, zero, 6
    flush_pipeline
    setup_operands
    .word 0x01FF148F              # FENCE.I (rd=x9 RESERVED)
    nop
    add  a1, s1, zero             # distance 2: reads x9
    flush_pipeline
    assert_value a1, 0xABC
    assert_value s1, 0xABC

# -----------------------------------------------
# Test 7: CONTROL — canonical 'fence rw,rw' (rd = 0). Must be clean today.
test_fence_canonical:
    addi t2, zero, 7
    flush_pipeline
    setup_operands
    fence rw, rw
    add  a1, s1, zero
    flush_pipeline
    assert_value a1, 0xABC
    assert_value s1, 0xABC

# -----------------------------------------------
# Test 8: CONTROL — canonical 'fence.i' (rd = 0). Must be clean today.
test_fencei_canonical:
    addi t2, zero, 8
    flush_pipeline
    setup_operands
    fence.i
    add  a1, s1, zero
    flush_pipeline
    assert_value a1, 0xABC
    assert_value s1, 0xABC

# ------------------------------------------------------------------------------------------------
# |                                          Test done!                                          |
# ------------------------------------------------------------------------------------------------
test_finish:
    addi t2, zero, 9
    halt
    fail
