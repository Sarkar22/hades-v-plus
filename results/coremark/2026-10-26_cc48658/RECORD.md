# CoreMark on HaDes-V+: 2026-10-26, cc48658

**Status: repeatable.** `make check-results CHECK_ARGS=coremark` re-runs the 42 `make coremark` commands and the 14 cache-model commands below and compares what they print with what this record stores: the summary of every run, its console log (without Verilator's run statistics), the sha256 of every program image, and the output of every cache-model command (with its wall time written as `#` and the build directory as `build/`).

## The figures and where they are quoted

[test/coremark/README.md](../../../test/coremark/README.md) and [docs/PERFORMANCE.md](../../../docs/PERFORMANCE.md) quote these figures; [`meta.json`](meta.json) lists each with the lines that quote it. The table of "Figures measured so far" in test/coremark/README.md, row by row (each row equals the `RESULT` line of its run):

| Row as quoted | Run | Cycles | Instructions | CPI | Cycles per iteration | CoreMark/MHz |
|---|---|---:|---:|---:|---:|---:|
| rv32im, standard RAM | `std-rv32im` | 4,217,860 | 3,081,452 | 1.369 | 421,786 | 2.371 |
| rv32im_zba_zbb_zbs, standard RAM | `std-zb` | 4,131,302 | 2,986,224 | 1.383 | 413,130 | 2.421 |
| rv32i, standard RAM | `std-rv32i` | 10,702,860 | 7,414,012 | 1.444 | 1,070,286 | 0.934 |
| rv32i, golden CPU, standard RAM | `golden` | 10,702,662 | n/a | n/a | 1,070,266 | 0.934 |
| rv32im, I+D caches, writes 1:4 | `c14-rv32im` | 4,626,853 | 3,081,452 | 1.502 | 462,685 | 2.161 |
| rv32im, I+D caches, writes 4:8 | `c48-rv32im` | 5,153,890 | 3,081,452 | 1.673 | 515,389 | 1.940 |
| rv32im, I+D caches, writes 8:24 | `c824-rv32im` | 6,653,779 | 3,081,452 | 2.159 | 665,378 | 1.503 |
| rv32im_zba_zbb_zbs, I+D caches, writes 1:4 | `c14-zb` | 4,571,378 | 2,986,224 | 1.531 | 457,138 | 2.188 |
| rv32im_zba_zbb_zbs, I+D caches, writes 4:8 | `c48-zb` | 5,098,327 | 2,986,224 | 1.707 | 509,833 | 1.961 |
| rv32im_zba_zbb_zbs, I+D caches, writes 8:24 | `c824-zb` | 6,598,106 | 2,986,224 | 2.210 | 659,811 | 1.516 |
| rv32im, I-cache only, writes 1:4 | `ionly14-rv32im` | 13,393,282 | 3,081,452 | 4.346 | 1,339,328 | 0.747 |
| rv32im, no caches, reads and writes 8:24 | `nocache824-rv32im` | 54,182,889 | 3,081,452 | 17.584 | 5,418,289 | 0.185 |
| rv32im_zba_zbb_zbs, no caches, reads and writes 8:24 | `nocache824-zb` | 52,553,197 | 2,986,224 | 17.599 | 5,255,320 | 0.190 |

The other figures:

| Figure as quoted | Quoted in | Measured here |
|---|---|---|
| The two rv32i rows differ by 198 cycles (0.002 %) | test/coremark/README.md:94 | std-rv32i 10,702,860 - golden 10,702,662 = 198 |
| A single iteration costs 521,381 cycles in the 4:8 cached configuration against 515,028 per iteration over 20; with 10 iterations the average is about 0.1 % above the steady state | test/coremark/README.md:94 | c48-rv32im-i1 521,381 cycles; c48-rv32im-i20 10,300,555 / 20 = 515,028; 515,389 / 515,028 - 1 = 0.07 % |
| The cycle classes of the timed window (preset A), six memories | test/coremark/README.md:100, test/coremark/README.md:101, test/coremark/README.md:105 | hpmA-std-rv32im: FRONT_OK 83.00 % FETCH_WAIT 0.00 % HAZARD 4.82 % MSTALL_ANY 2.23 % MEMWAIT_ANY 0.00 % REDIRECT_ANY 9.95 %; hpmA-c14-rv32im: FRONT_OK 75.65 % FETCH_WAIT 0.12 % HAZARD 4.40 % MSTALL_ANY 2.03 % MEMWAIT_ANY 8.73 % REDIRECT_ANY 9.07 %; hpmA-c48-rv32im: FRONT_OK 67.92 % FETCH_WAIT 0.11 % HAZARD 3.95 % MSTALL_ANY 1.82 % MEMWAIT_ANY 18.06 % REDIRECT_ANY 8.14 %; hpmA-c824-rv32im: FRONT_OK 52.61 % FETCH_WAIT 0.09 % HAZARD 3.06 % MSTALL_ANY 1.41 % MEMWAIT_ANY 36.53 % REDIRECT_ANY 6.30 %; hpmA-ionly14-rv32im: FRONT_OK 26.15 % FETCH_WAIT 0.04 % HAZARD 1.52 % MSTALL_ANY 0.70 % MEMWAIT_ANY 68.46 % REDIRECT_ANY 3.13 %; hpmA-nocache824-rv32im: FRONT_OK 4.89 % FETCH_WAIT 73.49 % HAZARD 0.00 % MSTALL_ANY 0.17 % MEMWAIT_ANY 20.67 % REDIRECT_ANY 0.77 % |
| The six classes add up to the window's cycles within a few hundred cycles; the counters' window differs from mcycle's by a few tens of cycles at each end | test/coremark/README.md:59, test/coremark/README.md:46 | hpmA-std-rv32im: 4,217,880 of 4,217,916 (-36); hpmA-c14-rv32im: 4,627,518 of 4,627,642 (-124); hpmA-c48-rv32im: 5,154,399 of 5,154,558 (-159); hpmA-c824-rv32im: 6,654,396 of 6,654,634 (-238); hpmA-ionly14-rv32im: 13,389,369 of 13,389,518 (-149); hpmA-nocache824-rv32im: 54,180,765 of 54,181,122 (-357) |
| Memory wait by kind (preset F): store 8.1 %, 17.5 % and 36.1 %, load 0.6 %, 0.5 % and 0.4 % | test/coremark/README.md:107 | hpmF-c14-rv32im: MEMWAIT_STORE 8.12 %, MEMWAIT_LOAD 0.61 %; hpmF-c48-rv32im: MEMWAIT_STORE 17.51 %, MEMWAIT_LOAD 0.55 %; hpmF-c824-rv32im: MEMWAIT_STORE 36.11 %, MEMWAIT_LOAD 0.42 % |
| 152,008 stores in 3.15 million instructions (4.8 %), 97.8 % of them D-cache hits; 1,438 load misses; 538 refills; whole-run store waits 7.95 %, 17.20 % and 35.61 % | test/coremark/README.md:107 | CACHE_STATS of c14-rv32im, c48-rv32im and c824-rv32im: caches, whole run (CACHE_STATS): instruction refills 538, load misses 1438, stores 152008 (hits 148651, misses 3357) store wait 380223 cycles = 7.95 % of the run / caches, whole run (CACHE_STATS): instruction refills 538, load misses 1438, stores 152008 (hits 148651, misses 3357) store wait 913670 cycles = 17.20 % of the run / caches, whole run (CACHE_STATS): instruction refills 538, load misses 1438, stores 152008 (hits 148651, misses 3357) store wait 2431891 cycles = 35.61 % of the run |
| Without the D-cache the loads wait for the memory: 65.6 % of the cycles | test/coremark/README.md:107 | hpmF-ionly14-rv32im: MEMWAIT_LOAD 65.65 % |
| The standard-memory trace: 4,361,915 cycles, 3,150,817 instructions | test/coremark/README.md:109 | model-rv32im-prep: cycles 4,361,915, retired 3,150,817 |
| RTL and model cycles at writes 1:4, 4:8, 8:24 and their differences (rv32im), and the differences with Zba, Zbb and Zbs (+0.07 %, +0.06 %, +0.12 %) | test/coremark/README.md:113, test/coremark/README.md:115, test/coremark/README.md:117 | rv32im 1:4: RETIRED 4,779,798, model 4,783,137, +0.07 %; rv32im 4:8: RETIRED 5,312,021, model 5,315,537, +0.07 %; rv32im 8:24: RETIRED 6,828,286, model 6,835,776, +0.11 %; zb 1:4: RETIRED 4,725,400, model 4,728,865, +0.07 %; zb 4:8: RETIRED 5,257,691, model 5,260,614, +0.06 %; zb 8:24: RETIRED 6,773,629, model 6,781,476, +0.12 % |
| RTLCHECK: AGREE; the counts of refills, load misses and stores are equal | test/coremark/README.md:72 | 6 of 6 rtlcheck commands: RTLCHECK: AGREE |
| BPRED=2 gives 3,820,054 cycles (2.618), BPRED=3 3,735,652 (2.677); cached with writes 4:8, 4,755,979 and 4,671,532 instead of 5,153,890 | test/coremark/README.md:123 | std-rv32im-bp2 3,820,054, std-rv32im-bp3 3,735,652, c48-rv32im-bp2 4,755,979, c48-rv32im-bp3 4,671,532, c48-rv32im 5,153,890 |
| About 9 KiB of code, 1.8 KiB of read-only data and 2.1 KiB of .bss; the program 9 KiB | test/coremark/README.md:48, test/coremark/README.md:124 | std-rv32im: text 9120, rodata 1760, data 12, bss 2084 bytes |
| The 16 HaDes-V+ rows of the table: cycles and CoreMark/MHz with -O2 and with CVA6's CI flags, and the HaDes-V+ bars of docs/img/coremark-cva6.svg | docs/PERFORMANCE.md:27, docs/PERFORMANCE.md:28, docs/PERFORMANCE.md:29, docs/PERFORMANCE.md:30, docs/PERFORMANCE.md:37, docs/PERFORMANCE.md:38, docs/PERFORMANCE.md:39, docs/PERFORMANCE.md:40, docs/PERFORMANCE.md:21 | std-rv32im 4,217,860, ci-std-rv32im 3,518,733; std-rv32im-bp3 3,735,652, ci-std-rv32im-bp3 3,336,029; std-zb 4,131,302, ci-std-zb 3,443,113; std-zb-bp3 3,642,478, ci-std-zb-bp3 3,257,719; c48-rv32im 5,153,890, ci-c48-rv32im 4,680,761; c48-rv32im-bp3 4,671,532, ci-c48-rv32im-bp3 4,495,884; c48-zb 5,098,327, ci-c48-zb 4,723,826; c48-zb-bp3 4,630,376, ci-c48-zb-bp3 4,545,221 |
| Instructions of the timed window: 3,081,452 (rv32im, -O2), 2,719,460 (CI flags), 2,986,224 (Zba, Zbb, Zbs) | docs/PERFORMANCE.md:46 | std-rv32im 3,081,452, ci-std-rv32im 2,719,460, std-zb 2,986,224 |
| The single-issue bounds and the share of the bound that HaDes-V+ reaches | docs/PERFORMANCE.md:50 | 10^7 / 3,081,452 = 3.245; 10^7 / 2,719,460 = 3.677; 2.677 / 3.245 = 82.5 % |
| The cycles of the timed window by class (never taken, 2-bit counters) | docs/PERFORMANCE.md:56, docs/PERFORMANCE.md:61 | hpmA-std-rv32im: FRONT_OK 3,500,970, REDIRECT_ANY 419,503, HAZARD 203,447, MSTALL_ANY 93,960, FETCH_WAIT 0, MEMWAIT_ANY 0, instructions 3,081,467, 4,217,880 of 4,217,916 (-36); hpmA-std-rv32im-bp3: FRONT_OK 3,259,866, REDIRECT_ANY 178,399, HAZARD 203,447, MSTALL_ANY 93,960, FETCH_WAIT 0, MEMWAIT_ANY 0, instructions 3,081,467, 3,735,672 of 3,735,708 (-36) |
| Of the redirects with the 2-bit counters, the mispredicted branches and the jumps | docs/PERFORMANCE.md:63 | hpmA-std-rv32im-bp3: REDIRECT_ANY 178,399, BR_MISPREDICT 80,861, the rest 97,538; hpmA-std-rv32im: 419,503 - 321,965 = 97,538 |
| Zba, Zbb and Zbs remove 3.1 % of the instructions; HaDes-V+ gains 2.6 % with the 2-bit predictor | docs/PERFORMANCE.md:67 | 1 - 2,986,224 / 3,081,452; 3,735,652 / 3,642,478 - 1 |
| The CI flags remove 11.7 % of the rv32im instructions; HaDes-V+ gains 19.9 % without prediction and 12.0 % with the 2-bit predictor | docs/PERFORMANCE.md:69 | 1 - 2,719,460 / 3,081,452; 4,217,860 / 3,518,733 - 1; 3,735,652 / 3,336,029 - 1 |
| The cached rows lose 18.2 to 21.3 % at -O2 and 24.8 to 28.3 % with the CI flags; 13,906 instruction refills instead of 538 | docs/PERFORMANCE.md:71 | CoreMark/MHz of c48-* against std-* and of ci-c48-* against ci-std-* (results.csv); CACHE_STATS: ci-c48-rv32im 13906, c48-rv32im 538 instruction refills |

The figures of docs/PERFORMANCE.md that set these runs against CVA6's are in [the CVA6 record](../../coremark-cva6/2026-10-26_173b683/RECORD.md).

## Commands

From the repository root, on cc48658. Each `make` was given `BUILD_JOBS=4` as well, which limits the parallel jobs of the Verilator builds and changes no output. The first command of each simulator configuration builds that simulator.

```
std-rv32im               make coremark
std-zb                   make coremark MARCH=rv32im_zba_zbb_zbs
std-rv32i                make coremark MARCH=rv32i
golden                   make coremark CPU=golden
c14-rv32im               make coremark ICACHE=8192 DCACHE=4096 MEM_LAT=8:24 MEM_BEAT_LAT=0 MEM_WR_LAT=1:4
c48-rv32im               make coremark ICACHE=8192 DCACHE=4096 MEM_LAT=8:24 MEM_BEAT_LAT=0 MEM_WR_LAT=4:8
c824-rv32im              make coremark ICACHE=8192 DCACHE=4096 MEM_LAT=8:24 MEM_BEAT_LAT=0 MEM_WR_LAT=8:24
c14-zb                   make coremark ICACHE=8192 DCACHE=4096 MEM_LAT=8:24 MEM_BEAT_LAT=0 MEM_WR_LAT=1:4 MARCH=rv32im_zba_zbb_zbs
c48-zb                   make coremark ICACHE=8192 DCACHE=4096 MEM_LAT=8:24 MEM_BEAT_LAT=0 MEM_WR_LAT=4:8 MARCH=rv32im_zba_zbb_zbs
c824-zb                  make coremark ICACHE=8192 DCACHE=4096 MEM_LAT=8:24 MEM_BEAT_LAT=0 MEM_WR_LAT=8:24 MARCH=rv32im_zba_zbb_zbs
ionly14-rv32im           make coremark ICACHE=8192 MEM_LAT=8:24 MEM_WR_LAT=1:4 MEM_BEAT_LAT=0
nocache824-rv32im        make coremark MEM_LAT=8:24 MEM_WR_LAT=8:24
nocache824-zb            make coremark MEM_LAT=8:24 MEM_WR_LAT=8:24 MARCH=rv32im_zba_zbb_zbs
c48-rv32im-i1            make coremark ICACHE=8192 DCACHE=4096 MEM_LAT=8:24 MEM_BEAT_LAT=0 MEM_WR_LAT=4:8 ITERATIONS=1
c48-rv32im-i20           make coremark ICACHE=8192 DCACHE=4096 MEM_LAT=8:24 MEM_BEAT_LAT=0 MEM_WR_LAT=4:8 ITERATIONS=20
hpmA-std-rv32im          make coremark HPM_PRESET=A
hpmA-std-rv32im-bp3      make coremark HPM_PRESET=A BPRED=3
hpmA-c14-rv32im          make coremark ICACHE=8192 DCACHE=4096 MEM_LAT=8:24 MEM_BEAT_LAT=0 MEM_WR_LAT=1:4 HPM_PRESET=A
hpmA-c48-rv32im          make coremark ICACHE=8192 DCACHE=4096 MEM_LAT=8:24 MEM_BEAT_LAT=0 MEM_WR_LAT=4:8 HPM_PRESET=A
hpmA-c824-rv32im         make coremark ICACHE=8192 DCACHE=4096 MEM_LAT=8:24 MEM_BEAT_LAT=0 MEM_WR_LAT=8:24 HPM_PRESET=A
hpmA-ionly14-rv32im      make coremark ICACHE=8192 MEM_LAT=8:24 MEM_WR_LAT=1:4 MEM_BEAT_LAT=0 HPM_PRESET=A
hpmA-nocache824-rv32im   make coremark MEM_LAT=8:24 MEM_WR_LAT=8:24 HPM_PRESET=A
hpmF-c14-rv32im          make coremark ICACHE=8192 DCACHE=4096 MEM_LAT=8:24 MEM_BEAT_LAT=0 MEM_WR_LAT=1:4 HPM_PRESET=F
hpmF-c48-rv32im          make coremark ICACHE=8192 DCACHE=4096 MEM_LAT=8:24 MEM_BEAT_LAT=0 MEM_WR_LAT=4:8 HPM_PRESET=F
hpmF-c824-rv32im         make coremark ICACHE=8192 DCACHE=4096 MEM_LAT=8:24 MEM_BEAT_LAT=0 MEM_WR_LAT=8:24 HPM_PRESET=F
hpmF-ionly14-rv32im      make coremark ICACHE=8192 MEM_LAT=8:24 MEM_WR_LAT=1:4 MEM_BEAT_LAT=0 HPM_PRESET=F
std-rv32im-bp2           make coremark BPRED=2
std-rv32im-bp3           make coremark BPRED=3
c48-rv32im-bp2           make coremark ICACHE=8192 DCACHE=4096 MEM_LAT=8:24 MEM_BEAT_LAT=0 MEM_WR_LAT=4:8 BPRED=2
c48-rv32im-bp3           make coremark ICACHE=8192 DCACHE=4096 MEM_LAT=8:24 MEM_BEAT_LAT=0 MEM_WR_LAT=4:8 BPRED=3
std-zb-bp3               make coremark MARCH=rv32im_zba_zbb_zbs BPRED=3
c48-zb-bp3               make coremark ICACHE=8192 DCACHE=4096 MEM_LAT=8:24 MEM_BEAT_LAT=0 MEM_WR_LAT=4:8 MARCH=rv32im_zba_zbb_zbs BPRED=3
ci-std-rv32im            make coremark OPT=-O3 "CM_FLAGS=-O3 -g -fno-tree-loop-distribute-patterns -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles -lgcc -funroll-all-loops -ffunction-sections -fdata-sections -Wl,-gc-sections -falign-jumps=4 -falign-functions=16 -march=rv32im -mabi=ilp32"
ci-std-rv32im-bp3        make coremark OPT=-O3 "CM_FLAGS=-O3 -g -fno-tree-loop-distribute-patterns -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles -lgcc -funroll-all-loops -ffunction-sections -fdata-sections -Wl,-gc-sections -falign-jumps=4 -falign-functions=16 -march=rv32im -mabi=ilp32" BPRED=3
ci-std-zb                make coremark OPT=-O3 "CM_FLAGS=-O3 -g -fno-tree-loop-distribute-patterns -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles -lgcc -funroll-all-loops -ffunction-sections -fdata-sections -Wl,-gc-sections -falign-jumps=4 -falign-functions=16 -march=rv32im_zba_zbb_zbs -mabi=ilp32" MARCH=rv32im_zba_zbb_zbs
ci-std-zb-bp3            make coremark OPT=-O3 "CM_FLAGS=-O3 -g -fno-tree-loop-distribute-patterns -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles -lgcc -funroll-all-loops -ffunction-sections -fdata-sections -Wl,-gc-sections -falign-jumps=4 -falign-functions=16 -march=rv32im_zba_zbb_zbs -mabi=ilp32" MARCH=rv32im_zba_zbb_zbs BPRED=3
ci-c48-rv32im            make coremark ICACHE=8192 DCACHE=4096 MEM_LAT=8:24 MEM_BEAT_LAT=0 MEM_WR_LAT=4:8 OPT=-O3 "CM_FLAGS=-O3 -g -fno-tree-loop-distribute-patterns -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles -lgcc -funroll-all-loops -ffunction-sections -fdata-sections -Wl,-gc-sections -falign-jumps=4 -falign-functions=16 -march=rv32im -mabi=ilp32"
ci-c48-rv32im-bp3        make coremark ICACHE=8192 DCACHE=4096 MEM_LAT=8:24 MEM_BEAT_LAT=0 MEM_WR_LAT=4:8 BPRED=3 OPT=-O3 "CM_FLAGS=-O3 -g -fno-tree-loop-distribute-patterns -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles -lgcc -funroll-all-loops -ffunction-sections -fdata-sections -Wl,-gc-sections -falign-jumps=4 -falign-functions=16 -march=rv32im -mabi=ilp32"
ci-c48-zb                make coremark ICACHE=8192 DCACHE=4096 MEM_LAT=8:24 MEM_BEAT_LAT=0 MEM_WR_LAT=4:8 MARCH=rv32im_zba_zbb_zbs OPT=-O3 "CM_FLAGS=-O3 -g -fno-tree-loop-distribute-patterns -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles -lgcc -funroll-all-loops -ffunction-sections -fdata-sections -Wl,-gc-sections -falign-jumps=4 -falign-functions=16 -march=rv32im_zba_zbb_zbs -mabi=ilp32"
ci-c48-zb-bp3            make coremark ICACHE=8192 DCACHE=4096 MEM_LAT=8:24 MEM_BEAT_LAT=0 MEM_WR_LAT=4:8 MARCH=rv32im_zba_zbb_zbs BPRED=3 OPT=-O3 "CM_FLAGS=-O3 -g -fno-tree-loop-distribute-patterns -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles -lgcc -funroll-all-loops -ffunction-sections -fdata-sections -Wl,-gc-sections -falign-jumps=4 -falign-functions=16 -march=rv32im_zba_zbb_zbs -mabi=ilp32"
trace-rv32im             make coremark BUSTRACE=1
trace-zb                 make coremark BUSTRACE=1 MARCH=rv32im_zba_zbb_zbs
```

The cache model, on the bus traces of the two `BUSTRACE=1` runs and the console logs of the cached runs:

```
python3 test/memsys/cachemodel.py prep build/cfg-trace/test/coremark/dut-rv32im-O2-performance-i10/bustrace.bin build/coremark-trace/rv32im --ram-kb 32
python3 test/memsys/cachemodel.py run build/coremark-trace/rv32im --isize 8192 --dsize 4096 --line 16 --mem burst --rd-lat 8:24 --wr-lat 1:4 --wbuf none
python3 test/memsys/cachemodel.py rtlcheck build/coremark-trace/rv32im build/cfg-mem8_24-wr1_4-beat0-i8k-d4k-l16/test/coremark/dut-rv32im-O2-performance-i10/run.log
python3 test/memsys/cachemodel.py run build/coremark-trace/rv32im --isize 8192 --dsize 4096 --line 16 --mem burst --rd-lat 8:24 --wr-lat 4:8 --wbuf none
python3 test/memsys/cachemodel.py rtlcheck build/coremark-trace/rv32im build/cfg-mem8_24-wr4_8-beat0-i8k-d4k-l16/test/coremark/dut-rv32im-O2-performance-i10/run.log
python3 test/memsys/cachemodel.py run build/coremark-trace/rv32im --isize 8192 --dsize 4096 --line 16 --mem burst --rd-lat 8:24 --wr-lat 8:24 --wbuf none
python3 test/memsys/cachemodel.py rtlcheck build/coremark-trace/rv32im build/cfg-mem8_24-beat0-i8k-d4k-l16/test/coremark/dut-rv32im-O2-performance-i10/run.log
python3 test/memsys/cachemodel.py prep build/cfg-trace/test/coremark/dut-rv32im_zba_zbb_zbs-O2-performance-i10/bustrace.bin build/coremark-trace/zb --ram-kb 32
python3 test/memsys/cachemodel.py run build/coremark-trace/zb --isize 8192 --dsize 4096 --line 16 --mem burst --rd-lat 8:24 --wr-lat 1:4 --wbuf none
python3 test/memsys/cachemodel.py rtlcheck build/coremark-trace/zb build/cfg-mem8_24-wr1_4-beat0-i8k-d4k-l16/test/coremark/dut-rv32im_zba_zbb_zbs-O2-performance-i10/run.log
python3 test/memsys/cachemodel.py run build/coremark-trace/zb --isize 8192 --dsize 4096 --line 16 --mem burst --rd-lat 8:24 --wr-lat 4:8 --wbuf none
python3 test/memsys/cachemodel.py rtlcheck build/coremark-trace/zb build/cfg-mem8_24-wr4_8-beat0-i8k-d4k-l16/test/coremark/dut-rv32im_zba_zbb_zbs-O2-performance-i10/run.log
python3 test/memsys/cachemodel.py run build/coremark-trace/zb --isize 8192 --dsize 4096 --line 16 --mem burst --rd-lat 8:24 --wr-lat 8:24 --wbuf none
python3 test/memsys/cachemodel.py rtlcheck build/coremark-trace/zb build/cfg-mem8_24-beat0-i8k-d4k-l16/test/coremark/dut-rv32im_zba_zbb_zbs-O2-performance-i10/run.log
```

With `HADES_BUILD_DIR` set, `build/` stands for that directory.

## Inputs

- Base commit `cc48658cb9c0c4640d8236341c3c429715a753b2`; its trees (`git rev-parse cc48658:<dir>`): rtl `7b099d1ec97726cd36514947fb7288dfefde88b9`, lib `b167910d69bd83c6482eda1c956d1433efce2636`, defines `d8fe3bade3185674f484b29d6505599545cf18d0`, sim `e1de1adc2afa75addf2a8630666d5f0d06a178c7`, std `aed86f8aaf0a453ae361b10b343403107b0fd97d`, ref `b1cd1eebbcd4c675f36085ebfc96416192423721`, test/coremark `5c1b318de419702d57f9a795284c2fb2890b5b7c`, test/memsys `884e1a271d2d8f382522f1312e1db1d77d8cc931`, third_party/coremark `06f9560f3380ebb54ed047fceeb271ff9c94d84d`.
- The files that the runs read beyond the simulated hardware, with their sha256, in [`inputs.sha256`](inputs.sha256).
- Products: [`results.csv`](results.csv) has one row per run (cycles, instructions, CPI, cycles per iteration, CoreMark/MHz, `crcfinal`, the sha256 of `out.elf` and `init.mem`); [`meta.json`](meta.json) keeps the command, the summary as printed and the image hashes of every run, and the output of every cache-model command; [`logs/`](logs) has the console log of every run (`<run>.run.log`) and the cache-model outputs (`model-*.txt`).

## Environment

- Date: 2026-10-26
- Host: Intel Core Ultra 7 165H, 22 threads, Linux
- Tools: Verilator 5.042 2025-11-02 rev v5.042; riscv32-unknown-elf-gcc () 12.2.0 with GNU Binutils 2.39; Python 3.12.3; GNU Make 4.3
- Workers: 1 (one run at a time). Wall time: 591 s for all runs and model commands, from an empty build directory with the compiler cache warm.

## Output

`make coremark`, the summary as printed:

```
CoreMark on HaDes-V+ (dut), dut-rv32im-O2-performance-i10
  Compiler flags   : -O2 -march=rv32im -mabi=ilp32
  image: text 9120, rodata 1760, data 12, bss 2084 bytes (RAM 32768, the top 4096 are the stack)

  timed window (CoreMark's start_time to stop_time, 10 iterations):
    cycles                 4217860
    instructions           3081452
    CPI                    1.369
    cycles per iteration   421786
    CoreMark/MHz estimate  2.371   (= iterations * 1000000 / cycles)
    at 50 MHz              118.5 iterations/s   (an estimate of the CoreMark score; not valid for reporting)

  CoreMark's own validation (CRCs after the first iteration, seedcrc 0xe9f5):
    crclist    0xe714  expected 0xe714  ok
    crcmatrix  0x1fd7  expected 0x1fd7  ok
    crcstate   0x8e3a  expected 0x8e3a  ok
    crcfinal   0xfcaf  (depends on the iterations)

RESULT dut-rv32im-O2-performance-i10 cycles=4217860 instructions=3081452 cpi=1.369 cycles_per_iteration=421786 coremark_per_mhz=2.371

COREMARK dut-rv32im-O2-performance-i10: PASS
```

## Caveats

- Cycles are those of the Verilator model of the RTL at the base commit. CoreMark/MHz is iterations x 10^6 / cycles of CoreMark's timed window: an estimate, not a CoreMark score (CoreMark's rules require a run of at least 10 seconds).
- The slow-memory and cached simulators draw their waits from the generator of sim/slow_memory.sv with seed 1 (MEM_SEED); other seeds give slightly different cycles.
- The cache model draws its latencies from a generator of its own: its cycles agree with the RTL's as one sample, not as an identity; its counts of refills, load misses and stores are equal (RTLCHECK: AGREE).
- The runs with CVA6's CI flags pass them through OPT=-O3 and CM_FLAGS; the start code of std/ stays rv32i as for every CoreMark build.
- The runs were made with BUILD_JOBS=4, which limits the parallel jobs of the Verilator builds and changes no output.
