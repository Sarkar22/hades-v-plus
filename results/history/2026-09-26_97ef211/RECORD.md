# A tick-synchronised FreeRTOS demo passed more than 5,000 ticks on a defective core

**Status: historical, and not verifiable.** No log or program of that run was kept; the
statement rests on the development log alone.

## Figure and where it is quoted

| Figure as quoted | Quoted at |
|---|---|
| "during development a tick-synchronised demo ran more than 5,000 ticks on a core that still had three such defects" | docs/VERIFICATION.md:123 (first in README.md of commit 62b0407) |

## What is known

- The development log of 2026-09-26 (the research that first booted FreeRTOS on the core)
  states: "An earlier tick-synchronised version of the app passed 5,005 ticks on the buggy DUT",
  and "A naive tick-synchronised demo PASSED 5,005 ticks on the buggy RTL, so a plain 'FreeRTOS
  boots' demo proves nothing."
- The same night an independent check of that research marked this one claim *unverifiable*:
  no log or program file of such a run could be found (only cycle numbers containing 5005).
- "Buggy" is the RTL of commit 97ef211. The randomised successor of that program failed on it,
  while the golden CPU passed the identical program (17,515 ticks); with a three-change patch of
  the Writeback stage it passed as well. That patch, kept outside the repository, is the origin of
  fixes A (exception against a same-cycle interrupt), B (`MPIE <= MIE`) and C (the in-flight CSR
  operation) of commit 0d25ee6: these are the "three such defects".
- According to commit 0d25ee6 all six defects were present at 97ef211; at the time of the demo,
  three were known.

## Environment

- Date: 2026-09-26 (evening, local time).
- Host: Intel Core Ultra 7 165H, 22 threads, Linux.
- Tools: Verilator 5.042, `riscv32-unknown-elf-gcc` 12.2.0, FreeRTOS-Kernel V11.1.0+.

## Caveats

- The figure cannot be re-run: the tick-synchronised program was not kept.
- The point the documentation makes, that a demo that merely boots proves little, is
  independently supported by the randomised programs and the campaigns
  (docs/VERIFICATION.md, *FreeRTOS Differential Campaigns*).
