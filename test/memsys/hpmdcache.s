# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: hpmdcache.s
#
# ------------------------------------------------------------------------------------------------
# |                                                                                              |
# | THE D-CACHE EVENTS IN THE PERFORMANCE COUNTERS, for the memory-system checks (test/memsys/   |
# | programs.py) in a simulator with both caches (docs/CACHES.md; make ICACHE=512 DCACHE=512 or  |
# | ICACHE=8192 DCACHE=4096, 16-byte lines). The counters count the data cache's event signals   |
# | (codes 140 to 147) and the port events of the arbiter (codes 134 to 139); the CACHE_STATS    |
# | line that sim/top.sv prints counts the same events and must agree with the counters at the   |
# | end of the run (the monitor of sim/top.sv compares them for the HPM_PRESET simulators H, I). |
# |                                                                                              |
# | Without a data cache the selectors for these codes read back 0: the program finds out (s5 =  |
# | 1 with one) and every check is then made 'without looking', so that the reports are the same |
# | in every configuration, as programs.py requires. The program is written for lines of 16      |
# | bytes (the line size of the gate configurations).                                            |
# |                                                                                              |
# | DATA UNDER TEST. Eight areas of 4 lines, the lines 128 bytes apart: the area PH<m> starts    |
# | 0x44000 + 16 * m, so that in a 512-byte direct-mapped cache of 16-byte lines (32 sets) the 32|
# | lines of the eight areas have 32 different sets (the 4 KiB cache holds them all as well) and |
# | nothing evicts anything. A window uses a line only once while it must be cold:               |
# |   PH0 case 3 (cold) and 4 (warm)   PH1 the dummy area of the warm-up passes                  |
# |   PH2 case 5                       PH3 case 2 (one line per window, lines 0 to 2)            |
# |   PH4, PH5 case 7 (cold, dummy)    PH6 case 7 (hit)   PH7 cases 6 and 6b (stores, loads)     |
# |                                                                                              |
# | WINDOWS. A window is a function that opens the counters (csrw mcountinhibit, zero), runs     |
# | its loads or stores and closes them (csrw mcountinhibit, s11, s11 = 0x3FFD). The trampoline  |
# | runs it twice: a warm-up pass on the dummy area PH1 (code in the instruction cache, the      |
# | counters cleared afterwards), then the pass that counts on the area of the case (s7). Only   |
# | the data of the window is cold in the second pass. Case 7 puts the eviction block (8 KiB     |
# | after block A, as in hpmcache.s) between the two passes, so that the load in the last word   |
# | before block A meets the refill of A's first line. Seven counters are enough for every       |
# | window; the selectors are set outside the windows.                                           |
# |                                                                                              |
# | WHAT EACH CASE CHECKS (L = 4 lines, LW = 4 words of a line):                                 |
# |   2  one cold line, three times, and one store to a present line, three times: if the        |
# |      figures of DC_REFILL_CYCLE and of DC_STORE_WAIT are the same each time, the memory has  |
# |      one fixed latency (s6 = 1; random latencies, for instance, make them differ) and the    |
# |      cases 5 and 6 compare their cycle counts with L times these figures; no other check     |
# |      depends on s6                                                                           |
# |   3  a loop of L loads, each of a cold line: DC_LOAD_MISS = DC_FILL = DC_LOOKUP_HIT = L (the |
# |      lookups that find the word, the second one of every miss), DC_BEAT = PORT_LOAD = LW * L,|
# |      PORT_GRANT_D >= LW * L, PORT_WAIT_D = 0 (the instruction side does not use the port)    |
# |   4  the same loop again over the same lines: DC_LOOKUP_HIT = L (the loads), and every other |
# |      count 0: DC_LOAD_MISS, DC_FILL, DC_BEAT, PORT_LOAD, PORT_GRANT_D, PORT_WAIT_D           |
# |   5  the loop over four other cold lines: DC_REFILL_CYCLE = PORT_WAIT_D + PORT_GRANT_D       |
# |      (every cycle of a refill requests the port: it waits or holds it), MEMWAIT_LOAD =       |
# |      DC_LOAD_MISS + DC_REFILL_CYCLE (the Memory stage waits in the cycle of the miss and in  |
# |      every cycle of the refill, and not in the lookup after it), DC_LOAD_MISS = L,           |
# |      DC_REFILL_CYCLE >= LW * L; fixed latency: DC_REFILL_CYCLE = L * (the figure of case 2)  |
# |   6  four stores in a row: two to present lines (loaded before), two to absent lines:        |
# |      DC_STORE_HIT = 2, DC_STORE_MISS = 2, PORT_STORE = 4, and no load event (DC_LOAD_MISS,   |
# |      DC_LOOKUP_HIT, DC_REFILL_CYCLE = 0); fixed latency: DC_STORE_WAIT = 4 * (case 2's)      |
# |   6b the same four stores again, other counters: DC_STORE_WAIT = MEMWAIT_STORE (the Memory   |
# |      stage waits for a store in every cycle in which the cache has not accepted it),         |
# |      PORT_WAIT_D + PORT_GRANT_D = DC_STORE_WAIT + 4 (every cycle of a store requests the     |
# |      port, and the cycle of its answer is not a wait)                                        |
# |   6c a loop of loads over the four lines of case 6: the two lines stored to when they were   |
# |      present are still present (a store hit keeps its line) and the two stored to when they  |
# |      were absent are not (a store miss allocates nothing): DC_LOAD_MISS = DC_FILL = 2,       |
# |      DC_LOOKUP_HIT = 4, DC_BEAT = PORT_LOAD = 2 * LW                                         |
# |   7  a cold load in the last word before block A, whose first line the eviction block has    |
# |      evicted from the instruction cache: the refill of A's line holds the port, the load     |
# |      misses and its refill waits for the port: PORT_WAIT_D >= 1, DC_LOAD_MISS = 1,           |
# |      DC_LOOKUP_HIT = 1, PORT_LOAD = DC_BEAT = LW, PORT_GRANT_D >= LW, IC_MISS >= 1; and the  |
# |      same load of a present line: a data-cache hit is answered whatever the arbiter does,    |
# |      so PORT_WAIT_D = 0, DC_LOAD_MISS = 0, DC_LOOKUP_HIT = 1, PORT_LOAD = PORT_GRANT_D =     |
# |      DC_BEAT = 0                                                                             |
# |                                                                                              |
# | Register allocation:                                                                         |
# |     t1: 1       t2: test case number    t3: test peripheral address                          |
# |     s0: eviction entry (block + 12), or 0   s2: the dummy area   s3: the area, saved         |
# |     s4: number of lines (the loop of a load window)  s5: 1 with a data cache                 |
# |     s6: 1 with a data cache and a fixed latency   s7: the area of the pass that counts       |
# |     s8: DC_REFILL_CYCLE of one cold line   s1: DC_STORE_WAIT of one store                    |
# |     s9: the function the trampoline runs   s10: its return   s11: 0x3FFD   ra: return address|
# |     a0-a7: the counters read (a1 .. a7 are counters 3 .. 9)    t4, t5, t6: scratch           |
# |                                                                                              |
# ------------------------------------------------------------------------------------------------

