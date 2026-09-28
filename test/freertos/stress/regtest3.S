/* RegTest3 -- register-integrity task for the stress program.
 *
 * Like the official RISC-V port RegTest tasks (RegTest.S from the FreeRTOS
 * RISC-V QEMU demo, also linked into this program), but it also covers x1/ra,
 * checks that it always runs with mstatus.MIE=1 (it never enters a critical
 * section), yields with ECALL on every iteration, and reports a failure at
 * once through hal_fail() instead of by stalling its loop counter.
 * sp, gp and tp are not touched (the port does not save gp/tp).
 */
    .equ RT3_BASE, 0x33330000

    .section .text.vRegTest3Task, "ax"
    .globl vRegTest3Task
vRegTest3Task:
    li   x1, RT3_BASE + 1
    li   x5, RT3_BASE + 5
    li   x6, RT3_BASE + 6
    li   x7, RT3_BASE + 7
    li   x8, RT3_BASE + 8
    li   x9, RT3_BASE + 9
    li   x10, RT3_BASE + 10
    li   x11, RT3_BASE + 11
    li   x12, RT3_BASE + 12
    li   x13, RT3_BASE + 13
    li   x14, RT3_BASE + 14
    li   x15, RT3_BASE + 15
    li   x16, RT3_BASE + 16
    li   x17, RT3_BASE + 17
    li   x18, RT3_BASE + 18
    li   x19, RT3_BASE + 19
    li   x20, RT3_BASE + 20
    li   x21, RT3_BASE + 21
    li   x22, RT3_BASE + 22
    li   x23, RT3_BASE + 23
    li   x24, RT3_BASE + 24
    li   x25, RT3_BASE + 25
    li   x26, RT3_BASE + 26
    li   x27, RT3_BASE + 27
    li   x28, RT3_BASE + 28
    li   x29, RT3_BASE + 29
    li   x30, RT3_BASE + 30
    li   x31, RT3_BASE + 31

rt3_loop:
    li   x31, RT3_BASE + 1
    bne  x1, x31, rt3_corrupt
    li   x31, RT3_BASE + 5
    bne  x5, x31, rt3_corrupt
    li   x31, RT3_BASE + 6
    bne  x6, x31, rt3_corrupt
    li   x31, RT3_BASE + 7
    bne  x7, x31, rt3_corrupt
    li   x31, RT3_BASE + 8
    bne  x8, x31, rt3_corrupt
    li   x31, RT3_BASE + 9
    bne  x9, x31, rt3_corrupt
    li   x31, RT3_BASE + 10
    bne  x10, x31, rt3_corrupt
    li   x31, RT3_BASE + 11
    bne  x11, x31, rt3_corrupt
    li   x31, RT3_BASE + 12
    bne  x12, x31, rt3_corrupt
    li   x31, RT3_BASE + 13
    bne  x13, x31, rt3_corrupt
    li   x31, RT3_BASE + 14
    bne  x14, x31, rt3_corrupt
    li   x31, RT3_BASE + 15
    bne  x15, x31, rt3_corrupt
    li   x31, RT3_BASE + 16
    bne  x16, x31, rt3_corrupt
    li   x31, RT3_BASE + 17
    bne  x17, x31, rt3_corrupt
    li   x31, RT3_BASE + 18
    bne  x18, x31, rt3_corrupt
    li   x31, RT3_BASE + 19
    bne  x19, x31, rt3_corrupt
    li   x31, RT3_BASE + 20
    bne  x20, x31, rt3_corrupt
    li   x31, RT3_BASE + 21
    bne  x21, x31, rt3_corrupt
    li   x31, RT3_BASE + 22
    bne  x22, x31, rt3_corrupt
    li   x31, RT3_BASE + 23
    bne  x23, x31, rt3_corrupt
    li   x31, RT3_BASE + 24
    bne  x24, x31, rt3_corrupt
    li   x31, RT3_BASE + 25
    bne  x25, x31, rt3_corrupt
    li   x31, RT3_BASE + 26
    bne  x26, x31, rt3_corrupt
    li   x31, RT3_BASE + 27
    bne  x27, x31, rt3_corrupt
    li   x31, RT3_BASE + 28
    bne  x28, x31, rt3_corrupt
    li   x31, RT3_BASE + 29
    bne  x29, x31, rt3_corrupt
    li   x31, RT3_BASE + 30
    bne  x30, x31, rt3_corrupt
    csrr x31, mstatus
    andi x31, x31, 8
    beqz x31, rt3_mie_off

    la   x31, ulRegTest3Counter
    lw   x30, 0(x31)
    addi x30, x30, 1
    sw   x30, 0(x31)
    li   x30, RT3_BASE + 30
    li   x31, RT3_BASE + 31
    ecall                           /* portYIELD() */
    j    rt3_loop

rt3_corrupt:                        /* x31 = expected value = RT3_BASE + register number */
    li   a2, RT3_BASE
    sub  a2, x31, a2
    mv   a3, x31
    la   a0, rt3_msg_corrupt
    li   a1, 0
    call hal_fail

rt3_mie_off:
    la   a0, rt3_msg_mie
    li   a1, 0
    li   a2, 0
    li   a3, 0
    call hal_fail

    .section .rodata.rt3_msgs, "a"
rt3_msg_corrupt:
    .asciz "RegTest3: register corrupted (a=register number, b=expected value)"
rt3_msg_mie:
    .asciz "RegTest3: task running with mstatus.MIE=0 outside any critical section"
