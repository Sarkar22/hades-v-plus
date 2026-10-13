# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: hpmcache.s
#
# ------------------------------------------------------------------------------------------------
# |                                                                                              |
# | THE I-CACHE EVENTS IN THE PERFORMANCE COUNTERS, for the memory-system checks (test/memsys/    |
# | programs.py) in a simulator with an instruction cache (docs/CACHES.md; make ICACHE=512 or     |
# | ICACHE=8192, any LINE). The counters count the cache's event signals (codes 128 to 139, 160 |
# | and 161); the cache's own CACHE_STATS line, which sim/top.sv prints, counts the same events  |
# | and must agree with the counters at the end of the run (the monitor of sim/top.sv does that  |
# | comparison for the HPM_PRESET simulators H and I).                                           |
# |                                                                                              |
# | Without a cache the selectors for these codes read back 0: the program finds out (s5 = 1 with |
# | a cache) and every check that needs the cache is then made 'without looking', so the         |
# | reports are the same in every configuration, as programs.py requires.                        |
# |                                                                                              |
# | CODE UNDER TEST (the layout is what makes the counts exact; every part is a multiple of 64   |
# | bytes, 64-byte aligned, so a cache line of any size from 8 to 64 bytes holds code of one     |
# | part only):                                                                                  |
# |   afunc   head (64 bytes: csrw open, 14 nops, a load of a RAM word), block A (128 bytes of    |
# |           nops), tail (64 bytes: 12 nops, csrw close, ret)                                   |
# |   wp1,wp2 head (a jal as the last word, or the one before it), skipped part (64 bytes of nops  |
# |           that the jal skips: the wrong path), target part (nops, csrw close, ret)             |
# |   An eviction block at +8 KiB from block A (and from the skipped part) holds code that maps  |
# |   to the same lines of a direct-mapped cache of 512 bytes and of 8 KiB; running it evicts     |
# |   block A (the skipped part) and nothing else (fetchredirect.s, evict_block).                |
# |   The trampolines (tramp_evict, tramp_warm, clr7) stand in the lines 27 to 31 of a 512-byte  |
# |   cache of 16-byte lines, where none of the code above stands, and are the only code that    |
# |   runs between a warm-up pass and the pass that counts.                                       |
# | EVICTION WINDOW: a warm-up pass, the counters cleared, the eviction block, then the pass.     |
# | WARM WINDOW: a warm-up pass, the counters cleared, the pass again.                            |
# |                                                                                              |
# | Counters, set 1:  3 IC_MISS  4 IC_FILL  5 IC_BEAT  6 IC_HIT_USED  7 FETCH_DELIVER             |
# |                   8 IC_ABANDON  9 IC_MISS_JUMP                                               |
# |   evict   IC_FILL = IC_MISS (no refill is running at the end), IC_BEAT = 32 (every word of    |
# |           block A once), IC_MISS a power of two from 2 to 16 (128 bytes / the line size; 8 for |
# |           16-byte lines), IC_HIT_USED = FETCH_DELIVER, IC_ABANDON = IC_MISS_JUMP = 0          |
# |   warm    IC_MISS = IC_FILL = IC_BEAT = 0, IC_HIT_USED = FETCH_DELIVER                       |
# | Counters, set 2:  3 PORT_WAIT_D  4 PORT_WAIT_I  5 PORT_GRANT_I  6 PORT_GRANT_D                |
# |                   7 PORT_LOAD  8 PORT_STORE  9 IC_MISS                                       |
# |   evict   PORT_LOAD = 1 (the load in the head), PORT_STORE = 0, PORT_GRANT_D >= 1; with lines |
# |           of 4 words or more PORT_WAIT_D >= 1 (that load meets the refill of block A's first  |
# |           line: it is the last word before it)                                               |
# |   warm    PORT_LOAD = 1, PORT_WAIT_I = PORT_GRANT_I = PORT_WAIT_D = 0                        |
# | Counters, set 3:  3 IC_MISS  4 IC_ABANDON  5 IC_MISS_JUMP  6 IC_FILL                          |
# |   wp1     a jal as the last word of a warm line, the wrong-path line absent: IC_MISS >= 1,    |
# |           IC_ABANDON >= 1 (the refill that nobody wants), IC_FILL = IC_MISS                  |
# |   wp2     the jal one word earlier, so that the lookup of the absent line falls in the cycle  |
# |           in which Execute redirects Fetch: IC_MISS_JUMP >= 1, IC_MISS_JUMP <= IC_MISS      |
# | Counter 3, IC_SNOOP_INVAL: a store of a nop word into a cached line of code: 1; into the data |
# |   area: 0; into a line of block A that the eviction block has evicted: 0                      |
# |                                                                                              |
# | Register allocation:                                                                         |
# |     t1: 1       t2: test case number    t3: test peripheral address     t6: address of buf   |
# |     s5: 1 with an instruction cache      s6: LINE_WORDS-ish: IC_MISS of the last window       |
# |     s8: eviction entry (block + 12)  s9: the function the trampoline runs  s10: its return   |
# |     s11: 0x3FFD   ra: return address   a0-a7, s0-s4, s7: the checks                         |
# |                                                                                              |
# ------------------------------------------------------------------------------------------------

