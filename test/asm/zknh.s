# Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
# Embedded Architectures & Systems Group, Graz University of Technology
# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: zknh.s
#
# ------------------------------------------------------------------------------------------------
# |                                                                                              |
# | Zknh extension test (SHA-2 hash functions, the 10 instructions of RV32):                     |
# | sha256sig0 sha256sig1 sha256sum0 sha256sum1, sha512sig0h sha512sig0l sha512sig1h             |
# | sha512sig1l sha512sum0r sha512sum1r.                                                         |
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
# | 1. The known answers of the ISA text and corner operands for every instruction: the          |
# |    sha256 sig forms end in a SHIFT and the sum forms in a ROTATION; the high and low         |
# |    sha512sig forms differ by one rs2 term; rs1 and rs2 have different roles.                 |
# | 2. The pair identities: two instructions per 32-bit half give the 64-bit sigma and           |
# |    Sigma functions of SHA-512 (FIPS 180-4), compared with precomputed values.                |
# | 3. rd = x0 discarded (also for the instruction right behind it), x0 as a source,             |
# |    rd == rs1 / rs2 / both.                                                                   |
# | 4. Forwarding into rs1 and rs2 at distance 1, 2, 3, from two stages at once; a               |
# |    load-use stall in front; forwarding out into an ALU op, a branch, a load address,         |
# |    store data, a JALR base and a CSR write.                                                  |
# | 5. Not executed in the shadow of a taken branch; correct as a branch target; around          |
# |    fence.i; an interrupt at 8 positions of a chain changes nothing.                          |
# | 6. minstret counts each instruction once; a dependent chain takes exactly as many            |
# |    cycles as the same chain of add (no stall, forwarded in its own cycle).                   |
# | 7. The illegal neighbours (the RV64-only and SM3 rs2 fields of the sha256 group,             |
# |    the unused sha512 slots, wrong funct3, AES and SM4 encodings) raise                       |
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

.option arch, +zknh

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

# The rs1 value a for which sha512sig0h(a, x0) = target: (a >> 1) ^ (a >> 7) ^ (a >> 8) is
# u ^ (u >> 6) ^ (u >> 7) with u = a >> 1, and u = target ^ (u >> 6) ^ (u >> 7) solved by
# iteration fixes at least six more bits each round, so six rounds are exact (target < 2^31).
# Lets a load address and a JALR base come straight out of a Zknh instruction. Uses a2-a4.
.macro sig0h_preimage rd:req, target:req
    mv   a2, \target
    .rept 6
    srli a3, a2, 6
    srli a4, a2, 7
    xor  a3, a3, a4
    xor  a2, \target, a3
    .endr
    slli \rd, a2, 1
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
    li32 t5, 0x00000001
    sha256sig0 s1, t5
    assert_value s1, 0x02004000
    li32 t5, 0x12345678
    sha256sig0 s1, t5
    assert_value s1, 0xE7FCE6EE
    li32 t5, 0x00000001
    sha256sig1 s1, t5
    assert_value s1, 0x0000A000
    li32 t5, 0x12345678
    sha256sig1 s1, t5
    assert_value s1, 0xA1F78649
    li32 t5, 0x00000001
    sha256sum0 s1, t5
    assert_value s1, 0x40080400
    li32 t5, 0x12345678
    sha256sum0 s1, t5
    assert_value s1, 0x66146474
    li32 t5, 0x00000001
    sha256sum1 s1, t5
    assert_value s1, 0x04200080
    li32 t5, 0x12345678
    sha256sum1 s1, t5
    assert_value s1, 0x3561ABDA
    li32 t5, 0x12345678
    li32 t6, 0x9ABCDEF0
    sha512sig0h s1, t5, t6
    assert_value s1, 0xF92C77C6
    li32 t5, 0x00000000
    li32 t6, 0x00000001
    sha512sig0h s1, t5, t6
    assert_value s1, 0x81000000
    li32 t5, 0x12345678
    li32 t6, 0x9ABCDEF0
    sha512sig0l s1, t5, t6
    assert_value s1, 0x192C77C6
    li32 t5, 0x00000000
    li32 t6, 0x00000001
    sha512sig0l s1, t5, t6
    assert_value s1, 0x83000000
    li32 t5, 0x12345678
    li32 t6, 0x9ABCDEF0
    sha512sig1h s1, t5, t6
    assert_value s1, 0x0A3460DB
    li32 t5, 0x00000000
    li32 t6, 0x00000001
    sha512sig1h s1, t5, t6
    assert_value s1, 0x00002000
    li32 t5, 0x12345678
    li32 t6, 0x9ABCDEF0
    sha512sig1l s1, t5, t6
    assert_value s1, 0xCA3460DB
    li32 t5, 0x00000000
    li32 t6, 0x00000001
    sha512sig1l s1, t5, t6
    assert_value s1, 0x04002000
    li32 t5, 0x12345678
    li32 t6, 0x9ABCDEF0
    sha512sum0r s1, t5, t6
    assert_value s1, 0x7C57A100
    li32 t5, 0x00000000
    li32 t6, 0x00000001
    sha512sum0r s1, t5, t6
    assert_value s1, 0x00000010
    li32 t5, 0x12345678
    li32 t6, 0x9ABCDEF0
    sha512sum1r s1, t5, t6
    assert_value s1, 0x70311233
    li32 t5, 0x00000000
    li32 t6, 0x00000001
    sha512sum1r s1, t5, t6
    assert_value s1, 0x00044000

