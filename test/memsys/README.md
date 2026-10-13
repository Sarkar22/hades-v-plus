# Memory-System Checks

Simulation tools for the memory system: a RAM that answers late, an oracle that checks every
answer of the RAM, and a trace-driven model of L1 caches. They test the memory system and
size caches between the CPU and the RAM, and they check the instruction cache that the
simulators can be built with ([docs/CACHES.md](../../docs/CACHES.md)). The design and synthesis
do not change, and the standard simulators behave as before: every option below builds its own
simulators, in `build/cfg-<name>`. The caches exist only in the simulators; the standard build
and the Basys 3 bitstream have none.

| Piece | Where | What it does |
|---|---|---|
| Slow memory | [sim/slow_memory.sv](../../sim/slow_memory.sv), selected in [rtl/mcu.sv](../../rtl/mcu.sv) under `HADES_SLOW_MEM` | A wrapper in front of each RAM port (fetch and data) that holds every transfer for a fixed or random number of wait states; optional burst timing for consecutive words. At latency 0 it is a wire: bus hashes and cycle counts equal the standard simulator's. |
| Scoreboard | [sim/top.sv](../../sim/top.sv) | A shadow copy of the RAM, loaded from the same `init.mem` and updated from every acknowledged store, byte lane by byte lane. Every fetch and load from the RAM must return the copy's word, the RAM must equal the copy after every store and at the end of the run, and `ack` and `err` must never come together. A mismatch stops the simulation. It checks the memory system, not the CPU: it does not see register results, and in most programs a single wrong instruction fetch shows only in its fetch compare, so keep it on. |
| RAM timeout check | [sim/top.sv](../../sim/top.sv) | Always on: an interconnect timeout on a RAM access stops the simulation. |
| Bus hash, retired instructions | [sim/top.sv](../../sim/top.sv) | `BUSHASH` lines (a hash of both CPU buses, cycle by cycle, and of the completed data transfers) and `RETIRED cycles=... instructions=... cpi=...` at the end of a run. |
| [programs.py](programs.py) | here | Runs every assembly and C program (`test/asm/*.s`, `test/c/*.c`) and the programs here (`test/memsys/*.s`) on both CPUs in one configuration, and judges each run against the same program at latency 0. The module benches, FreeRTOS and the trap sweep are not part of it. |
| [stores.s](stores.s) | here | Loads and stores with no other instruction between them (back to back on the bus when instruction fetch does not wait), in two passes (branch predictor off, then mode 3) in which every store changes the bytes it writes: they expose early acknowledgements and dropped, misdirected or reordered writes at any latency, also without the scoreboard (apart from two stores that are overwritten before any load; see its header). |
| [irqchain.s](irqchain.s) | here | An interrupt armed 1 to 200 cycles ahead of a chain of 16 instructions, each of which changes `a0`, so that it lands before every chain instruction, also while Fetch waits: every instruction must retire exactly once, and the handler checks `mcause`, `mepc` and `a0` at every interrupt. Before every delay an eviction step makes the tested code miss again in an instruction cache. |
| [fetchredirect.s](fetchredirect.s) | here | Abandoned fetches: taken branches and jumps forward and backward, predicted and mispredicted, whose targets each make a distinct, order-dependent checksum update and whose wrong-path words count in a register of their own, so that a word delivered for the wrong address shows also without the scoreboard. An eviction step before every pass and case makes the tested code miss again in an instruction cache. |
| [icoherence.s](icoherence.s) | here | Instruction-stream coherence: a block is run, patched with `sw`, `sh` and `sb` within one 16-byte line and across two, and run again after `fence.i`; the words right behind a `fence.i` are stored to before it. Both also with the block evicted from an instruction cache before every patch; stores with a cached line's index and another tag; a data store into a line of code; blocks one cache size apart; a store to the next line just before its first fetch; eight stores in consecutive instructions to eight cached lines. |
| `warm_*.s`, [mkwarm.py](mkwarm.py) | here | Warm-cache variants of the programs that time their own instructions with `mcycle`: each timing window runs twice, and only its second pass, from a warm instruction cache, is checked. Written by mkwarm.py from `test/asm`; do not edit them. |
| Bus trace, [cachemodel.py](cachemodel.py) | `HADES_BUSTRACE` in [sim/top.sv](../../sim/top.sv); here | A per-cycle trace of the core's buses and a model that replays it through split L1 caches in front of a slow memory; an I-cache-only mode and a comparison of a cached simulator run with the model (`rtlcheck`). |
| [matrix.py](matrix.py), [mutants.py](mutants.py), [legality.py](legality.py) | here | The verification of the simulators with an instruction cache ([docs/CACHES.md](../../docs/CACHES.md)): the matrix of configurations, latency profiles and suites; the mutation campaign; the refusals, negative builds and option checks. |

