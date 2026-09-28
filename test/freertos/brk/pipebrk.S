/* pipebrk -- register-integrity + pipeline-adjacency task for the brk program.
 *
 * Runs forever with ra and s0-s11 holding fixed values (checked every
 * iteration) while it executes, back to back and with interrupts enabled,
 * short sequences that put two "interesting" instructions next to each other
 * in the pipeline:
 *   - (M) a divide immediately before `csrci mstatus` / `csrsi mstatus`
 *   - (M) a divide immediately before ECALL (portYIELD), result used after it
 *   - a store / load to a slow peripheral (VGA word 1: write 2, read 3 cycles)
 *     immediately after a divide and a load-use into the next divide
 *   - a divide (or ALU op) immediately before fence.i
 *   - CSR write/read of mscratch (unused by the port) next to a divide
 *   - data-dependent branches on the results (exercises the branch predictor
 *     when it is enabled through MHPMEVENT10)
 * Without M the same skeleton runs with add/sub/xor instead of div/rem so
 * that the rv32i build has a golden twin. Operands come from an xorshift
 * register sequence seeded by the task parameter (a0), and include zero
 * divisors and INT_MIN / -1 (q*b + r == a holds for every input).
 * A failure calls hal_fail() at once. Loop counter: ulPipeBrkCounter.
 * sp, gp and tp are not touched.
 */
    .equ PB_BASE, 0x55550000

    .section .bss.ulPipeBrkCounter, "aw", @nobits
    .globl ulPipeBrkCounter
    .balign 4
ulPipeBrkCounter:
    .word 0

    .section .rodata.pb_msgs, "a"
pb_msg_regs:  .string "pipebrk: register corrupted (reg id, value)"
pb_msg_mie:   .string "pipebrk: MIE=1 right after csrci mstatus next to a divide"
pb_msg_inv:   .string "pipebrk: arithmetic invariant broken (block, value)"
pb_msg_vga:   .string "pipebrk: slow-bus read-back mismatch (read, written)"
pb_msg_scr:   .string "pipebrk: mscratch read-back mismatch (read, written)"
pb_msg_mie1:  .string "pipebrk: MIE=0 after csrsi mstatus"

/* INV(block): compute and check the arithmetic invariant of a0/a1/a2/a3.
 * M:     a2 = a0 / a1, a3 = a0 % a1   ->  a2*a1 + a3 == a0 (signed or unsigned)
 * no M:  a2 = a0 + a1, a3 = a0 - a1   ->  a2 + a3 == 2*a0                     */
#ifdef __riscv_mul
    #define OP_Q(rd, x, y)    div  rd, x, y
    #define OP_R(rd, x, y)    rem  rd, x, y
    #define OP_QU(rd, x, y)   divu rd, x, y
    #define OP_RU(rd, x, y)   remu rd, x, y
    .macro INV blk
        mul  t1, a2, a1
        add  t1, t1, a3
        beq  t1, a0, 1f
        li   a3, \blk
        mv   a2, t1
        j    pb_bad_inv
1:
    .endm
#else
    #define OP_Q(rd, x, y)    add  rd, x, y
    #define OP_R(rd, x, y)    sub  rd, x, y
    #define OP_QU(rd, x, y)   add  rd, x, y
    #define OP_RU(rd, x, y)   sub  rd, x, y
    .macro INV blk
        add  t1, a2, a3
        slli t2, a0, 1
        beq  t1, t2, 1f
        li   a3, \blk
        mv   a2, t1
        j    pb_bad_inv
1:
    .endm
#endif

    .section .text.vPipeBrkTask, "ax"
    .globl vPipeBrkTask
vPipeBrkTask:
    mv   a6, a0                 /* seed (task parameter), must be non-zero */
    bnez a6, 1f
    li   a6, 0x1234567
