# FreeRTOS differential campaign of 2026-09-27 (historical)

The final differential campaign on the fixed core: six `campaign.py` commands run one
after the other on 2026-09-27, 22:28 to 23:53 EDT.

**STATUS: historical**. The per-run results of this campaign were not kept, so it cannot be
compared run for run. It is superseded by
[the re-run of 2026-10-01](../2026-10-01_03386fd/RECORD.md), which repeats the same six
commands as one suite (`--suite sep2026`) at commit 03386fd and reproduces the run counts,
the per-set cycle totals and every per-run value that survives (see
[Confirmation](#confirmation-by-the-re-run-of-2026-10-01)).

## Figures

Where they are quoted:

- docs/VERIFICATION.md:136: "On the fixed core the final differential campaign passed **794 of 794** FreeRTOS runs (102 of them with the branch predictor enabled, about 14.7 billion simulated cycles), with every one of the 523 golden-CPU twin runs agreeing"

As recorded in the development log of 2026-09-27:

```text
FreeRTOS campaigns: DUT 794/794 PASS (102 of them predictor-on). Golden 523/523 PASS.
```

| set | DUT runs (predictor on) | golden runs | DUT Gcycles | golden Gcycles | wall time (s) |
|---|---|---|---|---|---|
| breaker | 120 (40) | 80 | 2.39 | 1.61 | 758 |
| breaker2 | 64 (16) | 40 | 1.25 | 0.79 | 405 |
| breaker-long | 18 (6) | 15 | 1.80 | 1.50 | 708 |
| validate | 112 (0) | 112 | 0.58 | 0.58 | 234 |
| bpred | 40 (40) | 36 | 1.53 | 1.49 | 686 |
| standard | 440 (0) | 240 | 7.13 | 4.61 | 2321 |
| total | 794 (102) | 523 | 14.68 | 10.58 | 5112 |

Every DUT run and every golden run passed; no DUT run diverged from its golden twin. The
cycle figures are, per set, the sum of the predictor-off and predictor-on figures of the
log (each to 0.01 billion); "about 14.7 billion simulated cycles" is the DUT total. The
validate and standard sets share 5 variants and seeds 0001-0008, so 40 DUT and 40 golden
runs were run twice: 754 distinct DUT runs.

## Commands

From the repository root, one after the other (each command also had its own `--out`
directory and log file):

```bash
C="nice python3 test/freertos/campaign.py --jobs 6"
$C --set breaker --seeds 8 --seed-base 0x101 --run-cycles 20000000
$C --set breaker2 --seeds 8 --seed-base 0x401 --run-cycles 20000000
$C --set breaker-long --seeds 3 --seed-base 0x301 --run-cycles 100000000 --max-checks 100000
$C --set validate --seeds 16
$C --set bpred --seeds 4 --seed-base 0x201 --run-cycles 10000000
$C --set standard --seeds 8
```

The same six entries now run in one pool with
`python3 test/freertos/campaign.py --suite sep2026` (see the re-run's record).

## Inputs

- Base commit: `97ef211` (the main branch at the time). The tree was 97ef211 plus the
  uncommitted changes that were committed on 2026-09-28 as `0d25ee6` (the six trap and
  interrupt fixes) and `6b19d41` (FreeRTOS support, this campaign script, the trap sweep).
  The record is filed under `6b19d41`, the later of the two commits that committed the
  measured tree (see [results/README.md](../../README.md#layout-of-a-record)); 97ef211 itself
  still has the six defects.
  Edits made between the campaign and those commits are not recorded separately; the tree
  itself was in temporary storage that was later lost.
- FreeRTOS sources: `FREERTOS_KERNEL` and `FREERTOS_DEMO` pointed at external checkouts,
  which the log shows at FreeRTOS-Kernel `8be86d4` (V11.1.0+) and FreeRTOS/FreeRTOS
  `f4fcc3b`: the commits vendored later into `third_party/freertos` by `6bf71d4`.
- Program images and per-run logs: not kept.
- Tools: Verilator 5.042; riscv32-unknown-elf-gcc 12.2.0 with binutils 2.39; Python 3.12
  (patch level not recorded).

## Run

- Date: 2026-09-27, 22:28:16 to 23:53:28 EDT (2026-09-28T02:28:16Z to 03:53:28Z), 5112 s
- Workers: 6 parallel simulations per command; the commands ran one after the other
- Host: 22 hardware threads, Linux (the CPU model was not recorded)

## Output as recorded

From the development log of 2026-09-27 (paths omitted). The start and end times of the six
commands:

```text
start Sun 27 Sep 2026 10:28:16 PM EDT
A breaker rc=0 Sun 27 Sep 2026 10:40:54 PM EDT
D breaker2 rc=0 Sun 27 Sep 2026 10:47:39 PM EDT
C breaker-long rc=0 Sun 27 Sep 2026 10:59:27 PM EDT
p1 validate rc=0 Sun 27 Sep 2026 11:03:21 PM EDT
B bpred rc=0 Sun 27 Sep 2026 11:14:47 PM EDT
p2 standard rc=0 Sun 27 Sep 2026 11:53:28 PM EDT
ALLDONE
```

The verdict of each command:

```text
breaker       - harness check: golden passed all 80 runs
              - dut: 120/120 runs passed
              (wall time 758 s; logs under ...)
breaker2      - harness check: golden passed all 40 runs
              - dut: 64/64 runs passed
breaker-long  - harness check: golden passed all 15 runs
              - dut: 18/18 runs passed
              (wall time 708 s; logs under ...)
validate      - harness check: golden passed all 112 runs
              - dut: 112/112 runs passed
              (wall time 234 s; logs under ...)
bpred         - harness check: golden passed all 36 runs
              - dut: 40/40 runs passed
              (wall time 686 s; logs under ...)
standard      - harness check: golden passed all 240 runs
              - dut: 440/440 runs passed
              (wall time 2321 s; logs under ...)
```

The per-set totals, computed from each command's `results.json` (the output directories
A_breaker ... p2_standard are breaker, breaker2, breaker-long, validate, bpred, standard):

```text
A_breaker    dut bp-off: 80/80 PASS (1.58 G cyc); dut bp-on: 40/40 PASS (0.81 G cyc); golden bp-off: 48/48 PASS (0.96 G cyc); golden bp-on: 32/32 PASS (0.65 G cyc)
D_breaker2   dut bp-off: 48/48 PASS (0.93 G cyc); dut bp-on: 16/16 PASS (0.32 G cyc); golden bp-off: 32/32 PASS (0.63 G cyc); golden bp-on: 8/8 PASS (0.16 G cyc)
C_long       dut bp-off: 12/12 PASS (1.20 G cyc); dut bp-on: 6/6 PASS (0.60 G cyc); golden bp-off: 9/9 PASS (0.90 G cyc); golden bp-on: 6/6 PASS (0.60 G cyc)
p1_validate  dut bp-off: 112/112 PASS (0.58 G cyc); golden bp-off: 112/112 PASS (0.58 G cyc)
B_bpred      dut bp-on: 40/40 PASS (1.53 G cyc); golden bp-on: 36/36 PASS (1.49 G cyc)
p2_standard  dut bp-off: 440/440 PASS (7.13 G cyc); golden bp-off: 240/240 PASS (4.61 G cyc)
```

## Per-run values that survive

The log quotes the exact cycle counts of 37 runs; [results.csv](results.csv) holds them
(`set, variant, seed, target, status, cycles`, plus `source`):

- `comparison-line` (19 runs): the final values printed when this campaign was compared
  with an earlier one: validate `minimal.rv32i.O2.p1s1.t10000.h4`, seeds 0001-0008 on the
  DUT and the golden CPU; standard `full.rv32i.O2.p1s1.t10000.h4`, DUT seeds 0001 and 0002,
  golden seed 0001.
- `csv-excerpt` (16 runs): lines of the bpred set's `results.csv`: the two `full` variants,
  seeds 0201-0204, DUT and golden.
- `earlier-identical` (2 runs): breaker `brk.bpdyn.rv32i.O2.p1s1.t10000.h4.bp3` seed 0101,
  DUT and golden. These lines come from a campaign of the same set run earlier that evening;
  the log reports that campaign identical to this one in status and cycles in all 120 DUT
  and 80 golden runs of the breaker set.

Progress lines of the logs give 14 more runs to 0.01 million cycles:

| set | variant | seed | target | as recorded |
|---|---|---|---|---|
| breaker | `brk.rv32i.O2.p0s1.t10000.h4` | 0102 | dut | PASS 20.25M |
| breaker | `brk.rv32i.O2.p0s1.t10000.h4` | 0105 | golden | PASS 20.25M |
| breaker | `brk.rv32i.O2.p1s1.t10000.h4` | 0104 | golden | PASS 20.28M |
| breaker | `brk.rv32i.O2.p1s1.t3000.h4` | 0104 | dut | PASS 18.29M |
| breaker | `brk.rv32i.Os.p1s0.t5000.h4` | 0103 | dut | PASS 20.29M |
| breaker | `brk.rv32i.Os.p1s0.t5000.h4` | 0106 | golden | PASS 20.29M |
| breaker-long | `brk.rv32i.Os.p1s0.t5000.h4` | 0301 | golden | PASS 100.29M |
| bpred | `stress.noyield.rv32i.Os.p1s1.t5000.h4.bp3` | 0203 | golden | PASS 9.76M |
| bpred | `stress.rv32i.O2.p1s1.t10000.h4.bp3` | 0201 | golden | PASS 10.17M |
| standard | `full.rv32i.O2.p1s1.t10000.h4` | 0004 | golden | PASS 150.68M |
| standard | `full.rv32im_zba.O2.p1s1.t10000.h4` | 0004 | dut | PASS 150.67M |
| standard | `mzba.rv32im_zba.O0.p1s1.t50000.h4` | 0008 | dut | PASS 5.73M |
| standard | `mzba.rv32im_zba.O2.p1s1.t5000.h1` | 0005 | dut | PASS 5.38M |
| standard | `mzba.rv32im_zba.Os.p0s1.t10000.h4` | 0006 | dut | PASS 5.45M |

## Confirmation by the re-run of 2026-10-01

[The re-run](../2026-10-01_03386fd/RECORD.md) ran the same six entries as
`python3 test/freertos/campaign.py --suite sep2026 --jobs 12 --wall-limit 0` at commit
03386fd, whose variant definitions are those of this campaign: the six commands above list
the same variants (names, RAM sizes, run lengths and cycle limits) with the campaign.py of
6b19d41 and with that of 03386fd. From 6b19d41 to 03386fd `rtl/` is unchanged; the UART
model (`lib/wishbone/wishbone_uart.sv`, 03386fd) and the simulation top level (`sim/`, the
console bridge of cbae9b9) changed. The re-run reproduces everything above that survives:

- the run counts: 794 DUT runs (102 with the branch predictor on) and 523 golden runs, all
  passed, none diverged, with the same 40 DUT and 40 golden repeat runs (754 distinct DUT
  runs);
- the per-set totals: computed from the re-run's results.csv in the same way, the six lines
  of the tabulation above are identical, character for character;
- all 37 exact per-run values of [results.csv](results.csv), in status and cycles; the two
  breaker runs also print as many UART pattern lines as the log records (117 on the DUT, 116
  on the golden CPU):

  ```text
  $ python3 test/freertos/campaign.py --results results/freertos-campaign/2026-09-27_6b19d41/results.csv \
        --compare results/freertos-campaign/2026-10-01_03386fd/results.csv
  (runs of results/freertos-campaign/2026-09-27_6b19d41/results.csv)
  == comparison with results/freertos-campaign/2026-10-01_03386fd/results.csv (key: set, variant, seed, target; compared: status, cycles; never wall time)
     runs here: 37; stored: 1317; in common: 37; only here: 0; stored but not run here: 1280
  COMPARE RESULT: IDENTICAL (the 37 runs in common; 1280 stored runs were not run here; every compared column equal)
  ```

- the 14 values to 0.01 million cycles of the progress lines: all the same.

The re-run's golden cycle totals print as 0.80 billion for breaker2 and 10.59 billion in all,
against 0.79 and 10.58 here: the figures here are sums of two values each rounded to 0.01
billion (breaker2: 0.63 + 0.16), while the re-run rounds the exact sums once (796,621,910 and
10,588,742,084 cycles). The wall times cannot be compared (the re-run used one pool of 12
workers for all six entries).

## Caveats

- The six commands, their seeds and lengths, the per-set totals and the per-run values above
  come from the development log of 2026-09-27. The campaign's own output directories (each
  with `results.csv`, `results.json`, `summary.md` and one `sim.log` per run) were in
  temporary storage that was lost on 2026-09-28.
- The wall time of breaker2 (405 s) is the time between its start and end in the list of
  start and end times above; its own wall-time line was not kept. Every wall time includes
  building the simulator models and the programs.
- During the breaker command (at 22:30 EDT), `sim/top.sv` was edited (the initial values
  of the two variables of the `+trace` snoop, which prints only with `+trace`). Every
  breaker run used the simulator models built before the edit; breaker2 rebuilt them when
  it started, and the later commands used the rebuilt models. After the campaign the
  breaker set was run again on the rebuilt models: the log reports identical status and
  cycles in all 120 DUT runs, and in all 80 golden runs when compared with the earlier
  campaign of that evening (its breaker set ran from 19:13 to 19:26 EDT), which was itself
  identical to this one.
- The figures were first quoted in README.md by commit 62b0407 (2026-09-28) and moved to
  docs/VERIFICATION.md by commit 499d488.
- Correction (2026-10-01): this record was first filed as `2026-09-27_97ef211`, the base commit
  of the measured tree, against the rule of results/README.md for work not yet committed. It was
  renamed to `2026-09-27_6b19d41`; its content is unchanged apart from this note, the sentence on
  the filing under Inputs and the paths in the comparison above, which was run again after the
  rename.
