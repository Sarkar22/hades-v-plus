# Formal proofs of the M and EXT units with Zbkb, Zbkx and Zknh: the runs of record (2026-10-02)

The runs of record of `make formal`, `make formal-full` and `make formal-ext` on the
`rtl/execute_stage.sv` with the cryptography half of the EXT unit (SHA-256
`52201629b7dff698b0d98c98667b8ed80c9c9029d6f9d0d0fa64ed49fc2bfa5d`), documented in
[formal/README.md, section 4](../../../formal/README.md#4-results-and-runtimes). They cover two
proofs: the k-induction proof that MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM and REMU produce the
RISC-V result for all operand pairs, and the proof that each of the 45 Zbb, Zbs, Zicond, Zbkb,
Zbkx and Zknh instructions forwards and hands Memory the result of the ratified specifications
for all operand values, without making Execute stall or jump.

**Status: needs formal tools.** The runs are repeatable with `make formal` (about 2.5 minutes),
`make formal-full` (about 45 minutes) and `make formal-ext` (about a minute) once the tools of
formal/README.md are installed (SymbiYosys/Yosys, sv2v, bitwuzla, Yices, z3).
`sh results/check.sh formal` runs `make formal` and compares the three summary lines of the
default run below.

## The runs

Made on 2026-10-02 between 19:00 and 19:50 local time, in the work tree of bd800d8 with Zbkb,
Zbkx and Zknh added: `rtl/execute_stage.sv`, `defines/op.sv`, `test/sv/test_ext_execute.sv` and
`formal/` changed, not yet committed (the files listed in `inputs.sha256`). The record is filed
under bd800d8, the commit the work is based on. `HADES_FORMAL_ENV` pointed at the tool
environment. Verbatim ends of the output:

```text
$ make formal-ext
...
required checks: 51, not PASS: none
negative controls: 37, not FAIL (as required): none
FORMAL RESULT: PASS (mode=ext)
real	0m57.129s

$ make formal
...
required checks: 121, not PASS: none
negative controls: 41, not FAIL (as required): none
FORMAL RESULT: PASS (mode=default)
real	2m21.969s

$ make formal-full
...
required checks: 123, not PASS: none
negative controls: 41, not FAIL (as required): none
second-solver runs not PASS (reported only, each also proven by the required engine): fmul_ops_mulh_f3_bwn:TIMEOUT(300s) fmul_ops_mulhsu_f3_bwn:TIMEOUT(300s) iface_a1_mulhsu_bwn:TIMEOUT(600s) iface_a1_mulh_bwn:TIMEOUT(600s) 
mutants: 18 rejected, 1 survived (diff32 is a proven-equivalent mutant, see README); unexpected survivors: none
EXT mutants: 37 rejected, 0 survived
FORMAL RESULT: PASS (mode=full)
real	45m6.556s
```

The runs were timed with the shell's `time` and made one after the other. The summaries as
printed, with every check's verdict and wall time, are in `logs/`; `results.csv` has one row per
run. The M unit's checks gave the verdicts of the earlier records (the same four second-solver
time-outs, `diff32` the only surviving M mutant).

## The EXT unit in the run of record

From the full run's summary (`logs/full.SUMMARY.txt`); wall times per task, `--par 4`, with the
monolithic H6 proof running alongside:

| Check | Engine | Result | Wall |
|---|---|---|---|
| `ext_spec_check_python`: `props/ext_spec.vh` against the Python model | Verilator | `ext spec cross-check: 1157509 vectors (157509 corner/shift, 1000000 random), 0 mismatches` | 5.2 s |
| `ext_payload_map`: the harness's map against `defines/op.sv` | Python | `ext payload map: op::EXT = 61, ext_payload_t layout, 45 rows of f_ext_payload match the 40 op::ext_t constants of defines/op.sv and the numbering of ext_spec.vh` | < 0.1 s |
| X1 + X2, `res_<insn>_yn`, 45 instructions, depth 3 | yices | 45 of 45 PASS | 1.5-3.2 s each for the 17 new instructions; 1.6-5.8 s for the others, rol, ror, rori 16.2-21.8 s |
| the same, `res_<insn>_bwn` (second solver) | bitwuzla | 45 of 45 PASS (reported only) | 2.0-5.4 s each |
| X3, `nostall_yn` | yices | PASS | 1.4 s |
| `ext_cover_bw`, depth 4 | bitwuzla | `ext_cover_bw: 45 cover statement(s) reached, 0 unreached` | 2.6 s |
| 37 negative controls, each mutant against its target property | yices | 37 of 37 FAIL, as required | 1.4-2.4 s each |
| sv2v fidelity, `test_ext_execute` | Verilator | `test_ext_execute: IDENTICAL output (14 lines) for SystemVerilog and sv2v model; last result line:All 1507647 EXT-unit checks passed` | (part of `sv2v_fidelity`) |