1:  li   x1,  PB_BASE + 1
    li   x8,  PB_BASE + 8
    li   x9,  PB_BASE + 9
    li   x18, PB_BASE + 18
    li   x19, PB_BASE + 19
    li   x20, PB_BASE + 20
    li   x21, PB_BASE + 21
    li   x22, PB_BASE + 22
    li   x23, PB_BASE + 23
    li   x24, PB_BASE + 24
    li   x25, PB_BASE + 25
    li   x26, PB_BASE + 26
    li   x27, PB_BASE + 27

pb_loop:
    /* xorshift32 on a6 */
    slli t0, a6, 13
    xor  a6, a6, t0
    srli t0, a6, 17
    xor  a6, a6, t0
    slli t0, a6, 5
    xor  a6, a6, t0
    mv   a0, a6
    /* divisor: a6 >> (a6 & 31) -- often small, sometimes 0; every 16th pass
     * INT_MIN / -1 */
    andi t0, a6, 31
    srl  a1, a6, t0
    andi t0, a6, 0x3C0
    bnez t0, 2f
    li   a0, 0x80000000
    li   a1, -1
2:
    /* ---- block 1: divide, then csrci mstatus right behind it ---- */
    OP_Q(a2, a0, a1)
    csrci mstatus, 8
    OP_R(a3, a0, a1)
    csrr t0, mstatus
    andi t0, t0, 8
    bnez t0, pb_bad_mie
    csrsi mstatus, 8
    INV 1
    csrr t0, mstatus
    andi t0, t0, 8
    beqz t0, pb_bad_mie1

    /* ---- block 2: divide, then ECALL (yield), result used after it ---- */
    OP_QU(a2, a0, a1)
    ecall
    OP_RU(a3, a0, a1)
#ifdef __riscv_mul
    mul  t1, a2, a1
    add  t1, t1, a3
    beq  t1, a0, 3f
    li   a3, 2
    mv   a2, t1
    j    pb_bad_inv
3:
#else
    INV 2
#endif

    /* ---- block 3: slow-bus store/load around divides, load-use into a divide ---- */
    li   t2, 0x00240004         /* VGA frame-buffer word 1 (only this task) */
    OP_Q(a2, a0, a1)
    sw   a2, 0(t2)
    lw   a4, 0(t2)
    OP_Q(a5, a4, a1)
    bne  a4, a2, pb_bad_vga
    OP_R(a3, a4, a1)
    mv   a2, a5
    mv   t3, a0
    mv   a0, a4
    INV 3
    mv   a0, t3

    /* ---- block 4: divide, then fence.i, then the remainder ---- */
    OP_QU(a2, a0, a1)
    fence.i
    OP_RU(a3, a0, a1)
#ifdef __riscv_mul
    mul  t1, a2, a1
    add  t1, t1, a3
    beq  t1, a0, 4f
    li   a3, 4
    mv   a2, t1
    j    pb_bad_inv
4:
#else
    INV 4
#endif

    /* ---- block 5: mscratch write/read next to divides ---- */
    OP_Q(a2, a0, a1)
    csrw mscratch, a2
    OP_R(a3, a0, a1)
    csrr t0, mscratch
    bne  t0, a2, pb_bad_scr
    INV 5

    /* ---- block 6: data-dependent branches on divide results ---- */
    OP_QU(a2, a0, a1)
    andi t0, a2, 1
    beqz t0, 5f
    addi a4, a2, -1             /* odd  -> a4 = q - 1 (even) */
    j    6f
5:  addi a4, a2, 1              /* even -> a4 = q + 1 (odd)  */
6:  xor  t0, a4, a2
    andi t0, t0, 1
    bnez t0, 7f
    li   a3, 6
    mv   a2, a4
    j    pb_bad_inv
7:  /* a short counted loop whose trip count depends on the result */
    andi t0, a2, 7
    addi t0, t0, 1
    li   t1, 0
