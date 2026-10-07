# Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
# Embedded Architectures & Systems Group, Graz University of Technology
# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: zbb.s
#
# ------------------------------------------------------------------------------------------------
# |                                                                                              |
# | Zbb extension test (basic bit manipulation, 18 instructions on RV32).                        |
# | andn orn xnor, clz ctz cpop, min max minu maxu, sext.b sext.h zext.h,                        |
# | rol ror rori, orc.b rev8.                                                                    |
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
# | 1. The known answers of the ISA text and corner operands for every instruction:              |
# |    operand order (andn is rs1 & ~rs2), clz/ctz of 0 = 32, signed vs unsigned                 |
# |    min/max, sign bit 7/15 for sext.b/sext.h, orc.b per byte, rev8 bytes not bits.            |
# | 2. Rotates by every amount 0..31: rol/ror with the upper 27 bits of rs2 set (ignored),       |
# |    rori with every shamt; 0x6005D513 is the legal rori a0, a1, 0.                            |
# | 3. rd = x0 discarded (also for the instruction right behind it), x0 as a source,             |
# |    rd == rs1 / rs2 / both.                                                                   |
# | 4. Forwarding into rs1 and rs2 at distance 1, 2, 3, from two stages at once; a               |
# |    load-use stall in front; forwarding out into an ALU op, a branch, a load address,         |
# |    store data, a JALR base and a CSR write.                                                  |
# | 5. Not executed in the shadow of a taken branch; correct as a branch target; around          |
# |    fence.i; an interrupt at every position of a chain changes nothing.                       |
# | 6. minstret counts each instruction once; a dependent chain takes exactly as many            |
# |    cycles as the same chain of add (no stall, forwarded in its own cycle).                   |
# | 7. The illegal neighbours (RV32-reserved, Zbc/RV64 encodings, unused funct3/funct7/rs2       |
# |    fields, the neighbours of the Zbkb forms) raise illegal-instruction.                      |
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
    li32 t5, 0x00000000
    clz        s1, t5
    assert_value s1, 0x00000020
    li32 t5, 0x00000001
    clz        s1, t5
    assert_value s1, 0x0000001F
    li32 t5, 0x80000000
    clz        s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0x00000000
    ctz        s1, t5
    assert_value s1, 0x00000020
    li32 t5, 0x80000000
    ctz        s1, t5
    assert_value s1, 0x0000001F
    li32 t5, 0xFFFFFFFF
    cpop       s1, t5
    assert_value s1, 0x00000020
    li32 t5, 0x00010080
    orc.b      s1, t5
    assert_value s1, 0x00FF00FF
    li32 t5, 0x12345678
    rev8       s1, t5
    assert_value s1, 0x78563412
    li32 t5, 0x00000080
    sext.b     s1, t5
    assert_value s1, 0xFFFFFF80
    li32 t5, 0x12348000
    sext.h     s1, t5
    assert_value s1, 0xFFFF8000
    li32 t5, 0xFFFF8000
    zext.h     s1, t5
    assert_value s1, 0x00008000
    li32 t5, 0x80000001
    li32 t6, 0x00000001
    rol        s1, t5, t6
    assert_value s1, 0x00000003
    li32 t5, 0x00000003
    li32 t6, 0x00000001
    ror        s1, t5, t6
    assert_value s1, 0x80000001
    li32 t5, 0xFFFFFFFF
    li32 t6, 0x00000001
    min        s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0xFFFFFFFF
    li32 t6, 0x00000001
    minu       s1, t5, t6
    assert_value s1, 0x00000001

# -----------------------------------------------
# andn, orn, xnor: rs1 combined with the COMPLEMENT of rs2 (never of rs1).
test_logic:
    addi t2, zero, 2
    flush_pipeline
    li32 t5, 0xFFFF0000
    li32 t6, 0x0F0F0F0F
    andn       s1, t5, t6
    assert_value s1, 0xF0F00000
    li32 t5, 0x0F0F0F0F
    li32 t6, 0xFFFF0000
    andn       s1, t5, t6
    assert_value s1, 0x00000F0F
    li32 t5, 0x00000000
    li32 t6, 0x00000000
    andn       s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0xFFFFFFFF
    li32 t6, 0x00000000
    andn       s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x00000000
    li32 t6, 0xFFFFFFFF
    andn       s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x12345678
    li32 t6, 0x12345678
    andn       s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x80000000
    li32 t6, 0x7FFFFFFF
    andn       s1, t5, t6
    assert_value s1, 0x80000000
    li32 t5, 0xFFFF0000
    li32 t6, 0x0F0F0F0F
    orn        s1, t5, t6
    assert_value s1, 0xFFFFF0F0
    li32 t5, 0x0F0F0F0F
    li32 t6, 0xFFFF0000
    orn        s1, t5, t6
    assert_value s1, 0x0F0FFFFF
    li32 t5, 0x00000000
    li32 t6, 0x00000000
    orn        s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0xFFFFFFFF
    li32 t6, 0x00000000
    orn        s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x00000000
    li32 t6, 0xFFFFFFFF
    orn        s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x12345678
    li32 t6, 0x12345678
    orn        s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x80000000
    li32 t6, 0x7FFFFFFF
    orn        s1, t5, t6
    assert_value s1, 0x80000000
    li32 t5, 0xFFFF0000
    li32 t6, 0x0F0F0F0F
    xnor       s1, t5, t6
    assert_value s1, 0x0F0FF0F0
    li32 t5, 0x0F0F0F0F
    li32 t6, 0xFFFF0000
    xnor       s1, t5, t6
    assert_value s1, 0x0F0FF0F0
    li32 t5, 0x00000000
    li32 t6, 0x00000000
    xnor       s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0xFFFFFFFF
    li32 t6, 0x00000000
    xnor       s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000000
    li32 t6, 0xFFFFFFFF
    xnor       s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x12345678
    li32 t6, 0x12345678
    xnor       s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x80000000
    li32 t6, 0x7FFFFFFF
    xnor       s1, t5, t6
    assert_value s1, 0x00000000

