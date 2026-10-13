# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: hpm.s
#
# ------------------------------------------------------------------------------------------------
# |                                                                                              |
# | HARDWARE PERFORMANCE COUNTERS: every event provoked a known number of times (docs/           |
# | EXTENSIONS.md, "Hardware Performance Counters").                                             |
# |                                                                                              |
# | The counters mhpmcounter3..9 (0xB03.., high halves 0xB83..) count the event whose code their |
# | selector mhpmevent3..9 (0x323..) holds; mcountinhibit (0x320) freezes them. Every check      |
# | below puts a known number of one kind of instruction between two writes of mcountinhibit     |
# | (the window), and compares the counters with that number. A window is opened with            |
# | 'csrw mcountinhibit, zero' and closed with 'csrw mcountinhibit, s11' (s11 = every            |
# | implemented bit, 0x3FFD, so mcycle and minstret stand still outside the window too). The     |
# | opening instruction is not counted (the inhibit register still holds the old value when it   |
# | passes Writeback), the closing instruction is: a window of k instructions gives INSTRET k+1, |
# | and CSR counts the closing instruction. The edges of a window stand in straight-line         |
# | code padded with nops.                                                                       |
# |                                                                                              |
# | EXACTNESS. Events counted at Writeback (the retirement classes, CYCLE, INSTRET) are exact at |
# | any latency of the memory. The trap events and the identities between counters are exact     |
# | too. The pipeline events (stalls, waits, hazards, fetch) are exact for a memory that answers |
# | in the cycle of the request: at start the program times 32 nops that have not run before     |
# | (33 cycles on that memory; a slow memory or an instruction cache needs more) and keeps the   |
# | result in s5. Checks that need that memory ('_g' in the macro names) pass without looking    |
# | when s5 is 0; they are the checks WAIT_STATES would otherwise have to excuse, so the reports |
# | are the same in every configuration (test/memsys/programs.py).                               |
# |                                                                                              |
# | The test needs seven counters (the standard build). With fewer (make HPM_COUNTERS=<n>) it    |
# | checks mcountinhibit and the selectors against that number, and stops. On a CPU without the  |
# | counters (the golden CPU) it fails the first check on the selectors and stops; before that   |
# | its accesses to 0x320 and 0x323.. show the legality of the golden decoder: they trap (the    |
# | handler counts and skips them).                                                              |
# |                                                                                              |
# | Every assert is executed once, in source order, so a report's number is its position in the  |
# | source (report 1 is the deliberate initial fail).                                            |
# |                                                                                              |
# | Register allocation:                                                                         |
# |     x0  (zero): hardwired 0               x5  (t0): reserved for macro use                   |
# |     t1: 1       t2: test case number      t3: test peripheral address (0x480000)              |
# |     t4, t5: scratch of the check macros   t6: address of buf (data for loads and stores)     |
# |     s4: 0 (a register that holds zero)    s5: 1 on a memory that answers in one cycle        |
# |     s6: wrong causes seen by the handler  s7: causes the handler accepts (bit mask)          |
# |     s8: interrupts taken                  s9: last mcause seen by the handler                |
# |     s10: exceptions skipped               s11: 0x3FFD, the closing value of a window         |
# |     gp, tp: the trap handler's scratch    a0-a7, s0-s3: the cases                            |
# |                                                                                              |
# ------------------------------------------------------------------------------------------------

# The toolchain defaults to plain rv32i; the instructions of the windows below need these
# (as in mul.s, zba.s, zbb.s, ...).
.option arch, +m, +zba, +zbb, +zbs, +zbkb, +zbkx, +zknh

.equ INH_ALL,    0x3FFD
.equ MTIME,      0x214004
.equ MTIMECMP,   0x21400C
.equ MTIMECMPH,  0x214010

# --- events (hpm.h) ---
.equ EV_CYCLE,           1
.equ EV_INSTRET,         2
.equ EV_LOAD,            3
.equ EV_STORE,           4
.equ EV_BRANCH,          5
.equ EV_BRANCH_TAKEN,    6
.equ EV_JUMP,            7
.equ EV_MUL,             8
.equ EV_DIV,             9
.equ EV_CSR,             10
.equ EV_BITMANIP,        11
.equ EV_CRYPTO,          12
.equ EV_MRET,            13
.equ EV_FENCE_I,         14
.equ EV_REPLAY,          15
.equ EV_BR_MISPREDICT,   16
.equ EV_BP_NN,           17
.equ EV_BP_NT,           18
.equ EV_BP_TN,           19
.equ EV_BP_TT,           20
.equ EV_EXCEPTION,       21
.equ EV_EXC_ECALL,       22
.equ EV_EXC_OTHER,       23
.equ EV_INTERRUPT,       24
.equ EV_INT_TIMER,       25
.equ EV_INT_EXT,         26
.equ EV_FETCH_WAIT,      32
.equ EV_FRONT_OK,        33
.equ EV_HAZARD,          34
.equ EV_MSTALL_ANY,      35
.equ EV_MEMWAIT_ANY,     36
.equ EV_REDIRECT_ANY,    37
.equ EV_HAZARD_LOAD,     38
.equ EV_MSTALL_MUL,      39
.equ EV_MSTALL_DIV,      40
.equ EV_MEMWAIT_LOAD,    41
.equ EV_MEMWAIT_STORE,   42
.equ EV_MEMWAIT_IO,      43
.equ EV_REDIRECT_BRANCH, 44
.equ EV_REDIRECT_JUMP,   45
.equ EV_REDIRECT_WB,     46
.equ EV_FETCH_DELIVER,   47
.equ EV_FETCH_DISCARD,   48
.equ EV_IO_ACCESS,       49

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

