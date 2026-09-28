/* crt0 for FreeRTOS programs on HaDes-V+: gp, sp, zero .sbss/.bss, paint the
 * main/ISR stack, point mtvec at the FreeRTOS trap handler, run main(). */
    .section .text.__reset, "ax"
    .globl __reset
__reset:
    .option push
    .option norelax
    la   gp, __global_pointer$
    .option pop
    la   sp, __ram_end

    la   t0, __bss_start            /* zero .sbss and .bss */
    la   t1, __bss_end
1:  bgeu t0, t1, 2f
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    1b

2:  la   t0, __isr_stack_bottom     /* paint the main/ISR stack (high-water mark) */
    la   t1, __ram_end
    li   t2, 0xDEADBEEF
3:  bgeu t0, t1, 4f
    sw   t2, 0(t0)
    addi t0, t0, 4
    j    3b

4:  la   t0, freertos_risc_v_trap_handler   /* direct mode (handler is 256-byte aligned) */
    csrw mtvec, t0
    call main

    li   t0, 0x480000               /* main() returned: report a failure and stop */
    li   t1, 1
    sw   t1, 0(t0)
    li   t1, 2
    sw   t1, 0(t0)
5:  j    5b
