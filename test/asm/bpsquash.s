# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: bpsquash.s
#
# ------------------------------------------------------------------------------------------------
# |                                                                                              |
# | THE BRANCH PREDICTOR'S COUNTERS COUNT RETIRED BRANCHES, EXACTLY ONCE EACH.                   |
# |                                                                                              |
# | mhpmcounter10..13 (0xB0A..0xB0D: predicted not taken and not taken, predicted not taken and  |
# | taken, predicted taken and not taken, predicted taken and taken) add up to the number of     |
# | conditional branches that the program executed. A branch that is squashed because an older   |
# | instruction traps, or an interrupt is taken, counts when it runs again and not before; a     |
# | write to a counter is not lost to an increment that falls in the same cycle.                 |
# |                                                                                              |
# | Cases (the sum of the four counters is read after each; the handlers have no branch, so      |
# | that the sum is the program's own):                                                          |
# |   1  a branch one instruction behind an ecall (the handler returns past the ecall)    1      |
# |   2  a branch two instructions behind an ecall                                        1      |
# |   3  a branch one instruction behind a misaligned load (the handler skips the load)   1      |
# |   4  a branch two instructions behind a misaligned load                               1      |
# |   5  a branch behind a test-device interrupt that is swept over 40 delays, once with a       |
# |      branch that is not taken and once with one that is taken: the sum is 2 (that branch and |
# |      the one that chose it) + the number of branches of the wait loop, which the program     |
# |      counts itself                                                                           |
# |   6  csrwi 0xB0B, 0 with a taken branch directly behind it: NT reads 1                       |
# |   7  the same with one instruction in between: NT reads 1                                    |
# | A predictor that counted a branch when it passes Execute, as the counters did before they    |
# | counted retired branches, gives 2 in cases 1 to 4, a wrong sum at some delays of case 5, 0   |
# | in case 6 (the write overwrites the count) and 8 in case 7 (the count overrides the write).  |
# |                                                                                              |
# | Register allocation:                                                                         |
# |     x5  (t0):   reserved for macro use         x6 (t1): 1        x7 (t2): test case number    |
# |     x28 (t3):   test peripheral address        t4: scratch       t6: address of buf           |
# |     s0: delay   s2: wrong sums   s8: interrupts taken (the interrupt handler)                |
# |     gp, tp:     the handlers' scratch          a0-a5: the cases                              |
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

.macro assert_value reg:req, value:req
    li   t0, \value
    assert_equal t0, \reg
.endm

.macro flush_pipeline
    nop
    nop
    nop
    nop
    nop
.endm

# set the four counters to 0 / sum them into a register (the csrr and csrw are not branches)
.macro clrbp
    csrw 0xB0A, zero
    csrw 0xB0B, zero
    csrw 0xB0C, zero
    csrw 0xB0D, zero
.endm

.macro sumbp rd:req
    csrr \rd, 0xB0A
    csrr t4, 0xB0B
    add  \rd, \rd, t4
    csrr t4, 0xB0C
    add  \rd, \rd, t4
    csrr t4, 0xB0D
    add  \rd, \rd, t4
.endm

.section .text.__reset
.globl __reset
__reset:
    li   t3, 0x480000
    li   t1, 1
    sw   t1, 0(t3)                # initial test: deliberate fail (proves the fail path works)
    la   t6, buf
    li   s8, 0
    csrw mstatus, zero
    li   t0, 0x880
    csrw mie, t0
    sw   zero, 4(t3)
    li   t0, 0x214010
    li   t4, -1
    sw   t4, 0(t0)                # timer disarmed
    csrw 0x32A, zero              # predictor mode 0 (the golden CPU ignores the register)
    la   t0, h_exc
    csrw mtvec, t0
    flush_pipeline

# ---- 1: ecall; branch -------------------------------------------------------------------------
case1:
    li   t2, 1
    clrbp
    flush_pipeline
    ecall
    bne  zero, zero, 1f           # the branch directly behind the ecall