# -----------------------------------------------
# sha256sig0 = ror 7 ^ ror 18 ^ srl 3, sha256sig1 = ror 17 ^ ror 19 ^ srl 10,
# sha256sum0 = ror 2 ^ ror 13 ^ ror 22, sha256sum1 = ror 6 ^ ror 11 ^ ror 25.
# The low bits that a shift drops but a rotation keeps tell them apart
# (0x00000007, 0x000003FF).
test_sha256:
    addi t2, zero, 3
    flush_pipeline
    li32 t5, 0x00000000
    sha256sig0 s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0x00000001
    sha256sig0 s1, t5
    assert_value s1, 0x02004000
    li32 t5, 0xFFFFFFFF
    sha256sig0 s1, t5
    assert_value s1, 0x1FFFFFFF
    li32 t5, 0x80000000
    sha256sig0 s1, t5
    assert_value s1, 0x11002000
    li32 t5, 0x7FFFFFFF
    sha256sig0 s1, t5
    assert_value s1, 0x0EFFDFFF
    li32 t5, 0x000000FF
    sha256sig0 s1, t5
    assert_value s1, 0xFE3FC01E
    li32 t5, 0x0000FF00
    sha256sig0 s1, t5
    assert_value s1, 0x3FC01E1E
    li32 t5, 0x00FF0000
    sha256sig0 s1, t5
    assert_value s1, 0xC01E1E3F
    li32 t5, 0xFF000000
    sha256sig0 s1, t5
    assert_value s1, 0x1E1E3FC0
    li32 t5, 0x0000FFFF
    sha256sig0 s1, t5
    assert_value s1, 0xC1FFDE00
    li32 t5, 0xFFFF0000
    sha256sig0 s1, t5
    assert_value s1, 0xDE0021FF
    li32 t5, 0x0F0F0F0F
    sha256sig0 s1, t5
    assert_value s1, 0xDC3C3C3C
    li32 t5, 0xF0F0F0F0
    sha256sig0 s1, t5
    assert_value s1, 0xC3C3C3C3
    li32 t5, 0x55555555
    sha256sig0 s1, t5
    assert_value s1, 0xF5555555
    li32 t5, 0xAAAAAAAA
    sha256sig0 s1, t5
    assert_value s1, 0xEAAAAAAA
    li32 t5, 0x00000080
    sha256sig0 s1, t5
    assert_value s1, 0x00200011
    li32 t5, 0x00008000
    sha256sig0 s1, t5
    assert_value s1, 0x20001100
    li32 t5, 0x00010000
    sha256sig0 s1, t5
    assert_value s1, 0x40002200
    li32 t5, 0x12345678
    sha256sig0 s1, t5
    assert_value s1, 0xE7FCE6EE
    li32 t5, 0x9ABCDEF0
    sha256sig0 s1, t5
    assert_value s1, 0xC5DEC4CC
    li32 t5, 0x00000007
    sha256sig0 s1, t5
    assert_value s1, 0x0E01C000
    li32 t5, 0x000003FF
    sha256sig0 s1, t5
    assert_value s1, 0xFEFFC078
    li32 t5, 0x6A09E667
    sha256sig0 s1, t5
    assert_value s1, 0xBA0CF582
    li32 t5, 0xBB67AE85
    sha256sig0 s1, t5
    assert_value s1, 0xF7BB5454
    li32 t5, 0x00000000
    sha256sig1 s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0x00000001
    sha256sig1 s1, t5
    assert_value s1, 0x0000A000
    li32 t5, 0xFFFFFFFF
    sha256sig1 s1, t5
    assert_value s1, 0x003FFFFF
    li32 t5, 0x80000000
    sha256sig1 s1, t5
    assert_value s1, 0x00205000
    li32 t5, 0x7FFFFFFF
    sha256sig1 s1, t5
    assert_value s1, 0x001FAFFF
    li32 t5, 0x000000FF
    sha256sig1 s1, t5
    assert_value s1, 0x00606000
    li32 t5, 0x0000FF00
    sha256sig1 s1, t5
    assert_value s1, 0x6060003F
    li32 t5, 0x00FF0000
    sha256sig1 s1, t5
    assert_value s1, 0x60003FA0
    li32 t5, 0xFF000000
    sha256sig1 s1, t5
    assert_value s1, 0x003FA060
    li32 t5, 0x0000FFFF
    sha256sig1 s1, t5
    assert_value s1, 0x6000603F
    li32 t5, 0xFFFF0000
    sha256sig1 s1, t5
    assert_value s1, 0x603F9FC0
    li32 t5, 0x0F0F0F0F
    sha256sig1 s1, t5
    assert_value s1, 0x6665A5A5
    li32 t5, 0xF0F0F0F0
    sha256sig1 s1, t5
    assert_value s1, 0x665A5A5A
    li32 t5, 0x55555555
    sha256sig1 s1, t5
    assert_value s1, 0x00155555
    li32 t5, 0xAAAAAAAA
    sha256sig1 s1, t5
    assert_value s1, 0x002AAAAA
    li32 t5, 0x00000080
    sha256sig1 s1, t5
    assert_value s1, 0x00500000
    li32 t5, 0x00008000
    sha256sig1 s1, t5
    assert_value s1, 0x50000020
    li32 t5, 0x00010000
    sha256sig1 s1, t5
    assert_value s1, 0xA0000040
    li32 t5, 0x12345678
    sha256sig1 s1, t5
    assert_value s1, 0xA1F78649
    li32 t5, 0x9ABCDEF0
    sha256sig1 s1, t5
    assert_value s1, 0xF480F13E
    li32 t5, 0x00000007
    sha256sig1 s1, t5
    assert_value s1, 0x00036000
    li32 t5, 0x000003FF
    sha256sig1 s1, t5
    assert_value s1, 0x01806000
    li32 t5, 0x6A09E667
    sha256sig1 s1, t5
    assert_value s1, 0xCFE5DA3C
    li32 t5, 0xBB67AE85
    sha256sig1 s1, t5
    assert_value s1, 0x22BCB334
    li32 t5, 0x00000000
    sha256sum0 s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0x00000001
    sha256sum0 s1, t5
    assert_value s1, 0x40080400
    li32 t5, 0xFFFFFFFF
    sha256sum0 s1, t5
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x80000000
    sha256sum0 s1, t5
    assert_value s1, 0x20040200
    li32 t5, 0x7FFFFFFF
    sha256sum0 s1, t5
    assert_value s1, 0xDFFBFDFF
    li32 t5, 0x000000FF
    sha256sum0 s1, t5
    assert_value s1, 0xC7FBFC3F
    li32 t5, 0x0000FF00
    sha256sum0 s1, t5
    assert_value s1, 0xFBFC3FC7
    li32 t5, 0x00FF0000
    sha256sum0 s1, t5
    assert_value s1, 0xFC3FC7FB
    li32 t5, 0xFF000000
    sha256sum0 s1, t5
    assert_value s1, 0x3FC7FBFC
    li32 t5, 0x0000FFFF
    sha256sum0 s1, t5
    assert_value s1, 0x3C07C3F8
    li32 t5, 0xFFFF0000
    sha256sum0 s1, t5
    assert_value s1, 0xC3F83C07
    li32 t5, 0x0F0F0F0F
    sha256sum0 s1, t5
    assert_value s1, 0x87878787
    li32 t5, 0xF0F0F0F0
    sha256sum0 s1, t5
    assert_value s1, 0x78787878
    li32 t5, 0x55555555
    sha256sum0 s1, t5
    assert_value s1, 0xAAAAAAAA
    li32 t5, 0xAAAAAAAA
    sha256sum0 s1, t5
    assert_value s1, 0x55555555
    li32 t5, 0x00000080
    sha256sum0 s1, t5
    assert_value s1, 0x04020020
    li32 t5, 0x00008000
    sha256sum0 s1, t5
    assert_value s1, 0x02002004
    li32 t5, 0x00010000
    sha256sum0 s1, t5
    assert_value s1, 0x04004008
    li32 t5, 0x12345678
    sha256sum0 s1, t5
    assert_value s1, 0x66146474
    li32 t5, 0x9ABCDEF0
    sha256sum0 s1, t5
    assert_value s1, 0x22502030
    li32 t5, 0x00000007
    sha256sum0 s1, t5
    assert_value s1, 0xC0381C01
    li32 t5, 0x000003FF
    sha256sum0 s1, t5
    assert_value s1, 0xDFF7FCFF
    li32 t5, 0x6A09E667
    sha256sum0 s1, t5
    assert_value s1, 0xCE20B47E
    li32 t5, 0xBB67AE85
    sha256sum0 s1, t5
    assert_value s1, 0x844E2671
    li32 t5, 0x00000000
    sha256sum1 s1, t5
    assert_value s1, 0x00000000
    li32 t5, 0x00000001
    sha256sum1 s1, t5
    assert_value s1, 0x04200080
    li32 t5, 0xFFFFFFFF
    sha256sum1 s1, t5
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x80000000
    sha256sum1 s1, t5
    assert_value s1, 0x02100040
    li32 t5, 0x7FFFFFFF
    sha256sum1 s1, t5
    assert_value s1, 0xFDEFFFBF
    li32 t5, 0x000000FF
    sha256sum1 s1, t5
    assert_value s1, 0xE3E07F83
    li32 t5, 0x0000FF00
    sha256sum1 s1, t5
    assert_value s1, 0xE07F83E3
    li32 t5, 0x00FF0000
    sha256sum1 s1, t5
    assert_value s1, 0x7F83E3E0
    li32 t5, 0xFF000000
    sha256sum1 s1, t5
    assert_value s1, 0x83E3E07F
    li32 t5, 0x0000FFFF
    sha256sum1 s1, t5
    assert_value s1, 0x039FFC60
    li32 t5, 0xFFFF0000
    sha256sum1 s1, t5
    assert_value s1, 0xFC60039F
    li32 t5, 0x0F0F0F0F
    sha256sum1 s1, t5
    assert_value s1, 0x5A5A5A5A
    li32 t5, 0xF0F0F0F0
    sha256sum1 s1, t5
    assert_value s1, 0xA5A5A5A5
    li32 t5, 0x55555555
    sha256sum1 s1, t5
    assert_value s1, 0x55555555
    li32 t5, 0xAAAAAAAA
    sha256sum1 s1, t5
    assert_value s1, 0xAAAAAAAA
    li32 t5, 0x00000080
    sha256sum1 s1, t5
    assert_value s1, 0x10004002
    li32 t5, 0x00008000
    sha256sum1 s1, t5
    assert_value s1, 0x00400210
    li32 t5, 0x00010000
    sha256sum1 s1, t5
    assert_value s1, 0x00800420
    li32 t5, 0x12345678
    sha256sum1 s1, t5
    assert_value s1, 0x3561ABDA
    li32 t5, 0x9ABCDEF0
    sha256sum1 s1, t5
    assert_value s1, 0x4216DCAD
    li32 t5, 0x00000007
    sha256sum1 s1, t5
    assert_value s1, 0x1CE00380
    li32 t5, 0x000003FF
    sha256sum1 s1, t5
    assert_value s1, 0x83E1FF8F
    li32 t5, 0x6A09E667
    sha256sum1 s1, t5
    assert_value s1, 0x55B65510
    li32 t5, 0xBB67AE85
    sha256sum1 s1, t5
    assert_value s1, 0x758DB092

