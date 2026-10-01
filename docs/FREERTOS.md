# Running FreeRTOS on HaDes-V+

This guide shows how to boot FreeRTOS on the HaDes-V+ core in simulation, how to check a
run against the golden reference CPU, how to run the stress tests, and how to write and run
a FreeRTOS program of your own. Every command below can be copied as it stands.

The simulations are cycle-accurate Verilator models of the complete microcontroller (core,
RAM, UART, timer, test peripheral). The FreeRTOS port is the official RISC-V port of
FreeRTOS V11.1.0+, unmodified, running in machine mode.

**Contents**

1. [Prerequisites](#1-prerequisites)
2. [One-time setup](#2-one-time-setup)
3. [Boot FreeRTOS](#3-boot-freertos)
4. [What the output means](#4-what-the-output-means)
5. [Compare with the golden CPU](#5-compare-with-the-golden-cpu)
6. [Run the stress tests](#6-run-the-stress-tests)
7. [The branch predictor, and changing a setting](#7-the-branch-predictor-and-changing-a-setting)
8. [Write and run your own program](#8-write-and-run-your-own-program)
9. [The interactive shell](#9-the-interactive-shell)
10. [Settings reference](#10-settings-reference)
11. [Where the files are](#11-where-the-files-are)
12. [Troubleshooting](#12-troubleshooting)
13. [How the port works](#13-how-the-port-works)

## 1. Prerequisites

| Tool | Tested version | Check |
|---|---|---|
| GNU make, a POSIX shell, coreutils | any recent Linux | `make --version` |
| Verilator | 5.042 | `verilator --version` |
| RISC-V GCC with newlib-nano, in `/opt/riscv32i/bin` | GCC 12.2.0, binutils 2.39 | see below |
| git | 2.43 | `git --version` |
| Python 3 | 3.12 (3.8 or newer) | `python3 --version` |
| Free disk space | 30 MB and more for the builds | `df -h .` |

No network access is needed: the FreeRTOS sources are part of the repository.

Check the tools:

```bash
verilator --version
/opt/riscv32i/bin/riscv32-unknown-elf-gcc --version | head -n 1
/opt/riscv32i/bin/riscv32-unknown-elf-gcc -march=rv32i -mabi=ilp32 -print-file-name=libc_nano.a
git --version
python3 --version
```

The third command must print a full path ending in `libc_nano.a`. If it prints only
`libc_nano.a`, the toolchain has no newlib-nano and cannot link FreeRTOS programs.

## 2. One-time setup

### 2.1 The FreeRTOS sources

The FreeRTOS sources are part of this repository, in
[`third_party/freertos/`](../third_party/freertos/README.md): the kernel and its RISC-V port
from FreeRTOS-Kernel at commit `8be86d4a24fd4091f8f4192018423ab590f408db`, and the standard
demo tasks and the FreeRTOS+CLI command interpreter (used by the interactive shell of
section 9) from FreeRTOS/FreeRTOS at commit `f4fcc3b228643144727e9257ba12db1cb632b6e6`, both
unmodified. There is nothing to download; the Makefile uses them by default.

To build against another FreeRTOS checkout instead, set `FREERTOS_HOME` to a directory that
holds clones of both repositories side by side (`FreeRTOS-Kernel/` and `FreeRTOS/`) and keep
it set for later commands, or set `FREERTOS_KERNEL` and `FREERTOS_DEMO` individually. Only
the commits above are tested.

### 2.2 Choose where to build

Verilator compiles every simulator into a native program, so the build directory must be
on a filesystem that can execute programs. Check which kind of filesystem the repository
is on:

```bash
findmnt -no FSTYPE,OPTIONS -T .
```

**On a native Linux filesystem** (`ext4`, `btrfs`, `xfs` and similar, without `noexec` in
the options) there is nothing to do: everything is built in `build/` inside the
repository.

**On a filesystem that cannot execute programs** — typically an NTFS or exFAT partition
(shown as `fuseblk`, `ntfs`, `ntfs3`, `exfat` or `vfat`), a network share, or any mount
with `noexec` in its options — a simulator built there fails to start with
`Permission denied`. The sources can stay where they are; only the build output has to
move. Point `HADES_BUILD_DIR` at a directory on a native filesystem:

```bash
export HADES_BUILD_DIR=$HOME/hades-build
```

On such a filesystem, also note:

* Files there cannot be marked executable, so scripts are run through `sh` or `python3`.
  The make targets already do this.
* `git config core.fileMode false` stops git from reporting every script as modified,
  since the filesystem cannot record execute permissions.

`export` holds only for the current terminal. To make a setting permanent, add it to
`~/.bashrc`, for example:

```bash
echo 'export HADES_BUILD_DIR=$HOME/hades-build' >> ~/.bashrc
```

`make help` shows the build directory in use on its last line:

```bash
make help | tail -n 1
```

```text
Build directory: <build directory>  (relocate with BUILD_DIR=/abs/path or HADES_BUILD_DIR)
```

Notes:

* A build directory belongs to one checkout. If you work with two copies of the
  repository, give each its own build directory.
* Instead of the environment variable you can name the directory per command, as in
  `make BUILD_DIR=$HOME/hades-build test/asm/ops`. All targets of the Makefile (assembly,
  C and SystemVerilog tests, `synthesis`, `show`, `clean`) follow it.

Every later section assumes that you are in the repository directory, with
`HADES_BUILD_DIR` set if your filesystem needs it.

## 3. Boot FreeRTOS

List the FreeRTOS programs:

```bash
make freertos-list
```

```text
FreeRTOS programs (make freertos APP=<name>; the interactive ones: make freertos-shell APP=<name>):
  brk        RTOS-level breaker: interrupt storms, tick catch-up, task churn, fence.i, deliberate exceptions; 64 KiB
  full       the FreeRTOS standard demo task set (official RISC-V QEMU full_demo) + RegTest; 256 KiB, simulation only
  minimal    two application tasks + idle (notification ping-pong, idle progress, tick drift); 32 KiB
  mzba       M and Zba code under the RTOS, checked against an rv32i software build of the same code; 32 KiB
  shell      interactive command shell (FreeRTOS+CLI) on the UART; make freertos-shell; 32 KiB
  stress     RegTest, desynchronised queues, ISR-fed semaphores, critical-section and slow-bus checks; 32 KiB
  template   starting point for your own program (copy it: make freertos-new NAME=<name>)
```

Boot the smallest one:

```bash
make freertos APP=minimal
```

The first run also builds the simulator of the core (about 20 seconds on a current
laptop); later runs reuse it. The program then runs for about 3.2 million clock cycles,
which takes about two seconds. The output ends like this:

```text
FreeRTOS V11.1.0+ on HaDes-V+: minimal (2 tasks + idle)
  config: tick=10000cyc preempt=1 slice=1 heap_4 isa=rv32i opt=2 ram=32K bpred=0
  seed: switches=00000000 seed=641ed1ca
~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz~
~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz~
~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz~
  ticks=309 notifications=113 idle=145732 isr-stack-peak=172/2048
FRTOS-RESULT: PASS mtime=0000000000305be6
(63414400 ps) Test pass!
...
All tests passed! (# Errors: 1 = initial test)
...
==============================================================================
FREERTOS RESULT: PASS  app=minimal cpu=dut isa=rv32i opt=-O2 tick=10000 bpred=0 seed=0 cycles=3169254
  UART pattern lines intact: 3/3
  log: <build directory>/test/freertos/minimal/run-dut.log
==============================================================================
```

`make` exits with status 0 exactly when the last block says `PASS`, so the command can
also be used in scripts.

## 4. What the output means

A run prints, in this order:

| Output | Meaning |
|---|---|
| `build: minimal [rv32i -O2 tick=10000 bpred=0] and the dut simulator(s)` | What is being built. The compiler output goes to `build.log` (shown on the next line); `VERBOSE=1` prints it instead. |
| `minimal: RAM 32 KiB, image+bss 15808 bytes (...)` | Size of the program image. `(program up to date, not rebuilt)` means the previous build was reused because nothing changed. |
| `RUN app=... cpu=dut ...` | The configuration of this run. `cpu=dut` is the HaDes-V+ core, `cpu=golden` the reference CPU. |
| `REFERENCE IMPLEMENTATION OF "cpu.sv" USED!` | Printed by the golden CPU only. |
| `(224280 ps) Test fail!` | **Not an error.** The program's first act is to write the test register's "initial" marker, which the simulator reports this way. The final count therefore includes one "error". |
| `FreeRTOS V11.1.0+ on HaDes-V+: minimal ...` | The program started. From here on, everything up to `FRTOS-RESULT` is the program's own UART output. |
| `config: tick=10000cyc preempt=1 slice=1 heap_4 isa=rv32i opt=2 ram=32K bpred=0` | The configuration the program was *built* with: cycles per RTOS tick, preemption, time slicing, heap implementation, instruction set, optimisation level, RAM size and branch-predictor mode. |
| `seed: switches=00000000 seed=641ed1ca` | The run seed (`SEED=`), which varies the interrupt timing. |
| `~0123...xyz~` | A fixed test line printed while interrupts are enabled. Every such line must arrive intact; a doubled or missing character would reveal a UART store that the core performed twice or lost. |
| `FRTOS-RESULT: PASS mtime=...` or `FRTOS-RESULT: FAIL <reason> a=<hex> b=<hex>` | The program's own verdict. `mtime` is the cycle count at the end (in hexadecimal). |
| `(63414400 ps) Test pass!` | The simulator's record of the verdict; one clock cycle is 20 ps. |
| `All tests passed! (# Errors: 1 = initial test)` | The test protocol agrees (the one error is the initial marker). |
| `- S i m u l a t i o n   R e p o r t ...` | Verilator's run statistics. |
| `FREERTOS RESULT: PASS ... cycles=3169254` | The overall verdict, see below. |

The overall verdict is one of:

| Verdict | Meaning |
|---|---|
| `PASS` | The program passed, the test protocol completed, and every test line arrived intact. |
| `FAIL` | The program detected an error (the reason is printed), or the protocol or a test line was broken. |
| `HANG` | No verdict before the cycle limit (`TIMEOUT=`). Either the program needs more cycles or the system hung. |
| `CRASH` | The simulator stopped without a verdict. |

The full output of every run is kept in `run-dut.log` or `run-golden.log` (see
[Where the files are](#11-where-the-files-are)).

## 5. Compare with the golden CPU

The repository contains a frozen reference implementation of the original core, the
*golden CPU*. It is the oracle for the base instruction set: a program that passes on the
golden CPU and fails on HaDes-V+ has found a bug in HaDes-V+. Run the same program on it
with `CPU=golden`:

```bash
make freertos APP=minimal CPU=golden
```

The golden CPU implements RV32I and Zicsr only. It has no multiply/divide (M) and no Zba,
and its `time` CSR reads 0. Programs are therefore built for `rv32i` by default, and
`CPU=golden` refuses any other `MARCH`. The first golden run builds the golden simulator
(about 15 seconds).

To run one program on both CPUs and compare the verdicts in one step:

```bash
make freertos-compare APP=minimal
```

```text
==============================================================================
COMPARE  dut: PASS   (3169254 cycles)   golden: PASS   (3169246 cycles)
AGREE: the program passed on both CPUs. (Cycle counts differ legitimately: the golden
CPU samples interrupts one cycle later, so the two runs interleave differently.)
==============================================================================
```

Both runs use the same program image. The cycle counts may differ slightly: the golden
CPU recognises an interrupt one cycle later than HaDes-V+, so the two runs interleave
differently. Only the verdicts are compared.

## 6. Run the stress tests

The `stress` program runs the port's register tests together with queues, semaphores and
critical sections while a test interrupt fires at random times. The timing depends on the
seed, so different seeds exercise different interleavings. Run it once, and once on both
CPUs with another seed:

```bash
make freertos APP=stress
make freertos-compare APP=stress SEED=7
```

A single run takes about 5 million cycles, a few seconds.

For a thorough check, `make freertos-stress` runs a *differential campaign*: seven
configurations of the `stress`, `minimal` and `mzba` programs (optimisation levels,
tick rates, with and without preemption), each with several seeds, on HaDes-V+ and on the
golden CPU, in parallel:

```bash
make freertos-stress
```

It builds the program variants and the simulators they need (a 64 KiB variant for the
`-O0` build), runs everything, and prints progress lines, a table of all runs and a
summary. It takes a minute or two once the simulators exist. The summary ends like this:

```text
### Verdict

- harness check: golden passed all 14 runs
- dut: 14/14 runs passed
...
CAMPAIGN RESULT: PASS (28 runs: 0 DUT run(s) not passed, 0 golden run(s) not passed, 0 build failure(s))
```

How to read it:

* `harness check: golden passed all N runs` confirms that the test programs themselves
  are valid. If the golden CPU fails a run, that configuration is invalid as a test and
  the campaign reports `HARNESS CHECK FAILED`.
* `dut: N/N runs passed` is the result for HaDes-V+. Any run that did not pass is listed
  with its reason, and `make` exits with a non-zero status.
* The table, a CSV and JSON file and one log per run are written to
  `$HADES_BUILD_DIR/freertos-campaign/validate/`.

More seeds, more parallel jobs, or another set of configurations:

```bash
make freertos-stress SEEDS=8 JOBS=6
```

`SET=standard` runs 55 configurations of all programs, including the M and Zba builds
(checked by the programs' own self-checks, since the golden CPU cannot run them) and the
full FreeRTOS demo; `SET=bpred` runs the programs with the branch predictor on. See
`test/freertos/README.md` for all sets.

## 7. The branch predictor, and changing a setting

The core's branch predictor is off after reset. `BPRED=<mode>` makes the program switch it
on at start-up (1 always-taken, 2 backward-taken, 3 bimodal):

```bash
make freertos APP=stress BPRED=3
```

The `config:` line of the output ends in `bpred=3`, which shows that the program was built
with the new setting. Every setting is part of the build configuration: when one changes,
the program is rebuilt *before* it runs, so the run always uses the setting given on its
own command line. Switch the predictor off again and look only at the `config:` line and
the verdict:

```bash
make freertos APP=stress BPRED=0 | grep -E 'config:|FREERTOS RESULT'
```

```text
  config: tick=10000cyc preempt=1 slice=1 heap_4 isa=rv32i opt=2 ram=32K bpred=0
FREERTOS RESULT: PASS  app=stress cpu=dut isa=rv32i opt=-O2 tick=10000 bpred=0 seed=0 cycles=...
```

The golden CPU has no branch predictor; it ignores the mode register, so a comparison with
the predictor on is still valid:

```bash
make freertos-compare APP=stress BPRED=3
```

`make freertos-check-rebuild` checks the rebuild behaviour automatically: it runs the
`minimal` program eight times with a different setting each time and verifies from each
run's `config:` line that the new build was used, and that an unchanged configuration is
not rebuilt. It ends with `REBUILD CHECK: PASS`:

```bash
make freertos-check-rebuild
```

## 8. Write and run your own program

`test/freertos/template/` is a small, commented program: a producer task sends numbers
through a queue to a consumer task, which checks their order and reports `PASS` after 20
items. Copy it under a new name and run the copy:

```bash
make freertos-new NAME=myapp
make freertos APP=myapp
```

The new directory `test/freertos/myapp/` contains three files:

| File | Contents |
|---|---|
| `main.c` | The program. Edit it freely; the comment at its top summarises the rules below. |
| `app_config.h` | FreeRTOS settings of this program (heap size, priorities, stack size, hooks), and the program's own options. |
| `app.mk` | Build settings: source files (by default every `.c` and `.S` file in the directory), extra kernel files (`timers.c`, `event_groups.c`, `stream_buffer.c`), RAM size, interrupt stack, cycle limit. |

Rules for a program:

* Start `main()` with `hal_begin("<name>")`, create the tasks, and call
  `vTaskStartScheduler()`.
* End the run with `hal_pass()` or `hal_fail(reason, detail, a, b)`. A program that calls
  neither runs until the cycle limit and is reported as `HANG`.
* Print with `hal_puts()`, `hal_putdec()`, `hal_puthex()` and `hal_putc()`. There is no
  `printf()`. Output of tasks that print at the same time interleaves; print whole lines
  inside `vTaskSuspendAll()` / `xTaskResumeAll()` (as the template does) or with
  `hal_puts_atomic()`. Do not print from an interrupt handler.
* One tick is `TICK` clock cycles (10000 by default); `pdMS_TO_TICKS(n)` is `n` ticks.
* The real board has 32 KiB of RAM. `RAM_KB=64` (or more) gives the simulation more room.
* A failed `configASSERT()`, a stack overflow, a failed allocation and an unexpected
  exception or interrupt all end the run with `FRTOS-RESULT: FAIL` and the reason.
* Built for `rv32i` (the default), the program also runs on the golden CPU.

The helper functions are declared in `test/freertos/common/hades_hal.h`.

`make freertos-new NAME=<name> FROM=<program>` copies another program instead of the
template, for example `FROM=shell` for a command shell of your own (section 9).

The template has two options of its own, set through `DEFS`. Run it with a different
number of items, and with an interrupt handler that the simulation's test interrupt
source triggers every 7919 cycles:

```bash
make freertos APP=myapp DEFS=-DTEMPLATE_ITEMS=5
make freertos-compare APP=myapp DEFS=-DTEMPLATE_WITH_IRQ=1
```

With the interrupt handler, the last line of the program's output reports the number of
interrupts handled, for example `external interrupts 128`.

Your program can use the M and Zba instructions on HaDes-V+ (it then no longer runs on
the golden CPU):

```bash
make freertos APP=myapp MARCH=rv32im_zba OPT=-Os
```

## 9. The interactive shell

`test/freertos/shell/` is a command shell for HaDes-V+: FreeRTOS with the official
FreeRTOS+CLI command interpreter, on the UART. In the simulator, the UART is connected to
your terminal, so you type commands into the running core as you would into a board's serial
console. The commands show the tasks, their CPU time and stacks, the heap, the cycle and
instruction counters, the branch predictor's counters, and exercise the M and Zba
instructions.

### Start it

```bash
make freertos-shell
```

The first run builds the shell and a console variant of the simulator (about a minute).
After the build lines, the shell starts like this; type `help` and press Enter:

```text
run: app=shell cpu=dut isa=rv32i opt=-Os tick=10000 bpred=0 seed=0  (UART copy: .../test/freertos/shell/console.log)
     (the first 'Test fail!' line is the program's deliberate 'initial test' marker)
[console] the UART is connected to this terminal; press Ctrl-] to end the simulation
(195860 ps) Test fail!

HaDes-V+ shell on FreeRTOS V11.1.0+ with FreeRTOS+CLI
  config: tick=10000cyc preempt=1 slice=1 heap_4 isa=rv32i opt=-Os ram=32K bpred=0
Type 'help' for the list of commands.
hades> help

help:
 Lists all the registered commands

version            Software, build and CPU extensions
tasks              Tasks: state, priority, free stack
stats              CPU cycles used by each task
mem                Heap and RAM use
uptime             Ticks, mtime, seconds since reset
counters           Cycles, instructions, IPC
bpred [0-3|reset]  Branch predictor mode and counters
mul <a> <b>        mul, mulh, mulhsu, mulhu
div <a> <b>        div, rem, divu, remu
zba <a> <b>        sh1add, sh2add, sh3add
uart               UART receive statistics
echo <text>        Print the text
halt               Stop (ends the simulation)
exit               The same as halt
hades>
```

(`help` is the built-in command of FreeRTOS+CLI; it lists itself first, in its own format.)

**To quit**, press **Ctrl-]** (Control and the right square bracket), or type `halt` or
`exit`. Ctrl-] is handled by the simulator itself, so it works whatever the program is
doing, also when it has hung and stopped reading the UART. The simulator switches the
terminal to raw mode while it runs, so that every key, Ctrl-C included, reaches the shell; it
restores the terminal settings however it ends: `halt`, Ctrl-], the cycle limit, a
`$fatal`, a crash, or any signal that ends a process by default, such as SIGINT, SIGTERM,
SIGHUP, SIGQUIT or SIGPIPE (the latter when the output goes to a pipe whose reader has
gone, as in `make freertos-shell | head`). A signal that was already ignored when the
simulator started (SIGHUP under `nohup`) stays ignored. Only `kill -9` cannot be caught; if
that leaves the terminal in raw mode, type `stty sane` and press Enter (the characters are
not echoed).
The copy of the UART output, `console.log`, is written as the characters arrive, so it is
complete however the simulation ends.

The simulation runs at about 1.6 to 1.9 million clock cycles per second on a current PC,
about 30 times slower than the 50 MHz board, and it has no cycle limit in this mode
(`TIMEOUT=` sets one). The RTOS tick is 10000 cycles by default, so `uptime` advances by
one RTOS second (1000 ticks) every 5 to 6 seconds of real time; `TICK=50000` gives the
board's real 1 kHz tick at 50 MHz.

### The commands

Numbers can be given in decimal (`-7`, `4294967295`) or hexadecimal (`0x80000000`). The
examples are from one session on HaDes-V+; the numbers depend on the moment.

| Command | What it shows or does |
|---|---|
| `help` | The list of commands. |
| `version` | FreeRTOS version, the instruction set and optimisation the program was compiled for, the build configuration, and which extensions the CPU actually executes (probed at start-up: M, Zba and Zicntr). |
| `tasks` | Every task with its state, priority and the least free stack space it has had so far (the high-water mark, in 32-bit words). |
| `stats` | CPU cycles each task has run since the scheduler started, and its share (FreeRTOS run-time statistics with the 64-bit `mcycle` counter as the clock). |
| `mem` | Free heap now and at the lowest point, the RAM layout, and the interrupt stack's peak use. |
| `uptime` | RTOS ticks, `mtime` (the cycle counter of the machine timer), and the time in seconds at the configured tick clock and at the board's 50 MHz. |
| `counters` | `mcycle`, `minstret` and the instructions per cycle, since reset and since the previous `counters`; the Zicntr counters `cycle`, `time`, `instret` where the CPU has them. |
| `bpred [0-3\|reset]` | The branch predictor's mode (`MHPMEVENT10`) and its four outcome counters (`MHPMCOUNTER10`-`13`: predicted/actual not taken/taken) with the prediction accuracy. `bpred <n>` sets mode n (0 off, 1 always taken, 2 backward taken, 3 bimodal) and clears the counters; `bpred reset` only clears them. |
| `mul <a> <b>` | `mul`, `mulh`, `mulhsu`, `mulhu`: the 64-bit product in two halves. |
| `div <a> <b>` | `div`, `rem`, `divu`, `remu`, including the cases that do not trap in RISC-V: division by zero and `-2^31 / -1`. |
| `zba <a> <b>` | `sh1add`, `sh2add`, `sh3add`. |
| `uart` | Characters received, dropped because the receive queue was full, and lost in the UART. |
| `echo <text>` | Prints the text. |
| `halt`, `exit` | End the program (`FRTOS-RESULT: PASS`) and with it the simulation. |

`mul`, `div` and `zba` run the CPU's own instructions when it has them, whatever `MARCH`
the program was built with, and compare every result with a software model compiled for
plain RV32I (`swmodel.c`). The last line says which: `the CPU's M instructions, equal to
the rv32i software model`, or on the golden CPU, which has neither M nor Zba,
`rv32i software model: the CPU has no M`.

```text
hades> tasks
task        state      priority  stack free (min)
console     running           2         185 words
blink       blocked           3          81 words
IDLE        ready             0         125 words
3 tasks
hades> stats
task            CPU cycles    share
console             315176    98.4%
blink                  459     0.1%
IDLE                  4607     1.4%
total               320242   since the scheduler started (clock: mcycle)
hades> mem
heap:      1152 of 4608 bytes free, 1152 at the lowest (heap_4)
RAM:       32768 bytes: program and data 31744 (with the heap), unused 512,
           interrupt stack 512 (168 used at most)
hades> counters
cycles:    563742 (mcycle)
instret:   304978 (minstret)
IPC:       0.541 since reset
cpu:       Zicntr: cycle 571965, time 571970, instret 310439
hades> bpred 3
counters cleared
mode:      3 (bimodal, 2-bit counters)
branches:  predicted not taken: 18 right (nn), 5 wrong (nt)
           predicted taken:     32 right (tt), 6 wrong (tn)
accuracy:  82.0% of 61
hades> div -7 2
a = -7 (0xfffffff9), b = 2 (0x00000002)
  div             -3  0xfffffffd  quotient, signed
  rem             -1  0xffffffff  remainder, signed
  divu    2147483644  0x7ffffffc  quotient, unsigned
  remu             1  0x00000001  remainder, unsigned
source:    the CPU's M instructions, equal to the rv32i software model
hades> div 1 0
a = 1 (0x00000001), b = 0 (0x00000000)
  div             -1  0xffffffff  quotient, signed
  rem              1  0x00000001  remainder, signed
  divu    4294967295  0xffffffff  quotient, unsigned
  remu             1  0x00000001  remainder, unsigned
note:      x / 0 does not trap: quotient all ones, remainder x
source:    the CPU's M instructions, equal to the rv32i software model
hades> halt
halted

FRTOS-RESULT: PASS mtime=0000000000117484
```

In this session the console task has most of the CPU because the commands were typed
without pauses; in a session typed by hand, `IDLE` has nearly all of it.

### Editing a command line

| Key | Effect |
|---|---|
| Enter (CR, LF or CR LF) | Run the command. |
| Backspace, Delete | Delete the last character. |
| Ctrl-C | Cancel the line (the simulator keeps running). |
| Ctrl-U | Erase the line. |
| Up arrow / Down arrow | Recall the previous command / erase the line. |
| Esc | Ignored. The key after it counts as usual (Enter, Ctrl-C or a letter); only `[` or `O` right after it starts an arrow-key sequence, and a pause of 100 RTOS ticks ends one. |
| Ctrl-] | End the simulation (handled by the simulator, never sent to the shell). |

A line has at most 80 characters. A longer one is rejected with
`error: line too long (at most 80 characters); it is discarded up to its end`, and the rest
of it is ignored up to the Enter, so that a long paste never runs half a command. Pasting
several lines at once is fine: the simulator reads them at once and types them one after the
other, each after the shell has answered the previous one.

### Attach a terminal program instead (PTY=1)

With `PTY=1` the UART is connected to a pseudo-terminal, which a terminal program can open
like a board's serial port:

```bash
make freertos-shell PTY=1
```

```text
[console] the UART is connected to the pseudo-terminal /dev/pts/5
[console] symbolic link: .../test/freertos/shell/pty
[console] attach a terminal program, e.g.  screen .../test/freertos/shell/pty   or   picocom .../test/freertos/shell/pty  (then press Enter)
[console] Ctrl-] typed there, or 'halt', ends the simulation; so does Ctrl-C here
```

In a second terminal, in the repository directory, attach to the link it printed and press
Enter to get a prompt:

```bash
screen ${HADES_BUILD_DIR:-build}/test/freertos/shell/pty
```

The first terminal keeps showing everything the shell prints. `halt`, or Ctrl-] typed in
`screen`, ends the simulation (and `screen` with it); Ctrl-C in the first terminal does too.
To leave `screen` without ending the simulation, detach it with Ctrl-A and then `d`;
`screen -r` attaches again. (Closing `screen` with Ctrl-A `k` instead leaves the device in
`screen`'s exclusive mode, so that no terminal program can open it again until the
simulation ends.) The link `pty` is removed when the simulation ends.

### Scripted sessions and the tests

`make freertos-shell-test` types the command script `test/freertos/shell/session.txt` into
the shell and checks the transcript. The script runs 39 command lines: every command, the
M-extension corner cases, the line-editing keys (a lone Esc included), an unknown command, a
wrong parameter count and an over-long line, and finally `uart` (nothing may have been
dropped) and `halt`. It ends with a verdict line, and `make` exits with status 0 only for
`PASS`:

```text
==============================================================================
FREERTOS SHELL RESULT: PASS  app=shell cpu=dut isa=rv32i opt=-Os tick=10000 bpred=0 seed=0 cycles=2278845
  typed lines: 39, prompts: 39, expectations met: 120/120
  log: .../test/freertos/shell/session-dut.log
  UART transcript: .../test/freertos/shell/session-dut.uart
==============================================================================
```

The same program on the golden CPU, and both compared line by line:

```bash
make freertos-shell-test CPU=golden
make freertos-shell-compare
```

```text
SHELL COMPARE: SAME  40 blocks, 158 lines equal after normalising numbers;
  lines labelled source:/cpu:/mode:/accuracy: (M, Zba, Zicntr, branch predictor) excluded
```

The comparison replaces every number by `#` (cycle counts and counters legitimately differ,
because the golden CPU takes interrupts one cycle later) and leaves out the lines that report
what the CPU implements; everything else, 158 lines, must be identical.

Write your own script and run it with `SCRIPT=`:

```bash
make freertos-shell-test SCRIPT=my-session.txt
```

Every line of a script is typed followed by Enter, each after the shell has answered the
previous line with its prompt. Lines starting with `#` are not typed. `#? <regular
expression>` requires a line of the preceding command's output to match (in the given
order), `#! <regular expression>` requires that none does. The output is what the shell
prints after the command line; the command line itself, as the shell echoes it after the
prompt, never counts, so `echo hello` followed by `#? hello` passes only if the shell really
prints `hello`. `#> <regular expression>` checks that echoed command line instead (for
example `#> \^C$` after a line cancelled with Ctrl-C). `#?dut`, `#?golden`, `#!dut`,
`#!golden`, `#>dut` and `#>golden` apply to one CPU only. Escapes: `\r`, `\n`, `\t`, `\e`
(Escape), `\\`, `\xHH`, and `\c` at the end of a line suppresses the Enter. For example:

```text
div 7 -2
#? ^\s+div\s+-3\s
#? ^\s+rem\s+1\s
echo abX\x08c
#? ^abc$
halt
```

The verdict is `PASS` only if every expectation is met, every typed line produced one
prompt, the program ended with `FRTOS-RESULT: PASS` and the simulator exited with status 0;
a simulator that exits with another status or is killed by a signal gives `CRASH`, whatever
the transcript says.

`make freertos-shell-tty-test` checks the interactive console itself: it runs the simulator
on a pseudo-terminal, as in a terminal window, types keys with pauses like a person (a lone
Esc among them), pastes 13 lines at once, and ends the simulation in every supported way:
Ctrl-] (also while a typed character waits unread in the UART of a program that has hung),
`exit`, the cycle limit, SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGPIPE (sent, and raised by a
closed output pipe), SIGABRT, SIGALRM, SIGUSR1, SIGSEGV, and a SIGTSTP stop followed by
SIGCONT; a SIGHUP that was ignored at the start (as under `nohup`) must stay ignored. Each
time it checks that the terminal settings are exactly those from before (as
`stty -g` prints them), and after SIGINT and SIGTERM that the copy of the UART output is
complete. It also runs sessions through `PTY=1`, ended by `halt` and by Ctrl-C in the
simulator's terminal. It ends with `TTY TEST: PASS`.

### Settings

`make freertos-shell`, `freertos-shell-test`, `freertos-shell-compare` and
`freertos-shell-tty-test` take the settings of section [10](#10-settings-reference), with
these differences:

* `APP` defaults to `shell`. Another program that reads the UART (`APP_CONSOLE := 1` in its
  `app.mk`) can use the same targets.
* `OPT` defaults to `-Os`, which fits the board's 32 KiB. With any other level the program
  needs a 64 KiB simulation (chosen automatically).
* `CPU=golden` needs `MARCH=rv32i` (the default), as everywhere.
* `TIMEOUT`: no limit in an interactive session; 50 million cycles for a scripted one.
* `PTY=1` (interactive only) and `SCRIPT=<file>` (scripted only).

`make freertos APP=shell` refuses to run the shell, because nothing would ever arrive on its
receive line; the message names the targets above.

### How it works

**The program** (`test/freertos/shell/`, 32 KiB):

* The UART raises the machine external interrupt while its one-byte receive buffer is full.
  The handler `app_external_irq()` (`console.c`) reads the byte with one word load (byte and
  status together; the load empties the buffer), sends it to a FreeRTOS queue of 64
  characters and wakes the console task. It never prints.
* The console task (priority 2) edits the line and hands complete lines to
  `FreeRTOS_CLIProcessCommand()`. The commands (`commands.c`) write their output into the
  CLI's buffer; a command with a lot to say (the task list) is called again for each line.
* Output: `shell_write()` sends each line of text with the scheduler suspended (the technique
  of `hal_puts_atomic()`), so the complete lines of different tasks never interleave, and
  interrupts, and with them input, keep working. A lone `\n` goes out as `\r\n`.
* `blink` (priority 3) toggles LED 0 every 500 ticks, a periodic task to look at with
  `tasks` and `stats`.
* `version` probes the CPU at start-up by executing one `mul`, one `sh1add` and one read of
  `cycle`, catching the illegal-instruction trap; the run-time statistics use `mcycle`,
  which both CPUs implement.
* The shell is built with `-Os` and uses no mutexes, no stream buffers and no 64-bit
  division from libgcc; that is what makes it fit. The program, its data and the heap
  (which holds the task stacks) take 31744 of the 32768 bytes, the interrupt stack 512, and
  512 are unused (`mem`).

**The simulator.** The console targets use a variant of the simulator,
`frtos-model/<cpu>-<n>k-console/top`, verilated with `+define+HADES_CONSOLE` and the DPI-C
bridge `sim/console.cpp`. The plain simulators, and with them every other test, do not
contain it. Every 64 clock cycles the bridge reads whatever has been typed into a queue of
its own and looks for Ctrl-], whatever the UART is doing. From that queue it types each
character into the UART's RX pin as a real 8N1 frame of 16 clock cycles per bit, which is
exactly the receiver's sampling interval at the simulation's baud rate (`sys_clk/15`). At
that rate a character arrives faster than a program can take it from its interrupt handler,
echo it and wait for the next, so only this injection is paced, like a careful typist: the
next character follows only after the program has read the previous one from the UART, at
least 512 cycles later, once its output has paused for 512 cycles, and, after Enter, once
the program has printed its next prompt. Typed-ahead and pasted input waits in the
simulator, so no character is lost (`uart` shows `dropped: 0`). What the program sends
reaches the terminal through the UART echo of `wishbone_uart.sv`, and `console.log`
through an unbuffered write.

**On a board** the same program talks to a terminal program on the other end of the UART
at 115200 baud; `halt` then only stops the shell. (The shell has been run in simulation
only.)

### Add a command

Make a shell of your own, so that the shipped one (and its test session) stays as it is:

```bash
make freertos-new NAME=myshell FROM=shell
```

This copies the shell's sources, `app.mk`, `app_config.h` and `session.txt` to
`test/freertos/myshell/`. Add a function and a table entry to
`test/freertos/myshell/commands.c`. A command that adds two numbers:

```c
/* add <a> <b> */
static BaseType_t prvAdd( char * pcOut, size_t xOutLen, const char * pcCommand )
{
    uint32_t a, b;

    if( !prvOperands( pcCommand, 1, 2, &a, &b, pcOut, xOutLen ) )   /* parses the parameters */
    {
        return pdFALSE;
    }

    shell_snprintf( pcOut, xOutLen, "%ld + %ld = %ld\n", ( int32_t ) a, ( int32_t ) b, ( int32_t ) ( a + b ) );
    return pdFALSE;   /* pdTRUE: call me again for more output */
}
```

Put it before the line `/* --- registration -- */`, and add to `axCommands[]` (after the
`exit` entry) the command word, its help line (ending in `\r\n`), the function and the
number of parameters (`-1` for any number):

```c
    { "add",      "add <a> <b>        Add two numbers\r\n", prvAdd, 2 },
```

Then run your shell, or check the new command with a script:

```bash
make freertos-shell APP=myshell
printf 'add 40 2\n#? ^40 \\+ 2 = 42$\nadd -5 0x10\n#? ^-5 \\+ 16 = 11$\nhalt\n' > add-test.txt
make freertos-shell-test APP=myshell SCRIPT=add-test.txt
```

`FreeRTOS_CLIGetParameter( pcCommand, n, &xLen )` returns the n-th parameter (not
terminated: use `xLen`). `shell_snprintf()` formats like `snprintf()` (`%d %u %x %s %c`,
widths, `l` and `ll`), and `shell_printf()` prints directly. Other tasks may print with
`shell_printf()` too: their complete lines never interleave with the shell's, but such a
line can appear in the middle of a command line that is being typed.

The 32 KiB image has about 1.6 KiB to spare (`mem`: 512 bytes unused, 1152 bytes of free
heap). For a larger addition, give the simulation more RAM with `RAM_KB=64`.

## 10. Settings reference

Settings are given on the `make` command line, as in `make freertos APP=stress SEED=7`.
They apply to `freertos` and `freertos-compare`, and to the shell targets of section 9
(`freertos-shell`, `freertos-shell-test`, `freertos-shell-compare`,
`freertos-shell-tty-test`). (They are deliberately ignored when they come from the
environment, so an unrelated variable such as `CPU` cannot change a run.)

| Setting | Values (default) | Meaning |
|---|---|---|
| `APP` | a name from `make freertos-list` (`minimal`) | The program. |
| `CPU` | `dut`, `golden` (`dut`) | The core to simulate. |
| `MARCH` | `rv32i`, `rv32im`, `rv32im_zba` (`rv32i`) | Instruction set the program is compiled for. Only `rv32i` runs on the golden CPU. |
| `OPT` | `-O0`, `-O2`, `-Os` (`-O2`; `-Os` for the shell) | Compiler optimisation. |
| `TICK` | clock cycles (`10000`) | Length of an RTOS tick. 50000 is 1 kHz at the board's 50 MHz. |
| `SEED` | hexadecimal, 0 to ffff (`0`) | Run seed (it drives the board's 16 switches, which the programs read). |
| `TIMEOUT` | clock cycles (per program, e.g. 50000000) | Cycle limit before `HANG`. An interactive shell session has none unless it is given. |
| `BPRED` | `0` to `3` (`0`) | Branch-predictor mode set at start-up: 0 off, 1 always taken, 2 backward taken, 3 bimodal. |
| `PREEMPT` | `0`, `1` (`1`) | `configUSE_PREEMPTION`. |
| `SLICE` | `0`, `1` (`1`) | `configUSE_TIME_SLICING`. |
| `HEAP` | `1`, `4` (`4`) | FreeRTOS heap implementation (`heap_1.c` or `heap_4.c`). |
| `RAM_KB` | KiB (per program, 32 for most) | Simulated RAM. 32 is the real board; larger values build a separate simulator. |
| `DEFS` | compiler flags | Extra `-D` definitions, e.g. `DEFS='-DTEMPLATE_ITEMS=5 -DTEMPLATE_WITH_IRQ=1'`. |
| `WAVES` | `1` | Also write a waveform, `sim.fst` (large for long runs). |
| `PTY` | `1` | `freertos-shell` only: connect the UART to a pseudo-terminal for `screen` or `picocom` instead of this terminal. |
| `SCRIPT` | a file (`test/freertos/<app>/session.txt`) | `freertos-shell-test` and `freertos-shell-compare`: the command script to type. |
| `VERBOSE` | `1` | Show the compiler output instead of writing it to `build.log`. |

For `make freertos-stress`: `SEEDS` (2), `JOBS` (4) and `SET` (`validate`).

The underlying variables (`FRTOS_APP`, `FRTOS_MARCH`, ...) and the lower-level targets
`make test/freertos/<name>`, `make frtos-elf` and `make frtos-model` are described in
`test/freertos/README.md`.

## 11. Where the files are

Everything generated is inside `$HADES_BUILD_DIR`:

| Path | Contents |
|---|---|
| `test/freertos/<name>/` | The program: `out.elf`, disassembly `out.dis`, link map `out.map`, memory image `init.mem`, `build.log`, and the run logs `run-dut.log` and `run-golden.log`. |
| `test/freertos/<name>/flags.txt` | The build configuration the program was last built with. |
| `frtos-model/dut-32k/top`, `frtos-model/ref-32k/top` | The simulators (HaDes-V+ and the golden CPU, 32 KiB RAM). |
| `frtos-model/dut-32k-console/top`, `frtos-model/ref-32k-console/top` | The console variants of the simulators, for the shell targets. |
| `test/freertos/shell/` | Besides the program: `console.log` (a copy of the UART output of the last interactive session), `pty` (the pseudo-terminal link while `PTY=1` runs), `session-dut.log` / `session-golden.log` and `session-dut.uart` / `session-golden.uart` (log and UART transcript of the last scripted session), and the scratch files of `freertos-shell-tty-test` (`tty-test-*`, `tty-hang/`). |
| `freertos-campaign/<set>/` | Stress-campaign results: `summary.md`, `results.csv`, `results.json`, `runs/.../sim.log`. |
| `ref/` | Copies of the golden-model libraries that the simulators link against. |

The FreeRTOS sources are in the repository, in `third_party/freertos/FreeRTOS-Kernel` and
`third_party/freertos/FreeRTOS/FreeRTOS/Demo` (or below `$FREERTOS_HOME` if it is set). Your
own programs are in the repository, in `test/freertos/<name>/`.

`make clean` deletes the whole build directory; the next run rebuilds everything.

## 12. Troubleshooting

**`Permission denied` (exit status 126) when a test starts.** The simulator was built on
a filesystem that cannot execute programs. Set `HADES_BUILD_DIR` (section 2.2) and run the
command again.

**`sh: 1: test/freertos/...: Permission denied`.** A script was started directly. Use the
make targets, or run scripts through `sh` or `python3`, for example
`sh test/freertos/check_rebuild.sh`.

**`FreeRTOS kernel sources not found at ...`.** `FREERTOS_HOME`, `FREERTOS_KERNEL` or
`FREERTOS_DEMO` is set to a directory without the FreeRTOS sources: unset it to use the copy
in `third_party/freertos/`. If files are missing from `third_party/freertos/` itself, restore
them with `git checkout -- third_party/freertos`.

**`Build directory ... belongs to the checkout ...`.** The build directory was created by
another copy of the repository. Use a separate `HADES_BUILD_DIR` for each copy, or delete
the old directory.

**`The golden CPU runs RV32I only`.** `CPU=golden` or `freertos-compare` was combined with
`MARCH=rv32im` or `rv32im_zba`. Leave `MARCH` unset.

**`FreeRTOS+CLI not found at ...`.** `FREERTOS_HOME` or `FREERTOS_PLUS_CLI` is set to a
directory without FreeRTOS+CLI: unset it to use the copy in `third_party/freertos/`, or
restore missing files with `git checkout -- third_party/freertos`.

**`'shell' is an interactive program that reads the UART`.** Use `make freertos-shell` or
`make freertos-shell-test` (section 9) instead of `make freertos APP=shell`.

**The terminal no longer echoes after the shell.** The simulator restores the terminal
settings on every way it can end except `kill -9`. Type `stty sane` and press Enter (the
characters are not shown while you type).

**`FREERTOS SHELL RESULT: FAIL`.** The reasons name the script line and the expectation
that was not met; the rendered transcript is in `session-dut.uart`
(`python3 test/freertos/shell/session.py check --script <script> <log> <uart>` checks it
again). `CRASH` means that the simulator ended without a result, or with an exit status
other than 0 (the reason gives it).

**`FreeRTOS program '...' not found`.** The name does not match a directory in
`test/freertos/` that contains an `app.mk`. `make freertos-list` lists the names.

**The verdict is `HANG`.** Raise the limit, for example `TIMEOUT=200000000`. If the program
still hangs, run the same command with `CPU=golden`: if the golden CPU passes, HaDes-V+
has a problem; if it hangs as well, the program does.

**`FRTOS-RESULT: FAIL ...` reasons.**

| Reason | What to do |
|---|---|
| `configASSERT [<file>] a=<line>` | A FreeRTOS assertion failed in `<file>` at line `a` (hexadecimal). |
| `stack overflow [<task>]` | Give the task a larger stack in `xTaskCreate()`. |
| `malloc failed` or `xTaskCreate failed` | Raise `configTOTAL_HEAP_SIZE` in `app_config.h`. |
| `unexpected exception (mcause, mepc) a=<cause> b=<pc>` | Look up the address `b` in `out.dis` to find the faulting instruction. Cause 2 is an illegal instruction (for example an M instruction in a program built for `rv32i`). |
| `main/ISR stack (almost) exhausted` | Raise `APP_ISR_STACK` in `app.mk`. |

**The link fails with `FreeRTOS image + heap does not fit in RAM`.** Reduce
`configTOTAL_HEAP_SIZE`, or give the simulation more RAM with `RAM_KB=64`. The simulated
RAM can grow up to 1792 KiB; beyond that it would overlap the next device, and the
simulator stops at once (verdict `CRASH`, reason `address windows overlap`).

**The build fails.** The message ends with the last 40 lines of `build.log` and its path.
`VERBOSE=1` shows the complete compiler output.

**The output appears in bursts rather than line by line.** `stdbuf` (from coreutils) is
missing; the run is otherwise unaffected.

**A waveform is needed.** Add `WAVES=1`; the path of `sim.fst` is printed with the verdict.
Open it with `gtkwave <path>/sim.fst`.

**Something looks stale.** Each program records its build configuration in `flags.txt`
and is rebuilt when it changes; the simulators are rebuilt when an RTL file changes.
`make freertos-check-rebuild` verifies the former. To start from scratch, run
`make clean`.

## 13. How the port works

* **Kernel and port.** FreeRTOS-Kernel V11.1.0+ (commit `8be86d4`), with the official
  `portable/GCC/RISC-V` port and the chip header `RISCV_MTIME_CLINT_no_extensions`. The
  standard demo tasks come from the FreeRTOS repository (commit `f4fcc3b`). Both are
  included, unmodified, in `third_party/freertos/`; its `README.md` lists every file with its
  provenance and licence (MIT).
* **Timer.** The port programs the memory-mapped machine timer: `mtime` at `0x00214004`
  and `mtimecmp` at `0x0021400C`. `mtime` counts clock cycles, so
  `configCPU_CLOCK_HZ` is `TICK × 1000` with a nominal tick rate of 1 kHz.
* **Traps.** Machine mode only. `mtvec` points to the port's trap handler in direct mode.
  External interrupts (the simulation's test interrupt source) are passed to
  `app_external_irq()`.
* **Memory.** The program is loaded at `0x40000`, the start of RAM, and runs from there.
  The top `APP_ISR_STACK` bytes of RAM are the stack of `main()` and, once the scheduler
  runs, the interrupt stack.
* **Shared files.** `test/freertos/common/` holds `FreeRTOSConfig.h`, the start-up code
  `start.S`, the linker script `hades-freertos.ld` and the helper functions
  `hades_hal.c` / `hades_hal.h`.
* **Why several CPUs and seeds.** A FreeRTOS program that boots proves little: the bugs
  that matter appear only when an interrupt meets a particular instruction in a particular
  pipeline cycle. The programs therefore randomise their interrupt timing with the seed,
  and the golden CPU decides whether a failure is a fault of the core or of the program.
