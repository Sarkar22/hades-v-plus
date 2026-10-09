# Memory-System Checks

Simulation tools for the memory system: a RAM that answers late, an oracle that checks every
answer of the RAM, and a trace-driven model of L1 caches. They test the memory system and
size caches between the CPU and the RAM. The design and synthesis do not change, and the
standard simulators behave as before: every option below builds its own simulators, in
`build/cfg-<name>`.

| Piece | Where | What it does |
|---|---|---|
| Slow memory | [sim/slow_memory.sv](../../sim/slow_memory.sv), selected in [rtl/mcu.sv](../../rtl/mcu.sv) under `HADES_SLOW_MEM` | A wrapper in front of each RAM port (fetch and data) that holds every transfer for a fixed or random number of wait states; optional burst timing for consecutive words. At latency 0 it is a wire: bus hashes and cycle counts equal the standard simulator's. |
| Scoreboard | [sim/top.sv](../../sim/top.sv) | A shadow copy of the RAM, loaded from the same `init.mem` and updated from every acknowledged store, byte lane by byte lane. Every fetch and load from the RAM must return the copy's word, the RAM must equal the copy after every store and at the end of the run, and `ack` and `err` must never come together. A mismatch stops the simulation. It checks the memory system, not the CPU: it does not see register results, and in most programs a single wrong instruction fetch shows only in its fetch compare, so keep it on. |
| RAM timeout check | [sim/top.sv](../../sim/top.sv) | Always on: an interconnect timeout on a RAM access stops the simulation. |
| Bus hash, retired instructions | [sim/top.sv](../../sim/top.sv) | `BUSHASH` lines (a hash of both CPU buses, cycle by cycle, and of the completed data transfers) and `RETIRED cycles=... instructions=... cpi=...` at the end of a run. |
| [programs.py](programs.py) | here | Runs every assembly and C program (`test/asm/*.s`, `test/c/*.c`) and the programs here (`test/memsys/*.s`) on both CPUs in one configuration, and judges each run against the same program at latency 0. The module benches, FreeRTOS and the trap sweep are not part of it. |
| [stores.s](stores.s) | here | Back-to-back loads and stores with no idle cycle between them, which expose early acknowledgements and dropped, repeated or reordered writes at any latency, also without the scoreboard. |
| [irqchain.s](irqchain.s) | here | An interrupt armed 1 to 200 cycles ahead of a chain of 16 instructions, each of which changes `a0`, so that it lands before every chain instruction, also while Fetch waits: every instruction must retire exactly once, and the handler checks `mcause`, `mepc` and `a0` at every interrupt. |
| [fetchredirect.s](fetchredirect.s) | here | Abandoned fetches: taken branches and jumps forward and backward, predicted and mispredicted, whose targets each make a distinct, order-dependent checksum update and whose wrong-path words count in a register of their own, so that a word delivered for the wrong address shows also without the scoreboard. |
| [icoherence.s](icoherence.s) | here | Instruction-stream coherence: a block is run, patched with `sw`, `sh` and `sb` within one 16-byte line and across two, and run again after `fence.i`; the words right behind a `fence.i` are stored to before it. |
| Bus trace, [cachemodel.py](cachemodel.py) | `HADES_BUSTRACE` in [sim/top.sv](../../sim/top.sv); here | A per-cycle trace of the core's buses and a model that replays it through split L1 caches in front of a slow memory. |

## Simulator Configurations

Options of any make target that builds a simulator (`make help` lists them):

| Option | Meaning |
|---|---|
| `MEM_LAT=<n>` or `<min>:<max>` | wait states of every RAM read and write, fixed or drawn per transfer (0 to 1023; at most 254 on the data port, see below) |
| `MEM_WR_LAT=...` | wait states of every RAM write (default: `MEM_LAT`) |
| `MEM_BEAT_LAT=<n>` | burst timing: a further transfer to the next word while `cyc` stays high waits n cycles; on the data port an access to another slave (I/O) ends the burst |
| `MEM_ONLY=fetch\|data` | the wait states apply to that RAM port only; the other one behaves as the standard RAM |
| `MEM_SEED=<n>` | seed of the latency generator (default 1); each port has its own sequence |
| `SCOREBOARD=0\|1` | the scoreboard (default: on with a slow memory, off otherwise) |
| `BUSHASH=0\|1` | the bus hash |
| `BUSTRACE=0\|1` | the bus trace (HaDes-V+ only) |