# -----------------------------------------------
# The six sha512 forms on corner pairs; rs1 = a and rs2 = b play different
# roles, so (a, b) and (b, a) give different results.
test_sha512:
    addi t2, zero, 4
    flush_pipeline
    li32 t5, 0x00000000
    li32 t6, 0x00000000
    sha512sig0h s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000001
    li32 t6, 0x00000001
    sha512sig0h s1, t5, t6
    assert_value s1, 0x81000000
    li32 t5, 0xFFFFFFFF
    li32 t6, 0xFFFFFFFF
    sha512sig0h s1, t5, t6
    assert_value s1, 0x01FFFFFF
    li32 t5, 0x80000000
    li32 t6, 0x7FFFFFFF
    sha512sig0h s1, t5, t6
    assert_value s1, 0x3E800000
    li32 t5, 0x7FFFFFFF
    li32 t6, 0x80000000
    sha512sig0h s1, t5, t6
    assert_value s1, 0x3F7FFFFF
    li32 t5, 0x12345678
    li32 t6, 0x9ABCDEF0
    sha512sig0h s1, t5, t6
    assert_value s1, 0xF92C77C6
    li32 t5, 0x9ABCDEF0
    li32 t6, 0x12345678
    sha512sig0h s1, t5, t6
    assert_value s1, 0x34F1AA1B
    li32 t5, 0x0000FFFF
    li32 t6, 0xFFFF0000
    sha512sig0h s1, t5, t6
    assert_value s1, 0x00007EFF
    li32 t5, 0xFFFF0000
    li32 t6, 0x0000FFFF
    sha512sig0h s1, t5, t6
    assert_value s1, 0x01FF8100
    li32 t5, 0x000000FF
    li32 t6, 0x0000FF00
    sha512sig0h s1, t5, t6
    assert_value s1, 0x0000007E
    li32 t5, 0x00008000
    li32 t6, 0x00000080
    sha512sig0h s1, t5, t6
    assert_value s1, 0x80004180
    li32 t5, 0x00000001
    li32 t6, 0x80000000
    sha512sig0h s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x80000000
    li32 t6, 0x00000001
    sha512sig0h s1, t5, t6
    assert_value s1, 0xC0800000
    li32 t5, 0x55555555
    li32 t6, 0xAAAAAAAA
    sha512sig0h s1, t5, t6
    assert_value s1, 0x80555555
    li32 t5, 0x00000000
    li32 t6, 0x00000000
    sha512sig0l s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000001
    li32 t6, 0x00000001
    sha512sig0l s1, t5, t6
    assert_value s1, 0x83000000
    li32 t5, 0xFFFFFFFF
    li32 t6, 0xFFFFFFFF
    sha512sig0l s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x80000000
    li32 t6, 0x7FFFFFFF
    sha512sig0l s1, t5, t6
    assert_value s1, 0xC0800000
    li32 t5, 0x7FFFFFFF
    li32 t6, 0x80000000
    sha512sig0l s1, t5, t6
    assert_value s1, 0x3F7FFFFF
    li32 t5, 0x12345678
    li32 t6, 0x9ABCDEF0
    sha512sig0l s1, t5, t6
    assert_value s1, 0x192C77C6
    li32 t5, 0x9ABCDEF0
    li32 t6, 0x12345678
    sha512sig0l s1, t5, t6
    assert_value s1, 0xC4F1AA1B
    li32 t5, 0x0000FFFF
    li32 t6, 0xFFFF0000
    sha512sig0l s1, t5, t6
    assert_value s1, 0x00007EFF
    li32 t5, 0xFFFF0000
    li32 t6, 0x0000FFFF
    sha512sig0l s1, t5, t6
    assert_value s1, 0xFFFF8100
    li32 t5, 0x000000FF
    li32 t6, 0x0000FF00
    sha512sig0l s1, t5, t6
    assert_value s1, 0x0000007E
    li32 t5, 0x00008000
    li32 t6, 0x00000080
    sha512sig0l s1, t5, t6
    assert_value s1, 0x80004180
    li32 t5, 0x00000001
    li32 t6, 0x80000000
    sha512sig0l s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x80000000
    li32 t6, 0x00000001
    sha512sig0l s1, t5, t6
    assert_value s1, 0xC2800000
    li32 t5, 0x55555555
    li32 t6, 0xAAAAAAAA
    sha512sig0l s1, t5, t6
    assert_value s1, 0xD4555555
    li32 t5, 0x00000000
    li32 t6, 0x00000000
    sha512sig1h s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000001
    li32 t6, 0x00000001
    sha512sig1h s1, t5, t6
    assert_value s1, 0x00002008
    li32 t5, 0xFFFFFFFF
    li32 t6, 0xFFFFFFFF
    sha512sig1h s1, t5, t6
    assert_value s1, 0x03FFFFFF
    li32 t5, 0x80000000
    li32 t6, 0x7FFFFFFF
    sha512sig1h s1, t5, t6
    assert_value s1, 0xFDFFF003
    li32 t5, 0x7FFFFFFF
    li32 t6, 0x80000000
    sha512sig1h s1, t5, t6
    assert_value s1, 0xFE000FFC
    li32 t5, 0x12345678
    li32 t6, 0x9ABCDEF0
    sha512sig1h s1, t5, t6
    assert_value s1, 0x0A3460DB
    li32 t5, 0x9ABCDEF0
    li32 t6, 0x12345678
    sha512sig1h s1, t5, t6
    assert_value s1, 0x5D4317AC
    li32 t5, 0x0000FFFF
    li32 t6, 0xFFFF0000
    sha512sig1h s1, t5, t6
    assert_value s1, 0xE007FC00
    li32 t5, 0xFFFF0000
    li32 t6, 0x0000FFFF
    sha512sig1h s1, t5, t6
    assert_value s1, 0xE3F803FF
    li32 t5, 0x000000FF
    li32 t6, 0x0000FF00
    sha512sig1h s1, t5, t6
    assert_value s1, 0x1FE007FB
    li32 t5, 0x00008000
    li32 t6, 0x00000080
    sha512sig1h s1, t5, t6
    assert_value s1, 0x00140200
    li32 t5, 0x00000001
    li32 t6, 0x80000000
    sha512sig1h s1, t5, t6
    assert_value s1, 0x0000000C
    li32 t5, 0x80000000
    li32 t6, 0x00000001
    sha512sig1h s1, t5, t6
    assert_value s1, 0x02003000
    li32 t5, 0x55555555
    li32 t6, 0xAAAAAAAA
    sha512sig1h s1, t5, t6
    assert_value s1, 0xFEAAB552
    li32 t5, 0x00000000
    li32 t6, 0x00000000
    sha512sig1l s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000001
    li32 t6, 0x00000001
    sha512sig1l s1, t5, t6
    assert_value s1, 0x04002008
    li32 t5, 0xFFFFFFFF
    li32 t6, 0xFFFFFFFF
    sha512sig1l s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x80000000
    li32 t6, 0x7FFFFFFF
    sha512sig1l s1, t5, t6
    assert_value s1, 0x01FFF003
    li32 t5, 0x7FFFFFFF
    li32 t6, 0x80000000
    sha512sig1l s1, t5, t6
    assert_value s1, 0xFE000FFC
    li32 t5, 0x12345678
    li32 t6, 0x9ABCDEF0
    sha512sig1l s1, t5, t6
    assert_value s1, 0xCA3460DB
    li32 t5, 0x9ABCDEF0
    li32 t6, 0x12345678
    sha512sig1l s1, t5, t6
    assert_value s1, 0xBD4317AC
    li32 t5, 0x0000FFFF
    li32 t6, 0xFFFF0000
    sha512sig1l s1, t5, t6
    assert_value s1, 0xE007FC00
    li32 t5, 0xFFFF0000
    li32 t6, 0x0000FFFF
    sha512sig1l s1, t5, t6
    assert_value s1, 0x1FF803FF
    li32 t5, 0x000000FF
    li32 t6, 0x0000FF00
    sha512sig1l s1, t5, t6
    assert_value s1, 0x1FE007FB
    li32 t5, 0x00008000
    li32 t6, 0x00000080
    sha512sig1l s1, t5, t6
    assert_value s1, 0x00140200
    li32 t5, 0x00000001
    li32 t6, 0x80000000
    sha512sig1l s1, t5, t6
    assert_value s1, 0x0000000C
    li32 t5, 0x80000000
    li32 t6, 0x00000001
    sha512sig1l s1, t5, t6
    assert_value s1, 0x06003000
    li32 t5, 0x55555555
    li32 t6, 0xAAAAAAAA
    sha512sig1l s1, t5, t6
    assert_value s1, 0x56AAB552
    li32 t5, 0x00000000
    li32 t6, 0x00000000
    sha512sum0r s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000001
    li32 t6, 0x00000001
    sha512sum0r s1, t5, t6
    assert_value s1, 0x42000010
    li32 t5, 0xFFFFFFFF
    li32 t6, 0xFFFFFFFF
    sha512sum0r s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x80000000
    li32 t6, 0x7FFFFFFF
    sha512sum0r s1, t5, t6
    assert_value s1, 0xE0FFFFF8
    li32 t5, 0x7FFFFFFF
    li32 t6, 0x80000000
    sha512sum0r s1, t5, t6
    assert_value s1, 0x1F000007
    li32 t5, 0x12345678
    li32 t6, 0x9ABCDEF0
    sha512sum0r s1, t5, t6
    assert_value s1, 0x7C57A100
    li32 t5, 0x9ABCDEF0
    li32 t6, 0x12345678
    sha512sum0r s1, t5, t6
    assert_value s1, 0xC7EC1ABB
    li32 t5, 0x0000FFFF
    li32 t6, 0xFFFF0000
    sha512sum0r s1, t5, t6
    assert_value s1, 0xFFF03E00
    li32 t5, 0xFFFF0000
    li32 t6, 0x0000FFFF
    sha512sum0r s1, t5, t6
    assert_value s1, 0x000FC1FF
    li32 t5, 0x000000FF
    li32 t6, 0x0000FF00
    sha512sum0r s1, t5, t6
    assert_value s1, 0x3E0FCE3E
    li32 t5, 0x00008000
    li32 t6, 0x00000080
    sha512sum0r s1, t5, t6
    assert_value s1, 0x00000821
    li32 t5, 0x00000001
    li32 t6, 0x80000000
    sha512sum0r s1, t5, t6
    assert_value s1, 0x63000000
    li32 t5, 0x80000000
    li32 t6, 0x00000001
    sha512sum0r s1, t5, t6
    assert_value s1, 0x00000018
    li32 t5, 0x55555555
    li32 t6, 0xAAAAAAAA
    sha512sum0r s1, t5, t6
    assert_value s1, 0x6B55555A
    li32 t5, 0x00000000
    li32 t6, 0x00000000
    sha512sum1r s1, t5, t6
    assert_value s1, 0x00000000
    li32 t5, 0x00000001
    li32 t6, 0x00000001
    sha512sum1r s1, t5, t6
    assert_value s1, 0x00844000
    li32 t5, 0xFFFFFFFF
    li32 t6, 0xFFFFFFFF
    sha512sum1r s1, t5, t6
    assert_value s1, 0xFFFFFFFF
    li32 t5, 0x80000000
    li32 t6, 0x7FFFFFFF
    sha512sum1r s1, t5, t6
    assert_value s1, 0x003E1FFF
    li32 t5, 0x7FFFFFFF
    li32 t6, 0x80000000
    sha512sum1r s1, t5, t6
    assert_value s1, 0xFFC1E000
    li32 t5, 0x12345678
    li32 t6, 0x9ABCDEF0
    sha512sum1r s1, t5, t6
    assert_value s1, 0x70311233
    li32 t5, 0x9ABCDEF0
    li32 t6, 0x12345678
    sha512sum1r s1, t5, t6
    assert_value s1, 0x34755677
    li32 t5, 0x0000FFFF
    li32 t6, 0xFFFF0000
    sha512sum1r s1, t5, t6
    assert_value s1, 0x3FFFFF83
    li32 t5, 0xFFFF0000
    li32 t6, 0x0000FFFF
    sha512sum1r s1, t5, t6
    assert_value s1, 0xC000007C
    li32 t5, 0x000000FF
    li32 t6, 0x0000FF00
    sha512sum1r s1, t5, t6
    assert_value s1, 0xBC40007F
    li32 t5, 0x00008000
    li32 t6, 0x00000080
    sha512sum1r s1, t5, t6
    assert_value s1, 0x02200002
    li32 t5, 0x00000001
    li32 t6, 0x80000000
    sha512sum1r s1, t5, t6
    assert_value s1, 0x00C00000
    li32 t5, 0x80000000
    li32 t6, 0x00000001
    sha512sum1r s1, t5, t6
    assert_value s1, 0x00066000
    li32 t5, 0x55555555
    li32 t6, 0xAAAAAAAA
    sha512sum1r s1, t5, t6
    assert_value s1, 0xAAD69555

