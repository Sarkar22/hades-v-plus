# Zba benchmark: first measurement, 2026-08-18, 1f501f5

**Status: historical.** These are the figures as first measured, with a build script that was never part of the repository. `make bench-zba` replaces it and reproduces them exactly: see [the record of 2026-10-01](../2026-10-01_03386fd/RECORD.md).

## The figures and where they are quoted

[docs/EXTENSIONS.md](../../../docs/EXTENSIONS.md) line 123:

> Measured during development (commit 1f501f5) with a benchmark that is not included in the repository, on an address-generation-heavy workload: **20.3 % fewer cycles** (1.26×) and 6–8 % smaller code, verified across 16,704 in-program operand comparisons with zero discrepancies.

As found in the development log of 2026-08-18 (00:22 to 00:37, UTC−4), all at `-O2`:

- `zba_bench`: `CHK ca5f039c` in both builds; `CYC 0000b126` (45,350 cycles) built for rv32i and `CYC 00008d25` (36,133) built for rv32i_zba: 20.32 % fewer cycles, 1.2551× as fast. Quoted as 20.3 % and 1.26×.
- Program image (`out.bin`): `zba_bench` 940 → 868 bytes (−7.7 %), `zba_arr` 1,680 → 1,576 bytes (−6.2 %). Quoted as 6–8 %.
- Zba instructions in the rv32i_zba build of `zba_bench`: 5 `sh1add`, 6 `sh2add`, 5 `sh3add`; none in the rv32i build.
- `zba_arr`: `P1`–`P8` and `SUM` equal in both builds; its `CYCLES` line, 23,386 → 22,234 (−4.93 %), includes waiting for the UART.
- `zba_diff`: `CASES 00000e22` (3,618) with its defaults, `CASES 0000110a` (4,362) with each of three seeds and 1,400 random pairs; `BAD 0`, `EXTRA 0` and `ZBA DIFF OK` in all four: 16,704 comparisons. Quoted as 16,704 with zero discrepancies.

The log, verbatim. The calculation:

```
bench off 45350, on 36133, saved 9217, reduction 20.32%, speedup 1.2551x
arr   off 23386, on 22234, saved 1152, reduction 4.93%
cases: main 3618 + 3x 4362 = 16704
cycles: main 51127, rnd 75441
per-comparison cost 14.1 cycles
--- code size ---
zba_arr_off: 1680
zba_arr_on: 1576
zba_bench_off: 940
zba_bench_on: 868
```

The runs (`_off` = built for rv32i, `_on` = built for rv32i_zba):

```
--- zba_arr_off ---
P1 2d47272d
P2 d2b891fc
P3 13f51b20
P4 5dc557b7
P5 5082b68e
P6 7dc9f82d
P7 356f0e1e
P8 78565846
SUM 78565846
CYCLES 00005b5a
--- zba_arr_on ---
P1 2d47272d
P2 d2b891fc
P3 13f51b20
P4 5dc557b7
P5 5082b68e
P6 7dc9f82d
P7 356f0e1e
P8 78565846
SUM 78565846
CYCLES 000056da
--- zba_bench_off ---
CHK ca5f039c
CYC 0000b126
--- zba_bench_on ---
CHK ca5f039c
CYC 00008d25
--- zba_diff ---
CASES 00000e22
BAD 00000000
EXTRA 00000000
CSUM d3cb1e95
CYCLES 0000c7b7
ZBA DIFF OK
```

```
##### random-only, SEED=0xB5297A4Du, N_RANDOM=1400 #####
CASES 0000110a
BAD 00000000
EXTRA 00000000
CSUM 763675a3
CYCLES 000126b1
ZBA DIFF OK
##### random-only, SEED=0x1F123BB5u, N_RANDOM=1400 #####
CASES 0000110a
BAD 00000000
EXTRA 00000000
CSUM bf7d075d
CYCLES 000126af
ZBA DIFF OK
##### random-only, SEED=0x9E3779B9u, N_RANDOM=1400 #####
CASES 0000110a
BAD 00000000
EXTRA 00000000
CSUM e3c933f4
CYCLES 000126af
ZBA DIFF OK
```

