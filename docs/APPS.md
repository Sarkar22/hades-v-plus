[HaDes-V+](../README.md) · [Docs](README.md) · [Building](BUILDING.md) · [FreeRTOS](FREERTOS.md) · [Shell](SHELL.md) · **Apps** · [Architecture](ARCHITECTURE.md) · [Extensions](EXTENSIONS.md) · [Verification](VERIFICATION.md)

# Building, Loading and Running Apps

The interactive shell ([SHELL.md](SHELL.md)) has a second configuration, `loader`, which runs
programs that you compile on the host: an *app* is built with the project's GCC and the SDK in `test/freertos/sdk/`, sent to
the running shell over the UART as an Intel HEX file, stored in a reserved RAM area, the
*app slot*, and run as a FreeRTOS task. The shell stays alive: Ctrl-C stops a running app,
and an app that raises an exception is stopped and reported while the shell carries on.

It is opt-in and runs in simulation only. The board's 32 KiB of RAM are full with the shell,
so the loader configuration runs on a simulated RAM of 256 KiB: the first 128 KiB hold the
shell, the other 128 KiB the app slot. `make freertos-shell` without `APP=loader`, and every
other program, are not affected. The complete specification (image format, load protocol,
console pacing, run semantics, test plan) is
[test/freertos/loader/SPEC.md](../test/freertos/loader/SPEC.md).

The tools, the one-time setup and the settings of the FreeRTOS targets are described in
[FREERTOS.md](FREERTOS.md). Every command below can be copied as it stands. The
outputs shown are from runs of this version of the repository that are not recorded under
[results/](../results/README.md).

**Contents**