# -----------------------------------------------
# clz, ctz, cpop on corner values (0 counts 32 for clz and ctz).
test_counts:
    addi t2, zero, 3
    flush_pipeline
    li32 t5, 0x00000000
    clz        s1, t5
    assert_value s1, 0x00000020
    li32 t5, 0x00000001
    clz        s1, t5
    assert_value s1, 0x0000001F
    li32 t5, 0xFFFFFFFF
    clz        s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0x80000000
    clz        s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0x7FFFFFFF
    clz        s1, t5
    assert_value s1, 0x00000001
    li32 t5, 0x000000FF
    clz        s1, t5
    assert_value s1, 0x00000018
    li32 t5, 0x00000080
    clz        s1, t5
    assert_value s1, 0x00000018
    li32 t5, 0x0000FFFF
    clz        s1, t5
    assert_value s1, 0x00000010
    li32 t5, 0x00008000
    clz        s1, t5
    assert_value s1, 0x00000010
    li32 t5, 0x00010000
    clz        s1, t5
    assert_value s1, 0x0000000F
    li32 t5, 0xFFFF0000
    clz        s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0x12345678
    clz        s1, t5
    assert_value s1, 0x00000003
    li32 t5, 0xDEADBEEF
    clz        s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0x00010080
    clz        s1, t5
    assert_value s1, 0x0000000F
    li32 t5, 0x00000008
    clz        s1, t5
    assert_value s1, 0x0000001C
    li32 t5, 0x00008000
    clz        s1, t5
    assert_value s1, 0x00000010
    li32 t5, 0x00010000
    clz        s1, t5
    assert_value s1, 0x0000000F
    li32 t5, 0x40000000
    clz        s1, t5
    assert_value s1, 0x00000001
    li32 t5, 0x00000000
    ctz        s1, t5
    assert_value s1, 0x00000020
    li32 t5, 0x00000001
    ctz        s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0xFFFFFFFF
    ctz        s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0x80000000
    ctz        s1, t5
    assert_value s1, 0x0000001F
    li32 t5, 0x7FFFFFFF
    ctz        s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0x000000FF
    ctz        s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0x00000080
    ctz        s1, t5
    assert_value s1, 0x00000007
    li32 t5, 0x0000FFFF
    ctz        s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0x00008000
    ctz        s1, t5
    assert_value s1, 0x0000000F
    li32 t5, 0x00010000
    ctz        s1, t5
    assert_value s1, 0x00000010
    li32 t5, 0xFFFF0000
    ctz        s1, t5
    assert_value s1, 0x00000010
    li32 t5, 0x12345678
    ctz        s1, t5
    assert_value s1, 0x00000003
    li32 t5, 0xDEADBEEF
    ctz        s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0x00010080
    ctz        s1, t5
    assert_value s1, 0x00000007
    li32 t5, 0x00000008
    ctz        s1, t5
    assert_value s1, 0x00000003
    li32 t5, 0x00008000
    ctz        s1, t5
    assert_value s1, 0x0000000F
    li32 t5, 0x00010000
    ctz        s1, t5
    assert_value s1, 0x00000010
    li32 t5, 0x40000000
    ctz        s1, t5
    assert_value s1, 0x0000001E
    li32 t5, 0x00000000
    cpop       s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0x00000001
    cpop       s1, t5
    assert_value s1, 0x00000001
    li32 t5, 0xFFFFFFFF
    cpop       s1, t5
    assert_value s1, 0x00000020
    li32 t5, 0x80000000
    cpop       s1, t5
    assert_value s1, 0x00000001
    li32 t5, 0x7FFFFFFF
    cpop       s1, t5
    assert_value s1, 0x0000001F
    li32 t5, 0x000000FF
    cpop       s1, t5
    assert_value s1, 0x00000008
    li32 t5, 0x00000080
    cpop       s1, t5
    assert_value s1, 0x00000001
    li32 t5, 0x0000FFFF
    cpop       s1, t5
    assert_value s1, 0x00000010
    li32 t5, 0x00008000
    cpop       s1, t5
    assert_value s1, 0x00000001
    li32 t5, 0x00010000
    cpop       s1, t5
    assert_value s1, 0x00000001
    li32 t5, 0xFFFF0000
    cpop       s1, t5
    assert_value s1, 0x00000010
    li32 t5, 0x12345678
    cpop       s1, t5
    assert_value s1, 0x0000000D
    li32 t5, 0xDEADBEEF
    cpop       s1, t5
    assert_value s1, 0x00000018
    li32 t5, 0x00010080
    cpop       s1, t5
    assert_value s1, 0x00000002
    li32 t5, 0x00000008
    cpop       s1, t5
    assert_value s1, 0x00000001
    li32 t5, 0x00008000
    cpop       s1, t5
    assert_value s1, 0x00000001
    li32 t5, 0x00010000
    cpop       s1, t5
    assert_value s1, 0x00000001
    li32 t5, 0x40000000
    cpop       s1, t5
    assert_value s1, 0x00000001

# -----------------------------------------------
# min, max (signed) and minu, maxu (unsigned), including the corners where
# the signed and unsigned orders disagree.
test_min_max:
    addi t2, zero, 4
    flush_pipeline
    li32 t5, 0x00000000
    li32 t6, 0x00000000
    min        s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000000
    li32 t6, 0x00000001
    min        s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000001
    li32 t6, 0x00000000
    min        s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0xFFFFFFFF
    li32 t6, 0x00000001
    min        s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x00000001
    li32 t6, 0xFFFFFFFF
    min        s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x80000000
    li32 t6, 0x7FFFFFFF
    min        s1, t5, t6
    assert_value s1, 0x80000000
    li32 t5, 0x7FFFFFFF
    li32 t6, 0x80000000
    min        s1, t5, t6
    assert_value s1, 0x80000000
    li32 t5, 0x80000000
    li32 t6, 0xFFFFFFFF
    min        s1, t5, t6
    assert_value s1, 0x80000000
    li32 t5, 0xFFFFFFFF
    li32 t6, 0xFFFFFFFF
    min        s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x12345678
    li32 t6, 0x0F0F0F0F
    min        s1, t5, t6
    assert_value s1, 0x0F0F0F0F
    li32 t5, 0xDEADBEEF
    li32 t6, 0xFFFF0000
    min        s1, t5, t6
    assert_value s1, 0xDEADBEEF
    li32 t5, 0x000000FF
    li32 t6, 0x00000080
    min        s1, t5, t6
    assert_value s1, 0x00000080
    li32 t5, 0x80000000
    li32 t6, 0x80000000
    min        s1, t5, t6
    assert_value s1, 0x80000000
    li32 t5, 0x00008000
    li32 t6, 0xFFFF8000
    min        s1, t5, t6
    assert_value s1, 0xFFFF8000
    li32 t5, 0x00000000
    li32 t6, 0x00000000
    max        s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000000
    li32 t6, 0x00000001
    max        s1, t5, t6
    assert_value s1, 0x00000001
    li32 t5, 0x00000001
    li32 t6, 0x00000000
    max        s1, t5, t6
    assert_value s1, 0x00000001
    li32 t5, 0xFFFFFFFF
    li32 t6, 0x00000001
    max        s1, t5, t6
    assert_value s1, 0x00000001
    li32 t5, 0x00000001
    li32 t6, 0xFFFFFFFF
    max        s1, t5, t6
    assert_value s1, 0x00000001
    li32 t5, 0x80000000
    li32 t6, 0x7FFFFFFF
    max        s1, t5, t6
    assert_value s1, 0x7FFFFFFF
    li32 t5, 0x7FFFFFFF
    li32 t6, 0x80000000
    max        s1, t5, t6
    assert_value s1, 0x7FFFFFFF
    li32 t5, 0x80000000
    li32 t6, 0xFFFFFFFF
    max        s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0xFFFFFFFF
    li32 t6, 0xFFFFFFFF
    max        s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x12345678
    li32 t6, 0x0F0F0F0F
    max        s1, t5, t6
    assert_value s1, 0x12345678
    li32 t5, 0xDEADBEEF
    li32 t6, 0xFFFF0000
    max        s1, t5, t6
    assert_value s1, 0xFFFF0000
    li32 t5, 0x000000FF
    li32 t6, 0x00000080
    max        s1, t5, t6
    assert_value s1, 0x000000FF
    li32 t5, 0x80000000
    li32 t6, 0x80000000
    max        s1, t5, t6
    assert_value s1, 0x80000000
    li32 t5, 0x00008000
    li32 t6, 0xFFFF8000
    max        s1, t5, t6
    assert_value s1, 0x00008000
    li32 t5, 0x00000000
    li32 t6, 0x00000000
    minu       s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000000
    li32 t6, 0x00000001
    minu       s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000001
    li32 t6, 0x00000000
    minu       s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0xFFFFFFFF
    li32 t6, 0x00000001
    minu       s1, t5, t6
    assert_value s1, 0x00000001
    li32 t5, 0x00000001
    li32 t6, 0xFFFFFFFF
    minu       s1, t5, t6
    assert_value s1, 0x00000001
    li32 t5, 0x80000000
    li32 t6, 0x7FFFFFFF
    minu       s1, t5, t6
    assert_value s1, 0x7FFFFFFF
    li32 t5, 0x7FFFFFFF
    li32 t6, 0x80000000
    minu       s1, t5, t6
    assert_value s1, 0x7FFFFFFF
    li32 t5, 0x80000000
    li32 t6, 0xFFFFFFFF
    minu       s1, t5, t6
    assert_value s1, 0x80000000
    li32 t5, 0xFFFFFFFF
    li32 t6, 0xFFFFFFFF
    minu       s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x12345678
    li32 t6, 0x0F0F0F0F
    minu       s1, t5, t6
    assert_value s1, 0x0F0F0F0F
    li32 t5, 0xDEADBEEF
    li32 t6, 0xFFFF0000
    minu       s1, t5, t6
    assert_value s1, 0xDEADBEEF
    li32 t5, 0x000000FF
    li32 t6, 0x00000080
    minu       s1, t5, t6
    assert_value s1, 0x00000080
    li32 t5, 0x80000000
    li32 t6, 0x80000000
    minu       s1, t5, t6
    assert_value s1, 0x80000000
    li32 t5, 0x00008000
    li32 t6, 0xFFFF8000
    minu       s1, t5, t6
    assert_value s1, 0x00008000
    li32 t5, 0x00000000
    li32 t6, 0x00000000
    maxu       s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000000
    li32 t6, 0x00000001
    maxu       s1, t5, t6
    assert_value s1, 0x00000001
    li32 t5, 0x00000001
    li32 t6, 0x00000000
    maxu       s1, t5, t6
    assert_value s1, 0x00000001
    li32 t5, 0xFFFFFFFF
    li32 t6, 0x00000001
    maxu       s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x00000001
    li32 t6, 0xFFFFFFFF
    maxu       s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x80000000
    li32 t6, 0x7FFFFFFF
    maxu       s1, t5, t6
    assert_value s1, 0x80000000
    li32 t5, 0x7FFFFFFF
    li32 t6, 0x80000000
    maxu       s1, t5, t6
    assert_value s1, 0x80000000
    li32 t5, 0x80000000
    li32 t6, 0xFFFFFFFF
    maxu       s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0xFFFFFFFF
    li32 t6, 0xFFFFFFFF
    maxu       s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x12345678
    li32 t6, 0x0F0F0F0F
    maxu       s1, t5, t6
    assert_value s1, 0x12345678
    li32 t5, 0xDEADBEEF
    li32 t6, 0xFFFF0000
    maxu       s1, t5, t6
    assert_value s1, 0xFFFF0000
    li32 t5, 0x000000FF
    li32 t6, 0x00000080
    maxu       s1, t5, t6
    assert_value s1, 0x000000FF
    li32 t5, 0x80000000
    li32 t6, 0x80000000
    maxu       s1, t5, t6
    assert_value s1, 0x80000000
    li32 t5, 0x00008000
    li32 t6, 0xFFFF8000
    maxu       s1, t5, t6
    assert_value s1, 0xFFFF8000

