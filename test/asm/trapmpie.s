# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: trapmpie.s
#
# ------------------------------------------------------------------------------------------------
# |                                                                                              |
# | MPIE ON TRAP ENTRY (regression for writeback fix B).                                         |
# |                                                                                              |
# | Privileged spec (mstatus): "When a trap is taken from privilege mode y into privilege mode  |
# | x, xPIE is set to the value of xIE; xIE is set to 0". MRET then sets MIE = MPIE, MPIE = 1.  |
# | So a trap taken while MIE=0 must leave MPIE=0 and the handler's MRET must come back with    |
# | MIE=0 -- regardless of the MPIE value before the trap. The frozen golden model does exactly |
# | this. The bug left MPIE unchanged when MIE=0, so e.g. a FreeRTOS yield (ECALL) issued       |
# | inside a critical section resumed the task with interrupts ENABLED.                          |
# |                                                                                              |
# | Each case: set mstatus, trap (ECALL or illegal), the handler records mstatus in s8, MRET,   |
# | then read mstatus into s9. Checked: (s8 & 0x88) and (s9 & 0x88).                            |
# |                                                                                              |
# |   before (MPIE,MIE)   in handler (MPIE,MIE)   after MRET (MPIE,MIE)                          |
# |       1,0                  0,0                     1,0          <- the buggy case            |
# |       0,0                  0,0                     1,0                                       |
# |       0,1                  1,0                     1,1                                       |
# |       1,1                  1,0                     1,1                                       |
# |                                                                                              |
# | Register allocation:                                                                         |
# |     x5  (t0):   reserved for macro use                                                       |
# |     x6  (t1):   constant 1                                                                   |
# |     x28 (t3):   test peripheral address                                                      |
# |     s8 / s9:    mstatus in handler / after MRET                                              |
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

# trap_case <mstatus before>, <trap: 0 = ecall, 1 = illegal>, <expected in handler>, <expected after>
.macro trap_case before:req, kind:req, inh:req, after:req
    li   s8, -1
    li   a0, \before
    csrw mstatus, a0
    .if \kind == 0
    ecall
    .else
    .word 0x00000000
    .endif
    csrr s9, mstatus
    andi s8, s8, 0x88
    andi s9, s9, 0x88
    assert_value s8, \inh
    assert_value s9, \after
.endm

.section .text.__reset
.globl __reset
__reset:
    lui  t3, 0x120
    slli t3, t3, 2        # test peripheral 0x480000
    addi t1, zero, 1
    fail                  # initial test: deliberate fail (proves the fail path works)
    la   t4, handler
    csrw mtvec, t4
    csrw mie, zero        # no interrupts in this test

    trap_case 0x80, 0, 0x00, 0x80    # ECALL,   MPIE=1 MIE=0  (the bug: handler saw 0x80, returned with MIE=1)
    trap_case 0x80, 1, 0x00, 0x80    # illegal, MPIE=1 MIE=0
    trap_case 0x00, 0, 0x00, 0x80    # ECALL,   MPIE=0 MIE=0
    trap_case 0x08, 0, 0x80, 0x88    # ECALL,   MPIE=0 MIE=1
    trap_case 0x88, 1, 0x80, 0x88    # illegal, MPIE=1 MIE=1

    halt
    fail

.align 4
handler:
    csrr s8, mstatus
    csrr t5, mepc
    addi t5, t5, 4
    csrw mepc, t5
    mret
