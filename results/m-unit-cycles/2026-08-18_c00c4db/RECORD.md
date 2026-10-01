# Cycles per M instruction: first measurement, 2026-08-18, c00c4db

**Status: historical.** These are the measurements behind the *Measured* column, made with programs that were deleted afterwards. They were recovered from the development log, and `make bench-mcost` now runs them: see [the record of 2026-10-01](../2026-10-01_03386fd/RECORD.md).

## The figures and where they are quoted

[docs/EXTENSIONS.md](../../../docs/EXTENSIONS.md) lines 47 to 54, written together with the measurement and first committed in c00c4db:

> | Operation | Cycles in Execute | Measured |
> |---|---|---|
> | any RV32I ALU op | 1 | 1.00 |
> | `mul` / `mulh` / `mulhsu` / `mulhu` | 2 | 2.00 |
> | `div` / `divu` / `rem` / `remu` | 34 | 34.00 |
> | `div` / `rem` by zero, or `-2³¹ / -1` | 1 | 1.00 |
>
> *(Measured in the assembled core over 800 back-to-back operations, loop overhead subtracted.)*

As found in the development log of 2026-08-18. At 09:26 (UTC−4), four assembly programs, `test/asm/zz_meas_nop.s`, `zz_meas_mul.s`, `zz_meas_div.s` and `zz_meas_dv0.s`, each ran 100 iterations of 8 back-to-back `addi s1, t5, 0`, `mul s1, t5, t6`, `div s1, t5, t6` or `div s1, t5, zero` (t5 = 1,000,003, t6 = 7) between two stores to the test peripheral. A and B are the times of those stores that the simulator printed, 20 time units per cycle; per-op is cycles / 800 (verbatim):

```
zz_meas_nop    A=320      B=24300    delta=23980    cycles=1199     per-op=1.499
zz_meas_div    A=320      B=552300   delta=551980   cycles=27599    per-op=34.499
zz_meas_mul    A=320      B=40300    delta=39980    cycles=1999     per-op=2.499
zz_meas_dv0    A=320      B=24300    delta=23980    cycles=1199     per-op=1.499
```

The conclusion recorded with it: "the constant 0.499 is the shared loop overhead, so the marginal costs are 1 / 2 / 34 / 1", which is the *Measured* column.

At 09:53, a second, independent program, `mcost.c`, timed 64 × 8 = 512 of each M instruction with `mcycle` against the same loop of `add`s (operands 0xDEADBEEF and 13). Its first run (verbatim, a colour code removed):

```
base-add 00000302
mul      00000502
mulh     00000502
mulhsu   00000502
mulhu    00000502
div      00004502
divu     00004502
rem      00004502
remu     0000450
Simulation timeout!
```

The simulator's limit of 100,000 cycles ended it in the `remu` line. A copy without the eight slow lines measured the early-out cases, and the costs were computed from both runs (verbatim):

```
base-add 00000302
div-by-0 00000302
remu-by-0 00000302
div-ovf  00000302

cycles for 64 iterations x 8 instructions (512 instructions + loop):
  base add                    770   marginal cost vs add =  0.00 cycles/instr ->  1.00 total
  mul/mulh/mulhsu/mulhu      1282   marginal cost vs add =  1.00 cycles/instr ->  2.00 total
  div/divu/rem/remu         17666   marginal cost vs add = 33.00 cycles/instr -> 34.00 total
```

## Where it was measured

In a working copy of 1f501f5 that carried the M implementation, not yet committed. Its files were copied into the repository and committed at 10:18 the same morning as c00c4db, "Add M extension: mul/div, and Execute's first stall". Trees of c00c4db (`git rev-parse c00c4db:<dir>`): rtl `184ba0352d5a21d130d7f31c215b0130c9b85685`, lib `10e725f3ea301c460e5cc6fe85372f7d7a56ff3b`, defines `77ae7c8984915dc833bf68e1e5d32b267b8a02bf`, sim `b9ea689e3115da8714c525858c64d7131505378f`, std `05909d5f7dd5d23f80a2d11e127fdb79eb8a5468`.

## How it was measured

- The four loop programs were assembled and run as assembly tests (`make test/asm/zz_meas_<x>`); the cycles are (B − A) / 20. They are now `test/bench/mcost/loop_addi.s`, `loop_mul.s`, `loop_div.s` and `loop_div0.s`, unchanged after the license header.
- `mcost.c` was compiled for `-march=rv32im -O2`, with private copies of the `std/` objects compiled with the same flags, linked with the link command of the C tests plus those flags, and run with `build/sim/top`. It is now `test/bench/mcost/mcost.c`, the first version, unchanged after the license header.

## Environment

- Date: 2026-08-18
- Tools named in the log: Verilator 5.042 2025-11-02; riscv32-unknown-elf-gcc 12.2.0.
- Host and wall time: not recorded.

## Re-runs on 2026-10-01

- On a simulator built from c00c4db, the recovered programs, whose images are byte-identical to those that `make bench-mcost` builds, give exactly the numbers above, including the end of the first `mcost.c` run in the `remu` line.
- On 03386fd, `make bench-mcost` gives the same numbers: [the record of 2026-10-01](../2026-10-01_03386fd/RECORD.md).

## Caveats

- The overhead of 0.499 cycles per operation was taken from the ALU loop, that is, on the assumption that an ALU operation costs one cycle. `make bench-mcost` adds a loop with an empty body that measures the overhead (399 cycles, 0.499 per operation) and gives the same column.
- Shortly before the measurement, the log also records runs with deliberate faults in the RTL, each reverted within the same command; the re-run on c00c4db, which gives the same counts, shows that the measurement was made on the correct RTL.
