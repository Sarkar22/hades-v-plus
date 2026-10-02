# Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
# Embedded Architectures & Systems Group, Graz University of Technology
# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: zicond.s
#
# ------------------------------------------------------------------------------------------------
# |                                                                                              |
# | Zicond extension test (czero.eqz, czero.nez).                                                |
# | The mnemonics are written with .insn, see the czero_eqz/czero_nez macros.                    |
# | If everything runs correctly, the first register of the peripheral test module               |
# | should always be zero, except during the first test, which checks the assert macro itself.   |
# | Note: This condition is necessary, but not sufficient to prove correctness.                  |
# |                                                                                              |
# | Every expected value below was computed from the ISA text by a separate model, never by      |
# | running the core. A trap handler is armed for the whole test and turns any exception into    |
# | a failure, except in the section that checks the illegal neighbours, which records the       |
# | cause instead and requires mcause = 2.                                                       |
# |                                                                                              |
# | What is checked:                                                                             |
# | 1. Polarity: czero.eqz is 0 when the condition rs2 is zero, czero.nez when it is             |
# |    non-zero; the value rs1 is never tested; every single-bit condition is non-zero.          |
# | 2. The select idiom (czero.eqz | czero.nez).                                                 |
# | 3. rd = x0 discarded (also for the instruction right behind it), x0 as value and             |
# |    as condition, rd == rs1 / rs2 / both.                                                     |
# | 4. Forwarding into rs1 and rs2 at distance 1, 2, 3, from two stages at once, a zero          |
# |    condition forwarded; a load-use stall in front; forwarding out into an ALU op, a          |
# |    branch, a load address, store data, a JALR base and a CSR write.                          |
# | 5. Not executed in the shadow of a taken branch; correct as a branch target; around          |
# |    fence.i; an interrupt at every position of a chain changes nothing.                       |
# | 6. minstret counts each instruction once; a dependent chain takes exactly as many            |
# |    cycles as the same chain of add (no stall, forwarded in its own cycle).                   |
# | 7. The illegal neighbours (other funct3 under funct7 0000111, neighbouring funct7)           |
# |    raise illegal-instruction.                                                                |
# |                                                                                              |
# | Register allocation:                                                                         |
# |     x0  (zero): hardwired 0                                                                  |
# |     x5  (t0):   reserved for macro use                                                       |
# |     x6  (t1):   constant 1                                                                   |
# |     x7  (t2):   test case number                                                             |
# |     x28 (t3):   constant 0x120000<<2 (test peripheral address)                               |
# |     x29 (t4):   constant address of words (a 4-word array)                                   |
# |     x30 (t5):   operand rs1                                                                  |
# |     x31 (t6):   operand rs2                                                                  |
# |     x9  (s1), x18 (s2), x19 (s3), x20 (s4): results                                          |
# |     x21 (s5), x22 (s6): trap handlers and counter samples                                    |
# |     x23 (s7):   interrupt count                                                              |
# |     x24 (s8), x25 (s9): cycle and instruction counts                                         |
# |     x10-x15 (a0-a5): chains and pipeline cases                                               |
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

# GCC 12.2 / binutils 2.39 cannot assemble the Zicond mnemonics, so they are written with
# .insn: opcode OP (0x33), funct3 5 (eqz) or 7 (nez), funct7 0000111.
.macro czero_eqz rd:req, rs1:req, rs2:req
    .insn r 0x33, 5, 7, \rd, \rs1, \rs2
.endm

.macro czero_nez rd:req, rs1:req, rs2:req
    .insn r 0x33, 7, 7, \rd, \rs1, \rs2
.endm

# Execute a hand-encoded word and require it to trap with mcause == cause.
.macro expect_trap enc:req, cause=2
    li32 t5, et_done_\@
    csrw mscratch, t5
    li32 t6, trap_var
    sw   zero, 0(t6)
    flush_pipeline
    .word \enc
et_done_\@:
    li32 t6, trap_var
    lw   t5, 0(t6)
    assert_value t5, \cause
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

# Catch-all trap handler: none of these instructions may trap.
unexpected_trap:
    fail
    halt
    flush_pipeline
    beq  zero, zero, __reset

# Records mcause and resumes at mscratch (illegal-neighbour section only).
record_trap:
    csrr s5, mcause
    li32 s6, trap_var
    sw   s5, 0(s6)
    csrr s5, mscratch
    csrw mepc, s5
    mret
    flush_pipeline
    beq  zero, zero, __reset

# External interrupt handler: counts the interrupt and clears the request.
ext_irq_handler:
    interrupt 0
    addi s7, s7, 1
    mret
    flush_pipeline
    beq  zero, zero, __reset

# ------------------------------------------------------------------------------------------------
# |                                          Test entry!                                         |
# ------------------------------------------------------------------------------------------------
test_init:
    addi t1, zero, 1              # t1 = 1
    addi t2, zero, 0              # t2 = test case number
    lui  t3, %hi(0x120000<<2)     # t3 = peripheral test address
    lui  t4, %hi(words)           # t4 = array address
    flush_pipeline
    addi t3, t3, %lo(0x120000<<2)
    addi t4, t4, %lo(words)
    li32 t5, unexpected_trap
    csrw mtvec, t5

