# Zba: the mutation counts of commit 1f501f5

**Status: historical.** The mutants were temporary edits of the RTL, made and reverted by hand;
they were not kept.

## Figures and where they are quoted

| Figure | Quoted at | Source |
|---|---|---|
| "Test sensitivity was proven by mutation - operand swap 38 errors, sign-preserving shift 10 errors, wrong shift amount 15 errors." | message of commit 1f501f5 (not in the current documentation) | development log of 2026-08-18 |
| "Test suites are additionally validated by **mutation testing**: faults are deliberately injected into the RTL to confirm the tests actually fail" | docs/VERIFICATION.md:26 (general statement; the evidence it lists, docs/VERIFICATION.md:231-236, is the trap-fix reverts and the formal mutation campaign, not these) | — |

## What the development log of 2026-08-18 records

Shortly after midnight (local time) on 2026-08-18, before the Zba commit, each mutant was applied
to `rtl/execute_stage.sv` (or the decoder) of the Zba tree and `make test/asm/zba` was run:

| Mutant | Output of `make test/asm/zba` |
|---|---|
| operand swap (the two source operands exchanged) | `Some test(s) failed! (# Errors: 38)` |
| sign-preserving shift (`{alu_in1[31], alu_in1[29:0], 1'b0} + alu_in2` for SH1ADD, likewise SH2ADD and SH3ADD) | `Some test(s) failed! (# Errors: 10)` |
| wrong shift amount (SH2ADD shifting by 1 instead of 2) | `Some test(s) failed! (# Errors: 15)` |
| Zba arms removed from the decoder | `Some test(s) failed! (# Errors: 2)` |
| forwarding suppressed in the Memory stage | `Some test(s) failed! (# Errors: 2)` |

The unmutated tree printed `All tests passed! (# Errors: 1 = initial test)`. The testbench's
`# Errors` count includes the deliberate initial-test failure, so `Errors: 38` is 37 failed
checks.

## Environment

- Date: 2026-08-18 (shortly after midnight, local time).
- Host: Intel Core Ultra 7 165H, 22 threads, Linux.
- Tools: Verilator 5.042, `riscv32-unknown-elf-gcc` 12.2.0.

## Caveats

- The mutants were not kept and are described here only as far as the log describes them; the
  last two are not in the commit message.
- `test/asm/zba.s` is unchanged since 1f501f5; at 03386fd it passes with 61 `Test pass!` lines
  (`results/tests/2026-10-01_03386fd/`). The mutants have not been re-run on it.