# The same, but only when s5 says that the memory answers in one cycle
.macro assert_equal_g r1:req, r2:req
    sub  t0, \r1, \r2
    sltu t0, zero, t0
    and  t0, t0, s5
    sw   t0, 0(t3)
.endm

.macro assert_value reg:req, value:req
    li   t0, \value
    assert_equal t0, \reg
.endm

.macro assert_value_g reg:req, value:req
    li   t0, \value
    assert_equal_g t0, \reg
.endm

# fail unless the register is non-zero
.macro assert_nonzero reg:req
    sltu t0, zero, \reg
    xori t0, t0, 1
    sw   t0, 0(t3)
.endm

.macro assert_nonzero_g reg:req
    sltu t0, zero, \reg
    xori t0, t0, 1
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

.macro pad
    nop
    nop
    nop
    nop
    nop
    nop
.endm

# counter n (3..9): select an event, read, check, clear
.macro selc n:req, code:req
    li   t0, \code
    csrw 0x320+\n, t0
.endm

.macro rdc n:req, reg:req
    csrr \reg, 0xB00+\n
.endm

# value of counter n against an immediate (the counters are frozen when this runs)
.macro chk n:req, value:req
    csrr t4, 0xB00+\n
    li   t5, \value
    assert_equal t4, t5
.endm

.macro chk_g n:req, value:req
    csrr t4, 0xB00+\n
    li   t5, \value
    assert_equal_g t4, t5
.endm

# clear the seven counters (both halves) and the predictor's counters
.macro clear_all
    .irp n, 3, 4, 5, 6, 7, 8, 9
    csrw 0xB00+\n, zero
    csrw 0xB80+\n, zero
    .endr
    csrw 0xB0A, zero
    csrw 0xB0B, zero
    csrw 0xB0C, zero
    csrw 0xB0D, zero
.endm

# select no event on the seven counters
.macro select_none
    .irp n, 3, 4, 5, 6, 7, 8, 9
    csrw 0x320+\n, zero
    .endr
.endm

.macro open
    csrw mcountinhibit, zero
.endm

.macro close
    csrw mcountinhibit, s11
.endm

# the access forms on one CSR: all six, and a csrrs/csrrc whose rs1 field is non-zero and holds 0
.macro forms csr:req
    csrrw  a0, \csr, zero
    csrrs  a0, \csr, zero
    csrrc  a0, \csr, zero
    csrrwi a0, \csr, 0
    csrrsi a0, \csr, 0
    csrrci a0, \csr, 0
    csrrs  a0, \csr, s4
    csrrc  a0, \csr, s4
.endm

.section .text.__reset
.globl __reset
__reset:
    li   t3, 0x480000
    li   t1, 1
    sw   t1, 0(t3)                # initial test: deliberate fail (proves the fail path works)
    li   s4, 0
    li   s6, 0
    li   s7, 0
    li   s8, 0
    li   s9, 0
    li   s10, 0
    li   s11, INH_ALL
    la   t6, buf
    la   t0, trap_handler
    csrw mtvec, t0
    li   t0, 0x880
    csrw mie, t0                  # MEIE and MTIE
    csrw mstatus, zero            # interrupts off
    sw   zero, 4(t3)              # no test-device interrupt
    li   t0, MTIMECMPH
    li   t4, -1
    sw   t4, 0(t0)                # timer disarmed
    flush_pipeline
    # ---- the memory's speed: 32 nops that have not run before take 33 cycles between two reads ----
    csrr s0, mcycle
    .rept 32
    nop
    .endr
    csrr s1, mcycle
    sub  s1, s1, s0
    addi s1, s1, -33
    seqz s5, s1
    flush_pipeline

# ----------------------------------------------------------------------------------------------
# 1. Legality (the decoder; the golden decoder's answer is recorded by the same accesses)
# ----------------------------------------------------------------------------------------------
case1:
    li   t2, 1
    li   s10, 0
    # the six access forms (and csrrs/csrrc with a non-zero rs1 field holding 0) on 0x320, 0x323, 0xB03 and 0xB83
    forms 0x320
    forms 0x323
    forms 0xB03
    forms 0xB83
    assert_value s10, 0           # none of them traps
    # no counters here (the golden CPU, or a build without them): stop at once
    li   t0, 1
    li   t4, 0
    csrw 0x323, t0
    csrr t4, 0x323
    csrw 0x323, zero
    assert_value t4, 1            # a code written to mhpmevent3 reads back
    bne  t4, t1, finish
    # addresses that must still trap with 'illegal instruction' (mcause 2)
    li   s10, 0
    li   s6, 0
    li   s7, 4                    # the only accepted cause: 2
    csrr a0, 0x7C0
    csrr a0, 0xC03
    csrr a0, 0xC83
    csrr a0, 0xB01
    csrr a0, 0xB81
    csrr a0, 0x321
    csrr a0, 0x322
    csrr a0, 0xB20
    csrr a0, 0xBA0
    csrw 0x723, a0
    csrw 0x729, a0
    assert_value s10, 11          # all eleven trap
    assert_value s6, 0            # each with mcause 2

