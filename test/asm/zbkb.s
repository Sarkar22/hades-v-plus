# Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
# Embedded Architectures & Systems Group, Graz University of Technology
# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: zbkb.s
#
# ------------------------------------------------------------------------------------------------
# |                                                                                              |
# | Zbkb extension test (bit manipulation for cryptography, 12 instructions on RV32).            |
# | The five forms Zbb does not have: pack packh brev8 zip unzip; and the seven it shares        |
# | with Zbb (rol ror rori andn orn xnor rev8), assembled here with Zbkb alone.                  |
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
# |    pack takes the LOW halves, rs1 low and rs2 high; packh the low bytes; brev8               |
# |    reverses bits inside each byte (not bytes); zip sends the low half to the EVEN            |
# |    bits; unzip inverts zip; brev8 twice and zip/unzip in either order give the input.        |
# | 2. pack rd, rs1, x0 is zext.h (the same word); pack with an rs2 register holding 0           |
# |    gives the same value; the brev8 shape under funct3 001 is binvi, still legal.             |
# | 3. rd = x0 discarded (also for the instruction right behind it), x0 as a source,             |
# |    rd == rs1 / rs2 / both.                                                                   |
# | 4. Forwarding into rs1 and rs2 at distance 1, 2, 3, from two stages at once; a               |
# |    load-use stall in front; forwarding out into an ALU op, a branch, a load address,         |
# |    store data, a JALR base and a CSR write.                                                  |
# | 5. Not executed in the shadow of a taken branch; correct as a branch target; around          |
# |    fence.i; an interrupt at 8 positions of a chain changes nothing.                          |
# | 6. minstret counts each instruction once; a dependent chain takes exactly as many            |
# |    cycles as the same chain of add (no stall, forwarded in its own cycle).                   |
# | 7. The illegal neighbours (unused funct3 and rs2 fields, RV32-reserved shamt[5],             |
# |    Zbkc and RV64 encodings) raise illegal-instruction.                                       |
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

.option arch, +zbkb

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
    li32 t5, 0x12345678
    li32 t6, 0x9ABCDEF0
    pack       s1, t5, t6
    assert_value s1, 0xDEF05678
    li32 t5, 0x12345678
    li32 t6, 0x9ABCDEF0
    packh      s1, t5, t6
    assert_value s1, 0x0000F078
    li32 t5, 0x12345678
    pack       s1, t5, zero        # pack rd, rs1, x0 = zext.h
    assert_value s1, 0x00005678
    li32 t5, 0x12345678
    brev8      s1, t5
    assert_value s1, 0x482C6A1E
    li32 t5, 0x01020304
    brev8      s1, t5
    assert_value s1, 0x8040C020
    li32 t5, 0x0000FFFF
    zip        s1, t5
    assert_value s1, 0x55555555
    li32 t5, 0xFFFF0000
    zip        s1, t5
    assert_value s1, 0xAAAAAAAA
    li32 t5, 0x12345678
    zip        s1, t5
    assert_value s1, 0x131C1F60
    li32 t5, 0x12345678
    unzip      s1, t5
    assert_value s1, 0x141646EC
    li32 t5, 0x55555555
    unzip      s1, t5
    assert_value s1, 0x0000FFFF

