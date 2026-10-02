# Benchmarks and measurement programs

The programs in this directory reproduce figures that the documentation quotes. Each `make` target builds its programs, runs them on the simulator of the assembly and C tests, checks the results, and prints a summary that ends in one line, `BENCH <NAME>: PASS` or `BENCH <NAME>: FAIL`; the target fails unless it says `PASS`. The results recorded so far, with the exact output, the commands and fingerprints of the inputs, are in [`results/`](../../results).

| Target | Programs | Reproduces | Recorded in |
|---|---|---|---|
| `make bench-zba [OPT=-O2]` | [`zba/`](zba) | the Zba figures: 20.3 % fewer cycles (1.26×), 6–8 % smaller code, 16,704 operand comparisons without a mismatch ([docs/EXTENSIONS.md](../../docs/EXTENSIONS.md#zba--scaled-index-address-generation)) | [`results/zba/`](../../results/zba) |
| `make bench-zbb [OPT=-O2]` | [`zbb/`](zbb) | the Zbb, Zbs and Zicond figures: 59.8 % fewer cycles (2.49×) in a best-case loop, 52,436 results of the 28 instruction forms compared without a mismatch ([docs/EXTENSIONS.md](../../docs/EXTENSIONS.md#zbb-and-zbs--bit-manipulation-b)) | [`results/zbb/`](../../results/zbb) |
| `make bench-mcost` | [`mcost/`](mcost) | the *Measured* column of the M unit's cycle table ([docs/EXTENSIONS.md](../../docs/EXTENSIONS.md#execute-learns-to-stall)) | [`results/m-unit-cycles/`](../../results/m-unit-cycles) |
| `make bench-fencei-window` | [`fencei-window/`](fencei-window) | the 3-slot staleness window without `FENCE.I` ([README.md](../../README.md), [docs/EXTENSIONS.md](../../docs/EXTENSIONS.md#zifencei--instruction-fetch-synchronisation)) | [`results/fencei-window/`](../../results/fencei-window) |
| `make bench` | all four | | |

Everything is built into `$(BUILD_DIR)/test/bench/` (`build/test/bench/` unless the build directory is relocated with `BUILD_DIR` or `HADES_BUILD_DIR`, see [docs/BUILDING.md](../../docs/BUILDING.md#building-running-and-debugging)); the objects of the assembly and C tests are not touched. The programs run again on every invocation, without writing waveforms, with a limit of 5,000,000 cycles per run (`BENCH_TIMEOUT`; 20,000,000 for `bench-zbb`, whose `zbb_diff` takes about 6 million cycles at `-O0`). The rules are in [`bench.mk`](bench.mk), the checks and summaries in [`bench.py`](bench.py). With `make -j`, add `-O` so that each summary is printed in one piece.

The programs were first written and run during development, outside the repository, and were recovered from the development log. In every recovered file, everything after the license header is the program exactly as it was measured, with one exception: `fencei-window/fencei_stale.s` was reconstructed from its first version and the four edits that the log records, and checked against the line numbers and disassembly addresses in the log ([results/fencei-window/2026-08-17_15b0b85](../../results/fencei-window/2026-08-17_15b0b85/RECORD.md)). The one program added later, `mcost/loop_empty.s`, says so in its header; the programs of `zbb/` were written for this repository when Zbb, Zbs and Zicond were added. The records in `results/` give the dates, the commits and the fingerprints.

## `make bench-zba`

`zba_bench.c` and `zba_arr.c` are compiled twice with GCC, for `-march=rv32i` (scaled indices as `slli` + `add`) and for `-march=rv32i_zba` (GCC emits `sh1add`/`sh2add`/`sh3add`), at `-O2` unless `OPT` says otherwise; each build has its own copies of the `std/` objects, compiled with the same flags.

- [`zba_bench.c`](zba/zba_bench.c): an address-generation workload with no I/O inside the timed window. Its checksum (`CHK`) must be equal for both builds; its cycle count (`CYC`, read from `mcycle`) and the size of the program image (`out.bin`) are the result.
- [`zba_arr.c`](zba/zba_arr.c): eight address-generation phases, each printing a checksum (`P1`–`P8`, `SUM`). All of them must be equal for both builds; its `CYCLES` line includes waiting for the UART, so it is not a speed figure.
- [`zba_diff.c`](zba/zba_diff.c): built for `rv32i` only. It issues the three Zba instructions as `.insn` words and compares every result with the same computation in RV32I. It runs four times: with its defaults (a 32 × 32 pool of special values and 128 random pairs) and with 1,400 random pairs each from the seeds `0xB5297A4D`, `0x1F123BB5` and `0x9E3779B9`. Every run must end in `ZBA DIFF OK`, with no mismatch.

The summary gives, for each build, the image size, the number of Zba instructions in the code, the timed cycles and the checksums, and then the comparison. At `-O2`:

```
  zba_bench: 45350 -> 36133 cycles (-20.3 %, 1.2551x), 940 -> 868 bytes (-7.7 %), CHK equal: yes
             Zba instructions in the rv32i_zba build: 5 sh1add, 6 sh2add, 5 sh3add
  zba_arr:   1680 -> 1576 bytes (-6.2 %), P1-P8 and SUM equal: yes; CYCLES 23386 -> 22234 (the window includes waiting for the UART)
  zba_diff:  16704 checks in 4 runs (3618 + 4362 + 4362 + 4362), 0 mismatches, ZBA DIFF OK in 4 of 4

BENCH ZBA: PASS
```

`OPT=-Os` gives 14.0 % fewer cycles for `zba_bench`; at `OPT=-O0` GCC emits no Zba instruction, and both builds are identical. The verdict depends only on the equality checks, not on the size of the gain.

## `make bench-zbb`

`zbb_bench.c` and `zbb_arr.c` are compiled three times with GCC, for `-march=rv32i`, for `-march=rv32i_zbb_zbs` and for `-march=rv32im_zba_zbb_zbs`, at `-O2` unless `OPT` says otherwise. Each build has its own copies of the `std/` objects, compiled for `rv32i` (they only print, outside the timed windows): with Zbs enabled, GCC 12.2 stops with an internal compiler error on `std/src/helperfunctions.c`, which sets or clears bit 11 under a condition.

- [`zbb_bench.c`](zbb/zbb_bench.c): a bit-manipulation workload with no I/O inside the timed window: population counts, integer log2 and normalisation, bit scans, clamps, packed 8- and 16-bit samples, masks, a hash with rotates, `rev8` and `orc.b` (written by hand in the builds with Zbb, as GCC 12 does not emit them) and a bitmap. Its checksum (`CHK`) must be equal in all three builds; its cycle count (`CYC`, from `mcycle`) and the image size are the result.
- [`zbb_arr.c`](zbb/zbb_arr.c): eight phases, each printing a checksum (`P1`–`P8`, `SUM`): population counts, leading and trailing zeros, `min`/`max`, sign and zero extension, masks, rotates, a bitmap with the register and immediate forms of Zbs, and a branch-free select, clamp and conditional add through [`std/include/zicond.h`](../../std/include/zicond.h) (in the `rv32i` build with `ZICOND_PORTABLE`, so in plain C). All of them must be equal in the three builds; `CYCLES` includes waiting for the UART.
- [`zbb_diff.c`](zbb/zbb_diff.c): built for `rv32i` only. It issues each of the 28 Zbb, Zbs and Zicond instruction forms as an `.insn` word (`czero` through `zicond.h`) and compares every result with a computation in RV32I C written from the ISA text: a pool of 24 special values (every pair for the two-operand forms, every shift amount for the immediate forms), 96 random pairs, a dependent chain, results used as load addresses and by branches, `rd = x0`, and the same register as both operands. It runs four times: with its defaults and with 400 random pairs each from the seeds `0xB5297A4D`, `0x1F123BB5` and `0x9E3779B9`. Every run must end in `ZBB DIFF OK`, with no mismatch, and its code must contain all 28 forms.

The summary gives, for each build, the image size, the number of Zbb, Zbs and Zicond instructions in the code, the timed cycles and the checksums, then the comparison and, per form, the instructions GCC chose. At `-O2`:

```
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

`zbb_bench` is a best case, made of the code these extensions are for. `OPT=-Os` gives 62.0 % fewer cycles; at `OPT=-O0` GCC still uses some of the instructions, and the gain is 27.4 %. At `-O2`, GCC 12 emits neither `xnor` nor `zext.h` in these two programs; the [example app `bitmanip`](../../docs/APPS.md#the-example-apps) shows idioms for every form. The verdict depends only on the equality checks, not on the size of the gain ([record](../../results/zbb/2026-10-02_e75223e/RECORD.md)).

## `make bench-mcost`

Two independent measurements of what each M instruction costs in the assembled core:

- [`loop_addi.s`, `loop_mul.s`, `loop_div.s`, `loop_div0.s`](mcost): 100 iterations of 8 back-to-back `addi`, `mul`, `div` or divide-by-zero `div`, that is 800 operations, between two stores to the test peripheral whose times the simulator prints (20 time units per cycle). [`loop_empty.s`](mcost/loop_empty.s) is the same loop with an empty body, which measures the loop overhead; the cost per operation is `(cycles - cycles of loop_empty) / 800`.
- [`mcost.c`](mcost/mcost.c), compiled for `rv32im` at `-O2`: 64 iterations of 8 identical instructions (512) for each of the eight M instructions, for `div` and `remu` by zero and for `-2³¹ / -1`, timed with `mcycle` against the same loop of `add`s; the cost is `(cycles - cycles of the add loop) / 512 + 1`.

The summary compares both with the table in docs/EXTENSIONS.md, and the verdict requires every value to match it:

```
  docs/EXTENSIONS.md "Measured" column   documented  800-op loops  mcost.c
  any RV32I ALU op                             1.00          1.00  (reference)
  mul / mulh / mulhsu / mulhu                  2.00          2.00  2.00 2.00 2.00 2.00
  div / divu / rem / remu                     34.00         34.00  34.00 34.00 34.00 34.00
  div / rem by zero, or -2^31 / -1             1.00          1.00  1.00 1.00 1.00

BENCH MCOST: PASS
```

The stage-level counterpart, the *Cycles in Execute* column, is printed by `make test/sv/test_m_execute` (`MEASURED: multiply = 2 cycles, divide = 34 cycles, early-out divide = 1 cycle(s)`).

## `make bench-fencei-window`

[`fencei_stale.s`](fencei-window/fencei_stale.s) patches, with a store, an instruction 4, 8, 12, 16 or 20 bytes after the store and then runs into it, without `FENCE.I`; the gap between them holds only `nop`s, so no jump can flush the pipeline. The patched instruction writes a marker that tells whether the old or the new word executed. Two controls repeat a case with something else in the gap: `FENCE.I` at distance 8, and at distance 12 two loads from the test peripheral's stall register, which hold the pipeline for extra cycles. The program checks the results itself (the first check fails on purpose, as in every assembly test), and [`stall_probe.s`](fencei-window/stall_probe.s) measures with `mcycle` how long those two loads take.

```
  sw+4  (0 nops in gap)   : OLD (STALE)
  sw+8  (1 nop  in gap)   : OLD (STALE)
  sw+12 (2 nops in gap)   : OLD (STALE)
  sw+16 (3 nops in gap)   : NEW (fresh)
  sw+20 (4 nops in gap)   : NEW (fresh)
  sw+8  (fence.i in gap)  : NEW (fresh)
  sw+12 (2 stalling lw )  : OLD (STALE)
```

The three instruction slots after the store run the old word. At `sw+4` and `sw+8` the instruction is already in a pipeline register when the store writes the memory. At `sw+12` the fetch reads the word through one port of the block RAM in the same cycle as the store writes it through the other: Verilator returns the old word, but on a Xilinx block RAM the data read in that case is undefined, so on the FPGA the `sw+12` instruction is not reliably fresh rather than certainly stale. [test/asm/fencei.s](../asm/fencei.s) therefore checks only what `FENCE.I` guarantees.
