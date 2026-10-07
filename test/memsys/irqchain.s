# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: irqchain.s
#
# ------------------------------------------------------------------------------------------------
# |                                                                                              |
# | AN INTERRUPT AT EVERY POSITION OF A CHAIN, for the memory-system checks                      |
# | (test/memsys/programs.py).                                                                   |
# |                                                                                              |
# | With wait states, Fetch often waits for an instruction when an interrupt arrives. Every      |
# | instruction must still retire exactly once: the interrupted one neither twice nor never.     |
# | The program arms the test device's interrupt N cycles ahead and runs three nops and a chain  |
# | of 16 RV32I instructions, each of which changes a0 (every step is a bijection of a0 that     |
# | does not leave it unchanged, so a doubled or a skipped instruction changes the final a0),    |
# | for every N from 1 to NMAX. NMAX = 200 is enough for the interrupt to land before every      |
# | chain instruction and in the wait loop behind the chain with 0 to 8 wait states per access,  |
# | fixed or random (see the recorded positions below).                                          |
# |                                                                                              |
# | The handler checks that the trap is the external interrupt and that it is precise: mepc      |
# | lies in the nops, the chain or its wait loop, and a0 holds the value after exactly the chain |
# | instructions before mepc (chain_values); any other case is counted in s9. Each iteration     |
# | then checks the final a0, and each sweep the number of interrupts and s9. The whole sweep    |
# | runs with the branch predictor off (mode 0) and in mode 3; the golden CPU ignores the mode.  |
# |                                                                                              |
# | The handler also records where the interrupts landed, as a mask of positions (bits 0-2: a    |
# | nop, bit 3 + k: before chain instruction k, bits 19-21: the wait loop), in the buffer: word  |
# | 0 for mode 0, word 1 for mode 3. The positions depend on the memory's timing, so the         |
# | program does not check them. The reports are the same at every latency.                      |
# |                                                                                              |
# | Register allocation:                                                                         |
# |     x5  (t0):   reserved for macro use                                                       |
# |     x6  (t1):   1 (the value a failed check writes)                                          |
# |     x7  (t2):   test case number                                                             |
# |     x28 (t3):   test peripheral address                                                      |
# |     x8  (s0):   buffer address (0x46000: unused RAM above the program)                       |
# |     s1:   branch-predictor mode           s2: N (interrupt delay)    s3: NMAX + 1            |
# |     s4, s5, s6: handler scratch           s7: interrupts taken       s8: interrupts armed    |
# |     s9: handler errors                    s10: pad (the first nop)   s11: chain_values       |
# |     a0: chain value                       a1, a2: chain operands     a3: position mask       |
# |     a4: wait-loop counter                 t4: scratch                                        |
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

# Interrupt delays 1..NMAX (cycles of the test device)
.equ NMAX, 200

# Chain operands, and the final a0 (chain_values below has the value before every step)
.equ CHAIN_A0, 0x13579BDF
.equ CHAIN_A1, 0x2468ACE1
.equ CHAIN_A2, 0x0F1E2D3C
.equ CHAIN_FINAL, 0x11922496

# Positions of the handler's check: 3 nops, 16 chain instructions and 3 of the wait loop
.equ POSITIONS, 22

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
    lui  s0, %hi(0x46000)
    addi s0, s0, %lo(0x46000)
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
    li32 s10, pad
    li32 s11, chain_values
    addi s1, zero, 0               # branch-predictor mode 0, then 3

# -----------------------------------------------
# Case 2 (mode 0) and case 3 (mode 3): for N = 1..NMAX arm the interrupt N cycles ahead, run
# the chain, wait for the interrupt and check a0; then check the number of interrupts and
# the handler's checks.
test_sweep:
    sltu t2, zero, s1
    addi t2, t2, 2                 # 2 for mode 0, 3 for mode 3
    csrw 0x32A, s1                 # MHPMEVENT10: branch-predictor mode
    addi s2, zero, 1
    li32 s3, NMAX+1
    addi s7, zero, 0
    addi s8, zero, 0
    addi s9, zero, 0
    addi a3, zero, 0
