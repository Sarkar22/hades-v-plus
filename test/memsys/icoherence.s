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
# | Case 4: case 2 again, with the block evicted from an instruction cache before every patch    |
# |         (run, evict, patch, FENCE.I, run): the patched lines are not cached when the stores  |
# |         come, and the refill after the FENCE.I must read the new words.                      |
# | Case 5: case 3 again, with the two words' line evicted before the stores of the new words.   |
# | Case 6: a store to the word 512 bytes after a cached code line (the line's index in a        |
# |         512-byte direct-mapped cache, another tag) and to the word 8 KiB after it (the       |
# |         line's index in a 512-byte and in an 8 KiB cache); the code then runs again without  |
# |         FENCE.I and must give its original result.                                           |
# | Case 7: a store to a data word in the same 16-byte line as code; the code runs again without |
# |         FENCE.I and must give its original result (the line is invalidated and refilled).    |
# | Case 8: two blocks exactly 512 bytes apart and two exactly 8 KiB apart (a conflict in a      |
# |         512-byte, resp. in an 8 KiB, direct-mapped cache): run A, run B, patch A, FENCE.I,   |
# |         run A (new), run B (old), then A is written back.                                    |
# | Case 9: a store to word 0 of the next line, from word 0 of the line before: the store's      |
# |         acknowledgement and the first fetch of the stored-to line fall in adjacent cycles at |
# |         latency 0. It runs first with the original word (so that both lines have run), then  |
# |         with a new one, which must run without FENCE.I: the stored-to word is the fourth     |
# |         instruction after the store, beyond the three-slot staleness window                  |
# |         (docs/EXTENSIONS.md, Zifencei).                                                      |
# | Case 10: eight stores in consecutive instructions, each to word 0 of another cached code     |
# |         line, then FENCE.I and a run of all eight lines: first with the original words       |
# |         (which also brings the stores and what follows them into a cache), then with new     |
# |         ones, then the originals again. At latency 0 with a cache their acknowledgements     |
# |         fall in eight consecutive cycles.                                                    |
# | Cases 6 to 10 lie at fixed addresses from 0x41000 (cases 6 to 8 need free words 512 bytes    |
# | and 8 KiB away from their code). Every case runs with the branch predictor off (mode 0) and  |
# | in mode 3 (the golden CPU ignores the mode). The expected values were computed with an       |
# | independent instruction-set model. The reports are the same at every latency.                |
# |                                                                                              |
# | EVICTION STEPS (cases 4 and 5): evict_blk and evict_next are blocks placed exactly 8 KiB     |
# | (0x2000 bytes) after the code they evict, so that their lines have that code's indexes in a  |
# | 512-byte and in an 8 KiB direct-mapped cache (evict_block below).                            |
# |                                                                                              |
# | Expected with a cache, from the assembled program: CACHE_STATS snoop_inval is at least 74    |
# | with a 512-byte cache and at least 78 with an 8 KiB cache (16-byte lines): the stores that   |
# | find their line valid by construction, in both modes (case 2: 5, case 3: 2, case 5: 1, case  |
# | 7: 2, case 9: 3, case 10: 24 per mode, and in the 8 KiB cache also case 8: 2 per mode, whose |
# | block A the 512-byte cache has already evicted).                                             |
# |                                                                                              |
# | Register allocation:                                                                         |
# |     x5  (t0):   reserved for macro use                                                       |
# |     x6  (t1):   1 (the value a failed check writes)                                          |
# |     x7  (t2):   test case number                                                             |
# |     x28 (t3):   test peripheral address                                                      |
# |     s1: blk                 s2: blk_copy (the original words)   s3: alt_* (the new words)    |
# |     s4: branch-predictor mode           a0-a5: data             t4, t5, t6: scratch          |
# |     s5: 0 = cached variant (cases 2, 3), 1 = evicted variant (cases 4, 5)                    |
# |     ra: return address (blocks, eviction steps)                                              |
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
# a0 before and after the code of cases 6 and 7; a0 before and after A, A (new), B, A2, A2 (new),
# B2 of case 8; a0 before and after the eight lines of case 10 (original words, new words)
.equ SIDX_A0, 0x13572468
.equ EXP_SIDX, 0x135727DB
.equ DLINE_A0, 0x0BADBEEF
.equ EXP_DLINE, 0x0BADC246
.equ APART_A0, 0x01020304
.equ EXP_APART_A, 0x01020415
.equ EXP_APART_ANEW, 0x010205A6
.equ EXP_APART_B, 0x01020637
.equ EXP_APART_A2, 0x01020748
.equ EXP_APART_A2NEW, 0x01020859
.equ EXP_APART_B2, 0x0102096A
.equ EIGHT_A0, 0x00FF00FF
.equ EXP_EIGHT_ORIG, 0x00FF0207
.equ EXP_EIGHT_NEW, 0x00FF038F

