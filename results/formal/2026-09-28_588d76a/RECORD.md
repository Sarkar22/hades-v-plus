# Formal proof of the M unit: the run of record (2026-09-28)

The run of record of `make formal-full` and `make formal`, documented in
[formal/README.md, section 4](../../../formal/README.md#4-results-and-runtimes): the k-induction
proof that MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM and REMU of `rtl/execute_stage.sv` produce the
RISC-V result for all operand pairs, with its lemma checks, covers, negative controls, sv2v
fidelity check and mutation campaign.

**Status: needs formal tools.** The proof is repeatable with `make formal` (about a minute) and
`make formal-full` (about 25 minutes) once the tools of formal/README.md are installed
(SymbiYosys/Yosys, sv2v, bitwuzla, Yices, z3). On the machine used on 2026-10-01 Yosys,
SymbiYosys, yosys-smtbmc, bitwuzla, Yices and z3 were not installed and none of the tools was on
`PATH` (only an sv2v binary was present), so the run was not repeated for this record; without
the tools `run.sh` stops with `FORMAL RESULT: FAIL (missing tools)` and exit status 2, as
documented (formal/README.md:373-374).

## The run of record

Made on 2026-09-28 (about 10:49 to 11:15 local time) on the tree that was committed the same day
as 588d76a, with `HADES_FORMAL_ENV` pointing at the tool environment and a relocated build
directory. Verbatim end of the output, from the development log of 2026-09-28:

```text
$ make formal-full
...
required checks: 74, not PASS: none
negative controls: 4, not FAIL (as required): none
second-solver runs not PASS (reported only, each also proven by the required engine): fmul_ops_mulh_f3_bwn:TIMEOUT(300s) fmul_ops_mulhsu_f3_bwn:TIMEOUT(300s) iface_a1_mulh_bwn:TIMEOUT(600s) iface_a1_mulhsu_bwn:TIMEOUT(600s)
mutants: 18 rejected, 1 survived (diff32 is a proven-equivalent mutant, see README); unexpected survivors: none
FORMAL RESULT: PASS (mode=full)

real	24m33.189s

$ make formal
...
required checks: 72, not PASS: none
negative controls: 4, not FAIL (as required): none
FORMAL RESULT: PASS (mode=default)

real	1m6.813s
```

An earlier full run of the same day reported the same summary after `real 144m11.982s`. A run
without the tools on `PATH`, made the same day, exited with status 2 after printing
`MISSING: sby/yowasp-sby yosys/yowasp-yosys yosys-smtbmc bitwuzla yices-smt2 z3 sv2v  -- see formal/README.md (Tools); nothing was run`.

## Figures and where they are quoted

| Figure as quoted | Quoted at | This record |
|---|---|---|
| `FORMAL RESULT: PASS (mode=default)`: 72 required checks and 4 negative controls | docs/VERIFICATION.md:82; README.md:94 | the default run above |
| `FORMAL RESULT: PASS (mode=full)` after 24 min 33 s: 74 required checks, 4 negative controls, 20 second-solver runs, 608 mutant runs; default mode after 1 min 07 s | formal/README.md:198-207 | the full and default runs above (608 = 19 mutants × 32 proofs) |
| "the SHA-256 of the proved `rtl/execute_stage.sv` recorded there is that of the file in this version of the repository"; `847dc018…fab1bb` | docs/VERIFICATION.md:84; README.md:81; formal/README.md:209 | `sha256sum rtl/execute_stage.sv` at 03386fd: `847dc0189ecc3bd61ad4d9d66ea414165fc16c9daa16e392f91e3b3f36fab1bb` (the same at 0d25ee6, 588d76a and cbae9b9) |
| developed against `97ef211`, SHA-256 `50bed4cf…5111` | formal/README.md:464-465 | `git show 97ef211:rtl/execute_stage.sv \| sha256sum`: `50bed4cf0a13fec392dc0ced2cddc3d6a720f4f63e27df5962ca9b801a7f5111` |
| 19 seeded bugs, 18 rejected; `diff32` equivalent; 19 mutants against 32 proofs | docs/VERIFICATION.md:218-219,236; formal/README.md:180-189,254-267 | `mutants: 18 rejected, 1 survived (diff32 ...)` |
| about 1-2 min / about 25-35 min; "a few minutes" / "about 35 minutes" | docs/VERIFICATION.md:188-189; formal/README.md:11-12; Makefile help text | 1 min 7 s and 24 min 33 s in the run of record |
| all 2^64 operand pairs, every reachable state, stall at most 33 consecutive cycles | docs/VERIFICATION.md:24,176-182; formal/README.md:6-8,58,284-285 | the proof statements of formal/README.md section 1; not re-checked here |
| per-check results and wall times (CTRL, DIVF, MULREG, FINAL, A1, A3a, lemmas, covers, spec check of 1,002,592 vectors, fidelity 24/53/8 lines, mutants) | formal/README.md:215-265 | the tables of formal/README.md section 4 are this run's `SUMMARY.txt`; not re-checked here |
| 22 hardware threads, `--par 4` | formal/README.md:209-211 | the same host as the other records of 2026-10-01: Intel Core Ultra 7 165H, 22 threads |

Historical figures in formal/README.md that no command re-runs (it says so itself, line 501):
bitwuzla 961 s at 16 bits and more than 1 h at 20 bits, H6 in 971 s at 32 bits (lines 474-475);
the audits' 15 and 21 mutants (line 482); the exact latencies of the separate compositional proof
and 10^9 cycles of co-simulation (lines 496-499); the first 15 mutants checked by the development
campaign (lines 320-321).

## Commands

From a clean clone at the repository root, with the tools installed as in formal/README.md:

```bash
export HADES_FORMAL_ENV=<file that puts the tools on PATH>   # if they are not on PATH already
make formal         # default mode
make formal-full    # full mode
```

## Inputs

The run of record was made on the tree committed as 588d76a. Every input of the proof is
identical at 588d76a and 03386fd (`git rev-parse <commit>:<path>`):

| Path | 588d76a = 03386fd |
|---|---|
| `formal` | `5a241ad565400c8327054e67f2369d96d08fb73a` |
| `rtl/execute_stage.sv` (blob) | `5e05a633f7a62a8d80da37c71d6a5cdfae44aa7d` |
| `defines` | `36f0452de823189873ca8ac79d7a662918961ad6` |
| `test/sv/test_m_execute.sv`, `test_execute_compare.sv`, `test_execute_bpred_nextpc.sv` (sv2v fidelity benches) | `e554dd0f…`, `58412f2d…`, `d61060e6…` |
| `test/sv/files.txt` | `8b137891791fe96927ad78e64b0aad7bded08bdc` |
| `ref` | `b1cd1eebbcd4c675f36085ebfc96416192423721` |

## Environment of the run of record

- Date: 2026-09-28.
- Host: Intel Core Ultra 7 165H, 22 threads, Linux.
- Tools (formal/README.md, *Tools*): YoWASP Yosys 0.69 with SBY and yosys-smtbmc, bitwuzla
  0.9.1, Yices 2.7.0, z3 from the `z3-solver` wheel (reports 5.1.0), sv2v 0.0.13, Verilator
  5.042, Python 3.
- Workers: `--par 4` (the Makefile default `FORMAL_PAR=4`).

## Caveats

- Not repeated on 2026-10-01 (tools absent). Everything above is the recorded run.
- The RTL that the proof covers has not changed since (same `rtl/execute_stage.sv` and `defines`),
  so the recorded run applies to 03386fd as it stands.
- What is and is not proven is stated in formal/README.md, section 5.
