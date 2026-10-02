# App loader: build programs on the host, run them on the shell

This document specifies an opt-in extension of the FreeRTOS shell of
[docs/SHELL.md](../../../docs/SHELL.md). A program compiled on the host with
the project's GCC and the SDK in `test/freertos/sdk/` (an *app*) is sent to the running shell
over the UART as an Intel HEX file, stored in a reserved RAM area (the *app slot*) and run as a
FreeRTOS task. The shell stays alive: Ctrl-C stops a running app, and an app that raises an
exception is stopped and reported while the shell carries on.

Names, formats, constants, messages, make targets and the tests are normative; values
introduced with "for example" are not. Where a message is given in full, the shell prints
exactly that text, because the scripted sessions check it. The user's guide is
[docs/APPS.md](../../../docs/APPS.md).

**Contents**

1. [Overview](#1-overview)
2. [Memory layout and the loader configuration](#2-memory-layout-and-the-loader-configuration)
3. [App image format](#3-app-image-format)
4. [Load protocol](#4-load-protocol)
5. [Sending a file from the host](#5-sending-a-file-from-the-host)
6. [The API and the entry convention](#6-the-api-and-the-entry-convention)
7. [Running an app](#7-running-an-app)
8. [Shell commands and their output](#8-shell-commands-and-their-output)
9. [Host side: the SDK](#9-host-side-the-sdk)
10. [Tests](#10-tests)
11. [Out of scope](#11-out-of-scope)

## Summary

| Item | Value |
|---|---|
| Configuration | The FreeRTOS program `loader` (`test/freertos/loader/`): the shell's own sources compiled with `SHELL_LOADER=1`, plus `loader.c`. Selected with `APP=loader` on the console targets; without it nothing changes. |
| Simulated RAM | 256 KiB (`RAM_KB=256`); simulation only |
| Shell region | `0x00040000`-`0x0005ffff` (128 KiB): image, data, heap, and the interrupt stack in its top 1 KiB |
| App slot | `0x00060000`-`0x0007ffff` (128 KiB), fixed by the ABI |
| Image | A 64-byte header at the slot base (magic `HAPP`, ABI version 1, flags, entry, sizes, CRC-32, name), then code and data; linked at the slot base |
| Transfer | Intel HEX: records 00, 01, 04, 05; at most 32 data bytes per record; data records contiguous from the slot base; every line answered with ACK or NAK |
| Pacing | Four control bytes from the program to the console bridge: DC1 (waiting for input), DC2 (waiting for a file), ACK, NAK; and DC4 around the name of the file wanted. The bridge sends the next line of a file only after the answer to the previous one. |
| Host side of a transfer | Every mode: `load <name>` (the bridge sends that app's file, or a line `!<reason>` if it has none). Terminal: `UPLOAD=<app>` (the bridge sends the file whenever `load` without a name asks for one) or a paste. Pseudo-terminal: `make freertos-send UPLOAD=<app>` (a send request that the bridge serves at the shell's prompt) or `cat`. Scripts: a `#< <file>` line. |
| App task | Priority 1, below the console task (2); static TCB in the shell; its stack in the slot |
| Endings | Return from `main()` or `app_exit()`; Ctrl-C; an exception; a stack overflow detected by FreeRTOS (reported whatever else ended the app) |
| Containment | The exception hook redirects the app task's saved `mepc` to a trampoline of the shell; the console task reports and deletes the task |
| Re-runs | The shell keeps a saved copy of the image at the top of the slot and restores the image from it before every run |

## 1. Overview

### 1.1 What the user sees

```text
$ make freertos-shell APP=loader
...
[console] the apps for 'load <name>': bitmanip compute crash hello selfmod upper
...
hades> load hello
load: waiting for hello (Ctrl-C cancels)
[console] sending .../test/freertos/sdk/rv32i/hello.hex (2950 bytes)
.
loaded hello: 1048 bytes at 0x00060000, entry 0x00060040, CRC32 0x5b1e2f07
hades> run world
Hello, world!
argv[0] = hello
argv[1] = world
app: hello exited with code 1 after 52113 cycles
hades>
```

(Sizes, CRC and cycle counts for example.) The app was built on the host by `make`, which
also started the simulation; `load hello` asks for the file of the app `hello`, the
simulator's console bridge sends it, and `run` runs it. Each `load` sends the file as it is at
that moment, so an app rebuilt in another terminal (`make freertos-app NAME=hello`) is picked
up by the next `load`. `load` without a name receives the file named by `UPLOAD=` on the
command line of `make`, or a pasted one. The same works through a pseudo-terminal (`PTY=1`)
and in scripted sessions (section 5).

### 1.2 Scope and limitations

* **Simulation only.** The board's 32 KiB RAM is full with the shell (31,616 bytes at `-Os`),
  so the loader configuration runs on a simulated RAM of 256 KiB.
* **No memory protection.** HaDes-V+ runs in machine mode only, so an app has the same rights
  as the shell: it can overwrite the kernel, the shell, the trap vector and every CSR.
  Containment is best effort (section 7): it covers exceptions raised while the app's task
  runs, in the app's own code or in a shell function it called, and stack overflows that
  FreeRTOS detects at a task switch. An app that writes outside the slot, changes `mtvec`,
  `mstatus`, `mie` or the timer, or disables interrupts and loops can still corrupt or hang the
  system; so can an app whose stack pointer lies outside the slot when an exception or an
  interrupt occurs (the context is then saved outside the slot), and a jump into the shell's
  code. Ctrl-] always ends the simulation.
* **One app at a time, in the foreground.** While an app runs, the terminal belongs to it and
  the command line waits.
* **The golden CPU runs RV32I apps only**, as everywhere in this repository.
* **`mtval` reads as 0** on HaDes-V+ and on the golden CPU (docs/ARCHITECTURE.md); the fault
  report shows it only when it is not 0.
* **Not a general Intel HEX loader**: it accepts the subset of section 4.1, which the SDK
  writes.

### 1.3 What stays as it is

* `make freertos-shell`, `freertos-shell-test`, `freertos-shell-compare` and
  `freertos-shell-tty-test` without `APP=` run the shell exactly as before. The shell's sources
  gain only `#if SHELL_LOADER` blocks, which the shell does not compile, `common/hades_hal.c`
  gains one `weak` attribute, and `init.mem` of every existing program is byte-identical to that
  of commit 03386fd (section 10.4).
* The plain simulators do not contain the console bridge and are unchanged. The console
  simulators behave as before for every program that never sends the control bytes of
  section 5.2 (no other program does), with one exception that applies to every program: in
  the terminal and pseudo-terminal modes, typed-ahead input that contains a Ctrl-C is typed
  without waiting for the prompt after each Enter (rule 1 of section 5.3). Scripts do not use
  this path: the shell's scripted session keeps its cycle count.
* No existing test, script, transcript or expectation changes. The user's guide is a document
  of its own, docs/APPS.md.

## 2. Memory layout and the loader configuration

### 2.1 RAM map

| Byte address | Size | Contents |
|---|---|---|
| `0x00040000` | | the shell's image from `init.mem`: `.reset`, `.text`, `.rodata`, `.data`, `.sdata` |
| | | `.sbss`, `.bss`: kernel and shell data, the FreeRTOS heap (8 KiB), the app task's TCB |
| | | unused (room for the shell to grow) |
| `0x0005fc00` | 1 KiB | the stack of `main()`, then the interrupt stack (`APP_ISR_STACK` = 1024) |
| `0x00060000` | 128 KiB | the app slot (section 2.2) |
| `0x00080000` | | end of the simulated RAM (`RAM_KB` = 256) |

The shell alone takes 31,616 bytes at `-Os`, 34,188 at `-O2` and 46,524 at `-O0` (image, data
and its 4,608-byte heap, built at 03386fd). The loader adds its code, a heap of 8 KiB and the
statically allocated idle task, which leaves tens of KiB of the 128 KiB region free at every
optimisation level. If the shell ever outgrows the region, the existing `ASSERT` of
`hades-freertos.ld` fails the link; moving the slot is an ABI change (section 3.7).

### 2.2 The app slot

```text
0x00060000                image: header (64 bytes), code, read-only data, data     ulImageSize bytes
                          (written by 'load', restored from the saved copy before every run)
+ ulImageSize             .sbss and .bss, zeroed by crt0.S at every run            ulBssSize bytes
                          free: [__app_heap_start, __app_heap_end) belongs to the app
copy_base - ulStackSize   the app task's stack, growing down                       ulStackSize bytes
copy_base                 the saved copy of the image                              align16(ulImageSize) bytes
0x00080000                end of the slot
```

with `align16(n) = (n + 15) & ~15` and `copy_base = 0x00080000 - align16(ulImageSize)`; the
stack's top is `copy_base`. An image is valid only if

    ulImageSize + ulBssSize + ulStackSize + align16(ulImageSize) <= 131072

The reasons for this arrangement:

* The saved copy lets every run start from the image as it was loaded, whatever the previous
  run did to its data or code, without a copy loop in `crt0.S`.
* The stack grows away from the saved copy, towards the app's own data: an overflow damages the
  app first and never the copy. `run` checks the copy's CRC before restoring from it
  (section 7.1), so a copy damaged by a stray write is never run.
* Everything an app owns lies in the slot, and nothing of the shell lies between its parts.

### 2.3 How the linker scripts express it

* **The shell** is linked with the existing `test/freertos/common/hades-freertos.ld`, unchanged,
  and `-Wl,--defsym=__hades_ram_size=128K`. Everything it places, the interrupt stack included,
  then ends at `__ram_end` = `0x00060000`, and its existing `ASSERT` guards the region.
  `freertos.mk` has the knob `APP_LINK_KB` (section 2.4): the RAM size a program is linked
  for, by default `FRTOS_RAM_KB`, so that the link line, `flags.txt` and the image of every
  existing program stay exactly as they are.
* **The simulator** is the console variant for 256 KiB, `frtos-model/<cpu>-256k-console`, built by
  the existing rules (`FRTOS_RAM_KB` = 256 gives `+define+HADES_MEMORY_SIZE_WORDS=65536`).
* **Apps** are linked with `test/freertos/sdk/app.ld` (section 3.3): one region at `0x00060000`
  of 128 KiB.
* **Checks.** `loader.c` refuses to compile with `FRTOS_RAM_KB` < 256 (`#error`), and the shell
  checks at start-up that `__ram_end` equals `HADES_APP_SLOT_BASE` (`hal_fail()` otherwise).

### 2.4 Selecting the loader configuration

The loader configuration is the FreeRTOS program `loader`, selected with `APP=loader` on the
existing console targets:

```bash
make freertos-shell APP=loader [UPLOAD=<app>] [PTY=1] [CPU=golden]   # interactive
make freertos-shell-test APP=loader [SCRIPT=<file>] [CPU=golden]     # test/freertos/loader/session.txt
make freertos-shell-compare APP=loader                               # the session on both CPUs, compared
make freertos-shell-tty-test APP=loader                              # test/freertos/loader/tty_test.py
```

A program rather than a flag such as `LOADER=1`: it reuses every console target and knob
(`CPU`, `PTY`, `SCRIPT`, `OPT`, `TICK`, `BPRED`, `SEED`, `TIMEOUT`, `WAVES`), has a build
directory and `flags.txt` of its own, and leaves the shell's build untouched. `make freertos
APP=loader` refuses, as it does for the shell (`APP_CONSOLE := 1`), and `make freertos-list`
lists it.

`test/freertos/loader/app.mk` (normative content; comments may be worded differently):

```make
# loader: the shell with an app loader: run programs built on the host; 256 KiB, simulation only
#
# test/freertos/loader/SPEC.md. The shell's sources (test/freertos/shell/) compiled with
# SHELL_LOADER=1, plus loader.c: the commands load, run and app. The SDK and the example apps
# are in test/freertos/sdk/. Interactive: make freertos-shell APP=loader [UPLOAD=<app>]
# [PTY=1]; scripted: make freertos-shell-test APP=loader (session.txt).
ifeq ($(wildcard $(FREERTOS_PLUS_CLI)/FreeRTOS_CLI.c),)
$(error FreeRTOS+CLI not found at $(FREERTOS_PLUS_CLI). ...)
endif
APP_SRCS         := $(FRTOS_DIR)/shell/main.c $(FRTOS_DIR)/shell/console.c \
                    $(FRTOS_DIR)/shell/commands.c $(FRTOS_DIR)/shell/format.c \
                    $(FREERTOS_PLUS_CLI)/FreeRTOS_CLI.c $(APP_DIR)/loader.c
APP_REF_SRCS     := $(FRTOS_DIR)/shell/swmodel.c
APP_INCLUDES     := -I$(FREERTOS_PLUS_CLI) -I$(FRTOS_DIR)/shell -I$(FRTOS_DIR)/sdk
APP_KERNEL_SRCS  := tasks.c queue.c list.c
APP_DEFS         := -DSHELL_LOADER=1 -DSHELL_RX_BUFFER=128
# -Os unless OPT= is given, as for the shell; every level fits the shell's 128 KiB.
ifeq ($(filter command line,$(origin OPT) $(origin FRTOS_OPT)),)
FRTOS_OPT        := -Os
endif
# The simulated RAM; the shell is linked for its first 128 KiB, the app slot follows.
APP_RAM_KB       := 256
APP_LINK_KB      := 128
APP_ISR_STACK    := 1024
APP_TIMEOUT      := 300000000
APP_CONSOLE      := 1
# The example apps and the test files, built before every console run, and where the console
# bridge finds them: relative file names, and the apps that 'load <name>' names (their RV32I
# builds). (Recursive '=': SDK_OUT is defined by sdk.mk, included later.)
APP_CONSOLE_DEPS := freertos-apps
APP_CONSOLE_ARGS  = +console_upload_dir=$(SDK_OUT) +console_app_dir=$(SDK_OUT)/rv32i
APP_TTY_TEST     := $(APP_DIR)/tty_test.py
APP_TTY_ARGS      = --upload-dir $(SDK_OUT)
```

The `$(error ...)` message is the one of `shell/app.mk`. No comment may follow a value on the
same line: make would keep the blanks in front of it as part of the value.

`test/freertos/loader/app_config.h` (normative content):

```c
/* loader: settings on top of common/FreeRTOSConfig.h: those of the shell, and what the
 * loader needs. */
#include "../shell/app_config.h"

/* The heap: the shell's tasks, its receive queue and the CLI's command list. The app's TCB
 * and stack are not on it. */
#undef configTOTAL_HEAP_SIZE
#define configTOTAL_HEAP_SIZE              ( ( size_t ) ( 8192 ) )

/* The app task: a static TCB in the shell and a stack in the app slot (xTaskCreateStatic),
 * deleted by the console task when the app ends. */
#define configSUPPORT_STATIC_ALLOCATION    1
#define INCLUDE_vTaskDelete                1
```

Knobs of `freertos.mk` for the loader, all with defaults that leave every other command line as it is:

| Variable (in an `app.mk`) | Meaning | Default |
|---|---|---|
| `APP_LINK_KB` | RAM size the program is linked for (`__hades_ram_size`) | `FRTOS_RAM_KB` |
| `APP_CONSOLE_DEPS` | make goals built (quietly, with the program) before a console run | empty |
| `APP_CONSOLE_ARGS` | extra simulator arguments of console runs, interactive and scripted | empty |
| `APP_TTY_TEST` | the script of `freertos-shell-tty-test` | `test/freertos/shell/tty_test.py` |
| `APP_TTY_ARGS` | extra arguments of that script | empty |

and, on the command line of `freertos-shell`, `UPLOAD=<app>` (section 9.6), which builds the
app's file if needed and passes `+console_upload=<absolute path>` to the simulator. `UPLOAD` is
honoured only on the command line, like the other short knobs.

### 2.5 Hooks in the shell's sources

All of them inside `#if SHELL_LOADER`; `shell.h` defines `SHELL_LOADER` as 0 unless it is given.

* `shell/console.c`: (1) the receive interrupt `app_external_irq()`: while an app runs, a
  received Ctrl-C (`0x03`) is not queued but notifies the console task (section 7.4); (2) for
  `loader.c`: read one byte from the receive queue with a timeout; discard the queue's
  contents; tell whether the output is at the start of a line; set the line editor's previous
  character (section 4.2, item 8).
* `shell/commands.c`: the entries `load`, `run` and `app` in `axCommands[]` between `echo` and
  `halt`; the exception handler calls `loader_exception()` (section 7.5) before `hal_fail()`;
  `mem` prints one more line (section 8.3).
* `shell/main.c`: one more banner line (section 8.2); `loader_init()` before the scheduler
  starts.
* `shell/shell.h`: the declarations.
* `common/hades_hal.c`: `vApplicationStackOverflowHook()` becomes `__attribute__( ( weak ) )`,
  as the two hooks below it already are, so that the loader can define its own (section 7.6).
  The code is the same, and every program's image stays byte-identical (section 10.4).

## 3. App image format

### 3.1 The interface header: `test/freertos/sdk/hades_app.h`

This file is the ABI. The shell (`loader.c`) and every app include it. Its declarations are
normative as given here; comments may be worded differently.

```c
/* hades_app.h -- the interface between the HaDes-V+ shell's app loader and the apps it runs
 * (test/freertos/loader/SPEC.md), ABI version 1: the app slot, the image header, the API table
 * and the helpers that apps call. */
#ifndef HADES_APP_H
#define HADES_APP_H

#include <stddef.h>
#include <stdint.h>

/* ---------------------------------------------------------------------- the app slot -- */
#define HADES_APP_SLOT_BASE        0x00060000u
#define HADES_APP_SLOT_SIZE        0x00020000u   /* 128 KiB */
#define HADES_APP_SLOT_END         ( HADES_APP_SLOT_BASE + HADES_APP_SLOT_SIZE )

/* -------------------------------------------------------------------- the image header -- */
#define HADES_APP_MAGIC            0x50504148u   /* the bytes 'H' 'A' 'P' 'P' */
#define HADES_APP_ABI              1u
#define HADES_APP_HEADER_SIZE      64u
#define HADES_APP_NAME_SIZE        16u           /* at most 15 characters and a NUL */
#define HADES_APP_STACK_MIN        1024u
#define HADES_APP_STACK_DEFAULT    4096u
#define HADES_APP_NEEDS_M          ( 1u << 0 )   /* ulFlags: compiled for M */
#define HADES_APP_NEEDS_ZBA        ( 1u << 1 )   /* ulFlags: compiled for Zba */
#define HADES_APP_NEEDS_ZBB        ( 1u << 2 )   /* ulFlags: compiled for Zbb */
#define HADES_APP_NEEDS_ZBS        ( 1u << 3 )   /* ulFlags: compiled for Zbs */

typedef struct
{
    uint32_t ulMagic;                       /*  0: HADES_APP_MAGIC */
    uint16_t usAbi;                         /*  4: HADES_APP_ABI */
    uint16_t usHeaderSize;                  /*  6: HADES_APP_HEADER_SIZE */
    uint32_t ulFlags;                       /*  8: HADES_APP_NEEDS_* */
    uint32_t ulEntry;                       /* 12: the address of _start */
    uint32_t ulImageSize;                   /* 16: bytes loaded, from the slot base */
    uint32_t ulBssSize;                     /* 20: bytes after the image, zeroed by crt0.S */
    uint32_t ulStackSize;                   /* 24: bytes of stack */
    uint32_t ulCrc32;                       /* 28: CRC-32 of the image, this field read as 0 */
    char acName[ HADES_APP_NAME_SIZE ];     /* 32: NUL-terminated and NUL-padded */
    uint32_t aulReserved[ 4 ];              /* 48: 0 */
} HadesAppHeader_t;

_Static_assert( sizeof( HadesAppHeader_t ) == HADES_APP_HEADER_SIZE, "HadesAppHeader_t" );

/* ----------------------------------------------------------------------- the API table -- */
#define HADES_APP_CPU_M            ( 1u << 0 )   /* ulCpu: the CPU executes M */
#define HADES_APP_CPU_ZBA          ( 1u << 1 )   /*        ... Zba */
#define HADES_APP_CPU_ZICNTR       ( 1u << 2 )   /*        ... reads cycle, time, instret */
#define HADES_APP_CPU_ZBB          ( 1u << 3 )   /*        ... Zbb */
#define HADES_APP_CPU_ZBS          ( 1u << 4 )   /*        ... Zbs */
#define HADES_APP_CPU_ZICOND       ( 1u << 5 )   /*        ... Zicond (czero.eqz, czero.nez) */

typedef struct HadesApi
{
    uint32_t ulAbi;                 /* HADES_APP_ABI */
    uint32_t ulSize;                /* sizeof( HadesApi_t ) in the shell */
    uint32_t ulCpu;                 /* HADES_APP_CPU_* */
    uint32_t ulTickHz;              /* RTOS ticks per second (1000) */
    uint32_t ulCyclesPerTick;       /* clock cycles per tick (TICK=) */
    void ( * pxPutc )( char c );
    void ( * pxPuts )( const char * pcText );
    void ( * pxWrite )( const char * pcText, size_t xLength );
    int ( * pxPrintf )( const char * pcFormat, ... ) __attribute__( ( format( printf, 1, 2 ) ) );
    int ( * pxSnprintf )( char * pcBuffer, size_t xSize, const char * pcFormat, ... )
        __attribute__( ( format( printf, 3, 4 ) ) );
    int ( * pxGetc )( int32_t lTimeoutMs );
    void ( * pxDelayMs )( uint32_t ulMs );
    uint32_t ( * pxTicks )( void );
    void ( * pxExit )( int iCode ) __attribute__( ( noreturn ) );
} HadesApi_t;

/* The entry point (_start of crt0.S), called on the app task's stack. Returning from it ends
 * the app, with the returned value as its exit code. */
typedef int ( * HadesAppEntry_t )( const HadesApi_t * pxApi, int iArgc, char ** ppcArgv );

/* ------------------------------------------------- console control bytes (SPEC.md 5.2) -- */
/* Sent by the shell to pace the simulator's console bridge; a terminal does not show them.
 * An app must not send them. */
#define HADES_CON_ACK              0x06u         /* a record line was accepted */
#define HADES_CON_INPUT            0x11u         /* DC1: waiting for input */
#define HADES_CON_FILE             0x12u         /* DC2: waiting for a file */
#define HADES_CON_NAME             0x14u         /* DC4: around the name of the file wanted */
#define HADES_CON_NAK              0x15u         /* a record line was rejected */

/* ------------------------------------------------------------------------- for apps -- */
/* The functions of the shell that an app calls, through the table that crt0.S receives
 * (SPEC.md, section 6.2). Call them only from the app's own task (an app has no other). The
 * devices (LEDs, switches, buttons, 7-segment display, VGA) are reached directly, with the
 * addresses of peripherals.h (std/include/, on the SDK's include path); the shell's blink
 * task rewrites the whole LED register every 500 ticks. */
extern const HadesApi_t * hades_api;            /* set by crt0.S before main() runs */

/* Output. Every '\n' is sent as "\r\n", and each line is sent as one unit, so that it never
 * interleaves with the output of other tasks. app_puts() adds no newline; app_write() sends
 * n characters. */
#define app_putc( c )              ( hades_api->pxPutc( c ) )
#define app_puts( s )              ( hades_api->pxPuts( s ) )
#define app_write( s, n )          ( hades_api->pxWrite( ( s ), ( n ) ) )

/* The shell's formatter: %d %i %u %x %X %s %c %%, the flags '-' and '0', a width (digits or
 * '*'), a precision for %s, the length modifiers l and z (32 bits) and ll (64 bits); no
 * floating point. app_printf() prints at most 159 characters per call (the rest is cut);
 * app_snprintf( buf, n, fmt, ... ) stores at most n - 1 and a NUL. Both return the number of
 * characters printed or stored. */
#define app_printf( ... )          ( hades_api->pxPrintf( __VA_ARGS__ ) )
#define app_snprintf( ... )        ( hades_api->pxSnprintf( __VA_ARGS__ ) )

/* Input. The next byte typed (0 to 255), or -1 if none arrives within ms milliseconds; ms < 0
 * waits for ever, 0 does not wait. Bytes arrive as typed: no echo, no line editing (CR, LF,
 * Backspace and DEL arrive as such). Ctrl-C never arrives: it stops the app. */
#define app_getc( ms )             ( hades_api->pxGetc( ms ) )

/* Time. app_delay_ms() blocks for ms milliseconds (one RTOS tick each; 0 yields);
 * app_ticks() is the tick count since the scheduler started (ticks of 1 ms at the nominal
 * 1 kHz; one tick is ulCyclesPerTick clock cycles). */
#define app_delay_ms( ms )         ( hades_api->pxDelayMs( ms ) )
#define app_ticks()                ( hades_api->pxTicks() )

/* Ends the app with this exit code, as returning it from main() does; does not return. */
#define app_exit( code )           ( hades_api->pxExit( code ) )

/* What the CPU executes: HADES_APP_CPU_M, _ZBA, _ZICNTR, _ZBB, _ZBS and _ZICOND. Zicond has no
 * -march of its own (std/include/zicond.h emits its instructions): an app that uses it checks
 * HADES_APP_CPU_ZICOND first. */
#define app_cpu()                  ( hades_api->ulCpu )

/* mcycle as 64 bits (high, low, high read); both CPUs implement it. */
static inline uint64_t app_cycles( void )
{
    uint32_t ulHi, ulLo, ulHi2;

    do
    {
        __asm volatile ( "csrr %0, mcycleh" : "=r" ( ulHi ) );
        __asm volatile ( "csrr %0, mcycle" : "=r" ( ulLo ) );
        __asm volatile ( "csrr %0, mcycleh" : "=r" ( ulHi2 ) );
    } while( ulHi != ulHi2 );

    return ( ( uint64_t ) ulHi << 32 ) | ulLo;
}

/* The app's free memory, after its .bss and below its stack (app.ld): there is no malloc. */
extern char __app_heap_start[], __app_heap_end[];

/* HADES_APP_STACK_SIZE( 8192 ); at file scope sets the app's stack size in bytes (default
 * HADES_APP_STACK_DEFAULT): at least HADES_APP_STACK_MIN and a multiple of 16, written as a
 * plain integer literal (it becomes an assembler symbol, which app.ld reads and checks). */
#define HADES_APP_STACK_SIZE( n )  __asm__( ".globl __app_stack_size\n\t.set __app_stack_size, " #n )

#endif /* HADES_APP_H */
```

The API's member names avoid `putc` and `getc`, which `<stdio.h>` may define as macros; the
header compiles cleanly with `-Wall -Wextra` next to `<stdio.h>` (checked with GCC 12.2).

### 3.2 Header fields

All fields little-endian, at the slot base.

| Offset | Field | Rule (checked by `load`, section 4.3) | Filled in by |
|---|---|---|---|
| 0 | `ulMagic` | `0x50504148` (the bytes `HAPP`) | `crt0.S` |
| 4 | `usAbi` | 1 | `crt0.S` |
| 6 | `usHeaderSize` | 64 | `crt0.S` |
| 8 | `ulFlags` | bit 0: compiled for M; bit 1: compiled for Zba; every other bit 0 | `appimg.py`, from the `-march` |
| 12 | `ulEntry` | inside the image after the header, `[0x00060040, 0x00060000 + ulImageSize)`, a multiple of 4 | `crt0.S` (`_start`) |
| 16 | `ulImageSize` | the bytes received; a multiple of 4; at least 68 | `app.ld` |
| 20 | `ulBssSize` | a multiple of 4 | `app.ld` |
| 24 | `ulStackSize` | at least 1024, a multiple of 16 | `app.ld` (`__app_stack_size`) |
| 28 | `ulCrc32` | the CRC-32 of section 3.4 | `appimg.py` |
| 32 | `acName` | 1 to 15 characters out of `A-Z a-z 0-9 _ -`, then NULs up to 16 bytes | `appimg.py` (the app's directory name) |
| 48 | `aulReserved` | 0 (not checked: section 4.3 has no reason for it) | `crt0.S` |

Besides, the sizes must fit the slot (section 2.2).

### 3.3 The app linker script: `test/freertos/sdk/app.ld`

Normative content (tested with binutils 2.39: the symbols come out as expected, and an app that
does not fit fails the link with the second message):

```ld
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
```

`objcopy -O binary` of the linked ELF gives exactly the image: `ulImageSize` bytes from the slot
base. The memory `[__app_heap_start, __app_heap_end)` is the app's to use; no allocator is
provided.

### 3.4 CRC-32

The standard CRC-32 of IEEE 802.3, as computed by Python's `zlib.crc32()`: reflected, polynomial
`0xEDB88320`, initial value `0xFFFFFFFF`, final XOR `0xFFFFFFFF`. Check value: the CRC-32 of the
nine ASCII bytes `123456789` is `0xcbf43926`. It is computed over the image
`[0x00060000, 0x00060000 + ulImageSize)` with the four bytes of `ulCrc32` read as 0. The shell
uses a 16-entry table (64 bytes, four bits per step).

### 3.5 Start-up code: `test/freertos/sdk/crt0.S`

Normative content (tested with the linker script above):

```asm
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
```

`crt0.S` sets neither `gp` nor `tp`: they belong to the shell (section 6.3).

### 3.6 Reference image: `tiny`

The smallest valid image, written by `appimg.py testfiles` (section 9.5): a header and two
instructions, `li a0, 7` and `ret` (`0x00700513`, `0x00008067`), with no `crt0.S`. Its entry
returns 7 directly to the shell, which tests the entry convention on its own. Header: image 72
bytes, bss 0, stack 1024, entry `0x00060040`, flags 0, name `tiny`. Its CRC-32 is `0xa0537c91`,
and `tiny.hex` is exactly (CR LF line ends):

```text
:020000040006F4
:100000004841505001004000000000004000060040
:10001000480000000000000000040000917C53A094
:1000200074696E790000000000000000000000000C
:1000300000000000000000000000000000000000C0
:08004000130570006780000049
:0400000500060040B1
:00000001FF
```

Both sides are checked against it: `appimg.py` produces this text, and the loader answers
`loaded tiny: 72 bytes at 0x00060000, entry 0x00060040, CRC32 0xa0537c91`. The negative test
files (section 9.5) are variations of it, with line numbers that refer to these eight lines.

### 3.7 Versioning

ABI version 1 covers: the slot's address and size, the header, `app.ld`'s layout rules, the
entry convention (section 6.1), the API table and its semantics, and the rules of section 6.3.
Within version 1, members are only ever appended to `HadesApi_t`, and an app checks `ulSize`
before it uses one added later. Any incompatible change, such as moving the slot, raises
`HADES_APP_ABI`; `load` refuses an image of another version.

## 4. Load protocol

### 4.1 The accepted Intel HEX

* Record types `00` (data), `01` (end of file), `04` (extended linear address) and `05` (start
  linear address). Every other type is refused. (`objcopy -O ihex` writes types `02` and `03`
  for addresses below 1 MiB, which is one reason why the SDK writes the file itself.)
* At most 32 data bytes per record, so a line has at most 75 characters without its line end.
* After the `:`, only hexadecimal digits, upper or lower case: no blanks.
* A line ends with CR, LF or CR LF. Empty lines are ignored.
* Data records are contiguous and in increasing order: the first starts at the slot base, and
  each one starts where the previous one ended. Every byte lies inside the slot. A record does
  not cross a 64 KiB boundary (its 16-bit address does not wrap).
* `01` is exactly `:00000001FF`. `04` has 2 data bytes and address `0000`; it gives the upper
  16 bits of the following data addresses (initially 0). `05` has 4 data bytes and address
  `0000`; it is optional, and if present it must equal the header's entry.
* The bytes of a data record are written to RAM only after its checksum has been verified (the
  upstream boot loader, `std/src/boot_internal.c`, writes them as they arrive).

### 4.2 The exchange

1. `load [name]` unloads the current app (from here on none is loaded), fills the whole slot
   with zeros, so that no part of an older image can pass for part of the new one, prints
   `load: waiting for an Intel HEX file (Ctrl-C cancels)`, or with a name
   `load: waiting for <name> (Ctrl-C cancels)` with the name between two DC4 (section 5.2), and
   then sends DC2. More than one parameter: `usage: load [name]`, and nothing else happens.
2. It reads the file from the receive queue, without echo and without line editing, one line at
   a time (into a static buffer of 76 bytes). Every non-empty line is answered with exactly one
   byte: ACK if the record was accepted (the end-of-file record included), NAK if it was
   rejected. The first rejected line ends the checking: its error is kept, and every later line
   is answered with NAK, unchecked, up to and including a line that reads `:00000001FF` (in
   either case). A line longer than 75 characters is rejected at its 76th character, and the
   rest of it is read and dropped up to its end.
3. Each time another 1024 bytes of data have been stored, it prints `.` (the only output while
   the file arrives).
4. After the end-of-file record without an error, it checks the image (section 4.3), copies it
   to `copy_base` (section 2.2), executes `fence.i`, marks the app loaded and prints the result.
5. Ctrl-C (`0x03`) at any point, also inside a line or after an error, cancels: no app is
   loaded. The result is `load cancelled`, or `load failed: <reason>` if a line had already been
   rejected (a file that is not Intel HEX, such as an ELF or a raw image, may hold the byte
   `0x03`; the first error is the more useful answer).
6. A sender that has no file for the request sends one line instead whose first character is
   `!`: the rest of that line is the reason (its printable characters, at most 159). The line is
   answered with NAK, and the result is `load failed: <reason>` (`load failed: the sender has
   no file` if the reason is empty); a Ctrl-C before its end cancels. The console bridge sends
   such a line for a name that it cannot resolve (section 5.3).
7. From the first character of the file on, a pause of 2000 ticks without input ends the load
   (a sender that stopped); before the first character there is no limit. Line ends before the
   first record (an empty line, the LF of a `load` typed with CR LF) do not start the limit.
8. The load then returns to the command line. The line editor's previous character is set to
   the last character the load read: if its last line ended with CR, a LF that follows (the end
   of a CR LF file) counts as the second half of that line end, as the line editor already does
   for CR LF, and produces no empty command line; after a file with LF line ends, a LF typed
   next is an Enter of its own.

Every result is printed on a line of its own (the line of dots, if any, is ended first) and is
exactly one of:

```text
loaded <name>: <bytes> bytes at 0x00060000, entry 0x<entry>, CRC32 0x<crc>
load failed: <reason>
load cancelled
```

with `<entry>` and `<crc>` as eight lowercase hexadecimal digits. After the timeout of item 7 the
reason is the first error if there was one, else `line <n>: no input for 2000 ticks (the file
stopped)`.

### 4.3 Errors

A reason names the first check that failed, in the order of the tables. The first three checks
of a line are made as its characters arrive, so the first offending character decides (a
character that fails two of them, such as a 76th character that is not a hexadecimal digit,
gives the reason of the earlier one); the others when the line is complete. `<n>` counts the
non-empty lines received so far, the current one included; addresses are eight lowercase
hexadecimal digits, record types two. In `address 0x<a> is outside the app slot`, `<a>` is the
record's first address: both ends of the slot are 64 KiB boundaries, which a record that passed
the check before cannot cross, so a record lies wholly inside the slot or wholly outside it. In
`unknown flags 0x<f>`, `<f>` holds only the unknown bits (`ulFlags` without bits 0 to 3). Every
reason in the table of section 9.5 was checked against a reference implementation of these
rules.

Checks of a line (the reason starts with `line <n>: `):

| Check | Reason after `line <n>: ` |
|---|---|
| the line starts with `:` | `a record starts with ':'` |
| every further character is a hexadecimal digit | `'<c>' is not a hexadecimal digit` (`<c>` printable) or `0x<hh> is not a hexadecimal digit` |
| at most 75 characters | `record too long (at most 32 data bytes)` |
| an even number of digits, at least 10 | `malformed record` |
| the digits match the record's length byte | `malformed record (it announces <ll> data bytes and holds <k>)` |
| the record's bytes add up to 0 modulo 256 | `checksum mismatch` |
| type 00, 01, 04 or 05 | `record type <tt> is not supported (only 00, 01, 04 and 05)` |
| the length and address fields of a type 01, 04 or 05 record | `malformed type <tt> record` |
| a data record does not cross a 64 KiB boundary | `record crosses a 64 KiB boundary` |
| every byte of a data record lies in the slot | `address 0x<a> is outside the app slot (0x00060000-0x0007ffff)` |
| a data record starts where the previous one ended | `address 0x<a>, expected 0x<e> (data records must be contiguous, from the slot base)` |

Checks of the image, after the end-of-file record:

| Check | Reason |
|---|---|
| at least 64 bytes received | `the file holds <n> bytes, less than a 64-byte header` |
| `ulMagic` | `bad magic 0x<m> (an app image starts with 0x50504148, "HAPP")` |
| `usAbi` | `ABI version <v> (this shell runs ABI version 1)` |
| `usHeaderSize` | `header size <s> (64 expected)` |
| `ulImageSize` equals the bytes received | `the header says <h> bytes, the file holds <n>` |
| `ulFlags` | `unknown flags 0x<f>` |
| `acName` | `bad name (1 to 15 letters, digits, '_' or '-', then NULs)` |
| `ulImageSize`, `ulBssSize` | `image and bss sizes must be multiples of 4` |
| `ulStackSize` | `stack of <s> bytes (at least 1024, a multiple of 16)` |
| `ulEntry` | `entry 0x<e> is not a word of the image after its header (0x00060040-0x<last>)` |
| the slot (section 2.2) | `<name> needs <t> bytes of the slot (image <i>, bss <b>, stack <s>, saved copy <c>); the slot has 131072` |
| a type 05 record | `the start address record says 0x<s>, the entry is 0x<e>` |
| CRC-32 | `CRC32 mismatch: the image has 0x<c>, its header says 0x<h>` |

`appimg.py info` (section 9.3) applies the same checks in the same order and prints the same
reasons, so the test files can be checked on the host as well.

## 5. Sending a file from the host

### 5.1 How the bridge types

`sim/console.cpp`, with the injector in `sim/top.sv`, types one character at a time into the
UART's receive pin as an 8N1 frame of 16 cycles per bit. It types the next character only after
the program has read the previous one from the UART's one-byte buffer, at least 512 cycles
later, and once the program's output has paused for 512 cycles: about 700 cycles or more per
character. In addition, once the program has shown its prompt, the characters after an Enter
(CR, or LF not after CR) wait until the program prints its next prompt, for at most 10 million
cycles (`kPromptWait`). Typed in this way, a file would stall at the end of every line, because
the loader prints no prompt while it receives a file. A transfer therefore needs an answer per
line that is not the prompt, and the bridge must know when the program wants a file.

### 5.2 Control bytes

Four bytes that the program sends to the bridge:

| Byte | Name | Sent by | Meaning |
|---|---|---|---|
| `0x11` | DC1 | `pxGetc()` of the API (section 6.2) | the app is about to wait for input (the receive queue is empty) |
| `0x12` | DC2 | `load` | waiting for a file; sent once, after the first line of `load` |
| `0x06` | ACK | `load` | a record line was accepted |
| `0x15` | NAK | `load` | a record line was rejected, or ignored after an error |

The shell sends them with `hal_putc()`, outside its line output, so they do not count as text.
Terminals do not display them; `session.py` drops them when it renders a transcript (they are
control characters); `console.log` and the logs keep them. No other program sends them.

`load <name>` also sends DC4 (`0x14`) before and after the name, inside its line
`load: waiting for <name> (Ctrl-C cancels)`, before the DC2: the name of the file wanted. DC4
is not text either and is shown or dropped as the four bytes above; the name between the two
is text. A DC4 pair that no DC2 follows lapses at the next prompt. DC4 does not end the wait
after an Enter (rule 1 of section 5.3), so input typed ahead does not reach the request.

### 5.3 File transfers

These rules apply in every mode, except where a mode is named.

1. **The wait after an Enter** ends at the program's next prompt or at the next of the four
   control bytes (still at the latest after `kPromptWait`). In the terminal and
   pseudo-terminal modes it also ends as soon as a Ctrl-C is among the characters waiting, so
   that Ctrl-C reaches a running app at once; the characters before it are typed first, at the
   usual pace. This part applies to every program, but it changes only the pacing of
   typed-ahead input that contains a Ctrl-C.
2. **File requests and uploads.** From the program's DC2 to its next prompt the bridge serves a
   file request. When it has a file for it (the file the request names, in every mode;
   `+console_upload` in the terminal and pseudo-terminal modes; the next `#<` entry of a
   script), the bridge reads the file at that moment, so that a rebuilt app is sent the next
   time, and types it (an upload); without one it types the input waiting (a paste, or `cat`
   into the pseudo-terminal) in the same way:
   * line by line: after the end (CR, or LF not after CR) of a line that is not empty it waits
     for ACK or NAK, at the latest `kPromptWait`, before it types the next character; every
     character is paced as before. An empty line is not answered (section 4.2), so it is not
     waited for;
   * the file ends, for the bridge, with the line `:00000001FF` (either case), after which the
     loader reads no more of it (section 4.2): nothing after that line is typed into the
     request. The rest of an upload is dropped, with a note unless it holds only blanks and line
     ends (an empty line after the end-of-file record would otherwise reach the command line
     as an empty command, and a record as an unknown one);
   * a Ctrl-C (`0x03`) inside an uploaded file is typed and ends the upload in the same way: the
     rest of the file is dropped (with a note), and the bridge types nothing until the prompt;
   * the upload also ends when the program shows its prompt before the file's end: the rest is
     dropped, with the note `the program ended the transfer`;
   * while an upload runs, characters typed in the terminal wait behind it, and they are not
     typed into the request: they wait for the prompt that ends it, also after the file's last
     byte, while the program still checks the image (otherwise input typed ahead, such as `run`
     after `load`, would be read as part of the file);
   * a Ctrl-C typed in the terminal (or the pseudo-terminal) during a file request is typed at
     once, ahead of the file and of the input waiting before it, and cancels the load: nothing
     more of the file is sent (with a note when an upload stops), and the bridge types nothing
     until the prompt (at the latest after `kPromptWait`);
   * after a request served by a paste (or `cat`), what is left of the file in the input
     waiting is dropped instead of being typed into the command line: lines that start with
     `:`, empty lines, and the rest of a line cut by a Ctrl-C, up to the first character of
     anything else, or until no input has arrived for `kPromptWait` cycles; a note gives the
     number of lines dropped. Input that follows the file, such as a command pasted after it,
     reaches the command line as usual;
   * a DC2 during a file request is ignored.
3. **`+console_upload_dir=<dir>`**: relative paths of `+console_upload`, of `#<` entries and of
   the files that requests name are relative to `<dir>`; by default to the simulator's working
   directory.

   **Named requests** (`load <name>`, section 5.2): the name is resolved as `UPLOAD=` is
   (section 9.6). A name ending in `.hex` is a file; `<march>/<name>` is the file
   `<march>/<name>.hex`; any other name is `<name>.hex` in the directory of
   **`+console_app_dir=<dir>`** (the loader's console runs pass `$(SDK_OUT)/rv32i`). The file is
   sent as an upload, ahead of `+console_upload`, a send request and the `#<` entries (which a
   script's typed line `load <name>` does not need). If there is no such file, the bridge types
   the line `!<reason>` and CR instead (section 4.2, item 6): `no app '<name>' (the apps:
   <names>)`, with the names of the `.hex` files in `+console_app_dir` in alphabetical order,
   for a name, or `cannot read <file>: <reason>` for a `.hex` file. In the terminal and
   pseudo-terminal modes the bridge lists the same names at start-up.
4. **`+console_upload=<file>`** (terminal and pseudo-terminal modes): the file sent whenever the
   program asks for one without naming it. Without it, in the terminal mode with a terminal as
   stdin, the bridge prints a hint when the program sends DC2 and no input is waiting (a paste
   typed ahead is typed as the file). In a scripted session it is not used (with a note): `#<`
   lines send files there.
5. The bridge reads the three new options itself, in `console_init()`, with
   `Verilated::commandArgsPlusMatch()` (Verilator 5.042); `sim/top.sv` and the DPI signature of
   `console_init()` stay unchanged.
6. Notes on stderr (wording informative):
   * `[console] sending <file> (<n> bytes)`
   * `[console] cannot read <file>: <reason>` (nothing is sent; Ctrl-C cancels the load)
   * `[console] the apps for 'load <name>': <names>` (at start-up, with `+console_app_dir`)
   * `[console] the program asks for a file: paste it, or press Ctrl-C and type 'load <name>'`
     (terminal mode without `+console_upload`; without `+console_app_dir`: `... paste it, or
     start the simulation with UPLOAD=<app>; Ctrl-C cancels`)
   * `[console] Ctrl-C: the upload stops after <k> of <n> bytes; the rest of the file is not
     sent`, printed when the Ctrl-C is typed, before the loader's `load cancelled`; the same
     with `the file holds a Ctrl-C (0x03)` and `the file goes on after its end-of-file record`
     in front
   * `[console] the program ended the transfer after <k> of <n> bytes`
   * `[console] dropped <n> line(s) of the file that the program did not read`
   * the script errors and notes of section 5.6
7. **A pseudo-terminal open to a second writer.** `screen` opens the device in exclusive mode
   (`TIOCEXCL`), in which no other program can open it: with `screen` 4.09 attached, opening the
   device for `cat` fails with `Device or resource busy`. In the
   pseudo-terminal mode with `+console_upload` or `+console_upload_dir` (which the loader's
   console runs always pass) the bridge therefore clears the exclusive mode (`TIOCNXCL`) every
   16 polls, 8192 cycles; without these options the device behaves as before. The control bytes
   are not text: they count neither for the prompt nor for the start of a line of the notes.
8. **Send requests** (pseudo-terminal mode with a link, `+console_pty_link=<path>`, and with
   `+console_upload` or `+console_upload_dir`). Every 16 polls the bridge also looks for the
   file `<path>.upload`, which holds the path of a file to send (relative paths as in rule 3).
   It removes the request and answers in `<path>.upload-answer` (written in one step):
   * `ok` if the program shows its prompt, nothing has been typed since, and no file request is
     being served. The bridge then types `load` and Enter, and at the program's DC2 sends the
     file as an upload (rule 2: the input waits behind it, Ctrl-C cancels it, the file ends at
     its end-of-file record);
   * `ok waiting` if a file request (a `load` typed by hand) waits for a file of which nothing
     has arrived yet: the bridge sends the file at once, as an upload;
   * `refused: the shell is not at its prompt (a command or an app is running)`, `refused: the
     command line is not empty (press Enter for a fresh prompt)` or `refused: a file is being
     sent` otherwise; nothing is typed.

   If the program shows its next prompt without having asked for the file, the request lapses
   with a note. The request and answer files are removed at the start and at the end of the
   simulation, with the link.

### 5.4 Terminal mode (the default)

```bash
make freertos-shell APP=loader
```

builds the shell, the simulator and the example apps, and starts the simulation; `load hello`
typed in the terminal then receives the file of `hello` (rule 3). With `UPLOAD=hello`, the
simulation is started with `+console_upload=<build>/test/freertos/sdk/rv32i/hello.hex`, and
every `load` without a name receives that file. `UPLOAD` takes the forms of rule 3, an app name
(its RV32I build), `<march>/<name>` (another build, for example `rv32im_zba/compute`) or the
path of a `.hex` file (section 9.6).

Without `UPLOAD=`, the file can be pasted into the terminal after `load`: the bridge reads the
paste at once and types it at the pace of rule 2, one line per answer. Ctrl-C cancels, also in
the middle of the file (rule 2); what is left of the file is then dropped from the input
waiting (rule 2), and a command pasted after the file still runs.

### 5.5 Pseudo-terminal mode (`PTY=1`)

```bash
make freertos-shell APP=loader PTY=1          # terminal 1: the simulation
screen build/test/freertos/loader/pty          # terminal 2: the shell's console
make freertos-send UPLOAD=hello                # terminal 3: 'load' and the file, at the prompt
```

`load hello` typed in terminal 2 works as in the terminal mode, without terminal 3;
`make freertos-send` also builds the app if needed.

`make freertos-send` builds the app's file if needed and writes a send request (rule 8) next
to the session's link, `build/test/freertos/loader/pty.upload`, with the file's absolute path.
It waits up to 30 seconds for the answer: on `ok` it prints
`send: 'load' and <file> (<n> bytes) -> <link>` and exits with status 0; on a refusal it prints
`freertos-send: not sent: <reason>` and fails. The bridge itself types `load` and sends the
file, so the transfer behaves as with `UPLOAD=`: input typed meanwhile waits for the prompt,
and Ctrl-C cancels it without leaving the rest of the file on the command line. The messages
appear in the terminal program. If no loader session is running in this mode, the target says
so and fails: it writes the request only when a simulator started with that link
(`+console_pty_link=<path>`) is running, since a link left behind by a killed simulator may
point to a device that another terminal uses now.

`(printf 'load\r'; cat <file>) > build/test/freertos/loader/pty` works as well, also while
`screen` is attached (rule 7). It is a paste: nothing checks that the shell is at its prompt,
and the bridge paces the file by rules 1 and 2 (`load` produces DC2, which ends the wait after
its Enter, and each line waits for the answer to the previous one). `UPLOAD=` also works with
`PTY=1`, as in the terminal mode. (Paths under `build/` are under `$HADES_BUILD_DIR` when it is
set.)

### 5.6 Scripted sessions

Two new kinds of lines in a session script (`+console_script`):

* `#< <file>`: the file is sent when the program next sends DC2 (not needed after a typed line
  `load <name>`, whose file the bridge finds by its name, rule 3).
* `#: <text>`: the text is typed, followed by Enter unless it ends in `\c`, when the program
  next sends DC1 or DC2. Escapes as in typed lines (`\r \n \t \e \\ \xHH`).

Both belong to the typed line before them. They are delivered in order, each one after the
previous entry has been typed completely; the next ordinary line is typed after the prompt that
answers the typed line, as before. An entry not yet delivered when that prompt appears is
dropped with the note `[console] <script>:<n>: not delivered: the program showed its prompt
first`. A `#<` file that cannot be read is an error at start-up, like a bad escape:
`[console] <script>:<n>: cannot read <file>: <reason>`, exit status 2; so is a `#<` or `#:`
line before the first typed line. One blank after `#<` or `#:` is not part of the file name or
the text. When the program sends DC2 and the typed line has no entry left, the bridge notes
`[console] <script>:<n>: the program asks for a file, but no "#<" line of this typed line is
left` (the session then ends at its cycle limit).

For `session.py` these lines start with `#` and are therefore comments: they are not typed lines
and expect no prompt, and the expectations that follow them belong to the typed line before
them. `session.py run --sim-arg <argument>` (repeatable) is how `freertos.mk` passes
`APP_CONSOLE_ARGS` to the simulator, and `--name <name>` names the logs
(`<name>-<cpu>.log` and `.uart`; default `session`).

```text
load
#< rv32i/upper.hex
#? ^loaded upper: \d+ bytes at 0x00060000, entry 0x[0-9a-f]{8}, CRC32 0x[0-9a-f]{8}$
run
#: hello world
#:
#? ^HELLO WORLD$
#? ^app: upper exited with code 1 after \d+ cycles$
```

### 5.7 Pacing guarantees and speed

* The UART's one-byte buffer never overflows: the bridge types a character only after the
  program has read the previous one.
* The receive queue never holds more than one line of a file: the bridge types the next line
  only after the answer to the previous one, and a record line has at most 77 characters with
  CR LF, while the loader configuration's queue holds 128 (`SHELL_RX_BUFFER`). A paste or `cat`
  has the same guarantee through rule 2. A `!<reason>` line, which may be longer, is the last
  line of its request, and the loader stores each of its characters as it arrives, without
  work at the end of a line. The test sessions check that `uart` reports `dropped: 0` and
  `overruns: 0`.
* Speed, estimated from the pacing rules: a record of 16 data bytes is a line of 45
  characters, at about 700 to 900 cycles per character: about 2.5 million cycles per KiB of
  image, one to two seconds of simulation. The documentation states measured figures.

## 6. The API and the entry convention

### 6.1 Entry convention

The app task's function (in the shell) calls `ulEntry` as a `HadesAppEntry_t`:

* `a0` = the API table (in the shell's memory, filled in by the shell; the app must not change
  it), `a1` = `argc`, `a2` = `argv`;
* `argv[0]` is the app's name, `argv[1]` to `argv[argc - 1]` are the words after `run` (at most
  8, separated by blanks, no quoting), `argv[argc]` is `NULL`; the strings are in the shell's
  memory, writable, and valid until the app ends;
* `sp` is 16-byte aligned, on the app's stack; `ra` returns into the shell: returning ends the
  app with `a0` as its exit code;
* `gp` and `tp` hold the shell's values;
* machine mode, interrupts enabled;
* the image has just been restored from the saved copy and `fence.i` executed; `.bss` has not
  been zeroed (`crt0.S` does that).

### 6.2 The API table

| Member | Meaning |
|---|---|
| `ulAbi` | 1 |
| `ulSize` | `sizeof( HadesApi_t )` in the shell (section 3.7) |
| `ulCpu` | what the CPU executes, from the shell's start-up probe: `HADES_APP_CPU_M`, `_ZBA`, `_ZICNTR`, `_ZBB`, `_ZBS`, `_ZICOND` (the last three probed only in the loader's build, with `clz`, `bset` and `czero.eqz`) |
| `ulTickHz` | 1000 (`configTICK_RATE_HZ`) |
| `ulCyclesPerTick` | clock cycles per tick (`TICK=`, 10000 by default) |
| `pxPutc( c )` | one character |
| `pxPuts( s )` | a string; no newline is added (as the shell's `shell_puts()`) |
| `pxWrite( s, n )` | `n` characters |
| `pxPrintf( fmt, ... )` | the shell's formatter (`format.c`): `%d %i %u %x %X %s %c %%`, the flags `-` and `0`, a width (digits or `*`), a precision for `%s`, `l` and `z` (32 bits) and `ll` (64 bits); at most 159 characters per call (the rest is cut); returns the number of characters printed |
| `pxSnprintf( b, n, fmt, ... )` | the same into a buffer (`shell_snprintf()`) |
| `pxGetc( ms )` | the next input byte (0 to 255), or -1 if none arrives within `ms` milliseconds; `ms` < 0 waits for ever, 0 does not wait. Bytes arrive as typed: no echo, no line editing; CR, LF and Backspace arrive as such; Ctrl-C never arrives (it stops the app; so does one typed before the app started, which `run` finds in the receive queue). It sends DC1 before it waits: when no byte is waiting and `ms` is not 0. |
| `pxDelayMs( ms )` | blocks for `ms` milliseconds (ticks at the nominal 1 kHz; one tick is `TICK` cycles); 0 yields |
| `pxTicks()` | the tick count since the scheduler started |
| `pxExit( code )` | ends the app with this exit code; does not return |

Output goes through the shell's `shell_write()`: a `\n` is sent as `\r\n`, and each line is sent
as one unit, so that it never interleaves with the output of other tasks. `shell_write()` sends
a line with the scheduler suspended, where an exception cannot be contained (section 7.5), so
`pxPuts`, `pxWrite` and `pxPrintf` read the app's text (or format it) first, with the scheduler
running: a bad pointer passed to them faults there and is reported `in the shell`. The functions
may be called only from the app's own task (an app has no other).

### 6.3 Rules for apps

An app runs in machine mode with full access to the hardware. The shell relies on the
following, and cannot enforce any of it.

An app may:

* use RV32I, and M, Zba, Zbb and Zbs if it was built for them (`load` records them in `ulFlags`,
  and `run` refuses an app that needs an extension the CPU lacks), and Zicond where `app_cpu()` has
  `HADES_APP_CPU_ZICOND`; read `mcycle`, `mcycleh`, `minstret`
  and `minstreth` (both CPUs), and the Zicntr counters `cycle`, `time` and `instret` where
  `app_cpu()` has `HADES_APP_CPU_ZICNTR` (HaDes-V+ only);
* write into its own memory, code included, and execute `fence.i` before running what it wrote;
* use the memory of section 2.2 between `__app_heap_start` and `__app_heap_end`;
* link `libgcc` and the freestanding parts of newlib-nano (`memcpy`, `memset`, `strlen` and the
  like); no `stdio`, no `malloc`;
* read the switches and buttons and write the 7-segment display or the VGA frame buffer, with
  the addresses of `std/include/peripherals.h`, which is on the SDK's include path; the LEDs as
  well, but the shell's `blink` task rewrites the whole LED register every 500 ticks (LED 0
  toggles, the others go off).

An app must not:

* write outside the slot (the shell, the kernel, the interrupt stack);
* change `gp` or `tp`: the FreeRTOS port does not save them, and the shell's code and interrupt
  handlers use `gp`;
* write `mstatus`, `mie`, `mtvec`, `mepc`, `mcause`, `mscratch`, the timer, `mcycle` or
  `minstret` (the shell's run-time statistics), or keep interrupts disabled (Ctrl-C and the
  tick need them);
* read the UART's receive register (it belongs to the shell's interrupt handler); writing the
  transmit register directly works but bypasses the line output, so use the API;
* write the test register at `0x00480000` (it ends the simulation);
* print the shell's prompt `hades> ` or the control bytes of section 5.2: the console bridge and
  the session checks rely on them;
* call the shell's functions by address: only the API is stable.

`ecall` from an app only makes FreeRTOS switch tasks; `ebreak` stops it like any exception.

## 7. Running an app

### 7.1 `run [args...]`

The `run` command, in the console task:

1. no app loaded: `error: no app loaded (try 'load hello')`;
2. more than 8 arguments: `error: at most 8 arguments`;
3. the header's `ulFlags` names an extension that the start-up probe did not find:
   `error: <name> was built for <isa>, but this CPU has no <missing>`, with `<isa>` as in
   section 8.6 and `<missing>` the extensions it lacks, in the order M, Zba, Zbb, Zbs, joined as
   `M`, `M and no Zba`, `M, no Zba, no Zbb and no Zbs`;
4. the CRC-32 of the saved copy differs from the header's:
   `error: the saved copy of <name> is damaged (CRC32 0x<c> instead of 0x<h>); load it again`,
   and the app is unloaded;
5. copies the saved copy to the slot base and executes `fence.i`;
6. builds `argv` from the arguments;
7. clears the console task's notification bits and the fault record, notes `mcycle`, marks the
   app running (from now on the receive interrupt intercepts Ctrl-C), sets the bit CTRLC itself
   if the receive queue holds a Ctrl-C (one typed before this point, for example right after
   the Enter of `run`; the queue is searched in a critical section and left as it was), and
   creates the app task: `xTaskCreateStatic()` with the shell's app task function, the name
   `app`, the stack `[copy_base - ulStackSize, copy_base)`, priority 1 and a `StaticTask_t` in
   the shell;
8. waits for a task notification (`xTaskNotifyWait()`, `portMAX_DELAY`) with one of the bits
   EXIT, FAULT or CTRLC;
9. marks the app no longer running, records a stack overflow if the four check words at the
   bottom of the app's stack have changed (section 7.6), deletes the app task (`vTaskDelete()`:
   the task is not running, since the console task is, so FreeRTOS removes it at once and its
   TCB and stack can be used again by the next run), discards the receive queue's contents
   (input the app did not read, also input typed ahead before a Ctrl-C), and prints the report
   of section 7.3 on a line of its own;
10. the prompt follows, as after any command.

### 7.2 The app task

Priority 1, below the console task (2) and `blink` (3), above the idle task (0). The console
task, and with it Ctrl-C, therefore always preempts the app; an app that computes for ever does
not starve the shell (only the idle task waits, which is harmless here). The app task's function
(shell code) calls the entry and then `loader_app_exit()` with the returned value. While an app
runs, the console task reads no commands: the terminal belongs to the app.

The app task never deletes itself. A task that deletes itself is freed later, by the idle task,
and its static TCB could not safely be used again by a `run` typed right after. Instead, every
ending wakes the console task, which deletes the app task:

* `loader_app_exit( code )` (used by `pxExit` and after the entry returns) records the code,
  calls `xTaskNotify( console, EXIT, eSetBits )` and then `vTaskSuspend( NULL )`;
* `loader_app_faulted()` (section 7.5) does the same with FAULT;
* Ctrl-C (section 7.4) sets CTRLC from the receive interrupt.

When several bits are set, FAULT is reported before EXIT, and EXIT before CTRLC. A stack
overflow recorded in the run (section 7.6) is reported instead of EXIT or CTRLC, and appended to
the report of an exception.

### 7.3 Reports

| Ending | Report |
|---|---|
| return from `main()`, or `app_exit( code )` | `app: <name> exited with code <code> after <c> cycles` |
| Ctrl-C | `app: <name> stopped by Ctrl-C after <c> cycles` |
| an exception | `app: <name> stopped by an exception after <c> cycles: <cause> (mcause <m>) at 0x<pc><where><mtval><ra><overflow>` |
| a stack overflow (also one found only when the app ended, section 7.6) | `app: <name> stopped by a stack overflow after <c> cycles (its stack is <s> bytes)` |

* `<c>`: `mcycle` at the report minus `mcycle` before the task was created, in decimal;
  `<code>`: signed decimal; `<pc>`: eight lowercase hexadecimal digits.
* `<cause>` for `mcause` 0 to 7: `instruction address misaligned`, `instruction access fault`,
  `illegal instruction`, `breakpoint`, `load address misaligned`, `load access fault`,
  `store address misaligned`, `store access fault`; any other value: `exception`.
* `<where>`: ` in <name>` if `mepc` lies in the app slot (the image, or code the app wrote into
  its memory), ` in the shell` if it lies in the shell's region (a shell function called by the
  app, for example with a bad pointer), nothing otherwise (for example at `0x00000000`).
* `<mtval>`: `, mtval 0x<v>` if `mtval` is not 0, nothing otherwise.
* `<ra>`: for `mcause` 0 and 1 (a fetch from a bad address, such as a call through a null
  pointer, where `mepc` is the target and says nothing about the caller), `, ra 0x<ra> in
  <name>` if the app's `ra` (word 2 of the frame) lies in the slot; nothing otherwise.
* `<overflow>`: `, after a stack overflow (its stack is <s> bytes)` if the check words of the
  app's stack had changed when the trampoline ran (section 7.5); nothing otherwise.

### 7.4 Ctrl-C

While an app runs, the receive interrupt (`console.c`) does not queue a received `0x03` but calls
`xTaskNotifyFromISR( console, CTRLC, eSetBits, ... )` and `portYIELD_FROM_ISR()`. The console
task then deletes the app task wherever it is. A Ctrl-C received before `run` marked the app
running is in the receive queue; `run` finds it there (step 7 of section 7.1), so it stops an
app that never reads input as well. No lock can be held at that moment: the shell's
only serialisation is the suspended scheduler (`shell_write()`) and critical sections, and the
console task cannot run during either; FreeRTOS releases its queue locks before it resumes the
scheduler; apps get no mutexes and no heap. Ctrl-C cannot stop an app that keeps interrupts
disabled; Ctrl-] still ends the simulation.

### 7.5 Exception containment

The port's trap handler (`third_party/freertos/.../portable/GCC/RISC-V/portASM.S`,
`portContext.h`) saves the running task's context on that task's stack, writes the stack
pointer to `pxCurrentTCB->pxTopOfStack` (the first member of the TCB), and, for a synchronous
exception other than ECALL, calls `freertos_risc_v_application_exception_handler( mcause,
mepc + 4 )` on the interrupt stack. When the handler returns, the port restores the context of
`pxCurrentTCB` and executes `mret`. The context frame (RV32, no FPU, chip extension
`RISCV_MTIME_CLINT_no_extensions`, 31 words):

| Word | Contents |
|---|---|
| 0 | the resume address: `mepc + 4` after an exception; `mret` jumps here |
| 1 | `mstatus` at the trap (MIE = 0, MPIE = the MIE before the trap, MPP = M) |
| 2 | `x1` (`ra`) |
| 3-29 | `x5` to `x31` |
| 30 | the task's `xCriticalNesting` |

On restore, `sp` becomes the frame's address plus 124; `gp` and `tp` are not in the frame.

In the loader configuration the shell's handler (`commands.c`) calls `loader_exception( mcause,
mepc )` after its CPU-probe case and before `hal_fail()`. The exception is contained only if all
of these hold:

1. an app task exists and is the current task (`xTaskGetCurrentTaskHandle()`);
2. no fault has been recorded in this run (a fault in the trampoline itself is not contained);
3. the scheduler runs (`xTaskGetSchedulerState() == taskSCHEDULER_RUNNING`): no
   `vTaskSuspendAll()` is in force;
4. the frame lies in the slot (`HADES_APP_SLOT_BASE <= frame` and `frame + 124 <=
   HADES_APP_SLOT_END`); an exception inside an interrupt handler would have put its frame on
   the interrupt stack;
5. word 30 of the frame is 0: no critical section is open.

Then it records the fault and redirects the saved `mepc`:

```c
int loader_exception( uint32_t ulCause, uint32_t ulPc )
{
    TaskHandle_t xTask = xTaskGetCurrentTaskHandle();
    uint32_t * pulFrame;

    if( ( xAppTask == NULL ) || ( xTask != xAppTask ) || ( xFault.ulKind != FAULT_NONE ) ||
        ( xTaskGetSchedulerState() != taskSCHEDULER_RUNNING ) )
    {
        return 0;
    }

    pulFrame = *( uint32_t ** ) xTask;                         /* pxTopOfStack */

    if( ( ( uintptr_t ) pulFrame < HADES_APP_SLOT_BASE ) ||
        ( ( uintptr_t ) pulFrame + 31u * 4u > HADES_APP_SLOT_END ) || ( pulFrame[ 30 ] != 0u ) )
    {
        return 0;
    }

    xFault.ulKind = FAULT_EXCEPTION;
    xFault.ulCause = ulCause;
    xFault.ulPc = ulPc;
    __asm volatile ( "csrr %0, mtval" : "=r" ( xFault.ulTval ) );
    pulFrame[ 0 ] = ( uint32_t ) ( uintptr_t ) loader_trampoline;   /* the saved mepc */
    pulFrame[ 1 ] = ( pulFrame[ 1 ] & ~0x80u ) | 0x1800u;          /* MPP = M, MPIE = 0 */
    return 1;
}
```

The port's restore then resumes the app task in `loader_trampoline` with interrupts disabled.
The trampoline is a short assembly stub: it sets `gp` to the shell's value again (without linker
relaxation, as `start.S`), loads `sp` with the top of the app's stack (`copy_base` of this run;
neither the app's `sp` nor its `gp` is trusted) and jumps to `loader_app_faulted()`. That
function first writes `0xa5a5a5a5` into the four words at the start of the app's stack, which
FreeRTOS checks at every switch away from the task (section 7.6): a stack that overflowed has
lost them, and the task switch that the next call causes would otherwise report the same
overflow again. Then it notifies the console task (FAULT); the critical section of that call
enables interrupts again, and the task suspends itself (section 7.2). Interrupts stay disabled
until then because an interrupt taken at the trampoline's first instruction could switch tasks
while `sp` is still the app's and the check words are still lost: FreeRTOS would find the
overflow a second time and end the run.
If any condition fails, the handler continues as in the shell:
`FRTOS-RESULT: FAIL unexpected exception (mcause, mepc)` ends the run. The CPU probe of the
shell's start-up keeps working, since it runs before any app exists.

### 7.6 Stack overflow

With `configCHECK_FOR_STACK_OVERFLOW` = 2, `vTaskSwitchContext()` checks the task it switches
out: its saved `sp` below the start of its stack, or the first 16 bytes of the stack changed. It
then calls `vApplicationStackOverflowHook()`, inside the trap handler, with that task's context
saved. `hades_hal.c` defines the hook as weak (section 2.5) and the loader defines its own: for
the app task, under conditions 2 and 4 of section 7.5, it records a stack overflow and
redirects the frame exactly as in section 7.5 (the trampoline's path then restores the check
words); for any other task, and when a condition fails, it calls
`hal_fail( "stack overflow", pcTaskName, ... )` as `hades_hal.c` does in the shell. Condition 5 does
not apply here: FreeRTOS switches tasks only at points where its data is consistent, and the
switch that finds an overflow is often the yield inside the critical section of
`xTaskResumeAll()` (when a task became ready while `shell_write()` had the scheduler
suspended), with word 30 at 1. The hook sets word 30 to 0 with the redirection, so that the
trampoline does not start inside a critical section; it changes no other word of the frame. (A
test app that overflows its stack and then prints for ever was stopped this way in five of six
runs.) The app's stack lies above its own data, so an overflow first damages the app.

FreeRTOS checks only when it switches tasks. An app that overflows its stack without a task
switch and then returns (or is stopped by Ctrl-C) is found at the switch that this ending
causes, after the EXIT (or CTRLC) bit has been sent: the hook records the overflow all the
same, and the report is that of a stack overflow (section 7.2), not of the exit. `run` also
compares the check words itself after the app has ended (step 9 of section 7.1), and the
trampoline before it restores them (section 7.5). An app that overflows its stack by more than
the free part of the slot, its data and its image without a task switch writes into the shell's
interrupt stack below the slot and can crash the system. The `stack` mode of the crash example
yields at every level of its recursion, so that the check finds the overflow at once; the
`deep` mode overflows without a switch and returns.

### 7.7 Re-running and re-loading

* Every `run` checks the saved copy, restores the image from it, and `crt0.S` zeroes `.bss`:
  every run starts from the image as it was loaded, whatever the previous run did.
* `load` replaces the app. From the moment it starts no app is loaded; a failed or cancelled
  load leaves none.
* After a contained exception or a Ctrl-C the shell carries on, and `run` works again, unless
  the app damaged its saved copy (step 4 of section 7.1).
* A new simulation starts with no app.

## 8. Shell commands and their output

Only the loader configuration has these changes. Columns and labels follow the shell's existing
output.

### 8.1 `help`

Three lines between `echo` and `halt`, in the shell's format (the command padded to 19
characters):

```text
load [name]        Receive an app (Intel HEX) into the app slot
run [args...]      Run the loaded app (Ctrl-C stops it)
app                The loaded app: name, size, entry, CRC32
```

`app` takes no parameters (FreeRTOS+CLI answers others with `Incorrect command
parameter(s)`); `load` takes at most one (section 4.2); `run` takes any number (the loader
limits them to 8).

### 8.2 Banner

One line after the `config:` line:

```text
  apps: 'load <name>' (for example 'load hello'), then 'run [args]'
```

The names of the apps are known to the console bridge, not to the shell: the bridge lists them
at start-up (section 5.3, rule 3).

### 8.3 `mem`

One line after the interrupt-stack line (`mem`'s `RAM:` line describes the shell's 128 KiB
region):

```text
apps:      131072-byte app slot at 0x00060000 ('app' shows what it holds)
```

### 8.4 `load`

Section 4.2. For example:

```text
hades> load hello
load: waiting for hello (Ctrl-C cancels)
.
loaded hello: 1048 bytes at 0x00060000, entry 0x00060040, CRC32 0x5b1e2f07
hades> load helo
load: waiting for helo (Ctrl-C cancels)
load failed: no app 'helo' (the apps: bitmanip compute crash hello selfmod upper)
hades> load
load: waiting for an Intel HEX file (Ctrl-C cancels)
```

### 8.5 `run`

Sections 7.1 and 7.3. For example:

```text
hades> run 1 2 3
...the app's output...
app: hello exited with code 3 after 61002 cycles
```

### 8.6 `app`

```text
name:      tiny (ABI 1)
image:     72 bytes at 0x00060000, entry 0x00060040, CRC32 0xa0537c91
isa:       rv32i
memory:    image 72 + bss 0 + stack 1024 + saved copy 80 = 1176 of 131072 bytes
```

`isa:` is `rv32i`, followed by `m` if the image needs M, `_zba` if it needs Zba, `_zbb` if it
needs Zbb and `_zbs` if it needs Zbs (as the `-march` names: `rv32i`, `rv32im`, `rv32i_zba`,
`rv32im_zba`, `rv32im_zba_zbb_zbs`). With no app loaded the output is
`no app loaded`.

### 8.7 Unchanged

Every other command and message, including `version` (which shows `RAM 256 KiB`, the simulated
RAM) and the line editor.

## 9. Host side: the SDK

### 9.1 Layout

```text
test/freertos/sdk/
  hades_app.h            the ABI (section 3.1)
  crt0.S                 image header and start-up code (section 3.5)
  app.ld                 the app linker script (section 3.3)
  appimg.py              the image tool (section 9.3)
  sdk.mk                 the make rules (section 9.6), included at the end of test/freertos/freertos.mk
  README.md              an overview of the SDK, with links to the guide and to this document
  apps/<name>/           one directory per app; every .c and .S file in it is compiled
    hello/hello.c
    compute/compute.c, compute/model.py
    crash/crash.c
    selfmod/selfmod.c
    upper/upper.c
```

The build output goes to `$(BUILD_DIR)/test/freertos/sdk/` (`SDK_OUT`):
`<march>/<name>.elf`, `.bin` (the final image, with name, flags and CRC filled in), `.hex`,
`.dis` (`objdump -d` of the ELF, whose header lacks name, flags and CRC) and `.map`, with the
objects under `<march>/obj/<name>/`; and the test files under `testfiles/`.

### 9.2 Building an app

```bash
make freertos-app NAME=<name> [MARCH=rv32i|rv32im|rv32i_zba|rv32im_zba|rv32im_zba_zbb_zbs] [OPT=-O2|-Os|-O0]
```

builds `test/freertos/sdk/apps/<name>/` (default `rv32i`, `-O2`) and prints one line, for
example (`<name>`: 1 to 15 letters, digits, `_` or `-`, since it is stored in the image header;
it is checked, and the directory's existence too, before anything is built):

```text
app hello [rv32i -O2]: image 1048 bytes, bss 16, stack 4096, CRC32 0x5b1e2f07 -> <build>/test/freertos/sdk/rv32i/hello.hex
```

* Compiling: `-march=<march> -mabi=ilp32 <opt> -g -ffunction-sections -fdata-sections -Wall
  -I test/freertos/sdk -I std/include` (`std/include/peripherals.h`: the addresses of the
  devices).
* Linking: `-nostdlib -nostartfiles -T test/freertos/sdk/app.ld -Wl,--gc-sections
  -Wl,--no-warn-rwx-segments -Wl,-Map=<name>.map` with `crt0.S` first, then the app's objects,
  then `-lc_nano -lgcc`.
* Then `objcopy -O binary` and `appimg.py hex`.
* An app is rebuilt when one of its sources, an SDK file or its flags change, in the manner of
  `freertos.mk`'s `flags.txt`.
* The build is quiet, as that of `make freertos`: its commands go to `$(SDK_OUT)/build.log`
  (`VERBOSE=1` shows them). When nothing had to be rebuilt, the line printed is
  `  (app <name> [<march> <opt>] up to date: <file>)` (indented by two blanks, as the
  corresponding line of `freertos.mk`).

### 9.3 `appimg.py`

```bash
python3 test/freertos/sdk/appimg.py hex --name <name> --march <march> [--opt=<level>] <app.bin> <app.hex>
python3 test/freertos/sdk/appimg.py info <file.hex|file.bin>
python3 test/freertos/sdk/appimg.py testfiles <directory>
```

(`--opt` only labels the line that `hex` prints, `[rv32i -O2]`; the `=` form is needed because
the value starts with `-`.)

* `hex` checks the raw image (`objcopy -O binary`): at least 68 bytes and a multiple of 4,
  magic, ABI, header size, `ulImageSize` equal to the file's size, the entry, the stack, the
  slot. It fills in `ulFlags` from `--march` (`rv32i` 0, `rv32im` M, `rv32i_zba` Zba,
  `rv32im_zba` M and Zba, `rv32im_zba_zbb_zbs` M, Zba, Zbb and Zbs; any other `-march` is an error), `acName` from `--name` (1 to 15 of
  `A-Z a-z 0-9 _ -`) and `ulCrc32`, rewrites `app.bin` and writes `app.hex`: a type 04 record
  with the upper half of the slot base, data records of 16 bytes (the last one shorter), a
  type 04 record before the first data record of every further 64 KiB, a type 05 record with
  the entry, and the end-of-file record; uppercase digits, CR LF line ends, no empty lines.
  It prints the line of section 9.2.
* `info` reads a file as the loader does (section 4) and prints its header, or the reason the
  loader would give; exit status 0 only if the loader would accept the file. It prints the line
  `load` would print (`loaded ...`, `load failed: <reason>` or `load cancelled`) and, for an
  accepted file, the four lines of `app` (section 8.6). A `.bin` is read as the HEX file that
  `hex` would write from it.
* `testfiles` writes the files of section 9.5 into the directory.

### 9.4 Example apps

All are built for RV32I, so that they also run on the golden CPU; `compute` is also built for
`rv32im_zba`, and `bitmanip` for `rv32im_zba_zbb_zbs`. Every app prints whole lines (ending in `\n`) and returns an exit code.

| App | Behaviour and output |
|---|---|
| `hello` | Prints `Hello, <argv[1]>!` (with no argument `Hello, HaDes-V+!`), then one line `argv[<i>] = <argv[i]>` per argument from `argv[0]` on; exit code `argc - 1`. |
| `compute` | Arithmetic that uses M and Zba when built for them, checked against constants. With a 32-bit linear congruential generator (`s = s * 1664525 + 1013904223`, `s` = 1 at the start) it fills two 16 x 16 matrices of `int32_t` with `(int32_t) ( s >> 16 ) - 32768`, multiplies them (products and sums in `uint32_t`, so that they wrap without undefined behaviour; the array indexing gives `sh2add` with Zba: each element of the product is computed by a function of its own that receives the row and the column as numbers, since GCC 12 turns indexing inside the loops into stepped pointers), reads the product's elements as `int32_t`, and forms four sums (again in `uint32_t`): the trace of the product; the sum of `C[i][j] / (j + 1)` (C division, rounding toward zero); the sum of `C[i][j] % 7`; the sum of the high halves of the unsigned 64-bit products `A[i][j] * B[j][i]` (`mulhu`). The expected values are constants in `compute.c`, computed by `model.py` (Python, the same arithmetic modelled independently; the comment names it). Prints `compute: trace <t>, quotients <q>, remainders <r>, mulhu <h>: PASS (<c> cycles)` with `<c>` from `app_cycles()`, exit code 0; on a mismatch the same line ends in `FAIL`, followed by the line `compute: expected trace <t>, quotients <q>, remainders <r>, mulhu <h>`, exit code 1. The four sums are printed as unsigned decimal numbers. |
| `bitmanip` | The bit-manipulation extensions. On 64 words from a xorshift32 generator (seed `0x2545F491`) it runs four sections, each timed with `app_cycles()` and checked against constants in `bitmanip.c` computed by `model.py`, which takes every instruction's result from `test/ext/ref.py`: `zbb` (population count, integer log2, trailing zeros, clamps with `min`/`max`/`minu`/`maxu`, packed 8/16-bit samples, `andn`/`orn`/`xnor` masks, a hash with rotates), `bytes` (`rev8` on big-endian fields and string lengths with `orc.b`, by inline assembly when built with Zbb, in C otherwise), `zbs` (a sieve of Eratosthenes in a 4096-bit bitmap with `bset`/`bclr`/`bext`/`binv`, then flags at fixed bit numbers with the immediate forms) and `zicond` (select, clamp and conditional add through `std/include/zicond.h`; in C in the RV32I build; skipped, with a line that says so, in a Zbb build on a CPU without `HADES_APP_CPU_ZICOND`). Prints `bitmanip: <section> <values>: PASS (<c> cycles[, <note>])` per section and `bitmanip: <n> of <m> sections passed`; exit code: the number of failed sections, each of which prints `FAIL` and the expected values. |
| `crash` | `crash [mode]` prints `crash: <mode>` and then: `illegal` (default) executes the word 0; `ebreak`; `misaligned` loads a word from an address 2 bytes past a word (with an `lw` in inline assembly: GCC splits a C access at an address it knows to be misaligned into two halfword loads, which do not trap); `load` loads from `0x00300000` (no device there); `store` stores to `0x00300000`; `null` calls a null function pointer; `stack` recurses with 256 bytes of locals per level, filling them and calling `app_delay_ms( 0 )` at every level; `deep` recurses in the same way 32 levels deep (about 9 KiB on its 4 KiB stack) without yielding, then returns 0 and prints nothing more; `loop` calls `app_getc( 1 )` once, which signals the bridge with DC1, and then spins for ever with interrupts enabled; `spin` spins for ever without reading input. Any other argument: `crash: usage: crash [illegal\|ebreak\|misaligned\|load\|store\|null\|stack\|deep\|loop\|spin]`, exit code 2. (`brk` and `test/asm/trap.s` provoke the same exceptions the same way.) |
| `selfmod` | Writes `li a0, 42` and `ret` into a word-aligned buffer in `.bss`, executes `fence.i` and calls it; then rewrites the same buffer in place to return `0x12345678` (`lui`, `addi`, `ret`), executes `fence.i` and calls it again: the case that an instruction cache must handle, since the old instructions at the same addresses have just been executed. Encodings as in `test/freertos/brk/main.c`. Prints one line per call, `selfmod: <instructions> -> <value>` (`<value>` in decimal and in hexadecimal, `42 (0x0000002a)`), then `selfmod: PASS` (exit code 0) or `selfmod: FAIL` (exit code 1). |
| `upper` | Prints `upper: type lines; an empty line ends`, then the prompt `> `; reads with `app_getc( -1 )`, echoes printable characters, handles Backspace and DEL, and at CR or LF (CR LF counts once) prints the line in upper case on a line of its own and the next prompt. An empty line ends it; exit code: the number of lines converted. |

### 9.5 Test files

`appimg.py testfiles` writes into `$(SDK_OUT)/testfiles/`, every file derived from `tiny.hex`
(section 3.6, its lines numbered 1 to 8), with record checksums and the CRC-32 recomputed unless
the row says otherwise:

| File | Change to `tiny.hex` | `load` answers |
|---|---|---|
| `tiny.hex` | none | `loaded tiny: 72 bytes at 0x00060000, entry 0x00060040, CRC32 0xa0537c91` |
| `bad-colon.hex` | line 2 without its `:` | `load failed: line 2: a record starts with ':'` |
| `bad-char.hex` | the first data digit of line 4 replaced by `G` | `load failed: line 4: 'G' is not a hexadecimal digit` |
| `bad-checksum.hex` | the checksum of line 3 plus one | `load failed: line 3: checksum mismatch` |
| `bad-length.hex` | the length byte of line 6 set to `09` | `load failed: line 6: malformed record (it announces 9 data bytes and holds 8)` |
| `bad-long.hex` | line 6 extended to 33 data bytes (zeros) | `load failed: line 6: record too long (at most 32 data bytes)` |
| `bad-type.hex` | line 1 replaced by the type 02 record `:020000020006F6` | `load failed: line 1: record type 02 is not supported (only 00, 01, 04 and 05)` |
| `bad-address.hex` | line 1 replaced by `:020000040005F5` | `load failed: line 2: address 0x00050000 is outside the app slot (0x00060000-0x0007ffff)` |
| `bad-gap.hex` | line 4 removed | `load failed: line 4: address 0x00060030, expected 0x00060020 (data records must be contiguous, from the slot base)` |
| `bad-magic.hex` | magic `XAPP` | `load failed: bad magic 0x50504158 (an app image starts with 0x50504148, "HAPP")` |
| `bad-abi.hex` | ABI version 2 | `load failed: ABI version 2 (this shell runs ABI version 1)` |
| `bad-imagesize.hex` | `ulImageSize` 76 | `load failed: the header says 76 bytes, the file holds 72` |
| `bad-flags.hex` | `ulFlags` `0x00000080` | `load failed: unknown flags 0x00000080` |
| `bad-name.hex` | name `ti ny` | `load failed: bad name (1 to 15 letters, digits, '_' or '-', then NULs)` |
| `bad-entry.hex` | entry `0x00060048` | `load failed: entry 0x00060048 is not a word of the image after its header (0x00060040-0x00060047)` |
| `bad-size.hex` | stack `0x00020000` | `load failed: tiny needs 131224 bytes of the slot (image 72, bss 0, stack 131072, saved copy 80); the slot has 131072` |
| `bad-start.hex` | line 7 replaced by `:0400000500060044AD` | `load failed: the start address record says 0x00060044, the entry is 0x00060040` |
| `bad-crc.hex` | the code word `li a0, 7` changed to `li a0, 8` (`0x00800513`); line 6's checksum recomputed, `ulCrc32` kept | `load failed: CRC32 mismatch: the image has 0xb5c16588, its header says 0xa0537c91` |
| `cancel.hex` | lines 1 to 3, then the byte `0x03` (Ctrl-C), nothing after it | `load cancelled` |
| `cancel-mid.hex` | lines 1 to 3, the first 9 characters of line 4, `0x03`, then the rest of the file | `load cancelled` |
| `bad-cancel.hex` | lines 1 to 3 of `bad-colon.hex`, `0x03`, then lines 4 to 8 | `load failed: line 2: a record starts with ':'` |
| `ok-blank.hex` | an empty line after line 3, and two after line 8 | `loaded tiny: ...` (as `tiny.hex`) |
| `after-eof.hex` | lines 2 and 3 again, and an empty line, after line 8 | `loaded tiny: ...` (as `tiny.hex`) |

The last four check the console bridge as well: nothing after the Ctrl-C or the end-of-file
record reaches the command line (section 5.3, rule 2).

### 9.6 Make targets and `UPLOAD`

| Target | What it does |
|---|---|
| `make freertos-app NAME=<name> [MARCH=] [OPT=]` | builds one app (section 9.2) |
| `make freertos-apps` | builds the examples (RV32I, `compute` also for `rv32im_zba`, `bitmanip` also for `rv32im_zba_zbb_zbs`) at `-O2`, and the test files; ignores `MARCH` and `OPT`; a prerequisite of the loader's console runs (`APP_CONSOLE_DEPS`) |
| `make freertos-send UPLOAD=<app>` | asks the running `make freertos-shell APP=loader PTY=1` session to type `load` and send the app's file (a send request, section 5.5); fails when it is refused |

`UPLOAD=<name>` means `$(SDK_OUT)/rv32i/<name>.hex`, built from `test/freertos/sdk/apps/<name>/`
if needed; `UPLOAD=<march>/<name>` the build for that `-march`; a value ending in `.hex` is a file,
used as it is. `load <name>` names files in the same way (section 5.3, rule 3), but the bridge
builds nothing: it sends the file as it is, and relative `.hex` paths are relative to
`$(SDK_OUT)`. The app named by `UPLOAD` is rebuilt when it is out of date, at the optimisation
level of its last build (recorded in its `flags.txt`), or `-O2` if it has none: `UPLOAD=` sends
the build that `make freertos-app` made, whatever its `OPT`. `freertos-apps` builds the examples
at `-O2`. An unknown app, or a name that breaks the rule of section 9.2, stops `make` before
anything is built; so does `UPLOAD=` with `make freertos-shell` but without `APP=loader`. `sdk.mk` defines `SDK_DIR`, `SDK_OUT`, these targets, and the make function that
turns an `UPLOAD` value into an absolute path (with the goal that builds it), which `freertos.mk`
uses for `+console_upload`. The names are fixed: `$(call sdk_upload_file,<value>)` is the
absolute path of the file, and `$(call sdk_upload_goal,<value>)` the make goal that builds it
(empty for a `.hex` file given as it is). `freertos.mk` adds that goal to the quiet build of
`freertos-shell` and passes `+console_upload=$(call sdk_upload_file,<value>)`; both are used
only when `UPLOAD` is given on the command line (`FRTOS_UPLOAD`). For an app the goal is the
file's absolute path, `$(SDK_OUT)/<march>/<name>.hex`: such a goal builds that app (`sdk.mk` defines the rules of an app only for the builds that are goals of the make run, as
`freertos.mk` reads only the `app.mk` of the program it builds). When `freertos-apps` is a goal of the same make run (a
console run of the loader with `UPLOAD=`), the app goals are built by its sub-make, so that two
makes never build the same app at once (`make -j`).

## 10. Tests

Every check below is run by its make target and ends in a verdict line; simulators started by a
check end by themselves (scripted sessions) or are ended by the test (`tty_test.py`), and no
simulator is left running afterwards.

### 10.1 The loader session: `test/freertos/loader/session.txt`

Run by `make freertos-shell-test APP=loader` (HaDes-V+), with `CPU=golden`, and compared by
`make freertos-shell-compare APP=loader`. `make freertos-loader-test [CPU=golden]` runs it and
the session of section 10.2 on one CPU, with one verdict line for both (`LOADER TEST: PASS`);
`make freertos-loader-compare` runs both sessions on both CPUs and compares the transcripts of
this one (`LOADER COMPARE: PASS`). The logs of section 10.2 are then `session-ext-<cpu>.log`
and `.uart` (`session.py run --name session-ext`). It uses RV32I builds only. Its steps, in this order,
each with expectations for the exact messages of sections 4, 7 and 8:

1. The banner: the shell's lines and the `apps:` line. `help` lists `load`, `run [args...]` and
   `app` between `echo` and `halt`. `mem` shows the `apps:` line.
2. Before any load: `app` gives `no app loaded`; `run` gives `error: no app loaded (try 'load
   hello')`.
3. `load` with `#< testfiles/tiny.hex`: the exact `loaded tiny: ... CRC32 0xa0537c91` line;
   `app` gives the four lines of section 8.6 exactly; `run` gives `app: tiny exited with code 7
   after \d+ cycles`.
4. `hello`: `load`; `app` (`name: hello (ABI 1)`, `isa: rv32i`); `run` (`Hello, HaDes-V+!`,
   code 0); `run world 42` (`Hello, world!`, `argv[2] = 42`, code 2);
   `run 1 2 3 4 5 6 7 8 9` gives `error: at most 8 arguments`.
5. `compute`: `load`; `run` twice, both `compute: ...: PASS (\d+ cycles)` and code 0 (the second
   run proves that the image is restored).
6. `selfmod`: `load`; `run`: `selfmod: PASS`, code 0.
7. `upper`: `load`; `run` with `#: hello world`, `#: HaDes-V+` and an empty `#:`: the echoed
   lines, `HELLO WORLD`, `HADES-V+`, code 2.
8. `crash`: `load`; then `run` (illegal instruction, `mcause 2`, `in crash`), and after it
   `tasks` (`3 tasks`: the app task is gone) and `uptime`; `run ebreak` (3), `run misaligned`
   (4), `run load` (5), `run store` (7), `run null` (`instruction access fault (mcause 1) at
   0x00000000, ra 0x<ra> in crash`), `run stack` (`stopped by a stack overflow`), `run deep`
   (`stopped by a stack overflow`, not `exited`), `run loop` with `#: \x03\c`
   (`stopped by Ctrl-C`), the typed line `run spin\r\x03\c` (`stopped by Ctrl-C`: the Ctrl-C
   right after the Enter); `tasks` again (`3 tasks`); then another app loads and runs: `tiny`,
   code 7.
9. A load replaces a loaded app even when it fails: `bad-checksum.hex`, `bad-address.hex`,
   `bad-size.hex`, `bad-magic.hex` and `bad-crc.hex`, each after a successful load of
   `tiny.hex`, give their reasons, and `run` then gives the error of step 2 and runs nothing
   (no `app:` report), although each file differs from `tiny` in one detail and the lines before
   the error were stored; `app` gives `no app loaded` after the first and the last.
10. Every other test file of section 9.5, one `load` each, with its exact reason; `cancel.hex`
    and `cancel-mid.hex` give `load cancelled`, `bad-cancel.hex` its error; `app` after them:
    `no app loaded`. `ok-blank.hex` and `after-eof.hex` give `loaded tiny` without an extra
    prompt or `Command not recognised`, and `run` gives code 7.
11. Reload: `load` `hello` again; `run again`: `Hello, again!`.
12. Load by name, without `#<` lines: `load selfmod` (`load: waiting for selfmod (Ctrl-C
    cancels)`, `loaded selfmod`) and `run` (`selfmod: PASS`); `load hello` and `run Ada`
    (`Hello, Ada!`, code 1); `load hello world` gives `usage: load [name]`, and `app` still
    shows `hello`; `load testfiles/tiny.hex` gives `loaded tiny`; `load nosuchapp` gives
    `load failed: no app 'nosuchapp' (the apps: ...)`, listing at least the five examples, and
    `run` then gives the error of step 2.
13. `uart`: `dropped: 0`, `overruns: 0`.
14. `halt`: `halted`, `FRTOS-RESULT: PASS`.

`session.py compare` must report SAME: the transcript contains no line that depends on the CPU
except numbers, which it normalises (and the `cpu:` lines of the shell's own commands, which it
excludes). The expectations of steps 3 to 14 do not depend on the CPU, and the golden CPU
raises the exceptions of step 8 as HaDes-V+ does (none of its known deviations, listed in
`test/trapsweep/README.md`, concerns them).

### 10.2 ISA extensions: `test/freertos/loader/session-ext.txt`

```bash
make freertos-shell-test APP=loader SCRIPT=test/freertos/loader/session-ext.txt
make freertos-shell-test APP=loader SCRIPT=test/freertos/loader/session-ext.txt CPU=golden
```

`load` with `#< rv32im_zba/compute.hex`; `app` shows `isa: rv32im_zba`; `run`: on HaDes-V+
`compute: ...: PASS` and code 0 (`#?dut`); on the golden CPU `error: compute was built for
rv32im_zba, but this CPU has no M and no Zba` (`#?golden`); then `load rv32im_zba/compute`
(the same build by name): `loaded compute`, and `app` shows `isa: rv32im_zba`. `version` shows
the CPU lines (`cpu: Zbb yes, Zbs yes, Zicond yes (for apps)` on HaDes-V+, `no` on the golden
CPU). `load rv32i/bitmanip`, `run`: every value of its four sections, on both CPUs.
`load rv32im_zba_zbb_zbs/bitmanip`, `run`: the same values on HaDes-V+; on the golden CPU
`error: bitmanip was built for rv32im_zba_zbb_zbs, but this CPU has no M, no Zba, no Zbb and no
Zbs`. Not compared between the CPUs.

### 10.3 The interactive check: `test/freertos/loader/tty_test.py`

Run by `make freertos-shell-tty-test APP=loader`, in the manner of `test/freertos/shell/tty_test.py`
(the simulator on a pseudo-terminal of its own, keys typed with pauses, the terminal settings
restored after every case). Arguments: `--sim`, `--dir`, `--upload-dir`, `--only`. Cases:

| Case | What it checks |
|---|---|
| `upload` | terminal mode with `+console_upload=<a scratch copy of hello.hex>`: `load`, `run` and `app` typed ahead at once give `loaded hello`, code 0 and the app's name (the input waits for the prompt that ends the upload); the scratch file is replaced by `tiny.hex`; `load` gives `loaded tiny` (the file is read at every request); `run` gives code 7 |
| `name` | terminal mode with `+console_app_dir=<SDK_OUT>/rv32i` and `+console_upload=testfiles/tiny.hex`: the start-up note lists at least the five examples; `load hello` and `run Ada` typed ahead at once give `loaded hello` and `Hello, Ada!` (the name decides over `+console_upload`, and the input waits for the prompt); `load crash` gives `loaded crash`; `load` without a name gives `loaded tiny`; `load nosuchapp` gives `load failed: no app 'nosuchapp' (the apps: ...)` with the names of the start-up note; `app`: `no app loaded` |
| `paste` | terminal mode without `+console_upload`: `load`, then all of `hello.hex` written to the terminal at once, followed by an empty line, two records and the command `app`: `loaded hello`; the bridge drops the empty line and the records (one prompt, no `Command not recognised`, the note `dropped 2 line(s)`), and `app` runs; `uart` shows `dropped: 0` |
| `pty-send` | `+console_pty`: a client attached in exclusive mode, as in `case_pty` of `shell/tty_test.py`; a send request for `hello.hex` (rule 8 of section 5.3, written as `make freertos-send` writes it) is answered `ok`; the client sees `loaded hello`, types `run`, sees code 0; while `run loop` of `crash` runs, a request is refused (`not at its prompt`) and nothing is typed into the app; after `load` typed by the client, a request is answered `ok waiting` and gives `loaded hello`; `load selfmod` typed by the client gives `loaded selfmod`, and `run` `selfmod: PASS` |
| `pty-cat` | `+console_pty`, a client in exclusive mode; a second writer writes `load`, CR and `compute.hex` into the device, as `cat` does; the client types Ctrl-C while the file arrives: `load cancelled`, the note `dropped <n> line(s)`, and nothing more on the device within 3 seconds; `app`: `no app loaded` |
| `input` | `run` of `upper`; `abc` typed with pauses, Enter, `xyz`, Enter, Enter: `ABC`, `XYZ`, code 2; every answer within 10 seconds of its Enter (the DC1 rule, not the 10-million-cycle limit) |
| `ctrl-c` | `run loop` of `crash`; a second later Ctrl-C: `stopped by Ctrl-C` within 10 seconds; `tasks`: `3 tasks` |
| `ctrl-c-ahead` | `run spin` of `crash`, Enter and Ctrl-C written at once: `stopped by Ctrl-C` within 10 seconds |
| `ctrl-c-load` | `+console_upload=<compute.hex>`: `load`, Ctrl-C a second later: the note `Ctrl-C: the upload stops after <k> of <n> bytes`, then `load cancelled`; no `Command not recognised` within the next 3 seconds (the rest of the file was dropped); `app`: `no app loaded` |

Each case ends with Ctrl-] or `halt` and exit status 0. It prints one line per case and
`LOADER TTY TEST: PASS` or `LOADER TTY TEST: FAIL`.

### 10.4 Regressions: the default stays as it is

1. **Images.** For every program of `make freertos-list` except `loader`, at its defaults, and
   for `shell` also at `-O2` and `-O0`, `init.mem` is byte-identical to the one built from
   commit 03386fd. The base tree is extracted with
   `git archive 03386fd | tar -x -C <directory>` (no change to any git state) and built with a
   `BUILD_DIR` of its own; the two files are compared with `cmp`.
2. **The shell's sessions**: `make freertos-shell-test` (PASS, 120/120 expectations) and with
   `CPU=golden` (PASS, 121/121), each with the same `cycles=` as at 03386fd;
   `make freertos-shell-compare`: SAME, 40 blocks, 158 lines.
3. `make freertos-shell-tty-test`: `TTY TEST: PASS`.
4. `make freertos-check-rebuild`: `REBUILD CHECK: PASS`; `make freertos APP=minimal` and
   `make freertos-compare APP=stress`: PASS, with the cycle counts of 03386fd.
5. The shell's own script on the loader configuration:
   `make freertos-shell-test APP=loader SCRIPT=test/freertos/shell/session.txt` passes (the
   shell's commands behave the same in the loader build).
6. Further runs of the loader's sessions: `BPRED=3` (code written at run time with the branch
   predictor on), `OPT=-O2`, `OPT=-O0`, `TICK=50000`; and `make freertos-stress`.

## 11. Out of scope

* The board: its RAM is full. A board version would need a smaller shell or more RAM, and a host
  tool that answers the line protocol over a real serial port (send a line, wait for ACK or
  NAK); the protocol is designed for one.
* Memory protection (it needs U-mode and PMP, which the core does not implement), several apps
  at once, apps in the background, relocatable images, a file system, quoting in `run`'s
  arguments.