# ----------------------------------------------------------------------------------------------
# 2. How many counters, and mcountinhibit as a WARL register
# ----------------------------------------------------------------------------------------------
case2:
    li   t2, 2
    li   s0, 0                    # N
.macro probe_n n:req
    li   t0, 1
    csrw 0x320+\n, t0
    csrr t4, 0x320+\n
    csrw 0x320+\n, zero
    bne  t4, t1, probe_done
    addi s0, s0, 1
.endm
    probe_n 3
    probe_n 4
    probe_n 5
    probe_n 6
    probe_n 7
    probe_n 8
    probe_n 9
probe_done:
    # the writable mask: CY, IR, counters 3..2+N and the predictor's counters 10..13
    li   a6, 1
    sll  a6, a6, s0
    addi a6, a6, -1
    slli a6, a6, 3
    li   t0, 0x3C05
    or   a6, a6, t0
    li   t0, -1
    csrw mcountinhibit, t0
    csrr a1, mcountinhibit
    csrw mcountinhibit, zero
    csrr a2, mcountinhibit
    assert_equal a1, a6           # all ones written: exactly the implemented bits (0x3FFD for seven counters)
    assert_value a2, 0
    li   t0, 7
    bne  s0, t0, finish           # fewer than seven counters: the rest of the test needs the standard build
    # a counter's inhibit bit is writable alone, and TM (bit 1) is not
    li   t0, 2
    csrw mcountinhibit, t0
    csrr a1, mcountinhibit
    li   t0, 0x8000
    csrw mcountinhibit, t0
    csrr a2, mcountinhibit
    csrw mcountinhibit, zero
    assert_value a1, 0
    assert_value a2, 0

# ----------------------------------------------------------------------------------------------
# 3. The selectors are WARL: a code that this build has, else 0
# ----------------------------------------------------------------------------------------------
case3:
    li   t2, 3
    li   s1, 0                    # wrong read-backs
    li   a0, 0
sel_loop:
    csrw 0x323, a0
    csrr a1, 0x323
    li   a2, 0
    addi t4, a0, -1               # 1..26 and 32..49 exist in the standard build
    sltiu t4, t4, 26
    addi t5, a0, -32
    sltiu t5, t5, 18
    or   t4, t4, t5
    beqz t4, 1f
    mv   a2, a0
1:  xor  t4, a1, a2
    beqz t4, sel_next
    # a mismatch is allowed where an instruction cache would add its events (128..139, 160, 161),
    # but only on a memory that is not the plain one (s5 = 0), and only as the code itself
    bnez s5, sel_bad
    bne  a1, a0, sel_bad
    addi t5, a0, -128
    sltiu t5, t5, 12
    addi t4, a0, -160
    sltiu t4, t4, 2
    or   t5, t5, t4
    bnez t5, sel_next
sel_bad:
    addi s1, s1, 1
sel_next:
    addi a0, a0, 1
    li   t0, 256
    bne  a0, t0, sel_loop
    assert_value s1, 0
    csrw 0x323, zero
    # values that are not codes: everything above 8 bits
    li   s1, 0
    .irp v, 256, 0x101, 0x1000001, 0x80000001, 0xFFFFFFFF, 0x180
    li   t0, \v
    csrw 0x323, t0
    csrr t4, 0x323
    or   s1, s1, t4
    .endr
    assert_value s1, 0
    csrw 0x323, zero
    # all seven selectors accept a code of the build and refuse one that it lacks
    li   s1, 0
    .irp n, 3, 4, 5, 6, 7, 8, 9
    li   t0, 42
    csrw 0x320+\n, t0
    csrr t4, 0x320+\n
    xori t4, t4, 42
    or   s1, s1, t4
    li   t0, 100
    csrw 0x320+\n, t0
    csrr t4, 0x320+\n
    or   s1, s1, t4
    csrw 0x320+\n, zero
    .endr
    assert_value s1, 0