The 17 new properties are X1 and X2 for pack, packh, brev8, zip, unzip, xperm4, xperm8,
sha256sig0, sha256sig1, sha256sum0, sha256sum1, sha512sig0h, sha512sig0l, sha512sig1h,
sha512sig1l, sha512sum0r and sha512sum1r; X3 is unchanged and covers every payload. The 20 new
mutants are described in formal/README.md, section 3 (*The EXT proof*), and listed with their
faults in section 4.

EXT mutation campaign (37 mutants × the 46 required property tasks, 300 s per task), as
printed:

```text
EXT mutant results (source: runs/times.txt; non-PASS tasks listed)
ext_andn_and         REJECTED  (46 tasks) non-PASS: res_andn_yn:FAIL
ext_lzc_zero31       REJECTED  (46 tasks) non-PASS: res_clz_yn:FAIL res_ctz_yn:FAIL
ext_ctz_no_reverse   REJECTED  (46 tasks) non-PASS: res_ctz_yn:FAIL
ext_pop_pair         REJECTED  (46 tasks) non-PASS: res_cpop_yn:FAIL
ext_minmax_sign      REJECTED  (46 tasks) non-PASS: res_max_yn:FAIL res_maxu_yn:FAIL res_min_yn:FAIL res_minu_yn:FAIL
ext_sexth_zero       REJECTED  (46 tasks) non-PASS: res_sext_h_yn:FAIL
ext_rol_as_ror       REJECTED  (46 tasks) non-PASS: res_rol_yn:FAIL
ext_orcb_and         REJECTED  (46 tasks) non-PASS: res_orc_b_yn:FAIL
ext_rev8_middle      REJECTED  (46 tasks) non-PASS: res_rev8_yn:FAIL
ext_bext_bit1        REJECTED  (46 tasks) non-PASS: res_bext_yn:FAIL res_bexti_yn:FAIL
ext_bseti_rs2        REJECTED  (46 tasks) non-PASS: res_bclri_yn:FAIL res_binvi_yn:FAIL res_bseti_yn:FAIL
ext_czero_rs1        REJECTED  (46 tasks) non-PASS: res_czero_eqz_yn:FAIL res_czero_nez_yn:FAIL
ext_stall_dead       REJECTED  (46 tasks) non-PASS: nostall_yn:FAIL
ext_reg_flip         REJECTED  (46 tasks) non-PASS: res_andn_yn:FAIL res_orn_yn:FAIL res_xnor_yn:FAIL res_clz_yn:FAIL res_ctz_yn:FAIL res_max_yn:FAIL res_maxu_yn:FAIL res_min_yn:FAIL res_sext_b_yn:FAIL res_minu_yn:FAIL res_cpop_yn:FAIL res_sext_h_yn:FAIL res_zext_h_yn:FAIL res_orc_b_yn:FAIL res_rev8_yn:FAIL res_bclr_yn:FAIL res_bclri_yn:FAIL res_rori_yn:FAIL res_bext_yn:FAIL res_ror_yn:FAIL res_bexti_yn:FAIL res_rol_yn:FAIL res_binv_yn:FAIL res_binvi_yn:FAIL res_bset_yn:FAIL res_bseti_yn:FAIL res_czero_eqz_yn:FAIL res_czero_nez_yn:FAIL
ext_reg_bubble       REJECTED  (46 tasks) non-PASS: res_andn_yn:FAIL res_orn_yn:FAIL res_xnor_yn:FAIL res_clz_yn:FAIL res_ctz_yn:FAIL res_max_yn:FAIL res_maxu_yn:FAIL res_min_yn:FAIL res_sext_b_yn:FAIL res_cpop_yn:FAIL res_minu_yn:FAIL res_sext_h_yn:FAIL res_zext_h_yn:FAIL res_orc_b_yn:FAIL res_rev8_yn:FAIL res_bclr_yn:FAIL res_bclri_yn:FAIL res_rori_yn:FAIL res_ror_yn:FAIL res_bext_yn:FAIL res_bexti_yn:FAIL res_rol_yn:FAIL res_binvi_yn:FAIL res_binv_yn:FAIL res_bset_yn:FAIL res_bseti_yn:FAIL res_czero_nez_yn:FAIL res_czero_eqz_yn:FAIL
ext_fwd_invalid      REJECTED  (46 tasks) non-PASS: res_andn_yn:FAIL res_orn_yn:FAIL res_xnor_yn:FAIL res_clz_yn:FAIL res_ctz_yn:FAIL res_cpop_yn:FAIL res_max_yn:FAIL res_maxu_yn:FAIL res_min_yn:FAIL res_minu_yn:FAIL res_sext_b_yn:FAIL res_sext_h_yn:FAIL res_zext_h_yn:FAIL res_rol_yn:FAIL res_ror_yn:FAIL res_rori_yn:FAIL res_orc_b_yn:FAIL res_rev8_yn:FAIL res_bclr_yn:FAIL res_bclri_yn:FAIL res_bext_yn:FAIL res_bexti_yn:FAIL res_binv_yn:FAIL res_bset_yn:FAIL res_binvi_yn:FAIL res_bseti_yn:FAIL res_czero_eqz_yn:FAIL res_czero_nez_yn:FAIL
ext_fwd_addr_rs1     REJECTED  (46 tasks) non-PASS: res_andn_yn:FAIL res_orn_yn:FAIL res_xnor_yn:FAIL res_clz_yn:FAIL res_ctz_yn:FAIL res_cpop_yn:FAIL res_max_yn:FAIL res_maxu_yn:FAIL res_min_yn:FAIL res_minu_yn:FAIL res_sext_b_yn:FAIL res_sext_h_yn:FAIL res_zext_h_yn:FAIL res_rol_yn:FAIL res_ror_yn:FAIL res_rori_yn:FAIL res_orc_b_yn:FAIL res_rev8_yn:FAIL res_bclr_yn:FAIL res_bclri_yn:FAIL res_bext_yn:FAIL res_bexti_yn:FAIL res_binv_yn:FAIL res_binvi_yn:FAIL res_bset_yn:FAIL res_bseti_yn:FAIL res_czero_eqz_yn:FAIL res_czero_nez_yn:FAIL
ext_pack_swap        REJECTED  (46 tasks) non-PASS: res_pack_yn:FAIL
ext_packh_byte1      REJECTED  (46 tasks) non-PASS: res_packh_yn:FAIL
ext_brev8_bytes      REJECTED  (46 tasks) non-PASS: res_brev8_yn:FAIL
ext_zip_unzip        REJECTED  (46 tasks) non-PASS: res_zip_yn:FAIL
ext_unzip_halves     REJECTED  (46 tasks) non-PASS: res_unzip_yn:FAIL
ext_xperm4_wrap      REJECTED  (46 tasks) non-PASS: res_xperm4_yn:FAIL
ext_xperm8_bound     REJECTED  (46 tasks) non-PASS: res_xperm8_yn:FAIL
ext_sig0_ror3        REJECTED  (46 tasks) non-PASS: res_sha256sig0_yn:FAIL
ext_sig1_srl11       REJECTED  (46 tasks) non-PASS: res_sha256sig1_yn:FAIL
ext_sum0_rol2        REJECTED  (46 tasks) non-PASS: res_sha256sum0_yn:FAIL
ext_sum1_ror24       REJECTED  (46 tasks) non-PASS: res_sha256sum1_yn:FAIL
ext_sig0h_gate       REJECTED  (46 tasks) non-PASS: res_sha512sig0h_yn:FAIL res_sha512sig0l_yn:FAIL
ext_sig0l_no25       REJECTED  (46 tasks) non-PASS: res_sha512sig0l_yn:FAIL
ext_sig1h_with26     REJECTED  (46 tasks) non-PASS: res_sha512sig1h_yn:FAIL
ext_sig1_srl18       REJECTED  (46 tasks) non-PASS: res_sha512sig1h_yn:FAIL res_sha512sig1l_yn:FAIL
ext_sum0r_swap       REJECTED  (46 tasks) non-PASS: res_sha512sum0r_yn:FAIL
ext_sum1r_13         REJECTED  (46 tasks) non-PASS: res_sha512sum1r_yn:FAIL
ext_crypto_never     REJECTED  (46 tasks) non-PASS: res_pack_yn:FAIL res_packh_yn:FAIL res_brev8_yn:FAIL res_zip_yn:FAIL res_unzip_yn:FAIL res_xperm4_yn:FAIL res_xperm8_yn:FAIL res_sha256sig0_yn:FAIL res_sha256sig1_yn:FAIL res_sha256sum0_yn:FAIL res_sha256sum1_yn:FAIL res_sha512sig0h_yn:FAIL res_sha512sig0l_yn:FAIL res_sha512sig1h_yn:FAIL res_sha512sig1l_yn:FAIL res_sha512sum0r_yn:FAIL res_sha512sum1r_yn:FAIL
ext_stall_crypto     REJECTED  (46 tasks) non-PASS: nostall_yn:FAIL
ext_reg_flip_k       REJECTED  (46 tasks) non-PASS: res_pack_yn:FAIL res_packh_yn:FAIL res_brev8_yn:FAIL res_zip_yn:FAIL res_unzip_yn:FAIL res_xperm4_yn:FAIL res_sha256sig0_yn:FAIL res_sha256sig1_yn:FAIL res_xperm8_yn:FAIL res_sha256sum0_yn:FAIL res_sha256sum1_yn:FAIL res_sha512sig0h_yn:FAIL res_sha512sig0l_yn:FAIL res_sha512sig1h_yn:FAIL res_sha512sig1l_yn:FAIL res_sha512sum0r_yn:FAIL res_sha512sum1r_yn:FAIL
```

