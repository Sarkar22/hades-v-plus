# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: csrirq.s
#
# ------------------------------------------------------------------------------------------------
# |                                                                                              |
# | INSTRUCTION IN FLIGHT WHEN A SEQUENTIAL INTERRUPT JUMPS (regression for writeback fix C).    |
# |                                                                                              |
# | A sequential interrupt is decided at instruction I and JUMPs one cycle later, while the     |
# | next instruction J is already in Writeback. J must then either retire completely (trap      |
# | after J) or not execute at all (trap before J, mepc = J) -- never half of each. The timer   |
# | interrupt is swept over every cycle around a probe instruction; three probes:               |
# |                                                                                              |
# |  pass 0  J = `csrci mstatus,8` (FreeRTOS portDISABLE_INTERRUPTS). Right after it, MIE must  |
# |          read 0. Bug: J's CSR write was dropped while mepc skipped J, so the interrupt      |
# |          returned with MIE=1 inside the critical section ('E').                             |
# |  pass 1  J = `csrw mscratch`. The write must not be lost ('W').                             |
# |  pass 2  minstret: across `csrr s0,minstret ; 40 nops ; csrr s1,minstret`, s1-s0 must be   |
# |          41 plus the handler's instruction count if the interrupt landed inside the window. |
# |          Bug: a J that retired in the JUMP cycle was not counted ('I').                     |
# |                                                                                              |
# | UART prints one char per iteration: '.' ok, else the letter above.                          |
# |                                                                                              |
# | Register allocation:                                                                         |
# |     s3 = #timer traps  s5 = #bad iterations  s6 = iteration  s7 = pass  s11 = test periph.  |
# |     s9 = mepc seen by the last trap  s10 = handler length as measured with minstret (diag.)  |
# |                                                                                              |
# ------------------------------------------------------------------------------------------------
.equ TIMER_MTIME,    0x214004
.equ TIMER_CMP,      0x21400C
.equ TIMER_CMPH,     0x214010
.equ UART,           0x210000
.equ TEST,           0x480000
.equ NITER,          96
.equ HANDLER_LEN,    11          # instructions retired by one pass through `handler` (incl. mret)

.section .text.__reset
.globl __reset
__reset:
    li   s11, TEST
    li   t1, 1
    sw   t1, 0(s11)       # initial test: deliberate fail (proves the fail path works)
    la   sp, __ram_end
    la   t0, handler
    csrw mtvec, t0
    li   s3, 0
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
    li   s9, 0
    li   s10, 0
    # arm: mtimecmp = mtime + 8 + s6 (low word while high = -1, then high = 0)
    li   t0, TIMER_MTIME
    lw   t1, 0(t0)
    addi t1, t1, 8
    add  t1, t1, s6
    li   t0, TIMER_CMP
    sw   t1, 0(t0)
    li   t0, TIMER_CMPH
    sw   zero, 0(t0)
    li   a2, 0x5A000
    add  a2, a2, s6       # unique mscratch value for this iteration
    li   a0, '.'
    beqz s7, probe_mstatus
    li   t0, 1
    beq  s7, t0, probe_mscratch

    # Each probe starts with 24 straight-line nops: the instruction right before
    # the probe must be a real instruction (not a bubble behind a taken branch)
    # for the interrupt to be decided there and hit the probe in the JUMP cycle.
probe_minstret:
    .rept 24
    nop
    .endr
win_start:
    csrr s0, minstret
    .rept 40
    nop
    .endr
win_end:
    csrr s1, minstret
    .rept 30
    nop
    .endr
    jal  wait_irq
    sub  t1, s1, s0
    li   t2, 41
    la   t3, win_start
    bgeu t3, s9, 1f       # trap before csrr s0 retired (or no trap yet) -> not in window
    la   t3, win_end
    bltu t3, s9, 1f       # trap after csrr s1 retired -> not in window
    addi t2, t2, HANDLER_LEN   # handler ran inside the window
1:  beq  t1, t2, check_done
    li   a0, 'I'
    j    check_done

probe_mscratch:
    .rept 24
    nop
    .endr
    csrw mscratch, a2
    csrr a1, mscratch
    .rept 40
    nop
    .endr
    jal  wait_irq
    beq  a1, a2, check_done
    li   a0, 'W'
    j    check_done

probe_mstatus:
    .rept 24
    nop
    .endr
    csrci mstatus, 8      # portDISABLE_INTERRUPTS()
    csrr a1, mstatus
    .rept 40
    nop
    .endr
    csrsi mstatus, 8      # portENABLE_INTERRUPTS(): a still-pending interrupt is taken here
    jal  wait_irq
    andi a1, a1, 8
    beqz a1, check_done
    li   a0, 'E'

check_done:
    li   t0, '.'
    beq  a0, t0, 2f
    addi s5, s5, 1
2:  jal  putc
    addi s6, s6, 1
    li   t0, NITER
    blt  s6, t0, iter
    li   a0, '\n'
    jal  putc
    addi s7, s7, 1
    li   t0, 3
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

wait_irq:                 # wait until this iteration's (single) timer trap happened
    li   t0, NITER
    mv   t1, s7
    addi t2, s6, 1
4:  beqz t1, 5f
    add  t2, t2, t0
    addi t1, t1, -1
    j    4b
5:  bne  s3, t2, 5b
    ret

putc:                     # a0 = char (clobbers t0, t1)
    li   t0, UART
6:  lbu  t1, 3(t0)
    andi t1, t1, 4
    beqz t1, 6b
    sb   a0, 0(t0)
    ret

.align 4
handler:                  # timer only; HANDLER_LEN instructions, all retire
    csrr a4, minstret
    csrr s9, mepc
    addi s3, s3, 1
    li   t5, TIMER_CMPH   # 2 instructions (lui + addi)
    li   t6, -1
    sw   t6, 0(t5)        # disarm
    csrr a5, minstret     # a5 - a4 = 7 (instructions from the first csrr up to here)
    sub  s10, a5, a4
    addi s10, s10, 4      # + csrr a5, sub, addi, mret  => HANDLER_LEN when counting is right
    mret
