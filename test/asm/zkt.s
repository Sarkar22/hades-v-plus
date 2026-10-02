# Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
# Embedded Architectures & Systems Group, Graz University of Technology
# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: zkt.s
#
# ------------------------------------------------------------------------------------------------
# |                                                                                              |
# | Zkt timing test: the instructions of the Zkt list that HaDes-V+ implements take a            |
# | fixed number of cycles whatever their operand values.                                        |
# | If everything runs correctly, the first register of the peripheral test module               |
# | should always be zero, except during the first test, which checks the assert macro itself.   |
# | Note: This condition is necessary, but not sufficient to prove correctness.                  |
# |                                                                                              |
# | Every expected value below was computed from the ISA text by a separate model, never by      |
# | running the core. A trap handler is armed for the whole test and turns any exception into    |
# | a failure.                                                                                   |
# |                                                                                              |
# | What is checked:                                                                             |
# | 1. A block of 8 identical, independent instructions is timed with mcycle (no                 |
# |    data-dependent control flow inside the window) for a set of operand values:               |
# |    0, 1, -1, 0x80000000, 0x7FFFFFFF, 0x80000000 x -1, amounts 0/1/31/32+k for                |
# |    shifts and rotates, a zero and a non-zero condition for czero.                            |
# | 2. Every block takes exactly the cycles of a block of add (1 cycle per instruction),         |
# |    except mul/mulh/mulhsu/mulhu, which take exactly 2 cycles per instruction.                |
# | Division (1 or 34 cycles), loads, stores and branches are not in the Zkt list and are        |
# | not timed here.                                                                              |
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

.option arch, +zbb, +zbs, +m

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
# The reference: a block of 8 independent add instructions takes 9 cycles
# between the two mcycle reads (one per instruction, plus the read).
test_reference_window:
    addi t2, zero, 1
    flush_pipeline
    li32 a1, 0x12345678
    li32 a2, 0x0F0F0F0F
    flush_pipeline
    csrr s5, mcycle
    add  a0, a1, a2
    add  a0, a1, a2
    add  a0, a1, a2
    add  a0, a1, a2
    add  a0, a1, a2
    add  a0, a1, a2
    add  a0, a1, a2
    add  a0, a1, a2
    csrr s6, mcycle
    sub  s9, s6, s5
    assert_value s9, 0x00000009

# -----------------------------------------------
# RV32I register-register: add sub slt sltu xor or and.
# Every block of 8 takes the same number of cycles whatever the operands.
test_rv32i_register:
    addi t2, zero, 2
    flush_pipeline
    li32 a1, 0x00000000
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # add 0x00000000, 0x00000000
    li32 a1, 0x00000001
    li32 a2, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # add 0x00000001, 0x00000001
    li32 a1, 0xFFFFFFFF
    li32 a2, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # add 0xFFFFFFFF, 0xFFFFFFFF
    li32 a1, 0x80000000
    li32 a2, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # add 0x80000000, 0xFFFFFFFF
    li32 a1, 0x7FFFFFFF
    li32 a2, 0x80000000
    flush_pipeline
    csrr s5, mcycle
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # add 0x7FFFFFFF, 0x80000000
    li32 a1, 0x80000000
    li32 a2, 0x7FFFFFFF
    flush_pipeline
    csrr s5, mcycle
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # add 0x80000000, 0x7FFFFFFF
    li32 a1, 0x12345678
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    add        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # add 0x12345678, 0x00000000
    li32 a1, 0x00000000
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # sub 0x00000000, 0x00000000
    li32 a1, 0x00000001
    li32 a2, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # sub 0x00000001, 0x00000001
    li32 a1, 0xFFFFFFFF
    li32 a2, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # sub 0xFFFFFFFF, 0xFFFFFFFF
    li32 a1, 0x80000000
    li32 a2, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # sub 0x80000000, 0xFFFFFFFF
    li32 a1, 0x7FFFFFFF
    li32 a2, 0x80000000
    flush_pipeline
    csrr s5, mcycle
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # sub 0x7FFFFFFF, 0x80000000
    li32 a1, 0x80000000
    li32 a2, 0x7FFFFFFF
    flush_pipeline
    csrr s5, mcycle
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # sub 0x80000000, 0x7FFFFFFF
    li32 a1, 0x12345678
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    sub        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # sub 0x12345678, 0x00000000
    li32 a1, 0x00000000
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # slt 0x00000000, 0x00000000
    li32 a1, 0x00000001
    li32 a2, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # slt 0x00000001, 0x00000001
    li32 a1, 0xFFFFFFFF
    li32 a2, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # slt 0xFFFFFFFF, 0xFFFFFFFF
    li32 a1, 0x80000000
    li32 a2, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # slt 0x80000000, 0xFFFFFFFF
    li32 a1, 0x7FFFFFFF
    li32 a2, 0x80000000
    flush_pipeline
    csrr s5, mcycle
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # slt 0x7FFFFFFF, 0x80000000
    li32 a1, 0x80000000
    li32 a2, 0x7FFFFFFF
    flush_pipeline
    csrr s5, mcycle
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # slt 0x80000000, 0x7FFFFFFF
    li32 a1, 0x12345678
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    slt        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # slt 0x12345678, 0x00000000
    li32 a1, 0x00000000
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # sltu 0x00000000, 0x00000000
    li32 a1, 0x00000001
    li32 a2, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # sltu 0x00000001, 0x00000001
    li32 a1, 0xFFFFFFFF
    li32 a2, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # sltu 0xFFFFFFFF, 0xFFFFFFFF
    li32 a1, 0x80000000
    li32 a2, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # sltu 0x80000000, 0xFFFFFFFF
    li32 a1, 0x7FFFFFFF
    li32 a2, 0x80000000
    flush_pipeline
    csrr s5, mcycle
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # sltu 0x7FFFFFFF, 0x80000000
    li32 a1, 0x80000000
    li32 a2, 0x7FFFFFFF
    flush_pipeline
    csrr s5, mcycle
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # sltu 0x80000000, 0x7FFFFFFF
    li32 a1, 0x12345678
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    sltu       a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # sltu 0x12345678, 0x00000000
    li32 a1, 0x00000000
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # xor 0x00000000, 0x00000000
    li32 a1, 0x00000001
    li32 a2, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # xor 0x00000001, 0x00000001
    li32 a1, 0xFFFFFFFF
    li32 a2, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # xor 0xFFFFFFFF, 0xFFFFFFFF
    li32 a1, 0x80000000
    li32 a2, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # xor 0x80000000, 0xFFFFFFFF
    li32 a1, 0x7FFFFFFF
    li32 a2, 0x80000000
    flush_pipeline
    csrr s5, mcycle
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # xor 0x7FFFFFFF, 0x80000000
    li32 a1, 0x80000000
    li32 a2, 0x7FFFFFFF
    flush_pipeline
    csrr s5, mcycle
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # xor 0x80000000, 0x7FFFFFFF
    li32 a1, 0x12345678
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    xor        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # xor 0x12345678, 0x00000000
    li32 a1, 0x00000000
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # or 0x00000000, 0x00000000
    li32 a1, 0x00000001
    li32 a2, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # or 0x00000001, 0x00000001
    li32 a1, 0xFFFFFFFF
    li32 a2, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # or 0xFFFFFFFF, 0xFFFFFFFF
    li32 a1, 0x80000000
    li32 a2, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # or 0x80000000, 0xFFFFFFFF
    li32 a1, 0x7FFFFFFF
    li32 a2, 0x80000000
    flush_pipeline
    csrr s5, mcycle
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # or 0x7FFFFFFF, 0x80000000
    li32 a1, 0x80000000
    li32 a2, 0x7FFFFFFF
    flush_pipeline
    csrr s5, mcycle
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # or 0x80000000, 0x7FFFFFFF
    li32 a1, 0x12345678
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    or         a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # or 0x12345678, 0x00000000
    li32 a1, 0x00000000
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # and 0x00000000, 0x00000000
    li32 a1, 0x00000001
    li32 a2, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # and 0x00000001, 0x00000001
    li32 a1, 0xFFFFFFFF
    li32 a2, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # and 0xFFFFFFFF, 0xFFFFFFFF
    li32 a1, 0x80000000
    li32 a2, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # and 0x80000000, 0xFFFFFFFF
    li32 a1, 0x7FFFFFFF
    li32 a2, 0x80000000
    flush_pipeline
    csrr s5, mcycle
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # and 0x7FFFFFFF, 0x80000000
    li32 a1, 0x80000000
    li32 a2, 0x7FFFFFFF
    flush_pipeline
    csrr s5, mcycle
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # and 0x80000000, 0x7FFFFFFF
    li32 a1, 0x12345678
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    and        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # and 0x12345678, 0x00000000

