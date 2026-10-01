# FreeRTOS differential campaign: set `validate`

Recorded on 2026-10-01 at commit 03386fd.

**STATUS: repeatable**. The simulations are deterministic: the command below reproduces every status and cycle count of results.csv, which `--compare` checks run for run.

## Figures

Where they are quoted:

- README.md:91: "| FreeRTOS differential campaign on HaDes-V+ and the golden CPU | `make freertos-stress` | 28 of 28 runs `PASS` |"
- docs/VERIFICATION.md:77: "| Differential campaign | `make freertos-stress` | `CAMPAIGN RESULT: PASS (28 runs: 0 DUT run(s) not passed, 0 golden run(s) not passed, 0 build failure(s))` |"
- docs/VERIFICATION.md:142-165: the table of the 28 runs (14 variant and seed rows, DUT and golden verdict with the cycles to 0.01 million), the summary table (dut 14 runs, 14 PASS, 14 with a golden twin, 0 diverged; golden 14 runs, 14 PASS) and "CAMPAIGN RESULT: PASS (28 runs: 0 DUT run(s) not passed, 0 golden run(s) not passed, 0 build failure(s))"
- docs/FREERTOS.md:279-282: "- harness check: golden passed all 14 runs", "- dut: 14/14 runs passed", "CAMPAIGN RESULT: PASS (28 runs: 0 DUT run(s) not passed, 0 golden run(s) not passed, 0 build failure(s))"

Measured by this run:

| target | runs | passed | with the branch predictor on | simulated cycles |
|---|---|---|---|---|
| dut | 14 | 14 | 0 | 72,464,642 (72.5 million) |
| golden | 14 | 14 | - | 72,448,113 (72.4 million) |

- dut: 14 runs with a golden twin, 0 diverged from it

```text
CAMPAIGN RESULT: PASS (28 runs: 0 DUT run(s) not passed, 0 golden run(s) not passed, 0 build failure(s))
```

## Command

From the root of a clean clone (tools as in docs/BUILDING.md):

```bash
python3 test/freertos/campaign.py --set validate --seeds 2 --strict --jobs 4
```

This is the campaign that `make freertos-stress` runs (the command the documentation quotes; see Caveats).

To check a re-run against this record:

```bash
python3 test/freertos/campaign.py --set validate --seeds 2 --strict --jobs 4 \
    --compare results/freertos-validate/2026-10-01_03386fd/results.csv
```

`--jobs` sets only the number of simulations run in parallel; it changes no result. The per-run logs (`sim.log`, and `cmd.txt` with the exact simulator command of the run) and the ELF files are not kept in the record; the command writes them under its output directory (`--out`, by default under `build/freertos-campaign/`).

## Inputs

- Base commit: `03386fdda932f4827cded26e8cfc2a2cc531b365` (committed 2026-10-01T00:36:13-04:00)

| input | git object at the base commit | working tree |
|---|---|---|
| `rtl` | `031b989be1f25dd20836028c5126a5b1dc562bd7` | as committed |
| `lib` | `f90a9a64ddc67db6642bc6654545f1509744426b` | as committed |
| `defines` | `36f0452de823189873ca8ac79d7a662918961ad6` | as committed |
| `sim` | `0dad5608c126445abb808c5addd7b6e9d4df54c7` | as committed |
| `ref` | `b1cd1eebbcd4c675f36085ebfc96416192423721` | as committed |
| `test/freertos` | `5cb0c42ab14390f060bd6d09bff6903020ac3432` | modified: `test/freertos/campaign.py` sha256 `cda2771aafd5473ed305ae1086483e8d90ae9efc56e1f3fd81f59c5a330705be` |
| `third_party/freertos` | `57da15398a605dce56c72d420bef3282ba2bb3cc` | as committed |
| `Makefile` | `c24da7fcabf3a320f4dd556b69de540f75fc6a6e` | modified: `Makefile` sha256 `1dcbe87eb8bef2f178223568dff041ee1e5a2dcb5ff1ed7ec5dd30de42be28ff` |
| `test/bench/bench.mk` | (not in the commit) | untracked: `test/bench/bench.mk` sha256 `1bd837d36516358dff9b3a236696f5707d387017702062f4a37a834879fca1a2` |

