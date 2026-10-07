# Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
# Embedded Architectures & Systems Group, Graz University of Technology
# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: zbkx.s
#
# ------------------------------------------------------------------------------------------------
# |                                                                                              |
# | Zbkx extension test (crossbar permutations, 2 instructions): xperm4 xperm8.                  |
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
# | 1. The known answers of the ISA text and corner operands: rs1 is the TABLE and rs2           |
# |    the INDICES (swapping them gives another result); an index past the end of the            |
# |    table (8..15 for xperm4, 4..255 for xperm8) gives 0, never a wrapped element.             |
# | 2. Every index value at every element position, against tables whose elements are all        |
# |    different (one of them without a zero element, so 0 can only mean out of range).          |
# | 3. rd = x0 discarded (also for the instruction right behind it), x0 as a source,             |
# |    rd == rs1 / rs2 / both.                                                                   |
# | 4. Forwarding into rs1 and rs2 at distance 1, 2, 3, from two stages at once; a               |
# |    load-use stall in front; forwarding out into an ALU op, a branch, a load address,         |
# |    store data, a JALR base and a CSR write.                                                  |
# | 5. Not executed in the shadow of a taken branch; correct as a branch target; around          |
# |    fence.i; an interrupt at 8 positions of a chain changes nothing.                          |
# | 6. minstret counts each instruction once; a dependent chain takes exactly as many            |
# |    cycles as the same chain of add (no stall, forwarded in its own cycle).                   |
# | 7. The illegal neighbours (the unused funct3 values of funct7 0010100) raise                 |
# |    illegal-instruction.                                                                      |
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

.option arch, +zbkx

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
    addi t2, zero, 2
    flush_pipeline
    li32 t5, 0x44332211
    li32 t6, 0x00010203
    xperm8     s1, t5, t6
    assert_value s1, 0x11223344
    li32 t5, 0x44332211
    li32 t6, 0x04FF0100
    xperm8     s1, t5, t6
    assert_value s1, 0x00002211
    li32 t5, 0x76543210
    li32 t6, 0x01234567
    xperm4     s1, t5, t6
    assert_value s1, 0x01234567
    li32 t5, 0x76543210
    li32 t6, 0x89ABCDEF
    xperm4     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0xFEDCBA98
    li32 t6, 0xF0F0F0F0
    xperm4     s1, t5, t6
    assert_value s1, 0x08080808

