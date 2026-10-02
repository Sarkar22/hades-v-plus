# FreeRTOS on HaDes-V+: programs and differential stress campaign

A passing FreeRTOS demo proves little: interrupt bugs only show when an
interrupt meets an ECALL, a `csrc mstatus` or a divide at one particular
pipeline cycle. These programs randomise that timing per run, and
`campaign.py` runs every build on the DUT *and* on the golden reference CPU
(`ref/*.so`), so a difference between them is a DUT bug, not a flaky test.

**Start with the user guide, [docs/FREERTOS.md](../../docs/FREERTOS.md):** setup
(including a build directory outside a disk that cannot execute programs), booting a
program, comparing with the golden CPU, the stress campaign, and writing your own program
from [template/](template/); the interactive shell and its app loader have guides of their
own, [docs/SHELL.md](../../docs/SHELL.md) and [docs/APPS.md](../../docs/APPS.md). This file
documents the programs and the campaign in depth.
Their results in this version of the repository are recorded in
[results/tests](../../results/tests/2026-10-01_03386fd/RECORD.md) and in the campaign records
named under [Differential campaign](#differential-campaign).

## Setup

The FreeRTOS sources are vendored, unmodified, in
[`third_party/freertos/`](../../third_party/freertos/README.md): FreeRTOS-Kernel `8be86d4`
(V11.1.0+) and, from FreeRTOS/FreeRTOS `f4fcc3b`, the standard demo tasks, RegTest and
FreeRTOS+CLI. There is nothing to fetch: the Makefile and `campaign.py` use them by default.
To build against an external checkout instead, set `FREERTOS_HOME` (a directory holding
`FreeRTOS-Kernel/` and `FreeRTOS/` side by side), or `FREERTOS_KERNEL` / `FREERTOS_DEMO`
(for `campaign.py` also `--kernel` / `--demo`). All build output follows `BUILD_DIR` /
`HADES_BUILD_DIR` (see docs/FREERTOS.md); the paths below assume the default `build/`.

## Front end

```bash
make freertos-list                               # the programs
make freertos APP=stress SEED=2a                 # build + run, UART streamed, one verdict line
make freertos APP=stress CPU=golden              # the same on the golden CPU (rv32i only)
make freertos-compare APP=stress BPRED=3         # DUT and golden, verdicts compared
make freertos-stress SEEDS=8 JOBS=6              # campaign.py --set validate --strict
make freertos-new NAME=myapp                     # copy template/ to myapp/
make freertos-new NAME=mysh FROM=shell           # copy shell/ (its sources and session.txt) to mysh/
make freertos-check-rebuild                      # check_rebuild.sh
make freertos-shell                              # the shell, typed into from this terminal (Ctrl-] quits)
make freertos-shell PTY=1                        # the same on a pseudo-terminal, for screen/picocom
make freertos-shell-test [SCRIPT=file]           # shell/session.txt typed in, transcript checked
make freertos-shell-compare                      # the scripted session on DUT and golden, compared
make freertos-shell-tty-test                     # shell/tty_test.py: keys, paste, quitting, terminal restore
make freertos-shell APP=loader                   # the shell with the app loader: 'load hello', then 'run'
make freertos-shell APP=loader UPLOAD=hello      # the same; 'load' without a name receives sdk/apps/hello
make freertos-send UPLOAD=hello                  # to a running 'make freertos-shell APP=loader PTY=1'
make freertos-app NAME=hello [MARCH=] [OPT=]     # build one app of sdk/apps/; freertos-apps: all of them
make freertos-loader-test [CPU=golden]           # loader/session.txt and session-ext.txt, one verdict
make freertos-loader-compare                     # both on DUT and golden, session.txt compared
make freertos-shell-tty-test APP=loader          # loader/tty_test.py: names, uploads, pastes, send requests, input, Ctrl-C
```

The short knobs (`APP CPU MARCH OPT TICK SEED TIMEOUT BPRED PREEMPT SLICE HEAP DEFS
RAM_KB PTY SCRIPT UPLOAD`) are command-line aliases of the `FRTOS_*` variables below; `run.sh`
prints the verdict (`PASS`/`FAIL`/`HANG`/`CRASH`, exit status 0 only for `PASS`), applying
the same UART-transcript check as the campaign.

## One program, one configuration

```bash
make test/freertos/stress                                   # rv32i -O2, 10000-cycle tick, DUT
make test/freertos/stress FRTOS_CPU=ref FRTOS_SEED=2a       # same on the golden CPU, seed 0x2a
make test/freertos/mzba FRTOS_MARCH=rv32im_zba FRTOS_OPT=-Os
make frtos-elf FRTOS_APP=full FRTOS_OUT=build/full          # build only
```

| knob | meaning (default) |
|---|---|
| `FRTOS_APP` | `minimal`, `stress`, `full`, `mzba`, `brk`, `shell`, `loader`, `template`, or your own |
| `FRTOS_MARCH` | `rv32i`, `rv32im`, `rv32im_zba` (`rv32i`) |
| `FRTOS_OPT` | `-O0`, `-O2`, `-Os` (`-O2`) |
| `FRTOS_PREEMPT` / `FRTOS_SLICE` | `configUSE_PREEMPTION` / `configUSE_TIME_SLICING` (1/1) |
| `FRTOS_TICK` | CPU cycles per RTOS tick (10000; 50000 = 1 kHz at 50 MHz) |
| `FRTOS_HEAP` | `1` or `4` (heap_1.c / heap_4.c) (4) |
| `FRTOS_RAM_KB` | RAM size; 32 = the board. Larger values build a simulator with `+define+HADES_MEMORY_SIZE_WORDS` (per program) |
| `FRTOS_SEED` | run seed, drives `+switches=<hex>` (0) |
| `FRTOS_CPU` | `dut` or `ref`/`golden` (golden) simulator (`dut`); the golden CPU runs `rv32i` builds only |
| `FRTOS_DEFS` | extra `-D` flags, e.g. `-DSTRESS_CRIT_YIELD=0` |
| `FRTOS_BPRED` | branch-predictor mode written to MHPMEVENT10 at start-up: 0 off, 1 always-taken, 2 backward-taken, 3 bimodal (0). The golden CPU reads this CSR as 0 and ignores writes, so it stays a valid twin |
| `FRTOS_PTY` | `freertos-shell`: `1` connects the UART to a pseudo-terminal (link `<out>/pty`) instead of this terminal |
| `FRTOS_SCRIPT` | `freertos-shell-test`/`-compare`: the command script (`test/freertos/<app>/session.txt`) |
| `FRTOS_UPLOAD` | `freertos-shell` (loader) and `freertos-send`: the app file sent when `load` asks for one (`<name>`, `<march>/<name>` or a `.hex` file) |

The output directory (`build/test/freertos/<app>`, or `FRTOS_OUT`) is reused
across configurations: `freertos.mk` records the compiler/linker flags of the
last build in `flags.txt` and rebuilds everything when any knob changes, before
the run. (It used to notice the change one invocation late, so the first run
after changing e.g. `FRTOS_TICK` or `FRTOS_BPRED` silently ran the previous
ELF.) `test/freertos/check_rebuild.sh` is the regression test: it runs
`minimal` eight times in a scratch directory, changing one knob at a time, and
checks from each run's start-up banner (`config: tick=... isa=... opt=...
bpred=...`) that the very next run used the new build, and that an unchanged
configuration is not rebuilt (15-30 s; prints `REBUILD CHECK: PASS`).

Every program prints exactly one `FRTOS-RESULT: PASS` or
`FRTOS-RESULT: FAIL <reason>` line and uses the usual test-register protocol,
so a pass ends in `All tests passed! (# Errors: 1 = initial test)`. Failures
are loud: `configASSERT`, stack overflow (`configCHECK_FOR_STACK_OVERFLOW=2`),
malloc failure, unexpected exceptions/interrupts, and each program's own
checks all end the run at once.

## Programs

* **shell** -- an interactive command shell (32 KiB, built with `-Os`; 64 KiB at other
  levels): FreeRTOS+CLI on the UART, fed by the UART receive interrupt through a queue.
  Commands: `help`, `version`, `tasks`, `stats` (run-time statistics with `mcycle` as the
  clock), `mem`, `uptime`, `counters`, `bpred [0-3|reset]` (MHPMEVENT10 and
  MHPMCOUNTER10-13), `mul`, `div`, `zba` (the CPU's own M/Zba instructions where it has
  them, compared with the rv32i software model `swmodel.c`), `uart`, `echo`,
  `halt`/`exit`. Its `app.mk` sets `APP_CONSOLE := 1`: it runs only under the console
  targets (`make freertos APP=shell` refuses), on the simulator variant
  `frtos-model/<cpu>-<n>k-console` (`+define+HADES_CONSOLE`, `sim/console.cpp`). Guide:
  docs/SHELL.md. `session.txt` is the scripted session (39 lines, 120
  expectations on the DUT, 121 on the golden CPU), `session.py` runs and checks it (a
  non-zero exit status of the simulator is a `CRASH`) and compares the DUT and golden
  transcripts, `tty_test.py` drives the interactive console through a pseudo-terminal
  (keys, paste, quitting, a hung program, signals, terminal restore, the UART copy). Not
  part of any campaign set.
* **loader** -- the shell with an app loader (256 KiB, simulation only; `-Os`): the shell's
  own sources compiled with `SHELL_LOADER=1`, plus `loader/loader.c`, which adds the
  commands `load` (an Intel HEX file over the UART into the 128 KiB app slot at
  `0x00060000`), `run [args...]` (the app as a FreeRTOS task at priority 1; Ctrl-C stops
  it; an exception or a stack overflow in it is reported and the shell carries on) and
  `app`. The shell is linked for the first 128 KiB (`APP_LINK_KB`). Apps are built on the
  host with the SDK in `sdk/` (`hades_app.h`, `crt0.S`, `app.ld`, `appimg.py`, `sdk.mk`;
  examples in `sdk/apps/`); the console bridge sends a file when the program asks for
  one (control bytes DC2, ACK/NAK per line, DC1 for app input), and `make freertos-send`
  asks it to, through a send request next to the pseudo-terminal's link. Guide: docs/APPS.md;
  specification: `loader/SPEC.md`. `session.txt` (83 lines, 146 expectations)
  and `session-ext.txt` (the `rv32im_zba` build of `compute`) are its scripted sessions,
  `tty_test.py` its interactive test. Its `app.mk` uses the console-target knobs
  `APP_CONSOLE_DEPS` (goals built before a console run: `freertos-apps`),
  `APP_CONSOLE_ARGS` (simulator arguments), `APP_TTY_TEST` and `APP_TTY_ARGS` (the script of
  `freertos-shell-tty-test`); every other program leaves them empty and builds exactly as
  before. Not part of any campaign set.
* **template** -- the starting point for your own program (`make freertos-new
  NAME=<name>`): producer -> queue -> consumer, PASS after `TEMPLATE_ITEMS` items;
  `-DTEMPLATE_WITH_IRQ=1` adds an interrupt handler fed by the `wishbone_test`
  interrupt. Its `app.mk` builds every `.c`/`.S` file in the program's directory
  (`APP_DIR`), so a copy needs no edits. Not part of any campaign set.
* **minimal** -- 2 tasks + idle (32 KiB). Notification ping-pong, idle
  progress, tick drift.
* **stress** -- 32 KiB at `-O2`/`-Os` (64 KiB at `-O0`). Official port RegTest
  tasks + RegTest3 (also checks `ra` and MIE=1); a queue with a low-priority
  producer and a high-priority consumer and one the other way round; a counting
  semaphore and task notifications fed from the `wishbone_test` interrupt,
  re-armed from its own ISR with seed-dependent random delays; two tasks that
  check `mstatus.MIE=0` inside critical sections, `taskYIELD()` inside them
  (`STRESS_CRIT_YIELD`, default 1) and toggle `csrc/csrs mstatus` in tight
  loops; ISR/semaphore/notification accounting and tick drift against `mtime`;
  an idle hook (`STRESS_SLOWBUS`, default 1) that writes and reads back a VGA
  frame-buffer word and the `wishbone_test` stall register (2- to 4-cycle bus
  accesses) and checks `mstatus.MIE=1`, so interrupts also land while Memory
  waits for a slow peripheral.
  A blocking call with `portMAX_DELAY` that returns empty-handed is a failure
  (it can only happen when the blocking ECALL was lost).
* **full** -- the FreeRTOS standard demo set used by the official RISC-V QEMU
  `full_demo` (blocktim, dynamic, GenQTest, recmutex, TimerDemo,
  EventGroupsDemo, TaskNotify, AbortDelay, countsem, MessageBufferDemo,
  StreamBufferDemo, StreamBufferInterrupt, QueueOverwrite, QueueSet, semtest,
  BlockQ, PollQ, IntSemTest, RegTest) with their tick-hook ISR halves, plus a
  random external interrupt. The check task fails the run on the first
  `xAre...StillRunning() != pdTRUE` or stalled RegTest counter. 256 KiB RAM
  (512 KiB at `-O0`); three 5000-tick check periods. The campaign runs it with time
  slicing on only, like the official demo: with `configUSE_TIME_SLICING=0`
  the demo's priority-0 tasks (semtest polling pair, MessageBuffer
  non-blocking/coherence tasks) can starve for a whole check period or trip
  MessageBufferDemo's coherence assert, and the golden CPU failed 3 of 12
  seeds that way ([record](../../results/history/2026-09-27_97ef211/RECORD.md)).
  MessageBufferDemo's "space available coherence" sub-test
  (`configRUN_ADDITIONAL_TESTS`, on in the official demo) is off: it trips on
  an ABA race in `xStreamBufferSpacesAvailable()` that any CPU can hit (see
  `full/app_config.h`).
* **mzba** -- M and Zba under the RTOS. `kernels.c` is built twice: with the
  program's `-march` and for plain rv32i as the reference; results are compared
  before the scheduler starts and continuously afterwards (random operands incl.
  0, -1, INT_MIN; array/matrix code that GCC compiles to `sh1add/sh2add/sh3add`).
  `divstorm.S` (M builds) runs back-to-back divides with register integrity
  while short random external interrupts land inside the 34-cycle divide stall.
* **brk** -- the RTOS-level breaker (64 KiB, 256 KiB at `-O0`). All at once,
  timing randomised by the seed: external-interrupt *storms* (bursts of
  1..150-cycle or 1..8-cycle intervals, far shorter than the tick; `-DBRK_STORM_MASK=3`
  makes them 8x more frequent) whose ISR writes a stream buffer and framed
  messages into a message buffer and drains a task->ISR stream buffer (all
  contents sequence-checked); `mtimecmp` written into the past, to 0 and a few
  cycles into the future, and critical sections spanning 1..3 ticks (tick
  catch-up); critical sections nested 1..8 deep with `taskYIELD()` at random
  depths and nested `vTaskSuspendAll()`; `taskYIELD()` with interrupts disabled
  outside any critical section; task churn with `vTaskDelete(NULL)`, deletion of
  blocked and of ready tasks (heap and task count must return to baseline); a
  priority-inheritance chain L<-M<-H with timeouts, a recursive mutex and hog
  tasks; self-modifying code + `fence.i` from two tasks (incl. a buffer that
  starts with `fence.i`); deliberate exceptions from a task (illegal, ebreak,
  misaligned load/store/jalr, access faults incl. after a 3-cycle stall, bad
  CSR), 1 in 4 of them inside a critical section, plus reads of the
  side-effecting `wishbone_test` counter (a load performed twice shows);
  `pipebrk.S` (divides next to `csrci/csrsi mstatus`, ECALL, slow-bus
  loads/stores, `fence.i`, `mscratch`; MIE toggles next to ECALL); `wfi` and
  slow-bus accesses in the idle hook; RegTest 1/2/3; optional run-time
  MHPMEVENT10 mode changes (`-DBRK_BPDYN=1`). It prints how often an interrupt
  was taken with mepc at a divide / M op / ECALL / CSR op / `fence.i`.

All task periods and interrupt rates scale with `FRTOS_TICK`, so the programs
pass on the golden CPU from pathological ticks (500 cycles at `-O2`/`-Os`,
1500 at `-O0`; `campaign.py --set ticksweep --golden-only` re-measures this)
up to the real 50000-cycle tick.

**UART transcript check.** A program cannot observe its own UART output, so
every program also prints the fixed line `HADES_PATTERN_LINE`
(`~0123...xyz~`, see `common/hades_hal.h`) with interrupts enabled -- once
per check period, and `stress`/`mzba` about every 100k cycles from a
low-priority task. `campaign.py` fails a run whose pattern lines do not arrive
intact (a UART store performed twice or lost); `--no-uart-check` only counts
them.

## Differential campaign

```bash
python3 test/freertos/campaign.py --set quick                         # smoke test, DUT + golden
python3 test/freertos/campaign.py --set validate --seeds 8 \
    --dut buggy=. --dut patched=/path/to/other/tree            # several DUT trees side by side
python3 test/freertos/campaign.py --set standard --seeds 3 --jobs 6   # every knob, all four programs
python3 test/freertos/campaign.py --set standard --list               # show the variants
python3 test/freertos/campaign.py --set full --only 'rv32i\.Os' --seeds 12   # one variant, more seeds
python3 test/freertos/campaign.py --set realtick --seeds 2              # full demo at the real 1 kHz tick (~750M cycles/run)
python3 test/freertos/campaign.py --set validate --run-cycles 40000000 # longer stress/minimal/mzba runs
python3 test/freertos/campaign.py --set breaker --seeds 8 --run-cycles 20000000     # brk, incl. branch predictor on
python3 test/freertos/campaign.py --set breaker2 --seeds 8 --run-cycles 20000000    # brk with heavy storms
python3 test/freertos/campaign.py --set bpred --seeds 4                             # stress/minimal/mzba/full, predictor on
python3 test/freertos/campaign.py --set breaker-long --run-cycles 100000000 --max-checks 100000
```

Each ELF is built once and run with `--seeds` interrupt-timing seeds on every
`--dut` tree (default: this repo) and, for rv32i builds, on the golden CPU
(verilated from the first tree with `+define+USE_REF_CPU`). Results go to
`build/freertos-campaign/` (`summary.md`, `results.csv`, `results.json`, one
`sim.log` per run) and the table is printed:

* `PASS` / `FAIL <reason>` / `HANG` (no result before the cycle limit) /
  `CRASH` (simulator ended otherwise), with the cycles simulated. `PASS`
  means the program passed *and* its UART transcript is intact; the summary
  counts the runs that failed *only* the UART transcript check separately.
* rv32i: the golden CPU is the oracle. A golden failure means the variant or
  the harness is broken and makes the campaign exit with status 2.
* rv32im / rv32im_zba: the golden CPU predates M and Zba; the programs' own
  self-checks are the oracle.
* Nothing reads the Zicntr `time` CSR (0 on the golden CPU); time comes from the
  memory-mapped `mtime`.

**Suites, records and comparisons.**

```bash
python3 test/freertos/campaign.py --suite sep2026 --list                # the runs of a suite
python3 test/freertos/campaign.py --suite sep2026 --jobs 12 --wall-limit 0 \
    --compare results/freertos-campaign/2026-10-01_03386fd/results.csv  # about 80 minutes
python3 test/freertos/campaign.py --set validate --seeds 2 --strict \
    --record "results/freertos-validate/$(date +%F)_$(git rev-parse --short HEAD)"  # write a record
python3 test/freertos/campaign.py --results a.csv --compare b.csv       # two stored results
```

* `--suite NAME` runs several sets in one pool of `--jobs` workers, each with its own
  seeds, seed base, run length and check limit, as the separate `--set` commands would;
  each entry builds and logs into `<out>/<entry>/` (by default under
  `build/freertos-campaign/<suite>/`). It cannot be combined with `--set`, `--seeds`,
  `--seed-base`, `--run-cycles` or `--max-checks`. `sep2026` is the final campaign on the
  fixed core, run on 2026-09-27: 794 DUT runs, 102 of them with the branch predictor on,
  and 523 golden runs, from the six commands that `--help` lists. Its `validate` and
  `standard` entries share 5 variants and the seeds 0001-0008, so 40 DUT and 40 golden runs
  are run twice, which also checks that the simulations are deterministic.
* `--wall-limit SECONDS` is a per-run wall-clock limit, a safety net against a simulator
  that stops making progress (default `max(600, cycle limit / 150000)`; `0`: none). A run
  it stops is a `CRASH` that a re-run need not repeat, so give `0` for long suites on a
  busy machine.
* `--record DIR` writes a record of the campaign into DIR, by convention
  `results/<topic>/<date>_<commit>/` ([results/README.md](../../results/README.md)):
  `RECORD.md`, `meta.json`, `results.csv` (one row per run), `summary.md` and
  `inputs.sha256` (program images and source fingerprints). It never overwrites an
  existing record. `--quoted-in 'FILE:LINE: TEXT'` notes where a figure of the campaign
  is quoted, `--note TEXT` adds a caveat; both can be repeated.
* `--compare FILE` compares the campaign run for run with a stored `results.csv`, keyed by
  set, variant, seed and target: status, reason, cycles, UART line counts, run shape and
  program image, never wall time. It ends with `COMPARE RESULT: IDENTICAL` or
  `COMPARE RESULT: DIFFERENT` and exits with status 4 on a difference. With
  `--results OTHER.csv`, nothing is run and OTHER.csv is compared with FILE.

The campaigns that the documentation quotes are recorded in
[results/freertos-validate](../../results/freertos-validate/2026-10-01_03386fd/RECORD.md)
(`make freertos-stress`) and
[results/freertos-campaign](../../results/freertos-campaign/2026-10-01_03386fd/RECORD.md)
(`--suite sep2026`).

**Reproducing one run.** Every run directory holds `cmd.txt` (the `make
frtos-elf` variables of its ELF and the exact simulator command) next to its
`sim.log`; the simulations are deterministic. By hand, e.g.

```bash
make test/freertos/full FRTOS_OPT=-Os FRTOS_SLICE=0 FRTOS_SEED=3            # DUT
make test/freertos/full FRTOS_OPT=-Os FRTOS_SLICE=0 FRTOS_SEED=3 FRTOS_CPU=ref
```

(the campaign additionally passes `-DFRTOS_NCHECKS`/`-DFRTOS_CHECK_TICKS`
for stress/mzba/minimal, derived from the tick period; see `cmd.txt`).

The simulator options used (`sim/top.sv`, all optional, defaults unchanged):
`+timeout=<cycles>` (default 100000), `+nodump` (no `sim.fst`),
`+switches=<hex>` (board switches = run seed).