# -----------------------------------------------
# The pair identities of the ISA text against the 64-bit FIPS 180-4
# functions, x = {hi, lo}: sigma0(x) = {sig0h(hi, lo), sig0l(lo, hi)},
# sigma1(x) = {sig1h(hi, lo), sig1l(lo, hi)}, Sigma0(x) = {sum0r(hi, lo),
# sum0r(lo, hi)}, Sigma1(x) = {sum1r(hi, lo), sum1r(lo, hi)}.
test_sha512_pairs:
    addi t2, zero, 5
    flush_pipeline
    # x = 0x0123456789ABCDEF
    li32 t5, 0x01234567
    li32 t6, 0x89ABCDEF
    sha512sig0h s1, t5, t6
    sha512sig0l s2, t6, t5
    assert_value s1, 0x6F92C77C
    assert_value s2, 0x6C4F1AA1
    sha512sig1h s1, t5, t6
    sha512sig1l s2, t6, t5
    assert_value s1, 0x70A3460D
    assert_value s2, 0xBBD4317A
    sha512sum0r s1, t5, t6
    sha512sum0r s2, t6, t5
    assert_value s1, 0xB7C57A10
    assert_value s2, 0x0C7EC1AB
    sha512sum1r s1, t5, t6
    sha512sum1r s2, t6, t5
    assert_value s1, 0x77031123
    assert_value s2, 0x33475567
    # x = 0xFEDCBA9876543210
    li32 t5, 0xFEDCBA98
    li32 t6, 0x76543210
    sha512sig0h s1, t5, t6
    sha512sig0l s2, t6, t5
    assert_value s1, 0x6E6D3883
    assert_value s2, 0x93B0E55E
    sha512sig1h s1, t5, t6
    sha512sig1l s2, t6, t5
    assert_value s1, 0x735CB9F2
    assert_value s2, 0x442BCE85
    sha512sum0r s1, t5, t6
    sha512sum0r s2, t6, t5
    assert_value s1, 0x483A85EF
    assert_value s2, 0xF3813E54
    sha512sum1r s1, t5, t6
    sha512sum1r s2, t6, t5
    assert_value s1, 0x88FCEEDC
    assert_value s2, 0xCCB8AA98
    # x = 0x8000000000000001
    li32 t5, 0x80000000
    li32 t6, 0x00000001
    sha512sig0h s1, t5, t6
    sha512sig0l s2, t6, t5
    assert_value s1, 0xC0800000
    assert_value s2, 0x00000000
    sha512sig1h s1, t5, t6
    sha512sig1l s2, t6, t5
    assert_value s1, 0x02003000
    assert_value s2, 0x0000000C
    sha512sum0r s1, t5, t6
    sha512sum0r s2, t6, t5
    assert_value s1, 0x00000018
    assert_value s2, 0x63000000
    sha512sum1r s1, t5, t6
    sha512sum1r s2, t6, t5
    assert_value s1, 0x00066000
    assert_value s2, 0x00C00000
    # x = 0x6A09E667F3BCC908
    li32 t5, 0x6A09E667
    li32 t6, 0xF3BCC908
    sha512sig0h s1, t5, t6
    sha512sig0l s2, t6, t5
    assert_value s1, 0x3DBAE919
    assert_value s2, 0x51CAA1DF
    sha512sig1h s1, t5, t6
    sha512sig1l s2, t6, t5
    assert_value s1, 0xC8C619E7
    assert_value s2, 0x3EE44510
    sha512sum0r s1, t5, t6
    sha512sum0r s2, t6, t5
    assert_value s1, 0x08C4DB56
    assert_value s2, 0xAAC80C2A
    sha512sum1r s1, t5, t6
    sha512sum1r s2, t6, t5
    assert_value s1, 0x259A6CC1
    assert_value s2, 0x643336EF
    # x = 0x428A2F98D728AE22
    li32 t5, 0x428A2F98
    li32 t6, 0xD728AE22
    sha512sig0h s1, t5, t6
    sha512sig0l s2, t6, t5
    assert_value s1, 0x038289BC
    assert_value s2, 0xC2ED2EE3
    sha512sig1h s1, t5, t6
    sha512sig1l s2, t6, t5
    assert_value s1, 0x009F1C29
    assert_value s2, 0x9FEAC94F
    sha512sum0r s1, t5, t6
    sha512sum0r s2, t6, t5
    assert_value s1, 0x76EE98F0
    assert_value s2, 0xFC856634
    sha512sum1r s1, t5, t6
    sha512sum1r s2, t6, t5
    assert_value s1, 0x5F6A0EDD
    assert_value s2, 0x24A42C7F
    # x = 0xFFFFFFFF00000000
    li32 t5, 0xFFFFFFFF
    li32 t6, 0x00000000
    sha512sig0h s1, t5, t6
    sha512sig0l s2, t6, t5
    assert_value s1, 0x7EFFFFFF
    assert_value s2, 0x81000000
    sha512sig1h s1, t5, t6
    sha512sig1l s2, t6, t5
    assert_value s1, 0xFC001FF8
    assert_value s2, 0x03FFE007
    sha512sum0r s1, t5, t6
    sha512sum0r s2, t6, t5
    assert_value s1, 0x3E00000F
    assert_value s2, 0xC1FFFFF0
    sha512sum1r s1, t5, t6
    sha512sum1r s2, t6, t5
    assert_value s1, 0xFF83C000
    assert_value s2, 0x007C3FFF