# -----------------------------------------------
# pack {rs2[15:0], rs1[15:0]} and packh {16'b0, rs2[7:0], rs1[7:0]}:
# rs1 supplies the LOW part, rs2 the high part; the upper halves
# (upper three bytes for packh) of both operands are ignored.
test_pack:
    addi t2, zero, 3
    flush_pipeline
    li32 t5, 0x00000000
    li32 t6, 0x00000000
    pack       s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000001
    li32 t6, 0x00000001
    pack       s1, t5, t6
    assert_value s1, 0x00010001
    li32 t5, 0xFFFFFFFF
    li32 t6, 0xFFFFFFFF
    pack       s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x80000000
    li32 t6, 0x7FFFFFFF
    pack       s1, t5, t6
    assert_value s1, 0xFFFF0000
    li32 t5, 0x7FFFFFFF
    li32 t6, 0x80000000
    pack       s1, t5, t6
    assert_value s1, 0x0000FFFF
    li32 t5, 0x12345678
    li32 t6, 0x9ABCDEF0
    pack       s1, t5, t6
    assert_value s1, 0xDEF05678
    li32 t5, 0x9ABCDEF0
    li32 t6, 0x12345678
    pack       s1, t5, t6
    assert_value s1, 0x5678DEF0
    li32 t5, 0x0000FFFF
    li32 t6, 0xFFFF0000
    pack       s1, t5, t6
    assert_value s1, 0x0000FFFF
    li32 t5, 0xFFFF0000
    li32 t6, 0x0000FFFF
    pack       s1, t5, t6
    assert_value s1, 0xFFFF0000
    li32 t5, 0x000000FF
    li32 t6, 0x0000FF00
    pack       s1, t5, t6
    assert_value s1, 0xFF0000FF
    li32 t5, 0x00008000
    li32 t6, 0x00000080
    pack       s1, t5, t6
    assert_value s1, 0x00808000
    li32 t5, 0x00000001
    li32 t6, 0x80000000
    pack       s1, t5, t6
    assert_value s1, 0x00000001
    li32 t5, 0x80000000
    li32 t6, 0x00000001
    pack       s1, t5, t6
    assert_value s1, 0x00010000
    li32 t5, 0x55555555
    li32 t6, 0xAAAAAAAA
    pack       s1, t5, t6
    assert_value s1, 0xAAAA5555
    li32 t5, 0x00000000
    li32 t6, 0x00000000
    packh      s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000001
    li32 t6, 0x00000001
    packh      s1, t5, t6
    assert_value s1, 0x00000101
    li32 t5, 0xFFFFFFFF
    li32 t6, 0xFFFFFFFF
    packh      s1, t5, t6
    assert_value s1, 0x0000FFFF
    li32 t5, 0x80000000
    li32 t6, 0x7FFFFFFF
    packh      s1, t5, t6
    assert_value s1, 0x0000FF00
    li32 t5, 0x7FFFFFFF
    li32 t6, 0x80000000
    packh      s1, t5, t6
    assert_value s1, 0x000000FF
    li32 t5, 0x12345678
    li32 t6, 0x9ABCDEF0
    packh      s1, t5, t6
    assert_value s1, 0x0000F078
    li32 t5, 0x9ABCDEF0
    li32 t6, 0x12345678
    packh      s1, t5, t6
    assert_value s1, 0x000078F0
    li32 t5, 0x0000FFFF
    li32 t6, 0xFFFF0000
    packh      s1, t5, t6
    assert_value s1, 0x000000FF
    li32 t5, 0xFFFF0000
    li32 t6, 0x0000FFFF
    packh      s1, t5, t6
    assert_value s1, 0x0000FF00
    li32 t5, 0x000000FF
    li32 t6, 0x0000FF00
    packh      s1, t5, t6
    assert_value s1, 0x000000FF
    li32 t5, 0x00008000
    li32 t6, 0x00000080
    packh      s1, t5, t6
    assert_value s1, 0x00008000
    li32 t5, 0x00000001
    li32 t6, 0x80000000
    packh      s1, t5, t6
    assert_value s1, 0x00000001
    li32 t5, 0x80000000
    li32 t6, 0x00000001
    packh      s1, t5, t6
    assert_value s1, 0x00000100
    li32 t5, 0x55555555
    li32 t6, 0xAAAAAAAA
    packh      s1, t5, t6
    assert_value s1, 0x0000AA55

# -----------------------------------------------
# brev8: the bit order reversed inside each byte; the bytes stay in place
# (rev8 reverses bytes, not bits).
test_brev8:
    addi t2, zero, 4
    flush_pipeline
    li32 t5, 0x00000000
    brev8      s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0x00000001
    brev8      s1, t5
    assert_value s1, 0x00000080
    li32 t5, 0xFFFFFFFF
    brev8      s1, t5
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x80000000
    brev8      s1, t5
    assert_value s1, 0x01000000
    li32 t5, 0x7FFFFFFF
    brev8      s1, t5
    assert_value s1, 0xFEFFFFFF
    li32 t5, 0x000000FF
    brev8      s1, t5
    assert_value s1, 0x000000FF
    li32 t5, 0x0000FF00
    brev8      s1, t5
    assert_value s1, 0x0000FF00
    li32 t5, 0x00FF0000
    brev8      s1, t5
    assert_value s1, 0x00FF0000
    li32 t5, 0xFF000000
    brev8      s1, t5
    assert_value s1, 0xFF000000
    li32 t5, 0x0000FFFF
    brev8      s1, t5
    assert_value s1, 0x0000FFFF
    li32 t5, 0xFFFF0000
    brev8      s1, t5
    assert_value s1, 0xFFFF0000
    li32 t5, 0x0F0F0F0F
    brev8      s1, t5
    assert_value s1, 0xF0F0F0F0
    li32 t5, 0xF0F0F0F0
    brev8      s1, t5
    assert_value s1, 0x0F0F0F0F
    li32 t5, 0x55555555
    brev8      s1, t5
    assert_value s1, 0xAAAAAAAA
    li32 t5, 0xAAAAAAAA
    brev8      s1, t5
    assert_value s1, 0x55555555
    li32 t5, 0x00000080
    brev8      s1, t5
    assert_value s1, 0x00000001
    li32 t5, 0x00008000
    brev8      s1, t5
    assert_value s1, 0x00000100
    li32 t5, 0x00010000
    brev8      s1, t5
    assert_value s1, 0x00800000
    li32 t5, 0x12345678
    brev8      s1, t5
    assert_value s1, 0x482C6A1E
    li32 t5, 0x9ABCDEF0
    brev8      s1, t5
    assert_value s1, 0x593D7B0F
    li32 t5, 0x01020304
    brev8      s1, t5
    assert_value s1, 0x8040C020
    li32 t5, 0x80402010
    brev8      s1, t5
    assert_value s1, 0x01020408
    li32 t5, 0x0F00F00F
    brev8      s1, t5
    assert_value s1, 0xF0000FF0