The 17 mutants of the Zbb, Zbs and Zicond half are rejected by exactly the proofs that rejected
them in the record of c1a7c85; none of them changes a result of the cryptography half. Each of
the 20 new mutants is rejected only by the proofs of the cryptography instructions it breaks
(`crypto_never` and `reg_flip_k` by all 17 of them, `stall_crypto` by X3 alone).

## Figures and where they are quoted

| Figure as quoted | Quoted at | This record |
|---|---|---|
| `FORMAL RESULT: PASS (mode=default)`: 121 required checks and 41 negative controls | formal/README.md (section 4) | the default run above |
| `FORMAL RESULT: PASS (mode=full)`: 123 required checks, 41 negative controls, 65 second-solver runs, 2,310 mutant runs; `mode=ext`: 51 required checks, 37 negative controls; the run times | formal/README.md (introduction, section 4) | the full and ext runs above (2,310 = 19 × 32 + 37 × 46) |
| the proved file `52201629…2bfa5d` | formal/README.md (introduction, sections 4 and 9) | `sha256sum rtl/execute_stage.sv`; the first line of each summary |
| the EXT proof: X1-X3 for 45 instructions, 1,157,509 specification vectors, 45 covers, 37 mutants each rejected by exactly the proofs of the instructions it breaks | formal/README.md (sections 1, 3, 4) | the EXT tables above |

