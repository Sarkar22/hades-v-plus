# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: bpirq3.s
#
# ------------------------------------------------------------------------------------------------
# |                                                                                              |
# | INTERRUPT RETURN ADDRESS AFTER A CORRECTLY PREDICTED TAKEN BRANCH: the Writeback paths that |
# | take mepc from the INTERRUPTED instruction's next PC (companion of bpirq.s / bpirq2.s).     |
# |                                                                                              |
# | A sequential interrupt decided while instruction I is in Writeback is taken one cycle      |
# | later, after the next slot J. If J is VALID it retires and mepc = J.next_PC (bpirq.s,       |
# | bpirq2.s exercise J = the branch itself). If J is a BUBBLE or carries an exception status   |
# | it does not retire and mepc = I.next_PC. With the branch predictor on (MHPMEVENT10 = 1..3)  |
# | a correctly predicted taken branch used to carry next_PC = PC+4, so mepc pointed at the     |
# | not-taken path. Shapes, an 8- (D) or 4-iteration (E, F) loop, over modes 0..3 x IRQ delays 1..40: |
# |   D: backward taken branch; its target reads a CSR result two slots earlier, so Decode      |
# |      stalls and a BUBBLE follows the branch into Writeback.  Bug: loop exits early.         |
# |   E: backward taken branch whose target is an ECALL (J = the ECALL, exception status).      |
# |      Bug: the ECALL is skipped and the loop exits early.                                     |
# |   F: forward taken branch over a poison instruction onto an ECALL.                          |
# |      Bug: the poison instruction executes and the ECALL is skipped.                         |
# | The ECALL handler counts ECALLs and returns to mepc+4; the IRQ handler disarms and returns.|
# | Every loop must run its full iteration count, one ECALL per iteration (E, F), no poison (F).|
# | Prints 'D<n> E<n> F<n> I<irqs> C<ecalls>' (hex); fails via the test register on any n > 0. |
# | The golden CPU ignores MHPMEVENT10 (reads 0, no trap), so it is a valid twin.               |
# |                                                                                              |
# | Register allocation:                                                                         |
# |     s0 = mode  s1 = IRQ delay  s5/s8/s9 = D/E/F mismatches  s6 = #IRQs  s10 = #ECALLs      |
# |     t3 = test peripheral  tp, gp = handler scratch                                          |
# |                                                                                              |
# ------------------------------------------------------------------------------------------------
.equ TEST,  0x480000
.equ UART,  0x210000
.equ NITD,  8                     # shape D iterations
.equ NITE,  4                     # shape E/F iterations (each one traps)
.equ NDLY,  40

.option norelax
.section .text.__reset
.global __reset
__reset:
    li   t3, TEST
    li   t1, 1
    sw   t1, 0(t3)                # initial test: deliberate fail (proves the fail path works)
    la   t0, handler
    csrw mtvec, t0
    li   t0, 0x800
    csrw mie, t0                  # MEIE (wishbone_test interrupt)
    li   t0, 7
    csrw mscratch, t0
    li   s0, 0
    li   s5, 0
    li   s8, 0
    li   s9, 0
    li   s6, 0
    li   s10, 0
m_loop:
    csrw 0x32A, s0                # MHPMEVENT10: branch predictor algorithm
    li   s1, 1
d_loop:
    # ---- shape D: bubble behind a backward taken branch ----
    li   s2, 0
    li   a0, NITD
    sw   s1, 4(t3)                # arm: IRQ pending s1 cycles from now
    csrsi mstatus, 8
    j    2f
1:  add  s2, s2, a1               # branch target: needs the csrr result -> Decode stall
    addi a0, a0, -1
    beqz a0, 3f
2:  csrr a1, mscratch             # a1 = 7 (CSR data only available from Writeback)
    bnez a0, 1b                   # backward, always taken here
3:  csrci mstatus, 8
    sw   zero, 4(t3)              # disarm (in case it did not fire)
    li   t0, 7*NITD
    beq  s2, t0, 4f
    addi s5, s5, 1
4:
    # ---- shape E: backward taken branch onto an ECALL ----
    li   a0, NITE
    mv   s4, s10
    sw   s1, 4(t3)
    csrsi mstatus, 8
    j    6f
5:  ecall                         # must execute exactly once per iteration
    addi a0, a0, -1
    beqz a0, 7f
6:  nop
    bnez a0, 5b                   # backward, always taken here
7:  csrci mstatus, 8
    sw   zero, 4(t3)
    sub  s4, s10, s4
    li   t0, NITE
    beq  s4, t0, 8f
    addi s8, s8, 1
8:
    # ---- shape F: forward taken branch over a poison instruction onto an ECALL ----
    li   s3, 0
    li   a0, NITE
    mv   s4, s10
    sw   s1, 4(t3)
    csrsi mstatus, 8
9:  beq  zero, zero, 10f          # forward, always taken
    addi s3, s3, 1                # poison: must never execute
10: ecall
    addi a0, a0, -1
    bnez a0, 9b
    csrci mstatus, 8
    sw   zero, 4(t3)
    sub  s4, s10, s4
    li   t0, NITE
    bnez s3, 11f
    beq  s4, t0, 12f
11: addi s9, s9, 1
12:
    addi s1, s1, 1
    li   t0, NDLY+1
    blt  s1, t0, d_loop
    addi s0, s0, 1
    li   t0, 4
    blt  s0, t0, m_loop

    csrwi 0x32A, 0
    li   s7, UART
    li   a0, 'D'
    call pch
    mv   a0, s5
    call phex
    li   a0, 'E'
    call pch
    mv   a0, s8
    call phex
    li   a0, 'F'
    call pch
    mv   a0, s9
    call phex
    li   a0, 'I'
    call pch
    mv   a0, s6
    call phex
    li   a0, 'C'
    call pch
    mv   a0, s10
    call phex
    li   a0, 10
    call pch
    or   t0, s5, s8
    or   t0, t0, s9
    bnez t0, 13f
    sw   zero, 0(t3)              # pass
    j    14f
13: sw   t1, 0(t3)                # fail
14: li   t0, 2
    sw   t0, 0(t3)                # end of simulation
15: j    15b

pch:                              # a0 = char (clobbers t6)
    lbu  t6, 3(s7)
    andi t6, t6, 4
    beqz t6, pch
    sb   a0, 0(s7)
    ret
phex:                             # a0 = value, 8 hex digits + space (clobbers t2, t4, t5, t6)
    mv   t2, ra
    mv   t4, a0
    li   t5, 8
16: srli a0, t4, 28
    slli t4, t4, 4
    addi a0, a0, 48
    li   t6, 58
    blt  a0, t6, 17f
    addi a0, a0, 39
17: call pch
    addi t5, t5, -1
    bnez t5, 16b
    li   a0, 32
    call pch
    mv   ra, t2
    ret

.balign 256
handler:
    csrr tp, mcause
    bltz tp, h_irq
    li   gp, 11
    bne  tp, gp, h_bad            # only ECALL is expected
    addi s10, s10, 1
    csrr tp, mepc
    addi tp, tp, 4
    csrw mepc, tp
    mret
h_irq:
    sw   zero, 4(t3)              # drop the IRQ line
    addi s6, s6, 1
    mret
h_bad:
    li   tp, 1
    sw   tp, 0(t3)
    li   tp, 2
    sw   tp, 0(t3)
18: j    18b