# ----------------------------------------------------------------------------------------------
# 4. The fixed selectors 11..13, the predictor's mode register, and the registers that read 0
# ----------------------------------------------------------------------------------------------
case4:
    li   t2, 4
    csrr a1, 0x32B
    csrr a2, 0x32C
    csrr a3, 0x32D
    li   t0, 0x31
    csrw 0x32B, t0
    csrw 0x32C, zero
    csrw 0x32D, t0
    csrr a4, 0x32B
    csrr a5, 0x32C
    csrr a6, 0x32D
    assert_value a1, 18           # BP_NT
    assert_value a2, 19           # BP_TN
    assert_value a3, 20           # BP_TT
    assert_value a4, 18           # a write changes nothing
    assert_value a5, 19
    assert_value a6, 20
    li   t0, 3
    csrw 0x32A, t0
    csrr a1, 0x32A
    csrw 0x32A, zero
    csrr a2, 0x32A
    assert_value a1, 3            # mhpmevent10 is the predictor's mode register
    assert_value a2, 0
    li   s1, 0
    li   t0, 0x55
    .irp c, 0x32E, 0x33F, 0xB0E, 0xB1F, 0xB8A, 0xB8D, 0xB8E, 0xB9F
    csrw \c, t0
    csrr t4, \c
    or   s1, s1, t4
    .endr
    assert_value s1, 0            # selectors 14..31 and counters 14..31 read 0 and ignore writes

# ----------------------------------------------------------------------------------------------
# 5. The high half is as wide as the counter: 48 bits
# ----------------------------------------------------------------------------------------------
case5:
    li   t2, 5
    csrw mcountinhibit, s11
    li   t0, -1
    csrw 0xB83, t0
    csrr a1, 0xB83
    csrr a2, 0xB03
    csrw 0xB89, t0
    csrr a3, 0xB89
    csrw 0xB03, t0
    csrr a4, 0xB03
    csrr a5, 0xB83
    assert_value a1, 0x0000FFFF   # bits above bit 47 read 0
    assert_value a2, 0            # the low half was not touched
    assert_value a3, 0x0000FFFF
    assert_value a4, 0xFFFFFFFF
    assert_value a5, 0x0000FFFF
    clear_all

# ----------------------------------------------------------------------------------------------
# 6. A window of nops: INSTRET and CYCLE against minstret and mcycle
# ----------------------------------------------------------------------------------------------
case6:
    li   t2, 6
    csrw mcountinhibit, s11
    selc 3, EV_INSTRET
    selc 4, EV_CYCLE
    clear_all
    csrr s0, minstret
    csrr s1, mcycle
    open
    .rept 20
    nop
    .endr
    close
    csrr s2, minstret
    csrr s3, mcycle
    sub  s2, s2, s0
    sub  s3, s3, s1
    rdc  3, a1
    rdc  4, a2
    assert_equal a1, s2           # the counter and minstret count the same instructions
    assert_equal a2, s3           # ... and mcycle the same cycles as CYCLE
    assert_value a1, 21           # 20 nops and the closing instruction; the opening one is not counted
    assert_value s2, 21

# ----------------------------------------------------------------------------------------------
# 7. The write forms on an inhibited counter, on mcycle and on minstret (all six write them)
# ----------------------------------------------------------------------------------------------
case7:
    li   t2, 7
    csrw mcountinhibit, s11       # everything stands still
    li   t0, 0x00FF00FF
    csrw 0xB03, t0
    li   t0, 0x0F000F00
    csrrs a1, 0xB03, t0
    csrr a2, 0xB03
    li   t0, 0x000F000F
    csrrc a3, 0xB03, t0
    csrr a4, 0xB03
    csrrsi a5, 0xB03, 0x15
    csrr a6, 0xB03
    csrrci a7, 0xB03, 0x05
    csrr s0, 0xB03
    assert_value a1, 0x00FF00FF   # csrrs returns the old value
    assert_value a2, 0x0FFF0FFF
    assert_value a3, 0x0FFF0FFF
    assert_value a4, 0x0FF00FF0
    assert_value a5, 0x0FF00FF0
    assert_value a6, 0x0FF00FF5
    assert_value a7, 0x0FF00FF5
    assert_value s0, 0x0FF00FF0
    clear_all
    # the same on minstret (IR is set) and on mcycle (CY is set)
    li   t0, 0x100
    csrw minstret, t0
    li   t0, 0x0F
    csrrs a1, minstret, t0
    csrr a2, minstret
    li   t0, 3
    csrrc a3, minstret, t0
    csrr a4, minstret
    csrrsi a5, minstret, 0x10
    csrr a6, minstret
    csrrci a7, minstret, 4
    csrr s0, minstret
    assert_value a1, 0x100
    assert_value a2, 0x10F
    assert_value a4, 0x10C
    assert_value a6, 0x11C
    assert_value s0, 0x118
    li   t0, 0x200
    csrw mcycle, t0
    li   t0, 0x0F
    csrrs a1, mcycle, t0
    csrr a2, mcycle
    li   t0, 3
    csrrc a3, mcycle, t0
    csrr a4, mcycle
    csrrsi a5, mcycle, 0x10
    csrr a6, mcycle
    csrrci a7, mcycle, 4
    csrr s0, mcycle
    assert_value a1, 0x200
    assert_value a2, 0x20F
    assert_value a4, 0x20C
    assert_value a6, 0x21C
    assert_value s0, 0x218