test_fail:
    addi t2, zero, 1
    assert_value zero, 1

# -----------------------------------------------
# The known answers of the ISA text: czero.eqz(5, 0) = 0, czero.nez(5, 0) = 5.
test_known_answers:
    addi t2, zero, 1
    flush_pipeline
    li32 t5, 0x00000005
    li32 t6, 0x00000000
    czero_eqz  s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000005
    li32 t6, 0x00000000
    czero_nez  s1, t5, t6
    assert_value s1, 0x00000005

# -----------------------------------------------
# czero.eqz gives 0 when the CONDITION rs2 is zero and rs1 otherwise;
# czero.nez the opposite. The value rs1 is never the condition.
test_polarity:
    addi t2, zero, 2
    flush_pipeline
    li32 t5, 0x00000000
    li32 t6, 0x00000000
    czero_eqz  s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000000
    li32 t6, 0x00000001
    czero_eqz  s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000000
    li32 t6, 0x80000000
    czero_eqz  s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000000
    li32 t6, 0xFFFFFFFF
    czero_eqz  s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000000
    li32 t6, 0x00010000
    czero_eqz  s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000001
    li32 t6, 0x00000000
    czero_eqz  s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000001
    li32 t6, 0x00000001
    czero_eqz  s1, t5, t6
    assert_value s1, 0x00000001
    li32 t5, 0x00000001
    li32 t6, 0x80000000
    czero_eqz  s1, t5, t6
    assert_value s1, 0x00000001
    li32 t5, 0x00000001
    li32 t6, 0xFFFFFFFF
    czero_eqz  s1, t5, t6
    assert_value s1, 0x00000001
    li32 t5, 0x00000001
    li32 t6, 0x00010000
    czero_eqz  s1, t5, t6
    assert_value s1, 0x00000001
    li32 t5, 0xFFFFFFFF
    li32 t6, 0x00000000
    czero_eqz  s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0xFFFFFFFF
    li32 t6, 0x00000001
    czero_eqz  s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0xFFFFFFFF
    li32 t6, 0x80000000
    czero_eqz  s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0xFFFFFFFF
    li32 t6, 0xFFFFFFFF
    czero_eqz  s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0xFFFFFFFF
    li32 t6, 0x00010000
    czero_eqz  s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x80000000
    li32 t6, 0x00000000
    czero_eqz  s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x80000000
    li32 t6, 0x00000001
    czero_eqz  s1, t5, t6
    assert_value s1, 0x80000000
    li32 t5, 0x80000000
    li32 t6, 0x80000000
    czero_eqz  s1, t5, t6
    assert_value s1, 0x80000000
    li32 t5, 0x80000000
    li32 t6, 0xFFFFFFFF
    czero_eqz  s1, t5, t6
    assert_value s1, 0x80000000
    li32 t5, 0x80000000
    li32 t6, 0x00010000
    czero_eqz  s1, t5, t6
    assert_value s1, 0x80000000
    li32 t5, 0x12345678
    li32 t6, 0x00000000
    czero_eqz  s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x12345678
    li32 t6, 0x00000001
    czero_eqz  s1, t5, t6
    assert_value s1, 0x12345678
    li32 t5, 0x12345678
    li32 t6, 0x80000000
    czero_eqz  s1, t5, t6
    assert_value s1, 0x12345678
    li32 t5, 0x12345678
    li32 t6, 0xFFFFFFFF
    czero_eqz  s1, t5, t6
    assert_value s1, 0x12345678
    li32 t5, 0x12345678
    li32 t6, 0x00010000
    czero_eqz  s1, t5, t6
    assert_value s1, 0x12345678
    li32 t5, 0x00000000
    li32 t6, 0x00000000
    czero_nez  s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000000
    li32 t6, 0x00000001
    czero_nez  s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000000
    li32 t6, 0x80000000
    czero_nez  s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000000
    li32 t6, 0xFFFFFFFF
    czero_nez  s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000000
    li32 t6, 0x00010000
    czero_nez  s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000001
    li32 t6, 0x00000000
    czero_nez  s1, t5, t6
    assert_value s1, 0x00000001
    li32 t5, 0x00000001
    li32 t6, 0x00000001
    czero_nez  s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000001
    li32 t6, 0x80000000
    czero_nez  s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000001
    li32 t6, 0xFFFFFFFF
    czero_nez  s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000001
    li32 t6, 0x00010000
    czero_nez  s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0xFFFFFFFF
    li32 t6, 0x00000000
    czero_nez  s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0xFFFFFFFF
    li32 t6, 0x00000001
    czero_nez  s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0xFFFFFFFF
    li32 t6, 0x80000000
    czero_nez  s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0xFFFFFFFF
    li32 t6, 0xFFFFFFFF
    czero_nez  s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0xFFFFFFFF
    li32 t6, 0x00010000
    czero_nez  s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x80000000
    li32 t6, 0x00000000
    czero_nez  s1, t5, t6
    assert_value s1, 0x80000000
    li32 t5, 0x80000000
    li32 t6, 0x00000001
    czero_nez  s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x80000000
    li32 t6, 0x80000000
    czero_nez  s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x80000000
    li32 t6, 0xFFFFFFFF
    czero_nez  s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x80000000
    li32 t6, 0x00010000
    czero_nez  s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x12345678
    li32 t6, 0x00000000
    czero_nez  s1, t5, t6
    assert_value s1, 0x12345678
    li32 t5, 0x12345678
    li32 t6, 0x00000001
    czero_nez  s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x12345678
    li32 t6, 0x80000000
    czero_nez  s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x12345678
    li32 t6, 0xFFFFFFFF
    czero_nez  s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x12345678
    li32 t6, 0x00010000
    czero_nez  s1, t5, t6
    assert_value s1, 0x00000000

