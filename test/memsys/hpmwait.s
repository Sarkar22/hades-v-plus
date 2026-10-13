# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: hpmwait.s
#
# ------------------------------------------------------------------------------------------------
# |                                                                                              |
# | WAIT STATES AND THE PERFORMANCE COUNTERS, for the memory-system checks (test/memsys/         |
# | programs.py), with a slow memory (MEM_LAT=..., sim/slow_memory.sv) or without one.           |
# |                                                                                              |
# | The program times a block of 32 nops three times with mcycle. If the three results are       |
# | equal the memory has one fixed latency (a cache or random latencies make them differ), and  |
# | the checks marked 'fixed' below are made; otherwise they pass without looking (s5 = 0), so   |
# | that the reports are the same in every configuration. The checks that hold for any latency   |
# | are always made.                                                                             |
# |                                                                                              |
# | Windows (opened with csrw mcountinhibit, zero and closed with csrw mcountinhibit, s11; the   |
# | block between them is straight-line and warm):                                               |
# |   1  32 nops: FETCH_WAIT + INSTRET = CYCLE                                       (fixed)     |
# |      Every cycle of a block of nops is a wait for the fetch port or the cycle in which a     |
# |      word is taken, one per instruction; with a plain memory FETCH_WAIT is 0 and INSTRET =   |
# |      CYCLE.                                                                                  |
# |   2  32 nops: the six cycle classes (FETCH_WAIT, FRONT_OK, HAZARD, MSTALL_ANY, MEMWAIT_ANY,   |
# |      REDIRECT_ANY) add up to CYCLE                                                (always)   |
# |   3  8 loads of a RAM word, each followed by a nop, and 16 of them: LOAD counts 8 and 16,    |
# |      MEMWAIT_ANY = MEMWAIT_LOAD, the six classes add up to CYCLE                  (always)   |
# |      MEMWAIT_LOAD of 16 loads is twice that of 8                                  (fixed)   |
# |   4  when the fetch does not wait (the nops take 33 cycles), the loads of window 3 cost      |
# |      mcycle as much as MEMWAIT_LOAD says: the difference between the time of the 8 loads     |
# |      and the nops, in cycles, is MEMWAIT_LOAD of window 3                         (fixed)   |
# | All of them also hold, trivially or for real, with no wait states.                           |
# |                                                                                              |
# | Register allocation:                                                                         |
# |     t1: 1       t2: test case number    t3: test peripheral address     t6: address of buf   |
# |     s0, s1, s2: the three times of the nop block     s5: 1 if they are equal (fixed)         |
# |     s6: 1 if the nops take 33 cycles (the fetch port does not wait)    s11: 0x3FFD           |
# |     ra: return address of the window functions    a0-a7, s3, s4, s7-s10: the checks          |
# |                                                                                              |
# ------------------------------------------------------------------------------------------------

.equ INH_ALL,        0x3FFD
.equ EV_CYCLE,       1
.equ EV_INSTRET,     2
.equ EV_LOAD,        3
.equ EV_FETCH_WAIT,  32
.equ EV_FRONT_OK,    33
.equ EV_HAZARD,      34
.equ EV_MSTALL_ANY,  35
.equ EV_MEMWAIT_ANY, 36
.equ EV_REDIRECT_ANY, 37
.equ EV_MEMWAIT_LOAD, 41

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

# only when s5 says that the latency is fixed
.macro assert_equal_f r1:req, r2:req
    sub  t0, \r1, \r2
    sltu t0, zero, t0
    and  t0, t0, s5
    sw   t0, 0(t3)
.endm

# only when s5 and s6 say that the latency is fixed and the fetch port does not wait
.macro assert_equal_ff r1:req, r2:req
    sub  t0, \r1, \r2
    sltu t0, zero, t0
    and  t0, t0, s5
    and  t0, t0, s6
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

.macro pad
    nop
    nop
    nop
    nop
    nop
    nop
.endm

.macro selc n:req, code:req
    li   t0, \code
    csrw 0x320+\n, t0
.endm

.macro rdc n:req, reg:req
    csrr \reg, 0xB00+\n
.endm

.macro clear_all
    .irp n, 3, 4, 5, 6, 7, 8, 9
    csrw 0xB00+\n, zero
    csrw 0xB80+\n, zero
    .endr
.endm