.option norelax

.equ INH_ALL,           0x3FFD
.equ EV_MEMWAIT_LOAD,   41
.equ EV_MEMWAIT_STORE,  42
.equ EV_IC_MISS,        129
.equ EV_PORT_WAIT_D,    135
.equ EV_PORT_GRANT_D,   137
.equ EV_PORT_LOAD,      138
.equ EV_PORT_STORE,     139
.equ EV_DC_LOOKUP_HIT,  140
.equ EV_DC_LOAD_MISS,   141
.equ EV_DC_BEAT,        142
.equ EV_DC_FILL,        143
.equ EV_DC_STORE_HIT,   144
.equ EV_DC_STORE_MISS,  145
.equ EV_DC_STORE_WAIT,  146
.equ EV_DC_REFILL,      147

.equ LW, 4                      # words of a line
.equ L,  4                      # lines of a window with a loop
.equ AREA, 0x44000
.equ PH0, AREA + 16 * 0
.equ PH1, AREA + 16 * 1
.equ PH2, AREA + 16 * 2
.equ PH3, AREA + 16 * 3
.equ PH4, AREA + 16 * 4
.equ PH5, AREA + 16 * 5
.equ PH6, AREA + 16 * 6
.equ PH7, AREA + 16 * 7

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

# every check below needs the data cache: it passes without looking when s5 is 0
.macro assert_equal r1:req, r2:req
    sub  t0, \r1, \r2
    sltu t0, zero, t0
    and  t0, t0, s5
    sw   t0, 0(t3)
.endm

