# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: trapirq.s
#
# ------------------------------------------------------------------------------------------------
# |                                                                                              |
# | EXCEPTION + INTERRUPT IN THE SAME WRITEBACK CYCLE (regression for writeback fix A).          |
# |                                                                                              |
# | The machine-timer interrupt is armed to become pending at a swept distance from a trapping   |
# | instruction (ECALL in pass 0, an all-zero illegal instruction in pass 1), so over the 2x96   |
# | iterations it lands on every cycle around the moment the trapping instruction reaches        |
# | Writeback.                                                                                   |
# |                                                                                              |
# | Privileged spec: mepc is "the address of the instruction that was interrupted or that       |
# | encountered the exception", and ECALL/EBREAK set epc to the instruction itself. Whichever   |
# | trap is taken first, the trapping instruction must therefore be observed EXACTLY ONCE (as   |
# | mcause 11 / 2) and the interrupt exactly once. The bug recorded the interrupt with          |
# | mepc = PC+4, so the ECALL/illegal instruction silently vanished ('L'); under FreeRTOS a     |
# | lost portYIELD ECALL corrupts the ready lists (hang in vListInsert).                         |
# |                                                                                              |
# | UART prints one char per iteration: '.' ok, 'L' trap lost, 'D' trap duplicated.            |
# |                                                                                              |
# | Register allocation:                                                                         |
# |     s2 = #ECALL traps  s3 = #timer traps  s4 = #illegal traps  s5 = #bad iterations         |
# |     s6 = iteration     s7 = pass (0: ecall, 1: illegal)   s11 = test peripheral             |
# |                                                                                              |
# ------------------------------------------------------------------------------------------------
.equ TIMER_MTIME,    0x214004
.equ TIMER_CMP,      0x21400C
.equ TIMER_CMPH,     0x214010
.equ UART,           0x210000
.equ TEST,           0x480000
.equ NITER,          96

.section .text.__reset
.globl __reset
__reset:
    li   s11, TEST
    li   t1, 1
    sw   t1, 0(s11)       # initial test: deliberate fail (proves the fail path works)
    la   sp, __ram_end
    la   t0, handler
    csrw mtvec, t0
    li   s2, 0
    li   s3, 0
    li   s4, 0
    li   s5, 0
    li   s7, 0
    li   t0, TIMER_CMPH   # disarm timer
    li   t1, -1
    sw   t1, 0(t0)
    li   t0, 0x80
    csrw mie, t0          # MTIE
    csrsi mstatus, 8      # MIE

pass_loop:
    li   s6, 0
iter:
    # arm: mtimecmp = mtime + 8 + s6 (low word while high = -1, then high = 0)
    li   t0, TIMER_MTIME
    lw   t1, 0(t0)
    addi t1, t1, 8
    add  t1, t1, s6
    li   t0, TIMER_CMP
    sw   t1, 0(t0)
    li   t0, TIMER_CMPH
    sw   zero, 0(t0)
    .rept 24
    nop
    .endr
    beqz s7, do_ecall
    .word 0x00000000      # illegal instruction (all-zero encoding)
    j    after
do_ecall:
    ecall
after:
    .rept 70
    nop
    .endr
    # wait for this iteration's timer interrupt
    addi t3, s6, 1
    beqz s7, 5f
    addi t3, t3, NITER
5:  bne  s3, t3, 5b
    # the trapping instruction must have been observed exactly once
    add  t3, s2, s4       # total synchronous traps
    li   a0, '.'
    beq  t3, s3, report
    addi s5, s5, 1
    li   a0, 'L'
    bltu t3, s3, 6f
    li   a0, 'D'
6:  mv   s9, a0
    sub  t3, s3, s4       # resync so iterations stay independent
    beqz s7, 1f
    sub  t3, s3, s2
    mv   s4, t3
    j    2f
1:  mv   s2, t3
2:  mv   a0, s9
report:
    jal  putc
    addi s6, s6, 1
    li   t0, NITER
    blt  s6, t0, iter
    li   a0, '\n'
    jal  putc
    addi s7, s7, 1
    li   t0, 2
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
3:  j 3b

putc:                     # a0 = char
    li   t0, UART
4:  lbu  t1, 3(t0)
    andi t1, t1, 4
    beqz t1, 4b
    sb   a0, 0(t0)
    ret

.align 4
handler:
    csrr t5, mcause
    bltz t5, h_irq
    li   t6, 11
    beq  t5, t6, h_ecall
    addi s4, s4, 1        # illegal instruction
    j    h_skip
h_ecall:
    addi s2, s2, 1
h_skip:
    csrr t6, mepc
    addi t6, t6, 4
    csrw mepc, t6
    mret
h_irq:
    addi s3, s3, 1
    li   t5, TIMER_CMPH
    li   t6, -1
    sw   t6, 0(t5)        # disarm
    mret
