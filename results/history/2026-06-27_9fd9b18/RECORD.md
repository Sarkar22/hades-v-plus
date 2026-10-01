# RISC-V Community Challenge: full marks, 56/56

**Status: historical.** The assessment was made by the challenge's own grading system, which is
not part of this repository (the upstream test-bench system is closed-source, README.md:120), so
it cannot be re-run here.

## Figure and where it is quoted

| Figure as quoted | Quoted at |
|---|---|
| "This submission scored full marks at every stage — 56/56 across Fetch, Decode, Register File, Instruction Decoder, Execute, Memory and Writeback — earning all three tiers: Bronze, Silver and Gold" | README.md:62; badge README.md:11 |

## What is known

- The development log of 2026-08-17 records the result of the grader's final run, on
  2026-06-27, on the commit that added the baseline bitstream (then `6baec2c`, now 9fd9b18 after
  the history was rewritten), verbatim:

  ```text
  Final persephone run (27.06.2026) scored commit `6baec2c` at full marks on every module (Fetch 8/8, Decode 4/4, RegFile 4/4, InstrDecoder 4/4, Execute 10/10, Memory 10/10, Writeback 16/16).
  ```

  (persephone is the challenge's grading system.) The module scores sum to 56. The challenge
  deadline was 2026-07-02.
- The public evidence is the three Credly badges linked from README.md:11 and :62.

## Environment

- Date of the grading run: 2026-06-27.
- Host and tools: those of the challenge's grading system; not recorded.

## Caveats

- The per-module breakdown comes from the development log, not from a document of the grader
  kept in the repository.
- The grade applies to the base core of that commit, before any of the extensions and fixes
  added afterwards.
- Correction (2026-10-01): the line of the development log is now quoted verbatim; it was
  first paraphrased.
