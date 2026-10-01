# Cycles per M instruction: 2026-10-01, 03386fd

**Status: repeatable.** `make bench-mcost` reproduces the *Measured* column exactly.

## The figures and where they are quoted

[docs/EXTENSIONS.md](../../../docs/EXTENSIONS.md) lines 47 to 54:

> | Operation | Cycles in Execute | Measured |
> |---|---|---|
> | any RV32I ALU op | 1 | 1.00 |
> | `mul` / `mulh` / `mulhsu` / `mulhu` | 2 | 2.00 |
> | `div` / `divu` / `rem` / `remu` | 34 | 34.00 |
> | `div` / `rem` by zero, or `-2³¹ / -1` | 1 | 1.00 |
>
> *(Measured in the assembled core over 800 back-to-back operations, loop overhead subtracted.)*

| Row | Documented | 800-operation loops | `mcost.c`, 512 of each |
|---|---|---|---|
| any RV32I ALU op | 1.00 | `addi`: (1,199 − 399) / 800 = 1.00 | `add`: the reference |
| `mul` / `mulh` / `mulhsu` / `mulhu` | 2.00 | `mul`: (1,999 − 399) / 800 = 2.00 | 1,282 cycles each: 2.00 |
| `div` / `divu` / `rem` / `remu` | 34.00 | `div`: (27,599 − 399) / 800 = 34.00 | 17,666 cycles each: 34.00 |
| `div` / `rem` by zero, or `-2³¹ / -1` | 1.00 | `div` by zero: (1,199 − 399) / 800 = 1.00 | `div` by 0, `remu` by 0, `-2³¹ / -1`: 770 cycles each: 1.00 |

399 cycles is the loop overhead, measured by the same loop with an empty body (100 iterations of `addi t2, t2, -1` and `bne t2, zero, loop`). For `mcost.c` the cost is (cycles − 770) / 512 + 1, 770 being its loop of `add`s.

The *Cycles in Execute* column is the design value; `make test/sv/test_m_execute` measures it at the stage level and prints, on 03386fd:

```
MEASURED: multiply = 2 cycles, divide = 34 cycles, early-out divide = 1 cycle(s)
Checks: 6268   Errors: 0
```

## Commands

From the repository root, on 03386fd with `test/bench/` and the bench targets of the `Makefile` added (the files and their sha256 are listed in [`inputs.sha256`](inputs.sha256)):

```
make bench-mcost
make test/sv/test_m_execute    # the stage-level line above (an existing test)
```

## Inputs

- Base commit `03386fdda932f4827cded26e8cfc2a2cc531b365`; its trees (`git rev-parse 03386fd:<dir>`): rtl `031b989be1f25dd20836028c5126a5b1dc562bd7`, lib `f90a9a64ddc67db6642bc6654545f1509744426b`, defines `36f0452de823189873ca8ac79d7a662918961ad6`, sim `0dad5608c126445abb808c5addd7b6e9d4df54c7`, std `05909d5f7dd5d23f80a2d11e127fdb79eb8a5468`.
- Added on top of it: the `Makefile` with the bench targets, `test/bench/bench.mk`, `test/bench/bench.py` and the programs, with their sha256 in [`inputs.sha256`](inputs.sha256). After their license headers, `loop_addi.s`, `loop_mul.s`, `loop_div.s`, `loop_div0.s` and `mcost.c` are byte-identical to the programs of 2026-08-18; `loop_empty.s` is new. Those fingerprints are of the files the run used. Some of them changed afterwards, before they were committed (the `Makefile` gained the `check-results` target and help text, `bench.mk` a header comment): [`rechecked.sha256`](rechecked.sha256) lists the changed files as committed, with which `make check-results` reproduced this record exactly; `sha256sum -c inputs.sha256` reports those files as `FAILED`. Correction (2026-10-01): the `Makefile` line of `inputs.sha256` had been changed to the extended file (sha256 `2cd15d50…834a`); it again names the file the run used.
- Products: [`results.csv`](results.csv) gives, for every program, the marker times or the counter values, the cycles and the cost per operation. The `init.mem` images and the `mcost.c` ELF are fingerprinted in [`meta.json`](meta.json); the assembled ELFs are not, because the assembler records a temporary file name in them.

## Environment

- Date: 2026-10-01
- Host: Intel Core Ultra 7 165H, 22 threads, Linux
- Tools: Verilator 5.042 2025-11-02 rev v5.042; riscv32-unknown-elf-gcc () 12.2.0 with GNU Binutils 2.39; Python 3.12.3; GNU Make 4.3
- Workers: 1. Wall time of `make bench-mcost` with the simulator already built: 0.36 s (programs built and run), 0.14 s when only run.

## Output

`make bench-mcost`, the summary printed after the build commands (verbatim):

```
M-unit cycle costs (test/bench/mcost)

  800-op loops: 100 iterations of 8 back-to-back instructions, timed between two
  test-peripheral markers (20 time units per cycle)
  program     loop body           cycles   per op  per op, loop overhead subtracted
  loop_empty  (empty body)           399    0.499  -
  loop_addi   addi s1, t5, 0        1199    1.499  1.00
  loop_mul    mul  s1, t5, t6       1999    2.499  2.00
  loop_div    div  s1, t5, t6      27599   34.499  34.00
  loop_div0   div  s1, t5, zero     1199    1.499  1.00
  loop overhead (loop_empty): 399 cycles, 0.499 per op

  mcost.c (rv32im -O2): 64 iterations of 8 identical instructions (512), mcycle;
  per op = (cycles - cycles of base-add) / 512 + 1, the 1 being the ADD measured above
  base-add        770     1.00
  mul            1282     2.00
  mulh           1282     2.00
  mulhsu         1282     2.00
  mulhu          1282     2.00
  div           17666    34.00
  divu          17666    34.00
  rem           17666    34.00
  remu          17666    34.00
  div-by-0        770     1.00
  remu-by-0       770     1.00
  div-ovf         770     1.00

  docs/EXTENSIONS.md "Measured" column   documented  800-op loops  mcost.c
  any RV32I ALU op                             1.00          1.00  (reference)
  mul / mulh / mulhsu / mulhu                  2.00          2.00  2.00 2.00 2.00 2.00
  div / divu / rem / remu                     34.00         34.00  34.00 34.00 34.00 34.00
  div / rem by zero, or -2^31 / -1             1.00          1.00  1.00 1.00 1.00

BENCH MCOST: PASS
```

The run logs are in [`logs/`](logs) (colour codes removed).

## Caveats

- The loops use t5 = 1,000,003 and t6 = 7, `mcost.c` uses 0xDEADBEEF and 13. The divider takes the same 34 cycles for any operands except the early-out cases.
- `rem` by zero is not measured on its own (`div` and `remu` by zero are), and `-2³¹ / -1` only for `div`.
- `loop_empty.s` was added on 2026-10-01. The measurement of 2026-08-18 subtracted the overhead that the ALU loop implies if an ALU operation costs one cycle, 0.499 per operation; the empty loop measures it directly, and it is the same 399 cycles.
- `mcost.c` runs longer than the simulator's default limit of 100,000 cycles; `make bench-mcost` gives every run a limit of 5,000,000.
- The programs, built from the same sources, give the same counts on a simulator built from c00c4db: see [the first measurement](../2026-08-18_c00c4db/RECORD.md).