## Where it was measured

In a working copy of 80dfaca ("Add Zicntr") that carried the Zba implementation, not yet committed. It was committed at 00:44 the same night as 1f501f5, "Add Zba: sh1add / sh2add / sh3add", the commit that the documentation names. Trees of 1f501f5 (`git rev-parse 1f501f5:<dir>`): rtl `d990b12c0ed76026f7143c4e36357b943afd7325`, lib `10e725f3ea301c460e5cc6fe85372f7d7a56ff3b`, defines `5593f63e4478a326c1ce53f365d6385f16362689`, sim `b9ea689e3115da8714c525858c64d7131505378f`, std `05909d5f7dd5d23f80a2d11e127fdb79eb8a5468`.

## How it was measured

The three programs were then `test/c/zba_bench.c`, `zba_arr.c` and `zba_diff.c` in the working copy (sha256 `9e9b491f12994d844d0098358b175b9db1c5b4a833aebfe0386791baf67bd1a9`, `228121fe3d58b2bb251016f5513adc05839291c23f420fe60212b1fb07c0fe64`, `2a41bad7d24dd6dfc5a7455b1a96b81695f85c518d4de745bc82af063cfa0e80`); they are now in `test/bench/zba/`, unchanged after the license header. A script built each variant in its own directory, with private copies of the `std/` objects compiled with the same flags:

```
FLAGS="-O2 -march=rv32i"        # or -march=rv32i_zba; for the three random runs of zba_diff
                                # also -DSKIP_POOL -DN_RANDOM=1400 -DSEED=<seed>u
riscv32-unknown-elf-gcc -fdata-sections -ffunction-sections -I std/include $FLAGS -c -o std/<f>.o std/src/<f>.c
riscv32-unknown-elf-gcc -fdata-sections -ffunction-sections -I std/include $FLAGS -c -o out.o <program>.c
riscv32-unknown-elf-gcc -o out.elf -nostdlib -nostartfiles -T std/hades-v.ld $FLAGS out.o std/*.o -lgcc \
    -Wl,--no-warn-rwx-segments -Wl,--gc-sections
riscv32-unknown-elf-objcopy -O binary out.elf out.bin
riscv32-unknown-elf-objcopy -I binary -O verilog -S --verilog-data-width 4 --reverse-bytes=4 out.bin init.mem
```

Each image was then run with `build/sim/top` in its directory (the simulator's default limit of 100,000 cycles). `make bench-zba` does the same, except that the `-D` flags of the random runs go to the program only; the `std/` objects do not use them, and the images are identical.

## Environment

- Date: 2026-08-18
- Tools named in the log: Verilator 5.042 2025-11-02; riscv32-unknown-elf-gcc () 12.2.0.
- Host and wall time: not recorded.

## Re-runs on 2026-10-01

- `make bench-zba` on 03386fd reproduces every figure above: [the record of 2026-10-01](../2026-10-01_03386fd/RECORD.md).
- The images built by `make bench-zba` are byte-identical to those built by the script above, recovered from the log. On a simulator built from 1f501f5 they print exactly the lines quoted here.

## Caveats

- The documentation says "commit 1f501f5": the measurement ran on the working copy that was committed as 1f501f5 a few minutes later, not on the commit itself; the re-run above confirms that 1f501f5 gives the same numbers.
- Between the measurement runs, the log also records a deliberate fault in the RTL (`sh2add` shifting by 4), reverted afterwards: with it, `zba_diff` reported mismatches and `zba_arr` timed out, so the checks do detect a wrong result. The runs quoted above were made on the correct RTL, the random runs before the fault and the others after it was reverted.