8:  addi t1, t1, 3
    addi t0, t0, -1
    bnez t0, 8b
    andi t0, a2, 7
    addi t0, t0, 1
    slli t2, t0, 1
    add  t2, t2, t0             /* 3 * trip count */
    beq  t1, t2, 9f
    li   a3, 7
    mv   a2, t1
    j    pb_bad_inv
9:
    /* ---- block 7: MIE toggles right next to ECALL (yield) ----
     * csrsi mstatus; ecall  -- a pending interrupt is taken at the csrsi
     *                          (mepc = the ecall), then the ecall traps
     * csrci mstatus; ecall  -- yield with MIE=0 (must come back with MIE=0)
     * ecall; csrci mstatus  -- the interrupt JUMP may land on the csrci */
    csrsi mstatus, 8
    ecall
    csrr t0, mstatus
    andi t0, t0, 8
    beqz t0, pb_bad_mie1
    csrci mstatus, 8
    ecall
    csrr t0, mstatus
    andi t0, t0, 8
    bnez t0, pb_bad_mie
    csrsi mstatus, 8
    ecall
    csrci mstatus, 8
    csrr t0, mstatus
    andi t0, t0, 8
    bnez t0, pb_bad_mie
    csrsi mstatus, 8
    /* ---- register check ---- */
    li   t0, PB_BASE + 1
    li   a2, 1
    bne  x1, t0, pb_bad_reg
    li   t0, PB_BASE + 8
    li   a2, 8
    bne  x8, t0, pb_bad_reg
    li   t0, PB_BASE + 9
    li   a2, 9
    bne  x9, t0, pb_bad_reg
    li   t0, PB_BASE + 18
    li   a2, 18
    bne  x18, t0, pb_bad_reg
    li   t0, PB_BASE + 19
    li   a2, 19
    bne  x19, t0, pb_bad_reg
    li   t0, PB_BASE + 20
    li   a2, 20
    bne  x20, t0, pb_bad_reg
    li   t0, PB_BASE + 21
    li   a2, 21
    bne  x21, t0, pb_bad_reg
    li   t0, PB_BASE + 22
    li   a2, 22
    bne  x22, t0, pb_bad_reg
    li   t0, PB_BASE + 23
    li   a2, 23
    bne  x23, t0, pb_bad_reg
    li   t0, PB_BASE + 24
    li   a2, 24
    bne  x24, t0, pb_bad_reg
    li   t0, PB_BASE + 25
    li   a2, 25
    bne  x25, t0, pb_bad_reg
    li   t0, PB_BASE + 26
    li   a2, 26
    bne  x26, t0, pb_bad_reg
    li   t0, PB_BASE + 27
    li   a2, 27
    bne  x27, t0, pb_bad_reg

    la   t0, ulPipeBrkCounter
    lw   t1, 0(t0)
    addi t1, t1, 1
    sw   t1, 0(t0)
    j    pb_loop

/* failure exits: hal_fail(msg, NULL, a, b) */
pb_bad_reg:                     /* a2 = register id */
    mv   a3, a2
    li   a2, 0
    la   a0, pb_msg_regs
    j    pb_fail
pb_bad_mie:
    csrr a2, mstatus
    li   a3, 0
    la   a0, pb_msg_mie
    j    pb_fail
pb_bad_mie1:
    csrr a2, mstatus
    li   a3, 0
    la   a0, pb_msg_mie1
    j    pb_fail
pb_bad_inv:                     /* a3 = block, a2 = value */
    la   a0, pb_msg_inv
    mv   t0, a2
    mv   a2, a3
    mv   a3, t0
    j    pb_fail
pb_bad_vga:
    mv   a3, a2
    mv   a2, a4
    la   a0, pb_msg_vga
    j    pb_fail
pb_bad_scr:
    mv   a3, a2
    mv   a2, t0
    la   a0, pb_msg_scr
pb_fail:
    li   a1, 0
    call hal_fail
1:  j    1b
