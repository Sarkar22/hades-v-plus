# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: dcache.s
#
# ------------------------------------------------------------------------------------------------
# |                                                                                              |
# | DATA ACCESSES, for the memory-system checks (test/memsys/programs.py), written for a         |
# | simulator with a data cache (make ICACHE=512 DCACHE=512 or ICACHE=8192 DCACHE=4096; the      |
# | cache is write-through and never allocates on a store miss, docs/CACHES.md) and independent  |
# | of the memory's timing: it gives the same reports on the standard build, at every latency,   |
# | with or without a cache, and on the golden CPU. Every load that follows a store checks the   |
# | whole line, so the program also finds a store that lands in the wrong line, the wrong lanes  |
# | or only in the cache or only in the RAM, with the scoreboard switched off (test/memsys/      |
# | mutants.py runs it that way).                                                                |
# |                                                                                              |
# | The words of a line hold the patterns P0 to P3 (all bytes different, the high bit set in     |
# | some). Each case below stores SV = 0x9ABCDEF1 into one of them and reads the four words back |
# | with lw, lbu, lb, lhu and lh at every lane and halfword (rb_word, 13 loads of a word), so    |
# | that the lanes written and the lanes kept are both checked. The value of the other bytes of  |
# | the store register (SV's upper bytes, which sb and sh do not store) differs from every byte  |
# | of P0 to P3, so a store that writes more lanes than it selects changes a word that must      |
# | not change.                                                                                  |
# |                                                                                              |
# | Case 2: seven stores (sb at offsets 0 to 3, sh at 0 and 2, sw), each into an ABSENT line: the|
# |         line was initialised by sw (RAM only, a store miss) and has not been loaded. The     |
# |         store miss writes the RAM and allocates nothing: the first load of the line misses   |
# |         and must return the RAM's words (a cache that allocated on the store would return    |
# |         its own, partly random, words).                                                      |
# | Case 3: the same seven stores into a PRESENT line (a load of the line first): the store hit  |
# |         writes the selected lanes of the line and the RAM; the loads that follow hit; then   |
# |         a load 4 KiB away (the same set in a 512-byte and in a 4 KiB cache) evicts the line  |
# |         and the loads that follow it return what the RAM holds.                              |
# | Case 4: lines 4 KiB apart, loads and stores alternated: a store miss into the set of a       |
# |         present line, then a load of that line (the store must not have touched it); a store |
# |         hit, an eviction by the other line and a reload.                                     |
# | Case 5: a store to a code line (the line has not been read as data), FENCE.I, the code runs; |
# |         then the code is read as data, stored to again (a store hit), FENCE.I and run.       |
# |                                                                                              |
# | Expected with a D-cache, from the assembled program (16-byte lines; a trace of the standard  |
# | build replayed through the direct-mapped model of cachemodel.py and through a second model,  |
# | which agree; the data lines never conflict except by design, so a 512-byte and a 4 KiB       |
# | D-cache give the same figures): CACHE_STATS dc_load_misses is at least 38, dc_store_hits at  |
# | least 10 and dc_store_misses at least 73 (1130 loads and 83 stores reach the D-cache).       |
# |                                                                                              |
# | Register allocation:                                                                         |
# |     x5  (t0):   reserved for macro use                                                       |
# |     x6  (t1):   1 (the value a failed check writes)                                          |
# |     x7  (t2):   test case number                                                             |
# |     x28 (t3):   test peripheral address                                                      |
# |     s1: differences found by rb_word (OR of XORs)     s2: address of the line being read     |
# |     a1: address of the word that rb_word reads        a2: the word that it expects           |
# |     t4, t5, t6: scratch    ra: return address (rb_word, init_line, the code of case 5)       |
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

# The data area: unused RAM above the program (the program is smaller than 0x4000 bytes)
.equ DATA0,   0x44000
.equ FAR,     0x1000           # a word 4 KiB away: the same set in a 512-byte and in a 4 KiB cache
.equ PAIR_A,  0x44400          # the pair of case 4: A, and B = A + FAR
.equ PAIR_B,  0x45400

# The patterns of a line, and the stored value (its upper bytes are not stored by sb and sh)
.equ P0, 0x8D7C6B5A
.equ P1, 0x1E2F3D4C
.equ P2, 0xF0E1D2C3
.equ P3, 0x0A1B2C3D
.equ SV, 0x9ABCDEF1
# The second line of case 4 holds other patterns
.equ DCW0, 0x31415926
.equ DCW1, 0xA7B6C5D4
.equ DCW2, 0x0F1E2D3C
.equ DCW3, 0xB1A29384

