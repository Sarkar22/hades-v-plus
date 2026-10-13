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
# | chain instruction and in the wait loop behind the chain with 0 to 8 fixed wait states per    |
# | access. With random 1 to 8 wait states it does so for most seeds, not for every one: the     |
# | recorded positions below show which were reached.                                            |
# |                                                                                              |
# | The handler checks that the trap is the external interrupt and that it is precise: mepc      |
# | lies in the nops, the chain or its wait loop, and a0 holds the value after exactly the chain |
# | instructions before mepc (chain_values); any other case is counted in s9. Each iteration     |
# | then checks the final a0, and each sweep the number of interrupts and s9. The whole sweep    |
# | runs with the branch predictor off (mode 0) and in mode 3; the golden CPU ignores the mode.  |
# |                                                                                              |
# | The handler also records where the interrupts landed, as a mask of positions (bits 0-2: a    |
# | nop, bit 3 + k: before chain instruction k, bits 19-21: the wait loop), in the buffer: word  |
# | 0 for mode 0, word 1 for mode 3 (RAM 0x46000 and 0x46004; sim.fst does not hold the RAM, but |
# | the stores to these words show on its data port). The positions depend on the memory's       |
# | timing, so the program does not check them. The reports are the same at every latency.       |
# |                                                                                              |
# | EVICTION STEP, for a simulator with an instruction cache (docs/CACHES.md): before every      |
# | delay N the iteration calls evict_irq, a block placed exactly 8 KiB (0x2000 bytes) after the |
# | tested code, irq_tested..irq_tested_end (the iteration from label 1 and irq_handler). 8 KiB  |
# | is a multiple of 512 bytes, so line k of the block has the index of tested line k in a       |
# | 512-byte and in an 8 KiB direct-mapped cache, and every tested line misses again in every    |
# | iteration: the interrupt often arrives while Fetch waits for a refill, and the handler's     |
# | first fetch misses as well. The block runs one jal per two lines (evict_block below);        |
# | without a cache it costs about 30 cycles per delay.                                          |
# |                                                                                              |
# | POSITIONS THAT A CACHE MAKES UNREACHABLE. With the eviction step, six of the 22 positions    |
# | are never recorded (mask 0x3bbbba at MEM_LAT=2 in a 512-byte and in an 8 KiB cache;          |
# | 0x3ffffe, every position but bit 0, without a cache and in a 16 KiB cache, where the         |
# | eviction block at +8 KiB does not evict). The interrupt is recognised in the cycle in which  |
# | an instruction I is in Writeback; I retires, and mepc is the address after the next          |
# | instruction J when J is in Writeback in the next cycle, else the address after I             |
# | (rtl/writeback_stage.sv). Bit 0 (mepc = pad, the first nop): J would be the arming store, so |
# | I, the instruction before it, would have to be in Writeback when the interrupt is pending,   |
# | at least two cycles after the store's bus access; I has retired by then. It is unreachable   |
# | at every latency. Bits 2, 6, 10, 14 and 18 (the nop at pad + 8 and chain instructions 3, 7,  |
# | 11 and 15) are the second word of a 16-byte line (pad is the last word of its line, so the   |
# | words behind it fall at offsets 4 of the following lines): mepc there needs J to be the      |
# | first word of the line, in Writeback right behind I, the last word of the line before. Every |
# | tested line misses in every iteration, so the first word of a line reaches Writeback only    |
# | after the refill of its line, and J is a bubble: mepc is then the address after I, the first |
# | word of the line. With a hit in the line (no cache, or a cache that the eviction block does  |
# | not evict) the second word is reached as well. matrix.py (leg directed-coverage) derives the |
# | list from the assembled program, requires a reason for every position that is missing, and   |
# | runs this program in a 16 KiB cache to show that the six are otherwise reached except bit 0. |
# |                                                                                              |
# | Expected with a cache (from the assembled program): the tested code has TESTED_LINES = 16    |
# | lines of 16 bytes, and every one of them retires an instruction in every iteration, so       |
# | CACHE_STATS i_done is at least 2 * NMAX * TESTED_LINES = 6400 with 16-byte lines, in a       |
# | 512-byte and in an 8 KiB cache alike, and the eviction block's wrong-path refills give       |
# | i_abandoned at least 3200. Run with +ram_words=0x46000,0x46004 to read the recorded position |
# | masks (RAM_WORDS line).                                                                      |
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
# |     a4: wait-loop counter                 t4: scratch                ra: eviction return     |
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

# The lines of the tested code (irq_tested..irq_tested_end, below)
.equ IRQ_TESTED_LINES, 16

# Eviction step: evict_block <lines> fills <lines> 16-byte lines, for code placed exactly 8 KiB
# before it (see the header). It is entered with 'jal ra, <block> + 12' and returns to ra. Every
# even line k holds three nops and, at word 3, a jal to word 3 of line k + 2 (the last one returns
# with jalr): one instruction runs per two lines. The jal resolves in Execute, so Fetch presents
# word 0 of line k + 1 on the wrong path before the target, and a cache refills that line too (a
# started refill always completes). The other words are nops that never run.
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
    jal  zero, 1f

# The tested code: the iteration and the handler, from a line boundary
.balign 16
irq_tested:
1:
    jal  ra, evict_irq + 12        # eviction step (an instruction cache misses every tested line)
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
    jal  zero, sweep_done

# External interrupt: disarm the test device, count, and check that the trap is the external
# interrupt, that mepc lies in the chain, the nops before it or its wait loop, and that a0
# holds the value after exactly the chain instructions before mepc.
irq_handler:
    sw   zero, 4(t3)
    addi s7, s7, 1
    csrr s5, mcause
    li32 s6, 0x8000000B            # machine external interrupt
    bne  s5, s6, 5f                # an exception or another interrupt
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
.org irq_tested + 16 * IRQ_TESTED_LINES   # (an error if the tested code outgrows its lines)
irq_tested_end:

sweep_done:
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

# The eviction block, exactly 8 KiB after the tested code (below the buffer at 0x46000)
.org irq_tested + 0x2000
evict_irq:
    evict_block IRQ_TESTED_LINES