# -----------------------------------------------
# xperm4: every index value 0..15 at every nibble position. Index word j
# has index (i + j) mod 16 in nibble i, so over the 16 words each
# position sees every index once; 8..15 must give 0.
test_xperm4_every_index:
    addi t2, zero, 3
    flush_pipeline
    li32 t5, 0xA5F0C3E1
    li32 t6, 0x76543210
    xperm4     s1, t5, t6
    assert_value s1, 0xA5F0C3E1
    li32 t5, 0xA5F0C3E1
    li32 t6, 0x87654321
    xperm4     s1, t5, t6
    assert_value s1, 0x0A5F0C3E
    li32 t5, 0xA5F0C3E1
    li32 t6, 0x98765432
    xperm4     s1, t5, t6
    assert_value s1, 0x00A5F0C3
    li32 t5, 0xA5F0C3E1
    li32 t6, 0xA9876543
    xperm4     s1, t5, t6
    assert_value s1, 0x000A5F0C
    li32 t5, 0xA5F0C3E1
    li32 t6, 0xBA987654
    xperm4     s1, t5, t6
    assert_value s1, 0x0000A5F0
    li32 t5, 0xA5F0C3E1
    li32 t6, 0xCBA98765
    xperm4     s1, t5, t6
    assert_value s1, 0x00000A5F
    li32 t5, 0xA5F0C3E1
    li32 t6, 0xDCBA9876
    xperm4     s1, t5, t6
    assert_value s1, 0x000000A5
    li32 t5, 0xA5F0C3E1
    li32 t6, 0xEDCBA987
    xperm4     s1, t5, t6
    assert_value s1, 0x0000000A
    li32 t5, 0xA5F0C3E1
    li32 t6, 0xFEDCBA98
    xperm4     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0xA5F0C3E1
    li32 t6, 0x0FEDCBA9
    xperm4     s1, t5, t6
    assert_value s1, 0x10000000
    li32 t5, 0xA5F0C3E1
    li32 t6, 0x10FEDCBA
    xperm4     s1, t5, t6
    assert_value s1, 0xE1000000
    li32 t5, 0xA5F0C3E1
    li32 t6, 0x210FEDCB
    xperm4     s1, t5, t6
    assert_value s1, 0x3E100000
    li32 t5, 0xA5F0C3E1
    li32 t6, 0x3210FEDC
    xperm4     s1, t5, t6
    assert_value s1, 0xC3E10000
    li32 t5, 0xA5F0C3E1
    li32 t6, 0x43210FED
    xperm4     s1, t5, t6
    assert_value s1, 0x0C3E1000
    li32 t5, 0xA5F0C3E1
    li32 t6, 0x543210FE
    xperm4     s1, t5, t6
    assert_value s1, 0xF0C3E100
    li32 t5, 0xA5F0C3E1
    li32 t6, 0x6543210F
    xperm4     s1, t5, t6
    assert_value s1, 0x5F0C3E10
    li32 t5, 0x7B2D4E96
    li32 t6, 0x76543210
    xperm4     s1, t5, t6
    assert_value s1, 0x7B2D4E96
    li32 t5, 0x7B2D4E96
    li32 t6, 0x87654321
    xperm4     s1, t5, t6
    assert_value s1, 0x07B2D4E9
    li32 t5, 0x7B2D4E96
    li32 t6, 0x98765432
    xperm4     s1, t5, t6
    assert_value s1, 0x007B2D4E
    li32 t5, 0x7B2D4E96
    li32 t6, 0xA9876543
    xperm4     s1, t5, t6
    assert_value s1, 0x0007B2D4
    li32 t5, 0x7B2D4E96
    li32 t6, 0xBA987654
    xperm4     s1, t5, t6
    assert_value s1, 0x00007B2D
    li32 t5, 0x7B2D4E96
    li32 t6, 0xCBA98765
    xperm4     s1, t5, t6
    assert_value s1, 0x000007B2
    li32 t5, 0x7B2D4E96
    li32 t6, 0xDCBA9876
    xperm4     s1, t5, t6
    assert_value s1, 0x0000007B
    li32 t5, 0x7B2D4E96
    li32 t6, 0xEDCBA987
    xperm4     s1, t5, t6
    assert_value s1, 0x00000007
    li32 t5, 0x7B2D4E96
    li32 t6, 0xFEDCBA98
    xperm4     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x7B2D4E96
    li32 t6, 0x0FEDCBA9
    xperm4     s1, t5, t6
    assert_value s1, 0x60000000
    li32 t5, 0x7B2D4E96
    li32 t6, 0x10FEDCBA
    xperm4     s1, t5, t6
    assert_value s1, 0x96000000
    li32 t5, 0x7B2D4E96
    li32 t6, 0x210FEDCB
    xperm4     s1, t5, t6
    assert_value s1, 0xE9600000
    li32 t5, 0x7B2D4E96
    li32 t6, 0x3210FEDC
    xperm4     s1, t5, t6
    assert_value s1, 0x4E960000
    li32 t5, 0x7B2D4E96
    li32 t6, 0x43210FED
    xperm4     s1, t5, t6
    assert_value s1, 0xD4E96000
    li32 t5, 0x7B2D4E96
    li32 t6, 0x543210FE
    xperm4     s1, t5, t6
    assert_value s1, 0x2D4E9600
    li32 t5, 0x7B2D4E96
    li32 t6, 0x6543210F
    xperm4     s1, t5, t6
    assert_value s1, 0xB2D4E960

