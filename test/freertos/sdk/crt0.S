/* crt0.S -- image header and start-up code of an app (test/freertos/loader/SPEC.md). */
    .section .hades_app_header, "a"
    .globl __hades_app_header
__hades_app_header:
    .word  0x50504148               /* magic: the bytes 'H' 'A' 'P' 'P' */
    .half  1, 64                    /* ABI version, header size */
    .word  0                        /* flags: filled in by appimg.py */
    .word  _start                   /* entry */
    .word  __app_image_size         /* from app.ld */
    .word  __app_bss_size
    .word  __app_stack_size
    .word  0                        /* CRC-32: filled in by appimg.py */
    .space 16                       /* name: filled in by appimg.py */
    .space 16                       /* reserved */

/* _start(api, argc, argv): called by the shell on the app's stack, ra = the shell's return path. */
    .section .text.hades_app_start, "ax"
    .globl _start
_start:
    la   t0, __app_bss_start        /* zero .sbss and .bss */
    la   t1, __app_bss_end
1:  bgeu t0, t1, 2f
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    1b
2:  la   t0, hades_api              /* the API, for app_printf() and the other helpers */
    sw   a0, 0(t0)
    mv   a0, a1                     /* main(argc, argv) */
    mv   a1, a2
    tail main                       /* main's return value goes back to the shell: the exit code */

    .section .sbss, "aw", @nobits
    .globl hades_api
    .balign 4
hades_api:
    .space 4
