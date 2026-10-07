# Formal proofs of the M and EXT units: the runs of record (2026-10-02)

The runs of record of `make formal`, `make formal-full` and `make formal-ext` on the
`rtl/execute_stage.sv` of commit c1a7c85 (SHA-256
`c36613c8fe0116aad83c66ea4a79dd4d03995c95290eb8a3d9c33eee6d3ae969`), the first file with the
unit of Zbb, Zbs and Zicond, documented in
[formal/README.md, section 4](../../../formal/README.md#4-results-and-runtimes). They cover two
proofs: the k-induction proof that MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM and REMU produce the
RISC-V result for all operand pairs, and the proof that each of the 28 Zbb, Zbs and Zicond
instructions forwards and hands Memory the result of the ratified specifications for all operand
values, without making Execute stall or jump. The record also holds the re-run of the M proof's
flow as committed in c1a7c85, unchanged, on the same file.

**Status: needs formal tools.** The runs are repeatable with `make formal` (about 1.5 minutes),
`make formal-full` (about 25 minutes) and `make formal-ext` (under a minute) once the tools of
formal/README.md are installed (SymbiYosys/Yosys, sv2v, bitwuzla, Yices, z3).
`sh results/check.sh formal` runs `make formal` and compares the three summary lines of the
default run below.

## The runs

Made on 2026-10-02: the runs of the flow of c1a7c85 between 13:17 and 14:22 local time, those of
the flow of this record between 15:25 and 15:56. `rtl/` and `defines/` are those of
c1a7c85. The flow of this record is the `formal/` directory of c1a7c85 extended by the EXT proof
(the files listed in `inputs.sha256`) and the target `formal-ext` of the Makefile; it was not yet
committed when the runs were made, so the record is filed under c1a7c85, the commit it is based
on. The runs labelled *flow of c1a7c85* used the `formal/` directory of c1a7c85 unchanged: the
default run in the work tree before the flow was changed, the full run in a clean export of
c1a7c85 (`git archive c1a7c85`). `HADES_FORMAL_ENV` pointed at the tool environment. Verbatim
ends of the output:

```text
$ make formal-full                      # flow of this record
...
required checks: 106, not PASS: none
negative controls: 21, not FAIL (as required): none
second-solver runs not PASS (reported only, each also proven by the required engine): fmul_ops_mulh_f3_bwn:TIMEOUT(300s) fmul_ops_mulhsu_f3_bwn:TIMEOUT(300s) iface_a1_mulh_bwn:TIMEOUT(600s) iface_a1_mulhsu_bwn:TIMEOUT(600s)
mutants: 18 rejected, 1 survived (diff32 is a proven-equivalent mutant, see README); unexpected survivors: none
EXT mutants: 17 rejected, 0 survived
FORMAL RESULT: PASS (mode=full)
elapsed 1577.96 s

$ make formal                           # flow of this record
...
required checks: 104, not PASS: none
negative controls: 21, not FAIL (as required): none
FORMAL RESULT: PASS (mode=default)
elapsed 99.78 s

$ make formal-ext                       # flow of this record
...
required checks: 34, not PASS: none
negative controls: 17, not FAIL (as required): none
FORMAL RESULT: PASS (mode=ext)
elapsed 26.55 s

$ make formal-full                      # flow of c1a7c85, clean export
...
required checks: 74, not PASS: none
negative controls: 4, not FAIL (as required): none
second-solver runs not PASS (reported only, each also proven by the required engine): fmul_ops_mulh_f3_bwn:TIMEOUT(300s) fmul_ops_mulhsu_f3_bwn:TIMEOUT(300s) iface_a1_mulhsu_bwn:TIMEOUT(600s) iface_a1_mulh_bwn:TIMEOUT(600s) 
mutants: 18 rejected, 1 survived (diff32 is a proven-equivalent mutant, see README); unexpected survivors: none
FORMAL RESULT: PASS (mode=full)
elapsed 1447.60 s

$ make formal                           # flow of c1a7c85
...
required checks: 72, not PASS: none
negative controls: 4, not FAIL (as required): none
FORMAL RESULT: PASS (mode=default)
real	1m10.203s
```

The runs were timed with `/usr/bin/time -f 'elapsed %e s'`, the default run of the flow of
c1a7c85 with the shell's `time`. The summaries as printed, with every check's verdict and wall
time, are in `logs/`; `results.csv` has one row per run.

## The EXT unit in the run of record

From the full run's summary (`logs/full.SUMMARY.txt`); wall times per task, `--par 4`:

| Check | Engine | Result | Wall |
|---|---|---|---|
| `ext_spec_check_python`: `props/ext_spec.vh` against the Python model | Verilator | `ext spec cross-check: 1042224 vectors (42224 corner/shift, 1000000 random), 0 mismatches` | 3.3 s |
| `ext_payload_map`: the harness's map against `defines/op.sv` | Python | PASS (28 entries, 23 `op::ext_t` constants) | < 0.1 s |
| X1 + X2, `res_<insn>_yn`, 28 instructions, depth 3 | yices | 28 of 28 PASS | 1.3-3.9 s each; rol, ror, rori 12.4-13.7 s |
| the same, `res_<insn>_bwn` (second solver) | bitwuzla | 28 of 28 PASS (reported only) | 1.4-3.6 s each |
| X3, `nostall_yn` | yices | PASS | 1.1 s |
| `ext_cover_bw`, depth 4 | bitwuzla | 28 of 28 cover statements reached | 1.7 s |
| 17 negative controls, each mutant against its target property | yices | 17 of 17 FAIL, as required | 1.1-1.6 s each |
| sv2v fidelity, `test_ext_execute` | Verilator | identical output (14 lines), `All 927129 EXT-unit checks passed` | (part of `sv2v_fidelity`) |

EXT mutation campaign (17 mutants × the 29 required property tasks, 300 s per task), as
printed:

```text
EXT mutant results (source: runs/times.txt; non-PASS tasks listed)
ext_andn_and         REJECTED  (29 tasks) non-PASS: res_andn_yn:FAIL
ext_lzc_zero31       REJECTED  (29 tasks) non-PASS: res_clz_yn:FAIL res_ctz_yn:FAIL
ext_ctz_no_reverse   REJECTED  (29 tasks) non-PASS: res_ctz_yn:FAIL
ext_pop_pair         REJECTED  (29 tasks) non-PASS: res_cpop_yn:FAIL
ext_minmax_sign      REJECTED  (29 tasks) non-PASS: res_max_yn:FAIL res_maxu_yn:FAIL res_min_yn:FAIL res_minu_yn:FAIL
ext_sexth_zero       REJECTED  (29 tasks) non-PASS: res_sext_h_yn:FAIL
ext_rol_as_ror       REJECTED  (29 tasks) non-PASS: res_rol_yn:FAIL
ext_orcb_and         REJECTED  (29 tasks) non-PASS: res_orc_b_yn:FAIL
ext_rev8_middle      REJECTED  (29 tasks) non-PASS: res_rev8_yn:FAIL
ext_bext_bit1        REJECTED  (29 tasks) non-PASS: res_bext_yn:FAIL res_bexti_yn:FAIL
ext_bseti_rs2        REJECTED  (29 tasks) non-PASS: res_bclri_yn:FAIL res_binvi_yn:FAIL res_bseti_yn:FAIL
ext_czero_rs1        REJECTED  (29 tasks) non-PASS: res_czero_eqz_yn:FAIL res_czero_nez_yn:FAIL
ext_stall_dead       REJECTED  (29 tasks) non-PASS: nostall_yn:FAIL
ext_reg_flip         REJECTED  (29 tasks) non-PASS: res_andn_yn:FAIL res_orn_yn:FAIL res_xnor_yn:FAIL res_clz_yn:FAIL res_ctz_yn:FAIL res_max_yn:FAIL res_maxu_yn:FAIL res_min_yn:FAIL res_minu_yn:FAIL res_sext_b_yn:FAIL res_cpop_yn:FAIL res_sext_h_yn:FAIL res_zext_h_yn:FAIL res_orc_b_yn:FAIL res_rev8_yn:FAIL res_bclr_yn:FAIL res_bclri_yn:FAIL res_rori_yn:FAIL res_bext_yn:FAIL res_rol_yn:FAIL res_ror_yn:FAIL res_bexti_yn:FAIL res_binv_yn:FAIL res_binvi_yn:FAIL res_bset_yn:FAIL res_bseti_yn:FAIL res_czero_eqz_yn:FAIL res_czero_nez_yn:FAIL
ext_reg_bubble       REJECTED  (29 tasks) non-PASS: res_andn_yn:FAIL res_orn_yn:FAIL res_xnor_yn:FAIL res_clz_yn:FAIL res_ctz_yn:FAIL res_max_yn:FAIL res_maxu_yn:FAIL res_min_yn:FAIL res_sext_b_yn:FAIL res_minu_yn:FAIL res_cpop_yn:FAIL res_sext_h_yn:FAIL res_zext_h_yn:FAIL res_orc_b_yn:FAIL res_rev8_yn:FAIL res_bclr_yn:FAIL res_bclri_yn:FAIL res_rol_yn:FAIL res_bext_yn:FAIL res_ror_yn:FAIL res_rori_yn:FAIL res_bexti_yn:FAIL res_binv_yn:FAIL res_bset_yn:FAIL res_binvi_yn:FAIL res_bseti_yn:FAIL res_czero_nez_yn:FAIL res_czero_eqz_yn:FAIL
ext_fwd_invalid      REJECTED  (29 tasks) non-PASS: res_andn_yn:FAIL res_orn_yn:FAIL res_xnor_yn:FAIL res_clz_yn:FAIL res_ctz_yn:FAIL res_cpop_yn:FAIL res_max_yn:FAIL res_maxu_yn:FAIL res_min_yn:FAIL res_minu_yn:FAIL res_sext_b_yn:FAIL res_sext_h_yn:FAIL res_zext_h_yn:FAIL res_rol_yn:FAIL res_ror_yn:FAIL res_rori_yn:FAIL res_orc_b_yn:FAIL res_rev8_yn:FAIL res_bclr_yn:FAIL res_bclri_yn:FAIL res_bext_yn:FAIL res_bexti_yn:FAIL res_binv_yn:FAIL res_binvi_yn:FAIL res_bset_yn:FAIL res_bseti_yn:FAIL res_czero_eqz_yn:FAIL res_czero_nez_yn:FAIL
ext_fwd_addr_rs1     REJECTED  (29 tasks) non-PASS: res_andn_yn:FAIL res_orn_yn:FAIL res_xnor_yn:FAIL res_clz_yn:FAIL res_ctz_yn:FAIL res_max_yn:FAIL res_cpop_yn:FAIL res_maxu_yn:FAIL res_minu_yn:FAIL res_min_yn:FAIL res_sext_b_yn:FAIL res_sext_h_yn:FAIL res_zext_h_yn:FAIL res_rol_yn:FAIL res_ror_yn:FAIL res_rori_yn:FAIL res_orc_b_yn:FAIL res_rev8_yn:FAIL res_bclr_yn:FAIL res_bclri_yn:FAIL res_bext_yn:FAIL res_bexti_yn:FAIL res_binv_yn:FAIL res_binvi_yn:FAIL res_bset_yn:FAIL res_bseti_yn:FAIL res_czero_eqz_yn:FAIL res_czero_nez_yn:FAIL
```

## Figures and where they are quoted

| Figure as quoted | Quoted at | This record |
|---|---|---|
| `FORMAL RESULT: PASS (mode=default)`: 104 required checks and 21 negative controls | README.md (Verification in Depth); docs/VERIFICATION.md (Verification at a Glance, System Level, Formal Verification) | the default run above |
| `FORMAL RESULT: PASS (mode=full)`: 106 required checks, 21 negative controls, 48 second-solver runs, 1,101 mutant runs; `mode=ext`: 34 required checks, 17 negative controls; the run times | formal/README.md (introduction, section 4); docs/VERIFICATION.md (Formal Verification) | the full and ext runs above (1,101 = 19 × 32 + 17 × 29) |
| the M flow of c1a7c85 on the new file: 74 and 72 required checks, the same verdicts as on 2026-09-28 | formal/README.md (section 4, section 9); docs/VERIFICATION.md (Formal Verification) | the last two runs above; their mutant table is `logs/full-flow-c1a7c85.SUMMARY.txt` |
| the proved file `c36613c8…3ae969`, that of c1a7c85 | formal/README.md (introduction, section 4); docs/VERIFICATION.md (Verification at a Glance, System Level, Formal Verification) | `git show c1a7c85:rtl/execute_stage.sv \| sha256sum`; the first line of each summary |
| the EXT proof: X1-X3 for 28 instructions, 1,042,224 specification vectors, 28 covers, 17 mutants each rejected by exactly the proofs of the instructions it breaks | README.md; docs/VERIFICATION.md (Approach, Formal Verification, Mutation Testing); docs/EXTENSIONS.md (Zbb and Zbs, Verification); formal/README.md (sections 1, 3, 4) | the EXT tables above |

## Commands

From a clean clone at the repository root, with the tools installed as in formal/README.md:

```bash
export HADES_FORMAL_ENV=<file that puts the tools on PATH>   # if they are not on PATH already
make formal         # default mode
make formal-full    # full mode
make formal-ext     # the EXT unit only
```

The re-run of the flow of c1a7c85 is the same `make formal` and `make formal-full` in a checkout
of c1a7c85.

## Inputs

`inputs.sha256` lists the SHA-256 of every input that the runs read: `rtl/execute_stage.sv`, the
eight `defines/` packages that `gen.sh` translates, every file of the flow of this record (all of
`formal/` except its README) and the four benches of the sv2v fidelity check with
`test/sv/files.txt`. At c1a7c85 (`git rev-parse c1a7c85:<path>`):

| Path | c1a7c85 |
|---|---|
| `rtl/execute_stage.sv` (blob) | `16f95c827fc48ce6eed0878a662f4b671ba7fcde` |
| `defines` | `a3a2c852ab9da325f42809aceaaa028b903d6dcd` |
| `formal` (the flow of the re-run of c1a7c85) | `672701adb7b11aa57a2d54d1939d305677ef7706` |
| `test/sv/test_m_execute.sv`, `test_execute_compare.sv`, `test_execute_bpred_nextpc.sv`, `test_ext_execute.sv` | `e554dd0f…`, `58412f2d…`, `d61060e6…`, `1a550410…` |
| `test/sv/files.txt` | `8b137891791fe96927ad78e64b0aad7bded08bdc` |
| `ref` | `b1cd1eebbcd4c675f36085ebfc96416192423721` |

## Environment

- Date: 2026-10-02.
- Host: Intel Core Ultra 7 165H, 22 threads, Linux.
- Tools (formal/README.md, *Tools*), installed that day in a persistent directory: YoWASP Yosys
  0.69 (`yowasp-yosys 0.69.0.0.post1233`, runtime 1.96) with SBY and yosys-smtbmc and z3 from
  the `z3-solver` wheel (`5.1.0.0`, reports 5.1.0), both in a Python 3.12 virtual environment
  because that Python refuses `pip install --user` (PEP 668); bitwuzla 0.9.1
  (`Bitwuzla-Linux-x86_64-static.zip`), Yices 2.7.0
  (`yices-2.7.0-x86_64-pc-linux-gnu-static-gmp.tar.gz`) and sv2v 0.0.13 (`sv2v-Linux.zip`), the
  release binaries; Verilator 5.042.
- Workers: `--par 4` (the Makefile default `FORMAL_PAR=4`). The runs of the two flows did not
  overlap, except that `make formal-ext` was first tried while the clean-export full run was in
  progress; the `make formal-ext` above was run alone.

## Caveats

- A first `make formal-full` of the flow of c1a7c85, started in the work tree, is not counted:
  `formal/run.sh` was edited while it ran, which a running bash script does not tolerate, and it
  stopped with status 2 in step 10. The full run of that flow above was made afterwards in a clean
  export of c1a7c85.
- The runs of the flow of this record were made with the EXT proof at depth 3 and 17 EXT
  mutants, the flow that `inputs.sha256` fingerprints, with one exception: the usage comment
  at the top of `formal/run.sh` was corrected afterwards (13 → 17 negative controls and EXT
  mutants); no executed line changed.
- Wall times depend on the host and its load and are never compared.
- What is and is not proven is stated in formal/README.md, section 5; for the EXT unit, item 9:
  the decoder's map from instruction word to payload, payloads the decoder never builds (covered
  by X3 only), and everything downstream of Execute are outside the proof.

**Update, 2026-10-02 (Zbkb, Zbkx and Zknh).** The cryptography half of the EXT unit changes the input of this proof: `rtl/execute_stage.sv` gains Part 2d and `defines/op.sv` a sixth bit of the sub-operation, and the flow was extended to the 45 instructions (121 required checks in the default run instead of 104). Those runs are recorded in [formal/2026-10-02_bd800d8](../2026-10-02_bd800d8/RECORD.md), which `sh results/check.sh formal` now compares with: of two records of the same day it takes the one whose commit came later. This record remains the run of record for the file `c36613c8…3ae969`; its figures are quoted as those of the earlier run.
