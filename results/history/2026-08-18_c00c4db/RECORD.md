# M: twenty flushes of the div.s interrupt sweep land on an unfinished divide

**Status: historical.** Measured once with temporary instrumentation of the RTL, which was
removed again; no test of the repository prints this count.

## Figure and where it is quoted

| Figure as quoted | Quoted at | Source |
|---|---|---|
| div.s: "an external interrupt swept across the 34-cycle window — 20 of the sweep's flushes land on an unfinished divide" | docs/EXTENSIONS.md:72 | development log of 2026-08-18 |

## What the development log of 2026-08-18 records

A review of the M extension, before commit c00c4db, asked whether the interrupt sweep of
`test/asm/div.s` really flushes a divide in progress. The answer recorded: "It genuinely lands
mid-divide. I instrumented execute_stage temporarily to count flushes by FSM state: 20 of the
sweep's flushes land on an UNFINISHED M op. Zero land on a finished-but-unretired one — that case
is not reachable deterministically from software here, which is exactly why test_m_execute sweep 10
drives it directly at the unit level."

At 03386fd, `make test/asm/div` passes (229 `Test pass!` lines) and `test_m_execute` covers the
flush cases at the unit level (`=== 9: JUMP mid-divide — abandon, no hang ===`, `=== 10: JUMP
arriving on the exact cycle the divide finishes ===`): see `results/tests/2026-10-01_03386fd/`.

## Related figures of the same commit (not in the documentation)

The message of c00c4db also states: "899k+ checks against two independently derived Python
models, 17747 stall-protocol checks injecting JUMP and Memory-STALL at every offset inside a
divide, and 6000 randomised sequences. Seven injected mutations were all killed". These were
development checks and are not re-run by any command of the repository; the formal proof
(`results/formal/2026-09-28_588d76a/`) now covers the arithmetic and the stall protocol of the
unit.

## Environment

- Date: 2026-08-18.
- Host: Intel Core Ultra 7 165H, 22 threads, Linux.
- Tools: Verilator 5.042, `riscv32-unknown-elf-gcc` 12.2.0.

## Caveats

- The count depends on the exact timing of `div.s` and of the pipeline; it was not re-measured
  after later RTL changes (the trap and interrupt fixes of 0d25ee6 changed Writeback).
