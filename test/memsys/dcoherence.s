# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: dcoherence.s
#
# ------------------------------------------------------------------------------------------------
# |                                                                                              |
# | CODE AND DATA CACHES TOGETHER, for the memory-system checks (test/memsys/programs.py). The   |
# | words of a block of code are read as data (so that a data cache holds them next to an        |
# | instruction cache that holds them as code), patched by stores, and run after FENCE.I. The    |
# | data cache is write-through and the instruction cache snoops the stores it acknowledges, so  |
# | the next fetch of a patched word must return the new instruction and the next load the new   |
# | word, whichever cache held the line, and whether the store found the line (a hit) or not     |
# | (a miss, which allocates nothing). The program gives the same reports on the standard build, |
# | at every latency and with or without caches: icoherence.s (unchanged) is the program for the |
# | instruction cache alone.                                                                     |
# |                                                                                              |
# | The block blk is four instructions in one 64-byte-aligned line:                              |
# |     word 0  addi a0, a0, 0x111        patched by sw      to  addi a0, a0, 0x444              |
# |     word 1  xori a0, a0, 0x222        patched by sh      to  xori a0, a0, 0x2D2 (bytes 2-3)  |
# |     word 2  addi a0, a0, 0x333        patched by sb      to  addi a0, a0, 0x5A3 (byte 3)     |
# |     word 3  jalr zero, 0(ra)          not patched                                            |
# | With a0 = 0x2468ACE0 it leaves 0x2468B306, patched 0x2468B999 (computed with an independent  |
# | model, not by the assembler). Each variant below runs it, reads the four words back as data, |
# | patches three of them, runs FENCE.I, runs it again, reads the words back, writes the         |
# | originals back, runs FENCE.I, runs it and reads the words back; each run and each read is    |
# | checked:                                                                                     |
# |   Case 2  the line is first read as data (the data cache holds it), then patched: three      |
# |           store hits. The reads after the patch are hits.                                    |
# |   Case 3  the line is read as data, then evicted from the data cache by a load of the word   |
# |           4 KiB after it (the same set in a 512-byte and in a 4 KiB cache), then patched:    |
# |           three store misses, which must allocate nothing; the read that follows misses.     |
# |           The originals are also written back to an evicted line.                            |
# |   Case 4  the line is read as data, patched (store hits), then evicted by a conflicting load |
# |           before FENCE.I: the instruction cache's refill and the reload of the words read the|
# |           RAM, which must hold the stores (the cache is write-through).                      |
# |   Case 5  a data word in the line of code: the line is read as data, the data word is stored |
# |           to (a store hit, and the instruction cache's snoop drops its copy of the line), and|
# |           the code runs again without FENCE.I with its original result; the code words read  |
# |           as data are the originals.                                                         |
# | Every case runs with the branch predictor off (mode 0) and in mode 3 (the golden CPU ignores |
# | the mode).                                                                                   |
# |                                                                                              |
# | Expected with a D-cache, from the assembled program (16-byte lines; a trace of the standard  |
# | build replayed through the direct-mapped model of cachemodel.py and through a second model,  |
# | which agree; a 512-byte and a 4 KiB D-cache give the same figures): CACHE_STATS              |
# | dc_load_misses is at least 14, dc_store_hits at least 28 and dc_store_misses at least 12     |
# | (86 loads and 40 stores reach the D-cache).                                                  |
# |                                                                                              |
# | Register allocation:                                                                         |
# |     x5  (t0):   reserved for macro use                                                       |
# |     x6  (t1):   1 (the value a failed check writes)                                          |
# |     x7  (t2):   test case number                                                             |
# |     x28 (t3):   test peripheral address                                                      |
# |     s1: blk     s2: differences found by a read       s4: branch-predictor mode              |
# |     a0: the data of the code under test    t4, t5, t6: scratch    ra: return address         |
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

# The words of blk and of its patches (addi a0, a0, imm: imm << 20 | 0x00050513; xori: ... 0x00054513)
.equ W0, 0x11150513
.equ W1, 0x22254513
.equ W2, 0x33350513
.equ W3, 0x00008067
.equ N0, 0x44450513            # the patched words (word 3 stays)
.equ N1, 0x2D254513
.equ N2, 0x5A350513
# a0 before and after blk: the original code, the patched code
.equ A0,       0x2468ACE0
.equ EXP_ORIG, 0x2468B306
.equ EXP_NEW,  0x2468B999
# case 5: the code next to a data word: a0 before and after, its words, the data word
.equ D_A0,    0x0BADBEEF
.equ D_EXP,   0x0BADC246
.equ D_W0,    0x35750513       # addi a0, a0, 0x357
.equ D_DATA,  0x600DF00D
.equ D_NEW,   0x0D15EA5E