# -----------------------------------------------
# sext.b (bit 7), sext.h (bit 15), zext.h (upper half cleared).
test_extend:
    addi t2, zero, 5
    flush_pipeline
    li32 t5, 0x00000000
    sext.b     s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0x00000001
    sext.b     s1, t5
    assert_value s1, 0x00000001
    li32 t5, 0xFFFFFFFF
    sext.b     s1, t5
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x80000000
    sext.b     s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0x7FFFFFFF
    sext.b     s1, t5
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x000000FF
    sext.b     s1, t5
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x00000080
    sext.b     s1, t5
    assert_value s1, 0xFFFFFF80
    li32 t5, 0x0000FFFF
    sext.b     s1, t5
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x00008000
    sext.b     s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0x00010000
    sext.b     s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0xFFFF0000
    sext.b     s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0x12345678
    sext.b     s1, t5
    assert_value s1, 0x00000078
    li32 t5, 0xDEADBEEF
    sext.b     s1, t5
    assert_value s1, 0xFFFFFFEF
    li32 t5, 0x00010080
    sext.b     s1, t5
    assert_value s1, 0xFFFFFF80
    li32 t5, 0x0000007F
    sext.b     s1, t5
    assert_value s1, 0x0000007F
    li32 t5, 0x00007FFF
    sext.b     s1, t5
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0xFFFFFF7F
    sext.b     s1, t5
    assert_value s1, 0x0000007F
    li32 t5, 0x12348000
    sext.b     s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0x00000000
    sext.h     s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0x00000001
    sext.h     s1, t5
    assert_value s1, 0x00000001
    li32 t5, 0xFFFFFFFF
    sext.h     s1, t5
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x80000000
    sext.h     s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0x7FFFFFFF
    sext.h     s1, t5
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x000000FF
    sext.h     s1, t5
    assert_value s1, 0x000000FF
    li32 t5, 0x00000080
    sext.h     s1, t5
    assert_value s1, 0x00000080
    li32 t5, 0x0000FFFF
    sext.h     s1, t5
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x00008000
    sext.h     s1, t5
    assert_value s1, 0xFFFF8000
    li32 t5, 0x00010000
    sext.h     s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0xFFFF0000
    sext.h     s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0x12345678
    sext.h     s1, t5
    assert_value s1, 0x00005678
    li32 t5, 0xDEADBEEF
    sext.h     s1, t5
    assert_value s1, 0xFFFFBEEF
    li32 t5, 0x00010080
    sext.h     s1, t5
    assert_value s1, 0x00000080
    li32 t5, 0x0000007F
    sext.h     s1, t5
    assert_value s1, 0x0000007F
    li32 t5, 0x00007FFF
    sext.h     s1, t5
    assert_value s1, 0x00007FFF
    li32 t5, 0xFFFFFF7F
    sext.h     s1, t5
    assert_value s1, 0xFFFFFF7F
    li32 t5, 0x12348000
    sext.h     s1, t5
    assert_value s1, 0xFFFF8000
    li32 t5, 0x00000000
    zext.h     s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0x00000001
    zext.h     s1, t5
    assert_value s1, 0x00000001
    li32 t5, 0xFFFFFFFF
    zext.h     s1, t5
    assert_value s1, 0x0000FFFF
    li32 t5, 0x80000000
    zext.h     s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0x7FFFFFFF
    zext.h     s1, t5
    assert_value s1, 0x0000FFFF
    li32 t5, 0x000000FF
    zext.h     s1, t5
    assert_value s1, 0x000000FF
    li32 t5, 0x00000080
    zext.h     s1, t5
    assert_value s1, 0x00000080
    li32 t5, 0x0000FFFF
    zext.h     s1, t5
    assert_value s1, 0x0000FFFF
    li32 t5, 0x00008000
    zext.h     s1, t5
    assert_value s1, 0x00008000
    li32 t5, 0x00010000
    zext.h     s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0xFFFF0000
    zext.h     s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0x12345678
    zext.h     s1, t5
    assert_value s1, 0x00005678
    li32 t5, 0xDEADBEEF
    zext.h     s1, t5
    assert_value s1, 0x0000BEEF
    li32 t5, 0x00010080
    zext.h     s1, t5
    assert_value s1, 0x00000080
    li32 t5, 0x0000007F
    zext.h     s1, t5
    assert_value s1, 0x0000007F
    li32 t5, 0x00007FFF
    zext.h     s1, t5
    assert_value s1, 0x00007FFF
    li32 t5, 0xFFFFFF7F
    zext.h     s1, t5
    assert_value s1, 0x0000FF7F
    li32 t5, 0x12348000
    zext.h     s1, t5
    assert_value s1, 0x00008000