# ----------------------------------------------------------------------------------------------
# 8. csrrs/csrrc with rs1 = x0 do not write; a non-zero rs1 field holding 0 does; a write wins.
#    Counter 3 counts INSTRET; the difference counter - minstret does not change unless the counter loses a count.
# ----------------------------------------------------------------------------------------------
case8:
    li   t2, 8
    csrw mcountinhibit, s11
    selc 3, EV_INSTRET
    clear_all
    li   s4, 0
    open
    pad
    csrr a1, 0xB03
    csrr a2, minstret
    sub  s0, a1, a2               # difference 1
    csrrs a3, 0xB03, zero         # the pure-read forms of csrrs, csrrc, csrrsi, csrrci
    csrrc a3, 0xB03, zero
    csrrsi a3, 0xB03, 0
    csrrci a3, 0xB03, 0
    csrr a1, 0xB03
    csrr a2, minstret
    sub  s1, a1, a2               # difference 2
    csrrs zero, 0xB03, s4         # rs1 field non-zero, value 0: a write of the old value
    csrr a1, 0xB03
    csrr a2, minstret
    sub  s2, a1, a2               # difference 3
    li   a0, 0x1234
    csrw 0xB03, a0                # a write wins over the increment of the same cycle
    csrr a4, 0xB03                # ... and the next instruction reads the value that was written
    close
    assert_equal s0, s1           # reading did not write
    addi s2, s2, 1
    assert_equal s2, s1           # the write lost exactly the count of the writing instruction
    assert_equal a4, a0

# ----------------------------------------------------------------------------------------------
# 9. The inhibit bits: HPM3, CY, IR and the predictor's counter 10
# ----------------------------------------------------------------------------------------------
case9:
    li   t2, 9
    csrw mcountinhibit, s11
    selc 3, EV_CYCLE
    selc 4, EV_CYCLE
    clear_all
    csrw 0x32A, zero              # predictor off: not-taken branches are BP_NN
    csrw mcountinhibit, zero
    # HPM3 frozen: counter 3 stands still, counter 4 runs
    li   t0, 8
    csrw mcountinhibit, t0
    csrr a1, 0xB03
    csrr a2, 0xB04
    .rept 6
    nop
    .endr
    csrr a3, 0xB03
    csrr a4, 0xB04
    csrw mcountinhibit, zero
    sub  a4, a4, a2
    assert_equal a3, a1
    assert_nonzero a4
    # CY frozen: mcycle stands still, minstret runs
    li   t0, 1
    csrw mcountinhibit, t0
    csrr a1, mcycle
    csrr a2, minstret
    .rept 6
    nop
    .endr
    csrr a3, mcycle
    csrr a4, minstret
    csrw mcountinhibit, zero
    sub  a4, a4, a2
    assert_equal a3, a1
    assert_nonzero a4
    # IR frozen: minstret stands still, mcycle runs
    li   t0, 4
    csrw mcountinhibit, t0
    csrr a1, minstret
    csrr a2, mcycle
    .rept 6
    nop
    .endr
    csrr a3, minstret
    csrr a4, mcycle
    csrw mcountinhibit, zero
    sub  a4, a4, a2
    assert_equal a3, a1
    assert_nonzero a4
    # counter 10 (mhpmcounter10, BP_NN) counts three not-taken branches, and not when bit 10 is set
    csrr a1, 0xB0A
    bne  zero, zero, 1f
    bne  zero, zero, 1f
    bne  zero, zero, 1f
1:  csrr a2, 0xB0A
    li   t0, 0x400
    csrw mcountinhibit, t0
    csrr a3, 0xB0A
    bne  zero, zero, 2f
    bne  zero, zero, 2f
    bne  zero, zero, 2f
2:  csrr a4, 0xB0A
    csrw mcountinhibit, zero
    sub  a2, a2, a1
    sub  a4, a4, a3
    assert_value a2, 3
    assert_value a4, 0
    csrw mcountinhibit, s11

# ----------------------------------------------------------------------------------------------
# 10. Wrap-around of the 48 bits, and the carry between the two halves
# ----------------------------------------------------------------------------------------------
case10:
    li   t2, 10
    csrw mcountinhibit, s11
    selc 3, EV_CYCLE
    selc 4, EV_CYCLE
    clear_all
    li   t0, 0xFFFF
    csrw 0xB83, t0
    li   t0, -6
    csrw 0xB03, t0                # 2^48 - 6
    open
    .rept 30
    nop
    .endr
    close
    rdc  3, a1
    csrr a2, 0xB83
    rdc  4, a3                    # k cycles were counted
    addi a4, a3, -6
    assert_equal a1, a4           # (k - 6) mod 2^48
    assert_value a2, 0
    clear_all
    csrw 0xB83, zero
    li   t0, -6
    csrw 0xB03, t0                # 2^32 - 6
    open
    .rept 30
    nop
    .endr
    close
    rdc  3, a1
    csrr a2, 0xB83
    rdc  4, a3
    addi a4, a3, -6
    assert_equal a1, a4
    assert_value a2, 1            # the carry went into the high half

