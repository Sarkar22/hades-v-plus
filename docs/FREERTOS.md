[HaDes-V+](../README.md) · [Architecture](ARCHITECTURE.md) · [Extensions](EXTENSIONS.md) · [Verification](VERIFICATION.md) · [Building](BUILDING.md) · **FreeRTOS**

# Running FreeRTOS on HaDes-V+

This guide shows how to boot FreeRTOS on the HaDes-V+ core in simulation, how to check a
run against the golden reference CPU, how to run the stress tests, and how to write and run
a FreeRTOS program of your own. Every command below can be copied as it stands. The outputs
shown are those of this version of the repository and are recorded under
[results/](../results/README.md#freertos), except the numbers of the interactive session in
section 9, which depend on the moment a key is typed, and the outputs of section 10, which
are from runs of this version that are not recorded there.

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
10. [Load and run programs on the shell](#10-load-and-run-programs-on-the-shell)
11. [Settings reference](#11-settings-reference)
12. [Where the files are](#12-where-the-files-are)
13. [Troubleshooting](#13-troubleshooting)
14. [How the port works](#14-how-the-port-works)

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
  loader     the shell with an app loader: run programs built on the host; 256 KiB, simulation only
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
[Where the files are](#12-where-the-files-are)).

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
summary. It takes about a minute once the simulators exist. The summary ends like this:

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

The result in this version of the repository is recorded run by run in
[results/freertos-validate](../results/freertos-validate/2026-10-01_03386fd/RECORD.md). The
campaign's command with `--compare` checks a re-run against it: every run must have the same
verdict, cycle count and program image (wall times are never compared). It ends with
`COMPARE RESULT: IDENTICAL`; on a difference it lists the runs that differ, ends with
`COMPARE RESULT: DIFFERENT` and exits with status 4:

```bash
python3 test/freertos/campaign.py --set validate --seeds 2 --strict --jobs 4 \
    --compare results/freertos-validate/2026-10-01_03386fd/results.csv
```

More seeds, more parallel jobs, or another set of configurations:

```bash
make freertos-stress SEEDS=8 JOBS=6
```

`SET=standard` runs 55 configurations of all programs, including the M and Zba builds
(checked by the programs' own self-checks, since the golden CPU cannot run them) and the
full FreeRTOS demo; `SET=bpred` runs the programs with the branch predictor on. See
`test/freertos/README.md` for all sets.

`campaign.py` also runs *suites*: several sets, each with its own seeds and run length, in
one pool of parallel simulations. The suite `sep2026` is the final campaign on the fixed
core, run on 2026-09-27: 794 runs on HaDes-V+ and 523 on the golden CPU, quoted in
[VERIFICATION.md](VERIFICATION.md#freertos-differential-campaigns). Its re-run is recorded
in [results/freertos-campaign](../results/freertos-campaign/2026-10-01_03386fd/RECORD.md); it
takes about 80 minutes with 12 parallel simulations:

```bash
python3 test/freertos/campaign.py --suite sep2026 --list      # its runs
python3 test/freertos/campaign.py --suite sep2026 --jobs 12 --wall-limit 0 \
    --compare results/freertos-campaign/2026-10-01_03386fd/results.csv
```

`--wall-limit 0` lifts the per-run wall-clock limit, which on a busy machine could stop a
long run. `--record DIR` writes the record of a campaign into a new directory, by
convention `results/<topic>/<date>_<commit>/` ([results/README.md](../results/README.md)).
All options are described in
[test/freertos/README.md](../test/freertos/README.md#differential-campaign).

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

The first run builds the shell and a console variant of the simulator (up to a minute).
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

The simulation runs at about 1.6 to 1.9 million clock cycles per second on a current PC
(less when the machine is busy),
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

**Ending a PTY-mode session.** A detached session keeps running, as a board stays powered
when its serial cable is unplugged, and in this mode the simulation has no cycle limit
(`TIMEOUT=` sets one). End it in one of these ways:

* attach again (`screen -r`, or `screen` on the link as above), then type `halt` and press
  Enter, or press Ctrl-];
* press Ctrl-C in the first terminal, or close that terminal window;
* from any terminal, end the simulator itself:

  ```bash
  pgrep -af console_pty_link     # list the PTY-mode simulators that are running
  pkill -f console_pty_link      # end them
  ```

Each of these ends the simulation and removes the link `pty` (after `pkill`, `make` reports
`Terminated`). A session started under `nohup`, or by a program that runs `make` in a
pseudo-terminal of its own, as a test harness does, keeps running when that terminal
closes; end it with `halt` or `pkill` as above.

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
`freertos-shell-tty-test` take the settings of section [11](#11-settings-reference), with
these differences:

* `APP` defaults to `shell`. Another program that reads the UART (`APP_CONSOLE := 1` in its
  `app.mk`) can use the same targets, as the loader configuration of section 10 does.
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

## 10. Load and run programs on the shell

The shell has a second configuration, `loader`, which runs programs that you compile on the
host: an *app* is built with the project's GCC and the SDK in `test/freertos/sdk/`, sent to
the running shell over the UART as an Intel HEX file, stored in a reserved RAM area, the
*app slot*, and run as a FreeRTOS task. The shell stays alive: Ctrl-C stops a running app,
and an app that raises an exception is stopped and reported while the shell carries on.

It is opt-in and runs in simulation only. The board's 32 KiB of RAM are full with the shell,
so the loader configuration runs on a simulated RAM of 256 KiB: the first 128 KiB hold the
shell, the other 128 KiB the app slot. `make freertos-shell` without `APP=loader`, and every
other program, are not affected. The complete specification (image format, load protocol,
console pacing, run semantics, test plan) is
[test/freertos/loader/SPEC.md](../test/freertos/loader/SPEC.md).

### Start it and run an example

```bash
make freertos-shell APP=loader UPLOAD=hello
```

This builds the shell with the loader, the 256 KiB console simulator and the example apps,
and starts the simulation as in section 9. `UPLOAD=hello` names the file that the simulator
sends whenever the shell asks for one: type `load`, then run the app with `run` and its
arguments (a session on HaDes-V+):

```text
HaDes-V+ shell on FreeRTOS V11.1.0+ with FreeRTOS+CLI
  config: tick=10000cyc preempt=1 slice=1 heap_4 isa=rv32i opt=-Os ram=256K bpred=0
  apps: 'load' receives an app into the 128 KiB slot at 0x00060000, 'run' runs it
Type 'help' for the list of commands.
hades> load
load: waiting for an Intel HEX file (Ctrl-C cancels)
[console] sending .../test/freertos/sdk/rv32i/hello.hex (1017 bytes)
loaded hello: 340 bytes at 0x00060000, entry 0x00060040, CRC32 0xbccb2e01
hades> run world
Hello, world!
argv[0] = hello
argv[1] = world
app: hello exited with code 1 after 37150 cycles
hades> app
name:      hello (ABI 1)
image:     340 bytes at 0x00060000, entry 0x00060040, CRC32 0xbccb2e01
isa:       rv32i
memory:    image 340 + bss 4 + stack 4096 + saved copy 352 = 4792 of 131072 bytes
hades> halt
halted
```

The file is read at every `load`, so an app rebuilt in another terminal while the simulation
runs is sent the next time. `UPLOAD` takes the name of an app (its RV32I build),
`<march>/<name>` for another build, for example `UPLOAD=rv32im_zba/compute`, or the path of a
`.hex` file. Every other command of section 9 works as before.

The example apps, in `test/freertos/sdk/apps/`, are built for RV32I (`compute` also for
`rv32im_zba`):

| App | What it does |
|---|---|
| `hello` | Prints `Hello, <argv[1]>!` and its arguments; the exit code is the number of arguments. |
| `compute` | Matrix arithmetic with multiplication, division and scaled indexing (M and Zba when built for them), checked against constants computed by a Python model (`model.py`); prints `PASS` and its cycle count. |
| `selfmod` | Writes instructions into its memory, executes `fence.i` and runs them; then rewrites the same words and runs them again. |
| `upper` | Reads lines from the terminal and prints them in upper case; an empty line ends it. |
| `crash` | Ends in the way its argument names: `illegal` (the default), `ebreak`, `misaligned`, `load`, `store` (access faults), `null` (a call through a null pointer), `stack` (endless recursion), `deep` (a stack overflow without a task switch, then a normal return), `loop` (spins until Ctrl-C, after waiting for input once), `spin` (spins without ever reading input). |

### Send the file: terminal, pseudo-terminal, script

The shell asks for a file when you type `load`, and the simulator's console bridge
(`sim/console.cpp`) sends it one line at a time: the next line only after the shell has
acknowledged the previous one, so no character is lost however long the file is. There is no
key or escape sequence to start an upload: `load` starts it, from whichever side.

| Mode | How the file is sent |
|---|---|
| Terminal (`make freertos-shell APP=loader`) | With `UPLOAD=<app>`, every `load` receives that app's file. Without it, type `load` and paste the contents of the `.hex` file into the terminal. |
| Pseudo-terminal (`PTY=1`) | In another terminal: `make freertos-send UPLOAD=<app>`. It builds the app if needed and asks the simulator to type `load` and send the file, which it does only while the shell waits at its prompt with nothing typed (after a `load` typed by hand, it sends the file to that `load`). `UPLOAD=` on the `freertos-shell` command line works as well. |
| Scripted session (`freertos-shell-test`) | A line `#< <file>` after the typed `load` line sends that file, relative to the SDK's build directory (`#< rv32i/hello.hex`); `#: <text>` types a line into a running app. |

A session in the pseudo-terminal mode takes three terminals:

```bash
make freertos-shell APP=loader PTY=1                   # 1: the simulation
screen ${HADES_BUILD_DIR:-build}/test/freertos/loader/pty   # 2: the shell's console (press Enter)
make freertos-send UPLOAD=hello                        # 3: at the prompt of terminal 2
```

```text
send: 'load' and .../test/freertos/sdk/rv32i/hello.hex (1017 bytes) -> .../test/freertos/loader/pty
```

The shell's answer, `loaded hello: ...`, appears in `screen`; type `run` there. When the shell
is busy (a command or an app is running) or something is typed on its command line, nothing
is sent, and `make freertos-send` fails with the reason:

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

### The commands

| Command | What it does |
|---|---|
| `load` | Unloads the current app, clears the slot, prints `load: waiting for an Intel HEX file (Ctrl-C cancels)` and receives the file. Every record is checked (checksum, address inside the slot, contiguous from the slot base) before its bytes are written; at the end the image is checked (magic `HAPP`, ABI version, sizes, entry, the room it needs in the slot, CRC-32), saved and made executable (`fence.i`). One line reports the result: `loaded <name>: ...`, `load failed: <reason>` or `load cancelled`. After a failed or cancelled load no app is loaded, so nothing of an older image can be run. A Ctrl-C after a rejected line gives that line's error rather than `load cancelled`. A `.` is printed for every KiB of image stored in the slot. |
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
```

`python3 test/freertos/sdk/appimg.py info <file.hex>` applies the same checks on the host
and prints the line `load` would print.

### Write and build an app

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
make freertos-shell APP=loader UPLOAD=myapp
```

`make freertos-app` prints one line with the sizes, the CRC-32 and the file it wrote:

```text
app myapp [rv32i -O2]: image 292 bytes, bss 4, stack 4096, CRC32 0x6496e1cd -> .../test/freertos/sdk/rv32i/myapp.hex
```

It compiles with `-ffunction-sections -fdata-sections`, links with the SDK's start-up code
(`crt0.S`, which writes the 64-byte image header and clears `.bss`) and linker script
(`app.ld`, which places the app at the slot base, `0x00060000`), and writes the image and its
HEX file. `make freertos-apps` builds every example and the loader's test files, at `-O2`.
`UPLOAD=myapp` (with `freertos-shell` or `freertos-send`) rebuilds the app when its sources
have changed, at the optimisation level of its last build, so it sends the build that
`make freertos-app` made. Then:

```text
hades> load
load: waiting for an Intel HEX file (Ctrl-C cancels)
[console] sending .../test/freertos/sdk/rv32i/myapp.hex (882 bytes)
loaded myapp: 292 bytes at 0x00060000, entry 0x00060040, CRC32 0x6496e1cd
hades> run Ada Bob
myapp: the first characters of the arguments add up to 131
app: myapp exited with code 2 after 39369 cycles
```

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

### Memory layout

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

### What is contained, and what is not

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

### The tests

```bash
make freertos-loader-test                # loader/session.txt and session-ext.txt on HaDes-V+
make freertos-loader-test CPU=golden     # the same on the golden CPU
make freertos-loader-compare             # both CPUs; the transcripts of session.txt compared
make freertos-shell-tty-test APP=loader  # uploads, pastes, send requests, input and Ctrl-C through a terminal
```

`test/freertos/loader/session.txt` loads and runs every example app (`hello` with arguments,
`compute` twice, `selfmod`, `upper` with typed input), ends `crash` in each of its ten ways
(each exception, a stack overflow found at a task switch and one found only as the app
returns, Ctrl-C in its loop, and Ctrl-C typed right after the Enter of `run`) and runs another
app afterwards, sends every rejected test file of SPEC.md, section 9.5 (after a successful load
of a valid image, so that the check that nothing runs is meaningful) and the files that hold a
Ctrl-C, empty lines or records after their end, and checks that `uart` lost no character. `session-ext.txt` runs `compute` built for `rv32im_zba`, which the golden CPU
refuses. The verdict:

```text
LOADER COMPARE: PASS  session.txt: dut PASS, golden PASS, transcripts SAME; session-ext.txt: dut PASS, golden PASS
```

after the verdict line of each session (`FREERTOS SHELL RESULT: PASS ... expectations met:
131/131`) and the comparison (`SHELL COMPARE: SAME  75 blocks, 261 lines equal after
normalising numbers`). `make` exits with status 0 only if every part passed. The logs are
`session-<cpu>.log` and `session-ext-<cpu>.log` (with the UART transcripts `.uart`) in
`${HADES_BUILD_DIR:-build}/test/freertos/loader/`.

### Settings

`APP=loader` takes the settings of the shell targets (section 9), except `RAM_KB`, which is
fixed at 256. `OPT` defaults to `-Os` (every level fits the shell's 128 KiB); `MARCH`, `BPRED`
and `TICK` apply to the shell, not to the apps, which `make freertos-app` builds with its own
`MARCH` and `OPT`. A scripted session has a limit of 300 million cycles. `UPLOAD=<app>`
applies to `make freertos-shell APP=loader` (without `APP=loader`, `make` stops with an
error) and to `make freertos-send`.

## 11. Settings reference

Settings are given on the `make` command line, as in `make freertos APP=stress SEED=7`.
They apply to `freertos` and `freertos-compare`, to the shell targets of section 9
(`freertos-shell`, `freertos-shell-test`, `freertos-shell-compare`,
`freertos-shell-tty-test`), and to the loader's targets of section 10. (They are deliberately ignored when they come from the
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
| `UPLOAD` | an app: `<name>`, `<march>/<name>` or a `.hex` file | `freertos-shell APP=loader`: the file sent whenever `load` asks for one; `freertos-send`: the file to send (section 10). |
| `VERBOSE` | `1` | Show the compiler output instead of writing it to `build.log`. |

For `make freertos-stress`: `SEEDS` (2), `JOBS` (4) and `SET` (`validate`). `campaign.py`
itself takes further options, among them `--suite`, `--compare` and `--record` (section 6;
all of them in [test/freertos/README.md](../test/freertos/README.md#differential-campaign)).

The underlying variables (`FRTOS_APP`, `FRTOS_MARCH`, ...) and the lower-level targets
`make test/freertos/<name>`, `make frtos-elf` and `make frtos-model` are described in
`test/freertos/README.md`.

## 12. Where the files are

Everything generated is inside `$HADES_BUILD_DIR`:

| Path | Contents |
|---|---|
| `test/freertos/<name>/` | The program: `out.elf`, disassembly `out.dis`, link map `out.map`, memory image `init.mem`, `build.log`, and the run logs `run-dut.log` and `run-golden.log`. |
| `test/freertos/<name>/flags.txt` | The build configuration the program was last built with. |
| `frtos-model/dut-32k/top`, `frtos-model/ref-32k/top` | The simulators (HaDes-V+ and the golden CPU, 32 KiB RAM). |
| `frtos-model/dut-32k-console/top`, `frtos-model/ref-32k-console/top` | The console variants of the simulators, for the shell targets. |
| `test/freertos/shell/` | Besides the program: `console.log` (a copy of the UART output of the last interactive session), `pty` (the pseudo-terminal link while `PTY=1` runs), `session-dut.log` / `session-golden.log` and `session-dut.uart` / `session-golden.uart` (log and UART transcript of the last scripted session), and the scratch files of `freertos-shell-tty-test` (`tty-test-*`, `tty-hang/`). |
| `test/freertos/loader/` | The loader configuration (section 10): as for the shell, and the logs of `freertos-loader-test` (`session-ext-<cpu>.log`, `.uart`), the link `pty` while `PTY=1` runs, and the scratch files of its interactive test (`tty-test-*`). |
| `test/freertos/sdk/` | The apps (section 10): `<march>/<name>.hex` (the file to send), `.bin` (the image), `.elf`, `.dis`, `.map` and `obj/<name>/`; `testfiles/` (the loader's test files); `build.log`. |
| `frtos-model/dut-256k-console/top`, `frtos-model/ref-256k-console/top` | The console simulators with 256 KiB of RAM, for the loader. |
| `freertos-campaign/<set>/` | Stress-campaign results: `summary.md`, `results.csv`, `results.json`, `runs/.../sim.log`. |
| `ref/` | Copies of the golden-model libraries that the simulators link against. |

The FreeRTOS sources are in the repository, in `third_party/freertos/FreeRTOS-Kernel` and
`third_party/freertos/FreeRTOS/FreeRTOS/Demo` (or below `$FREERTOS_HOME` if it is set). Your
own programs are in the repository, in `test/freertos/<name>/`.

`make clean` deletes the whole build directory; the next run rebuilds everything.

## 13. Troubleshooting

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

**`load failed: <reason>`.** The file is not an app image that the loader accepts; the
reason names the line or the field. `python3 test/freertos/sdk/appimg.py info <file>` gives
the same reason on the host. A file written by `objcopy -O ihex` is refused (`record type 02
is not supported`): send the `.hex` file that `make freertos-app` writes.

**`load` waits and nothing arrives.** In the terminal mode without `UPLOAD=`, the simulator
prints a hint: paste the file, or press Ctrl-C and restart with `UPLOAD=<app>`. In the
pseudo-terminal mode, run `make freertos-send UPLOAD=<app>` in another terminal: it sends the
file to the waiting `load`. It fails with `no loader session with a pseudo-terminal is
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
(section 10).

**`undefined reference to '_read'` (or `_lseek`, `_write`, `_sbrk`, ...) when an app is
linked.** The app calls a `stdio` function such as `printf` or `puts`, or `malloc`; apps have
neither. Use `app_printf` and the other functions of `hades_app.h`, and the memory between
`__app_heap_start` and `__app_heap_end`.

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

## 14. How the port works

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