# -----------------------------------------------
# Every single-bit condition counts as non-zero.
test_condition_every_bit:
    addi t2, zero, 3
    flush_pipeline
    li32 t5, 0xCAFEF00D
    slli t6, t1, 0
    czero_eqz  s1, t5, t6
    czero_nez  s2, t5, t6
    or   s3, s1, s2
    assert_value s3, 0xCAFEF00D
    assert_value s2, 0x00000000
    slli t6, t1, 1
    czero_eqz  s1, t5, t6
    czero_nez  s2, t5, t6
    or   s3, s1, s2
    assert_value s3, 0xCAFEF00D
    assert_value s2, 0x00000000
    slli t6, t1, 2
    czero_eqz  s1, t5, t6
    czero_nez  s2, t5, t6
    or   s3, s1, s2
    assert_value s3, 0xCAFEF00D
    assert_value s2, 0x00000000
    slli t6, t1, 3
    czero_eqz  s1, t5, t6
    czero_nez  s2, t5, t6
    or   s3, s1, s2
    assert_value s3, 0xCAFEF00D
    assert_value s2, 0x00000000
    slli t6, t1, 4
    czero_eqz  s1, t5, t6
    czero_nez  s2, t5, t6
    or   s3, s1, s2
    assert_value s3, 0xCAFEF00D
    assert_value s2, 0x00000000
    slli t6, t1, 5
    czero_eqz  s1, t5, t6
    czero_nez  s2, t5, t6
    or   s3, s1, s2
    assert_value s3, 0xCAFEF00D
    assert_value s2, 0x00000000
    slli t6, t1, 6
    czero_eqz  s1, t5, t6
    czero_nez  s2, t5, t6
    or   s3, s1, s2
    assert_value s3, 0xCAFEF00D
    assert_value s2, 0x00000000
    slli t6, t1, 7
    czero_eqz  s1, t5, t6
    czero_nez  s2, t5, t6
    or   s3, s1, s2
    assert_value s3, 0xCAFEF00D
    assert_value s2, 0x00000000
    slli t6, t1, 8
    czero_eqz  s1, t5, t6
    czero_nez  s2, t5, t6
    or   s3, s1, s2
    assert_value s3, 0xCAFEF00D
    assert_value s2, 0x00000000
    slli t6, t1, 9
    czero_eqz  s1, t5, t6
    czero_nez  s2, t5, t6
    or   s3, s1, s2
    assert_value s3, 0xCAFEF00D
    assert_value s2, 0x00000000
    slli t6, t1, 10
    czero_eqz  s1, t5, t6
    czero_nez  s2, t5, t6
    or   s3, s1, s2
    assert_value s3, 0xCAFEF00D
    assert_value s2, 0x00000000
    slli t6, t1, 11
    czero_eqz  s1, t5, t6
    czero_nez  s2, t5, t6
    or   s3, s1, s2
    assert_value s3, 0xCAFEF00D
    assert_value s2, 0x00000000
    slli t6, t1, 12
    czero_eqz  s1, t5, t6
    czero_nez  s2, t5, t6
    or   s3, s1, s2
    assert_value s3, 0xCAFEF00D
    assert_value s2, 0x00000000
    slli t6, t1, 13
    czero_eqz  s1, t5, t6
    czero_nez  s2, t5, t6
    or   s3, s1, s2
    assert_value s3, 0xCAFEF00D
    assert_value s2, 0x00000000
    slli t6, t1, 14
    czero_eqz  s1, t5, t6
    czero_nez  s2, t5, t6
    or   s3, s1, s2
    assert_value s3, 0xCAFEF00D
    assert_value s2, 0x00000000
    slli t6, t1, 15
    czero_eqz  s1, t5, t6
    czero_nez  s2, t5, t6
    or   s3, s1, s2
    assert_value s3, 0xCAFEF00D
    assert_value s2, 0x00000000
    slli t6, t1, 16
    czero_eqz  s1, t5, t6
    czero_nez  s2, t5, t6
    or   s3, s1, s2
    assert_value s3, 0xCAFEF00D
    assert_value s2, 0x00000000
    slli t6, t1, 17
    czero_eqz  s1, t5, t6
    czero_nez  s2, t5, t6
    or   s3, s1, s2
    assert_value s3, 0xCAFEF00D
    assert_value s2, 0x00000000
    slli t6, t1, 18
    czero_eqz  s1, t5, t6
    czero_nez  s2, t5, t6
    or   s3, s1, s2
    assert_value s3, 0xCAFEF00D
    assert_value s2, 0x00000000
    slli t6, t1, 19
    czero_eqz  s1, t5, t6
    czero_nez  s2, t5, t6
    or   s3, s1, s2
    assert_value s3, 0xCAFEF00D
    assert_value s2, 0x00000000
    slli t6, t1, 20
    czero_eqz  s1, t5, t6
    czero_nez  s2, t5, t6
    or   s3, s1, s2
    assert_value s3, 0xCAFEF00D
    assert_value s2, 0x00000000
    slli t6, t1, 21
    czero_eqz  s1, t5, t6
    czero_nez  s2, t5, t6
    or   s3, s1, s2
    assert_value s3, 0xCAFEF00D
    assert_value s2, 0x00000000
    slli t6, t1, 22
    czero_eqz  s1, t5, t6
    czero_nez  s2, t5, t6
    or   s3, s1, s2
    assert_value s3, 0xCAFEF00D
    assert_value s2, 0x00000000
    slli t6, t1, 23
    czero_eqz  s1, t5, t6
    czero_nez  s2, t5, t6
    or   s3, s1, s2
    assert_value s3, 0xCAFEF00D
    assert_value s2, 0x00000000
    slli t6, t1, 24
    czero_eqz  s1, t5, t6
    czero_nez  s2, t5, t6
    or   s3, s1, s2
    assert_value s3, 0xCAFEF00D
    assert_value s2, 0x00000000
    slli t6, t1, 25
    czero_eqz  s1, t5, t6
    czero_nez  s2, t5, t6
    or   s3, s1, s2
    assert_value s3, 0xCAFEF00D
    assert_value s2, 0x00000000
    slli t6, t1, 26
    czero_eqz  s1, t5, t6
    czero_nez  s2, t5, t6
    or   s3, s1, s2
    assert_value s3, 0xCAFEF00D
    assert_value s2, 0x00000000
    slli t6, t1, 27
    czero_eqz  s1, t5, t6
    czero_nez  s2, t5, t6
    or   s3, s1, s2
    assert_value s3, 0xCAFEF00D
    assert_value s2, 0x00000000
    slli t6, t1, 28
    czero_eqz  s1, t5, t6
    czero_nez  s2, t5, t6
    or   s3, s1, s2
    assert_value s3, 0xCAFEF00D
    assert_value s2, 0x00000000
    slli t6, t1, 29
    czero_eqz  s1, t5, t6
    czero_nez  s2, t5, t6
    or   s3, s1, s2
    assert_value s3, 0xCAFEF00D
    assert_value s2, 0x00000000
    slli t6, t1, 30
    czero_eqz  s1, t5, t6
    czero_nez  s2, t5, t6
    or   s3, s1, s2
    assert_value s3, 0xCAFEF00D
    assert_value s2, 0x00000000
    slli t6, t1, 31
    czero_eqz  s1, t5, t6
    czero_nez  s2, t5, t6
    or   s3, s1, s2
    assert_value s3, 0xCAFEF00D
    assert_value s2, 0x00000000