# The word 4 KiB after blk: a load of it evicts blk's line from a data cache of 512 bytes or 4 KiB
.equ FAR, 0x1000

# a0 = A0, run blk, a0 must be \want
.macro run_blk want:req
    li32 a0, A0
    jal  ra, blk
    assert_value a0, \want
.endm

# the four words of blk, read as data, must be \e0 .. \e3
.macro read_blk e0:req, e1:req, e2:req, e3:req
    lw   t4, 0(s1)
    li32 t5, \e0
    xor  s2, t4, t5
    lw   t4, 4(s1)
    li32 t5, \e1
    xor  t4, t4, t5
    or   s2, s2, t4
    lw   t4, 8(s1)
    li32 t5, \e2
    xor  t4, t4, t5
    or   s2, s2, t4
    lw   t4, 12(s1)
    li32 t5, \e3
    xor  t4, t4, t5
    or   s2, s2, t4
    assert_value s2, 0
.endm

.macro evict_blk
    li32 t5, blk + FAR
    lw   t4, 0(t5)
.endm

.macro patch_blk
    li32 t4, N0
    sw   t4, 0(s1)                 # a whole word
    li32 t4, N1 >> 16
    sh   t4, 6(s1)                 # bytes 2-3 of word 1
    li32 t4, N2 >> 24
    sb   t4, 11(s1)                # byte 3 of word 2
.endm

.macro unpatch_blk
    li32 t4, W0
    sw   t4, 0(s1)
    li32 t4, W1
    sw   t4, 4(s1)
    li32 t4, W2
    sw   t4, 8(s1)
.endm

# one variant: \v = 0 patch a present line, 1 patch an evicted line (and write back to an evicted
# line), 2 evict the line after the patch, before FENCE.I
.macro variant v:req
    run_blk EXP_ORIG
    read_blk W0, W1, W2, W3        # the data cache now holds the line
    .if \v == 1
    evict_blk
    .endif
    patch_blk
    .if \v == 2
    evict_blk
    .endif
    fence.i
    run_blk EXP_NEW
    read_blk N0, N1, N2, W3
    .if \v == 1
    evict_blk
    .endif
    unpatch_blk
    fence.i
    run_blk EXP_ORIG
    read_blk W0, W1, W2, W3
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
    addi s4, zero, 0               # branch-predictor mode 0, then 3

# Deliberate first failure: proves the assert macro and the test peripheral work.
test_fail:
    addi t2, zero, 1
    assert_value zero, 1

test_mode:
    csrw 0x32A, s4                 # MHPMEVENT10: branch-predictor mode
    jal  zero, test_cases

# The block that the cases patch: four instructions, one 64-byte-aligned line
.balign 64
blk:
    addi a0, a0, 0x111
    xori a0, a0, 0x222
    addi a0, a0, 0x333
    jalr zero, 0(ra)
    .space 48

# Case 5's code and data in one line
.balign 64
dline:
    addi a0, a0, 0x357
    jalr zero, 0(ra)
dline_data:
    .word D_DATA
    .word 0
    .space 48

test_cases:
    addi t2, zero, 2
    variant 0
    addi t2, zero, 3
    variant 1
    addi t2, zero, 4
    variant 2

# -----------------------------------------------
# Case 5: a data word in the line of code
    addi t2, zero, 5
    li32 s1, dline
    li32 a0, D_A0
    jal  ra, dline
    assert_value a0, D_EXP
    lw   t4, 8(s1)                 # the data word: the data cache holds the line, code words included
    assert_value t4, D_DATA
    li32 t4, D_NEW
    sw   t4, 8(s1)                 # a store hit into the line of code (the instruction cache drops its copy)
    lw   t5, 8(s1)
    assert_equal t5, t4
    li32 a0, D_A0
    jal  ra, dline                 # the same code, without FENCE.I
    assert_value a0, D_EXP
    lw   t4, 0(s1)
    assert_value t4, D_W0
    lw   t4, 4(s1)
    assert_value t4, W3
    li32 t4, D_DATA
    sw   t4, 8(s1)                 # for the next pass
    li32 s1, blk

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
