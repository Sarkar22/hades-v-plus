# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: irqlat.s
#
# ------------------------------------------------------------------------------------------------
# |                                                                                               |
# | INTERRUPTS DURING STRAIGHT-LINE CODE, with latencies derived by hand: the validation cases    |
# | of the testbench option +irq_latency (sim/top.sv).                                            |
# |                                                                                               |
# | The program arms the test device's interrupt six times, with the delays N = 20 .. 25, and     |
# | after each store runs 48 nops and a short wait loop. The handler disarms the device, counts   |
# | the interrupt, checks that it is the machine external interrupt and that mepc lies in the     |
# | nops or the wait loop. Its reports are the same at every latency and with or without a        |
# | cache (no check measures time); the latencies are not checked by the program but by           |
# | matrix.py (leg irq-latency-validation), against the figures derived below.                    |
# |                                                                                               |
# | WHAT +irq_latency MEASURES (sim/top.sv, 4.14): the cycles from the first cycle p in which     |
# | the interrupt is pending and enabled in Writeback to the first fetch answer (ack) after the   |
# | interrupt's jump cycle j.                                                                     |
# |                                                                                               |
# | THE DERIVATION, from rtl/writeback_stage.sv and rtl/fetch_stage.sv, for a memory in which     |
# | every instruction fetch takes F = L + 1 cycles (L wait cycles: the standard build has L = 0,  |
# | the uncached configurations MEM_LAT=L have L; sim/slow_memory.sv: a transfer of latency L     |
# | takes L + 1 cycles, a new one starts in the cycle after an answer and in the first cycle of   |
# | a changed address), in straight-line code:                                                    |
# |   1. Fetch is answered every F cycles, so Writeback holds a valid instruction once in F       |
# |      cycles and a bubble in the F - 1 cycles between.                                         |
# |   2. The interrupt is taken from a valid (not bubble) instruction in Writeback: with d the    |
# |      number of cycles from p to the next cycle with a valid instruction there (0 <= d <= L),  |
# |      is_interrupt (and is_interrupt_seq: no CSR or mret enabling it) holds in the cycle       |
# |      p + d, and int_jump_reg is set at the edge ending it.                                    |
# |   3. In the next cycle, j = p + d + 1, int_jump_fire = int_jump_reg (nothing in Memory        |
# |      waits for its bus: nops) and Writeback sends JUMP to Fetch; pc becomes the handler's     |
# |      address at the edge ending j. An answer in cycle j itself belongs to the old address     |
# |      (it is not counted).                                                                     |
# |   4. From cycle j + 1 Fetch presents the handler's address: a changed address starts a new    |
# |      transfer at once, answered L cycles later: the first ack after the jump cycle is in      |
# |      cycle j + 1 + L.                                                                         |
# |   Hence latency = (j + 1 + L) - p = L + 2 + d, with d in 0 .. L.                              |
# |                                                                                               |
# | d depends on where p falls between two valid instructions in Writeback. p = c + 1 + N, with   |
# | c the cycle in which the arming store is answered (the device loads N at the edge ending c,   |
# | counts N .. 0 down in the next cycles and raises the line when its counter is 0:              |
# | lib/wishbone/wishbone_test.sv). The code after the store is the same in every round, so       |
# | c is followed by the same stream of valid instructions; the next round's N is one more, so    |
# | p moves one cycle later against that stream and d one lower (modulo F). Six rounds with       |
# | consecutive N therefore see each value of d equally often when F divides 6, that is, F = 1,   |
# | 2, 3 and 6 (L = 0, 1, 2, 5), and then, whatever d is in the first round:                      |
# |                                                                                               |
# |     standard build (L = 0, F = 1):  d = 0 six times; latency 2 in every round                 |
# |         IRQLAT interrupts=6 max=2 mean=2.00                                                   |
# |     MEM_LAT=1 (F = 2):  d = 0 and 1 three times each; latencies 3 and 4                       |
# |         IRQLAT interrupts=6 max=4 mean=3.50                                                   |
# |     MEM_LAT=2 (F = 3):  d = 0, 1 and 2 twice each; latencies 4, 5 and 6                       |
# |         IRQLAT interrupts=6 max=6 mean=5.00                                                   |
# |     MEM_LAT=5 (F = 6):  d = 0 .. 5 once each; latencies 7 to 12                               |
# |         IRQLAT interrupts=6 max=12 mean=9.50                                                  |
# |                                                                                               |
# | (The checks need the interrupt to land in the nops: N = 20 .. 25 puts p within the first      |
# | few of the 48 nops at F = 2, 3 and 6 and in the first half of them at F = 1.)                 |
# |                                                                                               |
# | Register allocation:                                                                          |
# |     x5  (t0):   reserved for macro use                                                        |
# |     x6  (t1):   1 (the value a failed check writes)                                           |
# |     x7  (t2):   test case number                                                              |
# |     x28 (t3):   test peripheral address                                                       |
# |     s2:   N (interrupt delay)    s3: last N + 1       s7: interrupts taken                    |
# |     s8:   interrupts armed       s9: handler errors   s10: first nop                          |
# |     s4, s5, s6: handler scratch  a4: wait-loop counter       t4: scratch                      |
# |                                                                                               |
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