.option norelax

.equ INH_ALL,         0x3FFD
.equ EV_CYCLE,        1
.equ EV_FETCH_DELIVER, 47
.equ EV_IC_MISS,      129
.equ EV_IC_BEAT,      130
.equ EV_IC_FILL,      131
.equ EV_IC_ABANDON,   132
.equ EV_IC_SNOOP,     133
.equ EV_PORT_WAIT_I,  134
.equ EV_PORT_WAIT_D,  135
.equ EV_PORT_GRANT_I, 136
.equ EV_PORT_GRANT_D, 137
.equ EV_PORT_LOAD,    138
.equ EV_PORT_STORE,   139
.equ EV_IC_HIT_USED,  160
.equ EV_IC_MISS_JUMP, 161

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

# every check below needs the cache: it passes without looking when s5 is 0
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

# reg >= value
.macro assert_ge reg:req, value:req
    li   t0, \value
    sltu t0, \reg, t0
    and  t0, t0, s5
    sw   t0, 0(t3)
.endm

# reg <= other register
.macro assert_le r1:req, r2:req
    sltu t0, \r2, \r1
    and  t0, t0, s5
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
# before it. It is entered with 'jal ra, <block> + 12' and returns to ra. (As in fetchredirect.s:
# every even line holds three nops and, at word 3, a jal to word 3 of line k + 2, the last one a
# jalr; the other words never run, but Fetch presents them on the wrong path and a cache refills
# those lines too, because a started refill always completes.)
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

.section .text.__reset
.balign 512
code_base:
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
    # an instruction cache? The selector for IC_MISS reads back only where the cache's events exist
    li   t0, EV_IC_MISS
    csrw 0x323, t0
    csrr t4, 0x323
    csrw 0x323, zero
    addi t4, t4, -EV_IC_MISS
    seqz s5, t4
    csrw mcountinhibit, s11
    .irp n, 3, 4, 5, 6, 7, 8, 9
    csrw 0xB80+\n, zero
    .endr