# -----------------------------------------------
# zip: low half to the even bits, high half to the odd bits; unzip: the
# even bits to the low half, the odd bits to the high half.
test_zip_unzip:
    addi t2, zero, 5
    flush_pipeline
    li32 t5, 0x00000000
    zip        s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0x00000001
    zip        s1, t5
    assert_value s1, 0x00000001
    li32 t5, 0xFFFFFFFF
    zip        s1, t5
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x80000000
    zip        s1, t5
    assert_value s1, 0x80000000
    li32 t5, 0x7FFFFFFF
    zip        s1, t5
    assert_value s1, 0x7FFFFFFF
    li32 t5, 0x000000FF
    zip        s1, t5
    assert_value s1, 0x00005555
    li32 t5, 0x0000FF00
    zip        s1, t5
    assert_value s1, 0x55550000
    li32 t5, 0x00FF0000
    zip        s1, t5
    assert_value s1, 0x0000AAAA
    li32 t5, 0xFF000000
    zip        s1, t5
    assert_value s1, 0xAAAA0000
    li32 t5, 0x0000FFFF
    zip        s1, t5
    assert_value s1, 0x55555555
    li32 t5, 0xFFFF0000
    zip        s1, t5
    assert_value s1, 0xAAAAAAAA
    li32 t5, 0x0F0F0F0F
    zip        s1, t5
    assert_value s1, 0x00FF00FF
    li32 t5, 0xF0F0F0F0
    zip        s1, t5
    assert_value s1, 0xFF00FF00
    li32 t5, 0x55555555
    zip        s1, t5
    assert_value s1, 0x33333333
    li32 t5, 0xAAAAAAAA
    zip        s1, t5
    assert_value s1, 0xCCCCCCCC
    li32 t5, 0x00000080
    zip        s1, t5
    assert_value s1, 0x00004000
    li32 t5, 0x00008000
    zip        s1, t5
    assert_value s1, 0x40000000
    li32 t5, 0x00010000
    zip        s1, t5
    assert_value s1, 0x00000002
    li32 t5, 0x12345678
    zip        s1, t5
    assert_value s1, 0x131C1F60
    li32 t5, 0x9ABCDEF0
    zip        s1, t5
    assert_value s1, 0xD3DCDFA0
    li32 t5, 0x00000002
    zip        s1, t5
    assert_value s1, 0x00000004
    li32 t5, 0x00020000
    zip        s1, t5
    assert_value s1, 0x00000008
    li32 t5, 0x40000000
    zip        s1, t5
    assert_value s1, 0x20000000
    li32 t5, 0x00000000
    unzip      s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0x00000001
    unzip      s1, t5
    assert_value s1, 0x00000001
    li32 t5, 0xFFFFFFFF
    unzip      s1, t5
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x80000000
    unzip      s1, t5
    assert_value s1, 0x80000000
    li32 t5, 0x7FFFFFFF
    unzip      s1, t5
    assert_value s1, 0x7FFFFFFF
    li32 t5, 0x000000FF
    unzip      s1, t5
    assert_value s1, 0x000F000F
    li32 t5, 0x0000FF00
    unzip      s1, t5
    assert_value s1, 0x00F000F0
    li32 t5, 0x00FF0000
    unzip      s1, t5
    assert_value s1, 0x0F000F00
    li32 t5, 0xFF000000
    unzip      s1, t5
    assert_value s1, 0xF000F000
    li32 t5, 0x0000FFFF
    unzip      s1, t5
    assert_value s1, 0x00FF00FF
    li32 t5, 0xFFFF0000
    unzip      s1, t5
    assert_value s1, 0xFF00FF00
    li32 t5, 0x0F0F0F0F
    unzip      s1, t5
    assert_value s1, 0x33333333
    li32 t5, 0xF0F0F0F0
    unzip      s1, t5
    assert_value s1, 0xCCCCCCCC
    li32 t5, 0x55555555
    unzip      s1, t5
    assert_value s1, 0x0000FFFF
    li32 t5, 0xAAAAAAAA
    unzip      s1, t5
    assert_value s1, 0xFFFF0000
    li32 t5, 0x00000080
    unzip      s1, t5
    assert_value s1, 0x00080000
    li32 t5, 0x00008000
    unzip      s1, t5
    assert_value s1, 0x00800000
    li32 t5, 0x00010000
    unzip      s1, t5
    assert_value s1, 0x00000100
    li32 t5, 0x12345678
    unzip      s1, t5
    assert_value s1, 0x141646EC
    li32 t5, 0x9ABCDEF0
    unzip      s1, t5
    assert_value s1, 0xBEBC46EC
    li32 t5, 0x00000002
    unzip      s1, t5
    assert_value s1, 0x00010000
    li32 t5, 0x00020000
    unzip      s1, t5
    assert_value s1, 0x01000000
    li32 t5, 0x40000000
    unzip      s1, t5
    assert_value s1, 0x00008000

