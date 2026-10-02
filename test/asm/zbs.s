# Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
# Embedded Architectures & Systems Group, Graz University of Technology
# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: zbs.s
#
# ------------------------------------------------------------------------------------------------
# |                                                                                              |
# | Zbs extension test (single-bit instructions).                                                |
# | bclr bclri, bext bexti, binv binvi, bset bseti.                                              |
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
# | 1. Every bit index 0..31 for the register forms, with the upper 27 bits of rs2 set           |
# |    (only rs2[4:0] is the index), and every shamt 0..31 for the immediate forms.              |
# | 2. Corner operands: bext returns the bit itself (0 or 1), rs2 >= 32 wraps.                   |
# | 3. rd = x0 discarded (also for the instruction right behind it), x0 as a source,             |
# |    rd == rs1 / rs2 / both.                                                                   |
# | 4. Forwarding into rs1 and rs2 at distance 1, 2, 3, from two stages at once, into            |
# |    the immediate forms; a load-use stall in front; forwarding out into an ALU op, a          |
# |    branch, a load address, store data, a JALR base and a CSR write.                          |
# | 5. Not executed in the shadow of a taken branch; correct as a branch target; around          |
# |    fence.i; an interrupt at every position of a chain changes nothing.                       |
# | 6. minstret counts each instruction once; a dependent chain takes exactly as many            |
# |    cycles as the same chain of add (no stall, forwarded in its own cycle).                   |
# | 7. The illegal neighbours (shamt[5] = 1 on RV32, Zbkx, unused funct3/funct7)                 |
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

.option arch, +zbb, +zbs

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
# The known answers of the ISA text.
test_known_answers:
    addi t2, zero, 1
    flush_pipeline
    li32 t5, 0x80000000
    li32 t6, 0x0000001F
    bext       s1, t5, t6
    assert_value s1, 0x00000001
    li32 t5, 0x00000000
    li32 t6, 0x00000025
    bset       s1, t5, t6
    assert_value s1, 0x00000020
    li32 t5, 0xFFFFFFFF
    li32 t6, 0x00000000
    bclr       s1, t5, t6
    assert_value s1, 0xFFFFFFFE
    li32 t5, 0x00000000
    li32 t6, 0x0000001F
    binv       s1, t5, t6
    assert_value s1, 0x80000000