# -----------------------------------------------
# xperm8: at every byte position the in-range indices 0..3 and the
# out-of-range 4..8, 0x10, 0x20, 0x40, 0x80, 0x81, 0x83 and 0xFF (one
# high bit at a time and an index whose low two bits are in range).
test_xperm8_every_index:
    addi t2, zero, 4
    flush_pipeline
    li32 t5, 0xC3A55A3C
    li32 t6, 0x03020100
    xperm8     s1, t5, t6
    assert_value s1, 0xC3A55A3C
    li32 t5, 0xC3A55A3C
    li32 t6, 0x04030201
    xperm8     s1, t5, t6
    assert_value s1, 0x00C3A55A
    li32 t5, 0xC3A55A3C
    li32 t6, 0x05040302
    xperm8     s1, t5, t6
    assert_value s1, 0x0000C3A5
    li32 t5, 0xC3A55A3C
    li32 t6, 0x06050403
    xperm8     s1, t5, t6
    assert_value s1, 0x000000C3
    li32 t5, 0xC3A55A3C
    li32 t6, 0x07060504
    xperm8     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0xC3A55A3C
    li32 t6, 0x08070605
    xperm8     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0xC3A55A3C
    li32 t6, 0x10080706
    xperm8     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0xC3A55A3C
    li32 t6, 0x20100807
    xperm8     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0xC3A55A3C
    li32 t6, 0x40201008
    xperm8     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0xC3A55A3C
    li32 t6, 0x80402010
    xperm8     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0xC3A55A3C
    li32 t6, 0x81804020
    xperm8     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0xC3A55A3C
    li32 t6, 0x83818040
    xperm8     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0xC3A55A3C
    li32 t6, 0xFF838180
    xperm8     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0xC3A55A3C
    li32 t6, 0x00FF8381
    xperm8     s1, t5, t6
    assert_value s1, 0x3C000000
    li32 t5, 0xC3A55A3C
    li32 t6, 0x0100FF83
    xperm8     s1, t5, t6
    assert_value s1, 0x5A3C0000
    li32 t5, 0xC3A55A3C
    li32 t6, 0x020100FF
    xperm8     s1, t5, t6
    assert_value s1, 0xA55A3C00
    li32 t5, 0x0102F0FF
    li32 t6, 0x03020100
    xperm8     s1, t5, t6
    assert_value s1, 0x0102F0FF
    li32 t5, 0x0102F0FF
    li32 t6, 0x04030201
    xperm8     s1, t5, t6
    assert_value s1, 0x000102F0
    li32 t5, 0x0102F0FF
    li32 t6, 0x05040302
    xperm8     s1, t5, t6
    assert_value s1, 0x00000102
    li32 t5, 0x0102F0FF
    li32 t6, 0x06050403
    xperm8     s1, t5, t6
    assert_value s1, 0x00000001
    li32 t5, 0x0102F0FF
    li32 t6, 0x07060504
    xperm8     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x0102F0FF
    li32 t6, 0x08070605
    xperm8     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x0102F0FF
    li32 t6, 0x10080706
    xperm8     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x0102F0FF
    li32 t6, 0x20100807
    xperm8     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x0102F0FF
    li32 t6, 0x40201008
    xperm8     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x0102F0FF
    li32 t6, 0x80402010
    xperm8     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x0102F0FF
    li32 t6, 0x81804020
    xperm8     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x0102F0FF
    li32 t6, 0x83818040
    xperm8     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x0102F0FF
    li32 t6, 0xFF838180
    xperm8     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x0102F0FF
    li32 t6, 0x00FF8381
    xperm8     s1, t5, t6
    assert_value s1, 0xFF000000
    li32 t5, 0x0102F0FF
    li32 t6, 0x0100FF83
    xperm8     s1, t5, t6
    assert_value s1, 0xF0FF0000
    li32 t5, 0x0102F0FF
    li32 t6, 0x020100FF
    xperm8     s1, t5, t6
    assert_value s1, 0x02F0FF00

