/* Linker script for FreeRTOS programs on HaDes-V+ (init.mem images).
 *
 * The RAM size is given on the link command line:
 *     -Wl,--defsym=__hades_ram_size=<bytes>
 * 32 KiB is the real board. Anything larger needs a simulator verilated with
 * +define+HADES_MEMORY_SIZE_WORDS=<bytes/4> (see defines/constants.sv).
 *
 * The top __isr_stack_size bytes of RAM are main()'s stack until the scheduler
 * starts and the FreeRTOS interrupt stack afterwards (__freertos_irq_stack_top,
 * used because configISR_STACK_SIZE_WORDS is left undefined). start.S paints
 * that region so its high-water mark can be checked at run time.
 */
OUTPUT_ARCH(riscv)
ENTRY(__reset)

MEMORY {
    RAM (rwx) : ORIGIN = 0x40000, LENGTH = __hades_ram_size
}

__isr_stack_size = DEFINED(__isr_stack_size) ? __isr_stack_size : 2048;

SECTIONS {
    __ram_start = ORIGIN(RAM);
    __ram_end   = ORIGIN(RAM) + LENGTH(RAM);
    __freertos_irq_stack_top = __ram_end;
    __isr_stack_bottom = __ram_end - __isr_stack_size;

    /* The reset address is the first word of RAM. */
    .reset : {
        KEEP(*(.text.__reset))
        . = ALIGN(4);
    } > RAM

    .text : {
        *(.text .text.*)
        . = ALIGN(4);
    } > RAM

    .rodata : {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        . = ALIGN(4);
    } > RAM

    .data : {
        *(.data .data.*)
        . = ALIGN(4);
    } > RAM

    .sdata : {
        __sdata_start = .;
        *(.sdata .sdata.*)
        . = ALIGN(4);
    } > RAM

    .sbss (NOLOAD) : {
        __bss_start = .;
        *(.sbss .sbss.*)
        *(.scommon)
        . = ALIGN(4);
    } > RAM

    .bss (NOLOAD) : {
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
    } > RAM

    /DISCARD/ : {
        *(.eh_frame .eh_frame.*)
        *(.init_array* .fini_array* .preinit_array*)
    }

    __global_pointer$ = __sdata_start + 0x800;

    ASSERT(__bss_end <= __isr_stack_bottom,
           "FreeRTOS image + heap does not fit in RAM below the ISR stack (raise the RAM size or shrink the heap)")
}
