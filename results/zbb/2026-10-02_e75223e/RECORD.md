# Zbb benchmark: 2026-10-02, e75223e

**Status: repeatable.** `make bench-zbb` reproduces every number below exactly (`make check-results CHECK_ARGS=zbb`).

## The figures and where they are quoted

| Quoted | Measured here |
|---|---|
| 59.8 % fewer cycles (2.49×) at `-O2`, in a best-case loop ([README.md](../../../README.md#an-extended-cpu), [docs/EXTENSIONS.md](../../../docs/EXTENSIONS.md#verification-5), [test/bench/README.md](../../../test/bench/README.md#make-bench-zbb)) | `zbb_bench`: 302,330 → 121,388 cycles with `-march=rv32i_zbb_zbs` (−59.8 %, 2.4906×); 119,852 with `rv32im_zba_zbb_zbs` |
| the image shrinks from 1,636 to 904 bytes ([docs/EXTENSIONS.md](../../../docs/EXTENSIONS.md#verification-5)) | `out.bin` of `zbb_bench` at `-O2`, −44.7 % |
| 62.0 % at `-Os`, 27.4 % at `-O0` (same places) | `-Os`: 319,058 → 121,196; `-O0`: 824,570 → 598,594 |
| 52,436 results of the 28 forms compared without a mismatch ([docs/EXTENSIONS.md](../../../docs/EXTENSIONS.md#verification-5), [docs/VERIFICATION.md](../../../docs/VERIFICATION.md#system-level), [test/bench/README.md](../../../test/bench/README.md#make-bench-zbb)) | `zbb_diff` in 4 runs: 15,773 + 12,221 + 12,221 + 12,221 checks, 0 mismatches, `ZBB DIFF OK` in all four, at every level; its code holds all 28 forms |
| at `-O2` GCC 12 emits neither `xnor` nor `zext.h` in `zbb_bench` and `zbb_arr` ([test/bench/README.md](../../../test/bench/README.md#make-bench-zbb)) | the per-form counts below (at `-O0`, `zbb_arr` has one `zext.h`) |

The equality checks pass at all three levels: `CHK` of `zbb_bench` and `P1`–`P8` and `SUM` of `zbb_arr` are equal in the `rv32i`, `rv32i_zbb_zbs` and `rv32im_zba_zbb_zbs` builds.

## Commands

From the repository root:

```
make bench-zbb
make bench-zbb OPT=-Os
make bench-zbb OPT=-O0
```

The first builds the simulator, `build/sim/top`, if it does not exist yet. With `HADES_BUILD_DIR` set, all output goes to that directory instead of `build/`.

## Inputs

- Base commit `e75223e5a6af0e6ff5233f46d1196e85755e25d1`, with the Zbb, Zbs and Zicond changes not yet committed: [`inputs.sha256`](inputs.sha256) lists the sha256 of every file under `Makefile`, `test/bench/`, `std/`, `rtl/` and `defines/` that differs from the base commit, other than documentation, (the RTL and decoder changes, `std/include/zicond.h`, `bench.mk`, `bench.py` and the programs of `test/bench/zbb/`). The other inputs (`sim/`, `lib/`, `ref/`) are those of the base commit.
- Products: [`results.csv`](results.csv) lists, for each of the 30 builds (10 variants at 3 levels), the source, `-march` and extra flags, the image size, the number of Zbb, Zbs and Zicond instructions and of distinct forms with the count of each, the timed cycles, the program's output and the sha256 of `init.mem` and `out.elf`; both are reproducible bit for bit.

## Environment

- Date: 2026-10-02
- Host: Intel Core Ultra 7 165H, 22 threads, Linux
- Tools: Verilator 5.042 2025-11-02 rev v5.042; riscv32-unknown-elf-gcc () 12.2.0 with GNU Binutils 2.39; Python 3.12.3; GNU Make 4.3
- Workers: 1 (`make` without `-j`). Wall time with the simulator built: `make bench-zbb` 4.68 s, `OPT=-Os` 4.88 s, `OPT=-O0` 15.01 s.

## Output

`make bench-zbb`, the summary printed after the build commands (verbatim):

```
Zbb benchmark (test/bench/zbb), -O2: each program built for -march=rv32i, rv32i_zbb_zbs and rv32im_zba_zbb_zbs

  variant                      image bytes new instrs  timed cycles  result
  zbb_bench-rv32i                     1636          0        302330  CHK 653f8521
  zbb_bench-rv32i_zbb_zbs              904         20        121388  CHK 653f8521
  zbb_bench-rv32im_zba_zbb_zbs         900         20        119852  CHK 653f8521
  zbb_arr-rv32i                       2512          0         20333  SUM 0ff9b7e9
  zbb_arr-rv32i_zbb_zbs               1796         41         12117  SUM 0ff9b7e9
  zbb_arr-rv32im_zba_zbb_zbs          1552         41         12107  SUM 0ff9b7e9
  zbb_diff                            7200        210       1905212  CASES 15773 BAD 0 EXTRA 0, ZBB DIFF OK
  zbb_diff-B5297A4D                  16692        241       1205369  CASES 12221 BAD 0 EXTRA 0, ZBB DIFF OK
  zbb_diff-1F123BB5                  16692        241       1205635  CASES 12221 BAD 0 EXTRA 0, ZBB DIFF OK
  zbb_diff-9E3779B9                  16692        241       1205063  CASES 12221 BAD 0 EXTRA 0, ZBB DIFF OK

  zbb_bench: rv32i -> rv32i_zbb_zbs: 302330 -> 121388 cycles (-59.8 %, 2.4906x), 1636 -> 904 bytes (-44.7 %)
  zbb_bench: rv32i -> rv32im_zba_zbb_zbs: 302330 -> 119852 cycles (-60.4 %, 2.5225x), 1636 -> 900 bytes (-45.0 %)
             CHK equal in the three builds: yes
  zbb_arr:   2512 / 1796 / 1552 bytes, P1-P8 and SUM equal in the three builds: yes; CYCLES 20333 / 12117 / 12107 (the window includes waiting for the UART)
  zbb_diff:  52436 checks in 4 runs (15773 + 12221 + 12221 + 12221), 0 mismatches, ZBB DIFF OK in 4 of 4; 28 of 28 forms in its code

  Zbb/Zbs/Zicond instructions in the code (per form; zbb_bench, zbb_arr):
    zbb_bench-rv32i_zbb_zbs       20 words, 19 forms: andn=1 orn=1 clz=1 ctz=1 cpop=2 max=1 min=1 minu=1 sext.b=1 sext.h=1 rol=1 ror=1 rori=1 orc.b=1 rev8=1 bclr=1 bext=1 binv=1 bset=1
    zbb_arr-rv32i_zbb_zbs         41 words, 24 forms: andn=2 orn=1 clz=1 ctz=1 cpop=4 max=2 maxu=1 min=2 minu=1 sext.b=3 sext.h=2 rol=3 ror=1 rori=1 bclr=1 bclri=1 bext=1 bexti=1 binv=1 binvi=1 bset=1 bseti=1 czero.eqz=4 czero.nez=4
    zbb_bench-rv32im_zba_zbb_zbs  20 words, 19 forms: andn=1 orn=1 clz=1 ctz=1 cpop=2 max=1 min=1 minu=1 sext.b=1 sext.h=1 rol=1 ror=1 rori=1 orc.b=1 rev8=1 bclr=1 bext=1 binv=1 bset=1
    zbb_arr-rv32im_zba_zbb_zbs    41 words, 24 forms: andn=2 orn=1 clz=1 ctz=1 cpop=4 max=2 maxu=1 min=2 minu=1 sext.b=3 sext.h=2 rol=3 ror=1 rori=1 bclr=1 bclri=1 bext=1 bexti=1 binv=1 binvi=1 bset=1 bseti=1 czero.eqz=4 czero.nez=4

BENCH ZBB: PASS
```

`make bench-zbb OPT=-Os`:

```
Zbb benchmark (test/bench/zbb), -Os: each program built for -march=rv32i, rv32i_zbb_zbs and rv32im_zba_zbb_zbs

  variant                      image bytes new instrs  timed cycles  result
  zbb_bench-rv32i                     1664          0        319058  CHK 653f8521
  zbb_bench-rv32i_zbb_zbs              880         20        121196  CHK 653f8521
  zbb_bench-rv32im_zba_zbb_zbs         876         20        119660  CHK 653f8521
  zbb_arr-rv32i                       2480          0         20812  SUM 0ff9b7e9
  zbb_arr-rv32i_zbb_zbs               1764         40         12330  SUM 0ff9b7e9
  zbb_arr-rv32im_zba_zbb_zbs          1524         40         12185  SUM 0ff9b7e9
  zbb_diff                            6296        210       1900227  CASES 15773 BAD 0 EXTRA 0, ZBB DIFF OK
  zbb_diff-B5297A4D                   5980        210       1318558  CASES 12221 BAD 0 EXTRA 0, ZBB DIFF OK
  zbb_diff-1F123BB5                   5980        210       1318824  CASES 12221 BAD 0 EXTRA 0, ZBB DIFF OK
  zbb_diff-9E3779B9                   5980        210       1318382  CASES 12221 BAD 0 EXTRA 0, ZBB DIFF OK

  zbb_bench: rv32i -> rv32i_zbb_zbs: 319058 -> 121196 cycles (-62.0 %, 2.6326x), 1664 -> 880 bytes (-47.1 %)
  zbb_bench: rv32i -> rv32im_zba_zbb_zbs: 319058 -> 119660 cycles (-62.5 %, 2.6664x), 1664 -> 876 bytes (-47.4 %)
             CHK equal in the three builds: yes
  zbb_arr:   2480 / 1764 / 1524 bytes, P1-P8 and SUM equal in the three builds: yes; CYCLES 20812 / 12330 / 12185 (the window includes waiting for the UART)
  zbb_diff:  52436 checks in 4 runs (15773 + 12221 + 12221 + 12221), 0 mismatches, ZBB DIFF OK in 4 of 4; 28 of 28 forms in its code

  Zbb/Zbs/Zicond instructions in the code (per form; zbb_bench, zbb_arr):
    zbb_bench-rv32i_zbb_zbs       20 words, 19 forms: andn=1 orn=1 clz=1 ctz=1 cpop=2 max=1 min=1 minu=1 sext.b=1 sext.h=1 rol=1 ror=1 rori=1 orc.b=1 rev8=1 bclr=1 bext=1 binv=1 bset=1
    zbb_arr-rv32i_zbb_zbs         40 words, 24 forms: andn=2 orn=1 clz=1 ctz=1 cpop=3 max=2 maxu=1 min=2 minu=1 sext.b=3 sext.h=2 rol=3 ror=1 rori=1 bclr=1 bclri=1 bext=1 bexti=1 binv=1 binvi=1 bset=1 bseti=1 czero.eqz=4 czero.nez=4
    zbb_bench-rv32im_zba_zbb_zbs  20 words, 19 forms: andn=1 orn=1 clz=1 ctz=1 cpop=2 max=1 min=1 minu=1 sext.b=1 sext.h=1 rol=1 ror=1 rori=1 orc.b=1 rev8=1 bclr=1 bext=1 binv=1 bset=1
    zbb_arr-rv32im_zba_zbb_zbs    40 words, 24 forms: andn=2 orn=1 clz=1 ctz=1 cpop=3 max=2 maxu=1 min=2 minu=1 sext.b=3 sext.h=2 rol=3 ror=1 rori=1 bclr=1 bclri=1 bext=1 bexti=1 binv=1 binvi=1 bset=1 bseti=1 czero.eqz=4 czero.nez=4

BENCH ZBB: PASS
```

`make bench-zbb OPT=-O0`:

```
Zbb benchmark (test/bench/zbb), -O0: each program built for -march=rv32i, rv32i_zbb_zbs and rv32im_zba_zbb_zbs

  variant                      image bytes new instrs  timed cycles  result
  zbb_bench-rv32i                     2604          0        824570  CHK 653f8521
  zbb_bench-rv32i_zbb_zbs             1912         15        598594  CHK 653f8521
  zbb_bench-rv32im_zba_zbb_zbs        1912         15        598594  CHK 653f8521
  zbb_arr-rv32i                       4384          0         61989  SUM 0ff9b7e9
  zbb_arr-rv32i_zbb_zbs               3836         22         53552  SUM 0ff9b7e9
  zbb_arr-rv32im_zba_zbb_zbs          3628         22         53644  SUM 0ff9b7e9
  zbb_diff                           10356        208       6010391  CASES 15773 BAD 0 EXTRA 0, ZBB DIFF OK
  zbb_diff-B5297A4D                   9976        208       4215754  CASES 12221 BAD 0 EXTRA 0, ZBB DIFF OK
  zbb_diff-1F123BB5                   9976        208       4217424  CASES 12221 BAD 0 EXTRA 0, ZBB DIFF OK
  zbb_diff-9E3779B9                   9976        208       4215128  CASES 12221 BAD 0 EXTRA 0, ZBB DIFF OK

  zbb_bench: rv32i -> rv32i_zbb_zbs: 824570 -> 598594 cycles (-27.4 %, 1.3775x), 2604 -> 1912 bytes (-26.6 %)
  zbb_bench: rv32i -> rv32im_zba_zbb_zbs: 824570 -> 598594 cycles (-27.4 %, 1.3775x), 2604 -> 1912 bytes (-26.6 %)
             CHK equal in the three builds: yes
  zbb_arr:   4384 / 3836 / 3628 bytes, P1-P8 and SUM equal in the three builds: yes; CYCLES 61989 / 53552 / 53644 (the window includes waiting for the UART)
  zbb_diff:  52436 checks in 4 runs (15773 + 12221 + 12221 + 12221), 0 mismatches, ZBB DIFF OK in 4 of 4; 28 of 28 forms in its code

  Zbb/Zbs/Zicond instructions in the code (per form; zbb_bench, zbb_arr):
    zbb_bench-rv32i_zbb_zbs       15 words, 13 forms: clz=2 ctz=1 cpop=2 max=1 min=1 minu=1 sext.b=1 sext.h=1 rol=1 ror=1 rori=1 orc.b=1 rev8=1
    zbb_arr-rv32i_zbb_zbs         22 words, 15 forms: clz=2 ctz=1 cpop=3 max=1 maxu=1 min=2 minu=1 sext.b=1 sext.h=2 zext.h=1 rol=3 ror=1 rori=1 czero.eqz=1 czero.nez=1
    zbb_bench-rv32im_zba_zbb_zbs  15 words, 13 forms: clz=2 ctz=1 cpop=2 max=1 min=1 minu=1 sext.b=1 sext.h=1 rol=1 ror=1 rori=1 orc.b=1 rev8=1
    zbb_arr-rv32im_zba_zbb_zbs    22 words, 15 forms: clz=2 ctz=1 cpop=3 max=1 maxu=1 min=2 minu=1 sext.b=1 sext.h=2 zext.h=1 rol=3 ror=1 rori=1 czero.eqz=1 czero.nez=1

BENCH ZBB: PASS
```

The run log of every program is in [`logs/`](logs) (`<level>.<variant>.run.log`, colour codes removed).

## Caveats

- `zbb_bench` is a best case, made of the code these extensions are for (population counts, bit scans, clamps, packed samples, masks, rotates, a bitmap); on ordinary code the gain is much smaller. In the FreeRTOS programs GCC uses 12 of the 26 Zbb and Zbs forms ([bitmanip record](../../bitmanip/2026-10-02_e75223e/RECORD.md)).
- The std objects are built for `rv32i` in every variant: with Zbs enabled, GCC 12.2 stops with an internal compiler error on `std/src/helperfunctions.c` (a conditional set or clear of bit 11). They only print, outside the timed windows.
- `rev8` and `orc.b` are written as inline assembly in the builds with Zbb (GCC 12 does not emit them on RV32); the `rv32i` build uses plain C for them.
- The sizes are those of the program image loaded into RAM (`out.bin`), not of `.text` alone. The `CYCLES` line of `zbb_arr` includes waiting for the UART inside its timed window; it is not a speed figure.
- The cycles are those of the Verilator model of the RTL of this working tree. The RTL has not been implemented on an FPGA since the Zbb, Zbs and Zicond unit was added, so whether it still meets 50 MHz is unknown.