# ----------------------------------------------------------------------------------------------
# 11. The retirement classes, each with a different count
# ----------------------------------------------------------------------------------------------
case11:
    li   t2, 11
    csrw mcountinhibit, s11
    selc 3, EV_LOAD
    selc 4, EV_STORE
    selc 5, EV_BRANCH
    selc 6, EV_BRANCH_TAKEN
    selc 7, EV_JUMP
    selc 8, EV_MUL
    selc 9, EV_DIV
    clear_all
    csrw 0x32A, zero              # predictor off
    li   a6, 1000003
    li   a7, 7
    open
    pad
    .rept 3
    lw   a0, 0(t6)                # 3 loads
    .endr
    .rept 4
    sw   a0, 4(t6)                # 4 stores
    .endr
    li   s0, 6                    # a loop of 6 branches, 5 of them taken
1:  addi s0, s0, -1
    bnez s0, 1b
    .rept 4
    jal  zero, 3f                 # 4 jal and 3 jalr: 7 jumps
3:
    .endr
    .rept 3
    auipc a4, 0
    jalr zero, 8(a4)
    .endr
    mul    a0, a6, a7             # 3 mul, 2 mulh, 2 mulhsu, 1 mulhu: 8
    mul    a1, a6, a7
    mul    a2, a6, a7
    mulh   a0, a6, a7
    mulh   a1, a6, a7
    mulhsu a0, a6, a7
    mulhsu a1, a6, a7
    mulhu  a0, a6, a7
    div    a0, a6, a7             # 3 div, 2 divu, 2 rem, 2 remu: 9
    div    a1, a6, a7
    div    a2, a6, a7
    divu   a0, a6, a7
    divu   a1, a6, a7
    rem    a0, a6, a7
    rem    a1, a6, a7
    remu   a0, a6, a7
    remu   a1, a6, a7
    pad
    close
    chk  3, 3
    chk  4, 4
    chk  5, 6
    chk  6, 5
    chk  7, 7
    chk  8, 8
    chk  9, 9

case11b:
    li   t2, 12
    csrw mcountinhibit, s11
    selc 3, EV_CSR
    selc 4, EV_BITMANIP
    selc 5, EV_CRYPTO
    selc 6, EV_MRET
    selc 7, EV_FENCE_I
    selc 8, EV_REPLAY
    selc 9, EV_INSTRET
    clear_all
    li   a6, 0x00F0F0A5
    li   a7, 0x0123456
    csrw mstatus, zero            # an mret then leaves interrupts off
    csrr s0, minstret
    open
    pad
    .rept 4
    csrr a0, mscratch             # 4 csr
    .endr
    .rept 2
    la   t4, 3f
    csrw mepc, t4                 # + 2 csr
    mret                          # 2 mret
3:
    .endr
    .rept 5
    fence.i                       # 5 fence.i
    .endr
    sh1add a0, a6, a7             # 3 bitmanip
    andn   a1, a6, a7
    .insn r 0x33, 5, 7, a2, a6, a7     # czero.eqz
    pack   a0, a6, a7             # 4 crypto
    brev8  a1, a6
    xperm4 a2, a6, a7
    sha256sum0 a3, a6
    pad
    close
    csrr s1, minstret
    sub  s1, s1, s0
    chk  3, 7                     # 6 in the body and the closing csrw
    chk  4, 3
    chk  5, 4
    chk  6, 2
    chk  7, 5
    chk  8, 0                     # nothing is replayed without an interrupt
    csrr t4, 0xB09
    assert_equal t4, s1           # INSTRET against minstret again, with CSR instructions and traps around
    csrw mstatus, zero            # the second mret left MIE set

# ----------------------------------------------------------------------------------------------
# 12. Load-use hazards, and the CSR-use hazard (the value comes from Writeback)
# ----------------------------------------------------------------------------------------------
case12:
    li   t2, 13
    csrw mcountinhibit, s11
    selc 3, EV_HAZARD_LOAD
    selc 4, EV_HAZARD
    clear_all
    open
    pad
    .rept 8
    lw   a0, 0(t6)
    add  a1, a0, a0
    .endr
    pad
    close
    rdc  3, a1
    rdc  4, a2
    assert_value_g a1, 8          # one per pair
    sltu a3, a2, a1
    assert_equal_g a3, zero       # HAZARD includes HAZARD_LOAD
    csrw mcountinhibit, s11
    clear_all
    open
    pad
    .rept 8
    csrr a0, mscratch
    add  a1, a0, a0
    .endr
    pad
    close
    rdc  3, a1
    rdc  4, a2
    assert_value_g a1, 0          # a CSR-use hazard is not a load-use hazard
    assert_value_g a2, 16         # two cycles per pair

# ----------------------------------------------------------------------------------------------
# 13. M-unit stalls: 1 per mul, 33 per divide, none for a divide by zero
# ----------------------------------------------------------------------------------------------
case13:
    li   t2, 14
    csrw mcountinhibit, s11
    selc 3, EV_MSTALL_MUL
    selc 4, EV_MSTALL_DIV
    selc 5, EV_MSTALL_ANY
    selc 6, EV_MUL
    selc 7, EV_DIV
    clear_all
    li   a6, 1000003
    li   a7, 7
    li   s4, 0
    open
    pad
    .rept 5
    mul  a0, a6, a7               # 5 mul
    .endr
    .rept 4
    div  a1, a6, a7               # 4 divides
    .endr
    .rept 3
    div  a2, a6, s4               # 3 divides by zero: no stall
    .endr
    pad
    close
    chk_g 3, 5
    chk_g 4, 132
    chk_g 5, 137
    chk  6, 5
    chk  7, 7

