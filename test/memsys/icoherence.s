# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: icoherence.s
#
# ------------------------------------------------------------------------------------------------
# |                                                                                              |
# | INSTRUCTION-STREAM COHERENCE, for the memory-system checks (test/memsys/programs.py).        |
# |                                                                                              |
# | Code is data in this system: one RAM holds both, and a store can rewrite an instruction.     |
# | After a store to code and a FENCE.I, the next fetch of the stored-to word must return the    |
# | new instruction, also when that word was fetched and executed before the store (and could    |
# | be held in an instruction cache) and when it was fetched just before (and could be held in   |
# | the pipeline).                                                                               |
# |                                                                                              |
# | Case 2: a block of eight instructions (blk) that starts on a 16-byte boundary, so that its   |
# |         words 0-3 lie in one 16-byte line and words 4-7 in the next, runs; then              |
# |         - words 0, 1 and 2 (one line) are patched with sw, sh and sb, FENCE.I, it runs,      |
# |         - words 3, 4 and 5 (across the line boundary) with sb, sh and sw, FENCE.I, it runs,  |
# |         - the six words are written back, FENCE.I, it runs;                                  |
# |         each run checks a0. sh and sb change only an immediate field: the new encodings      |
# |         (alt_*) equal the old ones outside the stored bytes. Each patched word is read back. |
# | Case 3: the two words right behind a FENCE.I are stored to (sw, then sh) before it, when     |
# |         they may already have been fetched: first with their own encodings, so that they     |
# |         run once unchanged, then with new ones; after the FENCE.I the new code must run.     |
# |         Each stored word is read back. Then they are written back for the next pass.         |
# | Both cases run with the branch predictor off (mode 0) and in mode 3 (the golden CPU ignores  |
# | the mode). The expected values were computed with an independent instruction-set model.      |
# | The reports are the same at every latency.                                                   |
# |                                                                                              |
# | Register allocation:                                                                         |
# |     x5  (t0):   reserved for macro use                                                       |
# |     x6  (t1):   1 (the value a failed check writes)                                          |
# |     x7  (t2):   test case number                                                             |
# |     x28 (t3):   test peripheral address                                                      |
# |     s1: blk                 s2: blk_copy (the original words)   s3: alt_* (the new words)    |
# |     s4: branch-predictor mode           a0-a5: data             t4, t5, t6: scratch          |
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

.macro li32 reg:req, value:req
    lui  \reg, %hi(\value)
    addi \reg, \reg, %lo(\value)
.endm

.option norelax

# a0 and a1 before each run of blk, and a0 after it: the original block, after the patches of
# words 0-2, after the patches of words 3-5
.equ BLK_A0, 0x2468ACE0
.equ BLK_A1, 0x01234567
.equ EXP_ORIG, 0x258C0348
.equ EXP_LINE, 0xDDDDEC6E
.equ EXP_CROSS, 0x1B4E77EF
# a2 after the two words of case 3: the original ones, the patched ones
.equ EXP_NEXT_ORIG, 0x00C10547
.equ EXP_NEXT, 0x006246D0

# ------------------------------------------------------------------------------------------------
# |                                          Test entry!                                         |
# ------------------------------------------------------------------------------------------------
.global __reset
__reset:

test_init:
    addi t1, zero, 1
    addi t2, zero, 0
    lui  t3, %hi(0x120000<<2)
    addi t3, t3, %lo(0x120000<<2)
    li32 s1, blk
    li32 s2, blk_copy
    li32 s3, alt_w0
    addi s4, zero, 0               # branch-predictor mode 0, then 3

# Deliberate first failure: proves the assert macro and the test peripheral work.
test_fail:
    addi t2, zero, 1
    assert_value zero, 1

test_mode:
    csrw 0x32A, s4                 # MHPMEVENT10: branch-predictor mode
    jal  zero, test_block

# The block that case 2 patches (16-byte aligned: words 0-3 and 4-7 are two lines)
.balign 16
blk:
    addi a0, a0, 0x101             # word 0: sw
    xori a0, a0, 0x202             # word 1: sh of bytes 2-3
    addi a0, a0, 0x303             # word 2: sb of byte 3
    xori a0, a0, 0x404             # word 3: sb of byte 3 (last word of the line)
    addi a0, a0, 0x505             # word 4: sh of bytes 2-3 (first word of the next line)
    xori a0, a0, 0x606             # word 5: sw
    add  a0, a0, a1
    jalr zero, 0(ra)