## Simulator Configurations

Options of any make target that builds a simulator (`make help` lists them):

| Option | Meaning |
|---|---|
| `MEM_LAT=<n>` or `<min>:<max>` | wait states of every RAM read and write, fixed or drawn per transfer (0 to 1023; at most 254 on the data port, see below) |
| `MEM_WR_LAT=...` | wait states of every RAM write (default: `MEM_LAT`) |
| `MEM_BEAT_LAT=<n>` | burst timing: a further transfer to the next word while `cyc` stays high waits n cycles; on the data port an access to another slave (I/O) ends the burst |
| `MEM_ONLY=fetch\|data` | the wait states apply to that RAM port only; the other one behaves as the standard RAM (refused with `ICACHE`: the cached configuration has one memory port) |
| `MEM_SEED=<n>` | seed of the latency generator (default 1); each port has its own sequence; with `ICACHE` it also seeds the random initial contents of the cache's arrays |
| `ICACHE=<bytes>` | an instruction cache of that size (a decimal power of two of at least two lines; 0 or unset: none), direct-mapped, and one memory port that its refills share with the data side, with the latencies above (latency 0 if none is given). The RAM is then exempt from the interconnect timeout, so the 254-cycle limit below does not apply |
| `LINE=8\|16\|32\|64` | the cache's line size in bytes (default 16); only with a non-zero `ICACHE` |
| `SCOREBOARD=0\|1` | the scoreboard (default: on with a slow memory, off otherwise) |
| `BUSHASH=0\|1` | the bus hash |
| `BUSTRACE=0\|1` | the bus trace (HaDes-V+ only) |

```bash
make test/asm/ops MEM_LAT=2
make test/memsys/stores MEM_LAT=1:8 MEM_SEED=3
make freertos APP=minimal MEM_LAT=2
make test/memsys/stores ICACHE=512 MEM_LAT=2          # with an instruction cache
make freertos APP=minimal ICACHE=8192 MEM_LAT=1:8
make sim-config MEM_LAT=1:8          # name, build directory and environment of a configuration
make lint-loops MEM_LAT=2            # combinational loops, without the UNOPTFLAT waiver
```

The options are compiled in as the simulator's defaults; run-time options override them:
`+mem_lat`, `+mem_rd_lat`, `+mem_wr_lat`, `+mem_beat_lat`, `+mem_only`, `+mem_seed`,
`+scoreboard` / `+noscoreboard`, `+bushash` / `+nobushash`, `+retired` / `+noretired`,
`+bustrace=<file>`. A cached simulator adds `+cache_stats` / `+nocache_stats` (the
`CACHE_STATS` line, on by default), and every slow-memory simulator takes the testbench options
below.

Wait states make a program up to 1 + the longest wait times slower. Without `+timeout`, a
simulator with a slow memory therefore multiplies the default cycle limit (100000) by 1 + the
longest read, write or beat wait of the two ports, and prints the limit in a `SLOW MEMORY cycle
limit` line; at `MEM_LAT=1:8` it is 900000 cycles. `SIM_ARGS=+timeout=<cycles>` sets the limit
of a single run. `programs.py` scales its limit the same way.