# -----------------------------------------------
# The select idiom cond ? x : y = czero.eqz(x, cond) | czero.nez(y, cond).
test_select_idiom:
    addi t2, zero, 4
    flush_pipeline
    li32 t5, 0x11110000
    li32 s4, 0x00002222
    addi t6, zero, 0
    czero_eqz  s1, t5, t6
    czero_nez  s2, s4, t6
    or   s3, s1, s2
    assert_value s3, 0x00002222
    li32 t5, 0x11110000
    li32 s4, 0x00002222
    addi t6, zero, 7
    czero_eqz  s1, t5, t6
    czero_nez  s2, s4, t6
    or   s3, s1, s2
    assert_value s3, 0x11110000

# -----------------------------------------------
# rd = x0 discards the result, also for the instruction right behind it,
# which must read 0 rather than a forwarded value.
test_rd_is_x0:
    addi t2, zero, 5
    flush_pipeline
    li32 t5, 0x12345678
    li32 t6, 0x0000F00F
    czero_eqz  zero, t5, t6
    add  s1, zero, zero           # reads x0 right behind the discarded result
    czero_eqz  zero, t5, t6
    add  s2, t5, zero
    assert_value s1, 0x00000000
    assert_value s2, 0x12345678

# -----------------------------------------------
# x0 as a source operand.
test_x0_source:
    addi t2, zero, 6
    flush_pipeline
    czero_eqz  s1, zero, t6
    assert_value s1, 0x00000000
    czero_eqz  s1, t5, zero
    assert_value s1, 0x00000000
    czero_eqz  s1, zero, zero
    assert_value s1, 0x00000000

# -----------------------------------------------
# czero.nez with x0 as the value and as the condition.
test_x0_source_nez:
    addi t2, zero, 7
    flush_pipeline
    li32 t5, 0x13572468
    czero_nez  s1, t5, zero
    czero_nez  s2, zero, t5
    assert_value s1, 0x13572468
    assert_value s2, 0x00000000

