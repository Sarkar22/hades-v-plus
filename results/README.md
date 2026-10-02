# Recorded results

Every figure that the documentation of HaDes-V+ quotes, such as a test verdict, a cycle
count, a pass count or a timing slack, has a record in this folder, except the approximate,
derived and unrecorded figures listed under [Figures without a record](#figures-without-a-record). A record keeps the figure
as quoted and where it is quoted, the command that produced it, the inputs it was produced
from, the output as it was printed, and a status that says whether the figure can be re-run,
and with what. The simulations are deterministic, so a repeatable record has to be reproduced
exactly, not approximately; `make check-results` does that.

**Contents**

1. [Layout of a record](#layout-of-a-record)
2. [Status](#status)
3. [Checking the records](#checking-the-records)
4. [Adding a record](#adding-a-record)
5. [The records](#the-records)
6. [Index of quoted figures](#index-of-quoted-figures)

## Layout of a record

```text
results/<topic>/<YYYY-MM-DD>_<commit>/
```

The date is the day the result was produced, the commit the short hash of the commit it was
produced on. A historical result that was measured on work not yet committed is filed under
the commit that committed the measured tree; where that tree was never committed as such (for
example a core whose defects were fixed before the commit), under the commit it was based on.
The record says which tree was measured.

| File | Contents |
|---|---|
| `RECORD.md` | The figures exactly as quoted and where they are quoted; the status; the commands, runnable from the root of a clean clone; the base commit and the content fingerprints of the inputs (`git rev-parse <commit>:<path>`, the sha256 of files and of the program images produced); the date, the host (CPU model, hardware threads, operating system family), the tool versions, the number of parallel workers and the wall time; the output as printed; caveats |
| `meta.json` | The same, machine-readable. Every `meta.json` has `status`, `figures`, `host` and `caveats`. The records of the FreeRTOS campaigns keep the date under `run` and the base commit under `inputs`; the others have `date` and `base_commit` at the top level |
| `results.csv` | One row per run or build, where a record has several (LF line endings; those of the records of 2026-10-01 were converted from CRLF that day, with their content unchanged) |
| `inputs.sha256`, `images.sha256` | Fingerprints in the format that `sha256sum -c` checks; the paths are relative to the repository root unless the file's header says otherwise. They name the files the run used |
| `rechecked.sha256` | Where an input changed after the run, before it was committed: the changed files as committed, with which `make check-results` reproduced the record again; the header gives the date. `sha256sum -c inputs.sha256` reports those files as `FAILED`, `sha256sum -c rechecked.sha256` checks them |
| `summary.md`, `logs/`, other `.txt` files | The summary as printed, short run logs, excerpts of reports |

Paths in the records are relative to the repository root, and `build/` is the default build
directory; with `HADES_BUILD_DIR` set, read that directory instead. ELF files, simulators,
waveforms and long logs are not stored: the commands make them again.

All records so far were written on 2026-10-01, when the documentation was that of commit
03386fd: a place in the documentation given as `file:line` in a record refers to that version
(the one entry of the tests record that was updated for the app loader, to that of commit
8648288), not to the current files. The documentation has since been reorganised: the shell
and the app loader have their own guides, docs/SHELL.md and docs/APPS.md, and the summaries
that README.md held are in docs/VERIFICATION.md and docs/EXTENSIONS.md. The records are left
as they were written; the [index](#index-of-quoted-figures) below names the sections of the
current documentation.
Where a record rests on the maintainer's development log, it gives the date of the log; the
log itself is not part of the repository.

## Status

| Status | Meaning | Re-run with |
|---|---|---|
| repeatable | A command reproduces the figure exactly. Wall times and simulation speeds quoted with it are recorded too, but they depend on the host and its load and are never compared. | `make check-results` |
| needs formal tools | Repeatable once the formal tools of [formal/README.md](../formal/README.md#tools) are installed. They were not installed where the record was written, so the record keeps the earlier run of record. | `make check-results CHECK_ARGS=formal` |
| needs Vivado | Repeatable with Vivado 2024.2 from a checkout of the record's commit; not repeated for the record. | `make synthesis` at that commit |
| historical | Cannot be re-run: the program, the tree or the report no longer exists, or the result was made outside the repository. This includes a build that could be repeated (with Vivado, for example) but whose original output was not kept, or kept only in part: the figure is that of the original build, and a rebuild would make a new record. The record keeps what is known and where it comes from. | — |

Four topics have both a historical record of the first measurement and a repeatable record
that reproduces exactly everything that survives of it: `zba`, `m-unit-cycles`,
`fencei-window` and `freertos-campaign` (for the campaign of 2026-09-27, the run counts, the
per-set totals, and the 37 exact and 14 rounded per-run values that the development log keeps).

## Checking the records

```bash
make check-results                                    # the eight default checks, 6 to 14 minutes
make check-results CHECK_ARGS=--list                  # the checks and the record each one uses
make check-results CHECK_ARGS='zba trapsweep'         # only these checks
make check-results CHECK_ARGS='--campaign --jobs 12'  # also the 794-run campaign, about 80 minutes
make check-results CHECK_ARGS=bitmanip-long           # ext-exhaustive and the bitmanip campaign, about 30 minutes
sh results/check.sh --jobs 12 freertos-campaign       # the script itself, without make
```

[`check.sh`](check.sh) runs the commands of each record in the repository root, builds into the
build directory (`build/`, or `$HADES_BUILD_DIR`), and compares what they print with the values
stored in the newest record of the topic whose status is *repeatable* (*needs formal tools*
for `formal`). The times above are for a machine on which the simulators are already built;
they depend on its load.

| Check | Runs | Compares with the record |
|---|---|---|
| `zba` | `make bench-zba` at `-O2`, `-Os` and `-O0` | the three summaries, the 24 run logs and the sha256 of the 48 program files |
| `zbb` | `make bench-zbb` at `-O2`, `-Os` and `-O0` | the three summaries, the 30 run logs and the sha256 of the 60 program files |
| `m-unit-cycles` | `make bench-mcost` | the summary, the 6 run logs, the sha256 of the 7 program files |
| `fencei-window` | `make bench-fencei-window` | the summary, the 2 run logs, the sha256 of the 2 program files |
| `tests` | the 55 commands of the tests record | the recorded output lines and exit status of each command, the 67 differing checks of the golden-comparison benches, the sha256 of the 33 program images |
| `trapsweep` | `sweep.py list`, `sweep.py run` and the four fuzz sets | the verdict lines, the table of the 61 programs, the 28 flagged programs and 129 flagged probe lines, the 190 fuzz programs |
| `freertos-validate` | the campaign of `make freertos-stress`, with `--compare` | every deterministic column of the 28 runs |
| `bitmanip` | the 11 commands of the bitmanip record: the five assembly tests, `test_ext_execute`, `make ext-check`, fuzz variant b (1,000 programs), the `ext` probe family, and the loader's `session-ext.txt` on both CPUs | the recorded output lines and exit status of each command, and the per-program tables of the fuzz set (1,000 programs) and the probe family (3) |
| `bitmanip-long` | only by name: `make ext-exhaustive` and `campaign.py --set bitmanip --seeds 8`, with `--compare` | the 31 lines of `ext-exhaustive`; every deterministic column of the 120 campaign runs |
| `freertos-campaign` | only with `--campaign` or by name: `--suite sep2026 --wall-limit 0`, with `--compare` | every deterministic column of the 1317 runs |
| `formal` | only with `--formal` or by name: `make formal` | the summary lines of the run of record; without the tools, the check reports `NOT RUN` |

Wall times are never compared. The script first prints the tool versions and whether the
simulated hardware, the C runtime and the FreeRTOS sources still match the records' base
commit: after a change to any of them a difference is expected, and the result needs a new
record. It ends with one line, `CHECK RESULTS: PASS` or `CHECK RESULTS: FAIL` with the checks
that differ or could not be run, and exits with status 0 only for `PASS`; the commands' logs
are in `check-results/` of the build directory. `--jobs N` sets the number of parallel
simulations of the trap sweep and the campaigns (default 4). Interrupted, for example with
Ctrl-C, the script stops the command it is running with everything that command started, and
ends with `CHECK RESULTS: FAIL (interrupted)`. `--campaign` and `--formal` add their check to
the checks named, or to the default ones. The `tests` check creates
`test/freertos/myapp/` for one command, as
[docs/FREERTOS.md](../docs/FREERTOS.md#8-write-and-run-your-own-program) does, and removes it
again; if a program of that name already exists, it reports that instead of running the
command. Before a FreeRTOS command whose recorded output includes the program's size line, it
removes that program's ELF from the build directory, so that the command links the program
again and prints the line.

## Adding a record

A new result gets a new directory in the format above; an existing record is not changed,
except to correct it, and a correction is stated in the record. `campaign.py --record DIR`
writes the record of a FreeRTOS campaign
([test/freertos/README.md](../test/freertos/README.md#differential-campaign)); the other
records are written by hand. When a quoted figure changes, the documentation and the
[index](#index-of-quoted-figures) name the new record, and `check.sh` compares with it
because it is the newest of its topic. A record's fingerprints are those of the files its run
used. If one of those files changes before it is committed, the record keeps the old
fingerprint, and a re-run with the changed file that reproduces the record exactly is listed,
with its date, in `rechecked.sha256`; check the fingerprints again just before a commit.

## The records

| Record | Status | What it holds |
|---|---|---|
| [tests/2026-10-01_03386fd](tests/2026-10-01_03386fd/RECORD.md) | repeatable | Every self-checking suite of docs/VERIFICATION.md and the FreeRTOS figures of docs/FREERTOS.md and docs/SHELL.md: 55 commands with their output, the 67 differing checks of the golden-comparison benches, the sha256 of 33 program images |
| [trapsweep/2026-10-01_03386fd](trapsweep/2026-10-01_03386fd/RECORD.md) | repeatable | `sweep.py run` and the four fuzz sets: HaDes-V+ 61/61, golden CPU 25/51, every flagged probe |
| [freertos-validate/2026-10-01_03386fd](freertos-validate/2026-10-01_03386fd/RECORD.md) | repeatable | `make freertos-stress`: 28 runs |
| [freertos-campaign/2026-10-01_03386fd](freertos-campaign/2026-10-01_03386fd/RECORD.md) | repeatable | The suite `sep2026`: 794 runs on HaDes-V+ and 523 on the golden CPU, a re-run of the campaign of 2026-09-27 |
| [freertos-campaign/2026-09-27_6b19d41](freertos-campaign/2026-09-27_6b19d41/RECORD.md) | historical | The campaign of 2026-09-27 that docs/VERIFICATION.md quotes, reproduced by the record above; run on a tree based on 97ef211 and committed as 0d25ee6 and 6b19d41 |
| [zba/2026-10-01_03386fd](zba/2026-10-01_03386fd/RECORD.md) | repeatable | `make bench-zba` at `-O2`, `-Os` and `-O0` |
| [zbb/2026-10-02_e75223e](zbb/2026-10-02_e75223e/RECORD.md) | repeatable | `make bench-zbb` at `-O2`, `-Os` and `-O0`: Zbb, Zbs and Zicond against plain RV32I |
| [bitmanip/2026-10-02_e75223e](bitmanip/2026-10-02_e75223e/RECORD.md) | repeatable | The tests of Zbb, Zbs and Zicond: assembly tests, the Execute bench, the RTL against the C model (quick, and over all 2^32 inputs of the one-operand instructions), random programs, the `ext` probe family, the app `bitmanip`, the campaign set `bitmanip`; and, historical, the mutation testing |
| [zba/2026-08-18_1f501f5](zba/2026-08-18_1f501f5/RECORD.md) | historical | The first measurement of the Zba figures |
| [m-unit-cycles/2026-10-01_03386fd](m-unit-cycles/2026-10-01_03386fd/RECORD.md) | repeatable | `make bench-mcost`: the cycles of each M instruction |
| [m-unit-cycles/2026-08-18_c00c4db](m-unit-cycles/2026-08-18_c00c4db/RECORD.md) | historical | The first measurement of those cycles |
| [fencei-window/2026-10-01_03386fd](fencei-window/2026-10-01_03386fd/RECORD.md) | repeatable | `make bench-fencei-window`: the instructions that run stale after a store patches them |
| [fencei-window/2026-08-17_15b0b85](fencei-window/2026-08-17_15b0b85/RECORD.md) | historical | The first measurement of that window |
| [formal/2026-09-28_588d76a](formal/2026-09-28_588d76a/RECORD.md) | needs formal tools | The run of record of `make formal` and `make formal-full` |
| [fpga-timing/2026-09-30_cbae9b9](fpga-timing/2026-09-30_cbae9b9/RECORD.md) | needs Vivado | WNS +0.016 ns at commit cbae9b9, with report excerpts |
| [fpga-timing/2026-08-18_c00c4db](fpga-timing/2026-08-18_c00c4db/RECORD.md) | historical | WNS −0.120 ns when M was added, +0.026 ns at the commit before |
| [fpga-timing/2026-08-17_15b0b85](fpga-timing/2026-08-17_15b0b85/RECORD.md) | historical | WNS +0.221 ns, the bitstream with the branch predictor |
| [fpga-timing/2026-06-13_9fd9b18](fpga-timing/2026-06-13_9fd9b18/RECORD.md) | historical | WNS +0.242 ns, the baseline bitstream |
| [history/2026-06-27_9fd9b18](history/2026-06-27_9fd9b18/RECORD.md) | historical | Full marks, 56/56, in the RISC-V Community Challenge |
| [history/2026-08-17_15b0b85](history/2026-08-17_15b0b85/RECORD.md) | historical | The two bitstreams in `bitstream/` |
| [history/2026-08-18_1f501f5](history/2026-08-18_1f501f5/RECORD.md) | historical | The mutation counts of the Zba tests (commit message only) |
| [history/2026-08-18_c00c4db](history/2026-08-18_c00c4db/RECORD.md) | historical | 20 flushes of the `div.s` sweep on an unfinished divide |
| [history/2026-09-26_97ef211](history/2026-09-26_97ef211/RECORD.md) | historical | A tick-synchronised demo that ran more than 5,000 ticks on a defective core, according to the development log (not verifiable) |
| [history/2026-09-27_6b19d41](history/2026-09-27_6b19d41/RECORD.md) | historical | The six trap and interrupt defects: how they were found, and each fix reverted on its own |
| [history/2026-09-27_97ef211](history/2026-09-27_97ef211/RECORD.md) | historical | The golden CPU failing 3 of 12 seeds of the full demo with time slicing off |
| [history/2026-09-30_6bf71d4](history/2026-09-30_6bf71d4/RECORD.md) | historical | How the vendored FreeRTOS file set was determined: 239 configurations, 64 files |

## Index of quoted figures

Every figure quoted in [README.md](../README.md), the documents in [docs/](../docs),
[formal/README.md](../formal/README.md), the READMEs in [test/](../test) and
[third_party/freertos/README.md](../third_party/freertos/README.md), with the record that
holds it. Not listed are constants and parameters read from the sources (the memory map,
CSR addresses, widths, default settings, the cases a test program is written to cover) and
example commands.

### Test suites and programs

| Figure as quoted | Quoted in | Record | Status |
|---|---|---|---|
| `All tests passed! (# Errors: 1 = initial test)` for the assembly programs; three `Test pass!` lines for `bpred.s` | VERIFICATION.md [Verification at a Glance](../docs/VERIFICATION.md#verification-at-a-glance), [Programs on the Complete Core](../docs/VERIFICATION.md#programs-on-the-complete-core) | [tests](tests/2026-10-01_03386fd/RECORD.md) | repeatable |
| 11,026 checks against the golden Decode stage | README.md [Verification in Depth](../README.md#verification-in-depth); docs/README.md [First Commands](../docs/README.md#first-commands); VERIFICATION.md [Verification at a Glance](../docs/VERIFICATION.md#verification-at-a-glance), [Module Benches](../docs/VERIFICATION.md#module-benches) | [tests](tests/2026-10-01_03386fd/RECORD.md) | repeatable |
| 86 checks of `test_decode_compare`; `test_decode_hazard` passes | VERIFICATION.md [Module Benches](../docs/VERIFICATION.md#module-benches) | [tests](tests/2026-10-01_03386fd/RECORD.md) | repeatable |
| 486,896 decoder-sweep checks, of them 150,000 random words (290,288 before the Zbb, Zbs and Zicond sweeps) | README.md [Verification in Depth](../README.md#verification-in-depth); VERIFICATION.md [Verification at a Glance](../docs/VERIFICATION.md#verification-at-a-glance), [Module Benches](../docs/VERIFICATION.md#module-benches); EXTENSIONS.md M [Verification](../docs/EXTENSIONS.md#verification), Zba [Verification](../docs/EXTENSIONS.md#verification-1) | [tests](tests/2026-10-01_03386fd/RECORD.md) | repeatable |
| 6,268 checks of the M unit and its stall protocol | VERIFICATION.md [Verification at a Glance](../docs/VERIFICATION.md#verification-at-a-glance), [Module Benches](../docs/VERIFICATION.md#module-benches); EXTENSIONS.md M [Verification](../docs/EXTENSIONS.md#verification) | [tests](tests/2026-10-01_03386fd/RECORD.md) | repeatable |
| 40,000 next-PC checks over 20,000 random branches | VERIFICATION.md [Module Benches](../docs/VERIFICATION.md#module-benches); EXTENSIONS.md branch predictor [Verification](../docs/EXTENSIONS.md#verification-4) | [tests](tests/2026-10-01_03386fd/RECORD.md) | repeatable |
| The baselines 30 of 142, 6 of 98, 7 of 111 and 24 of 51 differing checks | VERIFICATION.md [Module Benches](../docs/VERIFICATION.md#module-benches), [Module-Bench Baselines](../docs/VERIFICATION.md#module-bench-baselines) | [tests](tests/2026-10-01_03386fd/RECORD.md), every check in [baseline-diffs.txt](tests/2026-10-01_03386fd/baseline-diffs.txt) | repeatable |
| `M-EXT PASS` after 200 checks against libgcc | VERIFICATION.md [Verification at a Glance](../docs/VERIFICATION.md#verification-at-a-glance), [Programs on the Complete Core](../docs/VERIFICATION.md#programs-on-the-complete-core); EXTENSIONS.md M [Verification](../docs/EXTENSIONS.md#verification) | [tests](tests/2026-10-01_03386fd/RECORD.md) | repeatable |
| `zba.s` with 62 assertions and `zbaadv.s` with 103 | EXTENSIONS.md Zba [Verification](../docs/EXTENSIONS.md#verification-1) | [tests](tests/2026-10-01_03386fd/RECORD.md) | repeatable |
| `zicntr.s`: the 36 write forms trap with `mcause=2`, the 24 read forms succeed | EXTENSIONS.md Zicntr [Verification](../docs/EXTENSIONS.md#verification-2) | [tests](tests/2026-10-01_03386fd/RECORD.md) | repeatable |
| `bpred.s` tests A, B and C; `bpirq.s` over modes 0–3 × delays 1–80, `bpirq2.s` over modes 0–3 × delays 1–32 × three shapes, `bpirq3.s` | EXTENSIONS.md branch predictor [Verification](../docs/EXTENSIONS.md#verification-4) | [tests](tests/2026-10-01_03386fd/RECORD.md) | repeatable |
| `op::t` still 6 bits and `instruction::t` 65 bits; 61 of 64 codes used after M, 62 with `EXT` = 61; `ILLEGAL` kept at 49 | EXTENSIONS.md M [Implementation Notes](../docs/EXTENSIONS.md#implementation-notes), Zba [Implementation Notes](../docs/EXTENSIONS.md#implementation-notes-1) | [tests](tests/2026-10-01_03386fd/RECORD.md) | repeatable |
| The programs and benches without a verdict of their own; `test_example` does not build with Verilator 5.042 | VERIFICATION.md [System Level](../docs/VERIFICATION.md#system-level) | [tests](tests/2026-10-01_03386fd/RECORD.md) | repeatable |
| `make test/c/bootloader`: `INFO: Bootloader started!`, then `Simulation timeout!` | VERIFICATION.md [Programs on the Complete Core](../docs/VERIFICATION.md#programs-on-the-complete-core) | [tests](tests/2026-10-01_03386fd/RECORD.md) | repeatable |
| The tool versions tested: Verilator 5.042, GCC 12.2.0, binutils 2.39, Python 3.12, GNU Make 4.3, git 2.43 | README.md [Quick Start](../README.md#quick-start); BUILDING.md [Tools and Dependencies](../docs/BUILDING.md#tools-and-dependencies); FREERTOS.md [Prerequisites](../docs/FREERTOS.md#1-prerequisites); VERIFICATION.md [Suites and Results](../docs/VERIFICATION.md#suites-and-results); EXTENSIONS.md [Zba](../docs/EXTENSIONS.md#zba--scaled-index-address-generation) (GCC 12), Zicntr [Implementation Notes](../docs/EXTENSIONS.md#implementation-notes-2) (binutils 2.39) | [tests](tests/2026-10-01_03386fd/RECORD.md) (Environment) | repeatable |

### FreeRTOS

| Figure as quoted | Quoted in | Record | Status |
|---|---|---|---|
| `make freertos APP=minimal`: `cycles=3169254`, about 3.2 million cycles in about two seconds, 15808 bytes, the seed, tick and result lines, `(224280 ps) Test fail!`, `(63414400 ps) Test pass!` | VERIFICATION.md [System Level](../docs/VERIFICATION.md#system-level); FREERTOS.md [3](../docs/FREERTOS.md#3-boot-freertos), [4](../docs/FREERTOS.md#4-what-the-output-means) | [tests](tests/2026-10-01_03386fd/RECORD.md) | repeatable |
| `make freertos APP=stress`: `cycles=5156655`, about 5 million cycles in a few seconds | VERIFICATION.md [System Level](../docs/VERIFICATION.md#system-level); FREERTOS.md [6](../docs/FREERTOS.md#6-run-the-stress-tests) | [tests](tests/2026-10-01_03386fd/RECORD.md) | repeatable |
| `make freertos APP=mzba MARCH=rv32im_zba`: `cycles=5637099` | VERIFICATION.md [System Level](../docs/VERIFICATION.md#system-level) | [tests](tests/2026-10-01_03386fd/RECORD.md) | repeatable |
| `make freertos APP=full`: `PASS` after 150,681,199 cycles, in 256 KiB of RAM | README.md [FreeRTOS with a Live Shell](../README.md#freertos-with-a-live-shell), [Status and Limitations](../README.md#status-and-limitations); VERIFICATION.md [Verification at a Glance](../docs/VERIFICATION.md#verification-at-a-glance), [System Level](../docs/VERIFICATION.md#system-level); test/freertos/README.md [Programs](../test/freertos/README.md#programs) | [tests](tests/2026-10-01_03386fd/RECORD.md) | repeatable |
| `AGREE`: 5156380 cycles on HaDes-V+, 5155907 on the golden CPU (`stress`, `SEED=7`) | VERIFICATION.md [System Level](../docs/VERIFICATION.md#system-level) | [tests](tests/2026-10-01_03386fd/RECORD.md) | repeatable |
| 3169254 and 3169246 cycles (`minimal` on both CPUs) | FREERTOS.md [5](../docs/FREERTOS.md#5-compare-with-the-golden-cpu) | [tests](tests/2026-10-01_03386fd/RECORD.md) | repeatable |
| `REBUILD CHECK: PASS (8 runs, ...)`, in 15–30 s | VERIFICATION.md [System Level](../docs/VERIFICATION.md#system-level); FREERTOS.md [7](../docs/FREERTOS.md#7-the-branch-predictor-and-changing-a-setting); test/freertos/README.md [One program, one configuration](../test/freertos/README.md#one-program-one-configuration) | [tests](tests/2026-10-01_03386fd/RECORD.md) (16.6 s) | repeatable |
| The scripted shell session: `cycles=2278845`, 39 command lines, 120 of 120 expectations (121 on the golden CPU); `(195860 ps) Test fail!`; the heap and RAM lines of `mem`; `div -7 2`; the image fits 32 KiB at `-Os`, with about 1.6 KiB to spare | VERIFICATION.md [Verification at a Glance](../docs/VERIFICATION.md#verification-at-a-glance), [System Level](../docs/VERIFICATION.md#system-level); SHELL.md [Start it](../docs/SHELL.md#start-it), [The commands](../docs/SHELL.md#the-commands), [Scripted sessions](../docs/SHELL.md#scripted-sessions-and-the-tests), [How it works](../docs/SHELL.md#how-it-works), [Add a command](../docs/SHELL.md#add-a-command); test/freertos/README.md [Programs](../test/freertos/README.md#programs) | [tests](tests/2026-10-01_03386fd/RECORD.md) | repeatable |
| `SHELL COMPARE: SAME  40 blocks, 158 lines equal after normalising numbers` | VERIFICATION.md [Verification at a Glance](../docs/VERIFICATION.md#verification-at-a-glance), [System Level](../docs/VERIFICATION.md#system-level); SHELL.md [Scripted sessions](../docs/SHELL.md#scripted-sessions-and-the-tests) | [tests](tests/2026-10-01_03386fd/RECORD.md) | repeatable |
| `TTY TEST: PASS  (22 of 22 cases passed)`; 13 lines pasted at once | VERIFICATION.md [System Level](../docs/VERIFICATION.md#system-level); SHELL.md [Scripted sessions](../docs/SHELL.md#scripted-sessions-and-the-tests) | [tests](tests/2026-10-01_03386fd/RECORD.md) | repeatable |
| The template with its interrupt: `PASS` after 20 items, `external interrupts 128` | FREERTOS.md [8](../docs/FREERTOS.md#8-write-and-run-your-own-program) | [tests](tests/2026-10-01_03386fd/RECORD.md) | repeatable |
| The program list of `make freertos-list`; `SET=standard` runs 55 configurations | FREERTOS.md [3](../docs/FREERTOS.md#3-boot-freertos), [6](../docs/FREERTOS.md#6-run-the-stress-tests) | [tests](tests/2026-10-01_03386fd/RECORD.md) | repeatable |
| The vendored sources: 76 files, 2,091,517 bytes; 35 and 41 files; all 21 kernel headers; 18 demo sources and 18 headers | third_party/freertos/README.md [Files](../third_party/freertos/README.md#files) | [tests](tests/2026-10-01_03386fd/RECORD.md) | repeatable |
| The file set from 239 configurations: 64 files used, the other 12; 14 of the 21 kernel headers included | third_party/freertos/README.md [Files](../third_party/freertos/README.md#files) | [history/2026-09-30_6bf71d4](history/2026-09-30_6bf71d4/RECORD.md) | historical |
| `make freertos-stress`: 28 of 28 runs `PASS`, 14/14 on each CPU, the table of the 28 runs; seven configurations, a 64 KiB variant for `-O0`; about a minute | VERIFICATION.md [Verification at a Glance](../docs/VERIFICATION.md#verification-at-a-glance), [System Level](../docs/VERIFICATION.md#system-level), [The Validation Campaign](../docs/VERIFICATION.md#the-validation-campaign); FREERTOS.md [6](../docs/FREERTOS.md#6-run-the-stress-tests) | [freertos-validate](freertos-validate/2026-10-01_03386fd/RECORD.md) (36.5 s with 4 workers) | repeatable |
| 794 of 794 runs, 102 of them with the branch predictor on, about 14.7 billion cycles, 523 golden twin runs; 754 distinct runs; about 80 minutes with 12 workers | README.md [Verification in Depth](../README.md#verification-in-depth); VERIFICATION.md [FreeRTOS Differential Campaigns](../docs/VERIFICATION.md#freertos-differential-campaigns); FREERTOS.md [6](../docs/FREERTOS.md#6-run-the-stress-tests); test/freertos/README.md [Differential campaign](../test/freertos/README.md#differential-campaign) | [freertos-campaign](freertos-campaign/2026-10-01_03386fd/RECORD.md), and the campaign of 2026-09-27: [freertos-campaign/2026-09-27_6b19d41](freertos-campaign/2026-09-27_6b19d41/RECORD.md) | repeatable |
| The golden CPU failed 3 of 12 seeds of the full demo with time slicing off | test/freertos/README.md [Programs](../test/freertos/README.md#programs) | [history/2026-09-27_97ef211](history/2026-09-27_97ef211/RECORD.md) | historical |
| A tick-synchronised demo ran more than 5,000 ticks on a core with three of the defects, according to the development log | VERIFICATION.md [FreeRTOS Differential Campaigns](../docs/VERIFICATION.md#freertos-differential-campaigns) | [history/2026-09-26_97ef211](history/2026-09-26_97ef211/RECORD.md) (the run was not kept; not verifiable) | historical |

### Trap and interrupt sweep

| Figure as quoted | Quoted in | Record | Status |
|---|---|---|---|
| HaDes-V+ 61/61 programs consistent, golden CPU 25/51; 25 of the 26 golden failures explained by its known deviations, the 26th, `race_ext_0`, by the expected `race` flag | README.md [Verification in Depth](../README.md#verification-in-depth); VERIFICATION.md [Verification at a Glance](../docs/VERIFICATION.md#verification-at-a-glance), [System Level](../docs/VERIFICATION.md#system-level), [Trap and Interrupt Sweep](../docs/VERIFICATION.md#trap-and-interrupt-sweep); test/trapsweep/README.md [Provenance and results](../test/trapsweep/README.md#provenance-and-results) | [trapsweep](trapsweep/2026-10-01_03386fd/RECORD.md) | repeatable |
| 574 probes in 15 families, 532 of them distinct (several hundred sequences); 15 × 15 pairs | README.md [Verification in Depth](../README.md#verification-in-depth); VERIFICATION.md [Approach](../docs/VERIFICATION.md#approach), [Test Hierarchy](../docs/VERIFICATION.md#test-hierarchy), [Trap and Interrupt Sweep](../docs/VERIFICATION.md#trap-and-interrupt-sweep); [test/trapsweep/README.md](../test/trapsweep/README.md) | [trapsweep](trapsweep/2026-10-01_03386fd/RECORD.md) | repeatable |
| The full run: 61 + 51 programs, 62,868 + 49,566 iterations, 103,639 trap entries, 13.4M + 10.3M cycles; about 20 s with 6 jobs | test/trapsweep/README.md [Running](../test/trapsweep/README.md#running) | [trapsweep](trapsweep/2026-10-01_03386fd/RECORD.md) (24.7 s with 3 jobs) | repeatable |
| The example lines: `csr_ext_0` and probe 62; probe `csrrw a1,mtvec,a0` with `k=10` and `mepc=0x45444` | test/trapsweep/README.md [Reading the summary](../test/trapsweep/README.md#reading-the-summary), [Known golden deviations](../test/trapsweep/README.md#known-golden-deviations) | [trapsweep](trapsweep/2026-10-01_03386fd/RECORD.md) | repeatable |
| The fuzz sets: `i` 60/60 and 60/60, `m` 40/40, `bp` 60/60, `mt` 30/30 and 30/30 | test/trapsweep/README.md [Provenance and results](../test/trapsweep/README.md#provenance-and-results) | [trapsweep](trapsweep/2026-10-01_03386fd/RECORD.md) | repeatable |
| The golden CPU's `CSRRWI rd, csr, 0` and old-`mtvec` deviations (the tagged probes) | VERIFICATION.md [The Frozen Golden Models](../docs/VERIFICATION.md#the-frozen-golden-models); test/trapsweep/README.md [Known golden deviations](../test/trapsweep/README.md#known-golden-deviations) | [trapsweep](trapsweep/2026-10-01_03386fd/RECORD.md) | repeatable |
| The six trap and interrupt defects, four found by FreeRTOS and two by the sweep; each fix reverted on its own fails its directed test, and the sweep gives 17/61, 46/61, 9/61, 39/61, 58/61 and 29/61; fuzz `bp` 20/60; before the `mtvec` fix 32/61 failed and fuzz `mt` 28/30 | README.md [Verification in Depth](../README.md#verification-in-depth), [Attribution and Upstream](../README.md#attribution-and-upstream); EXTENSIONS.md [What HaDes-V+ Adds](../docs/EXTENSIONS.md#what-hades-v-adds); VERIFICATION.md [Verification at a Glance](../docs/VERIFICATION.md#verification-at-a-glance), [Trap and Interrupt Sweep](../docs/VERIFICATION.md#trap-and-interrupt-sweep), [FreeRTOS Differential Campaigns](../docs/VERIFICATION.md#freertos-differential-campaigns), [Mutation Testing](../docs/VERIFICATION.md#mutation-testing); test/trapsweep/README.md [Provenance and results](../test/trapsweep/README.md#provenance-and-results) | [history/2026-09-27_6b19d41](history/2026-09-27_6b19d41/RECORD.md) | historical |

### Zba, M unit and FENCE.I

| Figure as quoted | Quoted in | Record | Status |
|---|---|---|---|
| Zba: 20.3 % fewer cycles (1.26×) at `-O2` in a best-case loop, 6–8 % smaller images, 16,704 comparisons without a discrepancy; 14.0 % at `-Os`; no Zba instruction at `-O0`; GCC emits `sh1add`/`sh2add`/`sh3add` for indexing code | README.md [An Extended CPU](../README.md#an-extended-cpu); EXTENSIONS.md [What HaDes-V+ Adds](../docs/EXTENSIONS.md#what-hades-v-adds), Zba [Verification](../docs/EXTENSIONS.md#verification-1); [test/bench/README.md](../test/bench/README.md#make-bench-zba) | [zba](zba/2026-10-01_03386fd/RECORD.md) (first measured: [zba/2026-08-18_1f501f5](zba/2026-08-18_1f501f5/RECORD.md)) | repeatable |
| M: measured 1.00, 2.00, 34.00 and 1.00 cycles over 800 back-to-back operations; a 2-cycle multiply and a 34-cycle divider; a divide by zero in one cycle rather than 34 | README.md [An Extended CPU](../README.md#an-extended-cpu); ARCHITECTURE.md [Hazards](../docs/ARCHITECTURE.md#hazards-and-how-theyre-handled); EXTENSIONS.md [What HaDes-V+ Adds](../docs/EXTENSIONS.md#what-hades-v-adds), [M](../docs/EXTENSIONS.md#m--multiply-and-divide), [Execute learns to stall](../docs/EXTENSIONS.md#execute-learns-to-stall); test/freertos/README.md [Programs](../test/freertos/README.md#programs); [test/bench/README.md](../test/bench/README.md#make-bench-mcost) | [m-unit-cycles](m-unit-cycles/2026-10-01_03386fd/RECORD.md) (first measured: [m-unit-cycles/2026-08-18_c00c4db](m-unit-cycles/2026-08-18_c00c4db/RECORD.md)) | repeatable |
| 20 of the `div.s` sweep's flushes landed on an unfinished divide | EXTENSIONS.md M [Verification](../docs/EXTENSIONS.md#verification) | [history/2026-08-18_c00c4db](history/2026-08-18_c00c4db/RECORD.md) | historical |
| `FENCE.I`: a staleness window of 3 instruction slots (`sw+4`, `sw+8`, `sw+12` stale, `sw+16` and `sw+20` fresh); 3 stall cycles in the gap do not narrow it | README.md [An Extended CPU](../README.md#an-extended-cpu); EXTENSIONS.md [What HaDes-V+ Adds](../docs/EXTENSIONS.md#what-hades-v-adds), Zifencei [Implementation Notes](../docs/EXTENSIONS.md#implementation-notes-3); [test/bench/README.md](../test/bench/README.md#make-bench-fencei-window) | [fencei-window](fencei-window/2026-10-01_03386fd/RECORD.md) (first measured: [fencei-window/2026-08-17_15b0b85](fencei-window/2026-08-17_15b0b85/RECORD.md)) | repeatable |

### Zbb, Zbs and Zicond

| Figure as quoted | Quoted in | Record | Status |
|---|---|---|---|
| Zbb and Zbs: 59.8 % fewer cycles (2.49×) at `-O2` in a best-case loop (302,330 → 121,388; 119,852 with M and Zba), image 1,636 → 904 bytes; 62.0 % at `-Os`, 27.4 % at `-O0`; 52,436 `zbb_diff` checks of the 28 forms without a mismatch; at `-O2` no `xnor` or `zext.h` in `zbb_bench` and `zbb_arr` | README.md [An Extended CPU](../README.md#an-extended-cpu); EXTENSIONS.md [What HaDes-V+ Adds](../docs/EXTENSIONS.md#what-hades-v-adds), Zbb and Zbs [Verification](../docs/EXTENSIONS.md#verification-5); VERIFICATION.md [System Level](../docs/VERIFICATION.md#system-level); [test/bench/README.md](../test/bench/README.md#make-bench-zbb) | [zbb](zbb/2026-10-02_e75223e/RECORD.md) | repeatable |
| `make ext-check`: 75 digest lines, 553,624,832 vectors identical; under a minute | VERIFICATION.md [Verification at a Glance](../docs/VERIFICATION.md#verification-at-a-glance), [System Level](../docs/VERIFICATION.md#system-level); EXTENSIONS.md Zbb and Zbs [Verification](../docs/EXTENSIONS.md#verification-5); [test/ext/README.md](../test/ext/README.md#the-check-of-the-rtl); BUILDING.md; the `make help` text | [bitmanip](bitmanip/2026-10-02_e75223e/RECORD.md) | repeatable |
| `make ext-exhaustive`: 2,091 digest lines, 34,376,492,288 vectors identical, every input of the eight one-operand instructions; about 14 minutes with 4 jobs | README.md [Verification in Depth](../README.md#verification-in-depth); VERIFICATION.md [Verification at a Glance](../docs/VERIFICATION.md#verification-at-a-glance), [System Level](../docs/VERIFICATION.md#system-level); EXTENSIONS.md Zbb and Zbs [Verification](../docs/EXTENSIONS.md#verification-5); BUILDING.md [Building, Running, and Debugging](../docs/BUILDING.md#building-running-and-debugging); [test/ext/README.md](../test/ext/README.md#the-check-of-the-rtl) | [bitmanip](bitmanip/2026-10-02_e75223e/RECORD.md) | repeatable (`bitmanip-long`) |
| `zbb.s` 442 assertions, `zbs.s` 374, `zicond.s` 190, `hints.s` 57, `zkt.s` 199; `test_ext_execute` 927,129 checks | EXTENSIONS.md Zbb and Zbs [Verification](../docs/EXTENSIONS.md#verification-5), [Implementation Notes](../docs/EXTENSIONS.md#implementation-notes-5), Zicond [Verification](../docs/EXTENSIONS.md#verification-6); VERIFICATION.md [Module Benches](../docs/VERIFICATION.md#module-benches) | [bitmanip](bitmanip/2026-10-02_e75223e/RECORD.md) | repeatable |
| Fuzz variant b: 1,000 of 1,000 programs consistent with the model; the `ext` probe family: 31 probes, 3 of 3 programs | README.md [Verification in Depth](../README.md#verification-in-depth); VERIFICATION.md [System Level](../docs/VERIFICATION.md#system-level); EXTENSIONS.md Zbb and Zbs [Verification](../docs/EXTENSIONS.md#verification-5) | [bitmanip](bitmanip/2026-10-02_e75223e/RECORD.md) | repeatable |
| The campaign set `bitmanip`: 120 of 120 runs passed; in the FreeRTOS programs GCC uses 12 of the 26 Zbb and Zbs forms, mostly `sext.b`, `zext.h`, `andn` and `bset` | VERIFICATION.md [System Level](../docs/VERIFICATION.md#system-level); EXTENSIONS.md Zbb and Zbs [Verification](../docs/EXTENSIONS.md#verification-5) | [bitmanip](bitmanip/2026-10-02_e75223e/RECORD.md) | repeatable (`bitmanip-long`) |
| The app `bitmanip`: 4 of 4 sections in both builds on HaDes-V+ and in the RV32I build on the golden CPU, all 28 forms in its `rv32im_zba_zbb_zbs` build (41 words; none in the RV32I build), its output and cycles; the refusal on the golden CPU; the `cpu:` lines of `version` | README.md [Programs Built on the PC](../README.md#programs-built-on-the-pc-loaded-and-run); APPS.md [The example apps](../docs/APPS.md#the-example-apps), [The commands](../docs/APPS.md#the-commands); VERIFICATION.md [System Level](../docs/VERIFICATION.md#system-level); EXTENSIONS.md Zbb and Zbs [Verification](../docs/EXTENSIONS.md#verification-5) | [bitmanip](bitmanip/2026-10-02_e75223e/RECORD.md) | repeatable |
| Mutation testing of the decoder and the Execute unit: every fault that changes a result caught, two equivalent faults; the faults that sweep G was added for | EXTENSIONS.md Zbb and Zbs [Verification](../docs/EXTENSIONS.md#verification-5); VERIFICATION.md [Mutation Testing](../docs/VERIFICATION.md#mutation-testing) | [bitmanip](bitmanip/2026-10-02_e75223e/RECORD.md) ([Mutation testing](bitmanip/2026-10-02_e75223e/RECORD.md#mutation-testing)) | historical |

### Formal proof

| Figure as quoted | Quoted in | Record | Status |
|---|---|---|---|
| `FORMAL RESULT: PASS (mode=default)`: 72 required checks and 4 negative controls, in 1 min 07 s | README.md [Verification in Depth](../README.md#verification-in-depth); VERIFICATION.md [Verification at a Glance](../docs/VERIFICATION.md#verification-at-a-glance), [System Level](../docs/VERIFICATION.md#system-level), [Formal Verification](../docs/VERIFICATION.md#formal-verification-of-the-m-unit); formal/README.md [4](../formal/README.md#4-results-and-runtimes) | [formal](formal/2026-09-28_588d76a/RECORD.md) | needs formal tools |
| `FORMAL RESULT: PASS (mode=full)`: 74 required checks, 4 negative controls, 20 second-solver runs, 608 mutant runs, in 24 min 33 s | VERIFICATION.md [Formal Verification](../docs/VERIFICATION.md#formal-verification-of-the-m-unit); formal/README.md [4](../formal/README.md#4-results-and-runtimes) | [formal](formal/2026-09-28_588d76a/RECORD.md) | needs formal tools |
| 19 mutants, 18 rejected, `diff32` equivalent | VERIFICATION.md [How it is built](../docs/VERIFICATION.md#how-it-is-built), [Mutation Testing](../docs/VERIFICATION.md#mutation-testing); formal/README.md [Supporting checks](../formal/README.md#supporting-checks-all-run-by-runsh), [4](../formal/README.md#4-results-and-runtimes) | [formal](formal/2026-09-28_588d76a/RECORD.md) | needs formal tools |
| All 2^64 operand pairs in every reachable state; at most 33 consecutive stall cycles | README.md [Verification in Depth](../README.md#verification-in-depth); VERIFICATION.md [Approach](../docs/VERIFICATION.md#approach), [Formal Verification](../docs/VERIFICATION.md#formal-verification-of-the-m-unit); formal/README.md [introduction](../formal/README.md), [1](../formal/README.md#1-what-is-proven), [5](../formal/README.md#5-what-is-not-proven); EXTENSIONS.md M [Implementation Notes](../docs/EXTENSIONS.md#implementation-notes) (33 stall cycles) | [formal](formal/2026-09-28_588d76a/RECORD.md) | needs formal tools |
| The checks of formal/README.md sections 3 and 4: the 33 cases of the H6 case split, of which the two negative controls make 32 and 31 `sat`; the specification check on 2,592 corner and 1,000,000 random vectors with 0 mismatches; the covers at depths 45 and 40; each check's result and time; the sv2v fidelity benches; the mutation table | formal/README.md [Lemmas](../formal/README.md#lemmas-hints), [Supporting checks](../formal/README.md#supporting-checks-all-run-by-runsh), [4](../formal/README.md#4-results-and-runtimes) | [formal](formal/2026-09-28_588d76a/RECORD.md) (the run's summary; not re-checked) | needs formal tools |
| The second solvers' gaps: bitwuzla takes more than 300 s for H8 and does not close FINAL(mul) MULH-F3 and MULHSU-F3 within 300 s; incremental engines do not close DIVF within 900 s | formal/README.md [Lemmas](../formal/README.md#lemmas-hints), [5](../formal/README.md#5-what-is-not-proven) | [formal](formal/2026-09-28_588d76a/RECORD.md) (its summary lists the 300 s time-outs of MULH-F3 and MULHSU-F3; the H8 and DIVF times are not in the record) | needs formal tools |
| The tested tools: YoWASP Yosys 0.69 with SBY and yosys-smtbmc, bitwuzla 0.9.1, Yices 2.7.0, z3 (its pip wheel reports 5.1.0), sv2v 0.0.13; without them, `FORMAL RESULT: FAIL (missing tools)` and exit status 2 | formal/README.md [5](../formal/README.md#5-what-is-not-proven), [Tools](../formal/README.md#tools) | [formal](formal/2026-09-28_588d76a/RECORD.md) (Environment; the run without the tools of 2026-09-28) | needs formal tools |
| The run times: about a minute and about 25 minutes (`make help`: a few minutes and about 35 minutes) | VERIFICATION.md [Formal Verification](../docs/VERIFICATION.md#formal-verification-of-the-m-unit); formal/README.md [introduction](../formal/README.md) | [formal](formal/2026-09-28_588d76a/RECORD.md) (1 min 07 s and 24 min 33 s; times are not compared) | needs formal tools |
| The SHA-256 of the proved `rtl/execute_stage.sv`, `847dc018…fab1bb`, that of commits 588d76a to e75223e, before Zbb, Zbs and Zicond changed the file (not re-proved since); the proof was developed against 97ef211 (`50bed4cf…5111`) | README.md [Verification in Depth](../README.md#verification-in-depth), [Status and Limitations](../README.md#status-and-limitations); VERIFICATION.md [Verification at a Glance](../docs/VERIFICATION.md#verification-at-a-glance), [System Level](../docs/VERIFICATION.md#system-level), [Formal Verification](../docs/VERIFICATION.md#formal-verification-of-the-m-unit); formal/README.md [4](../formal/README.md#4-results-and-runtimes), [9](../formal/README.md#9-history-and-independent-audits) | [formal](formal/2026-09-28_588d76a/RECORD.md) (checked with `git show e75223e:rtl/execute_stage.sv \| sha256sum` and `git show 97ef211:rtl/execute_stage.sv \| sha256sum`) | repeatable |
| `test_m_execute` detects every mutant except `diff32` (checked during development); the first 15 mutants of the development campaign | VERIFICATION.md [Mutation Testing](../docs/VERIFICATION.md#mutation-testing); formal/README.md [5](../formal/README.md#5-what-is-not-proven) | [formal](formal/2026-09-28_588d76a/RECORD.md) | historical |
| The earlier proof chain (961 s at 16 bits, more than 1 h at 20 bits, 971 s at 32 bits); the audits' 15 and 21 mutants; the latencies of the second proof and its 10^9 cycles of co-simulation | formal/README.md [9](../formal/README.md#9-history-and-independent-audits) | [formal](formal/2026-09-28_588d76a/RECORD.md) | historical |

### FPGA timing

| Figure as quoted | Quoted in | Record | Status |
|---|---|---|---|
| WNS +0.016 ns, 0 failing endpoints of 11070, Vivado 2024.2, the same result on a repeated run; the worst path from the block RAM through the branch predictor to the Fetch PC, 14 logic levels with about 53 % of the delay in logic | README.md [Status and Limitations](../README.md#status-and-limitations); BUILDING.md [Synthesis and FPGA Timing](../docs/BUILDING.md#synthesis-and-fpga-timing); EXTENSIONS.md M [Implementation Notes](../docs/EXTENSIONS.md#implementation-notes) | [fpga-timing/2026-09-30_cbae9b9](fpga-timing/2026-09-30_cbae9b9/RECORD.md) (commit cbae9b9; the current RTL has not been implemented) | needs Vivado |
| When M was added (c00c4db): WNS −0.120 ns, 2 failing endpoints of 11214, +0.026 ns at the commit before; in a second implementation of the same RTL with extra reports (WNS −1.054 ns, −0.883 ns for the parent), no M cell in the 40 worst paths, multiply +6.15 ns, divider +10.19 ns; the 21-level path to `mcause`; about 9 % more area; the 0.15 ns that M cost; the multiply's register not absorbed into the DSP48E1 | EXTENSIONS.md M [Implementation Notes](../docs/EXTENSIONS.md#implementation-notes) | [fpga-timing/2026-08-18_c00c4db](fpga-timing/2026-08-18_c00c4db/RECORD.md) | historical |
| +0.221 ns with the branch-predictor bitstream (15b0b85) | EXTENSIONS.md M [Implementation Notes](../docs/EXTENSIONS.md#implementation-notes) | [fpga-timing/2026-08-17_15b0b85](fpga-timing/2026-08-17_15b0b85/RECORD.md) | historical |
| The recorded `make synthesis` results of earlier revisions range from −0.120 ns to +0.242 ns; the same RTL with extra reporting commands ended about 1 ns lower | BUILDING.md [Synthesis and FPGA Timing](../docs/BUILDING.md#synthesis-and-fpga-timing); EXTENSIONS.md M [Implementation Notes](../docs/EXTENSIONS.md#implementation-notes) | [fpga-timing/2026-08-18_c00c4db](fpga-timing/2026-08-18_c00c4db/RECORD.md) (also the −1.054 ns and −0.883 ns runs) and [fpga-timing/2026-06-13_9fd9b18](fpga-timing/2026-06-13_9fd9b18/RECORD.md) | historical |

### History

| Figure as quoted | Quoted in | Record | Status |
|---|---|---|---|
| Full marks at every stage, 56/56, and the Bronze, Silver and Gold badges | README.md (badge), [Origin](../README.md#origin) | [history/2026-06-27_9fd9b18](history/2026-06-27_9fd9b18/RECORD.md) | historical |
| The two bitstreams in `bitstream/`, built before the extensions and the later fixes; the core has not been run on a physical board | [README.md](../README.md), [Status and Limitations](../README.md#status-and-limitations); BUILDING.md [Repository Structure](../docs/BUILDING.md#repository-structure) | [history/2026-08-17_15b0b85](history/2026-08-17_15b0b85/RECORD.md) | historical |
| The test suites are checked by mutation testing | VERIFICATION.md [Approach](../docs/VERIFICATION.md#approach) | the trap-fix reverts ([history/2026-09-27_6b19d41](history/2026-09-27_6b19d41/RECORD.md)), the formal mutants ([formal](formal/2026-09-28_588d76a/RECORD.md), status *needs formal tools*), the Zba mutants ([history/2026-08-18_1f501f5](history/2026-08-18_1f501f5/RECORD.md)) | historical |

### Figures without a record

| Figure as quoted | Quoted in | Why there is no record |
|---|---|---|
| The time of a first build: up to a minute (the shell), about 20 seconds (the core's simulator), about 15 seconds (the golden simulator), about a minute (the first YoWASP run) | README.md [Quick Start](../README.md#quick-start); FREERTOS.md [3](../docs/FREERTOS.md#3-boot-freertos), [5](../docs/FREERTOS.md#5-compare-with-the-golden-cpu); SHELL.md [Start it](../docs/SHELL.md#start-it); formal/README.md [Tools](../formal/README.md#tools) | Approximate; they depend on the host and on the compiler cache, and the records were made with cached builds |
| 30 MB of free disk space | FREERTOS.md [Prerequisites](../docs/FREERTOS.md#1-prerequisites) | An estimate of the build output |
| The Python package `rich` 13.7 | BUILDING.md [Tools and Dependencies](../docs/BUILDING.md#tools-and-dependencies) | The version that rendered the screenshots; no test uses it |
| The numbers of the example session (stack words, CPU cycles, IPC 0.541, the counters, the predictor's 82.0 %, `mtime`) and of the three screenshots | SHELL.md [The commands](../docs/SHELL.md#the-commands); [README.md](../README.md) (screenshots) | Illustrative: they depend on the moment a key is typed, as the guide says |
| About 3 half-cycles of margin for the `FENCE.I` refetch; two bubble cycles per taken branch without the predictor; up to about 34 cycles of extra interrupt latency behind a divide | EXTENSIONS.md Zifencei [table](../docs/EXTENSIONS.md#zifencei--instruction-fetch-synchronisation), [Branch Predictor Extension](../docs/EXTENSIONS.md#branch-predictor-extension), M [Implementation Notes](../docs/EXTENSIONS.md#implementation-notes) | Derived from the RTL, not measured |
| The programs pass on the golden CPU down to ticks of 500 cycles (`-O2`, `-Os`) and 1500 (`-O0`) | test/freertos/README.md [Programs](../test/freertos/README.md#programs) | Not recorded; `campaign.py --set ticksweep --golden-only` measures it again |
| About 1.6 to 1.9 million clock cycles per second | SHELL.md [Start it](../docs/SHELL.md#start-it) | A speed that depends on the host and its load, never compared. The tests record keeps one instance as printed (`walltime 87.191 s; speed 34.571 us/s` for `full`, 1.73 million cycles per second); a run on the same host under load gave 1.54 million |
| The golden CPU passes `bpirq.s`, `bpirq2.s` and `bpirq3.s` | EXTENSIONS.md branch predictor [Verification](../docs/EXTENSIONS.md#verification-4) | Observed during development, not recorded; no `make` target runs the assembly tests on the golden CPU |
| The golden CPU's `time` CSR reads 0; it reads `MHPMEVENT10` as 0 and ignores writes; its `minstret` reads one higher; it samples interrupts one cycle later | VERIFICATION.md [The Frozen Golden Models](../docs/VERIFICATION.md#the-frozen-golden-models) | Observed behaviour of the closed golden model, not recorded on its own |
| About 750 million cycles per run of the `realtick` set | test/freertos/README.md [Differential campaign](../test/freertos/README.md#differential-campaign) | An estimate; not recorded |
| The outputs of the app loader: image sizes, CRC-32 values and cycle counts of the example sessions, about one million cycles per KiB of HEX file (1.7 million for `hello`, 4.7 million for `compute`), and the verdict lines of its tests (146 of 146 expectations, 84 blocks and 292 lines) | APPS.md [Start it and run an example](../docs/APPS.md#start-it-and-run-an-example), [Write and build an app](../docs/APPS.md#write-and-build-an-app), [Send the file](../docs/APPS.md#send-the-file-terminal-pseudo-terminal-script), [The tests](../docs/APPS.md#the-tests); [README.md](../README.md) (screenshot) | From runs of this version that are not recorded, as the guide says; `make freertos-loader-compare` prints the verdict lines again, and the numbers of an interactive session depend on the moment a key is typed |