# ---- set 1: block A, evicted and warm -------------------------------------------------------------
    li   t2, 1
    selc 3, EV_IC_MISS
    selc 4, EV_IC_FILL
    selc 5, EV_IC_BEAT
    selc 6, EV_IC_HIT_USED
    selc 7, EV_FETCH_DELIVER
    selc 8, EV_IC_ABANDON
    selc 9, EV_IC_MISS_JUMP
    la   s9, afunc
    la   s8, evict_a + 12
    jal  ra, tramp_evict
    rdc  3, a1
    rdc  4, a2
    rdc  5, a3
    rdc  6, a4
    rdc  7, a5
    rdc  8, a6
    rdc  9, a7
    mv   s6, a1
    assert_equal a2, a1           # every refill ends: IC_FILL = IC_MISS
    assert_value a3, 32           # the 32 words of block A, once
    addi t4, a1, -1
    and  t4, t4, a1
    assert_value t4, 0            # IC_MISS is a power of two ...
    assert_ge a1, 2               # ... of at least 2 ...
    li   t4, 17
    sltu t4, a1, t4
    xori t4, t4, 1
    assert_value t4, 0            # ... and at most 16
    assert_equal a4, a5           # every fetch answer that Decode takes is a hit used
    assert_value a6, 0            # nothing is abandoned in straight-line code
    assert_value a7, 0
    li   t2, 2
    jal  ra, tramp_warm
    rdc  3, a1
    rdc  4, a2
    rdc  5, a3
    rdc  6, a4
    rdc  7, a5
    rdc  8, a6
    assert_value a1, 0            # the second pass hits everywhere
    assert_value a2, 0
    assert_value a3, 0
    assert_equal a4, a5
    assert_value a6, 0

# ---- set 2: the memory port ---------------------------------------------------------------------------
    li   t2, 3
    csrw mcountinhibit, s11
    selc 3, EV_PORT_WAIT_D
    selc 4, EV_PORT_WAIT_I
    selc 5, EV_PORT_GRANT_I
    selc 6, EV_PORT_GRANT_D
    selc 7, EV_PORT_LOAD
    selc 8, EV_PORT_STORE
    selc 9, EV_IC_MISS
    la   s9, afunc
    la   s8, evict_a + 12
    jal  ra, tramp_evict
    rdc  3, a1
    rdc  6, a4
    rdc  7, a5
    rdc  8, a6
    rdc  9, a7
    assert_value a5, 1            # the load of the head is the only data transfer
    assert_value a6, 0
    assert_ge a4, 1
    li   t4, 9
    sltu t4, a7, t4               # 1 if IC_MISS <= 8: lines of 4 words or more
    seqz t0, a1                   # 1 if PORT_WAIT_D = 0
    and  t0, t0, t4
    and  t0, t0, s5
    sw   t0, 0(t3)                # PORT_WAIT_D >= 1 where the line has at least 4 words
    li   t2, 4
    jal  ra, tramp_warm
    rdc  3, a1
    rdc  4, a2
    rdc  5, a3
    rdc  7, a5
    assert_value a5, 1
    assert_value a2, 0            # no refill, so the I side never waits for the port or uses it
    assert_value a3, 0
    assert_value a1, 0

# ---- set 3: the wrong path ------------------------------------------------------------------------------
    li   t2, 5
    csrw mcountinhibit, s11
    selc 3, EV_IC_MISS
    selc 4, EV_IC_ABANDON
    selc 5, EV_IC_MISS_JUMP
    selc 6, EV_IC_FILL
    la   s9, wp1
    la   s8, evict_w1 + 12
    jal  ra, tramp_evict
    rdc  3, a1
    rdc  4, a2
    rdc  5, a3
    rdc  6, a4
    assert_ge a1, 1               # the wrong path's line is refilled
    assert_ge a2, 1               # ... and nobody wants it
    assert_equal a4, a1
    assert_le a3, a1
    li   t2, 6
    la   s9, wp2
    la   s8, evict_w2 + 12
    jal  ra, tramp_evict
    rdc  3, a1
    rdc  4, a2
    rdc  5, a3
    rdc  6, a4
    assert_ge a1, 1
    assert_ge a3, 1               # the lookup that misses falls in the cycle of the redirect
    assert_equal a4, a1
    assert_le a3, a1

# ---- IC_SNOOP_INVAL ------------------------------------------------------------------------------------------
    li   t2, 7
    csrw mcountinhibit, s11
    selc 3, EV_IC_SNOOP
    la   s9, snoop_code
    jal  ra, tramp_warm
    rdc  3, a1
    assert_value a1, 1            # a store into a cached line of code
    la   s9, snoop_data
    jal  ra, tramp_warm
    rdc  3, a1
    assert_value a1, 0            # a store into the data area
    la   s9, snoop_absent
    la   s8, evict_a + 12
    jal  ra, tramp_evict
    rdc  3, a1
    assert_value a1, 0            # a store into a line that the eviction block has evicted