.macro assert_value reg:req, value:req
    li   t0, \value
    assert_equal t0, \reg
.endm

# reg >= value, reg >= other register
.macro assert_ge reg:req, value:req
    li   t0, \value
    sltu t0, \reg, t0
    and  t0, t0, s5
    sw   t0, 0(t3)
.endm

.macro assert_ge_r r1:req, r2:req
    sltu t0, \r1, \r2
    and  t0, t0, s5
    sw   t0, 0(t3)
.endm

# a check that needs a fixed latency as well (s6)
.macro assert_equal_f r1:req, r2:req
    sub  t0, \r1, \r2
    sltu t0, zero, t0
    and  t0, t0, s6
    sw   t0, 0(t3)
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

# Eviction block: evict_block <lines> fills <lines> 16-byte lines, for code placed exactly 8 KiB
# before it, as in hpmcache.s. It is entered with 'jal ra, <block> + 12' and returns to ra.
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

# One window: the function \fn on the area \real (a warm-up pass on the area \dummy), over \cnt lines
# (the loop), with the eviction block between the passes when \ev is 1
.macro window fn:req, real:req, dummy:req, cnt=1, ev=0
    csrw mcountinhibit, s11
    la   s9, \fn
    li   s7, \real
    li   s2, \dummy
    li   s4, \cnt
    .if \ev
    la   s0, evict_a + 12
    .else
    li   s0, 0
    .endif
    jal  ra, tramp
.endm

.section .text.__reset
.balign 512
code_base:
.globl __reset
__reset:
    li   t3, 0x480000
    li   t1, 1
    sw   t1, 0(t3)                # initial test: deliberate fail (proves the fail path works)
    li   s11, INH_ALL
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
    # a data cache? The selector for DC_LOAD_MISS reads back only where that cache's events exist
    li   t0, EV_DC_LOAD_MISS
    csrw 0x323, t0
    csrr t4, 0x323
    csrw 0x323, zero
    addi t4, t4, -EV_DC_LOAD_MISS
    seqz s5, t4
    csrw mcountinhibit, s11
    .irp n, 3, 4, 5, 6, 7, 8, 9
    csrw 0xB80+\n, zero
    .endr

# ---- 2: one cold line and one store, three times each: a fixed latency? ------------------------------
    li   t2, 2
    selc 3, EV_DC_REFILL
    window f_ld, PH3 + 128 * 0, PH1, 1
    rdc  3, s8                    # the cycles of a refill of one cold line
    window f_ld, PH3 + 128 * 1, PH1, 1
    rdc  3, a1
    window f_ld, PH3 + 128 * 2, PH1, 1
    rdc  3, a2
    xor  a1, a1, s8
    xor  a2, a2, s8
    or   a1, a1, a2               # 0 if the three refills took the same time
    li   t4, AREA + 16 * 7        # the two lines of PH7 that the stores of case 6 hit are loaded
    lw   t5, 0(t4)
    lw   t5, 128(t4)
    selc 3, EV_DC_STORE_WAIT
    window f_st1, PH7, PH1, 1
    rdc  3, s1                    # the cycles a store waits
    window f_st1, PH7, PH1, 1
    rdc  3, a3
    window f_st1, PH7, PH1, 1
    rdc  3, a4
    xor  a3, a3, s1
    xor  a4, a4, s1
    or   a3, a3, a4
    or   a1, a1, a3
    seqz s6, a1
    and  s6, s6, s5

# ---- 3: a loop of loads, each of a cold line -------------------------------------------------------------
    li   t2, 3
    selc 3, EV_DC_LOAD_MISS
    selc 4, EV_DC_FILL
    selc 5, EV_DC_BEAT
    selc 6, EV_DC_LOOKUP_HIT
    selc 7, EV_PORT_LOAD
    selc 8, EV_PORT_GRANT_D
    selc 9, EV_PORT_WAIT_D
    window f_ld, PH0, PH1, L
    rdc  3, a1
    rdc  4, a2
    rdc  5, a3
    rdc  6, a4
    rdc  7, a5
    rdc  8, a6
    rdc  9, a7
    assert_value a1, L            # DC_LOAD_MISS
    assert_value a2, L            # DC_FILL
    assert_value a3, LW * L       # DC_BEAT
    assert_value a4, L            # DC_LOOKUP_HIT: the second lookup of every miss
    assert_value a5, LW * L       # PORT_LOAD
    assert_ge a6, LW * L          # PORT_GRANT_D
    assert_value a7, 0            # PORT_WAIT_D