# -----------------------------------------------
# Tables 0 and -1 and the identity table, indices in range, out of range
# and mixed; rs1 is the table and rs2 the indices, so swapping them
# gives a different result.
test_xperm_corners:
    addi t2, zero, 5
    flush_pipeline
    li32 t5, 0x00000000
    li32 t6, 0x01234567
    xperm4     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000000
    li32 t6, 0x89ABCDEF
    xperm4     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000000
    li32 t6, 0x0F1E2D3C
    xperm4     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000000
    li32 t6, 0x00000000
    xperm4     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000000
    li32 t6, 0xFFFFFFFF
    xperm4     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0xFFFFFFFF
    li32 t6, 0x01234567
    xperm4     s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0xFFFFFFFF
    li32 t6, 0x89ABCDEF
    xperm4     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0xFFFFFFFF
    li32 t6, 0x0F1E2D3C
    xperm4     s1, t5, t6
    assert_value s1, 0xF0F0F0F0
    li32 t5, 0xFFFFFFFF
    li32 t6, 0x00000000
    xperm4     s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0xFFFFFFFF
    li32 t6, 0xFFFFFFFF
    xperm4     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x76543210
    li32 t6, 0x01234567
    xperm4     s1, t5, t6
    assert_value s1, 0x01234567
    li32 t5, 0x76543210
    li32 t6, 0x89ABCDEF
    xperm4     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x76543210
    li32 t6, 0x0F1E2D3C
    xperm4     s1, t5, t6
    assert_value s1, 0x00102030
    li32 t5, 0x76543210
    li32 t6, 0x00000000
    xperm4     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x76543210
    li32 t6, 0xFFFFFFFF
    xperm4     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000000
    li32 t6, 0x00010203
    xperm8     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000000
    li32 t6, 0xFFFFFFFF
    xperm8     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000000
    li32 t6, 0x04040404
    xperm8     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000000
    li32 t6, 0x04FF0100
    xperm8     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000000
    li32 t6, 0x00000000
    xperm8     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0xFFFFFFFF
    li32 t6, 0x00010203
    xperm8     s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0xFFFFFFFF
    li32 t6, 0xFFFFFFFF
    xperm8     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0xFFFFFFFF
    li32 t6, 0x04040404
    xperm8     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0xFFFFFFFF
    li32 t6, 0x04FF0100
    xperm8     s1, t5, t6
    assert_value s1, 0x0000FFFF
    li32 t5, 0xFFFFFFFF
    li32 t6, 0x00000000
    xperm8     s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x44332211
    li32 t6, 0x00010203
    xperm8     s1, t5, t6
    assert_value s1, 0x11223344
    li32 t5, 0x44332211
    li32 t6, 0xFFFFFFFF
    xperm8     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x44332211
    li32 t6, 0x04040404
    xperm8     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x44332211
    li32 t6, 0x04FF0100
    xperm8     s1, t5, t6
    assert_value s1, 0x00002211
    li32 t5, 0x44332211
    li32 t6, 0x00000000
    xperm8     s1, t5, t6
    assert_value s1, 0x11111111
    li32 t5, 0x03020100
    li32 t6, 0x44332211
    xperm4     s1, t5, t6
    assert_value s1, 0x22001100
    li32 t5, 0x44332211
    li32 t6, 0x03020100
    xperm4     s1, t5, t6
    assert_value s1, 0x12121111
    li32 t5, 0x03020100
    li32 t6, 0x44332211
    xperm8     s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x44332211
    li32 t6, 0x03020100
    xperm8     s1, t5, t6
    assert_value s1, 0x44332211

# -----------------------------------------------
# rd = x0 discards the result, also for the instruction right behind it,
# which must read 0 rather than a forwarded value.
test_rd_is_x0:
    addi t2, zero, 6
    flush_pipeline
    li32 t5, 0x12345678
    li32 t6, 0x03020100
    xperm8     zero, t5, t6
    add  s1, zero, zero           # reads x0 right behind the discarded result
    xperm4     zero, t5, t6
    add  s2, t5, zero
    assert_value s1, 0x00000000
    assert_value s2, 0x12345678
    xperm4     zero, t5, t6
    xperm4     s3, zero, t6
    assert_value s3, 0x00000000

# -----------------------------------------------
# x0 as a source operand.
test_x0_source:
    addi t2, zero, 7
    flush_pipeline
    li32 t5, 0x89ABCDEF
    li32 t6, 0x13579BDF
    xperm4     s1, zero, t6
    assert_value s1, 0x00000000
    xperm4     s1, t5, zero
    assert_value s1, 0xFFFFFFFF
    xperm4     s1, zero, zero
    assert_value s1, 0x00000000
    xperm8     s1, zero, t6
    assert_value s1, 0x00000000
    xperm8     s1, t5, zero
    assert_value s1, 0xEFEFEFEF
    xperm8     s1, zero, zero
    assert_value s1, 0x00000000

# -----------------------------------------------
# rd == rs1, rd == rs2 and rd == rs1 == rs2 all read the OLD operands.
test_aliasing:
    addi t2, zero, 8
    flush_pipeline
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    xperm4     t5, t5, t6
    assert_value t5, 0x40404400
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    xperm4     t6, t5, t6
    assert_value t6, 0x40404400
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    xperm4     t5, t5, t5
    assert_value t5, 0x04043210
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    xperm8     t5, t5, t6
    assert_value t5, 0x00003400
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    xperm8     t6, t5, t6
    assert_value t6, 0x00003400
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    xperm8     t5, t5, t5
    assert_value t5, 0x00000000

