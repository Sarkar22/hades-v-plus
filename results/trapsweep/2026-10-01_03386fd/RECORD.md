# Trap and interrupt sweep at 03386fd

`python3 test/trapsweep/sweep.py run` and the four random-program fuzz sets of
[test/trapsweep/README.md](../../../test/trapsweep/README.md), re-run from a fresh clone at commit
03386fd on 2026-10-01. Every run is checked by the independent instruction-set model `iss.py` and,
where the golden CPU applies, compared with it.

**Status: repeatable.** Every figure below was reproduced exactly; the simulations are
deterministic, and the job count changes only the wall time.

## Figures and where they are quoted

| Figure as quoted | Quoted at | This run |
|---|---|---|
| `DUT: 61/61 programs ISS-consistent` | docs/VERIFICATION.md:71,115; README.md:90 ("61 of 61 programs consistent"); test/trapsweep/README.md:170 | `DUT: 61/61 programs ISS-consistent` |
| `golden: 25/51 programs ISS-consistent (see the probe list: known golden deviations are tagged)` | docs/VERIFICATION.md:71,116; test/trapsweep/README.md:172 | the same line |
| 574 probes in 15 families, 532 distinct (`pre_i` repeats the 42 M-free probes of `pre`) | docs/VERIFICATION.md:102,108; test/trapsweep/README.md:27-28 | `sweep.py list`: 15 families, 574 probes, of which `pre_i` 42 (`pairs` 225 = 15 × 15, test/trapsweep/README.md:30) |
| 61 DUT and 51 golden programs, 62,868 + 49,566 iterations, 103,639 DUT trap entries, 13.4M + 10.3M cycles | test/trapsweep/README.md:67-69 | 61 + 51 programs; 62,868 + 49,566 iterations and 103,639 DUT trap entries (counted from the traces: iteration headers at offset 0x00, trap-entry records at offset 0x1C); 13,351,707 + 10,289,454 cycles |
| takes about 20 s with the default 6 jobs | test/trapsweep/README.md:69 | 24.7 s with 3 jobs (see Caveats) |
| `csr_ext_0 \| ... ISS[ref] groups_bad=148 ... \| DUT-vs-golden: 2205 iterations, 614 differ`; `ref probe 62 csrrwi a1,mscratch,0 (uimm=0) bad k=[1, 2, ...]` | test/trapsweep/README.md:79-80 | `csr_ext_0 \| dut:done ref:done \| ISS[dut] groups_bad=0 violations=0 notes=0 ISS[ref] groups_bad=148 violations=0 notes=0 \| DUT-vs-golden: 2205 iterations, 614 differ`; `ref probe  62 csrrwi a1,mscratch,0 (uimm=0)  bad k=[1, 2, 3, ...` |
| probe `csrrw a1,mtvec,a0`, golden `k=10` gives `mepc=0x45444` with the old handler | test/trapsweep/README.md:136-137 | `ref probe  56 csrrw a1,mtvec,a0 (->B)  bad k=[10, 27]`, `k=10 rtl: 01c:33eed 010:45444 ...` (`mepc` 0x45444, no handler-B marker) |
| DUT: only the three `race` programs carry flags | test/trapsweep/README.md:170-171 | flags only in `race_ext_0`, `race_timer_0`, `race_both_0` (`flags.txt`) |
| golden: every flagged probe is a CSRRWI-0 or `mtvec`-write probe | test/trapsweep/README.md:172-173; docs/VERIFICATION.md:119 | all 102 flagged-probe lines of the golden CPU (`ref probe ... bad k=[...]`) carry one of the two tags: 10 `golden bug: CSRRWI rd,csr,0 ...` and 92 `golden bug: an interrupt right after a retired csrw mtvec ...`. Of its 23 `ref VIOLATION` lines, 22 carry the `mtvec` tag; the remaining one is the `race` probe `sw zero,4(s11)` in `race_ext_0` (see Caveats). The other 4 of the 129 flagged probe lines in `flags.txt` (which also holds the summary lines of the 28 flagged programs) are the DUT's `race` violations |
| fuzz `i` 101-160: DUT 60/60, golden 60/60 | test/trapsweep/README.md:176 | `DUT: 60/60 programs ISS-consistent`, `golden: 60/60 programs ISS-consistent` |
| fuzz `m` 201-240: DUT 40/40 | test/trapsweep/README.md:176 | `DUT: 40/40 programs ISS-consistent` |
| fuzz `bp` 301-360: DUT 60/60 | test/trapsweep/README.md:176-177 | `DUT: 60/60 programs ISS-consistent` |
| fuzz `mt` 401-430: DUT 30/30, golden 30/30 | test/trapsweep/README.md:177 | `DUT: 30/30 programs ISS-consistent`, `golden: 30/30 programs ISS-consistent` |

The rows of the single-fix revert table (test/trapsweep/README.md:184-194) need RTL changes and
are a historical record:
[results/history/2026-09-27_6b19d41](../../history/2026-09-27_6b19d41/RECORD.md).

## Commands

From a clean clone at the repository root:

```bash
git clone <URL of this repository> hades-v-plus && cd hades-v-plus && git checkout 03386fd
python3 test/trapsweep/sweep.py list
python3 test/trapsweep/sweep.py run --jobs 3            # the documented command is the same without --jobs (6 jobs)
python3 test/trapsweep/sweep.py fuzz --seeds 101-160 --jobs 3 --out build/trapsweep/fuzz-i
python3 test/trapsweep/sweep.py fuzz --seeds 201-240 --variant m --jobs 3 --out build/trapsweep/fuzz-m
python3 test/trapsweep/sweep.py fuzz --seeds 301-360 --variant bp --jobs 3 --out build/trapsweep/fuzz-bp
python3 test/trapsweep/sweep.py fuzz --seeds 401-430 --variant mt --jobs 3 --out build/trapsweep/fuzz-mt
```