# Eviction step: evict_block <lines> fills <lines> 16-byte lines, for code placed exactly 8 KiB
# before it (see the header). It is entered with 'jal ra, <block> + 12' and returns to ra. Every
# even line k holds three nops and, at word 3, a jal to word 3 of line k + 2 (the last one returns
# with jalr): one instruction runs per two lines. The jal resolves in Execute, so Fetch presents
# word 0 of line k + 1 on the wrong path before the target, and a cache refills that line too (a
# started refill always completes). The other words are nops that never run.
.macro evict_block lines:req
    .set evict_k, 0
    .rept (\lines + 1) / 2
    nop
    nop
    nop
    .if evict_k + 2 < \lines
    jal  zero, . + 32
    .else
    jalr zero, 0(ra)
    .endif
    nop
    nop
    nop
    nop
    .set evict_k, evict_k + 2
    .endr
.endm

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
    addi s5, zero, 0               # cases 2 and 3 first, then 4 and 5
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
# Case 2 (s5 = 0): run blk; patch words 0-2 (one line), run; patch words 3-5 (across the line
# boundary), run; write the six words back, run. Case 4 (s5 = 1): the same, with blk evicted
# before every patch.
test_block:
    slli t2, s5, 1
    addi t2, t2, 2                 # 2 or 4
    li32 a0, BLK_A0
    li32 a1, BLK_A1
    jal  ra, blk
    assert_value a0, EXP_ORIG

    beq  s5, zero, 7f
    jal  ra, evict_blk + 12        # eviction step
7:
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

    beq  s5, zero, 7f
    jal  ra, evict_blk + 12        # eviction step
7:
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

    beq  s5, zero, 7f
    jal  ra, evict_blk + 12        # eviction step
7:
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
# Case 3 (s5 = 0): store to the two words behind a FENCE.I (sw, sh) before it, run them and read
# them back: first their original words (so that they have run before), then the new ones. Case 5
# (s5 = 1): the same, with their line evicted before the stores of the new words.
test_next:
    slli t2, s5, 1
    addi t2, t2, 3                 # 3 or 5
    li32 t5, next_w0
    addi a4, s2, 24                # the original words (in blk_copy)
    addi a5, s3, 24                # the new words (alt_n0)
    li32 a3, EXP_NEXT_ORIG
    jal  zero, 3f
.balign 16
    nop                            # (never runs: puts next_w0 at word 0 of a line)
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
    beq  s5, zero, 3b
    jal  ra, evict_next + 12       # eviction step
    jal  zero, 3b
4:
    lw   t4, 24(s2)                # write the original words back (for the next pass)
    lw   t6, 28(s2)
    sw   t4, 0(t5)
    sw   t6, 4(t5)
    fence.i
    bne  s5, zero, 8f
    addi s5, zero, 1               # cases 4 and 5
    jal  zero, test_block
8:
    jal  zero, test_far            # cases 6 to 10
test_far_done:

    addi s4, s4, 3
    addi t4, zero, 6
    bne  s4, t4, test_mode

# ------------------------------------------------------------------------------------------------
# |                                          Test done!                                          |
# ------------------------------------------------------------------------------------------------
test_finish:
    csrwi 0x32A, 0
    addi t2, zero, 11
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
apart_words:                       # case 8: A and A2, original and new
    addi a0, a0, 0x111
    addi a0, a0, 0x2A2
    addi a0, a0, 0x444
    addi a0, a0, 0x555
adj_words:                         # case 9: adj_next, original and new
    addi a2, a2, 0x100
    addi a2, a2, 0x200
eight_words:                       # case 10: word 0 of every line, original and new
    addi a0, a0, 0x11
    addi a0, a0, 0x22