# -----------------------------------------------
# Forwarding INTO the new instruction: the operand produced 1, 2 and 3
# instructions earlier, into rs1 and into rs2, and both operands
# forwarded from different stages.
test_forward_into:
    addi t2, zero, 9
    flush_pipeline
    li32 t6, 0x01234567
    li32 t5, 0x8001F00F
    xperm4     s1, t5, t6
    assert_value s1, 0xF00F1008
    li32 t5, 0x8001F00F
    li32 t6, 0x01234567
    xperm4     s2, t5, t6
    assert_value s2, 0xF00F1008
    li32 t6, 0x01234567
    li32 t5, 0x8001F00F
    xperm8     s1, t5, t6
    assert_value s1, 0xF0000000
    li32 t5, 0x8001F00F
    li32 t6, 0x01234567
    xperm8     s2, t5, t6
    assert_value s2, 0xF0000000
    li32 t6, 0x01234567
    li32 t5, 0x8001F00F
    nop
    xperm4     s1, t5, t6
    assert_value s1, 0xF00F1008
    li32 t5, 0x8001F00F
    li32 t6, 0x01234567
    nop
    xperm4     s2, t5, t6
    assert_value s2, 0xF00F1008
    li32 t6, 0x01234567
    li32 t5, 0x8001F00F
    nop
    xperm8     s1, t5, t6
    assert_value s1, 0xF0000000
    li32 t5, 0x8001F00F
    li32 t6, 0x01234567
    nop
    xperm8     s2, t5, t6
    assert_value s2, 0xF0000000
    li32 t6, 0x01234567
    li32 t5, 0x8001F00F
    nop
    nop
    xperm4     s1, t5, t6
    assert_value s1, 0xF00F1008
    li32 t5, 0x8001F00F
    li32 t6, 0x01234567
    nop
    nop
    xperm4     s2, t5, t6
    assert_value s2, 0xF00F1008
    li32 t6, 0x01234567
    li32 t5, 0x8001F00F
    nop
    nop
    xperm8     s1, t5, t6
    assert_value s1, 0xF0000000
    li32 t5, 0x8001F00F
    li32 t6, 0x01234567
    nop
    nop
    xperm8     s2, t5, t6
    assert_value s2, 0xF0000000
    li32 t5, 0x8001F00F
    li32 t6, 0x01234567
    xperm4     s1, t5, t6
    li32 t6, 0x01234567
    li32 t5, 0x8001F00F
    xperm8     s2, t5, t6
    li32 t5, 0x8001F00F
    xperm4     s3, t5, t5
    assert_value s1, 0xF00F1008
    assert_value s2, 0xF0000000
    assert_value s3, 0x0FF00FF0

# -----------------------------------------------
# A load feeding the new instruction directly (load-use stall in front of it),
# into rs1, into rs2 and into both.
test_load_use:
    addi t2, zero, 10
    flush_pipeline
    li32 t6, 0x00000005
    lw   t5, 12(t4)
    xperm4     s1, t5, t6
    assert_value s1, 0x88888883
    li32 t5, 0x7FFFFFFF
    lw   t6, 4(t4)
    xperm8     s2, t5, t6
    assert_value s2, 0x00FFFFFF
    lw   t5, 8(t4)
    lw   t6, 12(t4)
    xperm4     s3, t5, t6
    assert_value s3, 0xF00FF000
    lw   t5, 12(t4)
    lw   t6, 0(t4)
    xperm8     s4, t6, t5
    assert_value s4, 0x00000000

# -----------------------------------------------
# Forwarding OUT of the new instruction, consumed by the very next
# instruction: an ALU op, a branch, a load address, store data, a
# JALR base and a CSR write.
test_forward_out_of:
    addi t2, zero, 11
    flush_pipeline
    li32 t5, 0x76543210
    li32 t6, 0x0000000F
    xperm4     s1, t5, t6
    addi s2, s1, 1
    assert_value s2, 0x00000001
    li32 s3, 0x00111144
    li32 t5, 0x44332211
    li32 t6, 0x80000003
    xperm8     s1, t5, t6
    bne  s1, s3, fwd_branch_bad_1
    beq  zero, zero, fwd_branch_ok_2
