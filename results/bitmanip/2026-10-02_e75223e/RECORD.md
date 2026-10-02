# Zbb, Zbs and Zicond: 2026-10-02, e75223e

**Status: repeatable.** `make check-results` (its check `bitmanip`) re-runs every command of the first part and compares the output; the long runs of the second part are repeated by `make check-results CHECK_ARGS=bitmanip-long` (about 30 minutes with 4 jobs). The mutation results of the last part are historical: they were made with scripts that are not in the repository.

The frozen golden models decode every Zbb, Zbs and Zicond instruction as illegal, so none of these results comes from them. The oracles are the models written from the ratified ISA text in [test/ext/](../../../test/ext/README.md) (`ref.py`, `ref_exh.c`) and the instruction-set model `test/trapsweep/iss.py`, the expected values in the assembly tests (computed by a separate model from the ISA text), the self-checks of the programs, and the same C program built with and without the extensions.

## The figures and where they are quoted

| Figure | Quoted in | From |
|---|---|---|
| `make ext-check`: 75 digest lines, 553,624,832 vectors, identical, `violations=0` | docs/VERIFICATION.md; docs/EXTENSIONS.md (Zbb and Zbs, Verification); test/ext/README.md | [ext-check](#make-ext-check) |
| `make ext-exhaustive`: 2,091 digest lines, 34,376,492,288 vectors, identical; about 14 minutes with 4 jobs | README.md (Verification in Depth); docs/VERIFICATION.md; docs/EXTENSIONS.md; docs/BUILDING.md; test/ext/README.md | [long runs](#long-runs) |
| `zbb.s` 442 assertions, `zbs.s` 374, `zicond.s` 190, `hints.s` 57, `zkt.s` 199 (the `Test pass!` lines plus the deliberate initial-test assertion, as for `zba.s`) | docs/EXTENSIONS.md | [assembly tests](#assembly-tests) |
| `test_ext_execute`: 927,129 checks | docs/VERIFICATION.md; docs/EXTENSIONS.md | [Execute bench](#execute-bench) |
| fuzz variant b: 1,000 of 1,000 programs consistent with the model | README.md; docs/VERIFICATION.md; docs/EXTENSIONS.md | [random programs](#random-programs-and-the-ext-probe-family) |
| the `ext` probe family: 31 probes, 3 of 3 programs consistent | docs/VERIFICATION.md; docs/EXTENSIONS.md; test/trapsweep/README.md | [random programs](#random-programs-and-the-ext-probe-family) |
| the campaign set `bitmanip`: 120 of 120 runs passed; 12 of the 26 Zbb and Zbs forms in the FreeRTOS programs, mostly `sext.b`, `zext.h`, `andn`, `bset` | docs/VERIFICATION.md; docs/EXTENSIONS.md; test/freertos/README.md | [long runs](#long-runs) |
| the app `bitmanip`: 4 of 4 sections in both builds on HaDes-V+ and in the `rv32i` build on the golden CPU, the cycles of each section | README.md; docs/APPS.md; docs/VERIFICATION.md; docs/EXTENSIONS.md | [the app](#the-app-bitmanip-in-the-loaders-session) |
| the app's `rv32im_zba_zbb_zbs` build contains all 28 forms (41 words), its `rv32i` build none | README.md; docs/APPS.md; results/README.md | [the app](#the-app-bitmanip-in-the-loaders-session) |
| every fault that changes a result is caught; two that cannot were shown equivalent | docs/EXTENSIONS.md; docs/VERIFICATION.md (Mutation Testing) | [mutation testing](#mutation-testing) |

The decoder sweep, which also covers the new encodings (486,896 checks), is recorded with the other suites in [tests/2026-10-01_03386fd](../../tests/2026-10-01_03386fd/RECORD.md).

## Commands

From the repository root (`{jobs}` is `--jobs` of `check.sh`, 4 here; `{out}` an output directory):

| Part | Command | Exit status |
|---|---|---|
| asm/zbb | `make test/asm/zbb` | 0 |
| asm/zbs | `make test/asm/zbs` | 0 |
| asm/zicond | `make test/asm/zicond` | 0 |
| asm/hints | `make test/asm/hints` | 0 |
| asm/zkt | `make test/asm/zkt` | 0 |
| sv/test_ext_execute | `make test/sv/test_ext_execute` | 0 |
| ext-check | `make ext-check` | 0 |
| fuzz b 1001-2000 | `python3 test/trapsweep/sweep.py fuzz --seeds 1001-2000 --variant b --targets dut --jobs {jobs} --out {out}` | 0 |
| sweep ext | `python3 test/trapsweep/sweep.py run --fam ext --targets dut --jobs {jobs} --out {out}` | 0 |
| loader session-ext (HaDes-V+) | `make freertos-shell-test APP=loader SCRIPT=test/freertos/loader/session-ext.txt` | 0 |
| loader session-ext (golden CPU) | `make freertos-shell-test APP=loader SCRIPT=test/freertos/loader/session-ext.txt CPU=golden` | 0 |

The stored lines of each command and the rules that select them are in [`meta.json`](meta.json) and in `bitmanip_output()` of [`check.sh`](../../check.sh). [`fuzz-b.csv`](fuzz-b.csv) and [`ext-family.csv`](ext-family.csv) hold, for every program, whether it was consistent with the model and its cycle count on HaDes-V+; `check.sh` compares them as well.

## Output

### Assembly tests

```
asm/zbb:    441 'Test pass!' lines; All tests passed! (# Errors: 1 = initial test)
asm/zbs:    373 'Test pass!' lines; All tests passed! (# Errors: 1 = initial test)
asm/zicond: 189 'Test pass!' lines; All tests passed! (# Errors: 1 = initial test)
asm/hints:  56 'Test pass!' lines; All tests passed! (# Errors: 1 = initial test)
asm/zkt:    198 'Test pass!' lines; All tests passed! (# Errors: 1 = initial test)
```

### Execute bench

```
=== 1: known answers ===
=== 2: every form on the corner set ===
=== 3: random operands ===
=== 4: pipeline protocol ===
  Checks: 927129   Errors: 0
All 927129 EXT-unit checks passed
```

### make ext-check

```
ext check (quick): the RTL (instruction_decoder -> execute_stage) against the C reference model, 28 forms, 4 jobs
  andn          2 of    2 digest lines identical,      1,069,312 vectors, violations=0  ok
  orn           2 of    2 digest lines identical,      1,069,312 vectors, violations=0  ok
  xnor          2 of    2 digest lines identical,      1,069,312 vectors, violations=0  ok
  clz           4 of    4 digest lines identical,     67,108,864 vectors, violations=0  ok
  ctz           4 of    4 digest lines identical,     67,108,864 vectors, violations=0  ok
  cpop          4 of    4 digest lines identical,     67,108,864 vectors, violations=0  ok
  max           2 of    2 digest lines identical,      1,069,312 vectors, violations=0  ok
  maxu          2 of    2 digest lines identical,      1,069,312 vectors, violations=0  ok
  min           2 of    2 digest lines identical,      1,069,312 vectors, violations=0  ok
  minu          2 of    2 digest lines identical,      1,069,312 vectors, violations=0  ok
  sext.b        4 of    4 digest lines identical,     67,108,864 vectors, violations=0  ok
  sext.h        4 of    4 digest lines identical,     67,108,864 vectors, violations=0  ok
  zext.h        4 of    4 digest lines identical,     67,108,864 vectors, violations=0  ok
  rol           3 of    3 digest lines identical,      1,073,920 vectors, violations=0  ok
  ror           3 of    3 digest lines identical,      1,073,920 vectors, violations=0  ok
  rori          1 of    1 digest lines identical,        135,680 vectors, violations=0  ok
  orc.b         4 of    4 digest lines identical,     67,108,864 vectors, violations=0  ok
  rev8          4 of    4 digest lines identical,     67,108,864 vectors, violations=0  ok
  bclr          3 of    3 digest lines identical,      1,073,920 vectors, violations=0  ok
  bclri         1 of    1 digest lines identical,        135,680 vectors, violations=0  ok
  bext          3 of    3 digest lines identical,      1,073,920 vectors, violations=0  ok
  bexti         1 of    1 digest lines identical,        135,680 vectors, violations=0  ok
  binv          3 of    3 digest lines identical,      1,073,920 vectors, violations=0  ok
  binvi         1 of    1 digest lines identical,        135,680 vectors, violations=0  ok
  bset          3 of    3 digest lines identical,      1,073,920 vectors, violations=0  ok
  bseti         1 of    1 digest lines identical,        135,680 vectors, violations=0  ok
  czero.eqz     3 of    3 digest lines identical,      1,073,408 vectors, violations=0  ok
  czero.nez     3 of    3 digest lines identical,      1,073,408 vectors, violations=0  ok
  75 digest lines, 553,624,832 vectors, violations=0
EXT CHECK: PASS (28 of 28 forms identical)
```

### Random programs and the ext probe family

```
fuzz b 1001-2000: DUT: 1000/1000 programs ISS-consistent
ext_ext_0 | dut:done | ISS[dut] groups_bad=0 violations=0 notes=0
ext_timer_0 | dut:done | ISS[dut] groups_bad=0 violations=0 notes=0
ext_both_0 | dut:done | ISS[dut] groups_bad=0 violations=0 notes=0
DUT: 3/3 programs ISS-consistent
```

The 1,000 programs of fuzz variant b mix the 28 forms (register, immediate and unary forms, `czero` as `.insn` words, dependent chains behind loads) with RV32IM, Zba, loads, stores, branches and randomly timed external and timer interrupts; 1000 of 1000 are consistent. The `ext` family (3 programs, one per interrupt source) is run only when named: its 31 probes cover every form, dependent chains, a load result used at once, M results feeding the new instructions and the reverse, `ecall`, `csrci`, `mret` and stall neighbours, use in the interrupt handler, after a taken branch, as a branch condition and as a store address, results written to `x0`, the legal edge word `0x6005D513` and seven illegal neighbours, each swept over every interrupt offset.

### The app bitmanip in the loader's session

`make freertos-shell-test APP=loader SCRIPT=test/freertos/loader/session-ext.txt`, the verdict and the transcript lines that the record keeps:

```
FREERTOS SHELL RESULT: PASS  app=loader cpu=dut isa=rv32i opt=-Os tick=10000 bpred=0 seed=0 cycles=28018784
  typed lines: 14, prompts: 14, expectations met: 34/34
loaded compute: 1048 bytes at 0x00060000, entry 0x00060040, CRC32 0x41352324
compute: trace 1093898742, quotients 1445856025, remainders 22, mulhu 198418: PASS (75838 cycles)
app: compute exited with code 0 after 139294 cycles
loaded compute: 1048 bytes at 0x00060000, entry 0x00060040, CRC32 0x41352324
cpu:       M yes, Zba yes, Zbb yes, Zbs yes, Zicntr yes, Zicond yes
loaded bitmanip: 4172 bytes at 0x00060000, entry 0x00060040, CRC32 0x31515268
bitmanip: zbb    popcount 1020, log2 1907, ctz 62, mix 5dd12d14 00203fcc 648904fb, hash 200eb485: PASS (11163 cycles)
bitmanip: bytes  rev8 bb05f113, string lengths 102: PASS (1761 cycles, C)
bitmanip: zbs    primes below 4096: 564 (sum 1070091), after toggling 1928, flags 7f6b4d42: PASS (267172 cycles)
bitmanip: zicond select b23616d0, clamp 000013b0, add-if e806a5c8: PASS (1817 cycles, C)
bitmanip: 4 of 4 sections passed
app: bitmanip exited with code 0 after 448180 cycles
loaded bitmanip: 3336 bytes at 0x00060000, entry 0x00060040, CRC32 0xa8bf5894
bitmanip: zbb    popcount 1020, log2 1907, ctz 62, mix 5dd12d14 00203fcc 648904fb, hash 200eb485: PASS (5443 cycles)
bitmanip: bytes  rev8 bb05f113, string lengths 102: PASS (331 cycles, rev8 and orc.b)
bitmanip: zbs    primes below 4096: 564 (sum 1070091), after toggling 1928, flags 7f6b4d42: PASS (209356 cycles)
bitmanip: zicond select b23616d0, clamp 000013b0, add-if e806a5c8: PASS (1612 cycles, czero)
bitmanip: 4 of 4 sections passed
app: bitmanip exited with code 0 after 385103 cycles
```

With `CPU=golden`:

```
FREERTOS SHELL RESULT: PASS  app=loader cpu=golden isa=rv32i opt=-Os tick=10000 bpred=0 seed=0 cycles=27529337
  typed lines: 14, prompts: 14, expectations met: 30/30
loaded compute: 1048 bytes at 0x00060000, entry 0x00060040, CRC32 0x41352324
error: compute was built for rv32im_zba, but this CPU has no M and no Zba
loaded compute: 1048 bytes at 0x00060000, entry 0x00060040, CRC32 0x41352324
cpu:       M no, Zba no, Zbb no, Zbs no, Zicntr no, Zicond no
loaded bitmanip: 4172 bytes at 0x00060000, entry 0x00060040, CRC32 0x31515268
bitmanip: zbb    popcount 1020, log2 1907, ctz 62, mix 5dd12d14 00203fcc 648904fb, hash 200eb485: PASS (11161 cycles)
bitmanip: bytes  rev8 bb05f113, string lengths 102: PASS (1753 cycles, C)
bitmanip: zbs    primes below 4096: 564 (sum 1070091), after toggling 1928, flags 7f6b4d42: PASS (267153 cycles)
bitmanip: zicond select b23616d0, clamp 000013b0, add-if e806a5c8: PASS (1817 cycles, C)
bitmanip: 4 of 4 sections passed
app: bitmanip exited with code 0 after 448136 cycles
loaded bitmanip: 3336 bytes at 0x00060000, entry 0x00060040, CRC32 0xa8bf5894
error: bitmanip was built for rv32im_zba_zbb_zbs, but this CPU has no M, no Zba, no Zbb and no Zbs
```

The Zbb, Zbs and Zicond instruction words in the code of the two builds that the session loads, per form: every word of the SDK's disassembly (`objdump -d` of the ELF, `build/test/freertos/sdk/<march>/bitmanip.dis`) matched against the MATCH/MASK table `EXT_FORMS` of [`test/bench/bench.py`](../../../test/bench/bench.py), as `make bench-zbb` counts them. The `czero` words are written as `.insn` and counted by their encoding. `check.sh` recounts both builds after the session (`app_forms` in [`meta.json`](meta.json)):

```
bitmanip-rv32im_zba_zbb_zbs   41 words, 28 forms: andn=2 orn=1 xnor=1 clz=1 ctz=2 cpop=1 max=1 maxu=1 min=1 minu=1 sext.b=1 sext.h=1 zext.h=1 rol=1 ror=1 rori=1 orc.b=2 rev8=1 bclr=2 bclri=1 bext=3 bexti=1 binv=1 binvi=1 bset=3 bseti=1 czero.eqz=4 czero.nez=3
bitmanip-rv32i                 0 words,  0 forms: -
```

## Long runs

`make ext-exhaustive` (wall time 835 s with 4 jobs):

```
ext check (exhaustive): the RTL (instruction_decoder -> execute_stage) against the C reference model, 28 forms, 4 jobs
  andn          2 of    2 digest lines identical,      1,069,312 vectors, violations=0  ok
  orn           2 of    2 digest lines identical,      1,069,312 vectors, violations=0  ok
  xnor          2 of    2 digest lines identical,      1,069,312 vectors, violations=0  ok
  clz         256 of  256 digest lines identical,  4,294,967,296 vectors, violations=0  ok
  ctz         256 of  256 digest lines identical,  4,294,967,296 vectors, violations=0  ok
  cpop        256 of  256 digest lines identical,  4,294,967,296 vectors, violations=0  ok
  max           2 of    2 digest lines identical,      1,069,312 vectors, violations=0  ok
  maxu          2 of    2 digest lines identical,      1,069,312 vectors, violations=0  ok
  min           2 of    2 digest lines identical,      1,069,312 vectors, violations=0  ok
  minu          2 of    2 digest lines identical,      1,069,312 vectors, violations=0  ok
  sext.b      256 of  256 digest lines identical,  4,294,967,296 vectors, violations=0  ok
  sext.h      256 of  256 digest lines identical,  4,294,967,296 vectors, violations=0  ok
  zext.h      256 of  256 digest lines identical,  4,294,967,296 vectors, violations=0  ok
  rol           3 of    3 digest lines identical,      1,073,920 vectors, violations=0  ok
  ror           3 of    3 digest lines identical,      1,073,920 vectors, violations=0  ok
  rori          1 of    1 digest lines identical,        135,680 vectors, violations=0  ok
  orc.b       256 of  256 digest lines identical,  4,294,967,296 vectors, violations=0  ok
  rev8        256 of  256 digest lines identical,  4,294,967,296 vectors, violations=0  ok
  bclr          3 of    3 digest lines identical,      1,073,920 vectors, violations=0  ok
  bclri         1 of    1 digest lines identical,        135,680 vectors, violations=0  ok
  bext          3 of    3 digest lines identical,      1,073,920 vectors, violations=0  ok
  bexti         1 of    1 digest lines identical,        135,680 vectors, violations=0  ok
  binv          3 of    3 digest lines identical,      1,073,920 vectors, violations=0  ok
  binvi         1 of    1 digest lines identical,        135,680 vectors, violations=0  ok
  bset          3 of    3 digest lines identical,      1,073,920 vectors, violations=0  ok
  bseti         1 of    1 digest lines identical,        135,680 vectors, violations=0  ok
  czero.eqz     3 of    3 digest lines identical,      1,073,408 vectors, violations=0  ok
  czero.nez     3 of    3 digest lines identical,      1,073,408 vectors, violations=0  ok
  2091 digest lines, 34,376,492,288 vectors, violations=0
EXT CHECK: PASS (28 of 28 forms identical)
```

`python3 test/freertos/campaign.py --set bitmanip --seeds 8 --jobs 4` (wall time 645 s), HaDes-V+ only (the golden CPU has none of the extensions; the oracle is the programs' own self-checks):

```
CAMPAIGN RESULT: PASS (120 runs: 0 DUT run(s) not passed, 0 golden run(s) not passed, 0 build failure(s))
```

[`campaign.csv`](campaign.csv) holds the 120 runs (`check.sh` compares every deterministic column with `--compare`). The 15 variants build `minimal`, `stress` (also without yields), `mzba`, `full` and `brk` for `rv32im_zba_zbb_zbs` (`brk` for `rv32im_zba_zbb`: with Zbs, GCC 12.2 stops with an internal compiler error on its `prvFenceI()`), at `-O2`, `-Os` and `-O0`, with preemption and the branch predictor varied. [`campaign-forms.csv`](campaign-forms.csv) counts, per program image, the Zbb and Zbs instructions that GCC chose:

```
all images: 323 words, 12 forms: andn=31 clz=2 maxu=25 minu=22 sext.b=130 sext.h=13 zext.h=47 rol=4 bclr=12 bexti=2 bset=31 bseti=4
```

## Mutation testing

**Historical.** During development, hand-written faults were applied, each on its own, to a copy of the RTL, and the suites were run on each copy. The scripts were outside the repository, so this part cannot be re-run from it.

- **22 faults of the test plan** (decoder and Execute; for example: the immediate forms accept `shamt[5] = 1`, `zext.h` ignores a non-zero rs2 field, `clmul` decoded, `use_imm` not set for `bclri`, the shift amount taken from the wrong bits, `rol` computed as `ror`, `clz(0) = 31`, `ctz` without the bit reversal, `cpop` drops bit 31, `minu` signed, `min` and `max` swapped, `sext.h` extends bit 7, `orc.b` as an AND, `rev8` reverses bits, `czero` polarity swapped or testing rs1, `bext` without the shift, `andn` with its operands swapped, the result not forwarded, the result taken from the M unit, rd forced to 0): all 22 were caught by the decoder sweep, `test_ext_execute`, the harness against a C model, or `zbb.s`/`zbs.s`/`zicond.s`. The one that changes no result (the result not forwarded from Execute, so dependent instructions stall) is caught by `test_ext_execute`, the harness's `violations` count and the cycle-exact chains of the assembly tests; the random programs and the interrupt sweep, which compare results only, cannot see it.
- **37 further faults**, written separately: 13 in the decoder (wrong `funct3`, `shamt[5]` not checked, the unary group decoding only part of the rs2 field, `orc.b` with any rs2 field, the RV64 encodings of `rev8`, `zext.h`, `ctzw` and `cpopw` accepted, wrong sub-operation mappings, a non-canonical payload, the 16-bit encoding space) and 24 in Execute (signedness of `min`/`max`, `clz` off by one, `cpop(-1) = 0`, the rotate direction reversed or off by one, the `czero` condition inverted or testing only part of rs2, `orc.b`, `rev8`, `sext.b`, `zext.h` and `xnor` faults, a rotator stage wrong, the result wired to the wrong ALU code). 35 were caught; two cannot change any result and were shown equivalent (a comparator using `<=` instead of `<`, which differs only for equal operands, where `min` and `max` return the same value; and a rotate-left detection without its group check, whose output only `ror`, `rol` and `bext` read, which make the same choice either way). Of the 35, the repository's suites caught 34; the decoder accepting the RV64 `ctzw`/`cpopw` encodings was caught only by an exhaustive comparison of the new decoder with the old one over all 2^32 words. Sweep G of the decoder sweep (every OP-32 and OP-IMM-32 `funct7` × rs2 field × `funct3`) was added for it: re-applied to this tree, that fault and the RV64 `zext.h` fault each fail the sweep (`OP LEAK instr=6015951b ...`, `2/486896 encoding checks FAILED`; `OP LEAK instr=0805c53b ...`, `1/486896 encoding checks FAILED`).
- **Negative controls on this tree:** with the fault `clz` off by one, `make ext-check` fails (`clz` and `ctz` differ, `EXT CHECK: FAIL (2 of 28 forms differ: clz ctz)`) and `make bench-zbb` fails (`problem: zbb_arr: P2, SUM differ or are missing`, `problem: zbb_diff: no clean ZBB DIFF OK`).

## Inputs

- Base commit `e75223e5a6af0e6ff5233f46d1196e85755e25d1`, with the Zbb, Zbs and Zicond changes not yet committed: [`inputs.sha256`](inputs.sha256) lists the sha256 of every changed or new file under `Makefile`, `rtl/`, `defines/`, `std/`, `test/` and `lib/`, other than documentation, as the runs used them. The other inputs (`sim/`, `ref/`, `third_party/`) are those of the base commit.

## Environment

- Date: 2026-10-02
- Host: Intel Core Ultra 7 165H, 22 threads, Linux
- Tools: Verilator 5.042 2025-11-02 rev v5.042; riscv32-unknown-elf-gcc () 12.2.0 with GNU Binutils 2.39; Python 3.12.3; GNU Make 4.3
- Jobs: 4 for the fuzz set, the probe family, `ext-check`, `ext-exhaustive` and the campaign. Wall times: `make ext-check` 13.1 s; fuzz variant b, 1,000 programs, 52.9 s; the loader's session 22.1 s on HaDes-V+ and 28.2 s on the golden CPU; the others under 2 s each, with the simulators built.

## Caveats

- The golden models cannot check these instructions, and the golden CPU never runs them: every result above rests on models written from the ISA text, on the programs' self-checks and on builds with and without the extensions.
- No formal proof covers the new unit (the formal flow of `formal/` checks the M unit only), and the RTL has not been synthesised or implemented since the change: whether the core still meets 50 MHz is unknown.
- The cycle counts in the app's lines are those of the Verilator model of this working tree.

**Update, 2026-10-02 (form count of the app).** The statement that the app's `rv32im_zba_zbb_zbs` build contains all 28 forms had no output in this record. The per-form count of both builds was added to [the app's section](#the-app-bitmanip-in-the-loaders-session), to `meta.json` (`app_forms`) and to `check_bitmanip()` of `results/check.sh`, which now recounts it after the loader's session. The images counted are those of the session above (CRC32 `0xa8bf5894` and `0x31515268`); no other result of this record changed.

**Update, 2026-10-02 (the shell's `version` line).** The shell now prints one CPU line for all six extensions it probes, in the default build and in the loader's build alike: `cpu:       M yes, Zba yes, Zbb yes, Zbs yes, Zicntr yes, Zicond yes` on HaDes-V+ and `no` for each on the golden CPU, in place of the two lines `M ..., Zba ..., Zicntr ...` and `Zbb ..., Zbs ..., Zicond ... (for apps)`. `session-ext.txt` therefore checks one expectation fewer (34 on HaDes-V+, 30 on the golden CPU). The shell's code changed with it, so the sessions take a different number of cycles (`cycles=28018784` on HaDes-V+, `cycles=27529337` on the golden CPU), and so do some of the app's sections: the images of `compute` and `bitmanip` are unchanged (the same sizes and CRC-32), but the counts of `app_cycles()` include the timer interrupts taken while a section runs, and their timing relative to the app moved. On HaDes-V+, the RV32I build's `zbs` section now takes 267172 cycles (267175 before) and its `zicond` section 1817 (1999 before; the golden CPU took 1817 in both runs), the `rv32im_zba_zbb_zbs` build's `zbs` section 209356 (209170 before); the exit lines changed accordingly. Every value the sections compute and every verdict is unchanged. The two transcripts above and the `output` of both loader rows in `meta.json` were updated; docs/APPS.md quotes the new transcript. `inputs.sha256` still lists the files of the original runs: `test/freertos/shell/commands.c` and `test/freertos/loader/session-ext.txt` now differ from it (and `Makefile`, which gained the target `formal-ext`). Every other result of this record is unchanged and was re-checked with `make check-results`.

**Update, 2026-10-02 (formal proof).** The caveat that no formal proof covers the new unit no longer holds: the unit of Zbb, Zbs and Zicond in `rtl/execute_stage.sv` at c1a7c85 is proven against the ratified specifications for all operand values, see [formal/2026-10-02_c1a7c85](../../formal/2026-10-02_c1a7c85/RECORD.md).