# -----------------------------------------------
# RV32I shifts by register: sll srl sra, amounts 0, 1, 31, 32 + k.
# Every block of 8 takes the same number of cycles whatever the operands.
test_rv32i_shift:
    addi t2, zero, 3
    flush_pipeline
    li32 a1, 0x80000001
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    sll        a0, a1, a2
    sll        a0, a1, a2
    sll        a0, a1, a2
    sll        a0, a1, a2
    sll        a0, a1, a2
    sll        a0, a1, a2
    sll        a0, a1, a2
    sll        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # sll 0x80000001, 0x00000000
    li32 a1, 0xFFFFFFFF
    li32 a2, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    sll        a0, a1, a2
    sll        a0, a1, a2
    sll        a0, a1, a2
    sll        a0, a1, a2
    sll        a0, a1, a2
    sll        a0, a1, a2
    sll        a0, a1, a2
    sll        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # sll 0xFFFFFFFF, 0x00000001
    li32 a1, 0x80000000
    li32 a2, 0x0000001F
    flush_pipeline
    csrr s5, mcycle
    sll        a0, a1, a2
    sll        a0, a1, a2
    sll        a0, a1, a2
    sll        a0, a1, a2
    sll        a0, a1, a2
    sll        a0, a1, a2
    sll        a0, a1, a2
    sll        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # sll 0x80000000, 0x0000001F
    li32 a1, 0x12345678
    li32 a2, 0x00000025
    flush_pipeline
    csrr s5, mcycle
    sll        a0, a1, a2
    sll        a0, a1, a2
    sll        a0, a1, a2
    sll        a0, a1, a2
    sll        a0, a1, a2
    sll        a0, a1, a2
    sll        a0, a1, a2
    sll        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # sll 0x12345678, 0x00000025
    li32 a1, 0x7FFFFFFF
    li32 a2, 0xFFFFFFE3
    flush_pipeline
    csrr s5, mcycle
    sll        a0, a1, a2
    sll        a0, a1, a2
    sll        a0, a1, a2
    sll        a0, a1, a2
    sll        a0, a1, a2
    sll        a0, a1, a2
    sll        a0, a1, a2
    sll        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # sll 0x7FFFFFFF, 0xFFFFFFE3
    li32 a1, 0x80000001
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    srl        a0, a1, a2
    srl        a0, a1, a2
    srl        a0, a1, a2
    srl        a0, a1, a2
    srl        a0, a1, a2
    srl        a0, a1, a2
    srl        a0, a1, a2
    srl        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # srl 0x80000001, 0x00000000
    li32 a1, 0xFFFFFFFF
    li32 a2, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    srl        a0, a1, a2
    srl        a0, a1, a2
    srl        a0, a1, a2
    srl        a0, a1, a2
    srl        a0, a1, a2
    srl        a0, a1, a2
    srl        a0, a1, a2
    srl        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # srl 0xFFFFFFFF, 0x00000001
    li32 a1, 0x80000000
    li32 a2, 0x0000001F
    flush_pipeline
    csrr s5, mcycle
    srl        a0, a1, a2
    srl        a0, a1, a2
    srl        a0, a1, a2
    srl        a0, a1, a2
    srl        a0, a1, a2
    srl        a0, a1, a2
    srl        a0, a1, a2
    srl        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # srl 0x80000000, 0x0000001F
    li32 a1, 0x12345678
    li32 a2, 0x00000025
    flush_pipeline
    csrr s5, mcycle
    srl        a0, a1, a2
    srl        a0, a1, a2
    srl        a0, a1, a2
    srl        a0, a1, a2
    srl        a0, a1, a2
    srl        a0, a1, a2
    srl        a0, a1, a2
    srl        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # srl 0x12345678, 0x00000025
    li32 a1, 0x7FFFFFFF
    li32 a2, 0xFFFFFFE3
    flush_pipeline
    csrr s5, mcycle
    srl        a0, a1, a2
    srl        a0, a1, a2
    srl        a0, a1, a2
    srl        a0, a1, a2
    srl        a0, a1, a2
    srl        a0, a1, a2
    srl        a0, a1, a2
    srl        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # srl 0x7FFFFFFF, 0xFFFFFFE3
    li32 a1, 0x80000001
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    sra        a0, a1, a2
    sra        a0, a1, a2
    sra        a0, a1, a2
    sra        a0, a1, a2
    sra        a0, a1, a2
    sra        a0, a1, a2
    sra        a0, a1, a2
    sra        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # sra 0x80000001, 0x00000000
    li32 a1, 0xFFFFFFFF
    li32 a2, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    sra        a0, a1, a2
    sra        a0, a1, a2
    sra        a0, a1, a2
    sra        a0, a1, a2
    sra        a0, a1, a2
    sra        a0, a1, a2
    sra        a0, a1, a2
    sra        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # sra 0xFFFFFFFF, 0x00000001
    li32 a1, 0x80000000
    li32 a2, 0x0000001F
    flush_pipeline
    csrr s5, mcycle
    sra        a0, a1, a2
    sra        a0, a1, a2
    sra        a0, a1, a2
    sra        a0, a1, a2
    sra        a0, a1, a2
    sra        a0, a1, a2
    sra        a0, a1, a2
    sra        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # sra 0x80000000, 0x0000001F
    li32 a1, 0x12345678
    li32 a2, 0x00000025
    flush_pipeline
    csrr s5, mcycle
    sra        a0, a1, a2
    sra        a0, a1, a2
    sra        a0, a1, a2
    sra        a0, a1, a2
    sra        a0, a1, a2
    sra        a0, a1, a2
    sra        a0, a1, a2
    sra        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # sra 0x12345678, 0x00000025
    li32 a1, 0x7FFFFFFF
    li32 a2, 0xFFFFFFE3
    flush_pipeline
    csrr s5, mcycle
    sra        a0, a1, a2
    sra        a0, a1, a2
    sra        a0, a1, a2
    sra        a0, a1, a2
    sra        a0, a1, a2
    sra        a0, a1, a2
    sra        a0, a1, a2
    sra        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # sra 0x7FFFFFFF, 0xFFFFFFE3