# -----------------------------------------------
# rd == rs1, rd == rs2 and rd == rs1 == rs2 all read the OLD operands.
test_aliasing:
    addi t2, zero, 8
    flush_pipeline
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    czero_eqz  t5, t5, t6
    assert_value t5, 0xF0F01234
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    czero_eqz  t6, t5, t6
    assert_value t6, 0xF0F01234
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    czero_eqz  t5, t5, t5
    assert_value t5, 0xF0F01234

# -----------------------------------------------
# rd == rs1, rd == rs2 and rd == rs1 == rs2 all read the OLD operands.
test_aliasing_2:
    addi t2, zero, 9
    flush_pipeline
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    czero_nez  t5, t5, t6
    assert_value t5, 0x00000000
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    czero_nez  t6, t5, t6
    assert_value t6, 0x00000000
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    czero_nez  t5, t5, t5
    assert_value t5, 0x00000000

# -----------------------------------------------
# Forwarding INTO the new instruction: the operand produced 1, 2 and 3
# instructions earlier, into rs1 and into rs2, and both operands
# forwarded from different stages.
test_forward_into:
    addi t2, zero, 10
    flush_pipeline
    li32 t6, 0x00000013
    li32 t5, 0x8001F00F
    czero_eqz  s1, t5, t6
    assert_value s1, 0x8001F00F
    li32 t5, 0x8001F00F
    li32 t6, 0x00000013
    czero_eqz  s2, t5, t6
    assert_value s2, 0x8001F00F
    li32 t6, 0x00000013
    li32 t5, 0x8001F00F
    nop
    czero_eqz  s1, t5, t6
    assert_value s1, 0x8001F00F
    li32 t5, 0x8001F00F
    li32 t6, 0x00000013
    nop
    czero_eqz  s2, t5, t6
    assert_value s2, 0x8001F00F
    li32 t6, 0x00000013
    li32 t5, 0x8001F00F
    nop
    nop
    czero_eqz  s1, t5, t6
    assert_value s1, 0x8001F00F
    li32 t5, 0x8001F00F
    li32 t6, 0x00000013
    nop
    nop
    czero_eqz  s2, t5, t6
    assert_value s2, 0x8001F00F
    li32 t5, 0x8001F00F
    li32 t6, 0x00000013
    czero_eqz  s1, t5, t6
    li32 t6, 0x00000013
    li32 t5, 0x8001F00F
    czero_eqz  s2, t5, t6
    li32 t5, 0x8001F00F
    czero_eqz  s3, t5, t5
    assert_value s1, 0x8001F00F
    assert_value s2, 0x8001F00F
    assert_value s3, 0x8001F00F

# -----------------------------------------------
# Forwarding INTO the new instruction: the operand produced 1, 2 and 3
# instructions earlier, into rs1 and into rs2, and both operands
# forwarded from different stages.
test_forward_into_2:
    addi t2, zero, 11
    flush_pipeline
    li32 t6, 0x00000013
    li32 t5, 0x8001F00F
    czero_nez  s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x8001F00F
    li32 t6, 0x00000013
    czero_nez  s2, t5, t6
    assert_value s2, 0x00000000
    li32 t6, 0x00000013
    li32 t5, 0x8001F00F
    nop
    czero_nez  s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x8001F00F
    li32 t6, 0x00000013
    nop
    czero_nez  s2, t5, t6
    assert_value s2, 0x00000000
    li32 t6, 0x00000013
    li32 t5, 0x8001F00F
    nop
    nop
    czero_nez  s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x8001F00F
    li32 t6, 0x00000013
    nop
    nop
    czero_nez  s2, t5, t6
    assert_value s2, 0x00000000
    li32 t5, 0x8001F00F
    li32 t6, 0x00000013
    czero_nez  s1, t5, t6
    li32 t6, 0x00000013
    li32 t5, 0x8001F00F
    czero_nez  s2, t5, t6
    li32 t5, 0x8001F00F
    czero_nez  s3, t5, t5
    assert_value s1, 0x00000000
    assert_value s2, 0x00000000
    assert_value s3, 0x00000000

# -----------------------------------------------
# The condition produced 1, 2, 3 instructions earlier as ZERO.
test_forward_condition_zero:
    addi t2, zero, 12
    flush_pipeline
    li32 t5, 0x0BADF00D
    addi t6, zero, 0
    czero_eqz  s1, t5, t6
    assert_value s1, 0x00000000
    addi t6, zero, 0
    czero_nez  s2, t5, t6
    assert_value s2, 0x0BADF00D
    li32 t5, 0x0BADF00D
    addi t6, zero, 0
    nop
    czero_eqz  s1, t5, t6
    assert_value s1, 0x00000000
    addi t6, zero, 0
    nop
    czero_nez  s2, t5, t6
    assert_value s2, 0x0BADF00D
    li32 t5, 0x0BADF00D
    addi t6, zero, 0
    nop
    nop
    czero_eqz  s1, t5, t6
    assert_value s1, 0x00000000
    addi t6, zero, 0
    nop
    nop
    czero_nez  s2, t5, t6
    assert_value s2, 0x0BADF00D