# -----------------------------------------------
# Case 2: run blk; patch words 0-2 (one line), run; patch words 3-5 (across the line boundary),
# run; write the six words back, run.
test_block:
    addi t2, zero, 2
    li32 a0, BLK_A0
    li32 a1, BLK_A1
    jal  ra, blk
    assert_value a0, EXP_ORIG

    lw   t4, 0(s3)                 # alt_w0
    sw   t4, 0(s1)
    lhu  t4, 6(s3)                 # alt_w1, bytes 2-3
    sh   t4, 6(s1)
    lbu  t4, 11(s3)                # alt_w2, byte 3
    sb   t4, 11(s1)
    fence.i
    li32 a0, BLK_A0
    jal  ra, blk
    assert_value a0, EXP_LINE

    lbu  t4, 15(s3)                # alt_w3, byte 3
    sb   t4, 15(s1)
    lhu  t4, 18(s3)                # alt_w4, bytes 2-3
    sh   t4, 18(s1)
    lw   t4, 20(s3)                # alt_w5
    sw   t4, 20(s1)
    fence.i
    li32 a0, BLK_A0
    jal  ra, blk
    assert_value a0, EXP_CROSS

    addi a2, zero, 0               # the patched words are the new encodings
    addi t5, zero, 24
1:
    add  t4, s1, a2
    lw   t4, 0(t4)
    add  t6, s3, a2
    lw   t6, 0(t6)
    assert_equal t4, t6
    addi a2, a2, 4
    bne  a2, t5, 1b

    addi a2, zero, 0               # write the original words back
2:
    add  t4, s2, a2
    lw   t4, 0(t4)
    add  t6, s1, a2
    sw   t4, 0(t6)
    addi a2, a2, 4
    bne  a2, t5, 2b
    fence.i
    li32 a0, BLK_A0
    jal  ra, blk
    assert_value a0, EXP_ORIG

# -----------------------------------------------
# Case 3: store to the two words behind a FENCE.I (sw, sh) before it, run them and read them
# back: first their original words (so that they have run before), then the new ones.
test_next:
    addi t2, zero, 3
    li32 t5, next_w0
    addi a4, s2, 24                # the original words (in blk_copy)
    addi a5, s3, 24                # the new words (alt_n0)
    li32 a3, EXP_NEXT_ORIG
3:
    lw   t4, 0(a4)
    lhu  t6, 6(a4)
    li32 a2, 0x00C0FFEE
    sw   t4, 0(t5)
    sh   t6, 6(t5)
    fence.i
next_w0:
    addi a2, a2, 0x123             # sw: becomes alt_n0
    xori a2, a2, 0x456             # sh of bytes 2-3: becomes alt_n1
    assert_equal a2, a3
    lw   t4, 0(t5)
    lw   t6, 0(a4)
    assert_equal t4, t6
    lw   t4, 4(t5)
    lw   t6, 4(a4)
    assert_equal t4, t6
    beq  a4, a5, 4f                # the new words have run
    mv   a4, a5
    li32 a3, EXP_NEXT
    jal  zero, 3b
4:
    lw   t4, 24(s2)                # write the original words back (for the next pass)
    lw   t6, 28(s2)
    sw   t4, 0(t5)
    sw   t6, 4(t5)
    fence.i

    addi s4, s4, 3
    addi t4, zero, 6
    bne  s4, t4, test_mode

# ------------------------------------------------------------------------------------------------
# |                                          Test done!                                          |
# ------------------------------------------------------------------------------------------------
test_finish:
    csrwi 0x32A, 0
    addi t2, zero, 9
    halt
    fail

# Never executed: the original words of blk (words 0-5) and of next_w0 (2 words), and the
# words the patches write
.balign 4
blk_copy:
    addi a0, a0, 0x101
    xori a0, a0, 0x202
    addi a0, a0, 0x303
    xori a0, a0, 0x404
    addi a0, a0, 0x505
    xori a0, a0, 0x606
    addi a2, a2, 0x123
    xori a2, a2, 0x456
alt_w0:
    sub  a0, a1, a0                # replaces word 0 (sw)
    xori a0, a0, 0x2D2             # word 1: imm 0x202 -> 0x2D2 (sh of bytes 2-3)
    addi a0, a0, 0x5A3             # word 2: imm 0x303 -> 0x5A3 (sb of byte 3)
    xori a0, a0, -0x7FC            # word 3: imm 0x404 -> 0x804 (sb of byte 3)
    addi a0, a0, -0x1AB            # word 4: imm 0x505 -> 0xE55 (sh of bytes 2-3)
    slli a0, a0, 3                 # replaces word 5 (sw)
    sub  a2, a1, a2                # replaces next_w0 (sw)
    xori a2, a2, 0x3A9             # next_w0 + 4: imm 0x456 -> 0x3A9 (sh of bytes 2-3)