# -----------------------------------------------
# bclr, bext, binv, bset at every index 0..31, with the upper 27 bits
# of rs2 set (only rs2[4:0] is the index).
test_every_index_register:
    addi t2, zero, 2
    flush_pipeline
    li32 t5, 0xFFFFFFFF
    li32 s3, 0xFFFFFFE0
    addi t6, s3, 0
    bclr       s1, t5, t6
    assert_value s1, 0xFFFFFFFE
    addi t6, s3, 1
    bclr       s1, t5, t6
    assert_value s1, 0xFFFFFFFD
    addi t6, s3, 2
    bclr       s1, t5, t6
    assert_value s1, 0xFFFFFFFB
    addi t6, s3, 3
    bclr       s1, t5, t6
    assert_value s1, 0xFFFFFFF7
    addi t6, s3, 4
    bclr       s1, t5, t6
    assert_value s1, 0xFFFFFFEF
    addi t6, s3, 5
    bclr       s1, t5, t6
    assert_value s1, 0xFFFFFFDF
    addi t6, s3, 6
    bclr       s1, t5, t6
    assert_value s1, 0xFFFFFFBF
    addi t6, s3, 7
    bclr       s1, t5, t6
    assert_value s1, 0xFFFFFF7F
    addi t6, s3, 8
    bclr       s1, t5, t6
    assert_value s1, 0xFFFFFEFF
    addi t6, s3, 9
    bclr       s1, t5, t6
    assert_value s1, 0xFFFFFDFF
    addi t6, s3, 10
    bclr       s1, t5, t6
    assert_value s1, 0xFFFFFBFF
    addi t6, s3, 11
    bclr       s1, t5, t6
    assert_value s1, 0xFFFFF7FF
    addi t6, s3, 12
    bclr       s1, t5, t6
    assert_value s1, 0xFFFFEFFF
    addi t6, s3, 13
    bclr       s1, t5, t6
    assert_value s1, 0xFFFFDFFF
    addi t6, s3, 14
    bclr       s1, t5, t6
    assert_value s1, 0xFFFFBFFF
    addi t6, s3, 15
    bclr       s1, t5, t6
    assert_value s1, 0xFFFF7FFF
    addi t6, s3, 16
    bclr       s1, t5, t6
    assert_value s1, 0xFFFEFFFF
    addi t6, s3, 17
    bclr       s1, t5, t6
    assert_value s1, 0xFFFDFFFF
    addi t6, s3, 18
    bclr       s1, t5, t6
    assert_value s1, 0xFFFBFFFF
    addi t6, s3, 19
    bclr       s1, t5, t6
    assert_value s1, 0xFFF7FFFF
    addi t6, s3, 20
    bclr       s1, t5, t6
    assert_value s1, 0xFFEFFFFF
    addi t6, s3, 21
    bclr       s1, t5, t6
    assert_value s1, 0xFFDFFFFF
    addi t6, s3, 22
    bclr       s1, t5, t6
    assert_value s1, 0xFFBFFFFF
    addi t6, s3, 23
    bclr       s1, t5, t6
    assert_value s1, 0xFF7FFFFF
    addi t6, s3, 24
    bclr       s1, t5, t6
    assert_value s1, 0xFEFFFFFF
    addi t6, s3, 25
    bclr       s1, t5, t6
    assert_value s1, 0xFDFFFFFF
    addi t6, s3, 26
    bclr       s1, t5, t6
    assert_value s1, 0xFBFFFFFF
    addi t6, s3, 27
    bclr       s1, t5, t6
    assert_value s1, 0xF7FFFFFF
    addi t6, s3, 28
    bclr       s1, t5, t6
    assert_value s1, 0xEFFFFFFF
    addi t6, s3, 29
    bclr       s1, t5, t6
    assert_value s1, 0xDFFFFFFF
    addi t6, s3, 30
    bclr       s1, t5, t6
    assert_value s1, 0xBFFFFFFF
    addi t6, s3, 31
    bclr       s1, t5, t6
    assert_value s1, 0x7FFFFFFF
    li32 t5, 0xA5C30F69
    li32 s3, 0xFFFFFFE0
    addi t6, s3, 0
    bext       s1, t5, t6
    assert_value s1, 0x00000001
    addi t6, s3, 1
    bext       s1, t5, t6
    assert_value s1, 0x00000000
    addi t6, s3, 2
    bext       s1, t5, t6
    assert_value s1, 0x00000000
    addi t6, s3, 3
    bext       s1, t5, t6
    assert_value s1, 0x00000001
    addi t6, s3, 4
    bext       s1, t5, t6
    assert_value s1, 0x00000000
    addi t6, s3, 5
    bext       s1, t5, t6
    assert_value s1, 0x00000001
    addi t6, s3, 6
    bext       s1, t5, t6
    assert_value s1, 0x00000001
    addi t6, s3, 7
    bext       s1, t5, t6
    assert_value s1, 0x00000000
    addi t6, s3, 8
    bext       s1, t5, t6
    assert_value s1, 0x00000001
    addi t6, s3, 9
    bext       s1, t5, t6
    assert_value s1, 0x00000001
    addi t6, s3, 10
    bext       s1, t5, t6
    assert_value s1, 0x00000001
    addi t6, s3, 11
    bext       s1, t5, t6
    assert_value s1, 0x00000001
    addi t6, s3, 12
    bext       s1, t5, t6
    assert_value s1, 0x00000000
    addi t6, s3, 13
    bext       s1, t5, t6
    assert_value s1, 0x00000000
    addi t6, s3, 14
    bext       s1, t5, t6
    assert_value s1, 0x00000000
    addi t6, s3, 15
    bext       s1, t5, t6
    assert_value s1, 0x00000000
    addi t6, s3, 16
    bext       s1, t5, t6
    assert_value s1, 0x00000001
    addi t6, s3, 17
    bext       s1, t5, t6
    assert_value s1, 0x00000001
    addi t6, s3, 18
    bext       s1, t5, t6
    assert_value s1, 0x00000000
    addi t6, s3, 19
    bext       s1, t5, t6
    assert_value s1, 0x00000000
    addi t6, s3, 20
    bext       s1, t5, t6
    assert_value s1, 0x00000000
    addi t6, s3, 21
    bext       s1, t5, t6
    assert_value s1, 0x00000000
    addi t6, s3, 22
    bext       s1, t5, t6
    assert_value s1, 0x00000001
    addi t6, s3, 23
    bext       s1, t5, t6
    assert_value s1, 0x00000001
    addi t6, s3, 24
    bext       s1, t5, t6
    assert_value s1, 0x00000001
    addi t6, s3, 25
    bext       s1, t5, t6
    assert_value s1, 0x00000000
    addi t6, s3, 26
    bext       s1, t5, t6
    assert_value s1, 0x00000001
    addi t6, s3, 27
    bext       s1, t5, t6
    assert_value s1, 0x00000000
    addi t6, s3, 28
    bext       s1, t5, t6
    assert_value s1, 0x00000000
    addi t6, s3, 29
    bext       s1, t5, t6
    assert_value s1, 0x00000001
    addi t6, s3, 30
    bext       s1, t5, t6
    assert_value s1, 0x00000000
    addi t6, s3, 31
    bext       s1, t5, t6
    assert_value s1, 0x00000001
    li32 t5, 0x5A5A5A5A
    li32 s3, 0xFFFFFFE0
    addi t6, s3, 0
    binv       s1, t5, t6
    assert_value s1, 0x5A5A5A5B
    addi t6, s3, 1
    binv       s1, t5, t6
    assert_value s1, 0x5A5A5A58
    addi t6, s3, 2
    binv       s1, t5, t6
    assert_value s1, 0x5A5A5A5E
    addi t6, s3, 3
    binv       s1, t5, t6
    assert_value s1, 0x5A5A5A52
    addi t6, s3, 4
    binv       s1, t5, t6
    assert_value s1, 0x5A5A5A4A
    addi t6, s3, 5
    binv       s1, t5, t6
    assert_value s1, 0x5A5A5A7A
    addi t6, s3, 6
    binv       s1, t5, t6
    assert_value s1, 0x5A5A5A1A
    addi t6, s3, 7
    binv       s1, t5, t6
    assert_value s1, 0x5A5A5ADA
    addi t6, s3, 8
    binv       s1, t5, t6
    assert_value s1, 0x5A5A5B5A
    addi t6, s3, 9
    binv       s1, t5, t6
    assert_value s1, 0x5A5A585A
    addi t6, s3, 10
    binv       s1, t5, t6
    assert_value s1, 0x5A5A5E5A
    addi t6, s3, 11
    binv       s1, t5, t6
    assert_value s1, 0x5A5A525A
    addi t6, s3, 12
    binv       s1, t5, t6
    assert_value s1, 0x5A5A4A5A
    addi t6, s3, 13
    binv       s1, t5, t6
    assert_value s1, 0x5A5A7A5A
    addi t6, s3, 14
    binv       s1, t5, t6
    assert_value s1, 0x5A5A1A5A
    addi t6, s3, 15
    binv       s1, t5, t6
    assert_value s1, 0x5A5ADA5A
    addi t6, s3, 16
    binv       s1, t5, t6
    assert_value s1, 0x5A5B5A5A
    addi t6, s3, 17
    binv       s1, t5, t6
    assert_value s1, 0x5A585A5A
    addi t6, s3, 18
    binv       s1, t5, t6
    assert_value s1, 0x5A5E5A5A
    addi t6, s3, 19
    binv       s1, t5, t6
    assert_value s1, 0x5A525A5A
    addi t6, s3, 20
    binv       s1, t5, t6
    assert_value s1, 0x5A4A5A5A
    addi t6, s3, 21
    binv       s1, t5, t6
    assert_value s1, 0x5A7A5A5A
    addi t6, s3, 22
    binv       s1, t5, t6
    assert_value s1, 0x5A1A5A5A
    addi t6, s3, 23
    binv       s1, t5, t6
    assert_value s1, 0x5ADA5A5A
    addi t6, s3, 24
    binv       s1, t5, t6
    assert_value s1, 0x5B5A5A5A
    addi t6, s3, 25
    binv       s1, t5, t6
    assert_value s1, 0x585A5A5A
    addi t6, s3, 26
    binv       s1, t5, t6
    assert_value s1, 0x5E5A5A5A
    addi t6, s3, 27
    binv       s1, t5, t6
    assert_value s1, 0x525A5A5A
    addi t6, s3, 28
    binv       s1, t5, t6
    assert_value s1, 0x4A5A5A5A
    addi t6, s3, 29
    binv       s1, t5, t6
    assert_value s1, 0x7A5A5A5A
    addi t6, s3, 30
    binv       s1, t5, t6
    assert_value s1, 0x1A5A5A5A
    addi t6, s3, 31
    binv       s1, t5, t6
    assert_value s1, 0xDA5A5A5A
    li32 t5, 0x00000000
    li32 s3, 0xFFFFFFE0
    addi t6, s3, 0
    bset       s1, t5, t6
    assert_value s1, 0x00000001
    addi t6, s3, 1
    bset       s1, t5, t6
    assert_value s1, 0x00000002
    addi t6, s3, 2
    bset       s1, t5, t6
    assert_value s1, 0x00000004
    addi t6, s3, 3
    bset       s1, t5, t6
    assert_value s1, 0x00000008
    addi t6, s3, 4
    bset       s1, t5, t6
    assert_value s1, 0x00000010
    addi t6, s3, 5
    bset       s1, t5, t6
    assert_value s1, 0x00000020
    addi t6, s3, 6
    bset       s1, t5, t6
    assert_value s1, 0x00000040
    addi t6, s3, 7
    bset       s1, t5, t6
    assert_value s1, 0x00000080
    addi t6, s3, 8
    bset       s1, t5, t6
    assert_value s1, 0x00000100
    addi t6, s3, 9
    bset       s1, t5, t6
    assert_value s1, 0x00000200
    addi t6, s3, 10
    bset       s1, t5, t6
    assert_value s1, 0x00000400
    addi t6, s3, 11
    bset       s1, t5, t6
    assert_value s1, 0x00000800
    addi t6, s3, 12
    bset       s1, t5, t6
    assert_value s1, 0x00001000
    addi t6, s3, 13
    bset       s1, t5, t6
    assert_value s1, 0x00002000
    addi t6, s3, 14
    bset       s1, t5, t6
    assert_value s1, 0x00004000
    addi t6, s3, 15
    bset       s1, t5, t6
    assert_value s1, 0x00008000
    addi t6, s3, 16
    bset       s1, t5, t6
    assert_value s1, 0x00010000
    addi t6, s3, 17
    bset       s1, t5, t6
    assert_value s1, 0x00020000
    addi t6, s3, 18
    bset       s1, t5, t6
    assert_value s1, 0x00040000
    addi t6, s3, 19
    bset       s1, t5, t6
    assert_value s1, 0x00080000
    addi t6, s3, 20
    bset       s1, t5, t6
    assert_value s1, 0x00100000
    addi t6, s3, 21
    bset       s1, t5, t6
    assert_value s1, 0x00200000
    addi t6, s3, 22
    bset       s1, t5, t6
    assert_value s1, 0x00400000
    addi t6, s3, 23
    bset       s1, t5, t6
    assert_value s1, 0x00800000
    addi t6, s3, 24
    bset       s1, t5, t6
    assert_value s1, 0x01000000
    addi t6, s3, 25
    bset       s1, t5, t6
    assert_value s1, 0x02000000
    addi t6, s3, 26
    bset       s1, t5, t6
    assert_value s1, 0x04000000
    addi t6, s3, 27
    bset       s1, t5, t6
    assert_value s1, 0x08000000
    addi t6, s3, 28
    bset       s1, t5, t6
    assert_value s1, 0x10000000
    addi t6, s3, 29
    bset       s1, t5, t6
    assert_value s1, 0x20000000
    addi t6, s3, 30
    bset       s1, t5, t6
    assert_value s1, 0x40000000
    addi t6, s3, 31
    bset       s1, t5, t6
    assert_value s1, 0x80000000