1. [Start it and run an example](#start-it-and-run-an-example)
2. [The example apps](#the-example-apps)
3. [The commands](#the-commands)
4. [Write and build an app](#write-and-build-an-app)
5. [The app API](#the-app-api)
6. [Send the file: terminal, pseudo-terminal, script](#send-the-file-terminal-pseudo-terminal-script)
7. [Memory layout](#memory-layout)
8. [What is contained, and what is not](#what-is-contained-and-what-is-not)
9. [The tests](#the-tests)
10. [Settings](#settings)
11. [Troubleshooting](#troubleshooting)

## Start it and run an example

```bash
make freertos-shell APP=loader
```

This builds the shell with the loader, the 256 KiB console simulator and the example apps,
and starts the simulation as for the shell ([SHELL.md](SHELL.md#start-it)). Type `load` and the name of an app, then run the
app with `run` and its arguments (a session on HaDes-V+):

```text
[console] the apps for 'load <name>': compute crash hello selfmod upper
...
HaDes-V+ shell on FreeRTOS V11.1.0+ with FreeRTOS+CLI
  config: tick=10000cyc preempt=1 slice=1 heap_4 isa=rv32i opt=-Os ram=256K bpred=0
  apps: 'load <name>' (for example 'load hello'), then 'run [args]'
Type 'help' for the list of commands.
hades> load hello
load: waiting for hello (Ctrl-C cancels)
[console] sending .../test/freertos/sdk/rv32i/hello.hex (1017 bytes)
loaded hello: 340 bytes at 0x00060000, entry 0x00060040, CRC32 0xbccb2e01
hades> run Ada
Hello, Ada!
argv[0] = hello
argv[1] = Ada
app: hello exited with code 1 after 36656 cycles
hades> app
name:      hello (ABI 1)
image:     340 bytes at 0x00060000, entry 0x00060040, CRC32 0xbccb2e01
isa:       rv32i
memory:    image 340 + bss 4 + stack 4096 + saved copy 352 = 4792 of 131072 bytes
hades> halt
halted
```

The simulator lists the apps when it starts and sends the file of the app that `load` names:
the name of an app (its RV32I build), `<march>/<name>` for another build, for example
`load rv32im_zba/compute`, or the path of a `.hex` file (absolute, or relative to the SDK's
build directory, `${HADES_BUILD_DIR:-build}/test/freertos/sdk/`). A name it does not know
loads nothing, and the answer lists the apps:

```text
hades> load helo
load: waiting for helo (Ctrl-C cancels)
load failed: no app 'helo' (the apps: compute crash hello selfmod upper)
```

The file is read at every `load`, so an app rebuilt in another terminal while the simulation
runs is sent the next time. `run` before a successful `load` answers
`error: no app loaded (try 'load hello')`. Every other command of the shell
([SHELL.md](SHELL.md#the-commands)) works as before.

`load` without a name takes the file that arrives. `make freertos-shell APP=loader
UPLOAD=hello` names the file that the simulator sends to every such `load`; `UPLOAD` takes
the same forms as `load` (a relative `.hex` path is relative to the directory where `make`
runs).
Without `UPLOAD=`, paste the file
([Send the file](#send-the-file-terminal-pseudo-terminal-script)).

## The example apps

The example apps, in `test/freertos/sdk/apps/`, are built for RV32I (`compute` also for
`rv32im_zba`):

| App | What it does |
|---|---|
| `hello` | Prints `Hello, <argv[1]>!` and its arguments; the exit code is the number of arguments. |
| `compute` | Matrix arithmetic with multiplication, division and scaled indexing (M and Zba when built for them), checked against constants computed by a Python model (`model.py`); prints `PASS` and its cycle count. |
| `selfmod` | Writes instructions into its memory, executes `fence.i` and runs them; then rewrites the same words and runs them again. |
| `upper` | Reads lines from the terminal and prints them in upper case; an empty line ends it. |
| `crash` | Ends in the way its argument names: `illegal` (the default), `ebreak`, `misaligned`, `load`, `store` (access faults), `null` (a call through a null pointer), `stack` (endless recursion), `deep` (a stack overflow without a task switch, then a normal return), `loop` (spins until Ctrl-C, after waiting for input once), `spin` (spins without ever reading input). |

## The commands

| Command | What it does |
|---|---|
| `load [name]` | Unloads the current app, clears the slot, prints `load: waiting for an Intel HEX file (Ctrl-C cancels)` (with a name: `load: waiting for <name> (Ctrl-C cancels)`, and the simulator sends that app's file) and receives the file; more than one word gives `usage: load [name]` and changes nothing. Every record is checked (checksum, address inside the slot, contiguous from the slot base) before its bytes are written; at the end the image is checked (magic `HAPP`, ABI version, sizes, entry, the room it needs in the slot, CRC-32), saved and made executable (`fence.i`). One line reports the result: `loaded <name>: ...`, `load failed: <reason>` or `load cancelled`. After a failed or cancelled load no app is loaded, so nothing of an older image can be run. A Ctrl-C after a rejected line gives that line's error rather than `load cancelled`. A `.` is printed for every KiB of image stored in the slot. |
| `run [args...]` | Restores the image from its saved copy (so every run starts from the image as loaded), then runs it as the task `app` with `argv[0]` = the app's name and up to 8 arguments (separated by blanks; no quoting). While it runs, the terminal belongs to the app. Ctrl-C stops it, also one typed right after the Enter of `run`, and discards what was typed and not yet read by the app. Afterwards one line reports how it ended (below). |
| `app` | The loaded app: name, size, entry, CRC-32, instruction set, and how it uses the slot; `no app loaded` if there is none. |

The report after `run`:

| Ending | Report |
|---|---|
| `main()` returns, or `app_exit()` | `app: hello exited with code 2 after 40363 cycles` |
| Ctrl-C | `app: crash stopped by Ctrl-C after 30707 cycles` |
| An exception | `app: crash stopped by an exception after 30512 cycles: illegal instruction (mcause 2) at 0x000601b4 in crash` |
| A stack overflow | `app: crash stopped by a stack overflow after 69483 cycles (its stack is 4096 bytes)` |

The exception report names the cause and the address of the faulting instruction, followed
by `in <app>` when the address lies in the app slot and `in the shell` when it lies in the
shell (an API function called with a bad pointer). After a jump to a bad address (a call
through a null pointer) that address says nothing about the caller, so the report adds the
app's return address: `at 0x00000000, ra 0x0006026c in crash`. A stack overflow is reported
whenever FreeRTOS finds it, also when it finds it only as the app ends (an app that overflowed
without a task switch and then returned, or was stopped by Ctrl-C). `run` refuses an app built for an
extension that the CPU does not execute: on the golden CPU, `error: compute was built for
rv32im_zba, but this CPU has no M and no Zba`.

Some of the reasons `load` gives (all of them are listed in SPEC.md, section 4.3):

```text
load failed: line 3: checksum mismatch
load failed: line 2: address 0x00050000 is outside the app slot (0x00060000-0x0007ffff)
load failed: bad magic 0x50504158 (an app image starts with 0x50504148, "HAPP")
load failed: tiny needs 131224 bytes of the slot (image 72, bss 0, stack 131072, saved copy 80); the slot has 131072
load failed: CRC32 mismatch: the image has 0xb5c16588, its header says 0xa0537c91
load failed: no app 'helo' (the apps: compute crash hello selfmod upper)
```

`python3 test/freertos/sdk/appimg.py info <file.hex>` applies the same checks on the host
and prints the line `load` would print.

## Write and build an app

An app is a directory under `test/freertos/sdk/apps/`; every `.c` and `.S` file in it is
compiled. The directory's name is the app's name: 1 to 15 letters, digits, `_` or `-`, since
it is stored in the image header (`make` checks it before it compiles anything). Its `main()`
receives the arguments of `run`, and its return value is the exit code:

```c
/* test/freertos/sdk/apps/myapp/myapp.c */
#include "hades_app.h"

int main( int argc, char ** argv )
{
    uint32_t ulSum = 0;

    for( int i = 1; i < argc; i++ )
    {
        ulSum += ( uint32_t ) argv[ i ][ 0 ];
    }

    app_printf( "%s: the first characters of the arguments add up to %u\n", argv[ 0 ], ulSum );
    return argc - 1;
}
```

```bash
make freertos-app NAME=myapp                          # rv32i, -O2
make freertos-app NAME=myapp MARCH=rv32im_zba OPT=-Os # M and Zba: HaDes-V+ only
make freertos-shell APP=loader                        # then: load myapp
```

`make freertos-app` prints one line with the sizes, the CRC-32 and the file it wrote:

```text
app myapp [rv32i -O2]: image 292 bytes, bss 4, stack 4096, CRC32 0x6496e1cd -> .../test/freertos/sdk/rv32i/myapp.hex
```

It compiles with `-ffunction-sections -fdata-sections`, links with the SDK's start-up code
(`crt0.S`, which writes the 64-byte image header and clears `.bss`) and linker script
(`app.ld`, which places the app at the slot base, `0x00060000`), and writes the image and its
HEX file. `make freertos-apps` builds every example and the loader's test files, at `-O2`.
`load myapp` sends the file as `make freertos-app` wrote it (run `make freertos-app` again,
also while the simulation runs, and the next `load` sends the new build), and
`load rv32im_zba/myapp` the other build. `UPLOAD=myapp` (with `freertos-shell` or
`freertos-send`) rebuilds the app when its sources have changed, at the optimisation level of
its last build, so it sends the build that `make freertos-app` made. Then:

```text
hades> load myapp
load: waiting for myapp (Ctrl-C cancels)
[console] sending .../test/freertos/sdk/rv32i/myapp.hex (882 bytes)
loaded myapp: 292 bytes at 0x00060000, entry 0x00060040, CRC32 0x6496e1cd
hades> run Ada Bob
myapp: the first characters of the arguments add up to 131
app: myapp exited with code 2 after 39369 cycles
```

## The app API

The API, declared in `test/freertos/sdk/hades_app.h`:

| Function | Meaning |
|---|---|
| `app_printf( fmt, ... )`, `app_snprintf( buf, n, fmt, ... )` | The shell's formatter: `%d %i %u %x %X %s %c %%`, flags `-` and `0`, a width, a precision for `%s`, `l`, `z` and `ll`; no floating point. `app_printf` prints at most 159 characters per call (the rest is cut); `app_snprintf` stores at most `n - 1` and a NUL. Both return the number of characters. |
| `app_puts( s )`, `app_putc( c )`, `app_write( s, n )` | Text output; `\n` is sent as `\r\n`, and a line never interleaves with the shell's output. `app_puts` adds no newline. |
| `app_getc( ms )` | The next byte typed (0 to 255; no echo, no line editing), or -1 if none arrives within `ms` milliseconds; `ms` < 0 waits for ever, 0 does not wait. Ctrl-C never arrives: it stops the app. |
| `app_delay_ms( ms )`, `app_ticks()` | Block for `ms` milliseconds (one RTOS tick each; 0 yields); the tick count since the start. |
| `app_exit( code )` | End the app with this exit code, as returning it from `main()` does; does not return. |
| `app_cpu()`, `app_cycles()` | What the CPU executes (`HADES_APP_CPU_M`, `_ZBA`, `_ZICNTR`); `mcycle` as 64 bits. |
| `HADES_APP_STACK_SIZE( n );` | At file scope: the app's stack in bytes (default 4096; at least 1024 and a multiple of 16, as a plain integer). |
| `__app_heap_start`, `__app_heap_end` | Declared as `char` arrays: the app's free memory, between its `.bss` and its stack. |

`hades_app.h` documents each of them. The devices are reached directly, with the addresses of
`std/include/peripherals.h`, which is on the SDK's include path. In the simulation the switches
read the value of `SEED` (`SEED=a5` gives `0x00a5`):

```c
#include "hades_app.h"
#include "peripherals.h"                       /* std/include: the addresses of the devices */

int main( int argc, char ** argv )
{
    ( void ) argc;
    ( void ) argv;
    app_printf( "switches: 0x%04x\n", ( unsigned ) *SWITCHES_ADDRESS );
    return 0;
}
```

An app may use RV32I, and M and Zba if it was built for them; the freestanding parts of
newlib-nano (`memcpy`, `strlen` and the like) and libgcc, but no `stdio` and no `malloc`; the
memory between `__app_heap_start` and `__app_heap_end`; the switches, buttons, 7-segment
display and VGA frame buffer; and the LEDs, but the shell's `blink` task rewrites the whole LED
register every 500 ticks. It must not write outside the slot, change `gp`, `tp`, `mstatus`,
`mie`, `mtvec` or the timer, keep interrupts disabled, read the UART directly, or print the
prompt `hades> `. The shell cannot enforce any of this (see the limits below). The full rules
are in SPEC.md, section 6.3.

## Send the file: terminal, pseudo-terminal, script

The shell asks for a file when you type `load`, and the simulator's console bridge
(`sim/console.cpp`) sends it one line at a time: the next line only after the shell has
acknowledged the previous one, so no character is lost however long the file is. A name
after `load` tells the bridge which file to send, in every mode. There is no key or escape
sequence to start an upload: `load` starts it, from whichever side.

| Mode | How the file is sent |
|---|---|
| Terminal (`make freertos-shell APP=loader`) | `load <name>`: the app's file. `load` alone: with `UPLOAD=<app>`, that app's file; without it, paste the contents of the `.hex` file into the terminal. |
| Pseudo-terminal (`PTY=1`) | `load <name>` typed in the terminal program, as in the terminal mode. Or, in another terminal: `make freertos-send UPLOAD=<app>`. It builds the app if needed and asks the simulator to type `load` and send the file, which it does only while the shell waits at its prompt with nothing typed (after a `load` typed by hand, it sends the file to that `load`). `UPLOAD=` on the `freertos-shell` command line works as well. |
| Scripted session (`freertos-shell-test`) | A typed line `load <name>`, or a line `#< <file>` after the typed `load` line, which sends that file, relative to the SDK's build directory (`#< rv32i/hello.hex`); `#: <text>` types a line into a running app. |

A session in the pseudo-terminal mode takes three terminals:

```bash
make freertos-shell APP=loader PTY=1                   # 1: the simulation
screen ${HADES_BUILD_DIR:-build}/test/freertos/loader/pty   # 2: the shell's console (press Enter)
make freertos-send UPLOAD=hello                        # 3: at the prompt of terminal 2
```

```text
send: 'load' and .../test/freertos/sdk/rv32i/hello.hex (1017 bytes) -> .../test/freertos/loader/pty
```

The shell's answer, `loaded hello: ...`, appears in `screen`; type `run` there. (`load hello`
typed in `screen` does the same without the third terminal.) When the shell is busy (a
command or an app is running) or something is typed on its command line, nothing is sent, and
`make freertos-send` fails with the reason:

```text
freertos-send: not sent: the shell is not at its prompt (a command or an app is running)
```

If no loader session runs in this mode, it says so and sends nothing.
`(printf 'load\r'; cat <file>) > ${HADES_BUILD_DIR:-build}/test/freertos/loader/pty` also works,
also while `screen` holds the device, but it is a paste: nothing checks that the shell waits at
its prompt.

Ctrl-C during a `load` cancels it (`load cancelled`). With `UPLOAD=` or `make freertos-send`
the rest of the file is not sent, and the simulator notes where it stopped
(`[console] Ctrl-C: the upload stops after 2062 of 4551 bytes; ...`). After a pasted file, or
one written with `cat`, the simulator drops what is left of the file (its lines start with
`:`) instead of typing it into the command line, and notes how many lines it dropped; a
command pasted after the file still runs. Nothing that follows the file's end-of-file record
(`:00000001FF`) reaches the command line either.

Sending takes about one million clock cycles per KiB of HEX file, which is about three times
the size of the image, so about 3 million cycles (2 seconds) per KiB of image: the 340-byte
`hello` image (a 1017-byte file) loads in 1.7 million cycles, the 1600-byte RV32I `compute`
image (4551 bytes) in 4.7 million cycles (measured with `uptime` before and after `load`).

## Memory layout

| Address | Size | Contents |
|---|---|---|
| `0x00040000` | 128 KiB | The shell: program, data, FreeRTOS heap (8 KiB), and in its top 1 KiB the interrupt stack. It is linked for 128 KiB with the unchanged `hades-freertos.ld`. |
| `0x00060000` | 128 KiB | The app slot. |
| `0x00080000` | | End of the simulated RAM (256 KiB). |

Inside the slot, from the bottom: the image (a 64-byte header, then code, read-only data and
data), the app's `.bss`, free memory for the app, the app task's stack, and at the top the
saved copy of the image that `run` restores, after checking its CRC-32, before every run. The
app's stack grows down towards its own data, so an overflow damages the app first; `app`
shows how much of the slot an app needs.

## What is contained, and what is not

HaDes-V+ runs in machine mode only and has no memory protection, so an app has the same
rights as the shell: it can overwrite the kernel, the shell and every CSR. Containment is
best effort:

* **Contained:** an exception raised while the app's task runs, in the app's code or in a
  shell function it called (illegal instruction, `ebreak`, misaligned or faulting loads and
  stores, a jump to an address without memory); a stack overflow that FreeRTOS detects at a
  task switch; Ctrl-C, which stops an app wherever it is, also in an endless loop. The shell
  reports the ending, deletes the app's task, and carries on; `run` works again.
* **Not contained:** an app that writes outside the slot, changes `mtvec`, `mstatus`, `mie`
  or the timer, or disables interrupts and loops can corrupt or hang the whole system. So can
  an app whose stack pointer lies outside the slot when an exception or an interrupt occurs
  (the processor's state is then saved outside the slot), and a jump into the shell's code. A
  stack overflow that runs past the slot without a task switch writes into the shell's
  interrupt stack. In these cases the simulation usually ends with `FRTOS-RESULT: FAIL`;
  Ctrl-] always ends it.
* One app at a time, in the foreground.
* The golden CPU runs RV32I apps only, as everywhere in this repository; `run` refuses the
  others there.
* `mtval` reads 0 on both CPUs, so the report shows no faulting address for loads and
  stores, only the faulting instruction's.

## The tests

```bash
make freertos-loader-test                # loader/session.txt and session-ext.txt on HaDes-V+
make freertos-loader-test CPU=golden     # the same on the golden CPU
make freertos-loader-compare             # both CPUs; the transcripts of session.txt compared
make freertos-shell-tty-test APP=loader  # names, uploads, pastes, send requests, input and Ctrl-C through a terminal
```

`test/freertos/loader/session.txt` loads and runs every example app (`hello` with arguments,
`compute` twice, `selfmod`, `upper` with typed input), ends `crash` in each of its ten ways
(each exception, a stack overflow found at a task switch and one found only as the app
returns, Ctrl-C in its loop, and Ctrl-C typed right after the Enter of `run`) and runs another
app afterwards, sends every rejected test file of SPEC.md, section 9.5 (after a successful load
of a valid image, so that the check that nothing runs is meaningful) and the files that hold a
Ctrl-C, empty lines or records after their end, loads two apps and a test file by name and
asks for an unknown name, and checks that `uart` lost no character. `session-ext.txt` runs
`compute` built for `rv32im_zba` (and loads it by name, `load rv32im_zba/compute`), which the
golden CPU refuses. The verdict:

```text
LOADER COMPARE: PASS  session.txt: dut PASS, golden PASS, transcripts SAME; session-ext.txt: dut PASS, golden PASS
```

after the verdict line of each session (`FREERTOS SHELL RESULT: PASS ... expectations met:
146/146`) and the comparison (`SHELL COMPARE: SAME  84 blocks, 292 lines equal after
normalising numbers`). `make` exits with status 0 only if every part passed. The logs are
`session-<cpu>.log` and `session-ext-<cpu>.log` (with the UART transcripts `.uart`) in
`${HADES_BUILD_DIR:-build}/test/freertos/loader/`.

## Settings

`APP=loader` takes the settings of the shell targets ([SHELL.md](SHELL.md#settings)), except `RAM_KB`, which is
fixed at 256. `OPT` defaults to `-Os` (every level fits the shell's 128 KiB); `MARCH`, `BPRED`
and `TICK` apply to the shell, not to the apps, which `make freertos-app` builds with its own
`MARCH` and `OPT`. A scripted session has a limit of 300 million cycles. `UPLOAD=<app>`
applies to `make freertos-shell APP=loader` (without `APP=loader`, `make` stops with an
error) and to `make freertos-send`.

## Troubleshooting

**`load failed: <reason>`.** The file is not an app image that the loader accepts; the
reason names the line or the field. `python3 test/freertos/sdk/appimg.py info <file>` gives
the same reason on the host. A file written by `objcopy -O ihex` is refused (`record type 02
is not supported`): send the `.hex` file that `make freertos-app` writes.

**`load` waits and nothing arrives.** `load` without a name waits for a file. In the terminal
mode without `UPLOAD=`, the simulator prints a hint: paste the file, or press Ctrl-C and type
`load <name>`. In the pseudo-terminal mode, press Ctrl-C and type `load <name>`, or run
`make freertos-send UPLOAD=<app>` in another terminal: it sends the file to the waiting
`load`. It fails with `no loader session with a pseudo-terminal is
running` when the session was not started with `APP=loader PTY=1`.

**`freertos-send: not sent: ...`.** The simulator types `load` only while the shell waits at
its prompt with an empty command line. `the shell is not at its prompt`: a command or an app
is running (stop the app with Ctrl-C); `the command line is not empty`: press Enter in the
terminal program for a fresh prompt; `a file is being sent`: wait for the current `load` to
end.

**`error: <app> was built for rv32im_zba, but this CPU has no M and no Zba`.** The golden
CPU runs RV32I apps only: build the app without `MARCH`.

**`app: ... stopped by an exception`.** Look up the address in `.dis` of the app
(`${HADES_BUILD_DIR:-build}/test/freertos/sdk/<march>/<name>.dis`). For a jump to a bad
address, such as `instruction access fault (mcause 1) at 0x00000000`, look up the `ra` that
the report adds: the call before it is the one that jumped. If the whole simulation
ends with `FRTOS-RESULT: FAIL unexpected exception` instead, the exception could not be
contained, for example because the app had disabled interrupts or written outside the slot
([What is contained, and what is not](#what-is-contained-and-what-is-not)).

**`undefined reference to '_read'` (or `_lseek`, `_write`, `_sbrk`, ...) when an app is
linked.** The app calls a `stdio` function such as `printf` or `puts`, or `malloc`; apps have
neither. Use `app_printf` and the other functions of `hades_app.h`, and the memory between
`__app_heap_start` and `__app_heap_end`.

Problems that all FreeRTOS programs share are covered in
[FREERTOS.md](FREERTOS.md#13-troubleshooting), those of the shell in
[SHELL.md](SHELL.md#troubleshooting).