Each command exited with status 0. Output: `build/trapsweep/run/` and one directory per fuzz
set (`summary.txt`, `results.json`, per program `init.s` and `dut/sim.log`, `ref/sim.log`).

The tables of this record, `results.csv`, `flags.txt` and `fuzz.csv`, are derived from those
directories (iterations and trap entries counted from the `TRACE` lines of the logs) by
[`results/check.sh`](../../check.sh); `make check-results CHECK_ARGS=trapsweep` runs the commands
above with the same output directories, rebuilds the three tables and compares them with these
files.

Correction (2026-10-01): the fuzz commands were first written here without `--out`. All four sets
then write to `build/trapsweep/fuzz/`, each replacing the previous set's `results.json` and
`summary.txt`, so after the four commands only the `mt` set's results remain there and `fuzz.csv`
could not be made again from them. The verdict lines and the tables are the same with separate
directories.

## Inputs

Base commit `03386fdda932f4827cded26e8cfc2a2cc531b365`. Fingerprints (`git rev-parse 03386fd:<path>`):
`test/trapsweep` `c086ff7c5bb97ee8fbd223bb80d5fa9f06ed780f`, `rtl` `031b989be1f25dd20836028c5126a5b1dc562bd7`,
`lib` `f90a9a64ddc67db6642bc6654545f1509744426b`, `defines` `36f0452de823189873ca8ac79d7a662918961ad6`,
`sim` `0dad5608c126445abb808c5addd7b6e9d4df54c7`, `ref` `b1cd1eebbcd4c675f36085ebfc96416192423721`,
`test/freertos` `5cb0c42ab14390f060bd6d09bff6903020ac3432` (its `freertos.mk` builds the simulators).
The probe programs are generated by `probes.py` and the fuzz programs by `fuzz.py` from the seeds above.

## Environment

- Date: 2026-10-01.
- Host: Intel Core Ultra 7 165H, 22 threads, Linux.
- Tools: `Verilator 5.042 2025-11-02 rev v5.042`; `riscv32-unknown-elf-gcc () 12.2.0`
  (binutils 2.39); `Python 3.12.3`; `GNU Make 4.3`.
- Workers: 3 jobs (`--jobs 3`).
- Wall time: `run` 24.7 s; fuzz `i` 3.6 s, `m` 2.2 s, `bp` 3.5 s, `mt` 2.0 s; the simulators had
  been built by the FreeRTOS runs of [results/tests/2026-10-01_03386fd](../../tests/2026-10-01_03386fd/RECORD.md).

## Verbatim summary output

```text
$ python3 test/trapsweep/sweep.py run --jobs 3
61 programs, 112 simulations, 3 jobs
...
DUT: 61/61 programs ISS-consistent
golden: 25/51 programs ISS-consistent (see the probe list: known golden deviations are tagged)

$ python3 test/trapsweep/sweep.py fuzz --seeds 101-160 --jobs 3
60 programs, 120 simulations, 3 jobs
...
DUT: 60/60 programs ISS-consistent
golden: 60/60 programs ISS-consistent

$ python3 test/trapsweep/sweep.py fuzz --seeds 201-240 --variant m --jobs 3
40 programs, 40 simulations, 3 jobs
...
DUT: 40/40 programs ISS-consistent

$ python3 test/trapsweep/sweep.py fuzz --seeds 301-360 --variant bp --jobs 3
60 programs, 60 simulations, 3 jobs
...
DUT: 60/60 programs ISS-consistent

$ python3 test/trapsweep/sweep.py fuzz --seeds 401-430 --variant mt --jobs 3
30 programs, 60 simulations, 3 jobs
...
DUT: 30/30 programs ISS-consistent
golden: 30/30 programs ISS-consistent
```

## Caveats

- The documented command uses the default of 6 jobs; this run used 3, to share the machine with
  another long simulation campaign. The job count affects only the wall time (24.7 s here,
  "about 20 s" documented), not any result.
- The `race` family (test/trapsweep/README.md:118, "DUT and golden"): the DUT is flagged in all
  three `race` programs (2 violations in `race_ext_0`, 1 in `race_timer_0`, 1 in `race_both_0`); the
  golden CPU only in `race_ext_0` (1 violation, the external-interrupt probe `sw zero,4(s11)`), not
  on the timer probe. That one golden flag is the expected bounded-latency race, not one of the
  tagged golden deviations, so "every flagged probe is a CSRRWI-0 or mtvec-write probe"
  (test/trapsweep/README.md:172-173) holds for the 25 other non-consistent golden programs.
  `sweep.py` excuses the `race` family on the DUT only (`dut_ok = ok or (fam in EXPECTED ...)`,
  `ref_ok = ok`), so `race_ext_0` is one of the 26 golden programs counted as not ISS-consistent
  (`results.json`: `"dut_ok": true, "ref_ok": false`). docs/VERIFICATION.md:119 ("Every program
  the golden CPU fails is explained by its known deviations") therefore holds for 25 of the 26.
- The README's example `bad k=[1, 2, ...]` abbreviates the full list printed by the tool.
- The `bp` fuzz example of test/trapsweep/README.md:56 uses `--seeds 301-330`, its results line
  (176) the range 301-360; this record ran 301-360.

## Files

- `RECORD.md`: this file.
- `meta.json`: the same information, machine-readable.
- `results.csv`: one row per sweep program: verdicts, ISS counts, iterations, trap entries and
  cycles on both CPUs, DUT-vs-golden iterations and differences.
- `fuzz.csv`: one row per fuzz program (190 programs).
- `flags.txt`: the summary line of every flagged program and every flagged probe line, verbatim.