# ------------------------------------------------------------------------------------------------
# |              Cases 6 to 10, at fixed addresses (free words 512 bytes and 8 KiB away)          |
# ------------------------------------------------------------------------------------------------

# -----------------------------------------------
# Case 6: stores with the index of a cached code line and another tag (512 bytes and 8 KiB after
# it); the code is unchanged and runs again without FENCE.I.
.org 0x1000
sidx:                              # one line, 0x41000
    addi a0, a0, 0x135
    xori a0, a0, 0x246
    jalr zero, 0(ra)
    nop
test_far:
    addi t2, zero, 6
    li32 a0, SIDX_A0
    jal  ra, sidx
    assert_value a0, EXP_SIDX
    li32 t6, 0x5A5AA5A5
    li32 t4, sidx_512
    sw   t6, 0(t4)                 # the same index in a 512-byte cache
    lw   t5, 0(t4)
    assert_equal t5, t6
    li32 t4, sidx_8k
    sw   t6, 0(t4)                 # the same index in an 8 KiB cache
    lw   t5, 0(t4)
    assert_equal t5, t6
    li32 a0, SIDX_A0
    jal  ra, sidx                  # unchanged
    assert_value a0, EXP_SIDX
    jal  zero, test_dataline

.org 0x1200
sidx_512:                          # sidx + 512 bytes: never runs
    .word 0

# -----------------------------------------------
# Case 7: a data word in the line of code is stored to; the code runs again without FENCE.I.
.org 0x1240
dline:
    addi a0, a0, 0x357
    jalr zero, 0(ra)
dline_data:                        # data in the same 16-byte line
    .word 0x600DF00D
    .word 0
test_dataline:
    addi t2, zero, 7
    li32 a0, DLINE_A0
    jal  ra, dline
    assert_value a0, EXP_DLINE
    li32 t4, dline_data
    li32 t6, 0x0D15EA5E
    sw   t6, 0(t4)                 # the line is invalidated (a cache refills it)
    lw   t5, 0(t4)
    assert_equal t5, t6
    li32 a0, DLINE_A0
    jal  ra, dline                 # the same code
    assert_value a0, EXP_DLINE
    li32 t6, 0x600DF00D
    sw   t6, 0(t4)                 # the original data word back
    jal  zero, test_apart

# -----------------------------------------------
# Case 8: A and B exactly 512 bytes apart, A2 and B2 exactly 8 KiB apart: run A, run B, patch A,
# FENCE.I, run A (new), run B (old); then A is written back.
.org 0x1420
apart_a:
    addi a0, a0, 0x111             # patched: 0x111 -> 0x2A2
    jalr zero, 0(ra)
test_apart:
    addi t2, zero, 8
    li32 t5, apart_words
    li32 t4, apart_a
    li32 a0, APART_A0
    jal  ra, apart_a
    assert_value a0, EXP_APART_A
    li32 a0, APART_A0
    jal  ra, apart_b               # in a 512-byte cache B evicts A
    assert_value a0, EXP_APART_B
    lw   t6, 4(t5)
    sw   t6, 0(t4)                 # A, new
    fence.i
    li32 a0, APART_A0
    jal  ra, apart_a
    assert_value a0, EXP_APART_ANEW
    li32 a0, APART_A0
    jal  ra, apart_b
    assert_value a0, EXP_APART_B
    lw   t6, 0(t5)
    sw   t6, 0(t4)                 # A, original
    fence.i
    li32 a0, APART_A0
    jal  ra, apart_a
    assert_value a0, EXP_APART_A
    jal  zero, test_apart2

.org 0x1620
apart_b:                           # apart_a + 512 bytes
    addi a0, a0, 0x333
    jalr zero, 0(ra)

.org 0x1840
apart_a2:
    addi a0, a0, 0x444             # patched: 0x444 -> 0x555
    jalr zero, 0(ra)