# -----------------------------------------------
# unzip(zip(x)) = zip(unzip(x)) = x and brev8(brev8(x)) = x, back to back
# (the second instruction reads the first one's result forwarded).
test_inverses:
    addi t2, zero, 6
    flush_pipeline
    li32 t5, 0x12345678
    zip        s1, t5
    unzip      s1, s1
    assert_value s1, 0x12345678
    unzip      s2, t5
    zip        s2, s2
    assert_value s2, 0x12345678
    brev8      s3, t5
    brev8      s3, s3
    assert_value s3, 0x12345678
    li32 t5, 0x9ABCDEF0
    zip        s1, t5
    unzip      s1, s1
    assert_value s1, 0x9ABCDEF0
    unzip      s2, t5
    zip        s2, s2
    assert_value s2, 0x9ABCDEF0
    brev8      s3, t5
    brev8      s3, s3
    assert_value s3, 0x9ABCDEF0
    li32 t5, 0xDEADBEEF
    zip        s1, t5
    unzip      s1, s1
    assert_value s1, 0xDEADBEEF
    unzip      s2, t5
    zip        s2, s2
    assert_value s2, 0xDEADBEEF
    brev8      s3, t5
    brev8      s3, s3
    assert_value s3, 0xDEADBEEF
    li32 t5, 0x00000001
    zip        s1, t5
    unzip      s1, s1
    assert_value s1, 0x00000001
    unzip      s2, t5
    zip        s2, s2
    assert_value s2, 0x00000001
    brev8      s3, t5
    brev8      s3, s3
    assert_value s3, 0x00000001
    li32 t5, 0x80000000
    zip        s1, t5
    unzip      s1, s1
    assert_value s1, 0x80000000
    unzip      s2, t5
    zip        s2, s2
    assert_value s2, 0x80000000
    brev8      s3, t5
    brev8      s3, s3
    assert_value s3, 0x80000000

# -----------------------------------------------
# The RV32 zext.h word 0x0805C533 is pack a0, a1, x0; with rs2 a
# register that holds 0 pack gives the same value. 0x68759513, the
# brev8 shape under funct3 001, is binvi a0, a1, 7 and stays legal.
test_zext_h_word:
    addi t2, zero, 7
    flush_pipeline
    li32 a1, 0xFEDC8001
    li32 a0, 0x00000000
    .word 0x0805C533              # zext.h a0, a1 (= pack a0, a1, x0)
    assert_value a0, 0x00008001
    li32 a2, 0x00000000
    pack       s1, a1, a2
    assert_value s1, 0x00008001
    li32 a0, 0x00000000
    .word 0x68759513              # binvi a0, a1, 7
    assert_value a0, 0xFEDC8081

# -----------------------------------------------
# The seven Zbkb instructions that Zbb also has, assembled with Zbkb
# alone (one known answer each; zbb.s tests them in depth).
test_shared_with_zbb:
    addi t2, zero, 8
    flush_pipeline
    li32 t5, 0x80000001
    li32 t6, 0x00000001
    rol        s1, t5, t6
    assert_value s1, 0x00000003
    li32 t5, 0x00000003
    li32 t6, 0x00000001
    ror        s1, t5, t6
    assert_value s1, 0x80000001
    li32 t5, 0xF0F01234
    rori       s1, t5, 7
    assert_value s1, 0x69E1E024
    li32 t5, 0x12345678
    li32 t6, 0x0000F00F
    andn       s1, t5, t6
    assert_value s1, 0x12340670
    li32 t5, 0x12345678
    li32 t6, 0x0000F00F
    orn        s1, t5, t6
    assert_value s1, 0xFFFF5FF8
    li32 t5, 0x0F0F1234
    li32 t6, 0xFF00FF00
    xnor       s1, t5, t6
    assert_value s1, 0x0FF012CB
    li32 t5, 0x12345678
    rev8       s1, t5
    assert_value s1, 0x78563412

