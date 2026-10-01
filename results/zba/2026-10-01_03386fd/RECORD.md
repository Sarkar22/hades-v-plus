# Zba benchmark: 2026-10-01, 03386fd

**Status: repeatable.** `make bench-zba` reproduces every number below exactly.

## The figures and where they are quoted

[docs/EXTENSIONS.md](../../../docs/EXTENSIONS.md) line 123:

> Measured during development (commit 1f501f5) with a benchmark that is not included in the repository, on an address-generation-heavy workload: **20.3 % fewer cycles** (1.26×) and 6–8 % smaller code, verified across 16,704 in-program operand comparisons with zero discrepancies.

| Quoted | Measured here, at `-O2` |
|---|---|
| 20.3 % fewer cycles | `zba_bench`: 45,350 → 36,133 cycles, −20.3 % |
| 1.26× | 45,350 / 36,133 = 1.2551 |
| 6–8 % smaller code | program image (`out.bin`): `zba_bench` 940 → 868 bytes (−7.7 %), `zba_arr` 1,680 → 1,576 bytes (−6.2 %) |
| 16,704 in-program operand comparisons with zero discrepancies | `zba_diff` in 4 runs: 3,618 + 4,362 + 4,362 + 4,362 = 16,704 checks, 0 mismatches, `ZBA DIFF OK` in all four |

The same programs at other optimisation levels, not quoted in the documentation of 03386fd; docs/EXTENSIONS.md (Zba, Verification) and test/bench/README.md quote them since this record was added (correction of 2026-10-01: this sentence first said "not quoted in the documentation"): at `-Os`, `zba_bench` 43,814 → 37,670 cycles (−14.0 %) and 924 → 892 bytes; at `-O0`, GCC emits no Zba instruction and both builds are identical (1,904 bytes, 147,659 cycles). The equality checks pass at all three levels.

## Commands

From the repository root, on 03386fd with `test/bench/` and the bench targets of the `Makefile` added (the files and their sha256 are listed in [`inputs.sha256`](inputs.sha256)):

```
make bench-zba
make bench-zba OPT=-Os
make bench-zba OPT=-O0
```

The first builds the simulator, `build/sim/top`, if it does not exist yet. With `HADES_BUILD_DIR` set, all output goes to that directory instead of `build/`.

## Inputs

- Base commit `03386fdda932f4827cded26e8cfc2a2cc531b365`; its trees (`git rev-parse 03386fd:<dir>`): rtl `031b989be1f25dd20836028c5126a5b1dc562bd7`, lib `f90a9a64ddc67db6642bc6654545f1509744426b`, defines `36f0452de823189873ca8ac79d7a662918961ad6`, sim `0dad5608c126445abb808c5addd7b6e9d4df54c7`, std `05909d5f7dd5d23f80a2d11e127fdb79eb8a5468`.
- Added on top of it: the `Makefile` with the bench targets, `test/bench/bench.mk`, `test/bench/bench.py` and the programs, with their sha256 in [`inputs.sha256`](inputs.sha256). After their license headers, the three programs are byte-identical to the ones first measured: sha256 `9e9b491f12994d844d0098358b175b9db1c5b4a833aebfe0386791baf67bd1a9` (zba_bench.c), `228121fe3d58b2bb251016f5513adc05839291c23f420fe60212b1fb07c0fe64` (zba_arr.c), `2a41bad7d24dd6dfc5a7455b1a96b81695f85c518d4de745bc82af063cfa0e80` (zba_diff.c). Those fingerprints are of the files the run used. Some of them changed afterwards, before they were committed (the `Makefile` gained the `check-results` target and help text, `bench.mk` a header comment): [`rechecked.sha256`](rechecked.sha256) lists the changed files as committed, with which `make check-results` reproduced this record exactly; `sha256sum -c inputs.sha256` reports those files as `FAILED`. Correction (2026-10-01): the `Makefile` line of `inputs.sha256` had been changed to the extended file (sha256 `2cd15d50…834a`); it again names the file the run used.
- Products: [`results.csv`](results.csv) lists, for each of the 24 builds (8 variants at 3 levels), the image size, the Zba instruction counts, the timed cycles, the program's output and the sha256 of `init.mem` and `out.elf`; both are reproducible bit for bit.

## Environment

- Date: 2026-10-01
- Host: Intel Core Ultra 7 165H, 22 threads, Linux
- Tools: Verilator 5.042 2025-11-02 rev v5.042; riscv32-unknown-elf-gcc () 12.2.0 with GNU Binutils 2.39; Python 3.12.3; GNU Make 4.3
- Workers: 1 (`make` without `-j`). Wall time: `make bench`, all three benchmarks from a clean tree including the simulator build, 2.5 s with the simulator's C++ taken from the compiler cache, 12.7 s and 23.6 s in two runs without the cache (other jobs were running on the host during the second); `make bench-zba OPT=-Os` 4.2 s and `OPT=-O0` 1.5 s with the simulator already built.

## Output

`make bench-zba`, the summary printed after the build commands (verbatim):