# -----------------------------------------------
# bclri, bexti, binvi, bseti with every shamt 0..31.
test_every_shamt_immediate:
    addi t2, zero, 3
    flush_pipeline
    li32 t5, 0xFFFFFFFF
    bclri      s1, t5, 0
    assert_value s1, 0xFFFFFFFE
    bclri      s1, t5, 1
    assert_value s1, 0xFFFFFFFD
    bclri      s1, t5, 2
    assert_value s1, 0xFFFFFFFB
    bclri      s1, t5, 3
    assert_value s1, 0xFFFFFFF7
    bclri      s1, t5, 4
    assert_value s1, 0xFFFFFFEF
    bclri      s1, t5, 5
    assert_value s1, 0xFFFFFFDF
    bclri      s1, t5, 6
    assert_value s1, 0xFFFFFFBF
    bclri      s1, t5, 7
    assert_value s1, 0xFFFFFF7F
    bclri      s1, t5, 8
    assert_value s1, 0xFFFFFEFF
    bclri      s1, t5, 9
    assert_value s1, 0xFFFFFDFF
    bclri      s1, t5, 10
    assert_value s1, 0xFFFFFBFF
    bclri      s1, t5, 11
    assert_value s1, 0xFFFFF7FF
    bclri      s1, t5, 12
    assert_value s1, 0xFFFFEFFF
    bclri      s1, t5, 13
    assert_value s1, 0xFFFFDFFF
    bclri      s1, t5, 14
    assert_value s1, 0xFFFFBFFF
    bclri      s1, t5, 15
    assert_value s1, 0xFFFF7FFF
    bclri      s1, t5, 16
    assert_value s1, 0xFFFEFFFF
    bclri      s1, t5, 17
    assert_value s1, 0xFFFDFFFF
    bclri      s1, t5, 18
    assert_value s1, 0xFFFBFFFF
    bclri      s1, t5, 19
    assert_value s1, 0xFFF7FFFF
    bclri      s1, t5, 20
    assert_value s1, 0xFFEFFFFF
    bclri      s1, t5, 21
    assert_value s1, 0xFFDFFFFF
    bclri      s1, t5, 22
    assert_value s1, 0xFFBFFFFF
    bclri      s1, t5, 23
    assert_value s1, 0xFF7FFFFF
    bclri      s1, t5, 24
    assert_value s1, 0xFEFFFFFF
    bclri      s1, t5, 25
    assert_value s1, 0xFDFFFFFF
    bclri      s1, t5, 26
    assert_value s1, 0xFBFFFFFF
    bclri      s1, t5, 27
    assert_value s1, 0xF7FFFFFF
    bclri      s1, t5, 28
    assert_value s1, 0xEFFFFFFF
    bclri      s1, t5, 29
    assert_value s1, 0xDFFFFFFF
    bclri      s1, t5, 30
    assert_value s1, 0xBFFFFFFF
    bclri      s1, t5, 31
    assert_value s1, 0x7FFFFFFF
    li32 t5, 0x96F03C5A
    bexti      s1, t5, 0
    assert_value s1, 0x00000000
    bexti      s1, t5, 1
    assert_value s1, 0x00000001
    bexti      s1, t5, 2
    assert_value s1, 0x00000000
    bexti      s1, t5, 3
    assert_value s1, 0x00000001
    bexti      s1, t5, 4
    assert_value s1, 0x00000001
    bexti      s1, t5, 5
    assert_value s1, 0x00000000
    bexti      s1, t5, 6
    assert_value s1, 0x00000001
    bexti      s1, t5, 7
    assert_value s1, 0x00000000
    bexti      s1, t5, 8
    assert_value s1, 0x00000000
    bexti      s1, t5, 9
    assert_value s1, 0x00000000
    bexti      s1, t5, 10
    assert_value s1, 0x00000001
    bexti      s1, t5, 11
    assert_value s1, 0x00000001
    bexti      s1, t5, 12
    assert_value s1, 0x00000001
    bexti      s1, t5, 13
    assert_value s1, 0x00000001
    bexti      s1, t5, 14
    assert_value s1, 0x00000000
    bexti      s1, t5, 15
    assert_value s1, 0x00000000
    bexti      s1, t5, 16
    assert_value s1, 0x00000000
    bexti      s1, t5, 17
    assert_value s1, 0x00000000
    bexti      s1, t5, 18
    assert_value s1, 0x00000000
    bexti      s1, t5, 19
    assert_value s1, 0x00000000
    bexti      s1, t5, 20
    assert_value s1, 0x00000001
    bexti      s1, t5, 21
    assert_value s1, 0x00000001
    bexti      s1, t5, 22
    assert_value s1, 0x00000001
    bexti      s1, t5, 23
    assert_value s1, 0x00000001
    bexti      s1, t5, 24
    assert_value s1, 0x00000000
    bexti      s1, t5, 25
    assert_value s1, 0x00000001
    bexti      s1, t5, 26
    assert_value s1, 0x00000001
    bexti      s1, t5, 27
    assert_value s1, 0x00000000
    bexti      s1, t5, 28
    assert_value s1, 0x00000001
    bexti      s1, t5, 29
    assert_value s1, 0x00000000
    bexti      s1, t5, 30
    assert_value s1, 0x00000000
    bexti      s1, t5, 31
    assert_value s1, 0x00000001
    li32 t5, 0xA5A5A5A5
    binvi      s1, t5, 0
    assert_value s1, 0xA5A5A5A4
    binvi      s1, t5, 1
    assert_value s1, 0xA5A5A5A7
    binvi      s1, t5, 2
    assert_value s1, 0xA5A5A5A1
    binvi      s1, t5, 3
    assert_value s1, 0xA5A5A5AD
    binvi      s1, t5, 4
    assert_value s1, 0xA5A5A5B5
    binvi      s1, t5, 5
    assert_value s1, 0xA5A5A585
    binvi      s1, t5, 6
    assert_value s1, 0xA5A5A5E5
    binvi      s1, t5, 7
    assert_value s1, 0xA5A5A525
    binvi      s1, t5, 8
    assert_value s1, 0xA5A5A4A5
    binvi      s1, t5, 9
    assert_value s1, 0xA5A5A7A5
    binvi      s1, t5, 10
    assert_value s1, 0xA5A5A1A5
    binvi      s1, t5, 11
    assert_value s1, 0xA5A5ADA5
    binvi      s1, t5, 12
    assert_value s1, 0xA5A5B5A5
    binvi      s1, t5, 13
    assert_value s1, 0xA5A585A5
    binvi      s1, t5, 14
    assert_value s1, 0xA5A5E5A5
    binvi      s1, t5, 15
    assert_value s1, 0xA5A525A5
    binvi      s1, t5, 16
    assert_value s1, 0xA5A4A5A5
    binvi      s1, t5, 17
    assert_value s1, 0xA5A7A5A5
    binvi      s1, t5, 18
    assert_value s1, 0xA5A1A5A5
    binvi      s1, t5, 19
    assert_value s1, 0xA5ADA5A5
    binvi      s1, t5, 20
    assert_value s1, 0xA5B5A5A5
    binvi      s1, t5, 21
    assert_value s1, 0xA585A5A5
    binvi      s1, t5, 22
    assert_value s1, 0xA5E5A5A5
    binvi      s1, t5, 23
    assert_value s1, 0xA525A5A5
    binvi      s1, t5, 24
    assert_value s1, 0xA4A5A5A5
    binvi      s1, t5, 25
    assert_value s1, 0xA7A5A5A5
    binvi      s1, t5, 26
    assert_value s1, 0xA1A5A5A5
    binvi      s1, t5, 27
    assert_value s1, 0xADA5A5A5
    binvi      s1, t5, 28
    assert_value s1, 0xB5A5A5A5
    binvi      s1, t5, 29
    assert_value s1, 0x85A5A5A5
    binvi      s1, t5, 30
    assert_value s1, 0xE5A5A5A5
    binvi      s1, t5, 31
    assert_value s1, 0x25A5A5A5
    li32 t5, 0x00000000
    bseti      s1, t5, 0
    assert_value s1, 0x00000001
    bseti      s1, t5, 1
    assert_value s1, 0x00000002
    bseti      s1, t5, 2
    assert_value s1, 0x00000004
    bseti      s1, t5, 3
    assert_value s1, 0x00000008
    bseti      s1, t5, 4
    assert_value s1, 0x00000010
    bseti      s1, t5, 5
    assert_value s1, 0x00000020
    bseti      s1, t5, 6
    assert_value s1, 0x00000040
    bseti      s1, t5, 7
    assert_value s1, 0x00000080
    bseti      s1, t5, 8
    assert_value s1, 0x00000100
    bseti      s1, t5, 9
    assert_value s1, 0x00000200
    bseti      s1, t5, 10
    assert_value s1, 0x00000400
    bseti      s1, t5, 11
    assert_value s1, 0x00000800
    bseti      s1, t5, 12
    assert_value s1, 0x00001000
    bseti      s1, t5, 13
    assert_value s1, 0x00002000
    bseti      s1, t5, 14
    assert_value s1, 0x00004000
    bseti      s1, t5, 15
    assert_value s1, 0x00008000
    bseti      s1, t5, 16
    assert_value s1, 0x00010000
    bseti      s1, t5, 17
    assert_value s1, 0x00020000
    bseti      s1, t5, 18
    assert_value s1, 0x00040000
    bseti      s1, t5, 19
    assert_value s1, 0x00080000
    bseti      s1, t5, 20
    assert_value s1, 0x00100000
    bseti      s1, t5, 21
    assert_value s1, 0x00200000
    bseti      s1, t5, 22
    assert_value s1, 0x00400000
    bseti      s1, t5, 23
    assert_value s1, 0x00800000
    bseti      s1, t5, 24
    assert_value s1, 0x01000000
    bseti      s1, t5, 25
    assert_value s1, 0x02000000
    bseti      s1, t5, 26
    assert_value s1, 0x04000000
    bseti      s1, t5, 27
    assert_value s1, 0x08000000
    bseti      s1, t5, 28
    assert_value s1, 0x10000000
    bseti      s1, t5, 29
    assert_value s1, 0x20000000
    bseti      s1, t5, 30
    assert_value s1, 0x40000000
    bseti      s1, t5, 31
    assert_value s1, 0x80000000