# ----------------------------------------------------------------------------------------------
# 14. Waits for the data bus: the stall register of the test device answers after 3 wait cycles
#     (each access is separated from the one before it by a nop, so that the device reloads its wait)
# ----------------------------------------------------------------------------------------------
case14:
    li   t2, 15
    csrw mcountinhibit, s11
    selc 3, EV_MEMWAIT_LOAD
    selc 4, EV_MEMWAIT_STORE
    selc 5, EV_MEMWAIT_IO
    selc 6, EV_MEMWAIT_ANY
    selc 7, EV_IO_ACCESS
    selc 8, EV_LOAD
    selc 9, EV_STORE
    clear_all
    open
    pad
    .rept 5
    lw   a0, 12(t3)
    nop
    sw   a0, 12(t3)
    nop
    .endr
    pad
    close
    chk_g 3, 15
    chk_g 4, 15
    chk_g 5, 30
    chk_g 6, 30
    chk  7, 10
    chk  8, 5
    chk  9, 5

case14b:
    li   t2, 16
    csrw mcountinhibit, s11
    selc 3, EV_MEMWAIT_LOAD
    clear_all
    open
    pad
    lw   a0, 12(t3)               # two loads in a row: the second one finds the device ready
    lw   a1, 12(t3)
    pad
    close
    chk_g 3, 3
    # an access to a register that answers at once is already counted for the next instruction
    csrw mcountinhibit, s11
    selc 3, EV_IO_ACCESS
    clear_all
    open
    pad
    csrr a1, 0xB03
    lw   a0, 8(t3)
    csrr a2, 0xB03
    close
    sub  a2, a2, a1
    assert_value a2, 1

# ----------------------------------------------------------------------------------------------
# 15. Redirects and the predictor's events (mode 0: never taken; mode 1: always taken)
# ----------------------------------------------------------------------------------------------
case15:
    li   t2, 17
    csrw mcountinhibit, s11
    selc 3, EV_REDIRECT_BRANCH
    selc 4, EV_BR_MISPREDICT
    selc 5, EV_BP_NN
    selc 6, EV_BP_NT
    selc 7, EV_BRANCH
    selc 8, EV_BP_TN
    selc 9, EV_BP_TT
    clear_all
    csrw 0x32A, zero
    open
    pad
    .rept 7
    beq  zero, zero, 4f           # 7 taken forward branches, all mispredicted
    li   a1, 0xbad
4:
    .endr
    .rept 3
    bne  zero, zero, 5f           # 3 not-taken branches
5:
    .endr
    pad
    close
    chk  3, 7
    chk  4, 7
    chk  5, 3
    chk  6, 7
    chk  7, 10
    chk  8, 0
    chk  9, 0
    csrr a1, 0xB0A                # the predictor's counters 10..13 say the same
    csrr a2, 0xB0B
    csrr a3, 0xB0C
    csrr a4, 0xB0D
    assert_value a1, 3
    assert_value a2, 7
    assert_value a3, 0
    assert_value a4, 0
    # mode 1
    li   t0, 1
    csrw 0x32A, t0
    csrw mcountinhibit, s11
    clear_all
    open
    pad
    .rept 7
    beq  zero, zero, 6f
    li   a1, 0xbad
6:
    .endr
    .rept 3
    bne  zero, zero, 7f
7:
    .endr
    pad
    close
    csrw 0x32A, zero
    chk  3, 3                     # only the 3 branches predicted taken but not taken redirect
    chk  4, 3
    chk  5, 0
    chk  6, 0
    chk  7, 10
    chk  8, 3
    chk  9, 7

case15b:
    li   t2, 18
    csrw mcountinhibit, s11
    selc 3, EV_REDIRECT_JUMP
    selc 4, EV_FETCH_DISCARD
    selc 5, EV_JUMP
    selc 6, EV_REDIRECT_ANY
    clear_all
    open
    pad
    .rept 6
    jal  zero, 8f                 # 6 jal with no stalls
    nop
8:
    .endr
    pad
    close
    chk_g 3, 6
    chk_g 4, 6
    chk  5, 6
    chk_g 6, 6

# ----------------------------------------------------------------------------------------------
# 16. Fetch: one word per cycle without stalls; the partition of the cycles
# ----------------------------------------------------------------------------------------------
case16:
    li   t2, 19
    csrw mcountinhibit, s11
    selc 3, EV_FETCH_DELIVER
    selc 4, EV_INSTRET
    selc 5, EV_FETCH_WAIT
    clear_all
    open
    .rept 40
    nop
    .endr
    close
    rdc  3, a1
    rdc  4, a2
    rdc  5, a3
    assert_equal_g a1, a2         # one word delivered per instruction counted
    assert_value a2, 41
    assert_value_g a3, 0          # the plain memory answers in the cycle of the request
    # the six classes add up to the cycles, over a window that holds every kind of stall
    csrw mcountinhibit, s11
    selc 3, EV_FETCH_WAIT
    selc 4, EV_FRONT_OK
    selc 5, EV_HAZARD
    selc 6, EV_MSTALL_ANY
    selc 7, EV_MEMWAIT_ANY
    selc 8, EV_REDIRECT_ANY
    selc 9, EV_CYCLE
    clear_all
    li   a6, 1000003
    li   a7, 7
    open
    pad
    lw   a0, 0(t6)
    add  a1, a0, a0               # a load-use hazard
    mul  a2, a6, a7
    div  a3, a6, a7               # M-unit stalls
    lw   a0, 12(t3)               # a wait for the data bus
    nop
    beq  zero, zero, 9f           # a redirect
    li   a1, 0xbad