# ---- 4: the same loop over the same lines ----------------------------------------------------------------
    li   t2, 4
    window f_ld, PH0, PH0, L
    rdc  3, a1
    rdc  4, a2
    rdc  5, a3
    rdc  6, a4
    rdc  7, a5
    rdc  8, a6
    rdc  9, a7
    assert_value a1, 0
    assert_value a2, 0
    assert_value a3, 0
    assert_value a4, L            # DC_LOOKUP_HIT: the loads
    assert_value a5, 0
    assert_value a6, 0
    assert_value a7, 0

# ---- 5: refill cycles, the port and the Memory stage ------------------------------------------------------
    li   t2, 5
    selc 3, EV_DC_REFILL
    selc 4, EV_PORT_WAIT_D
    selc 5, EV_PORT_GRANT_D
    selc 6, EV_MEMWAIT_LOAD
    selc 7, EV_DC_LOAD_MISS
    window f_ld, PH2, PH1, L
    rdc  3, a1
    rdc  4, a2
    rdc  5, a3
    rdc  6, a4
    rdc  7, a5
    add  t4, a2, a3
    assert_equal a1, t4           # DC_REFILL_CYCLE = PORT_WAIT_D + PORT_GRANT_D
    add  t4, a5, a1
    assert_equal a4, t4           # MEMWAIT_LOAD = DC_LOAD_MISS + DC_REFILL_CYCLE
    assert_value a5, L
    assert_ge a1, LW * L
    slli t4, s8, 2                # L * (the cycles of one refill)
    assert_equal_f a1, t4

# ---- 6: four stores, two to present lines and two to absent lines -------------------------------------------
    li   t2, 6
    selc 3, EV_DC_STORE_HIT
    selc 4, EV_DC_STORE_MISS
    selc 5, EV_PORT_STORE
    selc 6, EV_DC_LOAD_MISS
    selc 7, EV_DC_LOOKUP_HIT
    selc 8, EV_DC_REFILL
    selc 9, EV_DC_STORE_WAIT
    window f_st, PH7, PH1, 4
    rdc  3, a1
    rdc  4, a2
    rdc  5, a3
    rdc  6, a4
    rdc  7, a5
    rdc  8, a6
    rdc  9, a7
    assert_value a1, 2            # DC_STORE_HIT
    assert_value a2, 2            # DC_STORE_MISS
    assert_value a3, 4            # PORT_STORE
    assert_value a4, 0
    assert_value a5, 0
    assert_value a6, 0
    slli t4, s1, 2                # 4 * (the cycles one store waits)
    assert_equal_f a7, t4

# ---- 6b: the same stores, other counters (the two absent lines are still absent, none is allocated) ---------------
    li   t2, 7
    selc 3, EV_DC_STORE_WAIT
    selc 4, EV_PORT_WAIT_D
    selc 5, EV_PORT_GRANT_D
    selc 6, EV_MEMWAIT_STORE
    selc 7, EV_DC_STORE_HIT
    selc 8, EV_DC_STORE_MISS
    window f_st, PH7, PH1, 4
    rdc  3, a1
    rdc  4, a2
    rdc  5, a3
    rdc  6, a4
    rdc  7, a5
    rdc  8, a6
    assert_equal a1, a4           # DC_STORE_WAIT = MEMWAIT_STORE
    add  t4, a2, a3
    addi t5, a1, 4
    assert_equal t4, t5           # PORT_WAIT_D + PORT_GRANT_D = DC_STORE_WAIT + 4 stores
    assert_value a5, 2
    assert_value a6, 2

# ---- 6c: loads of the four lines: a store hit keeps its line, a store miss allocates nothing -------------------------
    li   t2, 8
    selc 3, EV_DC_LOAD_MISS
    selc 4, EV_DC_FILL
    selc 5, EV_DC_BEAT
    selc 6, EV_DC_LOOKUP_HIT
    selc 7, EV_PORT_LOAD
    window f_ld, PH7, PH1, L
    rdc  3, a1
    rdc  4, a2
    rdc  5, a3
    rdc  6, a4
    rdc  7, a5
    assert_value a1, 2            # the two lines that were absent when stored to
    assert_value a2, 2
    assert_value a3, LW * 2
    assert_value a4, L
    assert_value a5, LW * 2