# -----------------------------------------------
# orc.b (each byte 0x00 or 0xFF) and rev8 (bytes, not bits, reversed).
test_byte:
    addi t2, zero, 6
    flush_pipeline
    li32 t5, 0x00000000
    orc.b      s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0x00000001
    orc.b      s1, t5
    assert_value s1, 0x000000FF
    li32 t5, 0xFFFFFFFF
    orc.b      s1, t5
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x80000000
    orc.b      s1, t5
    assert_value s1, 0xFF000000
    li32 t5, 0x7FFFFFFF
    orc.b      s1, t5
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x000000FF
    orc.b      s1, t5
    assert_value s1, 0x000000FF
    li32 t5, 0x00000080
    orc.b      s1, t5
    assert_value s1, 0x000000FF
    li32 t5, 0x0000FFFF
    orc.b      s1, t5
    assert_value s1, 0x0000FFFF
    li32 t5, 0x00008000
    orc.b      s1, t5
    assert_value s1, 0x0000FF00
    li32 t5, 0x00010000
    orc.b      s1, t5
    assert_value s1, 0x00FF0000
    li32 t5, 0xFFFF0000
    orc.b      s1, t5
    assert_value s1, 0xFFFF0000
    li32 t5, 0x12345678
    orc.b      s1, t5
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0xDEADBEEF
    orc.b      s1, t5
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x00010080
    orc.b      s1, t5
    assert_value s1, 0x00FF00FF
    li32 t5, 0x01000000
    orc.b      s1, t5
    assert_value s1, 0xFF000000
    li32 t5, 0x00000100
    orc.b      s1, t5
    assert_value s1, 0x0000FF00
    li32 t5, 0x80808080
    orc.b      s1, t5
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x01020304
    orc.b      s1, t5
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x00000000
    rev8       s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0x00000001
    rev8       s1, t5
    assert_value s1, 0x01000000
    li32 t5, 0xFFFFFFFF
    rev8       s1, t5
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x80000000
    rev8       s1, t5
    assert_value s1, 0x00000080
    li32 t5, 0x7FFFFFFF
    rev8       s1, t5
    assert_value s1, 0xFFFFFF7F
    li32 t5, 0x000000FF
    rev8       s1, t5
    assert_value s1, 0xFF000000
    li32 t5, 0x00000080
    rev8       s1, t5
    assert_value s1, 0x80000000
    li32 t5, 0x0000FFFF
    rev8       s1, t5
    assert_value s1, 0xFFFF0000
    li32 t5, 0x00008000
    rev8       s1, t5
    assert_value s1, 0x00800000
    li32 t5, 0x00010000
    rev8       s1, t5
    assert_value s1, 0x00000100
    li32 t5, 0xFFFF0000
    rev8       s1, t5
    assert_value s1, 0x0000FFFF
    li32 t5, 0x12345678
    rev8       s1, t5
    assert_value s1, 0x78563412
    li32 t5, 0xDEADBEEF
    rev8       s1, t5
    assert_value s1, 0xEFBEADDE
    li32 t5, 0x00010080
    rev8       s1, t5
    assert_value s1, 0x80000100
    li32 t5, 0x01000000
    rev8       s1, t5
    assert_value s1, 0x00000001
    li32 t5, 0x00000100
    rev8       s1, t5
    assert_value s1, 0x00010000
    li32 t5, 0x80808080
    rev8       s1, t5
    assert_value s1, 0x80808080
    li32 t5, 0x01020304
    rev8       s1, t5
    assert_value s1, 0x04030201

# -----------------------------------------------
# rol and ror on corner pairs (rotate by 0, by 31, by rs2 >= 32).
test_rotate_pairs:
    addi t2, zero, 7
    flush_pipeline
    li32 t5, 0x80000001
    li32 t6, 0x00000000
    rol        s1, t5, t6
    assert_value s1, 0x80000001
    li32 t5, 0x80000001
    li32 t6, 0x0000001F
    rol        s1, t5, t6
    assert_value s1, 0xC0000000
    li32 t5, 0x12345678
    li32 t6, 0x00000020
    rol        s1, t5, t6
    assert_value s1, 0x12345678
    li32 t5, 0x12345678
    li32 t6, 0x00000024
    rol        s1, t5, t6
    assert_value s1, 0x23456781
    li32 t5, 0xF000000F
    li32 t6, 0xFFFFFFFF
    rol        s1, t5, t6
    assert_value s1, 0xF8000007
    li32 t5, 0x00000000
    li32 t6, 0x00000005
    rol        s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0xFFFFFFFF
    li32 t6, 0x0000000D
    rol        s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x80000001
    li32 t6, 0x00000000
    ror        s1, t5, t6
    assert_value s1, 0x80000001
    li32 t5, 0x80000001
    li32 t6, 0x0000001F
    ror        s1, t5, t6
    assert_value s1, 0x00000003
    li32 t5, 0x12345678
    li32 t6, 0x00000020
    ror        s1, t5, t6
    assert_value s1, 0x12345678
    li32 t5, 0x12345678
    li32 t6, 0x00000024
    ror        s1, t5, t6
    assert_value s1, 0x81234567
    li32 t5, 0xF000000F
    li32 t6, 0xFFFFFFFF
    ror        s1, t5, t6
    assert_value s1, 0xE000001F
    li32 t5, 0x00000000
    li32 t6, 0x00000005
    ror        s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0xFFFFFFFF
    li32 t6, 0x0000000D
    ror        s1, t5, t6
    assert_value s1, 0xFFFFFFFF