1:  flush_pipeline
    sumbp a1
    assert_value a1, 1

# ---- 2: ecall; nop; branch ---------------------------------------------------------------------
case2:
    li   t2, 2
    clrbp
    flush_pipeline
    ecall
    nop
    bne  zero, zero, 2f
2:  flush_pipeline
    sumbp a1
    assert_value a1, 1

# ---- 3: misaligned load; branch ----------------------------------------------------------------
case3:
    li   t2, 3
    clrbp
    flush_pipeline
    lw   a0, 1(t6)                # load address misaligned: exception 4, the handler skips the load
    bne  zero, zero, 3f
3:  flush_pipeline
    sumbp a1
    assert_value a1, 1

# ---- 4: misaligned load; nop; branch -----------------------------------------------------------
case4:
    li   t2, 4
    clrbp
    flush_pipeline
    lw   a0, 1(t6)
    nop
    bne  zero, zero, 4f
4:  flush_pipeline
    sumbp a1
    assert_value a1, 1

# ---- 5: an interrupt swept over the delays 1..40 ------------------------------------------------
case5:
    li   t2, 5
    la   t0, h_irq
    csrw mtvec, t0
    li   s2, 0
    li   a5, 0                    # 0: a branch that is not taken, 1: one that is taken
sweep:
    li   s0, 1
sweep_delay:
    clrbp
    li   s8, 0
    csrsi mstatus, 8
    sw   s0, 4(t3)                # the interrupt comes s0 cycles from now
    .rept 12
    nop
    .endr
    bnez a5, sweep_taken
    bne  zero, zero, 5f           # not taken
5:  j    sweep_after
sweep_taken:
    beq  zero, zero, 6f           # taken
    li   a1, 0xbad
6:
sweep_after:
    .rept 12
    nop
    .endr
    li   a4, 0
7:  addi a4, a4, 1                # the wait loop: one branch for every addi
    beqz s8, 7b
    csrci mstatus, 8
    sumbp a1
    addi a4, a4, 2                # + the branch under test and the one that chose it (bnez a5)
    sub  t4, a1, a4
    or   s2, s2, t4
    addi s0, s0, 1
    li   t0, 41
    bne  s0, t0, sweep_delay
    addi a5, a5, 1
    li   t0, 2
    bne  a5, t0, sweep
    assert_value s2, 0
    la   t0, h_exc
    csrw mtvec, t0

# ---- 6: csrwi 0xB0B, 0; taken branch ----------------------------------------------------------
case6:
    li   t2, 6
    li   t0, 7
    csrw 0xB0B, t0
    flush_pipeline
    csrwi 0xB0B, 0                # NT := 0 ...
    beq  zero, zero, 8f           # ... and the taken branch directly behind it counts once
    li   a1, 0xbad
8:  csrr a2, 0xB0B
    flush_pipeline
    assert_value a2, 1

# ---- 7: csrwi 0xB0B, 0; nop; taken branch --------------------------------------------------------
case7:
    li   t2, 7
    li   t0, 7
    csrw 0xB0B, t0
    flush_pipeline
    csrwi 0xB0B, 0
    nop
    beq  zero, zero, 9f
    li   a1, 0xbad
9:  csrr a2, 0xB0B
    flush_pipeline
    assert_value a2, 1

    csrw 0x32A, zero
    halt
    fail

# Exceptions: skip the instruction. Interrupts: clear the test device and wait for the line to drop.
# Neither handler has a branch, so the counters see only the program's.
.balign 16
h_exc:
    csrr tp, mepc
    addi tp, tp, 4
    csrw mepc, tp
    mret

.balign 16
h_irq:
    sw   zero, 4(t3)
    addi s8, s8, 1
    .rept 6
    nop
    .endr
    mret

.balign 64
buf:
    .word 0x11111111, 0x22222222, 0x33333333, 0x44444444