# -----------------------------------------------
# mul mulh mulhsu mulhu: always 2 cycles, including the operands that make a
# divider take its early exit (0x80000000 x -1, 0).
# Every block of 8 takes the same number of cycles whatever the operands.
test_mul:
    addi t2, zero, 4
    flush_pipeline
    li32 a1, 0x00000000
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    addi s8, s8, -8
    assert_equal s8, s9                # mul 0x00000000, 0x00000000
    li32 a1, 0x00000001
    li32 a2, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    addi s8, s8, -8
    assert_equal s8, s9                # mul 0x00000001, 0x00000001
    li32 a1, 0xFFFFFFFF
    li32 a2, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    addi s8, s8, -8
    assert_equal s8, s9                # mul 0xFFFFFFFF, 0xFFFFFFFF
    li32 a1, 0x80000000
    li32 a2, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    addi s8, s8, -8
    assert_equal s8, s9                # mul 0x80000000, 0xFFFFFFFF
    li32 a1, 0x7FFFFFFF
    li32 a2, 0x80000000
    flush_pipeline
    csrr s5, mcycle
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    addi s8, s8, -8
    assert_equal s8, s9                # mul 0x7FFFFFFF, 0x80000000
    li32 a1, 0x80000000
    li32 a2, 0x7FFFFFFF
    flush_pipeline
    csrr s5, mcycle
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    addi s8, s8, -8
    assert_equal s8, s9                # mul 0x80000000, 0x7FFFFFFF
    li32 a1, 0x12345678
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    mul        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    addi s8, s8, -8
    assert_equal s8, s9                # mul 0x12345678, 0x00000000
    li32 a1, 0x00000000
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    addi s8, s8, -8
    assert_equal s8, s9                # mulh 0x00000000, 0x00000000
    li32 a1, 0x00000001
    li32 a2, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    addi s8, s8, -8
    assert_equal s8, s9                # mulh 0x00000001, 0x00000001
    li32 a1, 0xFFFFFFFF
    li32 a2, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    addi s8, s8, -8
    assert_equal s8, s9                # mulh 0xFFFFFFFF, 0xFFFFFFFF
    li32 a1, 0x80000000
    li32 a2, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    addi s8, s8, -8
    assert_equal s8, s9                # mulh 0x80000000, 0xFFFFFFFF
    li32 a1, 0x7FFFFFFF
    li32 a2, 0x80000000
    flush_pipeline
    csrr s5, mcycle
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    addi s8, s8, -8
    assert_equal s8, s9                # mulh 0x7FFFFFFF, 0x80000000
    li32 a1, 0x80000000
    li32 a2, 0x7FFFFFFF
    flush_pipeline
    csrr s5, mcycle
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    addi s8, s8, -8
    assert_equal s8, s9                # mulh 0x80000000, 0x7FFFFFFF
    li32 a1, 0x12345678
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    mulh       a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    addi s8, s8, -8
    assert_equal s8, s9                # mulh 0x12345678, 0x00000000
    li32 a1, 0x00000000
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    addi s8, s8, -8
    assert_equal s8, s9                # mulhsu 0x00000000, 0x00000000
    li32 a1, 0x00000001
    li32 a2, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    addi s8, s8, -8
    assert_equal s8, s9                # mulhsu 0x00000001, 0x00000001
    li32 a1, 0xFFFFFFFF
    li32 a2, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    addi s8, s8, -8
    assert_equal s8, s9                # mulhsu 0xFFFFFFFF, 0xFFFFFFFF
    li32 a1, 0x80000000
    li32 a2, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    addi s8, s8, -8
    assert_equal s8, s9                # mulhsu 0x80000000, 0xFFFFFFFF
    li32 a1, 0x7FFFFFFF
    li32 a2, 0x80000000
    flush_pipeline
    csrr s5, mcycle
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    addi s8, s8, -8
    assert_equal s8, s9                # mulhsu 0x7FFFFFFF, 0x80000000
    li32 a1, 0x80000000
    li32 a2, 0x7FFFFFFF
    flush_pipeline
    csrr s5, mcycle
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    addi s8, s8, -8
    assert_equal s8, s9                # mulhsu 0x80000000, 0x7FFFFFFF
    li32 a1, 0x12345678
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    mulhsu     a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    addi s8, s8, -8
    assert_equal s8, s9                # mulhsu 0x12345678, 0x00000000
    li32 a1, 0x00000000
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    addi s8, s8, -8
    assert_equal s8, s9                # mulhu 0x00000000, 0x00000000
    li32 a1, 0x00000001
    li32 a2, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    addi s8, s8, -8
    assert_equal s8, s9                # mulhu 0x00000001, 0x00000001
    li32 a1, 0xFFFFFFFF
    li32 a2, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    addi s8, s8, -8
    assert_equal s8, s9                # mulhu 0xFFFFFFFF, 0xFFFFFFFF
    li32 a1, 0x80000000
    li32 a2, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    addi s8, s8, -8
    assert_equal s8, s9                # mulhu 0x80000000, 0xFFFFFFFF
    li32 a1, 0x7FFFFFFF
    li32 a2, 0x80000000
    flush_pipeline
    csrr s5, mcycle
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    addi s8, s8, -8
    assert_equal s8, s9                # mulhu 0x7FFFFFFF, 0x80000000
    li32 a1, 0x80000000
    li32 a2, 0x7FFFFFFF
    flush_pipeline
    csrr s5, mcycle
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    addi s8, s8, -8
    assert_equal s8, s9                # mulhu 0x80000000, 0x7FFFFFFF
    li32 a1, 0x12345678
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    mulhu      a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    addi s8, s8, -8
    assert_equal s8, s9                # mulhu 0x12345678, 0x00000000