# -----------------------------------------------
# rd = x0 discards the result, also for the instruction right behind it,
# which must read 0 rather than a forwarded value.
test_rd_is_x0:
    addi t2, zero, 9
    flush_pipeline
    li32 t5, 0x12345678
    li32 t6, 0x9ABCDEF0
    pack       zero, t5, t6
    add  s1, zero, zero           # reads x0 right behind the discarded result
    pack       zero, t5, t6
    add  s2, t5, zero
    assert_value s1, 0x00000000
    assert_value s2, 0x12345678
    zip        zero, t5
    zip        s3, zero
    assert_value s3, 0x00000000

# -----------------------------------------------
# x0 as a source operand.
test_x0_source:
    addi t2, zero, 10
    flush_pipeline
    li32 t5, 0x89ABCDEF
    li32 t6, 0x13579BDF
    pack       s1, zero, t6
    assert_value s1, 0x9BDF0000
    pack       s1, t5, zero
    assert_value s1, 0x0000CDEF
    pack       s1, zero, zero
    assert_value s1, 0x00000000
    packh      s1, zero, t6
    assert_value s1, 0x0000DF00
    packh      s1, t5, zero
    assert_value s1, 0x000000EF
    packh      s1, zero, zero
    assert_value s1, 0x00000000
    brev8      s1, zero
    assert_value s1, 0x00000000
    zip        s1, zero
    assert_value s1, 0x00000000
    unzip      s1, zero
    assert_value s1, 0x00000000

# -----------------------------------------------
# rd == rs1, rd == rs2 and rd == rs1 == rs2 all read the OLD operands.
test_aliasing:
    addi t2, zero, 11
    flush_pipeline
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    pack       t5, t5, t6
    assert_value t5, 0x00FF1234
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    pack       t6, t5, t6
    assert_value t6, 0x00FF1234
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    pack       t5, t5, t5
    assert_value t5, 0x12341234
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    packh      t5, t5, t6
    assert_value t5, 0x0000FF34
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    packh      t6, t5, t6
    assert_value t6, 0x0000FF34
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    packh      t5, t5, t5
    assert_value t5, 0x00003434
    li32 t5, 0xF0F01234
    brev8      t5, t5
    assert_value t5, 0x0F0F482C
    li32 t5, 0xF0F01234
    zip        t5, t5
    assert_value t5, 0xAB04AF10
    li32 t5, 0xF0F01234
    unzip      t5, t5
    assert_value t5, 0xCC14CC46

# -----------------------------------------------
# Forwarding INTO the new instruction: the operand produced 1, 2 and 3
# instructions earlier, into rs1 and into rs2, and both operands
# forwarded from different stages.
test_forward_into:
    addi t2, zero, 12
    flush_pipeline
    li32 t6, 0x00137F13
    li32 t5, 0x8001F00F
    pack       s1, t5, t6
    assert_value s1, 0x7F13F00F
    li32 t5, 0x8001F00F
    li32 t6, 0x00137F13
    pack       s2, t5, t6
    assert_value s2, 0x7F13F00F
    li32 t5, 0x8100F00F
    zip        s3, t5
    assert_value s3, 0xD5020055
    li32 t6, 0x00137F13
    li32 t5, 0x8001F00F
    nop
    pack       s1, t5, t6
    assert_value s1, 0x7F13F00F
    li32 t5, 0x8001F00F
    li32 t6, 0x00137F13
    nop
    pack       s2, t5, t6
    assert_value s2, 0x7F13F00F
    li32 t5, 0x8203F00F
    nop
    zip        s3, t5
    assert_value s3, 0xD508005F
    li32 t6, 0x00137F13
    li32 t5, 0x8001F00F
    nop
    nop
    pack       s1, t5, t6
    assert_value s1, 0x7F13F00F
    li32 t5, 0x8001F00F
    li32 t6, 0x00137F13
    nop
    nop
    pack       s2, t5, t6
    assert_value s2, 0x7F13F00F
    li32 t5, 0x8302F00F
    nop
    nop
    zip        s3, t5
    assert_value s3, 0xD50A005D
    li32 t5, 0x8001F00F
    li32 t6, 0x00137F13
    pack       s1, t5, t6
    li32 t6, 0x00137F13
    li32 t5, 0x8001F00F
    pack       s2, t5, t6
    li32 t5, 0x8001F00F
    pack       s3, t5, t5
    assert_value s1, 0x7F13F00F
    assert_value s2, 0x7F13F00F
    assert_value s3, 0xF00FF00F

