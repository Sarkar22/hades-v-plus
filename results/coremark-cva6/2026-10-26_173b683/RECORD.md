# CoreMark on CVA6, Against HaDes-V+: 2026-10-26, 173b683

**Status: historical.** The runs were made outside the repository, with upstream [CVA6](https://github.com/openhwgroup/cva6) at `742dc82` and the tools listed below; `make check-results` does not repeat them. The commands below repeat them with those tools; each run's CoreMark output is in [`logs/`](logs). The HaDes-V+ side of the comparison is the repeatable [CoreMark record](../../coremark/2026-10-26_cc48658/RECORD.md).

## The figures and where they are quoted

[docs/PERFORMANCE.md](../../../docs/PERFORMANCE.md) quotes them; [`meta.json`](meta.json) lists each with the lines that quote it.

| Figure as quoted | Quoted in | Measured here |
|---|---|---|
| The 12 CVA6 rows of the table (cycles and CoreMark/MHz with -O2 and with CVA6's CI flags) and the CVA6 bars of docs/img/coremark-cva6.svg | docs/PERFORMANCE.md:31, docs/PERFORMANCE.md:32, docs/PERFORMANCE.md:33, docs/PERFORMANCE.md:34, docs/PERFORMANCE.md:35, docs/PERFORMANCE.md:36, docs/PERFORMANCE.md:21 | results.csv, rows cv32a65x-* and cv64a6-* (CoreMark's Total ticks) |
| Instructions of the timed window: 3,081,459 and 2,719,467 on cv32a65x (rv32im), 3,540,217 on cv64a6 (rv64im) | docs/PERFORMANCE.md:46, docs/PERFORMANCE.md:50 | results.csv: cv32a65x-rv32im-O2 3,081,459, cv32a65x-rv32im-ci 2,719,467, cv64a6-rv64im-O2 3,540,217 (the RVFI trace between the two reads of mcycle) |
| Instructions per cycle: 1.013 and 1.058 (cv32a65x), 0.745 to 0.772 (cv64a6) | docs/PERFORMANCE.md:50 | results.csv, column ipc |
| 16 KiB caches: 1.5 % faster (2,994,922 cycles) and 4.5 % (2,403,579) | docs/PERFORMANCE.md:65 | cv32a65x-rv32im-O2 3,040,438 / cv32a65x-16k-rv32im-O2 2,994,922; cv32a65x-best-ci 2,511,386 / cv32a65x-16k-best-ci 2,403,579 |
| C and the B extensions: 7.7 % at -O2; 56.1 % of the executed instructions 16 bits long; CoreMark's code 6,220 and 4,056 bytes; instructions per cycle 1.013 and 1.058 | docs/PERFORMANCE.md:67 | cv32a65x-rv32im-O2 3,040,438 / cv32a65x-best-O2 2,822,829 cycles; logs/cv32a65x-best-O2.mix.txt: window instructions 2986231, compressed 56.1 %, taken control transfers 422924 (14.2 %); results.csv, column coremark_code_bytes |
| The CI flags: 40.2 % fewer taken branches and jumps (419,504 to 250,863), code about 2.7 times as large; cv32a65x gains 12.4 to 13.5 %, cv64a6 0.7 to 2.5 % | docs/PERFORMANCE.md:69 | logs/cv32a65x-rv32im-O2.mix.txt: window instructions 3081459, compressed 0.0 %, taken control transfers 419504 (13.6 %); logs/cv32a65x-rv32im-ci.mix.txt: window instructions 2719467, compressed 0.0 %, taken control transfers 250863 (9.2 %); code 6220 and 16656 bytes; the cycles of results.csv |
| What a miss costs in the testbench (the two rows of the memlat table) and 'about 4 to 6 cycles more than a hit' | docs/PERFORMANCE.md:87, docs/PERFORMANCE.md:88, docs/PERFORMANCE.md:90 | logs/memlat-cv32a65x.txt and logs/memlat-cv64a6.txt (per_load_x100, per_line_x100) |
| Both compilers give the same instructions (27 objects, both flag sets) | docs/PERFORMANCE.md:95 | logs/gcc-compare.txt: 27 of 27 identical |
| CVA6's own CoreMark copies: 2,510,685 cycles against 2,511,386, a change of 0.03 % | docs/PERFORMANCE.md:96, docs/PERFORMANCE.md:105 | cv32a65x-best-ci-shipped 2,510,685, cv32a65x-best-ci 2,511,386 |
| Every run executes 10 iterations, 2.4 to 5.2 million cycles | docs/PERFORMANCE.md:8 | the shortest window cv32a65x-16k-best-ci 2,403,579 (this record), the longest c48-rv32im 5,153,890 (the HaDes-V+ record) |
| cv32a65x against HaDes-V+ with the 2-bit predictor: 22.9 % (rv32im, -O2), 24.5 % (CI flags), 29.0 % and 29.7 % (best instruction sets); HaDes-V+ against cv64a6: 15.5 % and 27.0 %; cv64a6 needs 14.9 % more instructions | docs/PERFORMANCE.md:48 | the cycles and instructions of this record and of the HaDes-V+ record (results/coremark/2026-10-26_cc48658) |
| CVA6 at 742dc82 of its master branch (2026-10-23), 259 commits after its release v5.3.0 of 2025-02-03, read-only since 2026-10-23 | docs/PERFORMANCE.md:6, docs/PERFORMANCE.md:94 | the clone: git log -1 742dc82 gives 742dc82a0c706e0a3bfb98b709fd3ee06d50d12a, 2026-10-23, 'Note: master made read-only. (#3664)'; git describe --tags 742dc82 gives v5.3.0-259-g742dc82a0; v5.3.0 is 2ef1c1b1f of 2025-02-03 |

The runs (CoreMark/MHz = 10 x 10^6 / cycles; instructions from the RVFI trace; every run printed `seedcrc` 0xe9f5, `crclist` 0xe714, `crcmatrix` 0x1fd7, `crcstate` 0x8e3a and `crcfinal` 0xfcaf; [`results.csv`](results.csv) has every column):

| Run | Configuration | `-march` | Flags | CoreMark sources | Cycles | CoreMark/MHz | Instructions | IPC | CRCs |
|---|---|---|---|---|---:|---:|---:|---:|---|
| `cv32a65x-16k-best-ci` | cv32a65x (16 KiB caches) | `rv32imc_zba_zbb_zbs_zbc` | CVA6 CI flags | CoreMark 1f483d5 | 2,403,579 | 4.160 | 2,641,907 | 1.099 | PASS |
| `cv32a65x-16k-rv32im-O2` | cv32a65x (16 KiB caches) | `rv32im` | -O2 | CoreMark 1f483d5 | 2,994,922 | 3.339 | 3,081,458 | 1.029 | PASS |
| `cv32a65x-best-O2` | cv32a65x | `rv32imc_zba_zbb_zbs_zbc` | -O2 | CoreMark 1f483d5 | 2,822,829 | 3.543 | 2,986,231 | 1.058 | PASS |
| `cv32a65x-best-ci` | cv32a65x | `rv32imc_zba_zbb_zbs_zbc` | CVA6 CI flags | CoreMark 1f483d5 | 2,511,386 | 3.982 | 2,641,907 | 1.052 | PASS |
| `cv32a65x-best-ci-shipped` | cv32a65x | `rv32imc_zba_zbb_zbs_zbc` | CVA6 CI flags | CVA6's copies | 2,510,685 | 3.983 | 2,641,907 | 1.052 | PASS |
| `cv32a65x-rv32im-O2` | cv32a65x | `rv32im` | -O2 | CoreMark 1f483d5 | 3,040,438 | 3.289 | 3,081,459 | 1.013 | PASS |
| `cv32a65x-rv32im-ci` | cv32a65x | `rv32im` | CVA6 CI flags | CoreMark 1f483d5 | 2,679,747 | 3.732 | 2,719,467 | 1.015 | PASS |
| `cv64a6-best-O2` | cv64a6_imafdc_sv39 | `rv64gc_zba_zbb_zbs_zbc_zbkb_zbkx_zkne_zknd_zknh` | -O2 | CoreMark 1f483d5 | 4,207,910 | 2.376 | 3,134,889 | 0.745 | PASS |
| `cv64a6-best-ci` | cv64a6_imafdc_sv39 | `rv64gc_zba_zbb_zbs_zbc_zbkb_zbkx_zkne_zknd_zknh` | CVA6 CI flags | CoreMark 1f483d5 | 4,138,860 | 2.416 | 3,076,365 | 0.743 | PASS |
| `cv64a6-rv64gc-O2` | cv64a6_imafdc_sv39 | `rv64gc` | -O2 | CoreMark 1f483d5 | 4,582,955 | 2.182 | 3,540,217 | 0.772 | PASS |
| `cv64a6-rv64gc-ci` | cv64a6_imafdc_sv39 | `rv64gc` | CVA6 CI flags | CoreMark 1f483d5 | 4,552,916 | 2.196 | 3,509,065 | 0.771 | PASS |
| `cv64a6-rv64im-O2` | cv64a6_imafdc_sv39 | `rv64im_zicsr_zifencei` | -O2 | CoreMark 1f483d5 | 4,701,238 | 2.127 | 3,540,217 | 0.753 | PASS |
| `cv64a6-rv64im-ci` | cv64a6_imafdc_sv39 | `rv64im_zicsr_zifencei` | CVA6 CI flags | CoreMark 1f483d5 | 4,587,616 | 2.180 | 3,509,065 | 0.765 | PASS |
| `cv64a6-rv64imac-O2` | cv64a6_imafdc_sv39 | `rv64imac_zicsr_zifencei` | -O2 | CoreMark 1f483d5 | 4,582,955 | 2.182 | 3,540,217 | 0.772 | PASS |
| `cv64a6-rv64imac-ci` | cv64a6_imafdc_sv39 | `rv64imac_zicsr_zifencei` | CVA6 CI flags | CoreMark 1f483d5 | 4,552,923 | 2.196 | 3,509,065 | 0.771 | PASS |

## What Was Run

- **CVA6** `742dc82a0c706e0a3bfb98b709fd3ee06d50d12a` (`master`, 259 commits after the release `v5.3.0`: `git describe --tags` gives `v5.3.0-259-g742dc82a0`; read-only since 2026-10-23), with its submodules (among them `core/cache_subsystem/hpdcache` `e8f072e1`, `core/cvfpu` `3eb6afea`, `verif/core-v-verif` `b3149ab0`), in its Verilator testbench through `verif/sim/cva6.py --iss=veri-testharness`, targets `cv32a65x` and `cv64a6_imafdc_sv39`; the 16 KiB runs through `--target hwconfig --hwconfig_opts="cv32a65x IcacheByteSize=16384 DcacheByteSize=16384"`.
- **CoreMark**: the six core files of [`third_party/coremark/`](../../../third_party/coremark/README.md) at 173b683 (eembc/coremark `1f483d5`, checked with its `MANIFEST`), with CVA6's port files `core_portme.c`, `core_portme.h`, `uart.c`, `uart.h` and its `syscalls.c` and `crt.S`, unchanged (their git blob ids are in `meta.json`). The run `cv32a65x-best-ci-shipped` used CVA6's own copies of the core files instead (`verif/tests/custom/coremark/`, with `coremark_main.c`).
- **Tools**: Verilator 5.008 with CVA6's `verif/regress/verilator-v5.patch`, as `verif/regress/install-verilator.sh` pins it; Spike 1.1.1-dev from `verif/core-v-verif/vendor/riscv/riscv-isa-sim`, built as `verif/regress/install-spike.sh` does but with `configure --with-boost-regex=no` (its Boost.Regex check failed on Ubuntu 24.04); `riscv32-unknown-elf-gcc` 12.2.0 (binutils 2.39) for cv32a65x; the xPack GNU RISC-V Embedded GCC 12.2.0-3 for cv64a6, its archive checked against the published SHA-256 `0bb5f0c6a36f5197888fcd176e3734ec5b74167b5a631883f72ae3cbd47a97c3`.
- **The miss costs**: [`memlat.c`](memlat.c), built and run like CoreMark (`uart.c`, `syscalls.c`, `crt.S` of CVA6), `-O2`, at both targets.
- **The compilers**: CoreMark's files and the HaDes-V+ port compiled by both GCCs at `rv32im`, `rv32im_zba_zbb_zbs` and (CI flags) `rv32imc_zba_zbb_zbs_zbc`, compared with `objdump -d`: [`logs/gcc-compare.txt`](logs/gcc-compare.txt).

## Commands

From `verif/sim` of the CVA6 clone, after `source setup-env.sh`, with `RISCV_CC` the compiler (for cv64a6, a wrapper that prints `riscv-none-elf-gcc (xPack-GNU-RISC-V-Embedded-GCC-12.2.0-3) 12.2.0` for `--version`, because `cva6.py` takes the version from the third word of that line, and passes every other call to `riscv-none-elf-gcc`), `VERILATOR_INSTALL_DIR` and `SPIKE_INSTALL_DIR` the tools above and `NUM_JOBS=2`. `$COREMARK` is a directory with the six core files and CVA6's port files, `$OUT` the run's output directory. The run `cv32a65x-rv32im-O2`, as run:

```
$RISCV_CC -c ../tests/custom/common/syscalls.c -O2 -ffunction-sections -fdata-sections -static -nostdlib -nostartfiles -lgcc -Wl,-gc-sections -fno-tree-loop-distribute-patterns -DNOPRINT -I../tests/custom/env -I../tests/custom/common -march=rv32im -mabi=ilp32 -o $OUT/syscalls.o
python3 cva6.py --target cv32a65x --iss=veri-testharness --iss_yaml=cva6.yaml --c_tests $COREMARK/core_main.c --sv_seed 1 --gcc_opts $COREMARK/uart.c\ $COREMARK/core_list_join.c\ $COREMARK/core_matrix.c\ $COREMARK/core_portme.c\ $COREMARK/core_state.c\ $COREMARK/core_util.c\ $OUT/syscalls.o\ ../tests/custom/common/crt.S\ -O2\ -ffunction-sections\ -fdata-sections\ -static\ -nostdlib\ -nostartfiles\ -lgcc\ -Wl\,-gc-sections\ -DCOMPILER_FLAGS=\'\"-O2\ -ffunction-sections\ -fdata-sections\ -static\ -nostdlib\ -nostartfiles\ -lgcc\ -Wl\,-gc-sections\"\'\ -DITERATIONS=10\ -DPERFORMANCE_RUN\ -DSKIP_TIME_CHECK\ -I../tests/custom/env\ -I../tests/custom/common\ -DNOPRINT\ -march=rv32im\ -mabi=ilp32 --iss_timeout=40000 --issrun_opts=+debug_disable=1\ +time_out=400000000 -o $OUT/cva6py --verbose
```

`meta.json` (`commands`) has the command of every run in the same form. The runs at `-O2` compile `syscalls.c` first, as above; the runs with the CI flags compile it with the rest. `+time_out=400000000` keeps the testbench's tracer from ending the simulation after 2,000,000 cycles.

## Environment

- Date: 2026-10-26
- Host: Intel Core Ultra 7 165H, 22 threads, Linux (Ubuntu 24.04)
- Python 3.12.3; host compiler g++ 13.3.0

## Output

Each run's output from CoreMark, as the testbench's console printed it (the path of the program removed): `logs/<run>.txt`; the instruction mixes of seven runs, counted in their RVFI traces: `logs/<run>.mix.txt`; the miss-cost program: `logs/memlat-*.txt`. The run `cv32a65x-rv32im-O2`:

```
<program>: core_main.o *** SUCCESS *** (tohost = 0) after 3100106 cycles
2K performance run parameters for coremark.
CoreMark Size    : 666
Total ticks      : 3040438
Total time (secs): 3
Iterations/Sec   : 3
ERROR! Must execute for at least 10 secs for a valid result!
Iterations       : 10
Compiler version : GCC12.2.0
Compiler flags   : -O2 -ffunction-sections -fdata-sections -static -nostdlib -nostartfiles -lgcc -Wl,-gc-sections
Memory location  :
seedcrc          : 0xe9f5
[0]crclist       : 0xe714
[0]crcmatrix     : 0x1fd7
[0]crcstate      : 0x8e3a
[0]crcfinal      : 0xfcaf
Errors detected
*** [rvfi_tracer] INFO: Simulation terminated after    3100094 cycles!
```

## Caveats

- CoreMark/MHz is iterations x 10^6 / cycles of CoreMark's timed window: an estimate, not a CoreMark score.
- The instructions of the window are counted in the testbench's RVFI trace between the two reads of mcycle in setStats(), because CVA6's CI build (NOPRINT) does not print its counters.
- The testbench memory is nearly ideal (logs/memlat-*.txt); a DRAM or a slower interconnect would cost more.
- GCC 12.2 emits neither Zcb nor Zicond; the best instruction sets of the runs leave them out.
- Runs at -O2 compile CVA6's syscalls.c with -fno-tree-loop-distribute-patterns: without it GCC turns its memset loop into a call of memset itself.
