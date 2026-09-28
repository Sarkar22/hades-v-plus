# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: mtvecirq.s
#
# ------------------------------------------------------------------------------------------------
# |                                                                                              |
# | INTERRUPT TAKEN RIGHT AFTER A CSR WRITE TO MTVEC.                                            |
# |                                                                                              |
# | The external (wishbone_test) interrupt is armed to become pending at a swept distance       |
# | (1-cycle steps) from a `csrw mtvec` that switches between two vectors A and B, so over the  |
# | iterations it lands on every cycle around the moment the csrw reaches Writeback.            |
# |                                                                                              |
# | Privileged spec: the trap is taken at an instruction boundary; if mepc is after the csrw,   |
# | the csrw has retired and the trap must use the NEW mtvec; if mepc is at or before it, the    |
# | OLD one. Bug: a sequential interrupt decided on the csrw itself captured mtvec in that      |
# | cycle (the old value) and jumped there although the csrw retired (mepc after it).           |
# |                                                                                              |
# | The frozen golden CPU has the same bug one delay step earlier and FAILS this test ('V' at   |
# | delay 12): here the spec (and test/trapsweep/iss.py) is the reference, not the golden model. |
# |                                                                                              |
# | pass 0: A -> B, pass 1: B -> A. UART prints one char per iteration: '.' ok, 'V' wrong       |
# | vector for the landing position, 'N' interrupt never taken, 'D' taken twice.                |
# |                                                                                              |
# | Register allocation:                                                                         |
# |     s3 = #traps this iteration  s4 = vector entered (0 = A, 1 = B)  s8 = mepc seen          |
# |     s5 = #bad iterations  s6 = delay  s7 = pass  s11 = test peripheral                       |
# |                                                                                              |
# ------------------------------------------------------------------------------------------------
.equ TEST,  0x480000
.equ UART,  0x210000
.equ NITER, 40

.section .text.__reset
.globl __reset
__reset:
    li   s11, TEST
    li   t1, 1
    sw   t1, 0(s11)       # initial test: deliberate fail (proves the fail path works)
    la   t0, vec_a
    csrw mtvec, t0
    li   t0, 0x800
    csrw mie, t0          # MEIE (wishbone_test interrupt)
    csrsi mstatus, 8      # MIE
    li   s5, 0
    li   s7, 0

pass_loop:
    li   s6, 1
iter:
    li   s3, 0
    li   s4, -1
    li   s8, 0
    la   a0, vec_a
    la   a1, vec_b
    beqz s7, 1f
    csrw mtvec, a1        # pass 1: start at B, switch to A
    mv   a2, a0
    j    2f
1:  csrw mtvec, a0        # pass 0: start at A, switch to B
    mv   a2, a1
2:  sw   s6, 4(s11)       # arm: interrupt pending s6 cycles from now
    .rept 12
    nop
    .endr
probe:
    csrw mtvec, a2
    .rept 12
    nop
    .endr
    li   t3, 200          # wait for the interrupt (bounded)
3:  bnez s3, 4f
    addi t3, t3, -1
    bnez t3, 3b
    sw   zero, 4(s11)
    li   a0, 'N'
    j    bad
4:  li   t0, 1
    li   a0, 'D'
    bne  s3, t0, bad
    # expected vector: new one iff mepc is after the csrw
    la   t0, probe
    sltu t1, t0, s8       # t1 = 1: csrw retired before the trap -> new vector
    xor  t2, s4, s7       # t2 = 1: new vector entered (pass 0: B=1 is new; pass 1: A=0 is new)
    li   a0, 'V'
    bne  t1, t2, bad
    li   a0, '.'
    j    report
bad:
    addi s5, s5, 1
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
5:  j    5b

putc:                     # a0 = char (clobbers t0, t1)
    li   t0, UART
6:  lbu  t1, 3(t0)
    andi t1, t1, 4
    beqz t1, 6b
    sb   a0, 0(t0)
    ret

.align 4
vec_a:
    li   s4, 0
    j    handler
.align 4
vec_b:
    li   s4, 1
handler:
    csrr s8, mepc
    csrr t6, mcause
    bgez t6, h_exc        # only the external interrupt is expected
    sw   zero, 4(s11)     # clear the wishbone_test interrupt
    addi s3, s3, 1
    mret
h_exc:
    li   t1, 1
    sw   t1, 0(s11)
    li   t1, 2
    sw   t1, 0(s11)
7:  j    7b