# -----------------------------------------------
# A load feeding the new instruction directly (load-use stall in front of it),
# into rs1, into rs2 and into both.
test_load_use:
    addi t2, zero, 13
    flush_pipeline
    li32 t6, 0x00000005
    lw   t5, 12(t4)
    packh      s1, t5, t6
    assert_value s1, 0x00000578
    li32 t5, 0x7FFFFFFF
    lw   t6, 4(t4)
    packh      s2, t5, t6
    assert_value s2, 0x000000FF
    lw   t5, 8(t4)
    lw   t6, 12(t4)
    packh      s3, t5, t6
    assert_value s3, 0x000078FF
    lw   t5, 8(t4)
    unzip      s4, t5
    assert_value s4, 0x0F0F0F0F

# -----------------------------------------------
# Forwarding OUT of the new instruction, consumed by the very next
# instruction: an ALU op, a branch, a load address, store data, a
# JALR base and a CSR write.
test_forward_out_of:
    addi t2, zero, 14
    flush_pipeline
    li32 t5, 0xF0F0F0F0
    li32 t6, 0x00000001
    packh      s1, t5, t6
    addi s2, s1, 1
    assert_value s2, 0x000001F1
    li32 s3, 0x00800000
    li32 t5, 0x00010000
    brev8      s1, t5
    bne  s1, s3, fwd_branch_bad_1
    beq  zero, zero, fwd_branch_ok_2
fwd_branch_bad_1:
    fail
fwd_branch_ok_2:
    addi t5, t4, 8
    srli t6, t5, 16
    pack       s1, t5, t6
    lw   s2, 0(s1)
    assert_value s2, 0x00FF00FF
    li32 t5, 0x11223344
    zip        s1, t5
    sw   s1, 20(t4)              # scratch_var
    flush_pipeline
    lw   s2, 20(t4)
    assert_value s2, 0x07071818
    addi s4, zero, 0
    li32 t5, zbkb_jalr_target_3
    srli t6, t5, 16
    pack       s1, t5, t6
    jalr ra, 0(s1)
    fail                          # not reached
    beq  zero, zero, jalr_back_4
zbkb_jalr_target_3:
    addi s4, zero, 1
jalr_back_4:
    assert_value s4, 0x00000001
    li32 t5, 0x00100001
    unzip      s1, t5
    csrw mscratch, s1
    csrr s2, mscratch
    assert_value s2, 0x00000401

# -----------------------------------------------
# An instruction in the shadow of a taken branch must not execute, and
# the new instruction works as a branch target.
test_branch_shadow:
    addi t2, zero, 15
    flush_pipeline
    li32 s1, 0x0000ABCD
    li32 t5, 0x00F00000
    li32 t6, 0x0F1E2D3C
    beq  zero, zero, shadow_target_5
    brev8      s1, t5
    pack       s1, t5, t6
    fail
shadow_target_5:
    pack       s2, t5, t6
    assert_value s1, 0x0000ABCD
    assert_value s2, 0x2D3C0000

# -----------------------------------------------
# Before and after fence.i, which refetches everything behind it.
test_fence_i:
    addi t2, zero, 16
    flush_pipeline
    li32 t5, 0x0F0F1234
    li32 t6, 0xFF00FF00
    packh      s1, t5, t6
    fence.i
    zip        s2, s1
    assert_value s1, 0x00000034
    assert_value s2, 0x00000510

# -----------------------------------------------
# minstret rises by exactly N over N of the new instructions: the
# difference between a window with them and an empty window.
test_minstret:
    addi t2, zero, 17
    flush_pipeline
    li32 a0, 0x13579BDF
    li32 a1, 0x2468ACE1
    flush_pipeline
    csrr s5, minstret
    csrr s6, minstret
    sub  s8, s6, s5
    flush_pipeline
    csrr s5, minstret
    zip        a0, a0
    pack       a0, a0, a1
    brev8      a0, a0
    packh      a0, a1, a0
    unzip      a0, a0
    pack       a0, a1, a0
    zip        a0, a0
    brev8      a0, a0
    packh      a0, a0, a1
    zip        a0, a0
    pack       a0, a0, a1
    unzip      a0, a0
    brev8      a0, a0
    pack       a0, a1, a0
    zip        a0, a0
    unzip      a0, a0
    csrr s6, minstret
    sub  s9, s6, s5
    sub  s9, s9, s8
    assert_value s9, 0x00000010
    assert_value a0, 0x9483ACE1

