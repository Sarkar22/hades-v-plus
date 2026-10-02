# Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
# Embedded Architectures & Systems Group, Graz University of Technology
# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: hints.s
#
# ------------------------------------------------------------------------------------------------
# |                                                                                              |
# | Hint test: Zihintpause (pause) and Zihintntl (ntl.p1, ntl.pall, ntl.s1, ntl.all).            |
# | The hints are encodings of existing instructions: pause is a FENCE with pred = W,            |
# | succ = 0, and the NTL hints are ADD x0, x0, x2..x5. They are written as words (the           |
# | toolchain cannot name Zihintntl, and pause needs +zihintpause).                              |
# | If everything runs correctly, the first register of the peripheral test module               |
# | should always be zero, except during the first test, which checks the assert macro itself.   |
# | Note: This condition is necessary, but not sufficient to prove correctness.                  |
# |                                                                                              |
# | Every expected value below was computed from the ISA text by a separate model, never by      |
# | running the core. A trap handler is armed for the whole test and turns any exception into    |
# | a failure.                                                                                   |
# |                                                                                              |
# | What is checked:                                                                             |
# | 1. Each hint right after a store, right before a dependent load and in a loop: no trap,      |
# |    x0 still 0, the registers the NTL hints name (x2..x5) and others unchanged, the           |
# |    stored word unchanged.                                                                    |
# | 2. Each hint retires as exactly one instruction (minstret).                                  |
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
# pause (Zihintpause): fence w, 0: right after a store, right before a dependent load,
# and in a loop: no trap, x0 still 0, no register and no stored
# word changed.
test_hint_after_store:
    addi t2, zero, 1
    flush_pipeline
    li32 sp, 0x22220002
    li32 gp, 0x33330003
    li32 tp, 0x44440004
    li32 s1, 0x55550009
    li32 a0, 0xAAAA000A
    li32 a5, 0xA5A5000F
    li32 t5, 0x600DF00D
    sw   t5, 20(t4)
    .word 0x0100000F
    lw   s3, 20(t4)
    .word 0x0100000F
    addi s4, s3, 1
    assert_value s3, 0x600DF00D
    assert_value s4, 0x600DF00E
    addi s3, zero, 10
hint_loop_1:
    .word 0x0100000F
    addi s3, s3, -1
    .word 0x0100000F
    bne  s3, zero, hint_loop_1
    assert_value s3, 0x00000000
    .word 0x0100000F
    add  s2, zero, zero        # x0 read right behind the hint
    assert_value s2, 0
    assert_value sp, 0x22220002
    assert_value gp, 0x33330003
    assert_value tp, 0x44440004
    assert_value s1, 0x55550009
    assert_value a0, 0xAAAA000A
    assert_value a5, 0xA5A5000F

# -----------------------------------------------
# ntl.p1 (Zihintntl): add x0, x0, x2: right after a store, right before a dependent load,
# and in a loop: no trap, x0 still 0, no register and no stored
# word changed.
test_hint_after_store_2:
    addi t2, zero, 2
    flush_pipeline
    li32 sp, 0x22220002
    li32 gp, 0x33330003
    li32 tp, 0x44440004
    li32 s1, 0x55550009
    li32 a0, 0xAAAA000A
    li32 a5, 0xA5A5000F
    li32 t5, 0x600DF00D
    sw   t5, 20(t4)
    .word 0x00200033
    lw   s3, 20(t4)
    .word 0x00200033
    addi s4, s3, 1
    assert_value s3, 0x600DF00D
    assert_value s4, 0x600DF00E
    addi s3, zero, 10
hint_loop_2:
    .word 0x00200033
    addi s3, s3, -1
    .word 0x00200033
    bne  s3, zero, hint_loop_2
    assert_value s3, 0x00000000
    .word 0x00200033
    add  s2, zero, zero        # x0 read right behind the hint
    assert_value s2, 0
    assert_value sp, 0x22220002
    assert_value gp, 0x33330003
    assert_value tp, 0x44440004
    assert_value s1, 0x55550009
    assert_value a0, 0xAAAA000A
    assert_value a5, 0xA5A5000F

# -----------------------------------------------
# ntl.pall: add x0, x0, x3: right after a store, right before a dependent load,
# and in a loop: no trap, x0 still 0, no register and no stored
# word changed.
test_hint_after_store_3:
    addi t2, zero, 3
    flush_pipeline
    li32 sp, 0x22220002
    li32 gp, 0x33330003
    li32 tp, 0x44440004
    li32 s1, 0x55550009
    li32 a0, 0xAAAA000A
    li32 a5, 0xA5A5000F
    li32 t5, 0x600DF00D
    sw   t5, 20(t4)
    .word 0x00300033
    lw   s3, 20(t4)
    .word 0x00300033
    addi s4, s3, 1
    assert_value s3, 0x600DF00D
    assert_value s4, 0x600DF00E
    addi s3, zero, 10