# -----------------------------------------------
# Zbb andn orn xnor.
# Every block of 8 takes the same number of cycles whatever the operands.
test_zbb_logic:
    addi t2, zero, 5
    flush_pipeline
    li32 a1, 0x00000000
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # andn 0x00000000, 0x00000000
    li32 a1, 0x00000001
    li32 a2, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # andn 0x00000001, 0x00000001
    li32 a1, 0xFFFFFFFF
    li32 a2, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # andn 0xFFFFFFFF, 0xFFFFFFFF
    li32 a1, 0x80000000
    li32 a2, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # andn 0x80000000, 0xFFFFFFFF
    li32 a1, 0x7FFFFFFF
    li32 a2, 0x80000000
    flush_pipeline
    csrr s5, mcycle
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # andn 0x7FFFFFFF, 0x80000000
    li32 a1, 0x80000000
    li32 a2, 0x7FFFFFFF
    flush_pipeline
    csrr s5, mcycle
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # andn 0x80000000, 0x7FFFFFFF
    li32 a1, 0x12345678
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    andn       a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # andn 0x12345678, 0x00000000
    li32 a1, 0x00000000
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # orn 0x00000000, 0x00000000
    li32 a1, 0x00000001
    li32 a2, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # orn 0x00000001, 0x00000001
    li32 a1, 0xFFFFFFFF
    li32 a2, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # orn 0xFFFFFFFF, 0xFFFFFFFF
    li32 a1, 0x80000000
    li32 a2, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # orn 0x80000000, 0xFFFFFFFF
    li32 a1, 0x7FFFFFFF
    li32 a2, 0x80000000
    flush_pipeline
    csrr s5, mcycle
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # orn 0x7FFFFFFF, 0x80000000
    li32 a1, 0x80000000
    li32 a2, 0x7FFFFFFF
    flush_pipeline
    csrr s5, mcycle
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # orn 0x80000000, 0x7FFFFFFF
    li32 a1, 0x12345678
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    orn        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # orn 0x12345678, 0x00000000
    li32 a1, 0x00000000
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # xnor 0x00000000, 0x00000000
    li32 a1, 0x00000001
    li32 a2, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # xnor 0x00000001, 0x00000001
    li32 a1, 0xFFFFFFFF
    li32 a2, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # xnor 0xFFFFFFFF, 0xFFFFFFFF
    li32 a1, 0x80000000
    li32 a2, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # xnor 0x80000000, 0xFFFFFFFF
    li32 a1, 0x7FFFFFFF
    li32 a2, 0x80000000
    flush_pipeline
    csrr s5, mcycle
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # xnor 0x7FFFFFFF, 0x80000000
    li32 a1, 0x80000000
    li32 a2, 0x7FFFFFFF
    flush_pipeline
    csrr s5, mcycle
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # xnor 0x80000000, 0x7FFFFFFF
    li32 a1, 0x12345678
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    xnor       a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # xnor 0x12345678, 0x00000000