9:  jal  zero, 9f
    nop
9:  fence.i
    nop
    pad
    close
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
    assert_equal t4, a7           # exactly one class for every cycle

# ----------------------------------------------------------------------------------------------
# 17. Exceptions: 5 ecall and 3 illegal instructions, each returning with mret
# ----------------------------------------------------------------------------------------------
case17:
    li   t2, 20
    csrw mcountinhibit, s11
    selc 3, EV_EXCEPTION
    selc 4, EV_EXC_ECALL
    selc 5, EV_EXC_OTHER
    selc 6, EV_MRET
    selc 7, EV_REDIRECT_WB
    selc 8, EV_INTERRUPT
    selc 9, EV_REPLAY
    clear_all
    li   s10, 0
    li   s6, 0
    li   s7, 0x804                # the causes that the handler accepts: 2 and 11
    open
    pad
    .rept 5
    ecall
    .endr
    .rept 3
    .word 0x00000000
    .endr
    pad
    close
    chk  3, 8
    chk  4, 5
    chk  5, 3
    chk  6, 8                     # the handler's mret
    chk  7, 16                    # a jump into the handler and one out of it, for each
    chk  8, 0
    chk  9, 0
    assert_value s10, 8
    assert_value s6, 0

# ----------------------------------------------------------------------------------------------
# 18. Interrupts: 4 from the test device, 4 from the timer
# ----------------------------------------------------------------------------------------------
case18:
    li   t2, 21
    csrw mcountinhibit, s11
    selc 3, EV_INTERRUPT
    selc 4, EV_INT_TIMER
    selc 5, EV_INT_EXT
    selc 6, EV_MRET
    selc 7, EV_EXCEPTION
    clear_all
    li   s8, 0
    li   a4, 0                    # interrupts expected so far
    open
    csrsi mstatus, 8
    li   a5, 4
irq_ext:
    li   t0, 12
    sw   t0, 4(t3)                # the test device raises its interrupt 12 cycles from now
    addi a4, a4, 1
1:  blt  s8, a4, 1b
    addi a5, a5, -1
    bnez a5, irq_ext
    li   a5, 4
irq_timer:
    li   t0, MTIME
    lw   t4, 0(t0)
    addi t4, t4, 40
    li   t0, MTIMECMP
    sw   t4, 0(t0)
    li   t0, MTIMECMPH
    sw   zero, 0(t0)              # mtimecmp = mtime + 40
    addi a4, a4, 1
2:  blt  s8, a4, 2b
    addi a5, a5, -1
    bnez a5, irq_timer
    csrci mstatus, 8
    pad
    close
    chk  3, 8
    chk  4, 4
    chk  5, 4
    chk  6, 8
    chk  7, 0

# ----------------------------------------------------------------------------------------------
# 19. The fetch port of the plain memory never waits; every counter stays below its width
# ----------------------------------------------------------------------------------------------
case19:
    li   t2, 22
    csrw mcountinhibit, s11
    selc 3, EV_FETCH_WAIT
    clear_all
    open
    pad
    .rept 20
    nop
    .endr
    close
    rdc  3, a1
    assert_value_g a1, 0
    csrw mcountinhibit, zero      # leave everything running, as at reset

finish:
    csrw mcountinhibit, zero
    select_none
    halt
    fail

# ----------------------------------------------------------------------------------------------
# The trap handler
#   exception: counted in s10, the cause (mcause) against the accepted mask in s7 (wrong ones in s6),
#              the instruction skipped
#   interrupt: counted in s8, the source cleared, a few nops so that the cleared line has dropped
# ----------------------------------------------------------------------------------------------
.balign 16
trap_handler:
    csrr gp, mcause
    mv   s9, gp
    bltz gp, 3f
    li   tp, 1
    sll  tp, tp, gp
    and  tp, tp, s7
    bnez tp, 1f
    addi s6, s6, 1
1:  addi s10, s10, 1
    csrr gp, mepc
    addi gp, gp, 4
    csrw mepc, gp
    mret
3:  addi s8, s8, 1
    li   tp, 0x8000000B
    bne  gp, tp, 4f
    sw   zero, 4(t3)              # external: clear the test device
    j    5f
4:  li   gp, MTIMECMPH
    li   tp, -1
    sw   tp, 0(gp)                # timer: disarm
5:  .rept 6
    nop
    .endr
    mret

.balign 64
buf:
    .word 0x11111111, 0x22222222, 0x33333333, 0x44444444
    .word 0, 0, 0, 0