# -----------------------------------------------
# rd = x0 discards the result, also for the instruction right behind it,
# which must read 0 rather than a forwarded value.
test_rd_is_x0:
    addi t2, zero, 6
    flush_pipeline
    li32 t5, 0x12345678
    li32 t6, 0x9ABCDEF0
    sha512sum0r zero, t5, t6
    add  s1, zero, zero           # reads x0 right behind the discarded result
    sha512sum0r zero, t5, t6
    add  s2, t5, zero
    assert_value s1, 0x00000000
    assert_value s2, 0x12345678
    sha256sum0 zero, t5
    sha256sum0 s3, zero
    assert_value s3, 0x00000000

# -----------------------------------------------
# x0 as a source operand.
test_x0_source:
    addi t2, zero, 7
    flush_pipeline
    li32 t5, 0x89ABCDEF
    li32 t6, 0x13579BDF
    sha256sig0 s1, zero
    assert_value s1, 0x00000000
    sha256sig1 s1, zero
    assert_value s1, 0x00000000
    sha256sum0 s1, zero
    assert_value s1, 0x00000000
    sha256sum1 s1, zero
    assert_value s1, 0x00000000
    sha512sig0h s1, zero, t6
    assert_value s1, 0x5F000000
    sha512sig0h s1, t5, zero
    assert_value s1, 0x454F1AA1
    sha512sig0h s1, zero, zero
    assert_value s1, 0x00000000
    sha512sig0l s1, zero, t6
    assert_value s1, 0xE1000000
    sha512sig0l s1, t5, zero
    assert_value s1, 0x454F1AA1
    sha512sig0l s1, zero, zero
    assert_value s1, 0x00000000
    sha512sig1h s1, zero, t6
    assert_value s1, 0xF37BE000
    sha512sig1h s1, t5, zero
    assert_value s1, 0x4F78D17A
    sha512sig1h s1, zero, zero
    assert_value s1, 0x00000000
    sha512sig1l s1, zero, t6
    assert_value s1, 0x8F7BE000
    sha512sig1l s1, t5, zero
    assert_value s1, 0x4F78D17A
    sha512sig1l s1, zero, zero
    assert_value s1, 0x00000000
    sha512sum0r s1, zero, t6
    assert_value s1, 0x318AF430
    sha512sum0r s1, t5, zero
    assert_value s1, 0x1E000008
    sha512sum0r s1, zero, zero
    assert_value s1, 0x00000000
    sha512sum1r s1, zero, t6
    assert_value s1, 0x89826BCD
    sha512sum1r s1, t5, zero
    assert_value s1, 0xF78204C5
    sha512sum1r s1, zero, zero
    assert_value s1, 0x00000000