fwd_branch_bad_1:
    fail
fwd_branch_ok_2:
    addi t5, t4, 8
    li32 t6, 0x03020100           # identity indices: the table comes back unchanged
    xperm8     s1, t5, t6
    lw   s2, 0(s1)
    assert_value s2, 0x00FF00FF
    li32 t5, 0x11223344
    li32 t6, 0x00010203
    xperm8     s1, t5, t6
    sw   s1, 20(t4)              # scratch_var
    flush_pipeline
    lw   s2, 20(t4)
    assert_value s2, 0x44332211
    addi s4, zero, 0
    li32 t5, zbkx_jalr_target_3
    li32 t6, 0x76543210           # identity indices
    xperm4     s1, t5, t6
    jalr ra, 0(s1)
    fail                          # not reached
    beq  zero, zero, jalr_back_4
zbkx_jalr_target_3:
    addi s4, zero, 1
jalr_back_4:
    assert_value s4, 0x00000001
    li32 t5, 0xFEDCBA98
    li32 t6, 0x00100001
    xperm4     s1, t5, t6
    csrw mscratch, s1
    csrr s2, mscratch
    assert_value s2, 0x88988889

# -----------------------------------------------
# An instruction in the shadow of a taken branch must not execute, and
# the new instruction works as a branch target.
test_branch_shadow:
    addi t2, zero, 12
    flush_pipeline
    li32 s1, 0x0000ABCD
    li32 t5, 0x00F00000
    li32 t6, 0x0F1E2D3C
    beq  zero, zero, shadow_target_5
    xperm4     s1, t5, t6
    xperm8     s1, t5, t6
    fail
shadow_target_5:
    xperm4     s2, t5, t6
    assert_value s1, 0x0000ABCD
    assert_value s2, 0x00000000

# -----------------------------------------------
# Before and after fence.i, which refetches everything behind it.
test_fence_i:
    addi t2, zero, 13
    flush_pipeline
    li32 t5, 0x0F0F1234
    li32 t6, 0x76543210
    xperm4     s1, t5, t6
    fence.i
    xperm8     s2, s1, t6
    assert_value s1, 0x0F0F1234
    assert_value s2, 0x00000000

# -----------------------------------------------
# minstret rises by exactly N over N of the new instructions: the
# difference between a window with them and an empty window.
test_minstret:
    addi t2, zero, 14
    flush_pipeline
    li32 a0, 0x13579BDF
    li32 a1, 0x0731B562
    flush_pipeline
    csrr s5, minstret
    csrr s6, minstret
    sub  s8, s6, s5
    flush_pipeline
    csrr s5, minstret
    xperm4     a0, a1, a0
    xperm8     a0, a0, a1
    xperm8     a0, a1, a0
    xperm4     a0, a0, a1
    xperm4     a0, a1, a0
    xperm4     a0, a0, a1
    xperm8     a0, a1, a0
    xperm8     a0, a0, a1
    xperm4     a0, a1, a0
    xperm4     a0, a0, a1
    xperm8     a0, a1, a0
    xperm4     a0, a0, a1
    xperm4     a0, a1, a0
    xperm8     a0, a0, a1
    xperm8     a0, a1, a0
    xperm4     a0, a0, a1
    csrr s6, minstret
    sub  s9, s6, s5
    sub  s9, s9, s8
    assert_value s9, 0x00000010
    assert_value a0, 0x26660622