.section .text.__reset
.globl __reset
__reset:
    li   t3, 0x480000
    li   t1, 1
    sw   t1, 0(t3)                # initial test: deliberate fail (proves the fail path works)
    li   s11, INH_ALL
    la   t6, buf
    flush_pipeline
    # no counters here (the golden CPU): fail once and stop
    li   t0, 1
    li   t4, 0
    csrw 0x323, t0
    csrr t4, 0x323
    csrw 0x323, zero
    li   t0, 1
    sub  t0, t0, t4
    sltu t0, zero, t0
    sw   t0, 0(t3)                # a code written to mhpmevent3 reads back
    bne  t4, t1, nocounters

    # ---- the time of the nop block, three times ----
    jal  ra, timed32
    mv   s0, a0
    jal  ra, timed32
    mv   s1, a0
    jal  ra, timed32
    mv   s2, a0
    sub  t4, s0, s1
    sub  t5, s1, s2
    or   t4, t4, t5
    seqz s5, t4                   # equal: one fixed latency
    addi t4, s1, -33
    seqz s6, t4                   # 33 cycles: the fetch port does not wait

    # ---- 1: FETCH_WAIT + INSTRET = CYCLE ----
    li   t2, 1
    csrw mcountinhibit, s11
    selc 3, EV_FETCH_WAIT
    selc 4, EV_INSTRET
    selc 5, EV_CYCLE
    clear_all
    jal  ra, window32
    rdc  3, a1
    rdc  4, a2
    rdc  5, a3
    add  a4, a1, a2
    assert_equal_f a4, a3
    assert_equal_ff a1, zero      # a plain memory never makes the fetch port wait

    # ---- 2: the six classes add up to the cycles ----
    li   t2, 2
    csrw mcountinhibit, s11
    selc 3, EV_FETCH_WAIT
    selc 4, EV_FRONT_OK
    selc 5, EV_HAZARD
    selc 6, EV_MSTALL_ANY
    selc 7, EV_MEMWAIT_ANY
    selc 8, EV_REDIRECT_ANY
    selc 9, EV_CYCLE
    clear_all
    jal  ra, window32
    rdc  3, a1
    rdc  4, a2
    rdc  5, a3
    rdc  6, a4
    rdc  7, a5
    rdc  8, a6
    rdc  9, a7
    add  t4, a1, a2
    add  t4, t4, a3
    add  t4, t4, a4
    add  t4, t4, a5
    add  t4, t4, a6
    assert_equal t4, a7

    # ---- 3: loads ----
    li   t2, 3
    csrw mcountinhibit, s11
    selc 3, EV_MEMWAIT_LOAD
    selc 4, EV_LOAD
    selc 5, EV_MEMWAIT_ANY
    selc 6, EV_CYCLE
    selc 7, EV_FETCH_WAIT
    selc 8, EV_HAZARD
    selc 9, EV_MSTALL_ANY
    clear_all
    jal  ra, window_loads8
    rdc  3, s7                    # MEMWAIT_LOAD of 8 loads
    rdc  4, a2
    rdc  5, a3
    assert_value a2, 8
    assert_equal a3, s7           # MEMWAIT_ANY = MEMWAIT_LOAD
    csrw mcountinhibit, s11
    clear_all
    jal  ra, window_loads16
    rdc  3, s8                    # MEMWAIT_LOAD of 16 loads
    rdc  4, a2
    rdc  5, a3
    assert_value a2, 16
    assert_equal a3, s8
    slli t4, s7, 1
    assert_equal_f s8, t4         # twice as many loads wait twice as long
    # the six classes again, now with loads in the window (the sixth, REDIRECT_ANY, is one more counter)
    li   t2, 4
    csrw mcountinhibit, s11
    selc 3, EV_FETCH_WAIT
    selc 4, EV_FRONT_OK
    selc 5, EV_HAZARD
    selc 6, EV_MSTALL_ANY
    selc 7, EV_MEMWAIT_ANY
    selc 8, EV_REDIRECT_ANY
    selc 9, EV_CYCLE
    clear_all
    jal  ra, window_loads8
    rdc  3, a1
    rdc  4, a2
    rdc  5, a3
    rdc  6, a4
    rdc  7, a5
    rdc  8, a6
    rdc  9, a7
    add  t4, a1, a2
    add  t4, t4, a3
    add  t4, t4, a4
    add  t4, t4, a5
    add  t4, t4, a6
    assert_equal t4, a7

    # ---- 4: the time of the loads, when only the data bus waits ----
    li   t2, 5
    jal  ra, timed_nops16
    mv   s9, a0
    jal  ra, timed_loads8
    mv   s10, a0
    sub  t4, s10, s9              # cycles of the 8 loads beyond those of 16 nops: 8 times the wait of a load
    assert_equal_ff t4, s7

finish:
    csrw mcountinhibit, zero
nocounters:                   # (a CPU without mcountinhibit would trap on the csrw above)
    halt
    fail

# ---- the timed blocks (mcycle between two reads) -------------------------------------------------
.balign 16
timed32:
    csrr a0, mcycle
    .rept 32
    nop
    .endr
    csrr a1, mcycle
    sub  a0, a1, a0
    ret

.balign 16
timed_nops16:
    csrr a0, mcycle
    .rept 15
    nop
    .endr
    csrr a1, mcycle
    sub  a0, a1, a0
    ret

.balign 16
timed_loads8:
    csrr a0, mcycle
    .rept 7
    lw   a2, 0(t6)
    nop
    .endr
    lw   a2, 0(t6)
    csrr a1, mcycle
    sub  a0, a1, a0
    ret

# ---- the windows ------------------------------------------------------------------------------------
.balign 16
window32:
    pad
    csrw mcountinhibit, zero
    .rept 32
    nop
    .endr
    csrw mcountinhibit, s11
    ret

.balign 16
window_loads8:
    pad
    csrw mcountinhibit, zero
    .rept 8
    lw   a0, 0(t6)
    nop
    .endr
    pad
    csrw mcountinhibit, s11
    ret

.balign 16
window_loads16:
    pad
    csrw mcountinhibit, zero
    .rept 16
    lw   a0, 0(t6)
    nop
    .endr
    pad
    csrw mcountinhibit, s11
    ret

.balign 64
buf:
    .word 0x11111111, 0x22222222, 0x33333333, 0x44444444
