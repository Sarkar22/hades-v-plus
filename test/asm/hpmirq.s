# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: hpmirq.s
#
# ------------------------------------------------------------------------------------------------
# |                                                                                              |
# | THE PERFORMANCE COUNTERS AT EVERY POSITION OF AN INTERRUPT (docs/EXTENSIONS.md, "Hardware    |
# | Performance Counters"; the style of csrirq.s).                                               |
# |                                                                                              |
# | A sequential interrupt is decided at an instruction I and jumps one cycle later, while the   |
# | next instruction J is already in Writeback: J retires and the trap comes after it, or J is   |
# | replayed (a CSR instruction on mstatus, mcause, mie or mtvec, and mret) and runs again after |
# | the handler. Seven probes put J, or I, at every cycle offset of the test device's interrupt  |
# | (the delay 1..40 is swept; the arming store comes 8 nops before the probe, 8 nops follow):   |
# |   0  csrw mcountinhibit  freezes IR and HPM3 for two nops, then thaws them                   |
# |   1  csrw mhpmevent4     writes the selector it already holds                                |
# |   2  csrrw mhpmcounter3  writes a counter that counts the same as counter 4                  |
# |   3  fence.i             (not replayed: it retires as J)                                     |
# |   4  csrsi mstatus, 8    (replayed as J)                                                     |
# |   5  mret into a pending interrupt (MIE = 0, MPIE = 1): the mret takes the interrupt itself  |
# |   6  mret with MIE = 1 (replayed as J)                                                       |
# | Counters, over a window that holds the arming, the probe, the handler and the return:        |
# |   3 INSTRET   4 INSTRET   5 REPLAY   6 INTERRUPT   7 REDIRECT_WB   8 MRET   9 FENCE_I        |
# | At every delay the checks, accumulated and reported once per probe:                          |
# |   A  counter 3 = minstret over the window (probes 0 and 3 to 6; with the IR bit set in the    |
# |      same write as HPM3 in probe 0, so that both stand still for the same instructions);     |
# |      counter 3 = counter 4 (probes 1 and 3 to 6)                                             |
# |   B  INTERRUPT = the handler entries                                                         |
# |   C  REPLAY = 0 where nothing is replayed (probes 0 to 3 and 5); in probes 4 and 6 REPLAY is |
# |      at most the entries whose mepc is the probe at every delay (an interrupt decided at the |
# |      instruction in front of the probe leaves mepc there too, and replays nothing), and, on  |
# |      a memory that answers in one cycle, 1 over the whole sweep (the probe is J at one delay) |
# |   D  REDIRECT_WB + p = EXCEPTION + INTERRUPT + MRET + FENCE_I - q - r, with p = 0 at the end |
# |      of the window and q, r (an mret that takes an interrupt at once, a fence.i that retires |
# |      as J) at most 1 here: the right side minus the left is 0, or 0 or 1 in probes 3, 5, 6   |
# |   E  (probe 2) a counter that is written as the stale J keeps the written value and the      |
# |      events after it: counter 3 - counter 4 = V - O - 1, with O the old value that csrrw     |
# |      returned (counter 4 counted the writing instruction, counter 3 did not)                 |
# |                                                                                              |
# | The test needs the standard build (seven counters, counters 3-9); with fewer (make           |
# | HPM_COUNTERS=<n>) it reports failures instead of stopping.                                   |
# |                                                                                              |
# | Register allocation:                                                                         |
# |     x5  (t0):   reserved for macro use         x6 (t1): 1        x7 (t2): probe number        |
# |     x28 (t3):   test peripheral address        t4, t5: scratch of the checks                 |
# |     s0: delay   s1, s2, s3, s9, s10: the accumulators E, A, B, C, D of the probe             |
# |     s4: minstret at the start of the window      s5: 1 on a memory that answers in one cycle |
# |     s6: the probe's address   s7: entries with mepc = s6   s8: entries   s11: 0x3FFD         |
# |     ra: O of probe 2     gp: the handler's scratch     a0-a7: the cases                      |
# |                                                                                              |
# ------------------------------------------------------------------------------------------------

.equ INH_ALL,    0x3FFD
.equ NMAX,       40
.equ EV_INSTRET,     2
.equ EV_FENCE_I,     14
.equ EV_REPLAY,      15
.equ EV_INTERRUPT,   24
.equ EV_MRET,        13
.equ EV_REDIRECT_WB, 46

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

# The start of a probe's sweep and of one iteration: freeze, select, clear, arm. mst is the value
# of mstatus while the probe runs; addr the label of the probe's instruction.
.macro prologue id:req, mst:req, addr:req
    li   t2, \id
    li   s0, 1
    li   s1, 0
    li   s2, 0
    li   s3, 0
    li   s9, 0
    li   s10, 0
loop\id:
    csrw mcountinhibit, s11
    selc 3, EV_INSTRET
    selc 4, EV_INSTRET
    selc 5, EV_REPLAY
    selc 6, EV_INTERRUPT
    selc 7, EV_REDIRECT_WB
    selc 8, EV_MRET
    selc 9, EV_FENCE_I
    clear_all
    li   s8, 0
    li   s7, 0
    la   s6, \addr
    sw   zero, 4(t3)
    li   t0, \mst
    csrw mstatus, t0
    csrr s4, minstret             # the window's start (IR is set, so it stands still)
    csrw mcountinhibit, zero      # the window opens
    sw   s0, 4(t3)                # the interrupt comes s0 cycles from now
    .rept 8
    nop
    .endr
.endm

# inst: counter 3 against minstret; c4: counter 3 against counter 4; rp: 0 nothing is replayed,
# 1 a replay is possible; g4: 0 exact, 1 q or r may be 1; p2: the check of probe 2
.macro epilogue id:req, inst:req, c4:req, rp:req, g4:req, p2:req
    .rept 8
    nop
    .endr
    li   a7, 300                  # wait for the interrupt