# -----------------------------------------------
# Corner operands: bext returns the bit (0 or 1), not a mask; setting a set
# bit and clearing a clear bit change nothing; rs2 >= 32 wraps.
test_corners:
    addi t2, zero, 4
    flush_pipeline
    li32 t5, 0x80000000
    li32 t6, 0x0000001F
    bclr       s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x7FFFFFFF
    li32 t6, 0x0000001F
    bclr       s1, t5, t6
    assert_value s1, 0x7FFFFFFF
    li32 t5, 0x00000001
    li32 t6, 0x00000000
    bclr       s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0xFFFFFFFE
    li32 t6, 0x00000000
    bclr       s1, t5, t6
    assert_value s1, 0xFFFFFFFE
    li32 t5, 0x12345678
    li32 t6, 0x00000023
    bclr       s1, t5, t6
    assert_value s1, 0x12345670
    li32 t5, 0x12345678
    li32 t6, 0xFFFFFFFF
    bclr       s1, t5, t6
    assert_value s1, 0x12345678
    li32 t5, 0x00000000
    li32 t6, 0x00000010
    bclr       s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0xFFFFFFFF
    li32 t6, 0x00000010
    bclr       s1, t5, t6
    assert_value s1, 0xFFFEFFFF
    li32 t5, 0x80000000
    li32 t6, 0x0000001F
    bext       s1, t5, t6
    assert_value s1, 0x00000001
    li32 t5, 0x7FFFFFFF
    li32 t6, 0x0000001F
    bext       s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000001
    li32 t6, 0x00000000
    bext       s1, t5, t6
    assert_value s1, 0x00000001
    li32 t5, 0xFFFFFFFE
    li32 t6, 0x00000000
    bext       s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x12345678
    li32 t6, 0x00000023
    bext       s1, t5, t6
    assert_value s1, 0x00000001
    li32 t5, 0x12345678
    li32 t6, 0xFFFFFFFF
    bext       s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000000
    li32 t6, 0x00000010
    bext       s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0xFFFFFFFF
    li32 t6, 0x00000010
    bext       s1, t5, t6
    assert_value s1, 0x00000001
    li32 t5, 0x80000000
    li32 t6, 0x0000001F
    binv       s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x7FFFFFFF
    li32 t6, 0x0000001F
    binv       s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x00000001
    li32 t6, 0x00000000
    binv       s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0xFFFFFFFE
    li32 t6, 0x00000000
    binv       s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x12345678
    li32 t6, 0x00000023
    binv       s1, t5, t6
    assert_value s1, 0x12345670
    li32 t5, 0x12345678
    li32 t6, 0xFFFFFFFF
    binv       s1, t5, t6
    assert_value s1, 0x92345678
    li32 t5, 0x00000000
    li32 t6, 0x00000010
    binv       s1, t5, t6
    assert_value s1, 0x00010000
    li32 t5, 0xFFFFFFFF
    li32 t6, 0x00000010
    binv       s1, t5, t6
    assert_value s1, 0xFFFEFFFF
    li32 t5, 0x80000000
    li32 t6, 0x0000001F
    bset       s1, t5, t6
    assert_value s1, 0x80000000
    li32 t5, 0x7FFFFFFF
    li32 t6, 0x0000001F
    bset       s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x00000001
    li32 t6, 0x00000000
    bset       s1, t5, t6
    assert_value s1, 0x00000001
    li32 t5, 0xFFFFFFFE
    li32 t6, 0x00000000
    bset       s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x12345678
    li32 t6, 0x00000023
    bset       s1, t5, t6
    assert_value s1, 0x12345678
    li32 t5, 0x12345678
    li32 t6, 0xFFFFFFFF
    bset       s1, t5, t6
    assert_value s1, 0x92345678
    li32 t5, 0x00000000
    li32 t6, 0x00000010
    bset       s1, t5, t6
    assert_value s1, 0x00010000
    li32 t5, 0xFFFFFFFF
    li32 t6, 0x00000010
    bset       s1, t5, t6
    assert_value s1, 0xFFFFFFFF