# -----------------------------------------------
# rol and ror by every amount 0..31 with the upper 27 bits of rs2 set
# (only rs2[4:0] counts), and rori by every shamt 0..31.
test_rotate_every_amount:
    addi t2, zero, 8
    flush_pipeline
    li32 t5, 0x12345679
    li32 s3, 0xFFFFFFE0
    addi t6, s3, 0
    rol        s1, t5, t6
    assert_value s1, 0x12345679
    addi t6, s3, 1
    rol        s1, t5, t6
    assert_value s1, 0x2468ACF2
    addi t6, s3, 2
    rol        s1, t5, t6
    assert_value s1, 0x48D159E4
    addi t6, s3, 3
    rol        s1, t5, t6
    assert_value s1, 0x91A2B3C8
    addi t6, s3, 4
    rol        s1, t5, t6
    assert_value s1, 0x23456791
    addi t6, s3, 5
    rol        s1, t5, t6
    assert_value s1, 0x468ACF22
    addi t6, s3, 6
    rol        s1, t5, t6
    assert_value s1, 0x8D159E44
    addi t6, s3, 7
    rol        s1, t5, t6
    assert_value s1, 0x1A2B3C89
    addi t6, s3, 8
    rol        s1, t5, t6
    assert_value s1, 0x34567912
    addi t6, s3, 9
    rol        s1, t5, t6
    assert_value s1, 0x68ACF224
    addi t6, s3, 10
    rol        s1, t5, t6
    assert_value s1, 0xD159E448
    addi t6, s3, 11
    rol        s1, t5, t6
    assert_value s1, 0xA2B3C891
    addi t6, s3, 12
    rol        s1, t5, t6
    assert_value s1, 0x45679123
    addi t6, s3, 13
    rol        s1, t5, t6
    assert_value s1, 0x8ACF2246
    addi t6, s3, 14
    rol        s1, t5, t6
    assert_value s1, 0x159E448D
    addi t6, s3, 15
    rol        s1, t5, t6
    assert_value s1, 0x2B3C891A
    addi t6, s3, 16
    rol        s1, t5, t6
    assert_value s1, 0x56791234
    addi t6, s3, 17
    rol        s1, t5, t6
    assert_value s1, 0xACF22468
    addi t6, s3, 18
    rol        s1, t5, t6
    assert_value s1, 0x59E448D1
    addi t6, s3, 19
    rol        s1, t5, t6
    assert_value s1, 0xB3C891A2
    addi t6, s3, 20
    rol        s1, t5, t6
    assert_value s1, 0x67912345
    addi t6, s3, 21
    rol        s1, t5, t6
    assert_value s1, 0xCF22468A
    addi t6, s3, 22
    rol        s1, t5, t6
    assert_value s1, 0x9E448D15
    addi t6, s3, 23
    rol        s1, t5, t6
    assert_value s1, 0x3C891A2B
    addi t6, s3, 24
    rol        s1, t5, t6
    assert_value s1, 0x79123456
    addi t6, s3, 25
    rol        s1, t5, t6
    assert_value s1, 0xF22468AC
    addi t6, s3, 26
    rol        s1, t5, t6
    assert_value s1, 0xE448D159
    addi t6, s3, 27
    rol        s1, t5, t6
    assert_value s1, 0xC891A2B3
    addi t6, s3, 28
    rol        s1, t5, t6
    assert_value s1, 0x91234567
    addi t6, s3, 29
    rol        s1, t5, t6
    assert_value s1, 0x22468ACF
    addi t6, s3, 30
    rol        s1, t5, t6
    assert_value s1, 0x448D159E
    addi t6, s3, 31
    rol        s1, t5, t6
    assert_value s1, 0x891A2B3C
    addi t6, s3, 0
    ror        s1, t5, t6
    assert_value s1, 0x12345679
    addi t6, s3, 1
    ror        s1, t5, t6
    assert_value s1, 0x891A2B3C
    addi t6, s3, 2
    ror        s1, t5, t6
    assert_value s1, 0x448D159E
    addi t6, s3, 3
    ror        s1, t5, t6
    assert_value s1, 0x22468ACF
    addi t6, s3, 4
    ror        s1, t5, t6
    assert_value s1, 0x91234567
    addi t6, s3, 5
    ror        s1, t5, t6
    assert_value s1, 0xC891A2B3
    addi t6, s3, 6
    ror        s1, t5, t6
    assert_value s1, 0xE448D159
    addi t6, s3, 7
    ror        s1, t5, t6
    assert_value s1, 0xF22468AC
    addi t6, s3, 8
    ror        s1, t5, t6
    assert_value s1, 0x79123456
    addi t6, s3, 9
    ror        s1, t5, t6
    assert_value s1, 0x3C891A2B
    addi t6, s3, 10
    ror        s1, t5, t6
    assert_value s1, 0x9E448D15
    addi t6, s3, 11
    ror        s1, t5, t6
    assert_value s1, 0xCF22468A
    addi t6, s3, 12
    ror        s1, t5, t6
    assert_value s1, 0x67912345
    addi t6, s3, 13
    ror        s1, t5, t6
    assert_value s1, 0xB3C891A2
    addi t6, s3, 14
    ror        s1, t5, t6
    assert_value s1, 0x59E448D1
    addi t6, s3, 15
    ror        s1, t5, t6
    assert_value s1, 0xACF22468
    addi t6, s3, 16
    ror        s1, t5, t6
    assert_value s1, 0x56791234
    addi t6, s3, 17
    ror        s1, t5, t6
    assert_value s1, 0x2B3C891A
    addi t6, s3, 18
    ror        s1, t5, t6
    assert_value s1, 0x159E448D
    addi t6, s3, 19
    ror        s1, t5, t6
    assert_value s1, 0x8ACF2246
    addi t6, s3, 20
    ror        s1, t5, t6
    assert_value s1, 0x45679123
    addi t6, s3, 21
    ror        s1, t5, t6
    assert_value s1, 0xA2B3C891
    addi t6, s3, 22
    ror        s1, t5, t6
    assert_value s1, 0xD159E448
    addi t6, s3, 23
    ror        s1, t5, t6
    assert_value s1, 0x68ACF224
    addi t6, s3, 24
    ror        s1, t5, t6
    assert_value s1, 0x34567912
    addi t6, s3, 25
    ror        s1, t5, t6
    assert_value s1, 0x1A2B3C89
    addi t6, s3, 26
    ror        s1, t5, t6
    assert_value s1, 0x8D159E44
    addi t6, s3, 27
    ror        s1, t5, t6
    assert_value s1, 0x468ACF22
    addi t6, s3, 28
    ror        s1, t5, t6
    assert_value s1, 0x23456791
    addi t6, s3, 29
    ror        s1, t5, t6
    assert_value s1, 0x91A2B3C8
    addi t6, s3, 30
    ror        s1, t5, t6
    assert_value s1, 0x48D159E4
    addi t6, s3, 31
    ror        s1, t5, t6
    assert_value s1, 0x2468ACF2
    rori       s1, t5, 0
    assert_value s1, 0x12345679
    rori       s1, t5, 1
    assert_value s1, 0x891A2B3C
    rori       s1, t5, 2
    assert_value s1, 0x448D159E
    rori       s1, t5, 3
    assert_value s1, 0x22468ACF
    rori       s1, t5, 4
    assert_value s1, 0x91234567
    rori       s1, t5, 5
    assert_value s1, 0xC891A2B3
    rori       s1, t5, 6
    assert_value s1, 0xE448D159
    rori       s1, t5, 7
    assert_value s1, 0xF22468AC
    rori       s1, t5, 8
    assert_value s1, 0x79123456
    rori       s1, t5, 9
    assert_value s1, 0x3C891A2B
    rori       s1, t5, 10
    assert_value s1, 0x9E448D15
    rori       s1, t5, 11
    assert_value s1, 0xCF22468A
    rori       s1, t5, 12
    assert_value s1, 0x67912345
    rori       s1, t5, 13
    assert_value s1, 0xB3C891A2
    rori       s1, t5, 14
    assert_value s1, 0x59E448D1
    rori       s1, t5, 15
    assert_value s1, 0xACF22468
    rori       s1, t5, 16
    assert_value s1, 0x56791234
    rori       s1, t5, 17
    assert_value s1, 0x2B3C891A
    rori       s1, t5, 18
    assert_value s1, 0x159E448D
    rori       s1, t5, 19
    assert_value s1, 0x8ACF2246
    rori       s1, t5, 20
    assert_value s1, 0x45679123
    rori       s1, t5, 21
    assert_value s1, 0xA2B3C891
    rori       s1, t5, 22
    assert_value s1, 0xD159E448
    rori       s1, t5, 23
    assert_value s1, 0x68ACF224
    rori       s1, t5, 24
    assert_value s1, 0x34567912
    rori       s1, t5, 25
    assert_value s1, 0x1A2B3C89
    rori       s1, t5, 26
    assert_value s1, 0x8D159E44
    rori       s1, t5, 27
    assert_value s1, 0x468ACF22
    rori       s1, t5, 28
    assert_value s1, 0x23456791
    rori       s1, t5, 29
    assert_value s1, 0x91A2B3C8
    rori       s1, t5, 30
    assert_value s1, 0x48D159E4
    rori       s1, t5, 31
    assert_value s1, 0x2468ACF2

