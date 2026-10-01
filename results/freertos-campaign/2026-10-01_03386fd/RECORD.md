# FreeRTOS differential campaign: suite `sep2026`

Recorded on 2026-10-01 at commit 03386fd.

**STATUS: repeatable**. The simulations are deterministic: the command below reproduces every status and cycle count of results.csv, which `--compare` checks run for run.

## Figures

Where they are quoted:

- docs/VERIFICATION.md:136: "On the fixed core the final differential campaign passed **794 of 794** FreeRTOS runs (102 of them with the branch predictor enabled, about 14.7 billion simulated cycles), with every one of the 523 golden-CPU twin runs agreeing"

Measured by this run:

| target | runs | passed | with the branch predictor on | simulated cycles |
|---|---|---|---|---|
| dut | 794 | 794 | 102 | 14,684,200,429 (14.68 billion) |
| golden | 523 | 523 | - | 10,588,742,084 (10.59 billion) |

- dut: 523 runs with a golden twin, 0 diverged from it
- exact duplicates (the same program image, seed, simulator and cycle limit as a run of an earlier entry): 40 dut, 40 golden runs; 80 of 80 gave the same result as the run they repeat; distinct DUT runs: 754

```text
CAMPAIGN RESULT: PASS (1317 runs: 0 DUT run(s) not passed, 0 golden run(s) not passed, 0 build failure(s))
```

The quoted figures against this run:

| quoted | measured |
|---|---|
| **794 of 794** FreeRTOS runs | 794 DUT runs, 794 passed (754 of them distinct: 40 repeat a run of an earlier entry exactly) |
| 102 of them with the branch predictor enabled | 102 |
| about 14.7 billion simulated cycles | 14,684,200,429 cycles in the DUT runs (the 523 golden runs add 10,588,742,084) |
| every one of the 523 golden-CPU twin runs agreeing | 523 golden runs, all passed; 523 DUT runs have a golden twin, none diverged from it |

