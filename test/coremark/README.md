# CoreMark on HaDes-V+

[CoreMark](https://www.eembc.org/coremark/) is a small CPU benchmark of the Embedded Microprocessor Benchmark Consortium (EEMBC): linked-list processing, matrix operations and a state machine, checked by CRCs. HaDes-V+ runs it from the unmodified upstream sources in [`third_party/coremark/`](../../third_party/coremark/README.md) (provenance, licence and trademark terms there) through the port in this directory, on the simulators of the assembly and C tests, with any of the simulator configurations of the Makefile (wait states, caches, performance counters).

**These figures are estimates, not CoreMark scores.** CoreMark's rules require a run of at least 10 seconds. The simulator runs roughly half a million to a million cycles per second of wall time, and 10 seconds at the design's 50 MHz are 500 million cycles, about 1,200 iterations. The default is 10 iterations. CoreMark itself prints `ERROR! Must execute for at least 10 secs for a valid result!` and `Errors detected` at the end of every run here; that is the only error it reports, and `make coremark` accepts it. What the target reports as CoreMark/MHz is `iterations * 1000000 / cycles` of the timed window, an estimate of what a run of the rules' length would give. Do not quote it as a CoreMark result.

## Running

```bash
make coremark                                   # rv32im, -O2, 10 iterations, the standard RAM (one-cycle answers)
make coremark MARCH=rv32im_zba_zbb_zbs          # the core's richer ISA (Zba, Zbb, Zbs)
make coremark MARCH=rv32i ITERATIONS=3          # rv32i: the multiplications and divisions are libgcc's
make coremark CPU=golden                        # the golden CPU (rv32i only), same checks
make coremark RUN=validation                    # CoreMark's validation seeds (0x3415, 0x3415, 0x66)
make coremark BPRED=3                           # with the 2-bit branch predictor
make coremark ICACHE=8192 DCACHE=4096 MEM_LAT=8:24 MEM_WR_LAT=4:8 MEM_BEAT_LAT=0     # the cached simulator
make coremark ICACHE=8192 DCACHE=4096 MEM_LAT=8:24 MEM_WR_LAT=4:8 MEM_BEAT_LAT=0 HPM_PRESET=A   # with the cycle breakdown
```

| Setting | Default | Meaning |
|---|---|---|
| `ITERATIONS` | 10 | iterations of the timed window; at least 1 (CoreMark's own choice, 0, aims at 10 s and cannot end in a simulation) |
| `MARCH` | `rv32im` (`rv32i` with `CPU=golden`) | `-march` of CoreMark and the port; the golden CPU has no M and no Zba |
| `OPT` | `-O2` | one optimisation level |
| `CPU` | `dut` | `golden`: the golden reference CPU in `ref/` (its own simulator, built into `<build directory>/coremark-model/golden`) |
| `BPRED` | not set | `0` to `3`: the branch predictor's algorithm (never taken, always taken, backward taken, 2-bit counters; `MHPMEVENT10`, [docs/EXTENSIONS.md](../../docs/EXTENSIONS.md)); not set leaves the reset value, 0 (never taken). Not for the golden CPU |
| `RUN` | `performance` | `performance` or `validation` (the two seed sets of CoreMark's run rules) |
| `TIMEOUT` | 20 million + 15 million per iteration cycles | cycle limit of the simulation |
| `MEM_LAT`, `ICACHE`, `HPM_PRESET`, ... | none | the simulator configurations of the [Makefile](../../Makefile) (`make help`): the simulator and the outputs then go to the configuration's directory, `<build directory>/cfg-<name>/` |

The program is built into `<build directory>/test/coremark/<cpu>-<march>-<opt>-<run>-i<iterations>[-hpm]/`; its console output is `run.log` there. `make coremark` runs the simulator, then [`coremark.py`](coremark.py) prints the summary and ends in one line, `COREMARK <label>: PASS` or `COREMARK <label>: FAIL`. The target fails unless it says `PASS`. Everything is rebuilt and run on every invocation (the object files are only recompiled when their sources change).

## What `PASS` means

* The program ran to its halt, with no timeout, and the scoreboard of a slow-memory simulator found nothing.
* CoreMark recognised its seeds (`seedcrc` 0xe9f5 for `RUN=performance`, 0x18f2 for `RUN=validation`: 2,000 bytes of data, 666 per algorithm, "2K" in CoreMark's banner) and the three CRCs of the list, matrix and state algorithms after the first iteration equal the known values (performance 0xe714, 0x1fd7, 0x8e3a; validation 0xe3c1, 0x0747, 0x8d84). CoreMark compares them itself and prints `ERROR! ... crc` lines when they differ; any such line fails the run.
* The iteration count printed is the one asked for, and CoreMark's `Total ticks` equals the cycles the port counted.

The CRCs of the first iteration do not depend on the number of iterations. `crcfinal` does (0xfcaf for 10 iterations of the performance run, equal on every build and on the golden CPU).

## The port

[`core_portme.h`](core_portme.h) and [`core_portme.c`](core_portme.c) are written for this repository against the porting interface of `coremark.h`; CoreMark's own files are not touched (a rule of CoreMark's, and `sha256sum -c MANIFEST` in `third_party/coremark/` checks it).

* **Time base: `mcycle`** (CSR 0xB00, Zicntr; the golden CPU has it too). `start_time()` and `stop_time()` read its low 32 bits; the difference is `Total ticks`. **One tick is one clock cycle, and the clock is assumed to be 50 MHz** (`HADES_CLOCK_HZ`, `SYS_CLK_FREQUENCY_MHZ` in `defines/clk_params.sv`): the simulation counts cycles, not time, and only this assumption turns cycles into the seconds CoreMark prints (`Total time (secs)` is 0 in a run this short).
* **Counters around the window.** On HaDes-V+ the port also reads `minstret` (0xB02) at both ends, so the summary gives the instructions and the CPI of the timed window; on the golden CPU, which has no counters, it does not. In a simulator built with `HPM_PRESET` it reads the seven programmable counters `mhpmcounter3-9` as well. Each reading takes a few instructions, so the counters' window differs from `mcycle`'s by a few tens of cycles at each end (more where the reading code is cold).
* **Output.** `ee_printf` writes to the UART with the status-register polling of the other C programs (`std/include/peripherals.h`) and supports what CoreMark prints (`%c %s %d %u %x`, a width, the `0` flag, `l`). After CoreMark's report `portable_fini` prints the `HADES port:`, `HADES instret:` and `HADES hpm<n>:` lines that `coremark.py` reads, and a note that the figures are not a score. No floating point (`HAS_FLOAT 0`).
* **Memory.** The data block is static (`MEM_STATIC`, 2,000 bytes in `.bss`), so the stack, the top 4 KiB of the 32 KiB RAM, stays free. The image is about 9 KiB of code, 1.8 KiB of read-only data and 2.1 KiB of `.bss`. `memset` (which GCC calls in `core_init_state`, outside the timed window) is the port's own; there is no C library.
* **Build.** CoreMark and the port are compiled with the same flags (`-O2 -march=<MARCH> -mabi=ilp32 -fdata-sections -ffunction-sections`, as CoreMark's rules ask; the flags are printed as `Compiler flags`) and linked with `std/hades-v.ld`. The start code of `std/` is compiled for rv32i as for the other benchmarks (nothing of it runs in the timed window). `-march=rv32im_zba_zbb_zbs` is what GCC 12.2 accepts for the core's richer ISA; `zicond`, `zbkb`, `zbkx` and `zknh` are not used by CoreMark's code, and GCC 12.2 has no `zicntr` in `-march` (the port reads the counter CSRs by number).

## The cycle breakdown

The programmable counters can count the classes that divide every cycle into exactly one of six (event codes 32-37 of [`defines/hpm.sv`](../../defines/hpm.sv)): the front end delivering, waiting for fetch, a data hazard, a multiplier or divider stall, a memory wait, a redirect. That is **preset A** (its seventh counter counts mispredicted branches). Preset F splits the hazards, the M-unit stalls and the memory waits further (load hazard, multiply, divide, load, store, I/O). Build a simulator with it and `make coremark` prints the counters of the timed window, each as a share of its cycles:

```bash
make coremark ICACHE=8192 DCACHE=4096 MEM_LAT=8:24 MEM_WR_LAT=4:8 MEM_BEAT_LAT=0 HPM_PRESET=A
```

The six classes add up to the window's cycles within a few hundred cycles of several million (the counters are read a few instructions from `mcycle`, and a cold instruction fetch in that code costs a refill); over a whole run they add up exactly (`+hpm_stats`). An `HPM_PRESET` simulator also checks the counter unit against a model of its own (`HPM_CHECK`). A cached simulator prints the caches' counts for the whole run (`CACHE_STATS`, including `dc_store_wait`).

## A bus trace for the cache model

The standard-memory run, recorded for the trace-driven cache model ([`test/memsys/cachemodel.py`](../memsys/cachemodel.py), [test/memsys/README.md](../memsys/README.md)):

```bash
make coremark BUSTRACE=1                        # build/cfg-trace/test/coremark/<tag>/bustrace.bin, 16 bytes per cycle
python3 test/memsys/cachemodel.py prep <bustrace.bin> <out dir> --ram-kb 32
python3 test/memsys/cachemodel.py run <out dir> --isize 8192 --dsize 4096 --line 16 --mem burst --rd-lat 8:24 --wr-lat 4:8 --wbuf none
python3 test/memsys/cachemodel.py rtlcheck <out dir> <build directory>/cfg-<name>/test/coremark/<tag>/run.log
```

The trace has the cycles of the standard run (the monitor only reads signals). The program has no interrupts, so its instruction stream does not depend on the memory's timing, except for the UART polling at the end, a few thousand cycles: the model's counts of refills, load misses and stores agree exactly with the RTL's (`RTLCHECK: AGREE`), its cycles with the RTL's run to within 0.11 % (below).

## Figures measured so far

Measured on the simulators of this revision, `ITERATIONS=10`, `-O2`, GCC 12.2.0, performance run, 50 MHz assumed. *Cycles* and *instructions* are those of the timed window; CoreMark/MHz is `10 * 10^6 / cycles`. The cached and slow-memory rows use `MEM_LAT=8:24` (reads wait 8 to 24 cycles, drawn per transfer, seed 1), `MEM_BEAT_LAT=0` (the further words of a cache refill follow at one per cycle, as in the earlier CPI study; writes are single words) and write waits as listed; the caches are the 8 KiB I-cache and 4 KiB D-cache of the performance configuration (16-byte lines, direct-mapped, write-through, no write buffer). Every row ends in `COREMARK ...: PASS`.

| Build and memory | Cycles | Instructions | CPI | Cycles per iteration | CoreMark/MHz (estimate) |
|---|---:|---:|---:|---:|---:|
| rv32im, standard RAM | 4,217,860 | 3,081,452 | 1.369 | 421,786 | 2.371 |
| rv32im_zba_zbb_zbs, standard RAM | 4,131,302 | 2,986,224 | 1.383 | 413,130 | 2.421 |
| rv32i, standard RAM | 10,702,860 | 7,414,012 | 1.444 | 1,070,286 | 0.934 |
| rv32i, golden CPU, standard RAM | 10,702,662 | n/a | n/a | 1,070,266 | 0.934 |
| rv32im, I+D caches, writes 1:4 | 4,626,853 | 3,081,452 | 1.502 | 462,685 | 2.161 |
| rv32im, I+D caches, writes 4:8 | 5,153,890 | 3,081,452 | 1.673 | 515,389 | 1.940 |
| rv32im, I+D caches, writes 8:24 | 6,653,779 | 3,081,452 | 2.159 | 665,378 | 1.503 |
| rv32im_zba_zbb_zbs, I+D caches, writes 1:4 | 4,571,378 | 2,986,224 | 1.531 | 457,138 | 2.188 |
| rv32im_zba_zbb_zbs, I+D caches, writes 4:8 | 5,098,327 | 2,986,224 | 1.707 | 509,833 | 1.961 |
| rv32im_zba_zbb_zbs, I+D caches, writes 8:24 | 6,598,106 | 2,986,224 | 2.210 | 659,811 | 1.516 |
| rv32im, I-cache only, writes 1:4 | 13,393,282 | 3,081,452 | 4.346 | 1,339,328 | 0.747 |
| rv32im, no caches, reads and writes 8:24 | 54,182,889 | 3,081,452 | 17.584 | 5,418,289 | 0.185 |
| rv32im_zba_zbb_zbs, no caches, reads and writes 8:24 | 52,553,197 | 2,986,224 | 17.599 | 5,255,320 | 0.190 |

The two rv32i rows differ by 198 cycles (0.002 %); they are not the same binary (the HaDes-V+ build also reads `minstret`). Their output, down to `crcfinal`, is identical. A single iteration costs 521,381 cycles in the 4:8 cached configuration against 515,028 per iteration over 20 (the first iteration pays for cold caches): with 10 iterations the average is about 0.1 % above the steady state.

The cycle classes of the timed window (preset A; the share of the window's cycles; rv32im):

| Memory | Front end delivering | Fetch wait | Hazard | M-unit stall | Memory wait | Redirect |
|---|---:|---:|---:|---:|---:|---:|
| standard RAM | 83.0 % | 0.0 % | 4.8 % | 2.2 % | 0.0 % | 9.9 % |
| I+D caches, writes 1:4 | 75.7 % | 0.1 % | 4.4 % | 2.0 % | 8.7 % | 9.1 % |
| I+D caches, writes 4:8 | 67.9 % | 0.1 % | 3.9 % | 1.8 % | 18.1 % | 8.1 % |
| I+D caches, writes 8:24 | 52.6 % | 0.1 % | 3.1 % | 1.4 % | 36.5 % | 6.3 % |
| I-cache only, writes 1:4 | 26.1 % | 0.0 % | 1.5 % | 0.7 % | 68.5 % | 3.1 % |
| no caches, 8:24 | 4.9 % | 73.5 % | 0.0 % | 0.2 % | 20.7 % | 0.8 % |

With both caches almost all of the memory wait is the stores, which wait for the memory's answer (preset F, memory wait by kind, share of the window's cycles): store 8.1 %, 17.5 % and 36.1 % at write waits 1:4, 4:8 and 8:24, load 0.6 %, 0.5 % and 0.4 %. The whole run has 152,008 stores in 3.15 million instructions (4.8 %), of which 97.8 % hit the D-cache; the data fits the 4 KiB D-cache (1,438 load misses). The instruction side misses little too: 538 refills, an 8 KiB I-cache for about 9 KiB of code. Whole-run store waits (`dc_store_wait`): 7.95 %, 17.20 % and 35.61 % of the cycles. Without the D-cache (I-cache only) the loads wait for the memory instead: 65.6 % of the cycles.

The cache model on the standard-memory trace of the same binary (`coremark-rv32im`, 4,361,915 cycles, 3,150,817 instructions, prepared with `--ram-kb 32`), `--mem burst --rd-lat 8:24 --wbuf none`, against the RTL's whole run (the cycles of the `RETIRED` line, including the start code and the UART report at the end):

| Write latency | RTL cycles | Model cycles | Difference |
|---|---:|---:|---:|
| 1:4 | 4,779,798 | 4,783,137 | +0.07 % |
| 4:8 | 5,312,021 | 5,315,537 | +0.07 % |
| 8:24 | 6,828,286 | 6,835,776 | +0.11 % |

The same holds for the build with Zba, Zbb and Zbs (+0.07 %, +0.06 %, +0.12 %). The latencies are drawn by different generators in the RTL and in the model, so the agreement of the cycles is to be read as one sample, not as an identity; the counts of refills, load misses and stores are equal.

## Notes and limits

* The window is measured from CoreMark's `start_time()` to its `stop_time()`; the start code, the data initialisation and the report (the UART runs at one character per 150 cycles) lie outside it. The `RETIRED` line of a slow-memory simulator covers the whole run.
* A simulation with wait states draws them at random (`MEM_SEED`); other seeds give slightly different cycles.
* The branch predictor is the design's reset value (mode 0, never taken) unless `BPRED` says otherwise; every taken branch is a redirect. `BPRED=2` (backward taken) gives 3,820,054 cycles in the standard RAM (2.618 CoreMark/MHz), `BPRED=3` (2-bit counters) 3,735,652 cycles (2.677); in the cached configuration with writes 4:8, 4,755,979 and 4,671,532 cycles instead of 5,153,890.
* The std objects and the port are small compared with the measured code, but the I-cache holds 8 KiB and the program 9 KiB: the cached figures include the conflict misses of that fit and will move with the size of the cache.
* What this is for: comparing memory-system variants and instruction-set variants on a program that others also run, with the same cycle breakdown as the other benchmarks. For a CoreMark score in the sense of EEMBC, the benchmark has to run for 10 seconds on hardware, with the reporting form of CoreMark's rules.