# -----------------------------------------------
# rd == rs1, rd == rs2 and rd == rs1 == rs2 all read the OLD operands.
test_aliasing:
    addi t2, zero, 8
    flush_pipeline
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    sha512sig0l t5, t5, t6
    assert_value t5, 0xF869192C
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    sha512sig0l t6, t5, t6
    assert_value t6, 0xF869192C
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    sha512sig0l t5, t5, t5
    assert_value t5, 0x2569192C
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    sha512sum1r t5, t5, t6
    assert_value t5, 0xD9C7B87C
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    sha512sum1r t6, t5, t6
    assert_value t6, 0xD9C7B87C
    li32 t5, 0xF0F01234
    li32 t6, 0x0F0F00FF
    sha512sum1r t5, t5, t5
    assert_value t5, 0x562687F5
    li32 t5, 0xF0F01234
    sha256sig0 t5, t5
    assert_value t5, 0x7372DE5E
    li32 t5, 0xF0F01234
    sha256sig1 t5, t5
    assert_value t5, 0x0B60DA62
    li32 t5, 0xF0F01234
    sha256sum0 t5, t5
    assert_value t5, 0x6DD350CE
    li32 t5, 0xF0F01234
    sha256sum1 t5, t5
    assert_value t5, 0xED54C432

# -----------------------------------------------
# Forwarding INTO the new instruction: the operand produced 1, 2 and 3
# instructions earlier, into rs1 and into rs2, and both operands
# forwarded from different stages.
test_forward_into:
    addi t2, zero, 9
    flush_pipeline
    li32 t6, 0x00137F13
    li32 t5, 0x8001F00F
    sha512sig1l s1, t5, t6
    assert_value s1, 0x21EDF7B8
    li32 t5, 0x8001F00F
    li32 t6, 0x00137F13
    sha512sig1l s2, t5, t6
    assert_value s2, 0x21EDF7B8
    li32 t5, 0x8100F00F
    sha256sig1 s3, t5
    assert_value s3, 0x6626709C
    li32 t6, 0x00137F13
    li32 t5, 0x8001F00F
    nop
    sha512sig1l s1, t5, t6
    assert_value s1, 0x21EDF7B8
    li32 t5, 0x8001F00F
    li32 t6, 0x00137F13
    nop
    sha512sig1l s2, t5, t6
    assert_value s2, 0x21EDF7B8
    li32 t5, 0x8203F00F
    nop
    sha256sig1 s3, t5
    assert_value s3, 0x8626B1BD
    li32 t6, 0x00137F13
    li32 t5, 0x8001F00F
    nop
    nop
    sha512sig1l s1, t5, t6
    assert_value s1, 0x21EDF7B8
    li32 t5, 0x8001F00F
    li32 t6, 0x00137F13
    nop
    nop
    sha512sig1l s2, t5, t6
    assert_value s2, 0x21EDF7B8
    li32 t5, 0x8302F00F
    nop
    nop
    sha256sig1 s3, t5
    assert_value s3, 0x2626F15D
    li32 t5, 0x8001F00F
    li32 t6, 0x00137F13
    sha512sig1l s1, t5, t6
    li32 t6, 0x00137F13
    li32 t5, 0x8001F00F
    sha512sig1l s2, t5, t6
    li32 t5, 0x8001F00F
    sha512sig1l s3, t5, t5
    assert_value s1, 0x21EDF7B8
    assert_value s2, 0x21EDF7B8
    assert_value s3, 0x000E77BC

