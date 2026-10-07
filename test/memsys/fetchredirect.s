# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: fetchredirect.s
#
# ------------------------------------------------------------------------------------------------
# |                                                                                              |
# | ABANDONED FETCHES, for the memory-system checks (test/memsys/programs.py).                   |
# |                                                                                              |
# | Every taken branch or jump, and every wrong prediction of the branch predictor, changes the  |
# | fetch address, often while a fetch of the old address still waits for the memory. The word   |
# | that then arrives for the new address must be the new address's word, never the abandoned    |
# | one's. In the cases below every branch and jump target starts with an update of the          |
# | checksum that no other instruction makes ('addi s2, s2, <distinct constant>', then           |
# | 'add s1, s1, s2', so the order of the updates counts too), and every word behind a taken     |
# | branch or jump that must not run adds a distinct constant to s3, which is never reset. A     |
# | target that runs another word, a wrong-path word that retires, or a skipped or doubled       |
# | target changes s1 or s3, at any latency of the slow memory and also without the              |
# | scoreboard. The jumps between the cases land on the case number or on s6, which counts the   |
# | passes; their wrong-path words also add to s3.                                               |
# |                                                                                              |
# | Case 2: 24 blocks visited in an order unlike their order in memory: 12 forward and 12        |
# |         backward transfers, three each through beq, bne, blt, bge, bltu, bgeu, jal and       |
# |         jalr, eight of them behind a branch that is never taken; four passes. With the       |
# |         predictor off every taken branch is mispredicted; in mode 3 most are predicted,      |
# |         and the never-taken branches are mispredicted.                                       |
# | Case 3: a loop whose branch follows a 32-bit pattern, with different updates on the taken    |
# |         and the not-taken path: the predictor (mode 3) is wrong in both directions.          |
# | Case 4: calls forward and backward, through jal and jalr, and their returns.                 |
# | Each case runs with the branch predictor off (mode 0) and in mode 3 (the golden CPU ignores  |
# | the mode), and checks s1 and s3; the end checks s6 and s3. The expected checksums were       |
# | computed with an independent instruction-set model, not by the CPU. The reports are the      |
# | same at every latency.                                                                       |
# |                                                                                              |
# | Register allocation:                                                                         |
# |     x5  (t0):   reserved for macro use                                                       |
# |     x6  (t1):   1 (the value a failed check writes)                                          |
# |     x7  (t2):   test case number                                                             |
# |     x28 (t3):   test peripheral address                                                      |
# |     s1: checksum            s2: running sum of the updates     s3: wrong-path words          |
# |     s4: branch-predictor mode   s5: pattern   s6: passes   s7, s8: loop counters             |
# |     t4, a0: scratch         ra: return address                                               |
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

# Expected checksums (s1 at the end of each case)
.equ EXP_ZIGZAG,  0x004AB4A9
.equ EXP_PATTERN, 0x005FC57F
.equ EXP_CALLS,   0x00075C6B

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
    addi s3, zero, 0               # (never reset: a wrong-path word stays visible)
    addi s4, zero, 0               # branch-predictor mode 0, then 3
    addi s6, zero, 0

# Deliberate first failure: proves the assert macro and the test peripheral work.
test_fail:
    addi t2, zero, 1
    assert_value zero, 1

test_mode:
    addi s6, s6, 1                 # passes (the target of the backward branch below)
    csrw 0x32A, s4                 # MHPMEVENT10: branch-predictor mode

# -----------------------------------------------
# Case 2: 24 blocks in a scrambled order, four passes.
test_zigzag:
    addi t2, zero, 2
    addi s1, zero, 0
    addi s2, zero, 0
    addi s8, zero, 4
zz_pass:
    addi s2, s2, 1951
    add  s1, s1, s2
    jal  zero, zz_1                # into the first block
    addi s3, s3, 2024
zz_base:
zz_21:
    addi s2, s2, 100
    add  s1, s1, s2
    beq  t1, zero, zz_poison
    bltu zero, t1, zz_22
    addi s3, s3, 76
zz_22:
    addi s2, s2, 1492
    add  s1, s1, s2
    bgeu t1, zero, zz_23
    addi s3, s3, 1047
zz_7:
    addi s2, s2, 991
    add  s1, s1, s2
    jal  zero, zz_8
    addi s3, s3, 1899
zz_11:
    addi s2, s2, 1156
    add  s1, s1, s2
    blt  zero, t1, zz_12
    addi s3, s3, 1956
zz_16:
    addi s2, s2, 1349
    add  s1, s1, s2
    li32 a0, zz_17
    jalr zero, 0(a0)
    addi s3, s3, 54
zz_14:
    addi s2, s2, 1517
    add  s1, s1, s2
    bgeu t1, zero, zz_15
    addi s3, s3, 931
zz_6:
    addi s2, s2, 1230
    add  s1, s1, s2
    beq  t1, zero, zz_poison
    bgeu t1, zero, zz_7
    addi s3, s3, 235
zz_18:
    addi s2, s2, 438
    add  s1, s1, s2
    beq  t1, zero, zz_poison
    bne  t1, zero, zz_19
    addi s3, s3, 1310
zz_1:
    addi s2, s2, 647
    add  s1, s1, s2
    beq  zero, zero, zz_2
    addi s3, s3, 1752
zz_24:
    addi s2, s2, 82
    add  s1, s1, s2
    beq  t1, zero, zz_poison
    li32 a0, zz_end
    jalr zero, 0(a0)
    addi s3, s3, 592