# -----------------------------------------------
# rd = x0 discards the result, also for the instruction right behind it,
# which must read 0 rather than a forwarded value.
test_rd_is_x0:
    addi t2, zero, 5
    flush_pipeline
    li32 t5, 0x12345678
    li32 t6, 0x0000F00F
    bset       zero, t5, t6
    add  s1, zero, zero           # reads x0 right behind the discarded result
    bset       zero, t5, t6
    add  s2, t5, zero
    assert_value s1, 0x00000000
    assert_value s2, 0x12345678
    bexti      zero, t5, 5
    bexti      s3, zero, 5
    assert_value s3, 0x00000000

# -----------------------------------------------
# x0 as a source operand.
test_x0_source:
    addi t2, zero, 6
    flush_pipeline
    bset       s1, zero, t6
    assert_value s1, 0x00008000
    bset       s1, t5, zero
    assert_value s1, 0x12345679
    bset       s1, zero, zero
    assert_value s1, 0x00000001

# -----------------------------------------------
# rd == rs1, rd == rs2 and rd == rs1 == rs2 all read the OLD operands.
test_aliasing:
    addi t2, zero, 7
    flush_pipeline
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    binv       t5, t5, t6
    assert_value t5, 0x70F01234
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    binv       t6, t5, t6
    assert_value t6, 0x70F01234
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    binv       t5, t5, t5
    assert_value t5, 0xF0E01234
    li32 t5, 0xF0F01234
    bclri      t5, t5, 7
    assert_value t5, 0xF0F01234