The run counts and the per-set cycle totals are those of the campaign of 2026-09-27, and so is every per-run value of it that survives (see [Comparison with the campaign of 2026-09-27](#comparison-with-the-campaign-of-2026-09-27)).

## Command

From the root of a clean clone (tools as in docs/BUILDING.md):

```bash
python3 test/freertos/campaign.py --suite sep2026 --jobs 12 --wall-limit 0
```

To check a re-run against this record:

```bash
python3 test/freertos/campaign.py --suite sep2026 --jobs 12 --wall-limit 0 \
    --compare results/freertos-campaign/2026-10-01_03386fd/results.csv
```

`--jobs` sets only the number of simulations run in parallel and `--wall-limit 0` lifts the per-run wall-clock limit; neither changes a result. The per-run logs (`sim.log`, and `cmd.txt` with the exact simulator command of the run) and the ELF files are not kept in the record; the command writes them under its output directory (`--out`, by default under `build/freertos-campaign/`).

Suite `sep2026`: the final campaign on the fixed core, run on 2026-09-27, whose totals docs/VERIFICATION.md quotes. It runs the entries below in one pool; each is equivalent to `python3 test/freertos/campaign.py <options>`:

| entry | options |
|---|---|
| breaker | `--set breaker --seeds 8 --seed-base 0x101 --run-cycles 20000000` |
| breaker2 | `--set breaker2 --seeds 8 --seed-base 0x401 --run-cycles 20000000` |
| breaker-long | `--set breaker-long --seeds 3 --seed-base 0x301 --run-cycles 100000000 --max-checks 100000` |
| validate | `--set validate --seeds 16` |
| bpred | `--set bpred --seeds 4 --seed-base 0x201 --run-cycles 10000000` |
| standard | `--set standard --seeds 8` |

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

- Program images: [inputs.sha256](inputs.sha256) lists the sha256 of the 101 `init.mem` images (the image a simulator loads; the `image` column of results.csv holds its first 16 hex digits), which `sha256sum -c` checks in the output directory of a re-run, and, as `# elf` comments, those of the 101 ELF files: their debug information holds the absolute path of the checkout, so they match only at the same path.
- Verilator: Verilator 5.042 2025-11-02 rev v5.042
- GCC: riscv32-unknown-elf-gcc () 12.2.0
- Binutils: GNU ld (GNU Binutils) 2.39
- Python: Python 3.12.3

## Run

- Date: 2026-10-01; from 2026-10-01T12:49:38Z to 2026-10-01T14:11:29Z (UTC); wall time 4911 s
- Workers: 12 parallel simulations
- Host: Intel Core Ultra 7 165H, 22 hardware threads, Linux

## Result

The summary as printed (the per-run table is in [summary.md](summary.md), one row per run in [results.csv](results.csv)):

```text
## Summary

| target | runs | PASS | FAIL | of which UART transcript only | HANG | CRASH | vs golden: runs with a golden twin | diverged |
|---|---|---|---|---|---|---|---|---|
| dut | 794 | 794 | 0 | 0 | 0 | 0 | 523 | 0 |
| golden | 523 | 523 | 0 | 0 | 0 | 0 | - | - |

### Per entry

| entry | equivalent options | variants | DUT runs (predictor on) | DUT passed | golden runs | golden passed | DUT Gcycles | golden Gcycles | simulation time (s) |
|---|---|---|---|---|---|---|---|---|---|
| breaker | `--set breaker --seeds 8 --seed-base 0x101 --run-cycles 20000000` | 15 | 120 (40) | 120 | 80 | 80 | 2.39 | 1.61 | 24176 |
| breaker2 | `--set breaker2 --seeds 8 --seed-base 0x401 --run-cycles 20000000` | 8 | 64 (16) | 64 | 40 | 40 | 1.25 | 0.80 | 3537 |
| breaker-long | `--set breaker-long --seeds 3 --seed-base 0x301 --run-cycles 100000000 --max-checks 100000` | 6 | 18 (6) | 18 | 15 | 15 | 1.80 | 1.50 | 5745 |
| validate | `--set validate --seeds 16` | 7 | 112 (0) | 112 | 112 | 112 | 0.58 | 0.58 | 1869 |
| bpred | `--set bpred --seeds 4 --seed-base 0x201 --run-cycles 10000000` | 10 | 40 (40) | 40 | 36 | 36 | 1.53 | 1.49 | 4711 |
| standard | `--set standard --seeds 8` | 55 | 440 (0) | 440 | 240 | 240 | 7.13 | 4.61 | 18725 |
| total |  | 101 | 794 (102) | 794 | 523 | 523 | 14.68 | 10.59 | 58763 |

Simulation time: the sum of the runs' wall-clock times (the entries share one pool of 12 workers).

Runs: exact duplicates (the same program image, seed, simulator and cycle limit as a run of an earlier entry): 40 dut, 40 golden runs; 80 of 80 gave the same result as the run they repeat; distinct DUT runs: 754.

### Failure signatures

### Verdict

- harness check: golden passed all 523 runs
- dut: 794/794 runs passed

(wall time 4911 s; logs under $HADES_BUILD_DIR/freertos-campaign/sep2026)

CAMPAIGN RESULT: PASS (1317 runs: 0 DUT run(s) not passed, 0 golden run(s) not passed, 0 build failure(s))
```

## Comparison with the campaign of 2026-09-27

The campaign of 2026-09-27 ([historical record](../2026-09-27_6b19d41/RECORD.md)) ran the same six commands one after the other, on 6 workers each, in a tree that was commit 97ef211 plus the changes committed the next day as 0d25ee6 and 6b19d41. Its per-run results were not kept; everything of it that survives in the development log of 2026-09-27 agrees with this re-run.

Per set (2026-09-27 / this re-run):

| set | DUT runs (predictor on) | golden runs | all passed | DUT Gcycles | golden Gcycles |
|---|---|---|---|---|---|
| breaker | 120 (40) / 120 (40) | 80 / 80 | yes / yes | 2.39 / 2.39 | 1.61 / 1.61 |
| breaker2 | 64 (16) / 64 (16) | 40 / 40 | yes / yes | 1.25 / 1.25 | 0.79 / 0.80 |
| breaker-long | 18 (6) / 18 (6) | 15 / 15 | yes / yes | 1.80 / 1.80 | 1.50 / 1.50 |
| validate | 112 (0) / 112 (0) | 112 / 112 | yes / yes | 0.58 / 0.58 | 0.58 / 0.58 |
| bpred | 40 (40) / 40 (40) | 36 / 36 | yes / yes | 1.53 / 1.53 | 1.49 / 1.49 |
| standard | 440 (0) / 440 (0) | 240 / 240 | yes / yes | 7.13 / 7.13 | 4.61 / 4.61 |
| total | 794 (102) / 794 (102) | 523 / 523 | yes / yes | 14.68 / 14.68 | 10.58 / 10.59 |

The two golden figures that differ in the last digit are not a difference in the runs: each figure of 2026-09-27 is the sum of a predictor-off and a predictor-on figure, each rounded to 0.01 billion (breaker2: 0.63 + 0.16 = 0.79), while this table rounds the exact sum once (796,621,910 cycles for breaker2; 10,588,742,084 in total). The log's own tabulation, computed in the same way from results.csv, is identical line for line:

```bash
python3 - <<'EOF'
import csv, collections
rows = list(csv.DictReader(open("results/freertos-campaign/2026-10-01_03386fd/results.csv")))
for s in ("breaker", "breaker2", "breaker-long", "validate", "bpred", "standard"):
    n, ok, cyc = collections.Counter(), collections.Counter(), collections.Counter()
    for r in rows:
        if r["set"] == s:
            k = (r["target"], "bp-on" if r["bpred"] != "0" else "bp-off")
            n[k] += 1; ok[k] += r["status"] == "PASS"; cyc[k] += int(r["cycles"])
    print(f"{s:13s}", "; ".join(f"{t} {b}: {ok[t, b]}/{n[t, b]} PASS ({cyc[t, b] / 1e9:.2f} G cyc)"
                               for t in ("dut", "golden") for b in ("bp-off", "bp-on") if n[t, b]))
EOF
```

```text
breaker       dut bp-off: 80/80 PASS (1.58 G cyc); dut bp-on: 40/40 PASS (0.81 G cyc); golden bp-off: 48/48 PASS (0.96 G cyc); golden bp-on: 32/32 PASS (0.65 G cyc)
breaker2      dut bp-off: 48/48 PASS (0.93 G cyc); dut bp-on: 16/16 PASS (0.32 G cyc); golden bp-off: 32/32 PASS (0.63 G cyc); golden bp-on: 8/8 PASS (0.16 G cyc)
breaker-long  dut bp-off: 12/12 PASS (1.20 G cyc); dut bp-on: 6/6 PASS (0.60 G cyc); golden bp-off: 9/9 PASS (0.90 G cyc); golden bp-on: 6/6 PASS (0.60 G cyc)
validate      dut bp-off: 112/112 PASS (0.58 G cyc); golden bp-off: 112/112 PASS (0.58 G cyc)
bpred         dut bp-on: 40/40 PASS (1.53 G cyc); golden bp-on: 36/36 PASS (1.49 G cyc)
standard      dut bp-off: 440/440 PASS (7.13 G cyc); golden bp-off: 240/240 PASS (4.61 G cyc)
```

(The log's lines are the same, under the names of its output directories A_breaker, D_breaker2, C_long, p1_validate, B_bpred and p2_standard.)

Per run: the historical record's results.csv holds the 37 exact per-run values that survive: 19 from the comparisons printed at the end of that campaign (validate `minimal.rv32i.O2.p1s1.t10000.h4`, seeds 0001-0008 on both CPUs; standard `full.rv32i.O2.p1s1.t10000.h4`, DUT seeds 0001 and 0002 and golden seed 0001), 16 lines of its bpred set's results.csv, and 2 breaker values from the identical campaign run earlier that evening. All 37 are the same in this re-run:

```text
$ python3 test/freertos/campaign.py --results results/freertos-campaign/2026-09-27_6b19d41/results.csv \
      --compare results/freertos-campaign/2026-10-01_03386fd/results.csv
(runs of results/freertos-campaign/2026-09-27_6b19d41/results.csv)
== comparison with results/freertos-campaign/2026-10-01_03386fd/results.csv (key: set, variant, seed, target; compared: status, cycles; never wall time)
   runs here: 37; stored: 1317; in common: 37; only here: 0; stored but not run here: 1280
COMPARE RESULT: IDENTICAL (the 37 runs in common; 1280 stored runs were not run here; every compared column equal)
```

For example, validate `minimal.rv32i.O2.p1s1.t10000.h4` seed 0001: DUT 5,169,449 and golden 5,169,441 cycles; standard `full.rv32i.O2.p1s1.t10000.h4`: DUT 150,679,860 (seed 0001) and 150,681,774 (seed 0002), golden 150,679,538 (seed 0001). The two breaker runs also print as many UART pattern lines as the log records (117 on the DUT, 116 on the golden CPU). The 14 further values that the log's progress lines give to 0.01 million cycles (listed in the historical record) are the same here too.

Wall times are not comparable: on 2026-09-27 the six commands ran one after the other on 6 workers each (5112 s in all, builds included); here they shared one pool of 12 workers (4911 s), on a machine shared with other jobs. The *simulation time* column of the per-entry table above is a sum of run times, not a wall time.

## Caveats

- The working tree differed from the base commit in these inputs: `test/freertos/campaign.py` (modified), `Makefile` (modified), `test/bench/bench.mk` (untracked); their sha256 are under Inputs.
- Wall times depend on the host and its load; every other column of results.csv is deterministic.
- This suite re-runs, in one pool of workers, the six commands of the campaign of 2026-09-27 whose totals docs/VERIFICATION.md:136 quotes (historical record: results/freertos-campaign/2026-09-27_6b19d41/). The per-run results of that campaign were not kept.
- test/freertos/campaign.py is the version that adds --suite, --record, --compare, --results and --wall-limit (sha256 under Inputs). Its variant definitions are those of 03386fd: the --list output of every set is unchanged, and each entry of the suite lists exactly the variants of the corresponding --set command.
- The other working-tree changes (the benchmark targets of the Makefile and test/bench/, committed with this record) do not affect the campaign. All 101 program images of this run (the `init.mem` lines of inputs.sha256) are identical to those built from a clean checkout of 03386fd; this was checked before the run and again afterwards, with a fresh build.
- Other jobs shared the machine during this run; that changes only the wall times.
- The run was started as `nice python3 test/freertos/campaign.py --suite sep2026 --jobs 12 --wall-limit 0 --record results/freertos-campaign/2026-10-01_03386fd`, with `--quoted-in` and `--note` options that only fill in this record, and with `HADES_BUILD_DIR` set to a build directory outside the working tree; none of this changes a result. The table of quoted against measured figures and the comparison with 2026-09-27 were added to this file after the run.
- After this run, and before it was committed, the `Makefile` was extended by the `check-results` target and help text; it changes no build rule. The sha256 under Inputs is that of the Makefile this run used.
- Correction (2026-10-01): inputs.sha256 first listed the ELF files as sha256sum lines, which `sha256sum -c` reports as FAILED anywhere but at the original path; they are now `# elf` comments, and the `init.mem` lines are unchanged.
- test/freertos/README.md was edited after this run (documentation only); it is not among the changes to the test/freertos input listed above.
- After this run, test/freertos/campaign.py was changed again before it was committed: it now copies the ref/*.so files of a relocated build directory once, before the parallel model builds (two makes copying the same file at once could fail with "File exists" in a new build directory), writes the ELF hashes of inputs.sha256 as comments and writes CSV files with LF line endings. None of this changes a result; the sha256 under Inputs is that of the campaign.py this run used.
- results.csv was converted from CRLF to LF line endings on 2026-10-01; its content is unchanged.