# -----------------------------------------------
# 0x6005D513 (imm 0x600 under funct3 101) is legal: it is rori a0, a1, 0.
test_rori_zero_encoding:
    addi t2, zero, 9
    flush_pipeline
    li32 a1, 0x89ABCDEF
    li32 a0, 0
    .word 0x6005D513
    assert_value a0, 0x89ABCDEF

# -----------------------------------------------
# rd = x0 discards the result, also for the instruction right behind it,
# which must read 0 rather than a forwarded value.
test_rd_is_x0:
    addi t2, zero, 10
    flush_pipeline
    li32 t5, 0x12345678
    li32 t6, 0x0000F00F
    andn       zero, t5, t6
    add  s1, zero, zero           # reads x0 right behind the discarded result
    andn       zero, t5, t6
    add  s2, t5, zero
    assert_value s1, 0x00000000
    assert_value s2, 0x12345678
    clz        zero, t5
    clz        s3, zero
    assert_value s3, 0x00000020

# -----------------------------------------------
# x0 as a source operand.
test_x0_source:
    addi t2, zero, 11
    flush_pipeline
    andn       s1, zero, t6
    assert_value s1, 0x00000000
    andn       s1, t5, zero
    assert_value s1, 0x12345678
    andn       s1, zero, zero
    assert_value s1, 0x00000000

# -----------------------------------------------
# rd == rs1, rd == rs2 and rd == rs1 == rs2 all read the OLD operands.
test_aliasing:
    addi t2, zero, 12
    flush_pipeline
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    ror        t5, t5, t6
    assert_value t5, 0xE1E02469
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    ror        t6, t5, t6
    assert_value t6, 0xE1E02469
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    ror        t5, t5, t5
    assert_value t5, 0x01234F0F
    li32 t5, 0xF0F01234
    rev8       t5, t5
    assert_value t5, 0x3412F0F0
    li32 t5, 0xF0F01234
    rori       t5, t5, 7
    assert_value t5, 0x69E1E024

# -----------------------------------------------
# rd == rs1, rd == rs2 and rd == rs1 == rs2 all read the OLD operands.
test_aliasing_2:
    addi t2, zero, 13
    flush_pipeline
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    max        t5, t5, t6
    assert_value t5, 0x0F0F00FF
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    max        t6, t5, t6
    assert_value t6, 0x0F0F00FF
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    max        t5, t5, t5
    assert_value t5, 0xF0F01234
    li32 t5, 0xF0F01234
    sext.h     t5, t5
    assert_value t5, 0x00001234

# -----------------------------------------------
# Forwarding INTO the new instruction: the operand produced 1, 2 and 3
# instructions earlier, into rs1 and into rs2, and both operands
# forwarded from different stages.
test_forward_into:
    addi t2, zero, 14
    flush_pipeline
    li32 t6, 0x00000013
    li32 t5, 0x8001F00F
    rol        s1, t5, t6
    assert_value s1, 0x807C000F
    li32 t5, 0x8001F00F
    li32 t6, 0x00000013
    rol        s2, t5, t6
    assert_value s2, 0x807C000F
    li32 t5, 0x8100F00F
    ctz        s3, t5
    assert_value s3, 0x00000000
    li32 t6, 0x00000013
    li32 t5, 0x8001F00F
    nop
    rol        s1, t5, t6
    assert_value s1, 0x807C000F
    li32 t5, 0x8001F00F
    li32 t6, 0x00000013
    nop
    rol        s2, t5, t6
    assert_value s2, 0x807C000F
    li32 t5, 0x8203F00F
    nop
    ctz        s3, t5
    assert_value s3, 0x00000000
    li32 t6, 0x00000013
    li32 t5, 0x8001F00F
    nop
    nop
    rol        s1, t5, t6
    assert_value s1, 0x807C000F
    li32 t5, 0x8001F00F
    li32 t6, 0x00000013
    nop
    nop
    rol        s2, t5, t6
    assert_value s2, 0x807C000F
    li32 t5, 0x8302F00F
    nop
    nop
    ctz        s3, t5
    assert_value s3, 0x00000000
    li32 t5, 0x8001F00F
    li32 t6, 0x00000013
    rol        s1, t5, t6
    li32 t6, 0x00000013
    li32 t5, 0x8001F00F
    rol        s2, t5, t6
    li32 t5, 0x8001F00F
    rol        s3, t5, t5
    assert_value s1, 0x807C000F
    assert_value s2, 0x807C000F
    assert_value s3, 0xF807C000

# -----------------------------------------------
# Forwarding INTO the new instruction: the operand produced 1, 2 and 3
# instructions earlier, into rs1 and into rs2, and both operands
# forwarded from different stages.
test_forward_into_2:
    addi t2, zero, 15
    flush_pipeline
    li32 t6, 0x00000013
    li32 t5, 0x8001F00F
    minu       s1, t5, t6
    assert_value s1, 0x00000013
    li32 t5, 0x8001F00F
    li32 t6, 0x00000013
    minu       s2, t5, t6
    assert_value s2, 0x00000013
    li32 t5, 0x8100F00F
    orc.b      s3, t5
    assert_value s3, 0xFF00FFFF
    li32 t6, 0x00000013
    li32 t5, 0x8001F00F
    nop
    minu       s1, t5, t6
    assert_value s1, 0x00000013
    li32 t5, 0x8001F00F
    li32 t6, 0x00000013
    nop
    minu       s2, t5, t6
    assert_value s2, 0x00000013
    li32 t5, 0x8203F00F
    nop
    orc.b      s3, t5
    assert_value s3, 0xFFFFFFFF
    li32 t6, 0x00000013
    li32 t5, 0x8001F00F
    nop
    nop
    minu       s1, t5, t6
    assert_value s1, 0x00000013
    li32 t5, 0x8001F00F
    li32 t6, 0x00000013
    nop
    nop
    minu       s2, t5, t6
    assert_value s2, 0x00000013
    li32 t5, 0x8302F00F
    nop
    nop
    orc.b      s3, t5
    assert_value s3, 0xFFFFFFFF
    li32 t5, 0x8001F00F
    li32 t6, 0x00000013
    minu       s1, t5, t6
    li32 t6, 0x00000013
    li32 t5, 0x8001F00F
    minu       s2, t5, t6
    li32 t5, 0x8001F00F
    minu       s3, t5, t5
    assert_value s1, 0x00000013
    assert_value s2, 0x00000013
    assert_value s3, 0x8001F00F