# -----------------------------------------------
# rd == rs1, rd == rs2 and rd == rs1 == rs2 all read the OLD operands.
test_aliasing_2:
    addi t2, zero, 8
    flush_pipeline
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    bext       t5, t5, t6
    assert_value t5, 0x00000001
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    bext       t6, t5, t6
    assert_value t6, 0x00000001
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    bext       t5, t5, t5
    assert_value t5, 0x00000001
    li32 t5, 0xF0F01234
    bseti      t5, t5, 7
    assert_value t5, 0xF0F012B4

# -----------------------------------------------
# Forwarding INTO the new instruction: the operand produced 1, 2 and 3
# instructions earlier, into rs1 and into rs2, and both operands
# forwarded from different stages.
test_forward_into:
    addi t2, zero, 9
    flush_pipeline
    li32 t6, 0x00000013
    li32 t5, 0x8001F00F
    bclr       s1, t5, t6
    assert_value s1, 0x8001F00F
    li32 t5, 0x8001F00F
    li32 t6, 0x00000013
    bclr       s2, t5, t6
    assert_value s2, 0x8001F00F
    li32 t6, 0x00000013
    li32 t5, 0x8001F00F
    nop
    bclr       s1, t5, t6
    assert_value s1, 0x8001F00F
    li32 t5, 0x8001F00F
    li32 t6, 0x00000013
    nop
    bclr       s2, t5, t6
    assert_value s2, 0x8001F00F
    li32 t6, 0x00000013
    li32 t5, 0x8001F00F
    nop
    nop
    bclr       s1, t5, t6
    assert_value s1, 0x8001F00F
    li32 t5, 0x8001F00F
    li32 t6, 0x00000013
    nop
    nop
    bclr       s2, t5, t6
    assert_value s2, 0x8001F00F
    li32 t5, 0x8001F00F
    li32 t6, 0x00000013
    bclr       s1, t5, t6
    li32 t6, 0x00000013
    li32 t5, 0x8001F00F
    bclr       s2, t5, t6
    li32 t5, 0x8001F00F
    bclr       s3, t5, t5
    assert_value s1, 0x8001F00F
    assert_value s2, 0x8001F00F
    assert_value s3, 0x8001700F

# -----------------------------------------------
# Forwarding INTO the new instruction: the operand produced 1, 2 and 3
# instructions earlier, into rs1 and into rs2, and both operands
# forwarded from different stages.
test_forward_into_2:
    addi t2, zero, 10
    flush_pipeline
    li32 t6, 0x00000013
    li32 t5, 0x8001F00F
    bext       s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x8001F00F
    li32 t6, 0x00000013
    bext       s2, t5, t6
    assert_value s2, 0x00000000
    li32 t6, 0x00000013
    li32 t5, 0x8001F00F
    nop
    bext       s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x8001F00F
    li32 t6, 0x00000013
    nop
    bext       s2, t5, t6
    assert_value s2, 0x00000000
    li32 t6, 0x00000013
    li32 t5, 0x8001F00F
    nop
    nop
    bext       s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x8001F00F
    li32 t6, 0x00000013
    nop
    nop
    bext       s2, t5, t6
    assert_value s2, 0x00000000
    li32 t5, 0x8001F00F
    li32 t6, 0x00000013
    bext       s1, t5, t6
    li32 t6, 0x00000013
    li32 t5, 0x8001F00F
    bext       s2, t5, t6
    li32 t5, 0x8001F00F
    bext       s3, t5, t5
    assert_value s1, 0x00000000
    assert_value s2, 0x00000000
    assert_value s3, 0x00000001

# -----------------------------------------------
# Forwarding into the immediate forms at distance 1, 2, 3.
test_forward_into_immediate:
    addi t2, zero, 11
    flush_pipeline
    li32 t5, 0x80020F10
    bseti      s1, t5, 9
    assert_value s1, 0x80020F10
    li32 t5, 0x80020F10
    bexti      s1, t5, 31
    assert_value s1, 0x00000001
    li32 t5, 0x80020F10
    binvi      s1, t5, 0
    assert_value s1, 0x80020F11
    li32 t5, 0x80020F10
    bclri      s1, t5, 17
    assert_value s1, 0x80000F10
    li32 t5, 0x80020F20
    nop
    bseti      s1, t5, 9
    assert_value s1, 0x80020F20
    li32 t5, 0x80020F20
    nop
    bexti      s1, t5, 31
    assert_value s1, 0x00000001
    li32 t5, 0x80020F20
    nop
    binvi      s1, t5, 0
    assert_value s1, 0x80020F21
    li32 t5, 0x80020F20
    nop
    bclri      s1, t5, 17
    assert_value s1, 0x80000F20
    li32 t5, 0x80020F30
    nop
    nop
    bseti      s1, t5, 9
    assert_value s1, 0x80020F30
    li32 t5, 0x80020F30
    nop
    nop
    bexti      s1, t5, 31
    assert_value s1, 0x00000001
    li32 t5, 0x80020F30
    nop
    nop
    binvi      s1, t5, 0
    assert_value s1, 0x80020F31
    li32 t5, 0x80020F30
    nop
    nop
    bclri      s1, t5, 17
    assert_value s1, 0x80000F30

# -----------------------------------------------
# A load feeding the new instruction directly (load-use stall in front of it),
# into rs1, into rs2 and into both.
test_load_use:
    addi t2, zero, 12
    flush_pipeline
    li32 t6, 0x00000005
    lw   t5, 12(t4)
    binv       s1, t5, t6
    assert_value s1, 0x12345658
    li32 t5, 0x7FFFFFFF
    lw   t6, 4(t4)
    binv       s2, t5, t6
    assert_value s2, 0x7FFFFFFE
    lw   t5, 8(t4)
    lw   t6, 12(t4)
    binv       s3, t5, t6
    assert_value s3, 0x01FF00FF
    lw   t5, 4(t4)
    bexti      s4, t5, 31
    assert_value s4, 0x00000001