zz_23:
    addi s2, s2, 179
    add  s1, s1, s2
    jal  zero, zz_24
    addi s3, s3, 99
zz_2:
    addi s2, s2, 1424
    add  s1, s1, s2
    bne  t1, zero, zz_3
    addi s3, s3, 1835
zz_13:
    addi s2, s2, 544
    add  s1, s1, s2
    bltu zero, t1, zz_14
    addi s3, s3, 662
zz_15:
    addi s2, s2, 1118
    add  s1, s1, s2
    beq  t1, zero, zz_poison
    jal  zero, zz_16
    addi s3, s3, 1287
zz_17:
    addi s2, s2, 97
    add  s1, s1, s2
    beq  zero, zero, zz_18
    addi s3, s3, 109
zz_5:
    addi s2, s2, 743
    add  s1, s1, s2
    bltu zero, t1, zz_6
    addi s3, s3, 104
zz_9:
    addi s2, s2, 481
    add  s1, s1, s2
    beq  t1, zero, zz_poison
    beq  zero, zero, zz_10
    addi s3, s3, 1513
zz_4:
    addi s2, s2, 2017
    add  s1, s1, s2
    bge  t1, zero, zz_5
    addi s3, s3, 944
zz_19:
    addi s2, s2, 1120
    add  s1, s1, s2
    blt  zero, t1, zz_20
    addi s3, s3, 395
zz_20:
    addi s2, s2, 119
    add  s1, s1, s2
    bge  t1, zero, zz_21
    addi s3, s3, 1040
zz_10:
    addi s2, s2, 6
    add  s1, s1, s2
    bne  t1, zero, zz_11
    addi s3, s3, 1901
zz_3:
    addi s2, s2, 404
    add  s1, s1, s2
    beq  t1, zero, zz_poison
    blt  zero, t1, zz_4
    addi s3, s3, 780
zz_12:
    addi s2, s2, 692
    add  s1, s1, s2
    beq  t1, zero, zz_poison
    bge  t1, zero, zz_13
    addi s3, s3, 1031
zz_8:
    addi s2, s2, 1828
    add  s1, s1, s2
    li32 a0, zz_9
    jalr zero, 0(a0)
    addi s3, s3, 1503
zz_poison:
    addi s3, s3, 1871
zz_end:
    addi s2, s2, 35
    add  s1, s1, s2
    addi s8, s8, -1
    bne  s8, zero, zz_pass
    addi s2, s2, 1597
    add  s1, s1, s2
    assert_value s1, EXP_ZIGZAG
    assert_value s3, 0

# -----------------------------------------------
# Case 3: a loop whose branch follows the bits of a pattern (taken on a 1).
test_pattern:
    addi t2, zero, 3
    addi s1, zero, 0
    addi s2, zero, 0
    li32 s5, 0xB4E1D2C3
    addi s7, zero, 32
pat_loop:
    addi s2, s2, 1171
    add  s1, s1, s2
    andi t4, s5, 1
    srli s5, s5, 1
    bne  t4, zero, pat_one
    addi s2, s2, 1283              # a 0
    add  s1, s1, s2
    jal  zero, pat_join
    addi s3, s3, 1373
pat_one:
    addi s2, s2, 1409              # a 1
    add  s1, s1, s2
pat_join:
    addi s2, s2, 1453
    add  s1, s1, s2
    addi s7, s7, -1
    bne  s7, zero, pat_loop
    addi s2, s2, 1559              # after the loop
    add  s1, s1, s2
    assert_value s1, EXP_PATTERN
    assert_value s3, 0
    jal  zero, test_calls
    addi s3, s3, 1693

# A subroutine before its callers (a backward call)
sub_back:
    addi s2, s2, 1777
    add  s1, s1, s2
    jalr zero, 0(ra)
    addi s3, s3, 1801

# -----------------------------------------------
# Case 4: calls forward and backward through jal and jalr, three times.
test_calls:
    addi t2, zero, 4
    addi s1, zero, 0
    addi s2, zero, 0
    addi s7, zero, 3
    li32 a0, sub_fwd2
call_loop:
    addi s2, s2, 1847
    add  s1, s1, s2
    jal  ra, sub_fwd
    addi s2, s2, 1867              # return point
    add  s1, s1, s2
    jal  ra, sub_back
    addi s2, s2, 1913              # return point
    add  s1, s1, s2
    jalr ra, 0(a0)
    addi s2, s2, 1931              # return point
    add  s1, s1, s2
    addi s7, s7, -1
    bne  s7, zero, call_loop
    addi s2, s2, 1973
    add  s1, s1, s2
    assert_value s1, EXP_CALLS
    assert_value s3, 0
    jal  zero, test_next_mode
    addi s3, s3, 1999

# Subroutines after their callers (forward calls)
sub_fwd:
    addi s2, s2, 2011
    add  s1, s1, s2
    jalr zero, 0(ra)
    addi s3, s3, 2017
sub_fwd2:
    addi s2, s2, 2027
    add  s1, s1, s2
    jalr zero, 0(ra)
    addi s3, s3, 2029

test_next_mode:
    addi s6, s6, 256               # passes (the target of the jump above)
    addi s4, s4, 3
    addi t4, zero, 6
    bne  s4, t4, test_mode

# ------------------------------------------------------------------------------------------------
# |                                          Test done!                                          |
# ------------------------------------------------------------------------------------------------
test_finish:
    addi s6, s6, 16                # (the fall-through of the branch above)
    addi t2, zero, 9
    assert_value s6, 2 + 2*256 + 16
    assert_value s3, 0
    csrwi 0x32A, 0
    halt
    fail