```bash
make test/asm/ops MEM_LAT=2
make test/memsys/stores MEM_LAT=1:8 MEM_SEED=3
make freertos APP=minimal MEM_LAT=2
make sim-config MEM_LAT=1:8          # name, build directory and environment of a configuration
make lint-loops MEM_LAT=2            # combinational loops, without the UNOPTFLAT waiver
```

The options are compiled in as the simulator's defaults; run-time options override them:
`+mem_lat`, `+mem_rd_lat`, `+mem_wr_lat`, `+mem_beat_lat`, `+mem_only`, `+mem_seed`,
`+scoreboard` / `+noscoreboard`, `+bushash` / `+nobushash`, `+retired` / `+noretired`,
`+bustrace=<file>`.

Wait states make a program up to 1 + the longest wait times slower. Without `+timeout`, a
simulator with a slow memory therefore multiplies the default cycle limit (100000) by 1 + the
longest read, write or beat wait of the two ports, and prints the limit in a `SLOW MEMORY cycle
limit` line; at `MEM_LAT=1:8` it is 900000 cycles. `SIM_ARGS=+timeout=<cycles>` sets the limit
of a single run. `programs.py` scales its limit the same way.

The data port waits at most 254 cycles: the interconnect ends a data access that has had no
answer for 255 cycles with `err` ([wishbone_interconnect.sv](../../lib/wishbone/wishbone_interconnect.sv)).
The Makefile and `sim/slow_memory.sv` refuse a longer read, write or beat latency on the data
port; the fetch port takes up to 1023 (`MEM_ONLY=fetch` for longer fetch waits alone).

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
latency 0 does not end with the verdict of the standard memory (`VERDICT_AT_LATENCY0` in programs.py; judging compares with that run, so it
must be right). The golden CPU's runs are judged the same way but only recorded: it is a
frozen model, and its stale-`mtvec` defect shows in `mtvecirq.s` at some latencies and not at
others (a golden-only rule lists it). Keep the latency-0 judging on (no `--no-judge`): it is
the check that catches a memory path whose faults stay invisible in programs with sparse
memory traffic. Keep the scoreboard on as well: a fault present at every latency gives the
same wrong result at latency 0, and the judging then compares wrong with wrong. With a slow
memory and the scoreboard off (`SCOREBOARD=0` or `+noscoreboard`), `run` refuses to start
unless `--allow-no-scoreboard` is given, and then warns. `compare` of the standard simulator
against latency 0 shows that the slow-memory simulator is cycle-for-cycle the standard one.

## FreeRTOS Under Wait States

The FreeRTOS programs keep their tick in clock cycles, so wait states make every task slower
against the tick. `minimal` and the shell pass unchanged; `stress`, `mzba` and `full` check
their own progress in real time and fail on both CPUs alike unless the tick is scaled by about
1 + the mean wait, for example `TICK=30000` at `MEM_LAT=2` and `TICK=60000` at `MEM_LAT=1:8`.
The `rv32i` build of `mzba` also needs its test-device interrupt interval, which is set in
cycles, scaled: `DEFS=-DMZBA_IRQ_MEAN=18000` (latency 2) or `36000` (1 to 8). The console
lengthens its pauses between typed characters by the factor `+console_pace=<n>` (1 to 32767;
default with a slow memory: 1 + its longest read, write or beat wait), so the scripted shell
session passes at every latency.

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
`check` runs hand-computed cases; given prepared traces, it also replays the cycles that
`--w1` gives (2 million in the example) of each through eight cache configurations with the fast replay and with the
plain per-cycle replay that specifies it, and requires equal results (`CHECK: PASS`). The
header of cachemodel.py documents the trace format, the model and its approximations.