With an instruction cache the default limit is 100000 times 1 + max(R, D), with R the
cycles of the longest refill and D those of the longest data transfer of the one memory port
(`R = (RD + 1) + (words per line - 1) * (B + 1)` and `D = max(RD, WR) + 1`, with RD and WR the
longest read and write wait and B the beat wait in burst mode, else RD), and the limit is
printed in the same `SLOW MEMORY cycle limit` line; `make help` states the rule.

The configuration of a cached simulator has the parts `i<size>` and `l<line>` after the memory
parts of its name (`mem2-i512-l16` for `ICACHE=512 MEM_LAT=2`; `mem1_8-seed2-i8k-l32` for
`ICACHE=8192 LINE=32 MEM_LAT=1:8 MEM_SEED=2`), and prints a `CACHE` line and a `SLOW MEMORY
memory port` line at time 0 ([docs/CACHES.md](../../docs/CACHES.md#what-the-simulator-prints)).
`DCACHE` is refused (there is no data cache), and so is `make synthesis` with any of these options.

The data port waits at most 254 cycles (without a cache): the interconnect ends a data access
that has had no answer for 255 cycles with `err` ([wishbone_interconnect.sv](../../lib/wishbone/wishbone_interconnect.sv)).
The Makefile and `sim/slow_memory.sv` refuse a longer read, write or beat latency on the data
port; the fetch port takes up to 1023 (`MEM_ONLY=fetch` for longer fetch waits alone). With an
instruction cache the RAM is exempt from that timeout and the one memory port takes up to 1023.

### Testbench options

Run-time options of [sim/top.sv](../../sim/top.sv), for placing events and reading results
(`SIM_ARGS='+...'` through make). Details, line formats and the reasons are in
[docs/CACHES.md](../../docs/CACHES.md#testbench-options).

| Option | Meaning |
|---|---|
| `+reset_at=<cycle>[,<cycle>...]` | A one-cycle reset three cycles after each listed cycle (decimal, at least 1, strictly ascending, at least 2 apart). Prints `RESET at cycle <n> (+reset_at=<c>): I-cache <phase>, data side <phase>` in the reset cycle. Every slow-memory simulator, both CPUs. `RETIRED` and `BUSHASH` keep counting through a reset; `CACHE_STATS` restarts |
| `+cache_phase_log=<file>` | One byte per cycle: the cache and the data side's phases, to choose the cycle of a reset (a reset wanted in cycle `t` is requested with `+reset_at=<t-3>`) |
| `+ram_words=<byte address>[,...]` | At the end, a `RAM_WORDS` line with these RAM words (word-aligned, inside the RAM) |
| `+retired_every=<n>` | A `RETIRED_AT instructions=<i> cycles=<c>` line each time HaDes-V+ has retired another n instructions |
| `+irq_latency` | An `IRQLAT interrupts=<n> max=<cycles> mean=<cycles>` line at the end: the cycles from an interrupt pending in Writeback to the first fetch answer after its jump. HaDes-V+ only; in every simulator |

## Programs Under Wait States

```bash
python3 test/memsys/programs.py run MEM_LAT=2
python3 test/memsys/programs.py run MEM_LAT=1:8 MEM_SEED=2
python3 test/memsys/programs.py run MEM_LAT=0 BUSHASH=1 --out /abs/l0
python3 test/memsys/programs.py run --sim-args +bushash --out /abs/std
python3 test/memsys/programs.py compare /abs/std /abs/l0
```

With a slow memory every program also runs at latency 0 in the same simulator, and each run
must give the same reports, verdict and output as that run, apart from the differences that
`WAIT_STATES` in programs.py lists with their reasons: checks that measure the timing of a
single-cycle memory (interrupt-position sweeps, `mcycle` deltas, the constant-time checks of
`zkt.s`). Which of them are excused depends on the latency profile, which the run prints.
The checks that time straight-line instructions are judged by the profile of the fetch port
alone: wait states of the data port alone excuse none of them.

- checks that compare a block of instructions with the cycle count of single-cycle fetch
  (the 17-cycle check of `test_cycle_exact` in the Zb\*, Zk\* and Zicond programs) whenever
  an instruction fetch takes more than one cycle: a read latency above 0 on the fetch port,
  unless a burst beat latency of 0 makes the instructions behind the first one of a block
  take one cycle each;
- checks that compare two blocks with each other (the equality check of `test_cycle_exact`,
  `zicntr.s` reports 4 and 5, the block comparisons of `zkt.s`) only with random fetch
  latencies, or in burst mode with a beat latency that differs from the read latency. At a
  fixed latency every fetch waits the same, so they still hold and still mean something; of
  `zkt.s` only report 2 (the 9-cycle reference block) and the 28 `mul`-family blocks (reports
  67-94) are excused there, the same at latencies 1, 2, 3, 4 and 8.

The exit status is 1 when a HaDes-V+ run differs otherwise, or when any run is bad: its
scoreboard reports a mismatch, its simulator stops with an error or returns a non-zero status
(the simulators exit with 0 after any verdict and after a timeout), or a HaDes-V+ run at
latency 0 does not end with the verdict of the standard memory (`VERDICT_AT_LATENCY0` in
programs.py; judging compares with that run, so it must be right). The golden CPU's runs are
judged the same way but only recorded: it is a frozen model, and its stale-`mtvec` defect
shows in `mtvecirq.s` at some latencies and not at others (a golden-only rule lists it). Keep
the latency-0 judging on (no `--no-judge`): it is the check that catches a memory path whose
faults stay invisible in programs with sparse memory traffic. Keep the scoreboard on as well:
a fault present at every latency gives the same wrong result at latency 0, and the judging
then compares wrong with wrong. With a slow memory and the scoreboard off (`SCOREBOARD=0` or
`+noscoreboard`), `run` refuses to start unless `--allow-no-scoreboard` is given, and then
warns. `compare` of the standard simulator against latency 0 shows that the slow-memory
simulator is cycle-for-cycle the standard one.

### With an instruction cache

```bash
python3 test/memsys/programs.py run ICACHE=512 MEM_LAT=2
python3 test/memsys/programs.py run ICACHE=8192 MEM_LAT=1:8 MEM_SEED=1
```

A cached simulator still has its cache at `+mem_lat=0`, so the reference is not the same
simulator at latency 0: `run` also builds the standard (cache-free) simulators and judges every
run against the same program on the same CPU in the standard simulator, run with `+scoreboard`
(in `<out>/standard`). A cache makes instruction fetch wait, and wait by different amounts, at
every latency (a miss costs a refill), so the timing classes are set directly: every rule of
`WAIT_STATES` applies whose condition is "waits", "fetch waits" or "variable", none of the
"fixed" ones, and no rule marked uncached-only. The warm variants (`warm_*.s`, below) carry the
rules of their originals marked uncached-only: with a cache their looped windows are judged
strictly. The default cycle limit of a cached run is 100000 times 1 + max(R, D), with R the
cycles of the longest refill and D those of the longest data transfer of the one memory port (at
`MEM_LAT=2` with 16-byte lines: R = 12, D = 3, 1300000 cycles); the reference runs keep 100000.
The lines `CACHE`, `CACHE_STATS`, `RESET`, `IRQLAT`, `RAM_WORDS` and `RETIRED_AT` are
configuration lines, which neither the judging nor `compare` reads as program output.

## Warm-Cache Timing Variants

```bash
python3 test/memsys/mkwarm.py            # (re)write test/memsys/warm_*.s
python3 test/memsys/mkwarm.py --list     # the windows, the loop register, the parts
python3 test/memsys/mkwarm.py --check    # the committed files, a negative case, runs on the standard build
```

Some programs of `test/asm` time a block of their own instructions with two reads of `mcycle`
and require an exact cycle count: the two windows of `test_cycle_exact` in `zbb.s`, `zbkb.s`,
`zbkx.s`, `zbs.s`, `zicond.s` and `zknh.s`, the three adjacent-read pairs of `zicntr.s` (its
reports 4 and 5) and the 303 windows of `zkt.s`. With an instruction cache the first fetch of
every line misses, so such a window fails even at latency 0. `mkwarm.py` writes a variant of
each in which every window, with its operand set-up, runs twice in a row (a loop of three
instructions outside the window, on a register that the original never uses); only the second
pass, in which every fetch hits and takes one cycle as on the standard RAM, reaches the checks.
The windows are listed in mkwarm.py by line number; the script checks that each loop body holds
no label, branch, jump, load, store or CSR write and is idempotent (no register that it reads
before writing it is also written by it), that a file loops every window that its looped
windows' checks compare with (every block check of `zkt.s` compares with the reference window,
report 2), and that every file fits below the reserved top 4 KiB of the RAM with 64 bytes to
spare. `zkt.s` leaves room for 72 loops, so its windows are spread over five parts
(`warm_zkt_1.s` to `warm_zkt_5.s`): each part loops the reference window and one range of the
302 block windows. The line `# mkwarm: unlooped window reports: ...` of each file names the
reports whose windows it does not loop; with a cache they keep their original's rule.
`--check` fails if a committed file differs from what the script writes, shows that a part
without the reference window is refused, and runs every warm file and its original on the
standard HaDes-V+ simulator: the reports and the verdict must be the same.

## Directed Tests With an Instruction Cache

`irqchain.s`, `fetchredirect.s` and `icoherence.s` give the same reports on the standard build
and at every latency, with or without a cache. For a cache they make their tested code miss:
an eviction step calls a block placed exactly 8 KiB after that code (8 KiB is a multiple of
512 bytes, so the block's lines have the tested lines' indexes in a 512-byte and in an 8 KiB
direct-mapped cache). The block runs one `jal` per two lines: the `jal` at word 3 of every
even line jumps to word 3 of the line after next, and Fetch, which resolves a `jal` in
Execute, presents word 0 of the line in between on the wrong path, where a cache starts a
refill that always completes (and is counted as abandoned). The header of each test states
what a cached run must show in its `CACHE_STATS` line (`i_done`, `i_abandoned`,
`snoop_inval`), computed from the assembled program and its retired instructions on the
standard build; `irqchain.s` records the positions its interrupts reached (read them with
`+ram_words=0x46000,0x46004`).

## Fetches Outside the RAM (trap sweep)

`test/trapsweep/sweep.py run --fam window` runs the optional family `window` (it is not part of
`all` or `sweep.py list`): `jalr` to byte 0xC0000 (the set of the reset line in a 512-byte and
in an 8 KiB cache), to byte 0x3FFFC (the word below the RAM) and to its own address plus
0x80000 (the same index, word and low tag bits as its own line, outside the RAM). Each must end
in a fetch fault, on both CPUs; with a tag compare cut down to the bits that the RAM window
needs, the last one would get `ack` and `err` together. The first and the last probe start a
16-byte line, so that the two words that Fetch presents before the target lie in the `jalr`'s
own line and the target is looked up while that line is valid.

## FreeRTOS Under Wait States

The FreeRTOS programs keep their tick in clock cycles, so wait states make every task slower
against the tick. `stress`, `mzba`, `full` and `brk` check their own progress in real time and
fail on both CPUs alike unless the tick is scaled by about 1 + the mean wait. In every
configuration with a slow memory the tick is therefore set automatically, unless `TICK=` is
given: `10000 * F` cycles, `F = 1 + ceil(the larger of the mean read and mean write wait)`, plus
1 with an instruction cache (`TICK=30000` at `MEM_LAT=2`, `TICK=40000` with `ICACHE=512` as
well). The programs get `-DFRTOS_SLOW_SCALE=F`: `mzba` scales its test-device interrupt
intervals by it and `brk` its interrupt intervals and sleep period, and the default cycle limit
of a program grows with the tick; the stress campaign passes its own tick and stays unscaled.
An explicit `TICK=` or `DEFS=-DMZBA_IRQ_MEAN=...` overrides
([docs/FREERTOS.md](../../docs/FREERTOS.md#slow-memory-and-cached-configurations)). The console
lengthens its pauses between typed characters by the factor `+console_pace=<n>` (1 to 32767;
default with a slow memory: 1 + its longest read, write or beat wait; with an instruction cache
2 + the longest wait of the one memory port), so the scripted shell session passes at every
latency.

## Cache Model

```bash
make freertos APP=minimal BUSTRACE=1     # build/cfg-trace/test/freertos/minimal/bustrace.bin
python3 test/memsys/cachemodel.py prep build/cfg-trace/test/freertos/minimal/bustrace.bin /abs/minimal --ram-kb 32
python3 test/memsys/cachemodel.py run /abs/minimal --isize 512 8192 --dsize 512 4096 --pair --line 8 16 32 --out results.jsonl
python3 test/memsys/cachemodel.py check                             # the hand-computed cases only
python3 test/memsys/cachemodel.py check /abs/minimal --w1 2000000   # and the trace replays
```

The trace monitor only reads signals (the run's cycle count is the standard one) and writes
16 bytes per cycle, so mind the disk: about 51 MB for `minimal` (3.2 million cycles), 2.4 GB
for `full` (151 million); `prep` keeps about 40% of that. The model (Python 3 with numpy)
replays the trace through direct-mapped or 2-way caches: an I-cache and a write-through,
no-write-allocate D-cache behind one memory port, with the I-cache snooping stores, optional
abort-on-redirect and an optional write buffer, under a per-beat or a burst memory latency,
and reports cycles per instruction, misses per 1000 instructions and the stall shares.
`check` runs hand-computed cases; given prepared traces, it also replays each of them, or the
cycles from `--w0` (default 0) up to `--w1` (the first 2 million in the example), through
twelve cache configurations (four of them I-cache-only) with the fast replay and with the plain
per-cycle replay that specifies it, and requires equal results (`CHECK: PASS`). The header of
cachemodel.py documents the trace format, the model and its approximations.

`--dsize 0` is the I-cache-only mode, the configuration of the simulators with an instruction
cache: every RAM load is one read transfer on the shared port (L + 1 cycles, never a burst),
stores as before, data side first; a snoop is counted as the RTL counts it (also when a miss in
the same cycle evicts the stored-to line); `port_load` counts the port cycles of loads, the
D-cache's fields are null, and a refill that runs or waits when the trace ends is completed and
reported (`i_end_completed`, `i_end_state`).

```bash
make test/memsys/stores ICACHE=512 MEM_LAT=2 > /abs/stores.log     # a cached run
python3 test/memsys/cachemodel.py rtlcheck /abs/stores-prepared /abs/stores.log
```

`rtlcheck` compares a cached run with the model on the trace of the same program recorded at
the standard memory: it reads the run's `CACHE`, `SLOW MEMORY memory port`, `CACHE_STATS` and
`RETIRED` lines (a log with a `RESET` line is refused), runs the model in the same
configuration and prints every field side by side. Exact (the verdict `RTLCHECK: AGREE`): the
started refills, the completed refills plus the one in flight against the model's completed
refills, `snoop_inval`, `d_loads`, `d_stores`, and the run's own identities, with a fixed
latency also the port cycles of refills and data transfers. The cycles, the port waits,
`i_abandoned` (against the model's `i_left`) and the port use are reported: they depend on the
model's approximation that the whole core waits during a miss. Use programs whose retired
instructions do not depend on timing (no interrupts, no polling).

## Verification of the Instruction Cache

Besides the tools below, the cache is checked by the bench [test/sv/test_icache.sv](../sv/test_icache.sv)
(`make test/sv/test_icache`, options through `SIM_ARGS`; the cache and the arbiter against a
reference model, every output and event in every cycle) and by the proofs of
[formal/cache/](../../formal/cache/README.md) (`make formal-cache`); both are described in
[docs/CACHES.md](../../docs/CACHES.md#verification-and-how-to-re-run-it).

```bash
python3 test/memsys/matrix.py list                       # legs, jobs, estimated cycles
python3 test/memsys/matrix.py run programs --jobs 2      # one leg; 'all' or nothing: every leg
python3 test/memsys/matrix.py summary
python3 test/memsys/mutants.py list
python3 test/memsys/mutants.py anchors                   # do the patches find their code?
python3 test/memsys/mutants.py dryrun                    # apply each, check that it builds, discard it
python3 test/memsys/mutants.py run all --jobs 2 --map
python3 test/memsys/legality.py run
```

`matrix.py` runs the matrix of the cached configurations (a 512-byte and an 8 KiB cache, other
line sizes in one leg) against the latency profiles `lat0`, `lat2`, `rand1` to `rand3` (1 to 8
cycles, three seeds), `burst`, `stress` (1 to 64 cycles, beyond the interconnect timeout without
the RAM's exemption) and `dram` (measurements only): the programs, the module benches, the
timing benches (`bench-mcost` and `bench-fencei-window` judged by its own rules with a cache),
FreeRTOS compares, the shell and the loader, the trap sweeps, the stress campaign, the coverage
of the directed tests, HaDes-V+ cached against the golden CPU uncached, `lint-loops`, mid-run
resets placed from a `+cache_phase_log` run, the model agreement (`cachemodel.py rtlcheck`) and
the CPI rows. It checks the `CACHE_STATS` identities on every log of a cached run, keeps every
verdict in `<out>/matrix.json` for the tree it ran on (a job judged for the same tree is not run
again), runs the longest jobs first, never runs two FreeRTOS builds of one program in one
configuration directory at once, and writes a summary table. A leg that needs a cache refuses
to run in a tree whose Makefile does not know `ICACHE`.

`mutants.py` applies each mutant of the memory system (a source patch, in a temporary copy of
the tree, never in the checkout) and runs the check that must catch it: the I-cache bench, a
program set in a configuration (the directed tests with the scoreboard's fetch compare disabled,
their own checks deciding), the trap sweep, a formal property, a port-cycle identity or the
reset runs; it prints `CAUGHT` or `MISSED`. Every patch names the code it changes by a regular
expression that must match exactly as often as stated; `anchors` lists the ones that do not
match the tree (a mutant whose patch does not apply is `ANCHOR MISSING`, never `CAUGHT`);
`dryrun` applies every patch in a temporary copy, checks that the copy still builds (Verilator
elaborates the simulator of the mutant's configuration, and the I-cache bench for a patch of the
cache; a patched program is assembled) and deletes the copy. `--map` also shows each run-time
assertion firing on its negative control. `apply <name> <dir>` writes a copy of the tree with one
mutant applied: the negative controls of `make formal-cache` take their mutants from it, so each
mutant is written in one place.

`legality.py` checks the refusals of the make options (`ICACHE`, `LINE`, `MEM_ONLY` with a
cache, `DCACHE`, synthesis with any configuration, checked with `make -n`), the configuration
names and defines, negative builds of the cache's parameters through Verilator directly, the
time-0 checks of the run options, `+reset_at`, the default cycle limit of every latency profile,
the builds of the cached simulators (plain, console, FreeRTOS model; scoreboard and bus-hash
options), the placement of every memory-wrapper reference in `sim/top.sv`, and the negative
cases of the I-cache bench.