hint_loop_3:
    .word 0x00300033
    addi s3, s3, -1
    .word 0x00300033
    bne  s3, zero, hint_loop_3
    assert_value s3, 0x00000000
    .word 0x00300033
    add  s2, zero, zero        # x0 read right behind the hint
    assert_value s2, 0
    assert_value sp, 0x22220002
    assert_value gp, 0x33330003
    assert_value tp, 0x44440004
    assert_value s1, 0x55550009
    assert_value a0, 0xAAAA000A
    assert_value a5, 0xA5A5000F

# -----------------------------------------------
# ntl.s1: add x0, x0, x4: right after a store, right before a dependent load,
# and in a loop: no trap, x0 still 0, no register and no stored
# word changed.
test_hint_after_store_4:
    addi t2, zero, 4
    flush_pipeline
    li32 sp, 0x22220002
    li32 gp, 0x33330003
    li32 tp, 0x44440004
    li32 s1, 0x55550009
    li32 a0, 0xAAAA000A
    li32 a5, 0xA5A5000F
    li32 t5, 0x600DF00D
    sw   t5, 20(t4)
    .word 0x00400033
    lw   s3, 20(t4)
    .word 0x00400033
    addi s4, s3, 1
    assert_value s3, 0x600DF00D
    assert_value s4, 0x600DF00E
    addi s3, zero, 10
hint_loop_4:
    .word 0x00400033
    addi s3, s3, -1
    .word 0x00400033
    bne  s3, zero, hint_loop_4
    assert_value s3, 0x00000000
    .word 0x00400033
    add  s2, zero, zero        # x0 read right behind the hint
    assert_value s2, 0
    assert_value sp, 0x22220002
    assert_value gp, 0x33330003
    assert_value tp, 0x44440004
    assert_value s1, 0x55550009
    assert_value a0, 0xAAAA000A
    assert_value a5, 0xA5A5000F

# -----------------------------------------------
# ntl.all: add x0, x0, x5: right after a store, right before a dependent load,
# and in a loop: no trap, x0 still 0, no register and no stored
# word changed.
test_hint_after_store_5:
    addi t2, zero, 5
    flush_pipeline
    li32 sp, 0x22220002
    li32 gp, 0x33330003
    li32 tp, 0x44440004
    li32 s1, 0x55550009
    li32 a0, 0xAAAA000A
    li32 a5, 0xA5A5000F
    li32 t5, 0x600DF00D
    sw   t5, 20(t4)
    .word 0x00500033
    lw   s3, 20(t4)
    .word 0x00500033
    addi s4, s3, 1
    assert_value s3, 0x600DF00D
    assert_value s4, 0x600DF00E
    addi s3, zero, 10
hint_loop_5:
    .word 0x00500033
    addi s3, s3, -1
    .word 0x00500033
    bne  s3, zero, hint_loop_5
    assert_value s3, 0x00000000
    .word 0x00500033
    add  s2, zero, zero        # x0 read right behind the hint
    assert_value s2, 0
    assert_value sp, 0x22220002
    assert_value gp, 0x33330003
    assert_value tp, 0x44440004
    assert_value s1, 0x55550009
    assert_value a0, 0xAAAA000A
    assert_value a5, 0xA5A5000F

# -----------------------------------------------
# Each hint retires as one instruction: minstret rises by exactly 1 per hint
# (a window with the five hints against an empty window).
test_hint_minstret:
    addi t2, zero, 6
    flush_pipeline
    csrr s5, minstret
    csrr s6, minstret
    sub  s8, s6, s5
    flush_pipeline
    csrr s5, minstret
    .word 0x0100000F
    .word 0x00200033
    .word 0x00300033
    .word 0x00400033
    .word 0x00500033
    csrr s6, minstret
    sub  s9, s6, s5
    sub  s9, s9, s8
    assert_value s9, 0x00000005
    flush_pipeline
    csrr s5, minstret
    .word 0x0100000F
    csrr s6, minstret
    sub  s9, s6, s5
    sub  s9, s9, s8
    assert_value s9, 0x00000001
    flush_pipeline
    csrr s5, minstret
    .word 0x00200033
    csrr s6, minstret
    sub  s9, s6, s5
    sub  s9, s9, s8
    assert_value s9, 0x00000001
    flush_pipeline
    csrr s5, minstret
    .word 0x00300033
    csrr s6, minstret
    sub  s9, s6, s5
    sub  s9, s9, s8
    assert_value s9, 0x00000001
    flush_pipeline
    csrr s5, minstret
    .word 0x00400033
    csrr s6, minstret
    sub  s9, s6, s5
    sub  s9, s9, s8
    assert_value s9, 0x00000001
    flush_pipeline
    csrr s5, minstret
    .word 0x00500033
    csrr s6, minstret
    sub  s9, s6, s5
    sub  s9, s9, s8
    assert_value s9, 0x00000001

# ------------------------------------------------------------------------------------------------
# |                                          Test done!                                          |
# ------------------------------------------------------------------------------------------------
test_finish:
    addi t2, zero, 7
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