1:  bgtz s8, 2f
    addi a7, a7, -1
    bnez a7, 1b
2:  .rept 6
    nop
    .endr
    csrw mcountinhibit, s11       # the window closes
    csrw mstatus, zero
    csrr a5, minstret
    sub  a5, a5, s4
    rdc  3, a1
    rdc  4, a2
    rdc  5, a3
    rdc  6, a4
    rdc  7, a6
    rdc  8, a7
    rdc  9, t5
    .if \inst
    sub  t4, a1, a5
    or   s2, s2, t4
    .endif
    .if \c4
    sub  t4, a1, a2
    or   s2, s2, t4
    .endif
    sub  t4, a4, s8               # B
    or   s3, s3, t4
    .if \rp == 0                  # C
    or   s9, s9, a3
    .else
    sltu t4, s7, a3
    or   s9, s9, t4
    add  s1, s1, a3               # (summed over the sweep)
    .endif
    add  t4, a4, a7               # D
    add  t4, t4, t5
    sub  t4, t4, a6
    .if \g4 == 0
    or   s10, s10, t4
    .else
    sltiu t4, t4, 2
    xori t4, t4, 1
    or   s10, s10, t4
    .endif
    .if \p2                       # E
    sub  t4, a1, a2
    sub  a0, a0, ra
    addi a0, a0, -1
    sub  t4, t4, a0
    or   s1, s1, t4
    .endif
    addi s0, s0, 1
    li   t0, NMAX + 1
    bne  s0, t0, loop\id
    assert_value s2, 0
    assert_value s3, 0
    assert_value s9, 0
    assert_value s10, 0
    .if \p2
    assert_value s1, 0
    .endif
    .if \rp
    addi t0, s1, -1               # the probe is replayed at one delay of the sweep, once
    snez t0, t0
    and  t0, t0, s5
    sw   t0, 0(t3)
    .endif
.endm

.section .text.__reset
.globl __reset
__reset:
    li   t3, 0x480000
    li   t1, 1
    sw   t1, 0(t3)                # initial test: deliberate fail (proves the fail path works)
    li   s11, INH_ALL
    la   t0, handler
    csrw mtvec, t0
    li   t0, 0x880
    csrw mie, t0
    csrw mstatus, zero
    sw   zero, 4(t3)
    li   t0, 0x214010
    li   t4, -1
    sw   t4, 0(t0)                # timer disarmed
    flush_pipeline
    csrr s0, mcycle               # the memory's speed: 32 nops that have not run before take 33 cycles
    .rept 32
    nop
    .endr
    csrr s1, mcycle
    sub  s1, s1, s0
    addi s1, s1, -33
    seqz s5, s1
    flush_pipeline
    # no counters here (the golden CPU): fail once and stop
    li   t0, 1
    li   t4, 0
    csrw 0x323, t0
    csrr t4, 0x323
    csrw 0x323, zero
    assert_value t4, 1
    bne  t4, t1, nocounters

# ---- 0: csrw mcountinhibit ---------------------------------------------------------------------
    li   a0, 0x0C
    prologue 0, 0x88, pr0
pr0:
    csrw mcountinhibit, a0        # IR and HPM3 stop ...
    nop
    nop
    csrw mcountinhibit, zero      # ... and start again
    epilogue 0, 1, 0, 0, 0, 0

# ---- 1: csrw mhpmevent4 --------------------------------------------------------------------------
    li   a0, EV_INSTRET
    prologue 1, 0x88, pr1
pr1:
    csrw 0x324, a0
    epilogue 1, 1, 1, 0, 0, 0

# ---- 2: csrrw mhpmcounter3 -----------------------------------------------------------------------
    prologue 2, 0x88, pr2
    li   a0, 0x555
pr2:
    csrrw ra, 0xB03, a0
    epilogue 2, 0, 0, 0, 0, 1

# ---- 3: fence.i ----------------------------------------------------------------------------------
    prologue 3, 0x88, pr3
pr3:
    fence.i
    epilogue 3, 1, 1, 0, 1, 0

# ---- 4: csrsi mstatus, 8 (replayed as the stale instruction) --------------------------------------
    prologue 4, 0x88, pr4
pr4:
    csrsi mstatus, 8
    epilogue 4, 1, 1, 1, 0, 0

# ---- 5: mret into a pending interrupt --------------------------------------------------------------
    prologue 5, 0x80, pr5
    la   t4, pr5_target
    csrw mepc, t4
pr5:
    mret
    li   a1, 0xbad
pr5_target:
    epilogue 5, 1, 1, 0, 1, 0

# ---- 6: mret with interrupts on -----------------------------------------------------------------------
    prologue 6, 0x88, pr6
    la   t4, pr6_target
    csrw mepc, t4
pr6:
    mret
    li   a1, 0xbad
pr6_target:
    epilogue 6, 1, 1, 1, 1, 0

finish:
    csrw mcountinhibit, zero
nocounters:                   # (a CPU without mcountinhibit would trap on the csrw above)
    halt
    fail

# The handler: count the entry, count it again when mepc is the probe, clear the test device, wait
# for the line to drop, return.
.balign 16
handler:
    addi s8, s8, 1
    csrr gp, mepc
    bne  gp, s6, 1f
    addi s7, s7, 1
    addi gp, zero, 6
    bne  t2, gp, 1f               # probe 6: a replayed mret would return to itself
    la   gp, pr6_target           # (mepc is its own address): go where it goes
    csrw mepc, gp
1:  sw   zero, 4(t3)
    .rept 6
    nop
    .endr
    mret