- Program images: [inputs.sha256](inputs.sha256) lists the sha256 of the 7 `init.mem` images (the image a simulator loads; the `image` column of results.csv holds its first 16 hex digits), which `sha256sum -c` checks in the output directory of a re-run, and, as `# elf` comments, those of the 7 ELF files: their debug information holds the absolute path of the checkout, so they match only at the same path.
- Verilator: Verilator 5.042 2025-11-02 rev v5.042
- GCC: riscv32-unknown-elf-gcc () 12.2.0
- Binutils: GNU ld (GNU Binutils) 2.39
- Python: Python 3.12.3

## Run

- Date: 2026-10-01; from 2026-10-01T15:35:31Z to 2026-10-01T15:36:08Z (UTC); wall time 36.5 s
- Workers: 4 parallel simulations
- Host: Intel Core Ultra 7 165H, 22 hardware threads, Linux

## Result

The summary as printed (the per-run table is in [summary.md](summary.md), one row per run in [results.csv](results.csv)):

```text
| variant | seed | dut | golden |
|---|---|---|---|
| minimal.rv32i.O2.p1s1.t10000.h4 | 0001 | PASS 5.17M | PASS 5.17M |
| minimal.rv32i.O2.p1s1.t10000.h4 | 0002 | PASS 5.16M | PASS 5.16M |
| mzba.rv32i.O2.p1s1.t10000.h4 | 0001 | PASS 6.07M | PASS 6.07M |
| mzba.rv32i.O2.p1s1.t10000.h4 | 0002 | PASS 5.98M | PASS 5.98M |
| stress.noyield.rv32i.O0.p1s1.t10000.h4 | 0001 | PASS 5.22M | PASS 5.22M |
| stress.noyield.rv32i.O0.p1s1.t10000.h4 | 0002 | PASS 5.22M | PASS 5.21M |
| stress.noyield.rv32i.O2.p0s1.t10000.h4 | 0001 | PASS 4.95M | PASS 4.95M |
| stress.noyield.rv32i.O2.p0s1.t10000.h4 | 0002 | PASS 4.95M | PASS 4.95M |
| stress.noyield.rv32i.O2.p1s1.t10000.h4 | 0001 | PASS 4.96M | PASS 4.96M |
| stress.noyield.rv32i.O2.p1s1.t10000.h4 | 0002 | PASS 4.95M | PASS 4.95M |
| stress.noyield.rv32i.Os.p1s1.t5000.h4 | 0001 | PASS 4.96M | PASS 4.96M |
| stress.noyield.rv32i.Os.p1s1.t5000.h4 | 0002 | PASS 4.96M | PASS 4.96M |
| stress.rv32i.O2.p1s1.t10000.h4 | 0001 | PASS 4.96M | PASS 4.96M |
| stress.rv32i.O2.p1s1.t10000.h4 | 0002 | PASS 4.96M | PASS 4.96M |

## Summary

| target | runs | PASS | FAIL | of which UART transcript only | HANG | CRASH | vs golden: runs with a golden twin | diverged |
|---|---|---|---|---|---|---|---|---|
| dut | 14 | 14 | 0 | 0 | 0 | 0 | 14 | 0 |
| golden | 14 | 14 | 0 | 0 | 0 | 0 | - | - |

### Failure signatures

### Verdict

- harness check: golden passed all 14 runs
- dut: 14/14 runs passed

(wall time 37 s; logs under $HADES_BUILD_DIR/freertos-campaign/validate)

CAMPAIGN RESULT: PASS (28 runs: 0 DUT run(s) not passed, 0 golden run(s) not passed, 0 build failure(s))
```

## Comparison

With `results/freertos-campaign/2026-10-01_03386fd/results.csv`:

```text
== comparison with results/freertos-campaign/2026-10-01_03386fd/results.csv (key: set, variant, seed, target; compared: status, reason, cycles, uart_lines, uart_bad, uart_only, app, march, opt, preempt, slice, tick, heap, tag, bpred, ram_kb, nchecks, check_ticks, timeout, image; never wall time)
   runs here: 28; stored: 1317; in common: 28; only here: 0; stored but not run here: 1289
COMPARE RESULT: IDENTICAL (the 28 runs in common; 1289 stored runs were not run here; every compared column equal)
```

## Caveats

- The working tree differed from the base commit in these inputs: `test/freertos/campaign.py` (modified), `Makefile` (modified), `test/bench/bench.mk` (untracked); their sha256 are under Inputs.
- Wall times depend on the host and its load; every other column of results.csv is deterministic.
- The command above is the one `make freertos-stress` runs (test/freertos/freertos.mk, defaults SET=validate, SEEDS=2, JOBS=4); the make target also passes `--kernel` and `--demo` (the vendored third_party/freertos, which is the default) and `--out $BUILD_DIR/freertos-campaign/validate`, and none of these changes a result. This record was made by running that command with `--record` and `--compare` added.
- Before this record was made, `make freertos-stress` itself was run in this working tree: its per-run table, its summary table and its CAMPAIGN RESULT line were identical to docs/VERIFICATION.md:142-165, and its results.csv was identical in every column except wall_s to that of the same command run with the campaign.py of 03386fd in a clean checkout of 03386fd.
- The 28 runs are also part of the suite sep2026 (its validate entry runs seeds 0001-0010 of the same seven variants); the comparison above checks them run for run against the record results/freertos-campaign/2026-10-01_03386fd/.
- test/freertos/campaign.py is the version that adds --suite, --record, --compare, --results and --wall-limit (sha256 under Inputs); the --list output of every set is the same as with the campaign.py of 03386fd. The other working-tree changes (the benchmark targets of the Makefile and test/bench/, committed with this record) do not affect the campaign; the seven program images (init.mem) are identical (sha256) to those built from a clean checkout of 03386fd.
- docs/FREERTOS.md:274 says the campaign "takes a minute or two once the simulators exist"; the wall time of this run (Run, above) was measured with the simulators already built.
- The sentence after the command (on `make freertos-stress`) and the wall time to 0.1 s under Run (the generated line rounded 36.5 s to 36 s, the summary to 37 s) were added to this file after the run.
- After this run, and before it was committed, the `Makefile` was extended by the `check-results` target and help text, and `test/bench/bench.mk` and `test/freertos/campaign.py` changed (see the other caveats); none of them changes a build rule of the campaign. [rechecked.sha256](rechecked.sha256) lists these files as committed, with which `make check-results` re-ran this campaign and printed `COMPARE RESULT: IDENTICAL (all 28 runs; every compared column equal)`. The sha256 under Inputs are those of the files this run used.
- Correction (2026-10-01): inputs.sha256 first listed the ELF files as sha256sum lines, which `sha256sum -c` reports as FAILED anywhere but at the original path; they are now `# elf` comments, and the `init.mem` lines are unchanged.
- test/freertos/README.md was edited after this run (documentation only); it is not among the changes to the test/freertos input listed above.
- After this run, test/freertos/campaign.py was changed again before it was committed: it now copies the ref/*.so files of a relocated build directory once, before the parallel model builds (two makes copying the same file at once could fail with "File exists" in a new build directory), writes the ELF hashes of inputs.sha256 as comments and writes CSV files with LF line endings. None of this changes a result; the sha256 under Inputs is that of the campaign.py this run used.
- This record was made with `--out $HADES_BUILD_DIR/freertos-campaign/validate`, the output directory of `make freertos-stress`, which the last line of the summary names; the command shown above uses the default `--out` (`<build directory>/freertos-campaign/`). The output directory changes no result.
- results.csv was converted from CRLF to LF line endings on 2026-10-01; its content is unchanged.