# -----------------------------------------------
# A chain of 16 back-to-back DEPENDENT instructions takes exactly as many
# cycles as the same chain of add instructions: the result is forwarded
# in its own cycle and nothing stalls (mcycle, read at the same points).
test_cycle_exact:
    addi t2, zero, 15
    flush_pipeline
    li32 a0, 0x13579BDF
    li32 a1, 0x0731B562
    flush_pipeline
    csrr s5, mcycle
    xperm4     a0, a1, a0
    xperm8     a0, a0, a1
    xperm8     a0, a1, a0
    xperm4     a0, a0, a1
    xperm4     a0, a1, a0
    xperm4     a0, a0, a1
    xperm8     a0, a1, a0
    xperm8     a0, a0, a1
    xperm4     a0, a1, a0
    xperm4     a0, a0, a1
    xperm8     a0, a1, a0
    xperm4     a0, a0, a1
    xperm4     a0, a1, a0
    xperm8     a0, a0, a1
    xperm8     a0, a1, a0
    xperm4     a0, a0, a1
    csrr s6, mcycle
    sub  s8, s6, s5
    mv   s4, a0
    li32 a0, 0x13579BDF
    li32 a1, 0x0731B562
    flush_pipeline
    csrr s5, mcycle
    add        a0, a1, a0
    add        a0, a0, a1
    add        a0, a1, a0
    add        a0, a0, a1
    add        a0, a1, a0
    add        a0, a0, a1
    add        a0, a1, a0
    add        a0, a0, a1
    add        a0, a1, a0
    add        a0, a0, a1
    add        a0, a1, a0
    add        a0, a0, a1
    add        a0, a1, a0
    add        a0, a0, a1
    add        a0, a1, a0
    add        a0, a0, a1
    csrr s6, mcycle
    sub  s9, s6, s5
    assert_equal s8, s9
    assert_value s4, 0x26660622
    addi s9, s8, -17
    assert_value s9, 0x00000000