# -----------------------------------------------
# Zbb rol ror, amounts 0, 1, 31, 32 + k.
# Every block of 8 takes the same number of cycles whatever the operands.
test_zbb_rotate:
    addi t2, zero, 6
    flush_pipeline
    li32 a1, 0x80000001
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    rol        a0, a1, a2
    rol        a0, a1, a2
    rol        a0, a1, a2
    rol        a0, a1, a2
    rol        a0, a1, a2
    rol        a0, a1, a2
    rol        a0, a1, a2
    rol        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # rol 0x80000001, 0x00000000
    li32 a1, 0xFFFFFFFF
    li32 a2, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    rol        a0, a1, a2
    rol        a0, a1, a2
    rol        a0, a1, a2
    rol        a0, a1, a2
    rol        a0, a1, a2
    rol        a0, a1, a2
    rol        a0, a1, a2
    rol        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # rol 0xFFFFFFFF, 0x00000001
    li32 a1, 0x80000000
    li32 a2, 0x0000001F
    flush_pipeline
    csrr s5, mcycle
    rol        a0, a1, a2
    rol        a0, a1, a2
    rol        a0, a1, a2
    rol        a0, a1, a2
    rol        a0, a1, a2
    rol        a0, a1, a2
    rol        a0, a1, a2
    rol        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # rol 0x80000000, 0x0000001F
    li32 a1, 0x12345678
    li32 a2, 0x00000025
    flush_pipeline
    csrr s5, mcycle
    rol        a0, a1, a2
    rol        a0, a1, a2
    rol        a0, a1, a2
    rol        a0, a1, a2
    rol        a0, a1, a2
    rol        a0, a1, a2
    rol        a0, a1, a2
    rol        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # rol 0x12345678, 0x00000025
    li32 a1, 0x7FFFFFFF
    li32 a2, 0xFFFFFFE3
    flush_pipeline
    csrr s5, mcycle
    rol        a0, a1, a2
    rol        a0, a1, a2
    rol        a0, a1, a2
    rol        a0, a1, a2
    rol        a0, a1, a2
    rol        a0, a1, a2
    rol        a0, a1, a2
    rol        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # rol 0x7FFFFFFF, 0xFFFFFFE3
    li32 a1, 0x80000001
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    ror        a0, a1, a2
    ror        a0, a1, a2
    ror        a0, a1, a2
    ror        a0, a1, a2
    ror        a0, a1, a2
    ror        a0, a1, a2
    ror        a0, a1, a2
    ror        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # ror 0x80000001, 0x00000000
    li32 a1, 0xFFFFFFFF
    li32 a2, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    ror        a0, a1, a2
    ror        a0, a1, a2
    ror        a0, a1, a2
    ror        a0, a1, a2
    ror        a0, a1, a2
    ror        a0, a1, a2
    ror        a0, a1, a2
    ror        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # ror 0xFFFFFFFF, 0x00000001
    li32 a1, 0x80000000
    li32 a2, 0x0000001F
    flush_pipeline
    csrr s5, mcycle
    ror        a0, a1, a2
    ror        a0, a1, a2
    ror        a0, a1, a2
    ror        a0, a1, a2
    ror        a0, a1, a2
    ror        a0, a1, a2
    ror        a0, a1, a2
    ror        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # ror 0x80000000, 0x0000001F
    li32 a1, 0x12345678
    li32 a2, 0x00000025
    flush_pipeline
    csrr s5, mcycle
    ror        a0, a1, a2
    ror        a0, a1, a2
    ror        a0, a1, a2
    ror        a0, a1, a2
    ror        a0, a1, a2
    ror        a0, a1, a2
    ror        a0, a1, a2
    ror        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # ror 0x12345678, 0x00000025
    li32 a1, 0x7FFFFFFF
    li32 a2, 0xFFFFFFE3
    flush_pipeline
    csrr s5, mcycle
    ror        a0, a1, a2
    ror        a0, a1, a2
    ror        a0, a1, a2
    ror        a0, a1, a2
    ror        a0, a1, a2
    ror        a0, a1, a2
    ror        a0, a1, a2
    ror        a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # ror 0x7FFFFFFF, 0xFFFFFFE3

# -----------------------------------------------
# Zicond czero.eqz czero.nez with a zero and a non-zero condition.
# Every block of 8 takes the same number of cycles whatever the operands.
test_zicond:
    addi t2, zero, 7
    flush_pipeline
    li32 a1, 0x12345678
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # czero.eqz 0x12345678, 0x00000000
    li32 a1, 0x12345678
    li32 a2, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # czero.eqz 0x12345678, 0x00000001
    li32 a1, 0x00000000
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # czero.eqz 0x00000000, 0x00000000
    li32 a1, 0xFFFFFFFF
    li32 a2, 0x80000000
    flush_pipeline
    csrr s5, mcycle
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # czero.eqz 0xFFFFFFFF, 0x80000000
    li32 a1, 0x80000000
    li32 a2, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    czero_eqz  a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # czero.eqz 0x80000000, 0xFFFFFFFF
    li32 a1, 0x12345678
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # czero.nez 0x12345678, 0x00000000
    li32 a1, 0x12345678
    li32 a2, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # czero.nez 0x12345678, 0x00000001
    li32 a1, 0x00000000
    li32 a2, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # czero.nez 0x00000000, 0x00000000
    li32 a1, 0xFFFFFFFF
    li32 a2, 0x80000000
    flush_pipeline
    csrr s5, mcycle
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # czero.nez 0xFFFFFFFF, 0x80000000
    li32 a1, 0x80000000
    li32 a2, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    czero_nez  a0, a1, a2
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # czero.nez 0x80000000, 0xFFFFFFFF