## Commands

From the repository root, with the tools installed as in formal/README.md:

```bash
export HADES_FORMAL_ENV=<file that puts the tools on PATH>   # if they are not on PATH already
make formal         # default mode
make formal-full    # full mode
make formal-ext     # the EXT unit only
```

## Inputs

`inputs.sha256` lists the SHA-256 of every input that the runs read: `rtl/execute_stage.sv`, the
eight `defines/` packages that `gen.sh` translates, every file of the flow (all of `formal/`
except its README) and the four benches of the sv2v fidelity check with `test/sv/files.txt`
(`sha256sum -c` from the repository root). Unchanged since bd800d8 (`git rev-parse bd800d8:<path>`):

| Path | bd800d8 |
|---|---|
| `test/sv/test_m_execute.sv`, `test_execute_compare.sv`, `test_execute_bpred_nextpc.sv` | `e554dd0f…`, `58412f2d…`, `d61060e6…` |
| `test/sv/files.txt` | `8b137891791fe96927ad78e64b0aad7bded08bdc` |
| `ref` | `b1cd1eebbcd4c675f36085ebfc96416192423721` |

## Environment

- Date: 2026-10-02.
- Host: Intel Core Ultra 7 165H, 22 threads, Linux.
- Tools (formal/README.md, *Tools*), as in the record of c1a7c85: YoWASP Yosys 0.69
  (`yowasp-yosys 0.69.0.0.post1233`, runtime 1.96) with SBY and yosys-smtbmc, z3 from the
  `z3-solver` wheel (`5.1.0.0`, reports 5.1.0), both in a Python 3.12 virtual environment;
  bitwuzla 0.9.1, Yices 2.7.0 and sv2v 0.0.13, the release binaries; Verilator 5.042.
- Workers: `--par 4` (the Makefile default `FORMAL_PAR=4`). The load of the machine during the
  runs was not recorded.

## Caveats

- The flow, the RTL and the EXT bench were not yet committed when the runs were made;
  `inputs.sha256` fingerprints them.
- The full run took 45 min 07 s against 26 min 18 s in the record of c1a7c85: the EXT mutation
  campaign has 1,702 runs instead of 493, and the monolithic H6 proof by bitwuzla
  (`hint_validity_h6_bwn` 1,698.8 s, `hint_validity_h6_bw` 825.9 s) ran alongside it.
- The usage comment at the top of `formal/run.sh` still gives the run times of the record of
  c1a7c85; no executed line differs.
- Wall times depend on the host and its load and are never compared.
- What is and is not proven is stated in formal/README.md, section 5; for the EXT unit, item 9:
  the decoder's map from instruction word to payload, payloads the decoder never builds
  (including the reserved codes `1_110_xx` and `1_111_xx` of the cryptography half; covered by
  X3 only), and everything downstream of Execute are outside the proof.