# ------------------------------------------------------------------------------------------------
# One case: a store of kind \st (sb, sh or sw) at byte offset \off of word \w of a line, nbytes
# wide. \present = 0: the line is absent when stored to; 1: the line is loaded first. The line is
# line number \n of the area (64 bytes apart, so that it is a line of its own whatever the line
# size). Expected values are computed by the assembler: the word that is stored to is
# P ^ ((P ^ (SV << 8*off)) & mask), the others keep their pattern.
# ------------------------------------------------------------------------------------------------
.macro rb4 base:req, e0:req, e1:req, e2:req, e3:req
    li   s1, 0
    li32 s2, \base
    addi a1, s2, 0
    li32 a2, \e0
    jal  ra, rb_word
    addi a1, s2, 4
    li32 a2, \e1
    jal  ra, rb_word
    addi a1, s2, 8
    li32 a2, \e2
    jal  ra, rb_word
    addi a1, s2, 12
    li32 a2, \e3
    jal  ra, rb_word
    assert_value s1, 0
.endm

.macro kcase present:req, st:req, off:req, nbytes:req, w:req, n:req
    .set MASK, (((1 << (8 * \nbytes)) - 1) << (8 * \off)) & 0xFFFFFFFF
    .set SHV,  (SV << (8 * \off)) & 0xFFFFFFFF
    .set E0, P0
    .set E1, P1
    .set E2, P2
    .set E3, P3
    .set PW, P\w
    .set E\w, (PW ^ ((PW ^ SHV) & MASK)) & 0xFFFFFFFF
    li32 s2, DATA0 + 64 * \n
    jal  ra, init_line             # the four words by sw: RAM only, the line is absent
    .if \present
    lw   t4, (4 * \w)(s2)         # the line becomes present
    .endif
    li32 t5, SV
    \st  t5, (4 * \w + \off)(s2)
    rb4  DATA0 + 64 * \n, E0, E1, E2, E3
    .if \present
    li32 t5, DATA0 + 64 * \n + FAR
    lw   t4, 0(t5)                 # a conflicting line evicts it
    rb4  DATA0 + 64 * \n, E0, E1, E2, E3
    .endif
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

# Deliberate first failure: proves the assert macro and the test peripheral work.
test_fail:
    addi t2, zero, 1
    assert_value zero, 1

# -----------------------------------------------
# Case 2: the seven stores into absent lines (lines 0 to 6 of the area)
test_absent:
    addi t2, zero, 2
    kcase 0, sb, 0, 1, 0, 0
    kcase 0, sb, 1, 1, 1, 1
    kcase 0, sb, 2, 1, 2, 2
    kcase 0, sb, 3, 1, 3, 3
    kcase 0, sh, 0, 2, 0, 4
    kcase 0, sh, 2, 2, 1, 5
    kcase 0, sw, 0, 4, 2, 6

# -----------------------------------------------
# Case 3: the seven stores into present lines (lines 7 to 13), each read back twice: from the
# line, then, after an eviction, from the RAM
test_present:
    addi t2, zero, 3
    kcase 1, sb, 0, 1, 1, 7
    kcase 1, sb, 1, 1, 2, 8
    kcase 1, sb, 2, 1, 3, 9
    kcase 1, sb, 3, 1, 0, 10
    kcase 1, sh, 0, 2, 2, 11
    kcase 1, sh, 2, 2, 3, 12
    kcase 1, sw, 0, 4, 0, 13

# -----------------------------------------------
# Case 4: A and B = A + 4 KiB share a set in both cache sizes; word 0 and word 1 of each are
# used. After each step the comment gives what the RAM or the line holds.
test_pair:
    addi t2, zero, 4
    li32 s2, PAIR_A
    jal  ra, init_line             # A: P0..P3 (RAM only)
    li32 s2, PAIR_B
    li32 t4, DCW0
    sw   t4, 0(s2)
    li32 t4, DCW1
    sw   t4, 4(s2)                 # B: DCW0, DCW1 (RAM only)
    li32 s0, PAIR_A
    li32 s2, PAIR_B
    lw   t4, 0(s0)                 # load A0: a miss, A is filled
    assert_value t4, P0
    li32 t5, 0x13572468
    sw   t5, 0(s2)                 # store B0: B is absent and A holds the set: a store miss
    lw   t4, 0(s0)                 # A0 again: a hit, and A is untouched by the store
    assert_value t4, P0
    lw   t4, 4(s0)
    assert_value t4, P1
    lw   t4, 0(s2)                 # load B0: a miss, evicts A; the RAM holds the stored word
    assert_value t4, 0x13572468
    lw   t4, 4(s2)
    assert_value t4, DCW1
    li32 t5, 0x2468ACE0
    sw   t5, 8(s0)                 # store A2: A is absent and B holds the set: a store miss
    lw   t4, 0(s2)                 # B0: a hit, untouched
    assert_value t4, 0x13572468
    lw   t4, 4(s2)
    assert_value t4, DCW1
    lw   t4, 8(s0)                 # load A2: a miss, evicts B
    assert_value t4, 0x2468ACE0
    lw   t4, 0(s0)
    assert_value t4, P0
    li32 t5, 0x000000A7
    sb   t5, 1(s0)                 # A is present: a store hit, byte 1 of A0
    lw   t4, 0(s0)                 # A0: the line holds the new byte
    assert_value t4, 0x8D7CA75A
    lw   t4, 0(s2)                 # load B0: a miss, evicts A
    assert_value t4, 0x13572468
    lw   t4, 0(s0)                 # load A0: a miss, from the RAM, which holds the new byte
    assert_value t4, 0x8D7CA75A
    li32 t5, 0x0000BEEF
    sh   t5, 2(s2)                 # B was evicted by the reload of A: a store miss, bytes 2-3 of B0
    lw   t4, 0(s2)                 # load B0: a miss, evicts A
    assert_value t4, 0xBEEF2468
    li32 t5, 0x600DF00D
    sw   t5, 4(s2)                 # B is present: a store hit, B1
    lw   t4, 4(s2)
    assert_value t4, 0x600DF00D
    lw   t4, 0(s0)                 # load A0: a miss, evicts B
    assert_value t4, 0x8D7CA75A
    lw   t4, 4(s2)                 # load B1: a miss, from the RAM
    assert_value t4, 0x600DF00D
    lw   t4, 0(s2)
    assert_value t4, 0xBEEF2468

