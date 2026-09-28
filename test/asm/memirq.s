# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: memirq.s
#
# ------------------------------------------------------------------------------------------------
# |                                                                                              |
# | INTERRUPT DURING A MULTI-CYCLE BUS ACCESS (regression for writeback fix D).                  |
# |                                                                                              |
# | The machine-timer interrupt is armed to become pending at a swept distance (1-cycle steps)   |
# | from a straight-line block of 8 loads or stores to one peripheral, so over the iterations    |
# | of a pass it lands on every cycle of the block. Seven passes, one per target:                         |
# |   pass 0  sw  RAM                    (1-cycle ack: control)                                 |
# |   pass 1  sw  LEDs                   (2-cycle registered ack)                               |
# |   pass 2  sw  VGA memory             (2-cycle write)                                        |
# |   pass 3  sw  test stall register    (4-cycle ack)                                          |
# |   pass 4  lw  LEDs                   (2-cycle)                                              |
# |   pass 5  lw  VGA memory             (3-cycle read)                                         |
# |   pass 6  lw  test stall register    (4-cycle ack)                                          |
# |                                                                                              |
# | Interrupts are precise: every instruction before mepc has completed and none at or after     |
# | it. Store k of a block writes the value k+1, the target is reset to 0 before the block, so  |
# | the handler checks target == number of block stores before mepc. A store that was          |
# | performed on the bus but whose PC is still in mepc (so it is performed again after mret)    |
# | is reported as 'P' followed by the landing position. An interrupt whose trap state was committed but whose JUMP never       |
# | reached Fetch (handler not entered, MIE left 0) is reported as 'J'. Loads must return the   |
# | value in the target ('V').                                                                   |
# |                                                                                              |
# | UART prints one char per iteration: where mepc landed ('<' before the block, '0'..'8'      |
# | index into it, '>' after it) or the error letter.                                          |
# |                                                                                              |
# | Register allocation:                                                                         |
# |     a0..a7 = block data     s1 = char to print   s2 = 1: store pass (handler checks)        |
# |     s3 = timer traps        s4 = landing index   s5 = #bad iterations  s6 = iteration       |
# |     s7 = pass               s8 = block address   s9 = entry address   s10 = target          |
# |     s11 = test peripheral   gp = log2(stride*4)  s0 = block returned  tp = report         |
# |     t5, t6: handler only                                                                     |
# |                                                                                              |
# ------------------------------------------------------------------------------------------------
.equ TIMER_MTIME,    0x214004
.equ TIMER_CMP,      0x21400C
.equ TIMER_CMPH,     0x214010
.equ UART,           0x210000
.equ TEST,           0x480000
.equ STALLREG,       0x48000C
.equ LEDS,           0x200000
.equ VGA,            0x240000
.equ NPASS,          7
.equ ARM_DELAY,      29
.equ LOADVAL,        0x1234

.section .text.__reset
.globl __reset
__reset:
    li   s11, TEST
    li   t1, 1
    sw   t1, 0(s11)       # initial test: deliberate fail (proves the fail path works)
    la   sp, __ram_end
    la   t0, handler
    csrw mtvec, t0
    li   s5, 0
    li   s7, 0
    li   t0, TIMER_CMPH   # disarm timer
    li   t1, -1
    sw   t1, 0(t0)
    li   t0, 0x80
    csrw mie, t0          # MTIE
    csrsi mstatus, 8      # MIE

pass_loop:
    # per-pass setup: s10 = target, s9 = entry, s8 = block - bias, gp = shift,
    # s2 = store pass. Access k of a block is at block + k*stride*4, so the number
    # of accesses before mepc is (mepc - block + (stride-1)*4) >> log2(stride*4).
    slli t0, s7, 5
    la   t1, pass_table
    add  t0, t0, t1
    lw   s10, 0(t0)
    lw   s9, 4(t0)
    lw   gp, 8(t0)
    lw   s2, 12(t0)
    lw   tp, 16(t0)
    sw   tp, niter, t1
    addi s8, s9, 16*4     # the block follows 16 nops
    li   t0, 3
    bne  gp, t0, 1f
    addi s8, s8, -4       # stride 2: bias 4
1:  li   s6, 0
iter:
    # target: 0 for store passes, LOADVAL for load passes
    li   t0, LOADVAL
    bnez s2, 2f
    sw   t0, 0(s10)
    j    3f
2:  sw   zero, 0(s10)
3:  li   a0, 1
    li   a1, 2
    li   a2, 3
    li   a3, 4
    li   a4, 5
    li   a5, 6
    li   a6, 7
    li   a7, 8
    li   s3, 0
    li   s4, -99
    li   s0, 0
    # arm: mtimecmp = mtime + ARM_DELAY + s6 (low word while high = -1, then high = 0)
    li   t0, TIMER_MTIME
    lw   t1, 0(t0)
    addi t1, t1, ARM_DELAY
    add  t1, t1, s6
    li   t0, TIMER_CMP
    sw   t1, 0(t0)
    li   t0, TIMER_CMPH
    sw   zero, 0(t0)
    jalr ra, 0(s9)        # 16 nops + the 8-access block
    li   s0, 1
    # wait for this iteration's timer interrupt (bounded)
    li   t3, 100
5:  bnez s3, got
    addi t3, t3, -1
    bnez t3, 5b
    # the interrupt was not taken: its JUMP was lost (MIE was left 0)
    li   s1, 'J'
    addi s5, s5, 1
    csrsi mstatus, 8      # re-enable so the pending interrupt is taken now
    li   t3, 100
6:  bnez s3, report
    addi t3, t3, -1
    bnez t3, 6b
    j    fatal