```
Zba benchmark (test/bench/zba), -O2: each program built for -march=rv32i and for -march=rv32i_zba

  variant               image bytes  Zba instrs  timed cycles  result
  zba_bench-rv32i               940           0         45350  CHK ca5f039c
  zba_bench-rv32i_zba           868          16         36133  CHK ca5f039c
  zba_arr-rv32i                1680           0         23386  SUM 78565846
  zba_arr-rv32i_zba            1576          27         22234  SUM 78565846
  zba_diff                     2588          15         51127  CASES 3618 BAD 0 EXTRA 0, ZBA DIFF OK
  zba_diff-B5297A4D            2392          12         75441  CASES 4362 BAD 0 EXTRA 0, ZBA DIFF OK
  zba_diff-1F123BB5            2392          12         75439  CASES 4362 BAD 0 EXTRA 0, ZBA DIFF OK
  zba_diff-9E3779B9            2392          12         75439  CASES 4362 BAD 0 EXTRA 0, ZBA DIFF OK

  zba_bench: 45350 -> 36133 cycles (-20.3 %, 1.2551x), 940 -> 868 bytes (-7.7 %), CHK equal: yes
             Zba instructions in the rv32i_zba build: 5 sh1add, 6 sh2add, 5 sh3add
  zba_arr:   1680 -> 1576 bytes (-6.2 %), P1-P8 and SUM equal: yes; CYCLES 23386 -> 22234 (the window includes waiting for the UART)
  zba_diff:  16704 checks in 4 runs (3618 + 4362 + 4362 + 4362), 0 mismatches, ZBA DIFF OK in 4 of 4

BENCH ZBA: PASS
```

`make bench-zba OPT=-Os`:

```
Zba benchmark (test/bench/zba), -Os: each program built for -march=rv32i and for -march=rv32i_zba

  variant               image bytes  Zba instrs  timed cycles  result
  zba_bench-rv32i               924           0         43814  CHK ca5f039c
  zba_bench-rv32i_zba           892          10         37670  CHK ca5f039c
  zba_arr-rv32i                1652           0         24609  SUM 78565846
  zba_arr-rv32i_zba            1572          21         23329  SUM 78565846
  zba_diff                     1956          15         40721  CASES 3618 BAD 0 EXTRA 0, ZBA DIFF OK
  zba_diff-B5297A4D            1768          12         62803  CASES 4362 BAD 0 EXTRA 0, ZBA DIFF OK
  zba_diff-1F123BB5            1768          12         62801  CASES 4362 BAD 0 EXTRA 0, ZBA DIFF OK
  zba_diff-9E3779B9            1768          12         62801  CASES 4362 BAD 0 EXTRA 0, ZBA DIFF OK

  zba_bench: 43814 -> 37670 cycles (-14.0 %, 1.1631x), 924 -> 892 bytes (-3.5 %), CHK equal: yes
             Zba instructions in the rv32i_zba build: 5 sh1add, 3 sh2add, 2 sh3add
  zba_arr:   1652 -> 1572 bytes (-4.8 %), P1-P8 and SUM equal: yes; CYCLES 24609 -> 23329 (the window includes waiting for the UART)
  zba_diff:  16704 checks in 4 runs (3618 + 4362 + 4362 + 4362), 0 mismatches, ZBA DIFF OK in 4 of 4

BENCH ZBA: PASS
```

`make bench-zba OPT=-O0`:

```
Zba benchmark (test/bench/zba), -O0: each program built for -march=rv32i and for -march=rv32i_zba

  variant               image bytes  Zba instrs  timed cycles  result
  zba_bench-rv32i              1904           0        147659  CHK ca5f039c
  zba_bench-rv32i_zba          1904           0        147659  CHK ca5f039c
  zba_arr-rv32i                3052           0         44089  SUM 78565846
  zba_arr-rv32i_zba            3052           0         44089  SUM 78565846
  zba_diff                     3384          15        144075  CASES 3618 BAD 0 EXTRA 0, ZBA DIFF OK
  zba_diff-B5297A4D            2908          12        220660  CASES 4362 BAD 0 EXTRA 0, ZBA DIFF OK
  zba_diff-1F123BB5            2908          12        220660  CASES 4362 BAD 0 EXTRA 0, ZBA DIFF OK
  zba_diff-9E3779B9            2908          12        220660  CASES 4362 BAD 0 EXTRA 0, ZBA DIFF OK

  zba_bench: 147659 -> 147659 cycles (+0.0 %, 1.0000x), 1904 -> 1904 bytes (+0.0 %), CHK equal: yes
             Zba instructions in the rv32i_zba build: 0 sh1add, 0 sh2add, 0 sh3add
  zba_arr:   3052 -> 3052 bytes (+0.0 %), P1-P8 and SUM equal: yes; CYCLES 44089 -> 44089 (the window includes waiting for the UART)
  zba_diff:  16704 checks in 4 runs (3618 + 4362 + 4362 + 4362), 0 mismatches, ZBA DIFF OK in 4 of 4

BENCH ZBA: PASS
```

The run log of every program is in [`logs/`](logs) (`<level>.<variant>.run.log`, colour codes removed).

## Caveats

- The cycles are those of the Verilator model of the RTL at the base commit. `zba_bench` consists of scaled-index accesses, so 20.3 % is the gain on a favourable program, not on a typical one.
- The sizes are those of the program image loaded into RAM (`out.bin`: code, read-only data and initialised data), not of `.text` alone.
- The `CYCLES` line of `zba_arr` (23,386 → 22,234) includes waiting for the UART inside its timed window; it is not a speed figure.
- The rv32i builds contain no Zba instruction (the benchmark checks this). `zba_diff` is built for rv32i only and issues its Zba instructions as `.insn` words, so it compares them with RV32I code in the same program.
- The program images are byte-identical to those that the build script of 2026-08-18, recovered from the development log, produces with the same tools; on a simulator built from 1f501f5 they print the same lines as here: see [the first measurement](../2026-08-18_1f501f5/RECORD.md).