# -----------------------------------------------
# A load feeding the new instruction directly (load-use stall in front of it),
# into rs1, into rs2 and into both.
test_load_use:
    addi t2, zero, 13
    flush_pipeline
    li32 t6, 0x00000005
    lw   t5, 12(t4)
    czero_eqz  s1, t5, t6
    assert_value s1, 0x12345678
    li32 t5, 0x7FFFFFFF
    lw   t6, 4(t4)
    czero_eqz  s2, t5, t6
    assert_value s2, 0x7FFFFFFF
    lw   t5, 8(t4)
    lw   t6, 12(t4)
    czero_eqz  s3, t5, t6
    assert_value s3, 0x00FF00FF

# -----------------------------------------------
# A load feeding the new instruction directly (load-use stall in front of it),
# into rs1, into rs2 and into both.
test_load_use_2:
    addi t2, zero, 14
    flush_pipeline
    li32 t6, 0x00000005
    lw   t5, 12(t4)
    czero_nez  s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x7FFFFFFF
    lw   t6, 4(t4)
    czero_nez  s2, t5, t6
    assert_value s2, 0x00000000
    lw   t5, 8(t4)
    lw   t6, 12(t4)
    czero_nez  s3, t5, t6
    assert_value s3, 0x00000000

# -----------------------------------------------
# Forwarding OUT of the new instruction, consumed by the very next
# instruction: an ALU op, a branch, a load address, store data, a
# JALR base and a CSR write.
test_forward_out_of:
    addi t2, zero, 15
    flush_pipeline
    li32 t5, 0x00000041
    addi t6, zero, 1
    czero_eqz  s1, t5, t6
    addi s2, s1, 1
    assert_value s2, 0x00000042
    li32 s3, 0x00000099
    li32 t5, 0x00000099
    czero_nez  s1, t5, zero
    bne  s1, s3, fwd_branch_bad_3
    beq  zero, zero, fwd_branch_ok_2
fwd_branch_bad_3:
    fail
fwd_branch_ok_2:
    addi t5, t4, 8
    czero_eqz  s1, t5, t1
    lw   s2, 0(s1)
    assert_value s2, 0x00FF00FF
    li32 t5, 0x5EED5EED
    czero_eqz  s1, t5, t1
    sw   s1, 20(t4)              # scratch_var
    flush_pipeline
    lw   s2, 20(t4)
    assert_value s2, 0x5EED5EED
    addi s4, zero, 0
    li32 t5, zicond_jalr_target_1
    czero_eqz  s1, t5, t1
    jalr ra, 0(s1)
    fail                          # not reached
    beq  zero, zero, jalr_back_4
zicond_jalr_target_1:
    addi s4, zero, 1
jalr_back_4:
    assert_value s4, 0x00000001
    li32 t5, 0x00000777
    addi t6, zero, 0
    czero_nez  s1, t5, t6
    csrw mscratch, s1
    csrr s2, mscratch
    assert_value s2, 0x00000777

# -----------------------------------------------
# An instruction in the shadow of a taken branch must not execute, and
# the new instruction works as a branch target.
test_branch_shadow:
    addi t2, zero, 16
    flush_pipeline
    li32 s1, 0x0000ABCD
    li32 t5, 0x00000042
    li32 t6, 0x00000000
    beq  zero, zero, shadow_target_5
    czero_eqz  s1, t5, t6
    czero_eqz  s1, t5, t6
    fail
shadow_target_5:
    czero_nez  s2, t5, t6
    assert_value s1, 0x0000ABCD
    assert_value s2, 0x00000042

# -----------------------------------------------
# Before and after fence.i, which refetches everything behind it.
test_fence_i:
    addi t2, zero, 17
    flush_pipeline
    li32 t5, 0x13131313
    li32 t6, 0x00000001
    czero_eqz  s1, t5, t6
    fence.i
    czero_eqz  s2, s1, t6
    assert_value s1, 0x13131313
    assert_value s2, 0x13131313
    li32 a2, 0

# -----------------------------------------------
# minstret rises by exactly N over N of the new instructions: the
# difference between a window with them and an empty window.
test_minstret:
    addi t2, zero, 18
    flush_pipeline
    li32 a0, 0x600DCAFE
    li32 a1, 0x00000003
    flush_pipeline
    csrr s5, minstret
    csrr s6, minstret
    sub  s8, s6, s5
    flush_pipeline
    csrr s5, minstret
    czero_eqz  a0, a0, a1
    czero_nez  a0, a0, a2
    czero_eqz  a0, a1, a0
    czero_nez  a0, a0, a2
    czero_eqz  a0, a0, a0
    czero_eqz  a0, a1, a0
    czero_nez  a0, a0, a2
    czero_eqz  a0, a0, a1
    czero_nez  a0, a0, a2
    czero_eqz  a0, a1, a0
    czero_eqz  a0, a0, a1
    czero_nez  a0, a0, a2
    czero_eqz  a0, a0, a0
    czero_nez  a0, a1, a0
    czero_eqz  a0, a1, a1
    czero_nez  a0, a0, a2
    csrr s6, minstret
    sub  s9, s6, s5
    sub  s9, s9, s8
    assert_value s9, 0x00000010
    assert_value a0, 0x00000003