# -----------------------------------------------
# A load feeding the new instruction directly (load-use stall in front of it),
# into rs1, into rs2 and into both.
test_load_use:
    addi t2, zero, 10
    flush_pipeline
    li32 t6, 0x00000005
    lw   t5, 12(t4)
    sha512sum1r s1, t5, t6
    assert_value s1, 0x3C150C5C
    li32 t5, 0x7FFFFFFF
    lw   t6, 4(t4)
    sha512sum1r s2, t5, t6
    assert_value s2, 0xFFC1E000
    lw   t5, 8(t4)
    lw   t6, 12(t4)
    sha512sum1r s3, t5, t6
    assert_value s3, 0x33F719E8
    lw   t5, 8(t4)
    sha256sum1 s4, t5
    assert_value s4, 0x9C639C63

# -----------------------------------------------
# Forwarding OUT of the new instruction, consumed by the very next
# instruction: an ALU op, a branch, a load address, store data, a
# JALR base and a CSR write.
test_forward_out_of:
    addi t2, zero, 11
    flush_pipeline
    li32 t5, 0xF0F0F0F0
    sha256sig0 s1, t5
    addi s2, s1, 1
    assert_value s2, 0xC3C3C3C4
    li32 s3, 0x83008300
    li32 t5, 0x00010000
    li32 t6, 0x00000001
    sha512sig0l s1, t5, t6
    bne  s1, s3, fwd_branch_bad_1
    beq  zero, zero, fwd_branch_ok_2
fwd_branch_bad_1:
    fail
fwd_branch_ok_2:
    addi s4, t4, 8
    sig0h_preimage t5, s4
    sha512sig0h s1, t5, zero
    lw   s2, 0(s1)
    assert_value s2, 0x00FF00FF
    li32 t5, 0x11223344
    sha256sum1 s1, t5
    sw   s1, 20(t4)              # scratch_var
    flush_pipeline
    lw   s2, 20(t4)
    assert_value s2, 0xE9DF0E83
    addi s4, zero, 0
    li32 s3, zknh_jalr_target_3
    sig0h_preimage t5, s3
    sha512sig0h s1, t5, zero
    jalr ra, 0(s1)
    fail                          # not reached
    beq  zero, zero, jalr_back_4
zknh_jalr_target_3:
    addi s4, zero, 1
jalr_back_4:
    assert_value s4, 0x00000001
    li32 t5, 0x00100001
    li32 t6, 0x80000000
    sha512sum1r s1, t5, t6
    csrw mscratch, s1
    csrr s2, mscratch
    assert_value s2, 0x00C00044

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
    sha256sig1 s1, t5
    sha512sig1h s1, t5, t6
    fail
shadow_target_5:
    sha512sig1h s2, t5, t6
    assert_value s1, 0x0000ABCD
    assert_value s2, 0xC224401E

# -----------------------------------------------
# Before and after fence.i, which refetches everything behind it.
test_fence_i:
    addi t2, zero, 13
    flush_pipeline
    li32 t5, 0x0F0F1234
    li32 t6, 0xFF00FF00
    sha512sum0r s1, t5, t6
    fence.i
    sha256sum0 s2, s1
    assert_value s1, 0xA631CE3E
    assert_value s2, 0x1F41B899

# -----------------------------------------------
# minstret rises by exactly N over N of the new instructions: the
# difference between a window with them and an empty window.
test_minstret:
    addi t2, zero, 14
    flush_pipeline
    li32 a0, 0x13579BDF
    li32 a1, 0x2468ACE1
    flush_pipeline
    csrr s5, minstret
    csrr s6, minstret
    sub  s8, s6, s5
    flush_pipeline
    csrr s5, minstret
    sha256sig0 a0, a0
    sha512sig0h a0, a0, a1
    sha256sum0 a0, a0
    sha512sig0l a0, a1, a0
    sha256sig1 a0, a0
    sha512sig1h a0, a0, a1
    sha256sum1 a0, a0
    sha512sig1l a0, a1, a0
    sha512sum0r a0, a0, a1
    sha256sig0 a0, a0
    sha512sum1r a0, a1, a0
    sha256sum0 a0, a0
    sha512sum0r a0, a1, a0
    sha256sig1 a0, a0
    sha512sum1r a0, a0, a1
    sha256sum1 a0, a0
    csrr s6, minstret
    sub  s9, s6, s5
    sub  s9, s9, s8
    assert_value s9, 0x00000010
    assert_value a0, 0x580E689D