# -----------------------------------------------
# A load feeding the new instruction directly (load-use stall in front of it),
# into rs1, into rs2 and into both.
test_load_use:
    addi t2, zero, 16
    flush_pipeline
    li32 t6, 0x00000005
    lw   t5, 12(t4)
    orn        s1, t5, t6
    assert_value s1, 0xFFFFFFFA
    li32 t5, 0x7FFFFFFF
    lw   t6, 4(t4)
    orn        s2, t5, t6
    assert_value s2, 0x7FFFFFFF
    lw   t5, 8(t4)
    lw   t6, 12(t4)
    orn        s3, t5, t6
    assert_value s3, 0xEDFFA9FF
    lw   t5, 8(t4)
    cpop       s4, t5
    assert_value s4, 0x00000010

# -----------------------------------------------
# Forwarding OUT of the new instruction, consumed by the very next
# instruction: an ALU op, a branch, a load address, store data, a
# JALR base and a CSR write.
test_forward_out_of:
    addi t2, zero, 17
    flush_pipeline
    li32 t5, 0xF0F0F0F0
    cpop       s1, t5
    addi s2, s1, 1
    assert_value s2, 0x00000011
    li32 s3, 0x0000000F
    li32 t5, 0x00010000
    clz        s1, t5
    bne  s1, s3, fwd_branch_bad_3
    beq  zero, zero, fwd_branch_ok_2
fwd_branch_bad_3:
    fail
fwd_branch_ok_2:
    addi t5, t4, 8
    ori  t5, t5, 3
    addi t6, zero, 3
    andn       s1, t5, t6
    lw   s2, 0(s1)
    assert_value s2, 0x00FF00FF
    li32 t5, 0x11223344
    rev8       s1, t5
    sw   s1, 20(t4)              # scratch_var
    flush_pipeline
    lw   s2, 20(t4)
    assert_value s2, 0x44332211
    addi s4, zero, 0
    li32 t5, zbb_jalr_target_1
    max        s1, t5, zero
    jalr ra, 0(s1)
    fail                          # not reached
    beq  zero, zero, jalr_back_4
zbb_jalr_target_1:
    addi s4, zero, 1
jalr_back_4:
    assert_value s4, 0x00000001
    li32 t5, 0x00100001
    orc.b      s1, t5
    csrw mscratch, s1
    csrr s2, mscratch
    assert_value s2, 0x00FF00FF

# -----------------------------------------------
# An instruction in the shadow of a taken branch must not execute, and
# the new instruction works as a branch target.
test_branch_shadow:
    addi t2, zero, 18
    flush_pipeline
    li32 s1, 0x0000ABCD
    li32 t5, 0x00F00000
    li32 t6, 0x00000000
    beq  zero, zero, shadow_target_5
    clz        s1, t5
    clz        s1, t5
    fail
shadow_target_5:
    rori       s2, t5, 3
    assert_value s1, 0x0000ABCD
    assert_value s2, 0x001E0000

# -----------------------------------------------
# Before and after fence.i, which refetches everything behind it.
test_fence_i:
    addi t2, zero, 19
    flush_pipeline
    li32 t5, 0x0F0F1234
    li32 t6, 0xFF00FF00
    xnor       s1, t5, t6
    fence.i
    xnor       s2, s1, t6
    assert_value s1, 0x0FF012CB
    assert_value s2, 0x0F0F1234

# -----------------------------------------------
# minstret rises by exactly N over N of the new instructions: the
# difference between a window with them and an empty window.
test_minstret:
    addi t2, zero, 20
    flush_pipeline
    li32 a0, 0x13579BDF
    li32 a1, 0x2468ACE1
    flush_pipeline
    csrr s5, minstret
    csrr s6, minstret
    sub  s8, s6, s5
    flush_pipeline
    csrr s5, minstret
    rori       a0, a0, 7
    xnor       a0, a0, a1
    rol        a0, a0, a1
    andn       a0, a1, a0
    orn        a0, a0, a1
    rev8       a0, a0
    ror        a0, a1, a0
    max        a0, a0, a1
    minu       a0, a1, a0
    sext.h     a0, a0
    maxu       a0, a0, a1
    min        a0, a1, a0
    zext.h     a0, a0
    orc.b      a0, a0
    cpop       a0, a0
    ctz        a0, a0
    csrr s6, minstret
    sub  s9, s6, s5
    sub  s9, s9, s8
    assert_value s9, 0x00000010
    assert_value a0, 0x00000004

# -----------------------------------------------
# A chain of 16 back-to-back DEPENDENT instructions takes exactly as many
# cycles as the same chain of add instructions: the result is forwarded
# in its own cycle and nothing stalls (mcycle, read at the same points).
test_cycle_exact:
    addi t2, zero, 21
    flush_pipeline
    li32 a0, 0x13579BDF
    li32 a1, 0x2468ACE1
    flush_pipeline
    csrr s5, mcycle
    rori       a0, a0, 7
    xnor       a0, a0, a1
    rol        a0, a0, a1
    andn       a0, a1, a0
    orn        a0, a0, a1
    rev8       a0, a0
    ror        a0, a1, a0
    max        a0, a0, a1
    minu       a0, a1, a0
    sext.h     a0, a0
    maxu       a0, a0, a1
    min        a0, a1, a0
    zext.h     a0, a0
    orc.b      a0, a0
    cpop       a0, a0
    ctz        a0, a0
    csrr s6, mcycle
    sub  s8, s6, s5
    mv   s4, a0
    li32 a0, 0x13579BDF
    li32 a1, 0x2468ACE1
    flush_pipeline
    csrr s5, mcycle
    addi       a0, a0, 1
    add        a0, a0, a1
    add        a0, a0, a1
    add        a0, a1, a0
    add        a0, a0, a1
    addi       a0, a0, 1
    add        a0, a1, a0
    add        a0, a0, a1
    add        a0, a1, a0
    addi       a0, a0, 1
    add        a0, a0, a1
    add        a0, a1, a0
    addi       a0, a0, 1
    addi       a0, a0, 1
    addi       a0, a0, 1
    addi       a0, a0, 1
    csrr s6, mcycle
    sub  s9, s6, s5
    assert_equal s8, s9
    assert_value s4, 0x00000004
    addi s9, s8, -17
    assert_value s9, 0x00000000