# -----------------------------------------------
# A chain of 16 back-to-back DEPENDENT instructions takes exactly as many
# cycles as the same chain of add instructions: the result is forwarded
# in its own cycle and nothing stalls (mcycle, read at the same points).
test_cycle_exact:
    addi t2, zero, 19
    flush_pipeline
    li32 a0, 0x600DCAFE
    li32 a1, 0x00000003
    flush_pipeline
    csrr s5, mcycle
    czero_eqz  a0, a0, a1
    czero_nez  a0, a0, a2
    czero_eqz  a0, a1, a0
    czero_nez  a0, a0, a2
    czero_eqz  a0, a0, a0
    czero_eqz  a0, a1, a0
    czero_nez  a0, a0, a2
    czero_eqz  a0, a0, a1
    czero_nez  a0, a0, a2
    czero_eqz  a0, a1, a0
    czero_eqz  a0, a0, a1
    czero_nez  a0, a0, a2
    czero_eqz  a0, a0, a0
    czero_nez  a0, a1, a0
    czero_eqz  a0, a1, a1
    czero_nez  a0, a0, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    mv   s4, a0
    li32 a0, 0x600DCAFE
    li32 a1, 0x00000003
    flush_pipeline
    csrr s5, mcycle
    add        a0, a0, a1
    add        a0, a0, a2
    add        a0, a1, a0
    add        a0, a0, a2
    add        a0, a0, a0
    add        a0, a1, a0
    add        a0, a0, a2
    add        a0, a0, a1
    add        a0, a0, a2
    add        a0, a1, a0
    add        a0, a0, a1
    add        a0, a0, a2
    add        a0, a0, a0
    add        a0, a1, a0
    add        a0, a1, a1
    add        a0, a0, a2
    csrr s6, mcycle
    sub  s9, s6, s5
    assert_equal s8, s9
    assert_value s4, 0x00000003
    addi s9, s8, -17
    assert_value s9, 0x00000000