test_apart2:
    li32 t4, apart_a2
    li32 a0, APART_A0
    jal  ra, apart_a2
    assert_value a0, EXP_APART_A2
    li32 a0, APART_A0
    jal  ra, apart_b2              # in an 8 KiB (and a 512-byte) cache B2 evicts A2
    assert_value a0, EXP_APART_B2
    lw   t6, 12(t5)
    sw   t6, 0(t4)                 # A2, new
    fence.i
    li32 a0, APART_A0
    jal  ra, apart_a2
    assert_value a0, EXP_APART_A2NEW
    li32 a0, APART_A0
    jal  ra, apart_b2
    assert_value a0, EXP_APART_B2
    lw   t6, 8(t5)
    sw   t6, 0(t4)                 # A2, original
    fence.i
    li32 a0, APART_A0
    jal  ra, apart_a2
    assert_value a0, EXP_APART_A2
    jal  zero, test_adjacent

# -----------------------------------------------
# Case 9: the store from word 0 of a line to word 0 of the next one (the fourth instruction after
# it): first the original word, then a new one, which must run without FENCE.I; then the original
# word back.
.org 0x1A00
adj_store:
    sw   t4, 16(a4)                # word 0: stores to adj_next
    addi a2, a2, 1
    addi a2, a2, 2
    addi a2, a2, 4
adj_next:                          # word 0 of the next line
    addi a2, a2, 0x100             # rewritten: 0x100 -> 0x200
    jalr zero, 0(ra)
test_adjacent:
    addi t2, zero, 9
    li32 a4, adj_store
    li32 t5, adj_words
    lw   t4, 0(t5)                 # the original word: both lines run (and are cached)
    addi a2, zero, 0
    jal  ra, adj_store
    assert_value a2, 0x107
    lw   t4, 4(t5)                 # the new word
    addi a2, zero, 0
    jal  ra, adj_store
    assert_value a2, 0x207
    lw   t6, 16(a4)
    assert_equal t6, t4
    lw   t4, 0(t5)                 # the original word back
    sw   t4, 16(a4)
    fence.i
    addi a2, zero, 0
    jal  ra, adj_store
    assert_value a2, 0x107
    jal  zero, test_eight

# -----------------------------------------------
# Case 10: eight stores in consecutive instructions (store_eight), each to word 0 of another line of
# eight, then FENCE.I and a run of the eight lines: the original words, the new ones, the
# original ones again.
.org 0x1C00
eight:                             # eight lines: a0 = (a0 + word 0's immediate) ^ (16 * line)
    .set eight_k, 1
    .rept 8
    addi a0, a0, 0x11              # word 0: 0x11 -> 0x22
    xori a0, a0, 16 * eight_k
    nop
    nop
    .set eight_k, eight_k + 1
    .endr
    jalr zero, 0(ra)
test_eight:
    addi t2, zero, 10
    li32 a4, eight
    li32 t5, eight_words
    li32 a0, EIGHT_A0
    jal  ra, eight                 # the eight lines run (and are cached)
    assert_value a0, EXP_EIGHT_ORIG
    lw   t4, 0(t5)                 # the original word
    jal  ra, store_eight
    fence.i
    li32 a0, EIGHT_A0
    jal  ra, eight
    assert_value a0, EXP_EIGHT_ORIG
    lw   t4, 4(t5)                 # the new word
    jal  ra, store_eight
    fence.i
    li32 a0, EIGHT_A0
    jal  ra, eight
    assert_value a0, EXP_EIGHT_NEW
    lw   t4, 0(t5)                 # the original word back
    jal  ra, store_eight
    fence.i
    li32 a0, EIGHT_A0
    jal  ra, eight
    assert_value a0, EXP_EIGHT_ORIG
    jal  zero, test_far_done
.balign 16
store_eight:                       # eight stores in consecutive instructions
    sw   t4, 0(a4)
    sw   t4, 16(a4)
    sw   t4, 32(a4)
    sw   t4, 48(a4)
    sw   t4, 64(a4)
    sw   t4, 80(a4)
    sw   t4, 96(a4)
    sw   t4, 112(a4)
    jalr zero, 0(ra)

# ------------------------------------------------------------------------------------------------
# The eviction blocks, exactly 8 KiB after the code they evict, and the far words of cases 6 and 8
.org blk - __reset + 0x2000
evict_blk:
    evict_block 2
.org next_w0 - __reset + 0x2000
evict_next:
    evict_block 1
.org 0x3000
sidx_8k:                           # sidx + 8 KiB: never runs
    .word 0
.org 0x3840
apart_b2:                          # apart_a2 + 8 KiB
    addi a0, a0, 0x666
    jalr zero, 0(ra)
