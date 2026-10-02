/* app.ld -- linker script of an app for the HaDes-V+ shell's loader (test/freertos/loader/SPEC.md).
 * The app is linked at the base of the app slot, header first. There is no __global_pointer$,
 * so the linker never turns an access into a gp-relative one: gp belongs to the shell. */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    SLOT (rwx) : ORIGIN = 0x00060000, LENGTH = 128K
}

/* The app's stack, in bytes: HADES_APP_STACK_SIZE(n) in a source file overrides it. */
__app_stack_size = DEFINED(__app_stack_size) ? __app_stack_size : 4096;

SECTIONS {
    .header : { KEEP(*(.hades_app_header)) } > SLOT
    .text : {
        KEEP(*(.text.hades_app_start))
        *(.text .text.*)
        . = ALIGN(4);
    } > SLOT
    .rodata : { *(.rodata .rodata.* .srodata .srodata.*) . = ALIGN(4); } > SLOT
    .data : { *(.data .data.* .sdata .sdata.*) . = ALIGN(4); } > SLOT
    __app_image_end = .;
    .bss (NOLOAD) : {
        __app_bss_start = .;
        *(.sbss .sbss.* .scommon .bss .bss.* COMMON)
        . = ALIGN(4);
        __app_bss_end = .;
    } > SLOT
    /DISCARD/ : { *(.eh_frame .eh_frame.* .init_array* .fini_array* .preinit_array*) }

    __app_image_size = __app_image_end - ORIGIN(SLOT);
    __app_bss_size   = __app_bss_end - __app_bss_start;
    __app_copy_base  = ORIGIN(SLOT) + LENGTH(SLOT) - ((__app_image_size + 15) & ~15);
    __app_stack_top  = __app_copy_base;
    __app_heap_start = __app_bss_end;
    __app_heap_end   = __app_stack_top - __app_stack_size;

    ASSERT(__app_stack_size >= 1024 && (__app_stack_size & 15) == 0,
           "the app stack must be at least 1024 bytes and a multiple of 16")
    ASSERT(__app_heap_start <= __app_heap_end,
           "the app does not fit in the slot: image + bss + stack + the saved copy of the image")
}