# -----------------------------------------------
# An external interrupt landing at every position of a chain of the
# new instructions: the chain's result and the count are unchanged.
test_interrupt_in_chain:
    addi t2, zero, 20
    flush_pipeline
    li32 t6, ext_irq_handler
    csrw mtvec, t6
    slli t6, t1, 11
    csrs mie, t6
    slli t6, t1, 3
    csrs mstatus, t6
    addi s7, zero, 0
    li32 a0, 0x600DCAFE
    li32 a1, 0x00000003
    flush_pipeline
    interrupt 1
    czero_eqz  a0, a0, a1
    czero_nez  a0, a0, a2
    czero_eqz  a0, a1, a0
    czero_nez  a0, a0, a2
    czero_eqz  a0, a0, a0
    czero_eqz  a0, a1, a0
    czero_nez  a0, a0, a2
    czero_eqz  a0, a0, a1
    czero_nez  a0, a0, a2
    czero_eqz  a0, a1, a0
    czero_eqz  a0, a0, a1
    czero_nez  a0, a0, a2
    czero_eqz  a0, a0, a0
    czero_nez  a0, a1, a0
    czero_eqz  a0, a1, a1
    czero_nez  a0, a0, a2
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x00000003
    li32 a0, 0x600DCAFE
    li32 a1, 0x00000003
    flush_pipeline
    interrupt 2
    czero_eqz  a0, a0, a1
    czero_nez  a0, a0, a2
    czero_eqz  a0, a1, a0
    czero_nez  a0, a0, a2
    czero_eqz  a0, a0, a0
    czero_eqz  a0, a1, a0
    czero_nez  a0, a0, a2
    czero_eqz  a0, a0, a1
    czero_nez  a0, a0, a2
    czero_eqz  a0, a1, a0
    czero_eqz  a0, a0, a1
    czero_nez  a0, a0, a2
    czero_eqz  a0, a0, a0
    czero_nez  a0, a1, a0
    czero_eqz  a0, a1, a1
    czero_nez  a0, a0, a2
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x00000003
    li32 a0, 0x600DCAFE
    li32 a1, 0x00000003
    flush_pipeline
    interrupt 3
    czero_eqz  a0, a0, a1
    czero_nez  a0, a0, a2
    czero_eqz  a0, a1, a0
    czero_nez  a0, a0, a2
    czero_eqz  a0, a0, a0
    czero_eqz  a0, a1, a0
    czero_nez  a0, a0, a2
    czero_eqz  a0, a0, a1
    czero_nez  a0, a0, a2
    czero_eqz  a0, a1, a0
    czero_eqz  a0, a0, a1
    czero_nez  a0, a0, a2
    czero_eqz  a0, a0, a0
    czero_nez  a0, a1, a0
    czero_eqz  a0, a1, a1
    czero_nez  a0, a0, a2
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x00000003
    li32 a0, 0x600DCAFE
    li32 a1, 0x00000003
    flush_pipeline
    interrupt 4
    czero_eqz  a0, a0, a1
    czero_nez  a0, a0, a2
    czero_eqz  a0, a1, a0
    czero_nez  a0, a0, a2
    czero_eqz  a0, a0, a0
    czero_eqz  a0, a1, a0
    czero_nez  a0, a0, a2
    czero_eqz  a0, a0, a1
    czero_nez  a0, a0, a2
    czero_eqz  a0, a1, a0
    czero_eqz  a0, a0, a1
    czero_nez  a0, a0, a2
    czero_eqz  a0, a0, a0
    czero_nez  a0, a1, a0
    czero_eqz  a0, a1, a1
    czero_nez  a0, a0, a2
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x00000003
    li32 a0, 0x600DCAFE
    li32 a1, 0x00000003
    flush_pipeline
    interrupt 5
    czero_eqz  a0, a0, a1
    czero_nez  a0, a0, a2
    czero_eqz  a0, a1, a0
    czero_nez  a0, a0, a2
    czero_eqz  a0, a0, a0
    czero_eqz  a0, a1, a0
    czero_nez  a0, a0, a2
    czero_eqz  a0, a0, a1
    czero_nez  a0, a0, a2
    czero_eqz  a0, a1, a0
    czero_eqz  a0, a0, a1
    czero_nez  a0, a0, a2
    czero_eqz  a0, a0, a0
    czero_nez  a0, a1, a0
    czero_eqz  a0, a1, a1
    czero_nez  a0, a0, a2
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x00000003
    li32 a0, 0x600DCAFE
    li32 a1, 0x00000003
    flush_pipeline
    interrupt 6
    czero_eqz  a0, a0, a1
    czero_nez  a0, a0, a2
    czero_eqz  a0, a1, a0
    czero_nez  a0, a0, a2
    czero_eqz  a0, a0, a0
    czero_eqz  a0, a1, a0
    czero_nez  a0, a0, a2
    czero_eqz  a0, a0, a1
    czero_nez  a0, a0, a2
    czero_eqz  a0, a1, a0
    czero_eqz  a0, a0, a1
    czero_nez  a0, a0, a2
    czero_eqz  a0, a0, a0
    czero_nez  a0, a1, a0
    czero_eqz  a0, a1, a1
    czero_nez  a0, a0, a2
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x00000003
    li32 a0, 0x600DCAFE
    li32 a1, 0x00000003
    flush_pipeline
    interrupt 7
    czero_eqz  a0, a0, a1
    czero_nez  a0, a0, a2
    czero_eqz  a0, a1, a0
    czero_nez  a0, a0, a2
    czero_eqz  a0, a0, a0
    czero_eqz  a0, a1, a0
    czero_nez  a0, a0, a2
    czero_eqz  a0, a0, a1
    czero_nez  a0, a0, a2
    czero_eqz  a0, a1, a0
    czero_eqz  a0, a0, a1
    czero_nez  a0, a0, a2
    czero_eqz  a0, a0, a0
    czero_nez  a0, a1, a0
    czero_eqz  a0, a1, a1
    czero_nez  a0, a0, a2
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x00000003
    li32 a0, 0x600DCAFE
    li32 a1, 0x00000003
    flush_pipeline
    interrupt 8
    czero_eqz  a0, a0, a1
    czero_nez  a0, a0, a2
    czero_eqz  a0, a1, a0
    czero_nez  a0, a0, a2
    czero_eqz  a0, a0, a0
    czero_eqz  a0, a1, a0
    czero_nez  a0, a0, a2
    czero_eqz  a0, a0, a1
    czero_nez  a0, a0, a2
    czero_eqz  a0, a1, a0
    czero_eqz  a0, a0, a1
    czero_nez  a0, a0, a2
    czero_eqz  a0, a0, a0
    czero_nez  a0, a1, a0
    czero_eqz  a0, a1, a1
    czero_nez  a0, a0, a2
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x00000003
    slli t6, t1, 3
    csrc mstatus, t6
    slli t6, t1, 11
    csrc mie, t6
    li32 t6, unexpected_trap
    csrw mtvec, t6
    flush_pipeline
    assert_value s7, 0x00000008

# -----------------------------------------------
# Encodings next to the new ones that are NOT instructions here
# (reserved on RV32, other extensions, wrong funct3/funct7/rs2
# field) must still raise illegal-instruction, mcause = 2.
test_illegal_neighbours:
    addi t2, zero, 21
    flush_pipeline
    li32 t5, record_trap
    csrw mtvec, t5
    flush_pipeline
    expect_trap 0x0EC58533, 2       # funct7 0000111, funct3 000
    expect_trap 0x0EC59533, 2       # funct7 0000111, funct3 001
    expect_trap 0x0EC5E533, 2       # funct7 0000111, funct3 110
    expect_trap 0x0CC5D533, 2       # funct7 0000110, funct3 101
    expect_trap 0x1EC5D533, 2       # funct7 0001111, funct3 101
    li32 t5, unexpected_trap
    csrw mtvec, t5
    flush_pipeline

# ------------------------------------------------------------------------------------------------
# |                                          Test done!                                          |
# ------------------------------------------------------------------------------------------------
test_finish:
    addi t2, zero, 22
    flush_pipeline
    halt
    fail
    beq  zero, zero, test_finish

    .align 4
words:
    .word 0x11111111
    .word 0x80000000
    .word 0x00FF00FF
    .word 0x12345678
trap_var:
    .word 0x0
scratch_var:
    .word 0x0