finish:
    csrw mcountinhibit, zero
nocounters:                       # (a CPU without mcountinhibit would trap on the csrw above)
    halt
    fail

# ================================================================================================
# The code under test
# ================================================================================================
.org code_base + 0x1000
afunc:
    csrw mcountinhibit, zero      # open
    .rept 14
    nop
    .endr
    lw   a0, 0(t6)                # the last word before block A
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
afunc_end:

# The wrong-path functions: head, skipped part, target part
.org code_base + 0x1200
wp1:
    csrw mcountinhibit, zero
    .rept 14
    nop
    .endr
    jal  zero, wp1_target         # the last word of a 64-byte part
wp1_w1:
    .rept 16
    nop
    .endr
wp1_target:
    .rept 12
    nop
    .endr
    csrw mcountinhibit, s11
    ret
    nop
    nop

.org code_base + 0x1400
wp2:
    csrw mcountinhibit, zero
    .rept 13
    nop
    .endr
    jal  zero, wp2_target         # one word before the last
    nop
wp2_w1:
    .rept 16
    nop
    .endr
wp2_target:
    .rept 12
    nop
    .endr
    csrw mcountinhibit, s11
    ret
    nop
    nop

# The trampolines and the function that clears the counters: lines 27 to 31 of a 512-byte cache of
# 16-byte lines (0x1B0 + 0x1000 mod 0x200 = 0x1B0)
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
tramp_evict:                      # s9 = the function, s8 = the eviction block + 12
    mv   s10, ra
    jal  ra, clr7
    jalr ra, 0(s9)                # the warm-up pass (its counts are cleared)
    jal  ra, clr7
    jalr ra, 0(s8)                # the eviction block
    jalr ra, 0(s9)                # the pass that counts
    jr   s10
tramp_warm:
    mv   s10, ra
    jalr ra, 0(s9)                # a warm-up pass (the lines past the function's end may have been evicted)
    jal  ra, clr7
    jalr ra, 0(s9)                # the pass that counts
    jr   s10
tramp_end:

# The snoop functions: a store of a nop word (0x00000013) into word 5 of their own code, into the
# data area, or into block A
.org code_base + 0x1600
snoop_code:
    la   t5, snoop_code
    li   t4, 0x13
    nop
    nop                           # words 4 to 7: the line that the store hits (word 5)
    nop
    nop
    nop
    csrw mcountinhibit, zero
    nop
    nop                           # (the store is clearly inside the window)
    sw   t4, 20(t5)               # into a line of the code that is running: cached and valid
    .rept 6
    nop
    .endr
    csrw mcountinhibit, s11
    ret

.org code_base + 0x1700
snoop_data:
    li   t4, 0x13
    nop
    nop
    nop
    nop
    nop
    csrw mcountinhibit, zero
    nop
    nop                           # (the store is clearly inside the window)
    sw   t4, 8(t6)                # into buf
    .rept 6
    nop
    .endr
    csrw mcountinhibit, s11
    ret

.org code_base + 0x1800
snoop_absent:
    la   t5, a_block
    li   t4, 0x13
    nop
    nop
    nop
    nop
    csrw mcountinhibit, zero
    nop
    nop                           # (the store is clearly inside the window)
    sw   t4, 0(t5)                # into block A: absent after the eviction block, invalid after the warm-up pass
    .rept 6
    nop
    .endr
    csrw mcountinhibit, s11
    ret

# The eviction blocks, exactly 8 KiB after block A and after the wrong-path parts of wp1 and wp2
.org a_block + 0x2000
evict_a:
    evict_block 8
.org wp1_w1 + 0x2000
evict_w1:
    evict_block 4
.org wp2_w1 + 0x2000
evict_w2:
    evict_block 4

.balign 64
buf:
    .word 0x11111111, 0x22222222, 0x33333333, 0x44444444
    .word 0, 0, 0, 0
