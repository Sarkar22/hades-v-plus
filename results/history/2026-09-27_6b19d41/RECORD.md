# The six trap and interrupt fixes: how they were found, and the single-fix reverts

**Status: historical.** The reverts were made by hand in a copy of the integrated tree before
the fixes were committed; the reverted trees were not kept, so the table cannot be re-run as it
stands. (Each revert could be reconstructed from the diff of commit 0d25ee6.)

## Figures and where they are quoted

| Figure as quoted | Quoted at | Source |
|---|---|---|
| six trap and interrupt defects: four exposed by running FreeRTOS under randomised interrupt timing, two by the interrupt-offset sweep against the independent model | README.md:77; docs/VERIFICATION.md:119,125; test/trapsweep/README.md:165-167 | commit 0d25ee6: "Booting FreeRTOS under desynchronised interrupt load exposed four defects in the trap path; adversarial offset sweeps against an independent ISA model then found two more. All six were present on the previous tip" (the two: E, predicted-branch `next_pc`, and F, stale `mtvec`) |
| each fix has a directed regression test that fails when that fix alone is reverted | README.md:96; docs/VERIFICATION.md:125,235 | commit 0d25ee6: "trapirq (A), trapmpie (B), csrirq (C), memirq (D), bpirq/bpirq2/bpirq3 and test_execute_bpred_nextpc (E), mtvecirq (F)"; the reverts below |
| the revert table: `sweep.py run` DUT ISS-consistent 17/61, 46/61, 9/61, 39/61, 58/61, 29/61, the families flagged and the directed tests that fail | test/trapsweep/README.md:180-191; docs/VERIFICATION.md:235; README.md:96 | development log of 2026-09-27, verbatim below |
| with the predictor-`next_pc` fix reverted, fuzz `bp` 301-360 is 20/60 ISS-consistent | test/trapsweep/README.md:193-194 | development log of 2026-09-27 ("noBP ... fuzz bp 20/60") |
| before the `mtvec` fix, the DUT failed 32/61 programs, every flagged probe one that writes `mtvec` | test/trapsweep/README.md:174-175 | the `live mtvec` revert: 29/61 consistent, i.e. 32 of 61 failed |
| fuzz `mt` 401-430 before the `mtvec` fix: DUT 28/30 | test/trapsweep/README.md:177-178 | development log of 2026-09-27: "pre mt rc=1: DUT: 28/30 programs ISS-consistent  <-- 2 FAILED golden: 30/30 programs ISS-consistent" |
| `writeback_compare` improved from 9 to 7 errors | (baseline now 7: docs/VERIFICATION.md:62,258) | commit 0d25ee6: "Golden baselines: writeback_compare improves from 9 to 7 errors; every other baseline is unchanged" |

## Verbatim results of the reverts

The development log of 2026-09-27 (about 22:27 local time) records, for each fix reverted on
its own in a copy of the integrated tree, the directed tests and the sweep (`noA` … `noMT`
name the reverted fix: A, B, C, D, the predicted-branch `next_pc` fix E, and the live-`mtvec`
fix F):