got:
    li   t0, 1
    bne  s3, t0, fatal    # more than one timer trap in one iteration
    # handler verdict (store passes): s4 = -1 means imprecise, tp = where
    li   t0, -1
    bne  s4, t0, 9f
    li   s1, 'P'
    addi s5, s5, 1
    jal  putc
    mv   s4, tp
    j    7f
9:
    # load passes: every loaded register must hold LOADVAL
    bnez s2, 7f
    li   t0, LOADVAL
    li   s1, 'V'
    bne  a0, t0, bad
    bne  a1, t0, bad
    bne  a2, t0, bad
    bne  a3, t0, bad
    bne  a4, t0, bad
    bne  a5, t0, bad
    bne  a6, t0, bad
    bne  a7, t0, bad
7:  # landing position
    li   s1, '<'
    addi t0, s4, 100
    beqz t0, report       # s4 = -100: mepc before the block
    li   s1, '>'
    li   t0, 100
    beq  s4, t0, report   # s4 = 100: mepc after the block
    addi s1, s4, '0'
    j    report
bad:
    addi s5, s5, 1
report:
    jal  putc
    addi s6, s6, 1
    lw   t0, niter
    blt  s6, t0, iter
    li   s1, '\n'
    jal  putc
    addi s7, s7, 1
    li   t0, NPASS
    blt  s7, t0, pass_loop

    li   t1, 1
    beqz s5, pass
    sw   t1, 0(s11)       # fail
    j    done
pass:
    sw   zero, 0(s11)     # pass
done:
    li   t1, 2
    sw   t1, 0(s11)       # end of simulation
8:  j 8b
fatal:
    li   s1, 'F'
    jal  putc
    li   t1, 1
    sw   t1, 0(s11)
    j    done

putc:                     # s1 = char
    li   t0, UART
4:  lbu  t1, 3(t0)
    andi t1, t1, 4
    beqz t1, 4b
    sb   s1, 0(t0)
    ret

# ---- blocks: 16 nops, then 8 accesses (store k writes k+1), then ret -------------------------
# Stride 2 puts a nop after every access: back-to-back accesses to the test stall register
# would only stall on the first one (its counter re-arms after an idle cycle).
.macro BLOCK op
    .rept 16
    nop
    .endr
    \op  a0, 0(s10)
    \op  a1, 0(s10)
    \op  a2, 0(s10)
    \op  a3, 0(s10)
    \op  a4, 0(s10)
    \op  a5, 0(s10)
    \op  a6, 0(s10)
    \op  a7, 0(s10)
    ret
.endm
.macro BLOCK2 op
    .rept 16
    nop
    .endr
    \op  a0, 0(s10)
    nop
    \op  a1, 0(s10)
    nop
    \op  a2, 0(s10)
    nop
    \op  a3, 0(s10)
    nop
    \op  a4, 0(s10)
    nop
    \op  a5, 0(s10)
    nop
    \op  a6, 0(s10)
    nop
    \op  a7, 0(s10)
    nop
    ret
.endm

.align 4
blk_sw_ram:   BLOCK sw
.align 4
blk_sw_leds:  BLOCK sw
.align 4
blk_sw_vga:   BLOCK sw
.align 4
blk_sw_stall: BLOCK2 sw
.align 4
blk_lw_leds:  BLOCK lw
.align 4
blk_lw_vga:   BLOCK lw
.align 4
blk_lw_stall: BLOCK2 lw

.align 4
pass_table:               # target, entry, log2(stride*4), store pass, iterations (1-cycle steps)
    .word scratch,  blk_sw_ram,   2, 1, 14, 0, 0, 0
    .word LEDS,     blk_sw_leds,  2, 1, 22, 0, 0, 0
    .word VGA,      blk_sw_vga,   2, 1, 22, 0, 0, 0
    .word STALLREG, blk_sw_stall, 3, 1, 46, 0, 0, 0
    .word LEDS,     blk_lw_leds,  2, 0, 22, 0, 0, 0
    .word VGA,      blk_lw_vga,   2, 0, 30, 0, 0, 0
    .word STALLREG, blk_lw_stall, 3, 0, 46, 0, 0, 0

.align 4
scratch: .word 0
niter:   .word 0

.align 4
handler:
    csrr t5, mcause
    bgez t5, h_exc        # only the timer interrupt is expected
    addi s3, s3, 1
    li   t5, TIMER_CMPH
    li   t6, -1
    sw   t6, 0(t5)        # disarm
    # t6 = number of block accesses before mepc; s4 = the same, -100 before the
    # block, 100 after it (s0 = 1 once the block has returned)
    csrr t6, mepc
    sub  t6, t6, s8
    sra  t6, t6, gp
    mv   s4, t6
    bltz t6, 1f
    li   t5, 8
    ble  t6, t5, 3f       # inside the block (8 = its ret)
1:  csrr t5, mepc
    beq  t5, ra, 2f       # the instruction the block returns to
    bnez s0, 2f           # anywhere after the block
    li   s4, -100         # before the block (arm code, nops)
    li   t6, 0
    j    3f
2:  li   s4, 100
    li   t6, 8
3:  beqz s2, h_ret        # load pass: nothing to compare
    # precise: exactly the stores before mepc have been performed (t6 = their count)
    lw   t5, 0(s10)
    beq  t5, t6, h_ret
    mv   tp, s4           # remember where (for the report)
    li   s4, -1
h_ret:
    mret
h_exc:
    li   t1, 1
    sw   t1, 0(s11)
    li   t1, 2
    sw   t1, 0(s11)
3:  j 3b