# Interrupt delays N = NFIRST .. NFIRST + ROUNDS - 1; the nops of each round
.equ NFIRST, 20
.equ ROUNDS, 6
.equ NOPS, 48
# The bytes from the first nop to the end of the wait loop (3 instructions)
.equ ROUND_BYTES, 4*NOPS + 12

# ------------------------------------------------------------------------------------------------
# |                                          Test entry!                                          |
# ------------------------------------------------------------------------------------------------
.global __reset
__reset:

test_init:
    addi t1, zero, 1
    addi t2, zero, 0
    lui  t3, %hi(0x120000<<2)
    addi t3, t3, %lo(0x120000<<2)
    li32 t4, unexpected_trap
    csrw mtvec, t4

# Deliberate first failure: proves the assert macro and the test peripheral work.
test_fail:
    addi t2, zero, 1
    assert_value zero, 1

test_enable:
    li32 t4, irq_handler
    csrw mtvec, t4
    slli t4, t1, 11
    csrs mie, t4                   # external interrupt
    slli t4, t1, 3
    csrs mstatus, t4               # MIE
    li32 s10, nops
    addi t2, zero, 2
    addi s2, zero, NFIRST
    addi s3, zero, NFIRST + ROUNDS
    addi s7, zero, 0
    addi s8, zero, 0
    addi s9, zero, 0

# One round: arm the interrupt N cycles ahead and run straight-line code.
round:
    li32 a4, 1000
    addi s8, s8, 1
    sw   s2, 4(t3)                 # arm: the interrupt comes N cycles after this store
nops:
    .rept NOPS
    nop
    .endr
2:
    bgeu s7, s8, 3f                # the handler has run
    addi a4, a4, -1
    bne  a4, zero, 2b              # (bounded: a lost interrupt fails the count check)
3:
    addi s2, s2, 1
    bne  s2, s3, round

# ------------------------------------------------------------------------------------------------
# |                                          Test done!                                           |
# ------------------------------------------------------------------------------------------------
test_check:
    addi t2, zero, 3
    assert_equal s7, s8
    assert_value s7, ROUNDS
    assert_value s9, 0

test_finish:
    csrwi mie, 0
    addi t2, zero, 9
    halt
    fail
4:
    beq  zero, zero, 4b

# External interrupt: disarm the test device, count, and check that the trap is the external
# interrupt and that mepc lies in the nops or the wait loop.
irq_handler:
    sw   zero, 4(t3)
    addi s7, s7, 1
    csrr s5, mcause
    li32 s6, 0x8000000B            # machine external interrupt
    bne  s5, s6, 5f
    csrr s4, mepc
    sub  s4, s4, s10               # byte offset from the first nop
    sltiu s5, s4, ROUND_BYTES + 1
    beq  s5, zero, 5f
    andi s5, s4, 3
    bne  s5, zero, 5f
    jal  zero, 6f
5:
    addi s9, s9, 1
6:
    mret

unexpected_trap:
    fail
    halt
7:
    beq  zero, zero, 7b