```text
== noA DONE
   trapirq   Some test(s) failed! (# Errors: 2)
   trapmpie  All tests passed! (# Errors: 1 = initial test)
   csrirq    All tests passed! (# Errors: 1 = initial test)
   memirq    All tests passed! (# Errors: 1 = initial test)
   bpirq     All tests passed! (# Errors: 1 = initial test)
   bpirq2    All tests passed! (# Errors: 1 = initial test)
   bpirq3    Some test(s) failed! (# Errors: 2)
   mtvecirq  All tests passed! (# Errors: 1 = initial test)

DUT: 17/61 programs ISS-consistent  <-- 44 FAILED
== noB DONE
   trapirq   All tests passed! (# Errors: 1 = initial test)
   trapmpie  Some test(s) failed! (# Errors: 5)
   csrirq    All tests passed! (# Errors: 1 = initial test)
   memirq    All tests passed! (# Errors: 1 = initial test)
   bpirq     All tests passed! (# Errors: 1 = initial test)
   bpirq2    All tests passed! (# Errors: 1 = initial test)
   bpirq3    All tests passed! (# Errors: 1 = initial test)
   mtvecirq  All tests passed! (# Errors: 1 = initial test)

DUT: 46/61 programs ISS-consistent  <-- 15 FAILED
== noC DONE
   trapirq   All tests passed! (# Errors: 1 = initial test)
   trapmpie  All tests passed! (# Errors: 1 = initial test)
   csrirq    Some test(s) failed! (# Errors: 2)
   memirq    All tests passed! (# Errors: 1 = initial test)
   bpirq     All tests passed! (# Errors: 1 = initial test)
   bpirq2    All tests passed! (# Errors: 1 = initial test)
   bpirq3    All tests passed! (# Errors: 1 = initial test)
   mtvecirq  Some test(s) failed! (# Errors: 2)

DUT: 9/61 programs ISS-consistent  <-- 52 FAILED
== noD
   trapirq   All tests passed! (# Errors: 1 = initial test)
   trapmpie  All tests passed! (# Errors: 1 = initial test)
   csrirq    All tests passed! (# Errors: 1 = initial test)
   memirq    Some test(s) failed! (# Errors: 2)
   bpirq     All tests passed! (# Errors: 1 = initial test)
   bpirq2    All tests passed! (# Errors: 1 = initial test)
   bpirq3    All tests passed! (# Errors: 1 = initial test)
   mtvecirq  All tests passed! (# Errors: 1 = initial test)
== noBP
   trapirq   All tests passed! (# Errors: 1 = initial test)
   trapmpie  All tests passed! (# Errors: 1 = initial test)
   csrirq    All tests passed! (# Errors: 1 = initial test)
   memirq    All tests passed! (# Errors: 1 = initial test)
   bpirq     Some test(s) failed! (# Errors: 2)
   bpirq2    Some test(s) failed! (# Errors: 2)
   bpirq3    Some test(s) failed! (# Errors: 2)
   mtvecirq  All tests passed! (# Errors: 1 = initial test)
```

```text
== noA: DUT: 17/61 programs ISS-consistent  <-- 44 FAILED  | non-race programs flagged by family: bp:3 bus:3 ctl:3 exc:3 exc_mpie0:3 m:3 nested:3 pairs:16 pre:4 pre_i:3
== noB: DUT: 46/61 programs ISS-consistent  <-- 15 FAILED  | non-race programs flagged by family: exc_mie0:3 exc_mie0mpie0:3 m:3 nested:3 pairs:3
== noC: DUT: 9/61 programs ISS-consistent  <-- 52 FAILED  | non-race programs flagged by family: bp:3 bus:3 csr:5 ctl:3 exc:3 exc_mpie0:3 flow:3 m:3 nested:3 pairs:16 pre:4 pre_i:3
== noD: DUT: 39/61 programs ISS-consistent  <-- 22 FAILED  | non-race programs flagged by family: bus:3 exc:3 exc_mpie0:3 m:3 nested:3 pre:4 pre_i:3
== noBP: DUT: 58/61 programs ISS-consistent  <-- 3 FAILED  | non-race programs flagged by family: bp:3
== noMT: DUT: 29/61 programs ISS-consistent  <-- 32 FAILED  | non-race programs flagged by family: bus:3 csr:3 m:3 pairs:16 pre:4 pre_i:3
== final: DUT: 61/61 programs ISS-consistent
```

The same log's summary adds `noMT: 29/61 / mtvecirq` (the directed test that fails without fix F)
and, for `noBP`, `fuzz bp 20/60`. Every row of test/trapsweep/README.md:186-191 matches these
lines. (The testbench's `# Errors` count includes the deliberate initial-test failure, so
`Errors: 2` is one failed check.)

## Inputs

The integrated tree of that evening, committed the next day as 0d25ee6 (the RTL fixes) and 6b19d41
(FreeRTOS support and `test/trapsweep/`); the fixed RTL is `git rev-parse 0d25ee6:rtl` =
`031b989be1f25dd20836028c5126a5b1dc562bd7`, unchanged since. Each revert undid one of the six
changes listed in the message of 0d25ee6.

## Environment

- Date: 2026-09-27 (late evening, local time).
- Host: Intel Core Ultra 7 165H, 22 threads, Linux.
- Tools: Verilator 5.042, `riscv32-unknown-elf-gcc` 12.2.0, Python 3.12.

## Caveats

- The reverted trees were not kept; the record is the printed output.
- The current sweep result of the fixed tree (61/61) is repeatable:
  [results/trapsweep/2026-10-01_03386fd](../../trapsweep/2026-10-01_03386fd/RECORD.md).