# -----------------------------------------------
# A chain of 16 back-to-back DEPENDENT instructions takes exactly as many
# cycles as the same chain of add instructions: the result is forwarded
# in its own cycle and nothing stalls (mcycle, read at the same points).
test_cycle_exact:
    addi t2, zero, 18
    flush_pipeline
    li32 a0, 0x13579BDF
    li32 a1, 0x2468ACE1
    flush_pipeline
    csrr s5, mcycle
    zip        a0, a0
    pack       a0, a0, a1
    brev8      a0, a0
    packh      a0, a1, a0
    unzip      a0, a0
    pack       a0, a1, a0
    zip        a0, a0
    brev8      a0, a0
    packh      a0, a0, a1
    zip        a0, a0
    pack       a0, a0, a1
    unzip      a0, a0
    brev8      a0, a0
    pack       a0, a1, a0
    zip        a0, a0
    unzip      a0, a0
    csrr s6, mcycle
    sub  s8, s6, s5
    mv   s4, a0
    li32 a0, 0x13579BDF
    li32 a1, 0x2468ACE1
    flush_pipeline
    csrr s5, mcycle
    addi       a0, a0, 1
    add        a0, a0, a1
    addi       a0, a0, 1
    add        a0, a1, a0
    addi       a0, a0, 1
    add        a0, a1, a0
    addi       a0, a0, 1
    addi       a0, a0, 1
    add        a0, a0, a1
    addi       a0, a0, 1
    add        a0, a0, a1
    addi       a0, a0, 1
    addi       a0, a0, 1
    add        a0, a1, a0
    addi       a0, a0, 1
    addi       a0, a0, 1
    csrr s6, mcycle
    sub  s9, s6, s5
    assert_equal s8, s9
    assert_value s4, 0x9483ACE1
    addi s9, s8, -17
    assert_value s9, 0x00000000