# -----------------------------------------------
# An external interrupt landing at every position of a chain of the
# new instructions: the chain's result and the count are unchanged.
test_interrupt_in_chain:
    addi t2, zero, 22
    flush_pipeline
    li32 t6, ext_irq_handler
    csrw mtvec, t6
    slli t6, t1, 11
    csrs mie, t6
    slli t6, t1, 3
    csrs mstatus, t6
    addi s7, zero, 0
    li32 a0, 0x13579BDF
    li32 a1, 0x2468ACE1
    flush_pipeline
    interrupt 1
    rori       a0, a0, 7
    xnor       a0, a0, a1
    rol        a0, a0, a1
    andn       a0, a1, a0
    orn        a0, a0, a1
    rev8       a0, a0
    ror        a0, a1, a0
    max        a0, a0, a1
    minu       a0, a1, a0
    sext.h     a0, a0
    maxu       a0, a0, a1
    min        a0, a1, a0
    zext.h     a0, a0
    orc.b      a0, a0
    cpop       a0, a0
    ctz        a0, a0
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x00000004
    li32 a0, 0x13579BDF
    li32 a1, 0x2468ACE1
    flush_pipeline
    interrupt 2
    rori       a0, a0, 7
    xnor       a0, a0, a1
    rol        a0, a0, a1
    andn       a0, a1, a0
    orn        a0, a0, a1
    rev8       a0, a0
    ror        a0, a1, a0
    max        a0, a0, a1
    minu       a0, a1, a0
    sext.h     a0, a0
    maxu       a0, a0, a1
    min        a0, a1, a0
    zext.h     a0, a0
    orc.b      a0, a0
    cpop       a0, a0
    ctz        a0, a0
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x00000004
    li32 a0, 0x13579BDF
    li32 a1, 0x2468ACE1
    flush_pipeline
    interrupt 3
    rori       a0, a0, 7
    xnor       a0, a0, a1
    rol        a0, a0, a1
    andn       a0, a1, a0
    orn        a0, a0, a1
    rev8       a0, a0
    ror        a0, a1, a0
    max        a0, a0, a1
    minu       a0, a1, a0
    sext.h     a0, a0
    maxu       a0, a0, a1
    min        a0, a1, a0
    zext.h     a0, a0
    orc.b      a0, a0
    cpop       a0, a0
    ctz        a0, a0
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x00000004
    li32 a0, 0x13579BDF
    li32 a1, 0x2468ACE1
    flush_pipeline
    interrupt 4
    rori       a0, a0, 7
    xnor       a0, a0, a1
    rol        a0, a0, a1
    andn       a0, a1, a0
    orn        a0, a0, a1
    rev8       a0, a0
    ror        a0, a1, a0
    max        a0, a0, a1
    minu       a0, a1, a0
    sext.h     a0, a0
    maxu       a0, a0, a1
    min        a0, a1, a0
    zext.h     a0, a0
    orc.b      a0, a0
    cpop       a0, a0
    ctz        a0, a0
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x00000004
    li32 a0, 0x13579BDF
    li32 a1, 0x2468ACE1
    flush_pipeline
    interrupt 5
    rori       a0, a0, 7
    xnor       a0, a0, a1
    rol        a0, a0, a1
    andn       a0, a1, a0
    orn        a0, a0, a1
    rev8       a0, a0
    ror        a0, a1, a0
    max        a0, a0, a1
    minu       a0, a1, a0
    sext.h     a0, a0
    maxu       a0, a0, a1
    min        a0, a1, a0
    zext.h     a0, a0
    orc.b      a0, a0
    cpop       a0, a0
    ctz        a0, a0
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x00000004
    li32 a0, 0x13579BDF
    li32 a1, 0x2468ACE1
    flush_pipeline
    interrupt 6
    rori       a0, a0, 7
    xnor       a0, a0, a1
    rol        a0, a0, a1
    andn       a0, a1, a0
    orn        a0, a0, a1
    rev8       a0, a0
    ror        a0, a1, a0
    max        a0, a0, a1
    minu       a0, a1, a0
    sext.h     a0, a0
    maxu       a0, a0, a1
    min        a0, a1, a0
    zext.h     a0, a0
    orc.b      a0, a0
    cpop       a0, a0
    ctz        a0, a0
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x00000004
    li32 a0, 0x13579BDF
    li32 a1, 0x2468ACE1
    flush_pipeline
    interrupt 7
    rori       a0, a0, 7
    xnor       a0, a0, a1
    rol        a0, a0, a1
    andn       a0, a1, a0
    orn        a0, a0, a1
    rev8       a0, a0
    ror        a0, a1, a0
    max        a0, a0, a1
    minu       a0, a1, a0
    sext.h     a0, a0
    maxu       a0, a0, a1
    min        a0, a1, a0
    zext.h     a0, a0
    orc.b      a0, a0
    cpop       a0, a0
    ctz        a0, a0
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x00000004
    li32 a0, 0x13579BDF
    li32 a1, 0x2468ACE1
    flush_pipeline
    interrupt 8
    rori       a0, a0, 7
    xnor       a0, a0, a1
    rol        a0, a0, a1
    andn       a0, a1, a0
    orn        a0, a0, a1
    rev8       a0, a0
    ror        a0, a1, a0
    max        a0, a0, a1
    minu       a0, a1, a0
    sext.h     a0, a0
    maxu       a0, a0, a1
    min        a0, a1, a0
    zext.h     a0, a0
    orc.b      a0, a0
    cpop       a0, a0
    ctz        a0, a0
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x00000004
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
    addi t2, zero, 23
    flush_pipeline
    li32 t5, record_trap
    csrw mtvec, t5
    flush_pipeline
    expect_trap 0x6205D513, 2       # rori with shamt[5] = 1 (reserved on RV32)
    expect_trap 0x6B85D513, 2       # rev8, RV64 encoding 0x6B8
    expect_trap 0x6865D513, 2       # brev8 neighbour, imm 0x686
    expect_trap 0x2865D513, 2       # orc.b neighbour, imm 0x286
    expect_trap 0x28F5D513, 2       # orc.b neighbour, imm 0x28F
    expect_trap 0x6995D513, 2       # rev8 neighbour, imm 0x699
    expect_trap 0x60359513, 2       # unary group, rs2 field 3
    expect_trap 0x60659513, 2       # unary group, rs2 field 6
    expect_trap 0x61F59513, 2       # unary group, rs2 field 31
    expect_trap 0x08E59513, 2       # zip neighbour, rs2 field 14
    expect_trap 0x08E5D513, 2       # unzip neighbour, rs2 field 14
    expect_trap 0x08C5D533, 2       # funct7 0000100, funct3 101 (zext.h/pack shape)
    expect_trap 0x08C5E533, 2       # funct7 0000100, funct3 110
    expect_trap 0x0AC59533, 2       # clmul (Zbc)
    expect_trap 0x0AC5A533, 2       # clmulr (Zbc)
    expect_trap 0x0AC5B533, 2       # clmulh (Zbc)
    expect_trap 0x0AC58533, 2       # funct7 0000101, funct3 000
    expect_trap 0x40C59533, 2       # funct7 0100000, funct3 001
    expect_trap 0x40C5A533, 2       # funct7 0100000, funct3 010
    expect_trap 0x40C5B533, 2       # funct7 0100000, funct3 011
    expect_trap 0x60C58533, 2       # funct7 0110000, funct3 000
    expect_trap 0x60C5A533, 2       # funct7 0110000, funct3 010
    expect_trap 0x60C5C533, 2       # funct7 0110000, funct3 100
    expect_trap 0x60C5E533, 2       # funct7 0110000, funct3 110
    expect_trap 0x60C5F533, 2       # funct7 0110000, funct3 111
    expect_trap 0x0805C53B, 2       # RV64 zext.h (OP-32)
    expect_trap 0x60C5953B, 2       # rolw (OP-32)
    expect_trap 0x6005951B, 2       # clzw (OP-IMM-32)
    li32 t5, unexpected_trap
    csrw mtvec, t5
    flush_pipeline

# ------------------------------------------------------------------------------------------------
# |                                          Test done!                                          |
# ------------------------------------------------------------------------------------------------
test_finish:
    addi t2, zero, 24
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