1:
    li32 a0, CHAIN_A0
    li32 a1, CHAIN_A1
    li32 a2, CHAIN_A2
    li32 a4, 1000
    addi s8, s8, 1
    sw   s2, 4(t3)                 # arm: the interrupt comes N cycles after this store
pad:
    nop                            # (the pipeline's depth: lets the interrupt also land
    nop                            # before the chain's first instructions)
    nop
chain:
    addi a0, a0, 0x2b5
    xor  a0, a0, a1
    sub  a0, a1, a0
    xori a0, a0, 0x5a5
    add  a0, a0, a2
    addi a0, a0, -0x77
    xor  a0, a2, a0
    sub  a0, a0, a1
    xori a0, a0, 0x3c
    add  a0, a1, a0
    addi a0, a0, 0x7ff
    xor  a0, a0, a2
    sub  a0, a2, a0
    xori a0, a0, -1
    add  a0, a0, a1
    addi a0, a0, 1
2:
    bgeu s7, s8, 3f                # the handler has run
    addi a4, a4, -1
    bne  a4, zero, 2b              # (bounded: a lost interrupt fails the count check)
3:
    assert_value a0, CHAIN_FINAL
    addi s2, s2, 1
    bne  s2, s3, 1b
    assert_equal s7, s8
    assert_value s7, NMAX
    assert_value s9, 0
    sltu t4, zero, s1
    slli t4, t4, 2
    add  t4, t4, s0
    sw   a3, 0(t4)                 # the position mask: word 0 (mode 0) or word 1 (mode 3)
    addi s1, s1, 3
    addi t4, zero, 6
    bne  s1, t4, test_sweep

# ------------------------------------------------------------------------------------------------
# |                                          Test done!                                          |
# ------------------------------------------------------------------------------------------------
test_finish:
    csrwi 0x32A, 0
    slli t4, t1, 3
    csrc mstatus, t4
    addi t2, zero, 9
    halt
    fail
4:
    beq  zero, zero, 4b

# External interrupt: disarm the test device, count, and check that the trap is the external
# interrupt, that mepc lies in the chain, the nops before it or its wait loop, and that a0
# holds the value after exactly the chain instructions before mepc.
irq_handler:
    sw   zero, 4(t3)
    addi s7, s7, 1
    csrr s5, mcause
    bge  s5, zero, 5f              # an exception
    csrr s4, mepc
    sub  s4, s4, s10               # byte offset from the first nop before the chain
    sltiu s5, s4, 4*POSITIONS
    beq  s5, zero, 5f
    andi s5, s4, 3
    bne  s5, zero, 5f
    srli s6, s4, 2
    sll  s6, t1, s6
    or   a3, a3, s6                # position mask
    add  s5, s4, s11
    lw   s5, 0(s5)
    beq  s5, a0, 6f
5:
    addi s9, s9, 1
6:
    mret

unexpected_trap:
    fail
    halt
7:
    beq  zero, zero, 7b

# a0 before each nop, before chain instruction k (k = 0..15) and after the chain (wait loop),
# computed with an independent model of the instructions, not by the CPU
.balign 4
chain_values:
    .word 0x13579BDF, 0x13579BDF, 0x13579BDF
    .word 0x13579BDF, 0x13579E94, 0x373F3275, 0xED297A6C
    .word 0xED297FC9, 0xFC47AD05, 0xFC47AC8E, 0xF35981B2
    .word 0xCEF0D4D1, 0xCEF0D4ED, 0xF35981CE, 0xF35989CD
    .word 0xFC47A4F1, 0x12D6884B, 0xED2977B4, 0x11922495
    .word 0x11922496, 0x11922496, 0x11922496
