# SHA-256 benchmark: 2026-10-02, bd800d8

**Status: repeatable.** `make bench-sha256` reproduces every number below exactly (`make check-results CHECK_ARGS=sha256`).

## The figures and where they are quoted

| Quoted | Measured here |
|---|---|
| SHA-256 at 84.2, 63.4 and 49.8 cycles per byte at `-O2` with RV32I, with Zba, Zbb and Zbs, and with Zknh; Zknh 1.27× as fast as Zbb alone and 1.69× as fast as RV32I ([README.md](../../../README.md#an-extended-cpu), [docs/EXTENSIONS.md](../../../docs/EXTENSIONS.md#verification-7), [test/bench/README.md](../../../test/bench/README.md#make-bench-sha256)) | `sha256_bench`, one `sha256()` of 16,384 bytes: 1,378,827, 1,038,045 and 815,740 cycles (84.16, 63.36 and 49.79 per byte; 1.328×, 1.273×, 1.690×) |
| 84.2, 64.0 and 49.8 at `-Os`; 463.1, 407.6 and 213.3 at `-O0` (same places) | `-Os`: 1,379,765, 1,048,235, 815,650 cycles; `-O0`: 7,586,542, 6,677,790, 3,495,102 |
| one million bytes `'a'` give the FIPS 180-2 digest, at 50.5 cycles per byte with Zknh ([docs/EXTENSIONS.md](../../../docs/EXTENSIONS.md#verification-7), [test/bench/README.md](../../../test/bench/README.md#make-bench-sha256)) | `sha256_long`: `cdc76e5c…c7112cd0`, 50,521,930 cycles at `-O2`, 50,865,722 at `-Os`; not run at `-O0` |
| 33,260 results of the 17 forms compared without a mismatch ([docs/EXTENSIONS.md](../../../docs/EXTENSIONS.md#verification-7), [docs/VERIFICATION.md](../../../docs/VERIFICATION.md#system-level), [test/bench/README.md](../../../test/bench/README.md#make-bench-sha256)) | `crypto_diff` in 4 runs: 8,621 + 8,213 + 8,213 + 8,213 checks, 0 mismatches, `CRYPTO DIFF OK` in all four, at every level; its code holds all 17 forms |
| GCC emits no Zbkb, Zbkx or Zknh instruction from C, and `rori` and `rol` for the rotations of the Zbb build ([docs/EXTENSIONS.md](../../../docs/EXTENSIONS.md#zbkb-zbkx-and-zknh--scalar-cryptography), [test/bench/README.md](../../../test/bench/README.md#make-bench-sha256)) | the per-form counts below: the Zknh build holds the four `sha256` forms of `zknh.h`, the `rv32im_zba_zbb_zbs` build `rol` 5, `rori` 5 and `rev8` 1 at `-O2` |

The checks pass at all three levels: the six NIST checks (the empty message, `"abc"` and the 448-bit message, each whole and in pieces) in every build, and the digest of the 16,384-byte buffer is the same in the three builds and equal to the one `bench.py` computes with Python's `hashlib`.

## Commands

From the repository root:

```
make bench-sha256
make bench-sha256 OPT=-Os
make bench-sha256 OPT=-O0
```

The first builds the simulator, `build/sim/top`, if it does not exist yet. With `HADES_BUILD_DIR` set, all output goes to that directory instead of `build/`.

## Inputs

- Base commit `bd800d8`, with the Zbkb, Zbkx and Zknh changes not yet committed: [`inputs.sha256`](inputs.sha256) lists the sha256 of every file under `Makefile`, `test/bench/`, `std/`, `rtl/` and `defines/` that differs from the base commit, other than documentation (the RTL and decoder changes, `std/include/zknh.h` and `sha256.h`, `bench.mk`, `bench.py` and the programs of `test/bench/sha256/`). The other inputs (`sim/`, `lib/`, `ref/`) are those of the base commit.
- Products: [`results.csv`](results.csv) lists, for each of the 23 builds (8 variants at `-O2` and `-Os`, 7 at `-O0`), the source, `-march` and extra flags, the image size, the number of Zbkb, Zbkx and Zknh instructions and of distinct forms with the count of each, the timed cycles, the program's output and the sha256 of `init.mem` and `out.elf`; the run log of every program is in [`logs/`](logs). All are reproducible bit for bit.

## Environment

- Date: 2026-10-02
- Host: Intel Core Ultra 7 165H, 22 threads, Linux
- Tools: Verilator 5.042 2025-11-02 rev v5.042; riscv32-unknown-elf-gcc () 12.2.0 with GNU Binutils 2.39; Python 3.12.3; GNU Make 4.3
- Workers: 1 (`make` without `-j`). Wall time from a clean `build/test/bench/sha256/`, with the simulator built: `make bench-sha256` 61.5 s, `OPT=-Os` 64.4 s, `OPT=-O0` 96.1 s.

## Output

`make bench-sha256`, the summary printed after the build commands (verbatim):

```
SHA-256 benchmark (test/bench/sha256), -O2: sha256_bench built for -march=rv32i, rv32im_zba_zbb_zbs, rv32im_zba_zbb_zbkb_zbkx_zbs_zknh

  variant                                          image bytes new instrs  timed cycles  result
  sha256_bench-rv32i                                      3504          0       1378827  NIST 6/6, OK
  sha256_bench-rv32im_zba_zbb_zbs                         3160          0       1038045  NIST 6/6, OK
  sha256_bench-rv32im_zba_zbb_zbkb_zbkx_zbs_zknh          3036          4        815740  NIST 6/6, OK
  sha256_long-rv32im_zba_zbb_zbkb_zbkx_zbs_zknh           3108          4      50521930  NIST 6/6, OK
  crypto_diff                                             7548         43       7058515  CASES 8621 BAD 0 EXTRA 0, CRYPTO DIFF OK
  crypto_diff-B5297A4D                                    7384         43       5835097  CASES 8213 BAD 0 EXTRA 0, CRYPTO DIFF OK
  crypto_diff-1F123BB5                                    7384         43       5835013  CASES 8213 BAD 0 EXTRA 0, CRYPTO DIFF OK
  crypto_diff-9E3779B9                                    7384         43       5834745  CASES 8213 BAD 0 EXTRA 0, CRYPTO DIFF OK

  sha256_bench: 16384 bytes; NIST examples 6/6 in every build; DIGEST 00128dedfa357517a7718b37759dde4126b85c8029573169136c8a1e3e8892e9
                DIGEST equal in the three builds and to Python's hashlib: yes
  cycles per byte (one sha256() of 16384 bytes, padding block included):
    rv32i                                   1378827 cycles  84.16 cycles per byte  3504 bytes
    rv32im_zba_zbb_zbs                      1038045 cycles  63.36 cycles per byte  3160 bytes
    rv32im_zba_zbb_zbkb_zbkx_zbs_zknh        815740 cycles  49.79 cycles per byte  3036 bytes
  speed-ups: Zba+Zbb+Zbs over rv32i 1.328x, Zknh over Zba+Zbb+Zbs 1.273x, Zknh over rv32i 1.690x
  sha256_long (Zknh): 1,000,000 bytes 'a', digest cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0 (as expected): 50521930 cycles, 50.52 cycles per byte
  crypto_diff: 33260 checks in 4 runs (8621 + 8213 + 8213 + 8213), 0 mismatches, CRYPTO DIFF OK in 4 of 4; 17 of 17 forms in its code

  Zbkb, Zbkx and Zknh instructions in the code (per form):
    sha256_bench-rv32i                                 0 words,  0 forms: -
    sha256_bench-rv32im_zba_zbb_zbs                    0 words,  0 forms: -
    sha256_bench-rv32im_zba_zbb_zbkb_zbkx_zbs_zknh     4 words,  4 forms: sha256sig0=1 sha256sig1=1 sha256sum0=1 sha256sum1=1
  Zbb, Zbs and Zicond instructions in the code (per form):
    sha256_bench-rv32i                                 0 words,  0 forms: -
    sha256_bench-rv32im_zba_zbb_zbs                   13 words,  5 forms: andn=1 minu=1 rol=5 rori=5 rev8=1
    sha256_bench-rv32im_zba_zbb_zbkb_zbkx_zbs_zknh     3 words,  3 forms: andn=1 minu=1 rev8=1

BENCH SHA256: PASS
```

`make bench-sha256 OPT=-Os`:

```
SHA-256 benchmark (test/bench/sha256), -Os: sha256_bench built for -march=rv32i, rv32im_zba_zbb_zbs, rv32im_zba_zbb_zbkb_zbkx_zbs_zknh

  variant                                          image bytes new instrs  timed cycles  result
  sha256_bench-rv32i                                      3068          0       1379765  NIST 6/6, OK
  sha256_bench-rv32im_zba_zbb_zbs                         2740          0       1048235  NIST 6/6, OK
  sha256_bench-rv32im_zba_zbb_zbkb_zbkx_zbs_zknh          2640          4        815650  NIST 6/6, OK
  sha256_long-rv32im_zba_zbb_zbkb_zbkx_zbs_zknh           2656          4      50865722  NIST 6/6, OK
  crypto_diff                                             4752         41       8616331  CASES 8621 BAD 0 EXTRA 0, CRYPTO DIFF OK
  crypto_diff-B5297A4D                                    4360         41       6896128  CASES 8213 BAD 0 EXTRA 0, CRYPTO DIFF OK
  crypto_diff-1F123BB5                                    4360         41       6896044  CASES 8213 BAD 0 EXTRA 0, CRYPTO DIFF OK
  crypto_diff-9E3779B9                                    4360         41       6895777  CASES 8213 BAD 0 EXTRA 0, CRYPTO DIFF OK

  sha256_bench: 16384 bytes; NIST examples 6/6 in every build; DIGEST 00128dedfa357517a7718b37759dde4126b85c8029573169136c8a1e3e8892e9
                DIGEST equal in the three builds and to Python's hashlib: yes
  cycles per byte (one sha256() of 16384 bytes, padding block included):
    rv32i                                   1379765 cycles  84.21 cycles per byte  3068 bytes
    rv32im_zba_zbb_zbs                      1048235 cycles  63.98 cycles per byte  2740 bytes
    rv32im_zba_zbb_zbkb_zbkx_zbs_zknh        815650 cycles  49.78 cycles per byte  2640 bytes
  speed-ups: Zba+Zbb+Zbs over rv32i 1.316x, Zknh over Zba+Zbb+Zbs 1.285x, Zknh over rv32i 1.692x
  sha256_long (Zknh): 1,000,000 bytes 'a', digest cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0 (as expected): 50865722 cycles, 50.87 cycles per byte
  crypto_diff: 33260 checks in 4 runs (8621 + 8213 + 8213 + 8213), 0 mismatches, CRYPTO DIFF OK in 4 of 4; 17 of 17 forms in its code

  Zbkb, Zbkx and Zknh instructions in the code (per form):
    sha256_bench-rv32i                                 0 words,  0 forms: -
    sha256_bench-rv32im_zba_zbb_zbs                    0 words,  0 forms: -
    sha256_bench-rv32im_zba_zbb_zbkb_zbkx_zbs_zknh     4 words,  4 forms: sha256sig0=1 sha256sig1=1 sha256sum0=1 sha256sum1=1
  Zbb, Zbs and Zicond instructions in the code (per form):
    sha256_bench-rv32i                                 0 words,  0 forms: -
    sha256_bench-rv32im_zba_zbb_zbs                   13 words,  5 forms: andn=1 minu=1 rol=5 rori=5 rev8=1
    sha256_bench-rv32im_zba_zbb_zbkb_zbkx_zbs_zknh     3 words,  3 forms: andn=1 minu=1 rev8=1

BENCH SHA256: PASS
```

`make bench-sha256 OPT=-O0`:

```
SHA-256 benchmark (test/bench/sha256), -O0: sha256_bench built for -march=rv32i, rv32im_zba_zbb_zbs, rv32im_zba_zbb_zbkb_zbkx_zbs_zknh

  variant                                          image bytes new instrs  timed cycles  result
  sha256_bench-rv32i                                      5120          0       7586542  NIST 6/6, OK
  sha256_bench-rv32im_zba_zbb_zbs                         4888          0       6677790  NIST 6/6, OK
  sha256_bench-rv32im_zba_zbb_zbkb_zbkx_zbs_zknh          4632          4       3495102  NIST 6/6, OK
  crypto_diff                                             7448         41      32835904  CASES 8621 BAD 0 EXTRA 0, CRYPTO DIFF OK
  crypto_diff-B5297A4D                                    6820         41      27079377  CASES 8213 BAD 0 EXTRA 0, CRYPTO DIFF OK
  crypto_diff-1F123BB5                                    6820         41      27079104  CASES 8213 BAD 0 EXTRA 0, CRYPTO DIFF OK
  crypto_diff-9E3779B9                                    6820         41      27078233  CASES 8213 BAD 0 EXTRA 0, CRYPTO DIFF OK

  sha256_bench: 16384 bytes; NIST examples 6/6 in every build; DIGEST 00128dedfa357517a7718b37759dde4126b85c8029573169136c8a1e3e8892e9
                DIGEST equal in the three builds and to Python's hashlib: yes
  cycles per byte (one sha256() of 16384 bytes, padding block included):
    rv32i                                   7586542 cycles  463.05 cycles per byte  5120 bytes
    rv32im_zba_zbb_zbs                      6677790 cycles  407.58 cycles per byte  4888 bytes
    rv32im_zba_zbb_zbkb_zbkx_zbs_zknh       3495102 cycles  213.32 cycles per byte  4632 bytes
  speed-ups: Zba+Zbb+Zbs over rv32i 1.136x, Zknh over Zba+Zbb+Zbs 1.911x, Zknh over rv32i 2.171x
  sha256_long (Zknh): not run at -O0 (over 200 million cycles)
  crypto_diff: 33260 checks in 4 runs (8621 + 8213 + 8213 + 8213), 0 mismatches, CRYPTO DIFF OK in 4 of 4; 17 of 17 forms in its code

  Zbkb, Zbkx and Zknh instructions in the code (per form):
    sha256_bench-rv32i                                 0 words,  0 forms: -
    sha256_bench-rv32im_zba_zbb_zbs                    0 words,  0 forms: -
    sha256_bench-rv32im_zba_zbb_zbkb_zbkx_zbs_zknh     4 words,  4 forms: sha256sig0=1 sha256sig1=1 sha256sum0=1 sha256sum1=1
  Zbb, Zbs and Zicond instructions in the code (per form):
    sha256_bench-rv32i                                 0 words,  0 forms: -
    sha256_bench-rv32im_zba_zbb_zbs                    2 words,  2 forms: ror=1 rev8=1
    sha256_bench-rv32im_zba_zbb_zbkb_zbkx_zbs_zknh     1 words,  1 forms: rev8=1

BENCH SHA256: PASS
```

## Caveats

- `sha256_bench` measures SHA-256 alone, a best case for Zknh; a program that hashes little gains little. The time that remains with Zknh is the message schedule's additions and each round's choice, majority and additions, which no instruction of these extensions computes.
- The std objects are built for `rv32i` in every variant: with Zbs enabled, GCC 12.2 stops with an internal compiler error on `std/src/helperfunctions.c`. They only print, outside the timed windows.
- GCC 12.2 has no builtins for the Zknh instructions and never emits them from C: [`std/include/zknh.h`](../../../std/include/zknh.h) issues them by inline assembly, and `rev8` is inline assembly as well (GCC 12 does not emit it on RV32). The `rv32i` build reads the message with byte loads.
- `sha256_long` is not run at `-O0`: at about 213 cycles per byte it would take over 200 million cycles, more than three minutes of simulation.
- The sizes are those of the program image loaded into RAM (`out.bin`), not of `.text` alone.
- The cycles are those of the Verilator model of the RTL of this working tree. The RTL has not been implemented on an FPGA since the Zbb, Zbs and Zicond unit was added, nor since its cryptography half, so whether it still meets 50 MHz is unknown.