# -----------------------------------------------
# A chain of 16 back-to-back DEPENDENT instructions takes exactly as many
# cycles as the same chain of add instructions: the result is forwarded
# in its own cycle and nothing stalls (mcycle, read at the same points).
test_cycle_exact:
    addi t2, zero, 15
    flush_pipeline
    li32 a0, 0x13579BDF
    li32 a1, 0x2468ACE1
    flush_pipeline
    csrr s5, mcycle
    sha256sig0 a0, a0
    sha512sig0h a0, a0, a1
    sha256sum0 a0, a0
    sha512sig0l a0, a1, a0
    sha256sig1 a0, a0
    sha512sig1h a0, a0, a1
    sha256sum1 a0, a0
    sha512sig1l a0, a1, a0
    sha512sum0r a0, a0, a1
    sha256sig0 a0, a0
    sha512sum1r a0, a1, a0
    sha256sum0 a0, a0
    sha512sum0r a0, a1, a0
    sha256sig1 a0, a0
    sha512sum1r a0, a0, a1
    sha256sum1 a0, a0
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
    add        a0, a0, a1
    addi       a0, a0, 1
    add        a0, a1, a0
    add        a0, a0, a1
    addi       a0, a0, 1
    add        a0, a1, a0
    addi       a0, a0, 1
    add        a0, a1, a0
    addi       a0, a0, 1
    add        a0, a0, a1
    addi       a0, a0, 1
    csrr s6, mcycle
    sub  s9, s6, s5
    assert_equal s8, s9
    assert_value s4, 0x580E689D
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
    li32 a1, 0x2468ACE1
    flush_pipeline
    interrupt 1
    sha256sig0 a0, a0
    sha512sig0h a0, a0, a1
    sha256sum0 a0, a0
    sha512sig0l a0, a1, a0
    sha256sig1 a0, a0
    sha512sig1h a0, a0, a1
    sha256sum1 a0, a0
    sha512sig1l a0, a1, a0
    sha512sum0r a0, a0, a1
    sha256sig0 a0, a0
    sha512sum1r a0, a1, a0
    sha256sum0 a0, a0
    sha512sum0r a0, a1, a0
    sha256sig1 a0, a0
    sha512sum1r a0, a0, a1
    sha256sum1 a0, a0
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x580E689D
    li32 a0, 0x13579BDF
    li32 a1, 0x2468ACE1
    flush_pipeline
    interrupt 2
    sha256sig0 a0, a0
    sha512sig0h a0, a0, a1
    sha256sum0 a0, a0
    sha512sig0l a0, a1, a0
    sha256sig1 a0, a0
    sha512sig1h a0, a0, a1
    sha256sum1 a0, a0
    sha512sig1l a0, a1, a0
    sha512sum0r a0, a0, a1
    sha256sig0 a0, a0
    sha512sum1r a0, a1, a0
    sha256sum0 a0, a0
    sha512sum0r a0, a1, a0
    sha256sig1 a0, a0
    sha512sum1r a0, a0, a1
    sha256sum1 a0, a0
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x580E689D
    li32 a0, 0x13579BDF
    li32 a1, 0x2468ACE1
    flush_pipeline
    interrupt 3
    sha256sig0 a0, a0
    sha512sig0h a0, a0, a1
    sha256sum0 a0, a0
    sha512sig0l a0, a1, a0
    sha256sig1 a0, a0
    sha512sig1h a0, a0, a1
    sha256sum1 a0, a0
    sha512sig1l a0, a1, a0
    sha512sum0r a0, a0, a1
    sha256sig0 a0, a0
    sha512sum1r a0, a1, a0
    sha256sum0 a0, a0
    sha512sum0r a0, a1, a0
    sha256sig1 a0, a0
    sha512sum1r a0, a0, a1
    sha256sum1 a0, a0
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x580E689D
    li32 a0, 0x13579BDF
    li32 a1, 0x2468ACE1
    flush_pipeline
    interrupt 4
    sha256sig0 a0, a0
    sha512sig0h a0, a0, a1
    sha256sum0 a0, a0
    sha512sig0l a0, a1, a0
    sha256sig1 a0, a0
    sha512sig1h a0, a0, a1
    sha256sum1 a0, a0
    sha512sig1l a0, a1, a0
    sha512sum0r a0, a0, a1
    sha256sig0 a0, a0
    sha512sum1r a0, a1, a0
    sha256sum0 a0, a0
    sha512sum0r a0, a1, a0
    sha256sig1 a0, a0
    sha512sum1r a0, a0, a1
    sha256sum1 a0, a0
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x580E689D
    li32 a0, 0x13579BDF
    li32 a1, 0x2468ACE1
    flush_pipeline
    interrupt 5
    sha256sig0 a0, a0
    sha512sig0h a0, a0, a1
    sha256sum0 a0, a0
    sha512sig0l a0, a1, a0
    sha256sig1 a0, a0
    sha512sig1h a0, a0, a1
    sha256sum1 a0, a0
    sha512sig1l a0, a1, a0
    sha512sum0r a0, a0, a1
    sha256sig0 a0, a0
    sha512sum1r a0, a1, a0
    sha256sum0 a0, a0
    sha512sum0r a0, a1, a0
    sha256sig1 a0, a0
    sha512sum1r a0, a0, a1
    sha256sum1 a0, a0
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x580E689D
    li32 a0, 0x13579BDF
    li32 a1, 0x2468ACE1
    flush_pipeline
    interrupt 6
    sha256sig0 a0, a0
    sha512sig0h a0, a0, a1
    sha256sum0 a0, a0
    sha512sig0l a0, a1, a0
    sha256sig1 a0, a0
    sha512sig1h a0, a0, a1
    sha256sum1 a0, a0
    sha512sig1l a0, a1, a0
    sha512sum0r a0, a0, a1
    sha256sig0 a0, a0
    sha512sum1r a0, a1, a0
    sha256sum0 a0, a0
    sha512sum0r a0, a1, a0
    sha256sig1 a0, a0
    sha512sum1r a0, a0, a1
    sha256sum1 a0, a0
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x580E689D
    li32 a0, 0x13579BDF
    li32 a1, 0x2468ACE1
    flush_pipeline
    interrupt 7
    sha256sig0 a0, a0
    sha512sig0h a0, a0, a1
    sha256sum0 a0, a0
    sha512sig0l a0, a1, a0
    sha256sig1 a0, a0
    sha512sig1h a0, a0, a1
    sha256sum1 a0, a0
    sha512sig1l a0, a1, a0
    sha512sum0r a0, a0, a1
    sha256sig0 a0, a0
    sha512sum1r a0, a1, a0
    sha256sum0 a0, a0
    sha512sum0r a0, a1, a0
    sha256sig1 a0, a0
    sha512sum1r a0, a0, a1
    sha256sum1 a0, a0
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x580E689D
    li32 a0, 0x13579BDF
    li32 a1, 0x2468ACE1
    flush_pipeline
    interrupt 8
    sha256sig0 a0, a0
    sha512sig0h a0, a0, a1
    sha256sum0 a0, a0
    sha512sig0l a0, a1, a0
    sha256sig1 a0, a0
    sha512sig1h a0, a0, a1
    sha256sum1 a0, a0
    sha512sig1l a0, a1, a0
    sha512sum0r a0, a0, a1
    sha256sig0 a0, a0
    sha512sum1r a0, a1, a0
    sha256sum0 a0, a0
    sha512sum0r a0, a1, a0
    sha256sig1 a0, a0
    sha512sum1r a0, a0, a1
    sha256sum1 a0, a0
    flush_pipeline
    flush_pipeline
    assert_value a0, 0x580E689D
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
    expect_trap 0x10459513, 2       # sha256 group, rs2 field 4 (RV64 sha512sum0)
    expect_trap 0x10559513, 2       # sha256 group, rs2 field 5 (RV64 sha512sum1)
    expect_trap 0x10659513, 2       # sha256 group, rs2 field 6 (RV64 sha512sig0)
    expect_trap 0x10759513, 2       # sha256 group, rs2 field 7 (RV64 sha512sig1)
    expect_trap 0x10859513, 2       # sha256 group, rs2 field 8 (sm3p0, Zksh)
    expect_trap 0x10959513, 2       # sha256 group, rs2 field 9 (sm3p1, Zksh)
    expect_trap 0x11F59513, 2       # sha256 group, rs2 field 31
    expect_trap 0x1025D513, 2       # sha256sig0 shape, funct3 101
    expect_trap 0x12259513, 2       # sha256sig0 shape, inst[25] = 1
    expect_trap 0x30059513, 2       # aes64im (RV64)
    expect_trap 0x31059513, 2       # aes64ks1i rnum 0 (RV64)
    expect_trap 0x10C58533, 2       # funct7 0001000 under OP, funct3 000
    expect_trap 0x58C58533, 2       # funct7 0101100 (unused sha512 slot)
    expect_trap 0x5AC58533, 2       # funct7 0101101 (unused sha512 slot)
    expect_trap 0x50C59533, 2       # sha512sum0r shape, funct3 001
    expect_trap 0x5CC5C533, 2       # sha512sig0h shape, funct3 100
    expect_trap 0xD6C58533, 2       # sha512sig1l shape, inst[31] = 1
    expect_trap 0x22C58533, 2       # aes32esi bs 0 (Zkne)
    expect_trap 0x26C58533, 2       # aes32esmi bs 0 (Zkne)
    expect_trap 0x2AC58533, 2       # aes32dsi bs 0 (Zknd)
    expect_trap 0x2EC58533, 2       # aes32dsmi bs 0 (Zknd)
    expect_trap 0xE2C58533, 2       # aes32esi bs 3 (Zkne)
    expect_trap 0x30C58533, 2       # sm4ed bs 0 (Zksed)
    expect_trap 0x34C58533, 2       # sm4ks bs 0 (Zksed)
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