# -----------------------------------------------
# An external interrupt landing at 8 positions of a chain of the
# new instructions: the chain's result and the count are unchanged.
test_interrupt_in_chain:
    addi t2, zero, 16
    flush_pipeline
    li32 t6, ext_irq_handler
    csrw mtvec, t6
    slli t6, t1, 11
    csrs mie, t6
    slli t6, t1, 3
    csrs mstatus, t6
    addi s7, zero, 0
    li32 a0, 0x13579BDF
    li32 a1, 0x0731B562
    flush_pipeline
    interrupt 1
    xperm4     a0, a1, a0
    xperm8     a0, a0, a1
    xperm8     a0, a1, a0
    xperm4     a0, a0, a1
    xperm4     a0, a1, a0
    xperm4     a0, a0, a1
    xperm8     a0, a1, a0
    xperm8     a0, a0, a1
    xperm4     a0, a1, a0
    xperm4     a0, a0, a1
    xperm8     a0, a1, a0
    xperm4     a0, a0, a1
    xperm4     a0, a1, a0
    xperm8     a0, a0, a1
    xperm8     a0, a1, a0
    xperm4     a0, a0, a1
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x26660622
    li32 a0, 0x13579BDF
    li32 a1, 0x0731B562
    flush_pipeline
    interrupt 2
    xperm4     a0, a1, a0
    xperm8     a0, a0, a1
    xperm8     a0, a1, a0
    xperm4     a0, a0, a1
    xperm4     a0, a1, a0
    xperm4     a0, a0, a1
    xperm8     a0, a1, a0
    xperm8     a0, a0, a1
    xperm4     a0, a1, a0
    xperm4     a0, a0, a1
    xperm8     a0, a1, a0
    xperm4     a0, a0, a1
    xperm4     a0, a1, a0
    xperm8     a0, a0, a1
    xperm8     a0, a1, a0
    xperm4     a0, a0, a1
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x26660622
    li32 a0, 0x13579BDF
    li32 a1, 0x0731B562
    flush_pipeline
    interrupt 3
    xperm4     a0, a1, a0
    xperm8     a0, a0, a1
    xperm8     a0, a1, a0
    xperm4     a0, a0, a1
    xperm4     a0, a1, a0
    xperm4     a0, a0, a1
    xperm8     a0, a1, a0
    xperm8     a0, a0, a1
    xperm4     a0, a1, a0
    xperm4     a0, a0, a1
    xperm8     a0, a1, a0
    xperm4     a0, a0, a1
    xperm4     a0, a1, a0
    xperm8     a0, a0, a1
    xperm8     a0, a1, a0
    xperm4     a0, a0, a1
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x26660622
    li32 a0, 0x13579BDF
    li32 a1, 0x0731B562
    flush_pipeline
    interrupt 4
    xperm4     a0, a1, a0
    xperm8     a0, a0, a1
    xperm8     a0, a1, a0
    xperm4     a0, a0, a1
    xperm4     a0, a1, a0
    xperm4     a0, a0, a1
    xperm8     a0, a1, a0
    xperm8     a0, a0, a1
    xperm4     a0, a1, a0
    xperm4     a0, a0, a1
    xperm8     a0, a1, a0
    xperm4     a0, a0, a1
    xperm4     a0, a1, a0
    xperm8     a0, a0, a1
    xperm8     a0, a1, a0
    xperm4     a0, a0, a1
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x26660622
    li32 a0, 0x13579BDF
    li32 a1, 0x0731B562
    flush_pipeline
    interrupt 5
    xperm4     a0, a1, a0
    xperm8     a0, a0, a1
    xperm8     a0, a1, a0
    xperm4     a0, a0, a1
    xperm4     a0, a1, a0
    xperm4     a0, a0, a1
    xperm8     a0, a1, a0
    xperm8     a0, a0, a1
    xperm4     a0, a1, a0
    xperm4     a0, a0, a1
    xperm8     a0, a1, a0
    xperm4     a0, a0, a1
    xperm4     a0, a1, a0
    xperm8     a0, a0, a1
    xperm8     a0, a1, a0
    xperm4     a0, a0, a1
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x26660622
    li32 a0, 0x13579BDF
    li32 a1, 0x0731B562
    flush_pipeline
    interrupt 6
    xperm4     a0, a1, a0
    xperm8     a0, a0, a1
    xperm8     a0, a1, a0
    xperm4     a0, a0, a1
    xperm4     a0, a1, a0
    xperm4     a0, a0, a1
    xperm8     a0, a1, a0
    xperm8     a0, a0, a1
    xperm4     a0, a1, a0
    xperm4     a0, a0, a1
    xperm8     a0, a1, a0
    xperm4     a0, a0, a1
    xperm4     a0, a1, a0
    xperm8     a0, a0, a1
    xperm8     a0, a1, a0
    xperm4     a0, a0, a1
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x26660622
    li32 a0, 0x13579BDF
    li32 a1, 0x0731B562
    flush_pipeline
    interrupt 7
    xperm4     a0, a1, a0
    xperm8     a0, a0, a1
    xperm8     a0, a1, a0
    xperm4     a0, a0, a1
    xperm4     a0, a1, a0
    xperm4     a0, a0, a1
    xperm8     a0, a1, a0
    xperm8     a0, a0, a1
    xperm4     a0, a1, a0
    xperm4     a0, a0, a1
    xperm8     a0, a1, a0
    xperm4     a0, a0, a1
    xperm4     a0, a1, a0
    xperm8     a0, a0, a1
    xperm8     a0, a1, a0
    xperm4     a0, a0, a1
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x26660622
    li32 a0, 0x13579BDF
    li32 a1, 0x0731B562
    flush_pipeline
    interrupt 8
    xperm4     a0, a1, a0
    xperm8     a0, a0, a1
    xperm8     a0, a1, a0
    xperm4     a0, a0, a1
    xperm4     a0, a1, a0
    xperm4     a0, a0, a1
    xperm8     a0, a1, a0
    xperm8     a0, a0, a1
    xperm4     a0, a1, a0
    xperm4     a0, a0, a1
    xperm8     a0, a1, a0
    xperm4     a0, a0, a1
    xperm4     a0, a1, a0
    xperm8     a0, a0, a1
    xperm8     a0, a1, a0
    xperm4     a0, a0, a1
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x26660622
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
# (reserved on RV32, RV64-only forms, other extensions, wrong
# funct3/funct7/rs2 field) must still raise illegal-instruction,
# mcause = 2.
test_illegal_neighbours:
    addi t2, zero, 17
    flush_pipeline
    li32 t5, record_trap
    csrw mtvec, t5
    flush_pipeline
    expect_trap 0x28C58533, 2       # funct7 0010100, funct3 000
    expect_trap 0x28C5B533, 2       # funct7 0010100, funct3 011
    expect_trap 0x28C5D533, 2       # funct7 0010100, funct3 101
    expect_trap 0x28C5E533, 2       # funct7 0010100, funct3 110
    expect_trap 0x28C5F533, 2       # funct7 0010100, funct3 111
    li32 t5, unexpected_trap
    csrw mtvec, t5
    flush_pipeline

# ------------------------------------------------------------------------------------------------
# |                                          Test done!                                          |
# ------------------------------------------------------------------------------------------------
test_finish:
    addi t2, zero, 18
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