# -----------------------------------------------
# Forwarding OUT of the new instruction, consumed by the very next
# instruction: an ALU op, a branch, a load address, store data, a
# JALR base and a CSR write.
test_forward_out_of:
    addi t2, zero, 13
    flush_pipeline
    li32 t5, 0x00000080
    bexti      s1, t5, 7
    addi s2, s1, 1
    assert_value s2, 0x00000002
    li32 s3, 0x00000020
    li32 t5, 0x00000000
    addi t6, zero, 37
    bset       s1, t5, t6
    bne  s1, s3, fwd_branch_bad_3
    beq  zero, zero, fwd_branch_ok_2
fwd_branch_bad_3:
    fail
fwd_branch_ok_2:
    bseti      s1, t4, 3
    lw   s2, 0(s1)
    assert_value s2, 0x00FF00FF
    li32 t5, 0x00001234
    binvi      s1, t5, 31
    sw   s1, 20(t4)              # scratch_var
    flush_pipeline
    lw   s2, 20(t4)
    assert_value s2, 0x80001234
    addi s4, zero, 0
    li32 t5, zbs_jalr_target_1
    bclri      s1, t5, 31
    jalr ra, 0(s1)
    fail                          # not reached
    beq  zero, zero, jalr_back_4
zbs_jalr_target_1:
    addi s4, zero, 1
jalr_back_4:
    assert_value s4, 0x00000001
    li32 t5, 0xFFFFFFFF
    addi t6, zero, 4
    bclr       s1, t5, t6
    csrw mscratch, s1
    csrr s2, mscratch
    assert_value s2, 0xFFFFFFEF

# -----------------------------------------------
# An instruction in the shadow of a taken branch must not execute, and
# the new instruction works as a branch target.
test_branch_shadow:
    addi t2, zero, 14
    flush_pipeline
    li32 s1, 0x0000ABCD
    li32 t5, 0x00000000
    li32 t6, 0x00000000
    beq  zero, zero, shadow_target_5
    bset       s1, t5, t6
    bset       s1, t5, t6
    fail
shadow_target_5:
    bexti      s2, t5, 3
    assert_value s1, 0x0000ABCD
    assert_value s2, 0x00000000

# -----------------------------------------------
# Before and after fence.i, which refetches everything behind it.
test_fence_i:
    addi t2, zero, 15
    flush_pipeline
    li32 t5, 0x0000F000
    li32 t6, 0x0000000C
    binv       s1, t5, t6
    fence.i
    binv       s2, s1, t6
    assert_value s1, 0x0000E000
    assert_value s2, 0x0000F000

# -----------------------------------------------
# minstret rises by exactly N over N of the new instructions: the
# difference between a window with them and an empty window.
test_minstret:
    addi t2, zero, 16
    flush_pipeline
    li32 a0, 0x0F1E2D3C
    li32 a1, 0x00000017
    flush_pipeline
    csrr s5, minstret
    csrr s6, minstret
    sub  s8, s6, s5
    flush_pipeline
    csrr s5, minstret
    bseti      a0, a0, 3
    binv       a0, a0, a1
    bclri      a0, a0, 0
    bset       a0, a1, a0
    binvi      a0, a0, 31
    bclr       a0, a0, a1
    bset       a0, a0, a1
    binv       a0, a1, a0
    bseti      a0, a0, 30
    bclr       a0, a1, a0
    binvi      a0, a0, 5
    bclri      a0, a0, 12
    bset       a0, a0, a1
    binv       a0, a0, a1
    bext       a0, a0, a1
    bexti      a0, a0, 0
    csrr s6, minstret
    sub  s9, s6, s5
    sub  s9, s9, s8
    assert_value s9, 0x00000010
    assert_value a0, 0x00000000

# -----------------------------------------------
# A chain of 16 back-to-back DEPENDENT instructions takes exactly as many
# cycles as the same chain of add instructions: the result is forwarded
# in its own cycle and nothing stalls (mcycle, read at the same points).
test_cycle_exact:
    addi t2, zero, 17
    flush_pipeline
    li32 a0, 0x0F1E2D3C
    li32 a1, 0x00000017
    flush_pipeline
    csrr s5, mcycle
    bseti      a0, a0, 3
    binv       a0, a0, a1
    bclri      a0, a0, 0
    bset       a0, a1, a0
    binvi      a0, a0, 31
    bclr       a0, a0, a1
    bset       a0, a0, a1
    binv       a0, a1, a0
    bseti      a0, a0, 30
    bclr       a0, a1, a0
    binvi      a0, a0, 5
    bclri      a0, a0, 12
    bset       a0, a0, a1
    binv       a0, a0, a1
    bext       a0, a0, a1
    bexti      a0, a0, 0
    csrr s6, mcycle
    sub  s8, s6, s5
    mv   s4, a0
    li32 a0, 0x0F1E2D3C
    li32 a1, 0x00000017
    flush_pipeline
    csrr s5, mcycle
    addi       a0, a0, 1
    add        a0, a0, a1
    addi       a0, a0, 1
    add        a0, a1, a0
    addi       a0, a0, 1
    add        a0, a0, a1
    add        a0, a0, a1
    add        a0, a1, a0
    addi       a0, a0, 1
    add        a0, a1, a0
    addi       a0, a0, 1
    addi       a0, a0, 1
    add        a0, a0, a1
    add        a0, a0, a1
    add        a0, a0, a1
    addi       a0, a0, 1
    csrr s6, mcycle
    sub  s9, s6, s5
    assert_equal s8, s9
    assert_value s4, 0x00000000
    addi s9, s8, -17
    assert_value s9, 0x00000000

