# App SDK for the shell's loader

Programs ("apps") built on the host for the app loader of the FreeRTOS shell (`APP=loader`,
simulation only). The guide is [docs/FREERTOS.md, section 10](../../../docs/FREERTOS.md#10-load-and-run-programs-on-the-shell);
the specification, with the image format and the load protocol, is
[../loader/SPEC.md](../loader/SPEC.md).

```bash
make freertos-app NAME=<name> [MARCH=rv32i|rv32im|rv32i_zba|rv32im_zba] [OPT=-O2|-Os|-O0]   # one app
make freertos-apps                                   # the examples (-O2) and the loader's test files
make freertos-shell APP=loader UPLOAD=<name>         # 'load' in the shell receives the app
make freertos-send UPLOAD=<name>                     # to a running 'make freertos-shell APP=loader PTY=1',
                                                     # at its prompt: the simulator types 'load' and sends it
```

| File | Contents |
|---|---|
| `hades_app.h` | The interface, ABI version 1: the app slot, the image header, the API table and the functions apps call (`app_printf()`, `app_getc()`, `app_exit()`, ...). |
| `crt0.S` | The image header (64 bytes, at the slot base) and the start-up code: it clears `.bss`, stores the address of the API table in `hades_api` and calls `main( argc, argv )`. |
| `app.ld` | The linker script: one region, the 128 KiB app slot at `0x00060000`; the link fails if the image, its `.bss`, its stack and the saved copy of the image do not fit. |
| `appimg.py` | The image tool: `hex` fills in the header's name, flags and CRC-32 and writes the Intel HEX file; `info` checks a file as the loader does; `testfiles` writes the loader's test files. |
| `sdk.mk` | The make targets above (included by `test/freertos/freertos.mk`). |
| `apps/<name>/` | One directory per app; every `.c` and `.S` file in it is compiled. `<name>` is the app's name, stored in its image header: 1 to 15 letters, digits, `_` or `-`. The examples: `hello`, `compute` (with `model.py`, which computes its expected values), `crash`, `selfmod`, `upper`. |

An app is compiled with `-march=<march> -mabi=ilp32 <opt> -ffunction-sections
-fdata-sections` and the include directories `test/freertos/sdk` and `std/include` (for
`peripherals.h`, the addresses of the devices), linked without the standard start files
against `crt0.S`, `app.ld`, newlib-nano and libgcc, and placed at the fixed address
`0x00060000`. The output goes to `${HADES_BUILD_DIR:-build}/test/freertos/sdk/<march>/`:
`<name>.hex` (the file to send), `.bin` (the image), `.elf`, `.dis`, `.map`. An app is rebuilt
when one of its sources, an SDK file or its flags change; `UPLOAD=<name>` keeps the
optimisation level of its last build.

Rules for an app (in full: SPEC.md, section 6.3): use only the API of `hades_app.h` to talk
to the shell; use RV32I, and M and Zba only if the app was built for them (the golden CPU runs
RV32I apps only); no `stdio` and no `malloc` (the memory between `__app_heap_start` and
`__app_heap_end` belongs to the app); do not write outside the slot, change `gp`, `tp`,
`mstatus`, `mie`, `mtvec` or the timer, keep interrupts disabled, or read the UART directly.
HaDes-V+ runs in machine mode without memory protection, so the shell cannot enforce these
rules: an exception, a stack overflow that FreeRTOS detects and Ctrl-C are contained, but an
app that breaks them can still bring the system down.