# -----------------------------------------------
# An external interrupt landing at 8 positions of a chain of the
# new instructions: the chain's result and the count are unchanged.
test_interrupt_in_chain:
    addi t2, zero, 19
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
    zip        a0, a0
    pack       a0, a0, a1
    brev8      a0, a0
    packh      a0, a1, a0
    unzip      a0, a0
    pack       a0, a1, a0
    zip        a0, a0
    brev8      a0, a0
    packh      a0, a0, a1
    zip        a0, a0
    pack       a0, a0, a1
    unzip      a0, a0
    brev8      a0, a0
    pack       a0, a1, a0
    zip        a0, a0
    unzip      a0, a0
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x9483ACE1
    li32 a0, 0x13579BDF
    li32 a1, 0x2468ACE1
    flush_pipeline
    interrupt 2
    zip        a0, a0
    pack       a0, a0, a1
    brev8      a0, a0
    packh      a0, a1, a0
    unzip      a0, a0
    pack       a0, a1, a0
    zip        a0, a0
    brev8      a0, a0
    packh      a0, a0, a1
    zip        a0, a0
    pack       a0, a0, a1
    unzip      a0, a0
    brev8      a0, a0
    pack       a0, a1, a0
    zip        a0, a0
    unzip      a0, a0
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x9483ACE1
    li32 a0, 0x13579BDF
    li32 a1, 0x2468ACE1
    flush_pipeline
    interrupt 3
    zip        a0, a0
    pack       a0, a0, a1
    brev8      a0, a0
    packh      a0, a1, a0
    unzip      a0, a0
    pack       a0, a1, a0
    zip        a0, a0
    brev8      a0, a0
    packh      a0, a0, a1
    zip        a0, a0
    pack       a0, a0, a1
    unzip      a0, a0
    brev8      a0, a0
    pack       a0, a1, a0
    zip        a0, a0
    unzip      a0, a0
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x9483ACE1
    li32 a0, 0x13579BDF
    li32 a1, 0x2468ACE1
    flush_pipeline
    interrupt 4
    zip        a0, a0
    pack       a0, a0, a1
    brev8      a0, a0
    packh      a0, a1, a0
    unzip      a0, a0
    pack       a0, a1, a0
    zip        a0, a0
    brev8      a0, a0
    packh      a0, a0, a1
    zip        a0, a0
    pack       a0, a0, a1
    unzip      a0, a0
    brev8      a0, a0
    pack       a0, a1, a0
    zip        a0, a0
    unzip      a0, a0
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x9483ACE1
    li32 a0, 0x13579BDF
    li32 a1, 0x2468ACE1
    flush_pipeline
    interrupt 5
    zip        a0, a0
    pack       a0, a0, a1
    brev8      a0, a0
    packh      a0, a1, a0
    unzip      a0, a0
    pack       a0, a1, a0
    zip        a0, a0
    brev8      a0, a0
    packh      a0, a0, a1
    zip        a0, a0
    pack       a0, a0, a1
    unzip      a0, a0
    brev8      a0, a0
    pack       a0, a1, a0
    zip        a0, a0
    unzip      a0, a0
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x9483ACE1
    li32 a0, 0x13579BDF
    li32 a1, 0x2468ACE1
    flush_pipeline
    interrupt 6
    zip        a0, a0
    pack       a0, a0, a1
    brev8      a0, a0
    packh      a0, a1, a0
    unzip      a0, a0
    pack       a0, a1, a0
    zip        a0, a0
    brev8      a0, a0
    packh      a0, a0, a1
    zip        a0, a0
    pack       a0, a0, a1
    unzip      a0, a0
    brev8      a0, a0
    pack       a0, a1, a0
    zip        a0, a0
    unzip      a0, a0
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x9483ACE1
    li32 a0, 0x13579BDF
    li32 a1, 0x2468ACE1
    flush_pipeline
    interrupt 7
    zip        a0, a0
    pack       a0, a0, a1
    brev8      a0, a0
    packh      a0, a1, a0
    unzip      a0, a0
    pack       a0, a1, a0
    zip        a0, a0
    brev8      a0, a0
    packh      a0, a0, a1
    zip        a0, a0
    pack       a0, a0, a1
    unzip      a0, a0
    brev8      a0, a0
    pack       a0, a1, a0
    zip        a0, a0
    unzip      a0, a0
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x9483ACE1
    li32 a0, 0x13579BDF
    li32 a1, 0x2468ACE1
    flush_pipeline
    interrupt 8
    zip        a0, a0
    pack       a0, a0, a1
    brev8      a0, a0
    packh      a0, a1, a0
    unzip      a0, a0
    pack       a0, a1, a0
    zip        a0, a0
    brev8      a0, a0
    packh      a0, a0, a1
    zip        a0, a0
    pack       a0, a0, a1
    unzip      a0, a0
    brev8      a0, a0
    pack       a0, a1, a0
    zip        a0, a0
    unzip      a0, a0
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x9483ACE1
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
    addi t2, zero, 20
    flush_pipeline
    li32 t5, record_trap
    csrw mtvec, t5
    flush_pipeline
    expect_trap 0x08C58533, 2       # funct7 0000100, funct3 000
    expect_trap 0x08C59533, 2       # funct7 0000100, funct3 001
    expect_trap 0x08C5A533, 2       # funct7 0000100, funct3 010
    expect_trap 0x08C5B533, 2       # funct7 0000100, funct3 011
    expect_trap 0x08C5D533, 2       # funct7 0000100, funct3 101
    expect_trap 0x08C5E533, 2       # funct7 0000100, funct3 110
    expect_trap 0x6865D513, 2       # brev8 neighbour, imm 0x686
    expect_trap 0x6885D513, 2       # brev8 neighbour, imm 0x688
    expect_trap 0x6A75D513, 2       # brev8 shape, inst[25] = 1 (imm 0x6A7)
    expect_trap 0x08E59513, 2       # zip neighbour, rs2 field 14
    expect_trap 0x09F59513, 2       # zip neighbour, rs2 field 31
    expect_trap 0x0AF59513, 2       # zip shape, inst[25] = 1 (imm 0x0AF)
    expect_trap 0x08E5D513, 2       # unzip neighbour, rs2 field 14
    expect_trap 0x0AF5D513, 2       # unzip shape, inst[25] = 1
    expect_trap 0x08059513, 2       # zip/unzip shape, rs2 field 0, funct3 001
    expect_trap 0x0AC59533, 2       # clmul (Zbkc)
    expect_trap 0x0AC5B533, 2       # clmulh (Zbkc)
    expect_trap 0x08C5C53B, 2       # packw (RV64, OP-32)
    expect_trap 0x0805C53B, 2       # RV64 zext.h (OP-32)
    li32 t5, unexpected_trap
    csrw mtvec, t5
    flush_pipeline

# ------------------------------------------------------------------------------------------------
# |                                          Test done!                                          |
# ------------------------------------------------------------------------------------------------
test_finish:
    addi t2, zero, 21
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