# -----------------------------------------------
# An external interrupt landing at every position of a chain of the
# new instructions: the chain's result and the count are unchanged.
test_interrupt_in_chain:
    addi t2, zero, 18
    flush_pipeline
    li32 t6, ext_irq_handler
    csrw mtvec, t6
    slli t6, t1, 11
    csrs mie, t6
    slli t6, t1, 3
    csrs mstatus, t6
    addi s7, zero, 0
    li32 a0, 0x0F1E2D3C
    li32 a1, 0x00000017
    flush_pipeline
    interrupt 1
    bseti      a0, a0, 3
    binv       a0, a0, a1
    bclri      a0, a0, 0
    bset       a0, a1, a0
    binvi      a0, a0, 31
    bclr       a0, a0, a1
    bset       a0, a0, a1
    binv       a0, a1, a0
    bseti      a0, a0, 30
    bclr       a0, a1, a0
    binvi      a0, a0, 5
    bclri      a0, a0, 12
    bset       a0, a0, a1
    binv       a0, a0, a1
    bext       a0, a0, a1
    bexti      a0, a0, 0
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x00000000
    li32 a0, 0x0F1E2D3C
    li32 a1, 0x00000017
    flush_pipeline
    interrupt 2
    bseti      a0, a0, 3
    binv       a0, a0, a1
    bclri      a0, a0, 0
    bset       a0, a1, a0
    binvi      a0, a0, 31
    bclr       a0, a0, a1
    bset       a0, a0, a1
    binv       a0, a1, a0
    bseti      a0, a0, 30
    bclr       a0, a1, a0
    binvi      a0, a0, 5
    bclri      a0, a0, 12
    bset       a0, a0, a1
    binv       a0, a0, a1
    bext       a0, a0, a1
    bexti      a0, a0, 0
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x00000000
    li32 a0, 0x0F1E2D3C
    li32 a1, 0x00000017
    flush_pipeline
    interrupt 3
    bseti      a0, a0, 3
    binv       a0, a0, a1
    bclri      a0, a0, 0
    bset       a0, a1, a0
    binvi      a0, a0, 31
    bclr       a0, a0, a1
    bset       a0, a0, a1
    binv       a0, a1, a0
    bseti      a0, a0, 30
    bclr       a0, a1, a0
    binvi      a0, a0, 5
    bclri      a0, a0, 12
    bset       a0, a0, a1
    binv       a0, a0, a1
    bext       a0, a0, a1
    bexti      a0, a0, 0
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x00000000
    li32 a0, 0x0F1E2D3C
    li32 a1, 0x00000017
    flush_pipeline
    interrupt 4
    bseti      a0, a0, 3
    binv       a0, a0, a1
    bclri      a0, a0, 0
    bset       a0, a1, a0
    binvi      a0, a0, 31
    bclr       a0, a0, a1
    bset       a0, a0, a1
    binv       a0, a1, a0
    bseti      a0, a0, 30
    bclr       a0, a1, a0
    binvi      a0, a0, 5
    bclri      a0, a0, 12
    bset       a0, a0, a1
    binv       a0, a0, a1
    bext       a0, a0, a1
    bexti      a0, a0, 0
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x00000000
    li32 a0, 0x0F1E2D3C
    li32 a1, 0x00000017
    flush_pipeline
    interrupt 5
    bseti      a0, a0, 3
    binv       a0, a0, a1
    bclri      a0, a0, 0
    bset       a0, a1, a0
    binvi      a0, a0, 31
    bclr       a0, a0, a1
    bset       a0, a0, a1
    binv       a0, a1, a0
    bseti      a0, a0, 30
    bclr       a0, a1, a0
    binvi      a0, a0, 5
    bclri      a0, a0, 12
    bset       a0, a0, a1
    binv       a0, a0, a1
    bext       a0, a0, a1
    bexti      a0, a0, 0
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x00000000
    li32 a0, 0x0F1E2D3C
    li32 a1, 0x00000017
    flush_pipeline
    interrupt 6
    bseti      a0, a0, 3
    binv       a0, a0, a1
    bclri      a0, a0, 0
    bset       a0, a1, a0
    binvi      a0, a0, 31
    bclr       a0, a0, a1
    bset       a0, a0, a1
    binv       a0, a1, a0
    bseti      a0, a0, 30
    bclr       a0, a1, a0
    binvi      a0, a0, 5
    bclri      a0, a0, 12
    bset       a0, a0, a1
    binv       a0, a0, a1
    bext       a0, a0, a1
    bexti      a0, a0, 0
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x00000000
    li32 a0, 0x0F1E2D3C
    li32 a1, 0x00000017
    flush_pipeline
    interrupt 7
    bseti      a0, a0, 3
    binv       a0, a0, a1
    bclri      a0, a0, 0
    bset       a0, a1, a0
    binvi      a0, a0, 31
    bclr       a0, a0, a1
    bset       a0, a0, a1
    binv       a0, a1, a0
    bseti      a0, a0, 30
    bclr       a0, a1, a0
    binvi      a0, a0, 5
    bclri      a0, a0, 12
    bset       a0, a0, a1
    binv       a0, a0, a1
    bext       a0, a0, a1
    bexti      a0, a0, 0
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x00000000
    li32 a0, 0x0F1E2D3C
    li32 a1, 0x00000017
    flush_pipeline
    interrupt 8
    bseti      a0, a0, 3
    binv       a0, a0, a1
    bclri      a0, a0, 0
    bset       a0, a1, a0
    binvi      a0, a0, 31
    bclr       a0, a0, a1
    bset       a0, a0, a1
    binv       a0, a1, a0
    bseti      a0, a0, 30
    bclr       a0, a1, a0
    binvi      a0, a0, 5
    bclri      a0, a0, 12
    bset       a0, a0, a1
    binv       a0, a0, a1
    bext       a0, a0, a1
    bexti      a0, a0, 0
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x00000000
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
    addi t2, zero, 19
    flush_pipeline
    li32 t5, record_trap
    csrw mtvec, t5
    flush_pipeline
    expect_trap 0x4A059513, 2       # bclri with shamt[5] = 1 (reserved on RV32)
    expect_trap 0x4A05D513, 2       # bexti with shamt[5] = 1
    expect_trap 0x6A059513, 2       # binvi with shamt[5] = 1
    expect_trap 0x2A059513, 2       # bseti with shamt[5] = 1
    expect_trap 0x28C5A533, 2       # xperm4 (Zbkx)
    expect_trap 0x28C5C533, 2       # xperm8 (Zbkx)
    expect_trap 0x48C58533, 2       # funct7 0100100, funct3 000
    expect_trap 0x48C5F533, 2       # funct7 0100100, funct3 111
    expect_trap 0x68C5D533, 2       # funct7 0110100, funct3 101
    expect_trap 0x28C5D533, 2       # funct7 0010100, funct3 101
    li32 t5, unexpected_trap
    csrw mtvec, t5
    flush_pipeline

# ------------------------------------------------------------------------------------------------
# |                                          Test done!                                          |
# ------------------------------------------------------------------------------------------------
test_finish:
    addi t2, zero, 20
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
