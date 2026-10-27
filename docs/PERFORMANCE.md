[HaDes-V+](../README.md) · [Docs](README.md) · [Building](BUILDING.md) · [FreeRTOS](FREERTOS.md) · [Shell](SHELL.md) · [Apps](APPS.md) · [Architecture](ARCHITECTURE.md) · [Extensions](EXTENSIONS.md) · [Verification](VERIFICATION.md) · [Caches](CACHES.md) · **Performance**


# Performance: CoreMark Against CVA6 (Simulation)

This document compares HaDes-V+ with [CVA6](https://github.com/openhwgroup/cva6), the application-class RISC-V core of the OpenHW Group, on the CPU benchmark [CoreMark](https://www.eembc.org/coremark/): the same CoreMark sources, the same compiler, and the same instructions where the instruction sets allow it, counted in cycles of the simulated RTL. HaDes-V+ runs CoreMark with `make coremark` ([test/coremark/README.md](../test/coremark/README.md)). CVA6 runs it in its own Verilator testbench, at commit `742dc82` of its `master` branch (2026-10-23, 259 commits after its release v5.3.0), in two of its configurations: **cv32a65x**, the embedded 32-bit core, and **cv64a6_imafdc_sv39**, the 64-bit core for Linux.

**The figures are estimates, not CoreMark scores.** Every run executes 10 iterations, 2.4 to 5.2 million cycles; CoreMark's rules accept only runs of at least 10 seconds, and CoreMark says so at the end of every run. CoreMark/MHz here is `10 × 10^6 / cycles` of CoreMark's timed window, and it says nothing about the clock frequency either core reaches. Every figure has a record: the HaDes-V+ runs are repeatable ([record](../results/coremark/2026-10-26_cc48658/RECORD.md), `make check-results CHECK_ARGS=coremark`); the CVA6 runs were made outside the repository, with the versions and commands that [their record](../results/coremark-cva6/2026-10-26_173b683/RECORD.md) lists.

**Contents**

1. [Results](#results)
2. [What the Numbers Show](#what-the-numbers-show)
3. [The Cores and Their Memories](#the-cores-and-their-memories)
4. [How It Was Measured](#how-it-was-measured)
5. [What Is Not Compared](#what-is-not-compared)
6. [Running It Again](#running-it-again)

## Results

<p align="center"><img src="img/coremark-cva6.svg" width="900" alt="Horizontal bar chart of CoreMark/MHz estimates in two panels, -O2 and CVA6's CI flags. With -O2: HaDes-V+ 2.37 to 2.75, CVA6 cv32a65x 3.29 and 3.54, CVA6 cv64a6 2.13 to 2.38, HaDes-V+ with caches and a DRAM-like memory 1.94 to 2.16. With the CI flags: HaDes-V+ 2.84 to 3.07, cv32a65x 3.73 and 3.98, cv64a6 2.18 to 2.42."></p>

Two flag sets: `-O2` is what `make coremark` uses (with `-ffunction-sections -fdata-sections`); the *CI flags* are those of CVA6's own CoreMark job ([`verif/regress/coremark.sh`](https://github.com/openhwgroup/cva6/blob/742dc82a0c706e0a3bfb98b709fd3ee06d50d12a/verif/regress/coremark.sh)): `-O3 -g -fno-tree-loop-distribute-patterns -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles -lgcc -funroll-all-loops -ffunction-sections -fdata-sections -Wl,-gc-sections -falign-jumps=4 -falign-functions=16`. *Branch prediction* of HaDes-V+ is its run-time mode: never taken (the reset value, the behaviour of the upstream HaDes-V) or the 2-bit counters (`BPRED=3`).

| Core | `-march` | Branch prediction | Memory | `-O2`: cycles | `-O2`: CoreMark/MHz | CI flags: cycles | CI flags: CoreMark/MHz |
|---|---|---|---|---:|---:|---:|---:|
| HaDes-V+ | `rv32im` | never taken | one-cycle RAM | 4,217,860 | 2.371 | 3,518,733 | 2.842 |
| HaDes-V+ | `rv32im` | 2-bit, 32 entries | one-cycle RAM | 3,735,652 | 2.677 | 3,336,029 | 2.998 |
| HaDes-V+ | `rv32im_zba_zbb_zbs` | never taken | one-cycle RAM | 4,131,302 | 2.421 | 3,443,113 | 2.904 |
| HaDes-V+ | `rv32im_zba_zbb_zbs` | 2-bit, 32 entries | one-cycle RAM | 3,642,478 | 2.745 | 3,257,719 | 3.070 |
| CVA6 cv32a65x | `rv32im` | BHT 32, RAS 2, no BTB | I$ 2 KiB, D$ 2 KiB; testbench memory | 3,040,438 | **3.289** | 2,679,747 | **3.732** |
| CVA6 cv32a65x | `rv32imc_zba_zbb_zbs_zbc` | BHT 32, RAS 2, no BTB | I$ 2 KiB, D$ 2 KiB; testbench memory | 2,822,829 | **3.543** | 2,511,386 | **3.982** |
| CVA6 cv64a6 | `rv64im` | BHT 128, BTB 32, RAS 2 | I$ 16 KiB, D$ 32 KiB; testbench memory | 4,701,238 | 2.127 | 4,587,616 | 2.180 |
| CVA6 cv64a6 | `rv64imac` | BHT 128, BTB 32, RAS 2 | I$ 16 KiB, D$ 32 KiB; testbench memory | 4,582,955 | 2.182 | 4,552,923 | 2.196 |
| CVA6 cv64a6 | `rv64gc` | BHT 128, BTB 32, RAS 2 | I$ 16 KiB, D$ 32 KiB; testbench memory | 4,582,955 | 2.182 | 4,552,916 | 2.196 |
| CVA6 cv64a6 | `rv64gc_zba_zbb_zbs_zbc_zbkb_zbkx_zkne_zknd_zknh` | BHT 128, BTB 32, RAS 2 | I$ 16 KiB, D$ 32 KiB; testbench memory | 4,207,910 | 2.376 | 4,138,860 | 2.416 |
| *HaDes-V+, cached* | `rv32im` | never taken | I$ 8 KiB, D$ 4 KiB; reads 8-24, writes 4-8 cycles | 5,153,890 | *1.940* | 4,680,761 | *2.136* |
| *HaDes-V+, cached* | `rv32im` | 2-bit, 32 entries | I$ 8 KiB, D$ 4 KiB; reads 8-24, writes 4-8 cycles | 4,671,532 | *2.141* | 4,495,884 | *2.224* |
| *HaDes-V+, cached* | `rv32im_zba_zbb_zbs` | never taken | I$ 8 KiB, D$ 4 KiB; reads 8-24, writes 4-8 cycles | 5,098,327 | *1.961* | 4,723,826 | *2.117* |
| *HaDes-V+, cached* | `rv32im_zba_zbb_zbs` | 2-bit, 32 entries | I$ 8 KiB, D$ 4 KiB; reads 8-24, writes 4-8 cycles | 4,630,376 | *2.160* | 4,545,221 | *2.200* |

The rows in italics, HaDes-V+ with its simulation-only caches in front of a DRAM-like memory model ([docs/CACHES.md](CACHES.md)), are context: their memory is not comparable with CVA6's testbench memory (see [The Cores and Their Memories](#the-cores-and-their-memories)). Every run printed CoreMark's CRCs of the performance run, `seedcrc` 0xe9f5, `crclist` 0xe714, `crcmatrix` 0x1fd7, `crcstate` 0x8e3a, and `crcfinal` 0xfcaf for 10 iterations.

## What the Numbers Show

**The same instructions.** With `-march=rv32im` both 32-bit cores run the same code: the timed window holds 3,081,452 instructions on HaDes-V+ and 3,081,459 on cv32a65x at `-O2` (2,719,460 and 2,719,467 with the CI flags; the ports read the counters a few instructions apart). The differences between them are differences in cycles per instruction.

**cv32a65x is 22.9 % faster per MHz than HaDes-V+ at the same instructions, and 29.0 % to 29.7 % with each core's best instruction set.** The comparison is HaDes-V+ with its 2-bit predictor: 2.677 against 3.289 at `-O2` (2.998 against 3.732, 24.5 %, with the CI flags), and 2.745 with Zba, Zbb and Zbs against 3.543 with C and the B extensions. HaDes-V+ is 15.5 % to 27.0 % faster per MHz than cv64a6 with its best instruction set (2.376 and 2.416).

**cv32a65x issues up to two instructions per cycle; a single-issue core cannot get there.** A core that issues one instruction per cycle needs at least as many cycles as instructions: at most 3.245 CoreMark/MHz for the `rv32im` `-O2` code (3.677 with the CI flags). cv32a65x is above that bound (1.013 instructions per cycle at `rv32im`, 1.058 with its best instruction set) because it issues and commits up to two per cycle. HaDes-V+ with the 2-bit predictor reaches 82.5 % of the bound. cv64a6 issues one instruction per cycle; it reaches 0.745 to 0.772 instructions per cycle at `-O2` and runs the 64-bit code of CoreMark's 16- and 32-bit arithmetic, which needs 14.9 % more instructions than `rv32im` (3,540,217).

**Where the cycles of HaDes-V+ go.** The performance counters divide every cycle into one class ([docs/EXTENSIONS.md](EXTENSIONS.md); preset A, `rv32im`, `-O2`, one-cycle RAM):

| Cycles of the timed window | Never taken | 2-bit counters |
|---|---:|---:|
| One per instruction | 3,081,467 | 3,081,467 |
| Redirects: a taken branch or a jump (never taken), a mispredicted branch or a jump (2-bit), two cycles each | 419,503 × 2 = 839,006 | 178,399 × 2 = 356,798 |
| Data hazards | 203,447 | 203,447 |
| Multiply and divide | 93,960 | 93,960 |
| Waiting for fetch or memory | 0 | 0 |
| Sum (the counters are read a few instructions away from `mcycle`) | 4,217,880 | 3,735,672 |

A redirect costs two cycles: the counters put one in `REDIRECT_ANY` and the other in `FRONT_OK`, which therefore exceeds the instructions by exactly the redirects. Of the 178,399 redirects with the 2-bit counters, 80,861 are mispredicted branches; the other 97,538 are jumps (`jal`, `jalr`), which the predictor does not predict. Removing every lost cycle would give the single-issue bound, 3.245 CoreMark/MHz, still below cv32a65x.

**The caches hardly matter in CVA6's testbench.** Its memory answers a miss within a few cycles (measured below, [Memories](#the-cores-and-their-memories)), so cv32a65x's 2 KiB caches cost little: the same configuration with 16 KiB caches is 1.5 % faster at `rv32im` `-O2` (2,994,922 cycles) and 4.5 % with its best instruction set and the CI flags (2,403,579).

**Compressed and bit-manipulation instructions.** Zba, Zbb and Zbs remove 3.1 % of the instructions on both 32-bit cores (3,081,452 to 2,986,224); HaDes-V+ gains 2.6 % with the 2-bit predictor. cv32a65x gains 7.7 % at `-O2` from C and the B extensions together: the same 3.1 % fewer instructions, and code in which 56.1 % of the executed instructions are 16 bits long (CoreMark's code shrinks from 6,220 to 4,056 bytes); its instructions per cycle rise from 1.013 to 1.058. CoreMark uses no Zbc instruction.

**The CI flags.** `-O3 -funroll-all-loops` removes 11.7 % of the `rv32im` instructions and 40.2 % of the taken branches and jumps (419,504 to 250,863 in cv32a65x's trace), and makes CoreMark's code about 2.7 times as large. HaDes-V+ gains 19.9 % without prediction, where every taken branch costs two cycles, and 12.0 % with the 2-bit predictor; cv32a65x 12.4 to 13.5 %; cv64a6, whose 64-bit code loses few instructions to unrolling, 0.7 to 2.5 %.

**HaDes-V+ with caches and a slow memory.** The cached rows lose 18.2 to 21.3 % against the one-cycle RAM at `-O2` and 24.8 to 28.3 % with the CI flags, whose unrolled code no longer fits the 8 KiB instruction cache (13,906 instruction refills in the whole `rv32im` run instead of 538). At `-O2` most of the loss is stores waiting for the memory: the data cache writes through and has no write buffer ([test/coremark/README.md](../test/coremark/README.md#figures-measured-so-far)).

## The Cores and Their Memories

| | HaDes-V+ | CVA6 cv32a65x | CVA6 cv64a6_imafdc_sv39 |
|---|---|---|---|
| Instruction set | RV32IM, Zba, Zbb, Zbs, Zicond, Zbkb, Zbkx, Zknh, Zicntr; M-mode | RV32IMC, Zba, Zbb, Zbc, Zbs, Zcb; M-mode, no MMU | RV64GC, Zba, Zbb, Zbc, Zbs, Zbkb, Zbkx, Zkne, Zknd, Zknh, Zcb, Zicond; Sv39 |
| Pipeline | 5 stages, single issue, in order; branches resolved in Execute (two cycles per redirect), one bubble per load-use | 6 stages, dual issue (2 ALUs, 2 commit ports), scoreboard of 8 | 6 stages, single issue, scoreboard of 8 |
| Branch prediction | never taken (reset value) or one of three others at run time; jumps not predicted | BHT of 32 entries, no BTB, return-address stack of 2 | BHT of 128, BTB of 32, return-address stack of 2 |
| Caches | none in the standard build | I$ 2 KiB 2-way, D$ 2 KiB 2-way (HPDcache, write-through), 16-byte lines | I$ 16 KiB 4-way, D$ 32 KiB 8-way (write-through), 16-byte lines |
| Memory in simulation | one RAM that answers in the cycle of the request | AXI crossbar, atomics adapter, `axi_delayer` without delay, `axi2mem`, single-cycle SRAM | the same |

cv32a65x's configuration package gives its data cache as `DcacheByteSize: 2028`; the index width rounds it up to 1 KiB per way, 2 KiB in all. A small program run in the same testbench measured what a miss costs ([`memlat.c`](../results/coremark-cva6/2026-10-26_173b683/memlat.c)):

| | Dependent load, 256 KiB pointer chase | Same chase within 1 KiB | 32 KiB of straight-line code | 1 KiB of code, repeated |
|---|---:|---:|---:|---:|
| cv32a65x | 9.00 cycles per load | 3.00 | 7.00 cycles per 16-byte line | 2.12 |
| cv64a6 | 8.00 (about one load in eight still hits its 32 KiB D$) | 4.00 | 8.11 | 4.13 |

A miss costs about 4 to 6 cycles more than a hit: the testbench memory is nearly ideal, as the one-cycle RAM of HaDes-V+ is. A DRAM, or a memory behind a slower interconnect, would cost both cores more, and cv32a65x's small caches would then matter.

## How It Was Measured

* **Versions.** HaDes-V+ at commit `cc48658`, Verilator 5.042. CVA6 at [`742dc82`](https://github.com/openhwgroup/cva6/tree/742dc82a0c706e0a3bfb98b709fd3ee06d50d12a) (its `master` branch, 259 commits after the release `v5.3.0` of 2025-02-03, read-only since 2026-10-23), with the submodules of that commit, in its open-source testbench (`verif/sim/cva6.py --iss=veri-testharness`) and the tools the repository pins for it: Verilator 5.008 with CVA6's patch, and Spike 1.1.1-dev from its `core-v-verif` submodule (`b3149ab0`), whose libraries the testbench links.
* **Compiler: GCC 12.2.0 for all.** Both 32-bit cores: `riscv32-unknown-elf-gcc` 12.2.0 with binutils 2.39, the compiler of the rest of this repository. cv64a6: the xPack GNU RISC-V Embedded GCC 12.2.0-3 (`riscv-none-elf-gcc`, binutils 2.38), its archive checked against the published SHA-256. Both compilers turn CoreMark's files and the HaDes-V+ port into the same instructions at the 32-bit instruction sets of the comparison (27 objects, both flag sets).
* **The same CoreMark.** All cores run the core files of CoreMark at commit `1f483d5`, which [`third_party/coremark/`](../third_party/coremark/README.md) holds. CVA6's repository has its own, older copies, changed for its CI (among other things a full untimed run of all iterations before the timed one); they were replaced by the upstream files. CVA6's port (`core_portme.c`, `core_portme.h`, `uart.c`) and its start-up code, system calls and linker script are used as they are. One run with CVA6's own copies (cv32a65x, best instruction set, CI flags) took 2,510,685 cycles against 2,511,386.
* **The timed window.** Both ports read `mcycle` at CoreMark's `start_time()` and `stop_time()`; CoreMark prints the difference as `Total ticks`, the cycles of the table. HaDes-V+ also reads `minstret`. For CVA6, whose CI build does not print its counters, the instructions are counted in the testbench's RVFI trace, between the two reads of `mcycle`.
* **Validation.** A run counts only with CoreMark's 2K performance banner, 10 iterations and the CRCs above. CoreMark's own `ERROR!` line about the 10 seconds appears in every run and is the only one.

## What Is Not Compared

* **Clock frequency, area and power.** All figures are per MHz. HaDes-V+ met 50 MHz on an Artix-7 with almost no margin when its timing was last measured ([README](../README.md#status-and-limitations)); CVA6, with its longer pipeline, is designed for considerably higher clocks. A comparison per second would need both implemented in the same technology.
* **Memory.** HaDes-V+'s standard RAM answers in the cycle of the request and has no cache; no memory at a realistic clock can do that. CVA6's testbench memory is nearly ideal too, but CVA6 pays for its misses. The cached HaDes-V+ rows use a different memory model and are not comparable with either.
* **Instruction sets beyond GCC 12.2.** GCC 12.2 cannot emit Zcb or Zicond; a newer compiler would change the figures for the best instruction sets of all three cores.
* **Run length.** Ten iterations, not CoreMark's 10 seconds. The cold start is in the figures, and it is small: CVA6's own copies, which run every iteration once untimed before the timed run, change cv32a65x's cycles by 0.03 %.

## Running It Again

HaDes-V+, from the repository root (`make coremark` prints the summary with the CRC checks and ends in `COREMARK ...: PASS`):

```bash
make coremark                                            # rv32im, -O2, never taken, one-cycle RAM
make coremark BPRED=3 MARCH=rv32im_zba_zbb_zbs           # the 2-bit predictor, Zba, Zbb and Zbs
make coremark ICACHE=8192 DCACHE=4096 MEM_LAT=8:24 MEM_WR_LAT=4:8 MEM_BEAT_LAT=0   # the cached rows
make coremark HPM_PRESET=A                               # with the cycle classes
make coremark OPT=-O3 "CM_FLAGS=<the CI flags above> -march=rv32im -mabi=ilp32"     # the CI flags
make check-results CHECK_ARGS=coremark                   # every HaDes-V+ figure of this document
```

CVA6, in a clone of its repository at `742dc82` with its submodules, after `verif/regress/install-verilator.sh` and `verif/regress/install-spike.sh`, from `verif/sim`, with `COREMARK` the directory that holds the upstream core files and CVA6's port files:

```bash
python3 cva6.py --target cv32a65x --iss=veri-testharness --iss_yaml=cva6.yaml --iss_timeout=40000 --c_tests $COREMARK/core_main.c \
  --gcc_opts "$COREMARK/uart.c $COREMARK/core_list_join.c $COREMARK/core_matrix.c $COREMARK/core_portme.c \
    $COREMARK/core_state.c $COREMARK/core_util.c ../tests/custom/common/syscalls.c ../tests/custom/common/crt.S \
    <flags> -DITERATIONS=10 -DPERFORMANCE_RUN -DSKIP_TIME_CHECK -DNOPRINT -I../tests/custom/env \
    -I../tests/custom/common -march=rv32im -mabi=ilp32" --issrun_opts="+debug_disable=1 +time_out=400000000"
```

Four adjustments were needed; [the record](../results/coremark-cva6/2026-10-26_173b683/RECORD.md) has the exact commands of every run:

* `+time_out=400000000`: otherwise the testbench's tracer ends every simulation after 2,000,000 cycles.
* With plain `-O2`, GCC turns the byte loop of `syscalls.c`'s `memset` into a call to `memset` itself, an endless recursion at start-up; `syscalls.c` is therefore compiled with `-fno-tree-loop-distribute-patterns`, which the CI flags contain anyway.
* `cva6.py` reads the compiler's version from the third word of `gcc --version`, which the xPack compiler's banner does not have there; a two-line wrapper answers `--version` for it.
* Spike's `configure` was run with `--with-boost-regex=no`: its check for Boost.Regex failed on Ubuntu 24.04.

CoreMark is a trademark of EEMBC.