# -----------------------------------------------
# RV32I register-immediate: addi slti sltiu xori ori andi slli srli srai,
# Zbb rori and rev8, lui and auipc, for several rs1 values.
test_immediate_forms:
    addi t2, zero, 8
    flush_pipeline
    li32 a1, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    addi       a0, a1, -1
    addi       a0, a1, -1
    addi       a0, a1, -1
    addi       a0, a1, -1
    addi       a0, a1, -1
    addi       a0, a1, -1
    addi       a0, a1, -1
    addi       a0, a1, -1
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # addi 0x00000000, -1
    li32 a1, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    addi       a0, a1, -1
    addi       a0, a1, -1
    addi       a0, a1, -1
    addi       a0, a1, -1
    addi       a0, a1, -1
    addi       a0, a1, -1
    addi       a0, a1, -1
    addi       a0, a1, -1
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # addi 0x00000001, -1
    li32 a1, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    addi       a0, a1, -1
    addi       a0, a1, -1
    addi       a0, a1, -1
    addi       a0, a1, -1
    addi       a0, a1, -1
    addi       a0, a1, -1
    addi       a0, a1, -1
    addi       a0, a1, -1
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # addi 0xFFFFFFFF, -1
    li32 a1, 0x80000000
    flush_pipeline
    csrr s5, mcycle
    addi       a0, a1, -1
    addi       a0, a1, -1
    addi       a0, a1, -1
    addi       a0, a1, -1
    addi       a0, a1, -1
    addi       a0, a1, -1
    addi       a0, a1, -1
    addi       a0, a1, -1
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # addi 0x80000000, -1
    li32 a1, 0x7FFFFFFF
    flush_pipeline
    csrr s5, mcycle
    addi       a0, a1, -1
    addi       a0, a1, -1
    addi       a0, a1, -1
    addi       a0, a1, -1
    addi       a0, a1, -1
    addi       a0, a1, -1
    addi       a0, a1, -1
    addi       a0, a1, -1
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # addi 0x7FFFFFFF, -1
    li32 a1, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    slti       a0, a1, 0
    slti       a0, a1, 0
    slti       a0, a1, 0
    slti       a0, a1, 0
    slti       a0, a1, 0
    slti       a0, a1, 0
    slti       a0, a1, 0
    slti       a0, a1, 0
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # slti 0x00000000, 0
    li32 a1, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    slti       a0, a1, 0
    slti       a0, a1, 0
    slti       a0, a1, 0
    slti       a0, a1, 0
    slti       a0, a1, 0
    slti       a0, a1, 0
    slti       a0, a1, 0
    slti       a0, a1, 0
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # slti 0x00000001, 0
    li32 a1, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    slti       a0, a1, 0
    slti       a0, a1, 0
    slti       a0, a1, 0
    slti       a0, a1, 0
    slti       a0, a1, 0
    slti       a0, a1, 0
    slti       a0, a1, 0
    slti       a0, a1, 0
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # slti 0xFFFFFFFF, 0
    li32 a1, 0x80000000
    flush_pipeline
    csrr s5, mcycle
    slti       a0, a1, 0
    slti       a0, a1, 0
    slti       a0, a1, 0
    slti       a0, a1, 0
    slti       a0, a1, 0
    slti       a0, a1, 0
    slti       a0, a1, 0
    slti       a0, a1, 0
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # slti 0x80000000, 0
    li32 a1, 0x7FFFFFFF
    flush_pipeline
    csrr s5, mcycle
    slti       a0, a1, 0
    slti       a0, a1, 0
    slti       a0, a1, 0
    slti       a0, a1, 0
    slti       a0, a1, 0
    slti       a0, a1, 0
    slti       a0, a1, 0
    slti       a0, a1, 0
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # slti 0x7FFFFFFF, 0
    li32 a1, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # sltiu 0x00000000, 1
    li32 a1, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # sltiu 0x00000001, 1
    li32 a1, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # sltiu 0xFFFFFFFF, 1
    li32 a1, 0x80000000
    flush_pipeline
    csrr s5, mcycle
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # sltiu 0x80000000, 1
    li32 a1, 0x7FFFFFFF
    flush_pipeline
    csrr s5, mcycle
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    sltiu      a0, a1, 1
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # sltiu 0x7FFFFFFF, 1
    li32 a1, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # xori 0x00000000, -2048
    li32 a1, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # xori 0x00000001, -2048
    li32 a1, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # xori 0xFFFFFFFF, -2048
    li32 a1, 0x80000000
    flush_pipeline
    csrr s5, mcycle
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # xori 0x80000000, -2048
    li32 a1, 0x7FFFFFFF
    flush_pipeline
    csrr s5, mcycle
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    xori       a0, a1, -2048
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # xori 0x7FFFFFFF, -2048
    li32 a1, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # ori 0x00000000, 2047
    li32 a1, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # ori 0x00000001, 2047
    li32 a1, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # ori 0xFFFFFFFF, 2047
    li32 a1, 0x80000000
    flush_pipeline
    csrr s5, mcycle
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # ori 0x80000000, 2047
    li32 a1, 0x7FFFFFFF
    flush_pipeline
    csrr s5, mcycle
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    ori        a0, a1, 2047
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # ori 0x7FFFFFFF, 2047
    li32 a1, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    andi       a0, a1, -1
    andi       a0, a1, -1
    andi       a0, a1, -1
    andi       a0, a1, -1
    andi       a0, a1, -1
    andi       a0, a1, -1
    andi       a0, a1, -1
    andi       a0, a1, -1
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # andi 0x00000000, -1
    li32 a1, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    andi       a0, a1, -1
    andi       a0, a1, -1
    andi       a0, a1, -1
    andi       a0, a1, -1
    andi       a0, a1, -1
    andi       a0, a1, -1
    andi       a0, a1, -1
    andi       a0, a1, -1
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # andi 0x00000001, -1
    li32 a1, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    andi       a0, a1, -1
    andi       a0, a1, -1
    andi       a0, a1, -1
    andi       a0, a1, -1
    andi       a0, a1, -1
    andi       a0, a1, -1
    andi       a0, a1, -1
    andi       a0, a1, -1
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # andi 0xFFFFFFFF, -1
    li32 a1, 0x80000000
    flush_pipeline
    csrr s5, mcycle
    andi       a0, a1, -1
    andi       a0, a1, -1
    andi       a0, a1, -1
    andi       a0, a1, -1
    andi       a0, a1, -1
    andi       a0, a1, -1
    andi       a0, a1, -1
    andi       a0, a1, -1
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # andi 0x80000000, -1
    li32 a1, 0x7FFFFFFF
    flush_pipeline
    csrr s5, mcycle
    andi       a0, a1, -1
    andi       a0, a1, -1
    andi       a0, a1, -1
    andi       a0, a1, -1
    andi       a0, a1, -1
    andi       a0, a1, -1
    andi       a0, a1, -1
    andi       a0, a1, -1
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # andi 0x7FFFFFFF, -1
    li32 a1, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    slli       a0, a1, 0
    slli       a0, a1, 0
    slli       a0, a1, 0
    slli       a0, a1, 0
    slli       a0, a1, 0
    slli       a0, a1, 0
    slli       a0, a1, 0
    slli       a0, a1, 0
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # slli 0x00000000, 0
    li32 a1, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    slli       a0, a1, 0
    slli       a0, a1, 0
    slli       a0, a1, 0
    slli       a0, a1, 0
    slli       a0, a1, 0
    slli       a0, a1, 0
    slli       a0, a1, 0
    slli       a0, a1, 0
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # slli 0x00000001, 0
    li32 a1, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    slli       a0, a1, 0
    slli       a0, a1, 0
    slli       a0, a1, 0
    slli       a0, a1, 0
    slli       a0, a1, 0
    slli       a0, a1, 0
    slli       a0, a1, 0
    slli       a0, a1, 0
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # slli 0xFFFFFFFF, 0
    li32 a1, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    slli       a0, a1, 31
    slli       a0, a1, 31
    slli       a0, a1, 31
    slli       a0, a1, 31
    slli       a0, a1, 31
    slli       a0, a1, 31
    slli       a0, a1, 31
    slli       a0, a1, 31
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # slli 0x00000000, 31
    li32 a1, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    slli       a0, a1, 31
    slli       a0, a1, 31
    slli       a0, a1, 31
    slli       a0, a1, 31
    slli       a0, a1, 31
    slli       a0, a1, 31
    slli       a0, a1, 31
    slli       a0, a1, 31
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # slli 0x00000001, 31
    li32 a1, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    slli       a0, a1, 31
    slli       a0, a1, 31
    slli       a0, a1, 31
    slli       a0, a1, 31
    slli       a0, a1, 31
    slli       a0, a1, 31
    slli       a0, a1, 31
    slli       a0, a1, 31
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # slli 0xFFFFFFFF, 31
    li32 a1, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    srli       a0, a1, 1
    srli       a0, a1, 1
    srli       a0, a1, 1
    srli       a0, a1, 1
    srli       a0, a1, 1
    srli       a0, a1, 1
    srli       a0, a1, 1
    srli       a0, a1, 1
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # srli 0x00000000, 1
    li32 a1, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    srli       a0, a1, 1
    srli       a0, a1, 1
    srli       a0, a1, 1
    srli       a0, a1, 1
    srli       a0, a1, 1
    srli       a0, a1, 1
    srli       a0, a1, 1
    srli       a0, a1, 1
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # srli 0x00000001, 1
    li32 a1, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    srli       a0, a1, 1
    srli       a0, a1, 1
    srli       a0, a1, 1
    srli       a0, a1, 1
    srli       a0, a1, 1
    srli       a0, a1, 1
    srli       a0, a1, 1
    srli       a0, a1, 1
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # srli 0xFFFFFFFF, 1
    li32 a1, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    srli       a0, a1, 31
    srli       a0, a1, 31
    srli       a0, a1, 31
    srli       a0, a1, 31
    srli       a0, a1, 31
    srli       a0, a1, 31
    srli       a0, a1, 31
    srli       a0, a1, 31
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # srli 0x00000000, 31
    li32 a1, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    srli       a0, a1, 31
    srli       a0, a1, 31
    srli       a0, a1, 31
    srli       a0, a1, 31
    srli       a0, a1, 31
    srli       a0, a1, 31
    srli       a0, a1, 31
    srli       a0, a1, 31
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # srli 0x00000001, 31
    li32 a1, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    srli       a0, a1, 31
    srli       a0, a1, 31
    srli       a0, a1, 31
    srli       a0, a1, 31
    srli       a0, a1, 31
    srli       a0, a1, 31
    srli       a0, a1, 31
    srli       a0, a1, 31
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # srli 0xFFFFFFFF, 31
    li32 a1, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    srai       a0, a1, 31
    srai       a0, a1, 31
    srai       a0, a1, 31
    srai       a0, a1, 31
    srai       a0, a1, 31
    srai       a0, a1, 31
    srai       a0, a1, 31
    srai       a0, a1, 31
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # srai 0x00000000, 31
    li32 a1, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    srai       a0, a1, 31
    srai       a0, a1, 31
    srai       a0, a1, 31
    srai       a0, a1, 31
    srai       a0, a1, 31
    srai       a0, a1, 31
    srai       a0, a1, 31
    srai       a0, a1, 31
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # srai 0x00000001, 31
    li32 a1, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    srai       a0, a1, 31
    srai       a0, a1, 31
    srai       a0, a1, 31
    srai       a0, a1, 31
    srai       a0, a1, 31
    srai       a0, a1, 31
    srai       a0, a1, 31
    srai       a0, a1, 31
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # srai 0xFFFFFFFF, 31
    li32 a1, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    srai       a0, a1, 1
    srai       a0, a1, 1
    srai       a0, a1, 1
    srai       a0, a1, 1
    srai       a0, a1, 1
    srai       a0, a1, 1
    srai       a0, a1, 1
    srai       a0, a1, 1
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # srai 0x00000000, 1
    li32 a1, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    srai       a0, a1, 1
    srai       a0, a1, 1
    srai       a0, a1, 1
    srai       a0, a1, 1
    srai       a0, a1, 1
    srai       a0, a1, 1
    srai       a0, a1, 1
    srai       a0, a1, 1
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # srai 0x00000001, 1
    li32 a1, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    srai       a0, a1, 1
    srai       a0, a1, 1
    srai       a0, a1, 1
    srai       a0, a1, 1
    srai       a0, a1, 1
    srai       a0, a1, 1
    srai       a0, a1, 1
    srai       a0, a1, 1
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # srai 0xFFFFFFFF, 1
    li32 a1, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    rori       a0, a1, 0
    rori       a0, a1, 0
    rori       a0, a1, 0
    rori       a0, a1, 0
    rori       a0, a1, 0
    rori       a0, a1, 0
    rori       a0, a1, 0
    rori       a0, a1, 0
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # rori 0x00000000, 0
    li32 a1, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    rori       a0, a1, 0
    rori       a0, a1, 0
    rori       a0, a1, 0
    rori       a0, a1, 0
    rori       a0, a1, 0
    rori       a0, a1, 0
    rori       a0, a1, 0
    rori       a0, a1, 0
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # rori 0x00000001, 0
    li32 a1, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    rori       a0, a1, 0
    rori       a0, a1, 0
    rori       a0, a1, 0
    rori       a0, a1, 0
    rori       a0, a1, 0
    rori       a0, a1, 0
    rori       a0, a1, 0
    rori       a0, a1, 0
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # rori 0xFFFFFFFF, 0
    li32 a1, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    rori       a0, a1, 1
    rori       a0, a1, 1
    rori       a0, a1, 1
    rori       a0, a1, 1
    rori       a0, a1, 1
    rori       a0, a1, 1
    rori       a0, a1, 1
    rori       a0, a1, 1
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # rori 0x00000000, 1
    li32 a1, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    rori       a0, a1, 1
    rori       a0, a1, 1
    rori       a0, a1, 1
    rori       a0, a1, 1
    rori       a0, a1, 1
    rori       a0, a1, 1
    rori       a0, a1, 1
    rori       a0, a1, 1
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # rori 0x00000001, 1
    li32 a1, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    rori       a0, a1, 1
    rori       a0, a1, 1
    rori       a0, a1, 1
    rori       a0, a1, 1
    rori       a0, a1, 1
    rori       a0, a1, 1
    rori       a0, a1, 1
    rori       a0, a1, 1
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # rori 0xFFFFFFFF, 1
    li32 a1, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    rori       a0, a1, 31
    rori       a0, a1, 31
    rori       a0, a1, 31
    rori       a0, a1, 31
    rori       a0, a1, 31
    rori       a0, a1, 31
    rori       a0, a1, 31
    rori       a0, a1, 31
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # rori 0x00000000, 31
    li32 a1, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    rori       a0, a1, 31
    rori       a0, a1, 31
    rori       a0, a1, 31
    rori       a0, a1, 31
    rori       a0, a1, 31
    rori       a0, a1, 31
    rori       a0, a1, 31
    rori       a0, a1, 31
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # rori 0x00000001, 31
    li32 a1, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    rori       a0, a1, 31
    rori       a0, a1, 31
    rori       a0, a1, 31
    rori       a0, a1, 31
    rori       a0, a1, 31
    rori       a0, a1, 31
    rori       a0, a1, 31
    rori       a0, a1, 31
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # rori 0xFFFFFFFF, 31
    li32 a1, 0x00000000
    flush_pipeline
    csrr s5, mcycle
    rev8       a0, a1
    rev8       a0, a1
    rev8       a0, a1
    rev8       a0, a1
    rev8       a0, a1
    rev8       a0, a1
    rev8       a0, a1
    rev8       a0, a1
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # rev8 0x00000000
    li32 a1, 0x00000001
    flush_pipeline
    csrr s5, mcycle
    rev8       a0, a1
    rev8       a0, a1
    rev8       a0, a1
    rev8       a0, a1
    rev8       a0, a1
    rev8       a0, a1
    rev8       a0, a1
    rev8       a0, a1
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # rev8 0x00000001
    li32 a1, 0xFFFFFFFF
    flush_pipeline
    csrr s5, mcycle
    rev8       a0, a1
    rev8       a0, a1
    rev8       a0, a1
    rev8       a0, a1
    rev8       a0, a1
    rev8       a0, a1
    rev8       a0, a1
    rev8       a0, a1
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # rev8 0xFFFFFFFF
    li32 a1, 0x80000000
    flush_pipeline
    csrr s5, mcycle
    rev8       a0, a1
    rev8       a0, a1
    rev8       a0, a1
    rev8       a0, a1
    rev8       a0, a1
    rev8       a0, a1
    rev8       a0, a1
    rev8       a0, a1
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # rev8 0x80000000
    li32 a1, 0x7FFFFFFF
    flush_pipeline
    csrr s5, mcycle
    rev8       a0, a1
    rev8       a0, a1
    rev8       a0, a1
    rev8       a0, a1
    rev8       a0, a1
    rev8       a0, a1
    rev8       a0, a1
    rev8       a0, a1
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # rev8 0x7FFFFFFF
    flush_pipeline
    csrr s5, mcycle
    lui  a0, 0x80000
    lui  a0, 0x80000
    lui  a0, 0x80000
    lui  a0, 0x80000
    lui  a0, 0x80000
    lui  a0, 0x80000
    lui  a0, 0x80000
    lui  a0, 0x80000
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # lui
    flush_pipeline
    csrr s5, mcycle
    auipc a0, 0xFFFFF
    auipc a0, 0xFFFFF
    auipc a0, 0xFFFFF
    auipc a0, 0xFFFFF
    auipc a0, 0xFFFFF
    auipc a0, 0xFFFFF
    auipc a0, 0xFFFFF
    auipc a0, 0xFFFFF
    csrr s6, mcycle
    sub  s8, s6, s5
    assert_equal s8, s9                # auipc

# ------------------------------------------------------------------------------------------------
# |                                          Test done!                                          |
# ------------------------------------------------------------------------------------------------
test_finish:
    addi t2, zero, 9
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