# ---- 7: a load that meets the refill of an instruction-cache line, cold and present -----------------------------------
    li   t2, 9
    selc 3, EV_PORT_WAIT_D
    selc 4, EV_DC_LOAD_MISS
    selc 5, EV_DC_LOOKUP_HIT
    selc 6, EV_PORT_LOAD
    selc 7, EV_PORT_GRANT_D
    selc 8, EV_IC_MISS
    selc 9, EV_DC_BEAT
    window f_ev, PH4, PH5, 1, 1
    rdc  3, a1
    rdc  4, a2
    rdc  5, a3
    rdc  6, a4
    rdc  7, a5
    rdc  8, a6
    rdc  9, a7
    assert_ge a1, 1               # the refill of the load's line waits behind the instruction-cache refill
    assert_value a2, 1
    assert_value a3, 1
    assert_value a4, LW
    assert_ge a5, LW
    assert_ge a6, 1
    assert_value a7, LW
    li   t2, 10
    window f_ev, PH6, PH6, 1, 1
    rdc  3, a1
    rdc  4, a2
    rdc  5, a3
    rdc  6, a4
    rdc  7, a5
    rdc  8, a6
    rdc  9, a7
    assert_value a1, 0            # a data-cache hit is answered during the instruction-cache refill
    assert_value a2, 0
    assert_value a3, 1
    assert_value a4, 0
    assert_value a5, 0
    assert_ge a6, 1
    assert_value a7, 0

finish:
    csrw mcountinhibit, zero
nocounters:                       # (a CPU without mcountinhibit would trap on the csrw above)
    halt
    fail

# ================================================================================================
# The windows
# ================================================================================================
.org code_base + 0x1000
f_ev:                             # one load, in the last word before block A (s7 = its address)
    csrw mcountinhibit, zero      # open
    .rept 14
    nop
    .endr
    lw   a0, 0(s7)
a_block:
    .rept 32
    nop
    .endr
a_tail:
    .rept 12
    nop
    .endr
    csrw mcountinhibit, s11       # close
    ret
    nop
    nop

.org code_base + 0x1200
f_ld:                             # s4 loads of lines 128 bytes apart from s7
    csrw mcountinhibit, zero      # open
    nop
    nop
    mv   t4, s7
    mv   t5, s4
1:  lw   t6, 0(t4)
    addi t4, t4, 128
    addi t5, t5, -1
    bnez t5, 1b
    nop
    nop
    nop
    csrw mcountinhibit, s11       # close
    ret
    nop
    nop
    nop
    nop

.org code_base + 0x1300
f_st:                             # four stores, 128 bytes apart, from s7
    csrw mcountinhibit, zero      # open
    nop
    nop
    li   t4, 0x5A5A5A5A
    sw   t4, 0(s7)
    sw   t4, 128(s7)
    sw   t4, 256(s7)
    sw   t4, 384(s7)
    nop
    nop
    nop
    csrw mcountinhibit, s11       # close
    ret
    nop
    nop
    nop
    nop

.org code_base + 0x1400
f_st1:                            # one store to s7
    csrw mcountinhibit, zero      # open
    nop
    nop
    li   t4, 0x5A5A5A5A
    sw   t4, 0(s7)
    nop
    nop
    nop
    csrw mcountinhibit, s11       # close
    ret
    nop
    nop
    nop
    nop

# The trampoline and the function that clears the counters: lines 27 to 31 of a 512-byte cache of
# 16-byte lines (0x1B0 + 0x1000 mod 0x200 = 0x1B0), where no window stands
.org code_base + 0x15B0
clr7:
    csrw 0xB03, zero
    csrw 0xB04, zero
    csrw 0xB05, zero
    csrw 0xB06, zero
    csrw 0xB07, zero
    csrw 0xB08, zero
    csrw 0xB09, zero
    ret
tramp:                            # s9 = the function, s7 = its area, s2 = the dummy area, s0 = eviction entry or 0
    mv   s10, ra
    mv   s3, s7
    mv   s7, s2
    jalr ra, 0(s9)                # the warm-up pass on the dummy area (its counts are cleared)
    mv   s7, s3
    jal  ra, clr7
    beqz s0, 2f
    jalr ra, 0(s0)                # the eviction block
2:  jalr ra, 0(s9)                # the pass that counts
    jr   s10
tramp_end:

# The eviction block, exactly 8 KiB after block A
.org a_block + 0x2000
evict_a:
    evict_block 8
