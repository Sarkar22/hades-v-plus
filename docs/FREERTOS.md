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
9. [Settings reference](#9-settings-reference)
10. [Where the files are](#10-where-the-files-are)
11. [Troubleshooting](#11-troubleshooting)
12. [How the port works](#12-how-the-port-works)

## 1. Prerequisites

| Tool | Tested version | Check |
|---|---|---|
| GNU make, a POSIX shell, coreutils | any recent Linux | `make --version` |
| Verilator | 5.042 | `verilator --version` |
| RISC-V GCC with newlib-nano, in `/opt/riscv32i/bin` | GCC 12.2.0, binutils 2.39 | see below |
| git | 2.43 (2.25 or newer is needed) | `git --version` |
| Python 3 | 3.12 (3.8 or newer) | `python3 --version` |
| Network access to github.com | for the one-time download of FreeRTOS | |
| Free disk space | about 100 MB: FreeRTOS sources 50 MB, builds 30 MB and more | `df -h .` |

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

### 2.1 Download FreeRTOS

The FreeRTOS sources are not part of this repository. Download them once, at the exact
commits that were tested:

```bash
make freertos-fetch
```

By default they are placed in the repository's parent directory. To keep them somewhere
else, set `FREERTOS_HOME` first and keep it set for later commands, for example
`export FREERTOS_HOME=$HOME/freertos`.

The last lines of the output confirm the two commits:

```text
FreeRTOS sources ready in <FREERTOS_HOME>:
  FreeRTOS-Kernel  8be86d4a24fd4091f8f4192018423ab590f408db
  FreeRTOS (demo)  f4fcc3b228643144727e9257ba12db1cb632b6e6
```

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
`FREERTOS_HOME` set if you moved the FreeRTOS sources and `HADES_BUILD_DIR` set if your
filesystem needs it.

## 3. Boot FreeRTOS

List the FreeRTOS programs:

```bash
make freertos-list
```

```text
FreeRTOS programs (make freertos APP=<name>):
  brk        RTOS-level breaker: interrupt storms, tick catch-up, task churn, fence.i, deliberate exceptions; 64 KiB
  full       the FreeRTOS standard demo task set (official RISC-V QEMU full_demo) + RegTest; 256 KiB, simulation only
  minimal    two application tasks + idle (notification ping-pong, idle progress, tick drift); 32 KiB
  mzba       M and Zba code under the RTOS, checked against an rv32i software build of the same code; 32 KiB
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
[Where the files are](#10-where-the-files-are)).

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

## 9. Settings reference

Settings are given on the `make` command line, as in `make freertos APP=stress SEED=7`.
They apply to `freertos` and `freertos-compare`. (They are deliberately ignored when they
come from the environment, so an unrelated variable such as `CPU` cannot change a run.)

| Setting | Values (default) | Meaning |
|---|---|---|
| `APP` | a name from `make freertos-list` (`minimal`) | The program. |
| `CPU` | `dut`, `golden` (`dut`) | The core to simulate. |
| `MARCH` | `rv32i`, `rv32im`, `rv32im_zba` (`rv32i`) | Instruction set the program is compiled for. Only `rv32i` runs on the golden CPU. |
| `OPT` | `-O0`, `-O2`, `-Os` (`-O2`) | Compiler optimisation. |
| `TICK` | clock cycles (`10000`) | Length of an RTOS tick. 50000 is 1 kHz at the board's 50 MHz. |
| `SEED` | hexadecimal, 0 to ffff (`0`) | Run seed (it drives the board's 16 switches, which the programs read). |
| `TIMEOUT` | clock cycles (per program, e.g. 50000000) | Cycle limit before `HANG`. |
| `BPRED` | `0` to `3` (`0`) | Branch-predictor mode set at start-up: 0 off, 1 always taken, 2 backward taken, 3 bimodal. |
| `PREEMPT` | `0`, `1` (`1`) | `configUSE_PREEMPTION`. |
| `SLICE` | `0`, `1` (`1`) | `configUSE_TIME_SLICING`. |
| `HEAP` | `1`, `4` (`4`) | FreeRTOS heap implementation (`heap_1.c` or `heap_4.c`). |
| `RAM_KB` | KiB (per program, 32 for most) | Simulated RAM. 32 is the real board; larger values build a separate simulator. |
| `DEFS` | compiler flags | Extra `-D` definitions, e.g. `DEFS='-DTEMPLATE_ITEMS=5 -DTEMPLATE_WITH_IRQ=1'`. |
| `WAVES` | `1` | Also write a waveform, `sim.fst` (large for long runs). |
| `VERBOSE` | `1` | Show the compiler output instead of writing it to `build.log`. |

For `make freertos-stress`: `SEEDS` (2), `JOBS` (4) and `SET` (`validate`).

The underlying variables (`FRTOS_APP`, `FRTOS_MARCH`, ...) and the lower-level targets
`make test/freertos/<name>`, `make frtos-elf` and `make frtos-model` are described in
`test/freertos/README.md`.

## 10. Where the files are

Everything generated is inside `$HADES_BUILD_DIR`:

| Path | Contents |
|---|---|
| `test/freertos/<name>/` | The program: `out.elf`, disassembly `out.dis`, link map `out.map`, memory image `init.mem`, `build.log`, and the run logs `run-dut.log` and `run-golden.log`. |
| `test/freertos/<name>/flags.txt` | The build configuration the program was last built with. |
| `frtos-model/dut-32k/top`, `frtos-model/ref-32k/top` | The simulators (HaDes-V+ and the golden CPU, 32 KiB RAM). |
| `freertos-campaign/<set>/` | Stress-campaign results: `summary.md`, `results.csv`, `results.json`, `runs/.../sim.log`. |
| `ref/` | Copies of the golden-model libraries that the simulators link against. |

The FreeRTOS sources are in `$FREERTOS_HOME/FreeRTOS-Kernel` and
`$FREERTOS_HOME/FreeRTOS/FreeRTOS/Demo`. Your own programs are in the repository, in
`test/freertos/<name>/`.

`make clean` deletes the whole build directory; the next run rebuilds everything.

## 11. Troubleshooting

**`Permission denied` (exit status 126) when a test starts.** The simulator was built on
a filesystem that cannot execute programs. Set `HADES_BUILD_DIR` (section 2.2) and run the
command again.

**`sh: 1: test/freertos/...: Permission denied`.** A script was started directly. Use the
make targets, or run scripts through `sh` or `python3`, for example
`sh test/freertos/fetch_freertos.sh $FREERTOS_HOME`.

**`FreeRTOS kernel sources not found at ...`.** `FREERTOS_HOME` is not set in this
terminal, or `make freertos-fetch` has not been run. Without `FREERTOS_HOME` the Makefile
looks next to the repository.

**`make freertos-fetch` fails.** It needs network access to github.com. Behind a proxy,
set `https_proxy`. It can be re-run at any time; it reuses existing clones.

**`Build directory ... belongs to the checkout ...`.** The build directory was created by
another copy of the repository. Use a separate `HADES_BUILD_DIR` for each copy, or delete
the old directory.

**`The golden CPU runs RV32I only`.** `CPU=golden` or `freertos-compare` was combined with
`MARCH=rv32im` or `rv32im_zba`. Leave `MARCH` unset.

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

## 12. How the port works

* **Kernel and port.** FreeRTOS-Kernel V11.1.0+ (commit `8be86d4`), with the official
  `portable/GCC/RISC-V` port and the chip header `RISCV_MTIME_CLINT_no_extensions`. The
  standard demo tasks come from the FreeRTOS repository (commit `f4fcc3b`). Nothing in
  either is modified; `make freertos-fetch` downloads them.
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