# -----------------------------------------------
# Case 5: a store to a code line that has not been read as data (a store miss), FENCE.I, the code
# runs; then the code is read as data, stored to again (a store hit), FENCE.I and run.
test_code:
    addi t2, zero, 5
    li32 s0, patch_code
    li32 t6, patch_alt
    li32 a0, 0x00001000
    jal  ra, patch_code
    assert_value a0, 0x00001075    # the original code: a0 += 0x75
    lw   t4, 0(t6)                 # the new word (alt, a different code line)
    sw   t4, 0(s0)                 # a store miss into the code line
    fence.i
    li32 a0, 0x00001000
    jal  ra, patch_code
    assert_value a0, 0x0000101B    # the new code: a0 += 0x1B
    lw   t4, 0(s0)                 # the patched word read as data: a miss, from the RAM
    lw   t5, 0(t6)
    assert_equal t4, t5
    lw   t4, 4(s0)                 # the return that follows, read as data (a hit)
    li32 t5, 0x00008067
    assert_equal t4, t5
    lw   t4, 8(t6)                 # the original word, kept in alt_back
    sw   t4, 0(s0)                 # a store hit into the code line, which the loads above brought in
    fence.i
    li32 a0, 0x00001000
    jal  ra, patch_code
    assert_value a0, 0x00001075
    lw   t4, 0(s0)
    lw   t5, 8(t6)
    assert_equal t4, t5

# ------------------------------------------------------------------------------------------------
# |                                          Test done!                                          |
# ------------------------------------------------------------------------------------------------
test_finish:
    addi t2, zero, 9
    halt
    fail

# ------------------------------------------------------------------------------------------------
# init_line: the four words of the line at s2 by sw (a line that is not present: RAM only).
# ------------------------------------------------------------------------------------------------
init_line:
    li32 t4, P0
    sw   t4, 0(s2)
    li32 t4, P1
    sw   t4, 4(s2)
    li32 t4, P2
    sw   t4, 8(s2)
    li32 t4, P3
    sw   t4, 12(s2)
    jalr zero, 0(ra)

# ------------------------------------------------------------------------------------------------
# rb_word: reads the word at a1 with lw, with lbu and lb at the four lanes and with lhu and lh at
# the two halves, and ORs the differences from a2 (the expected word) into s1.
# ------------------------------------------------------------------------------------------------
rb_word:
    lw   t4, 0(a1)
    xor  t4, t4, a2
    or   s1, s1, t4
    .irp k, 0, 1, 2, 3
    lbu  t4, \k(a1)
    srli t5, a2, 8 * \k
    andi t5, t5, 0xff
    xor  t4, t4, t5
    or   s1, s1, t4
    lb   t4, \k(a1)
    slli t5, a2, 24 - 8 * \k
    srai t5, t5, 24
    xor  t4, t4, t5
    or   s1, s1, t4
    .endr
    lhu  t4, 0(a1)
    slli t5, a2, 16
    srli t5, t5, 16
    xor  t4, t4, t5
    or   s1, s1, t4
    lhu  t4, 2(a1)
    srli t5, a2, 16
    xor  t4, t4, t5
    or   s1, s1, t4
    lh   t4, 0(a1)
    slli t5, a2, 16
    srai t5, t5, 16
    xor  t4, t4, t5
    or   s1, s1, t4
    lh   t4, 2(a1)
    srai t5, a2, 16
    xor  t4, t4, t5
    or   s1, s1, t4
    jalr zero, 0(ra)

# ------------------------------------------------------------------------------------------------
# The code of case 5 (16-byte aligned: its two words and two filler words are one line), and the
# words it is patched with
# ------------------------------------------------------------------------------------------------
.balign 16
patch_code:
    addi a0, a0, 0x75              # the patch replaces this word
    jalr zero, 0(ra)
    nop
    nop
patch_alt:
    addi a0, a0, 0x1B              # never executed here: the new word
    jalr zero, 0(ra)
alt_back:
    addi a0, a0, 0x75              # never executed here: the original word
