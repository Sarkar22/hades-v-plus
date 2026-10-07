[HaDes-V+](../README.md) · [Docs](README.md) · [Building](BUILDING.md) · [FreeRTOS](FREERTOS.md) · [Shell](SHELL.md) · [Apps](APPS.md) · [Architecture](ARCHITECTURE.md) · [Extensions](EXTENSIONS.md) · **Verification**

# Verification

This document describes how the behaviour of HaDes-V+ is checked: the results at a glance, the approach, every self-checking suite with its result, the test hierarchy, the trap and interrupt sweep, the FreeRTOS differential campaigns, the formal proofs of the multiply/divide unit and of the Zbb, Zbs and Zicond unit, the mutation testing that checks the tests themselves, and the known differences from the frozen reference models.

**Contents**

1. [Verification at a Glance](#verification-at-a-glance)
2. [Approach](#approach)
3. [Suites and Results](#suites-and-results)
4. [Test Hierarchy](#test-hierarchy)
5. [Trap and Interrupt Sweep](#trap-and-interrupt-sweep)
6. [FreeRTOS Differential Campaigns](#freertos-differential-campaigns)
7. [Formal Verification](#formal-verification)
8. [Mutation Testing](#mutation-testing)
9. [Known Divergences](#known-divergences)

## Verification at a Glance

Each result below summarises what the command prints in this version of the repository; the formal result is the recorded run in [formal/README.md](../formal/README.md#4-results-and-runtimes), made on 2026-10-02 on the `rtl/execute_stage.sv` of this version (SHA-256 `52201629…2bfa5d`) ([details](#formal-verification)). A *differential* run executes the same program, with the same randomised interrupt timing, on HaDes-V+ and on the golden CPU, and compares the verdicts. The [sections below](#approach) describe the methods and list every self-checking suite with its result.

[results/](../results/README.md) holds a record of each of these results and of the other figures that the documentation quotes: the command, the inputs, the output as printed, and whether it can be re-run (its index also names the few approximate figures that have none). `make check-results` re-runs the repeatable records and compares their output with the stored values.

| Check | Command | Result | Record |
|---|---|---|---|
| Every RV32I instruction, self-checking | `make test/asm/ops` | `All tests passed!` | [record](../results/tests/2026-10-01_03386fd/RECORD.md) |
| Decode stage, including forwarding and hazards, against the golden Decode stage | `make test/sv/test_decode_exhaustive` | 11,026 checks, all equal | [record](../results/tests/2026-10-01_03386fd/RECORD.md) |
| Decoder sweep: every opcode × funct3 × funct7 combination, every immediate and `rs2` field of the arithmetic opcodes and 150,000 random words decode as in the golden decoder, except the new M, Zba, Zbb, Zbs, Zicond, Zbkb, Zbkx and Zknh encodings, which must decode to exactly their own operations | `make test/sv/test_zba_encoding_sweep` | 486,896 checks passed | [record](../results/tests/2026-10-01_03386fd/RECORD.md) |
| Zbb, Zbs, Zicond, Zbkb, Zbkx and Zknh: the decoder and Execute stage against a C model written from the ISA texts, all 45 instruction forms | `make ext-check`; `make ext-exhaustive` | 125 digest lines identical; with the 15 one-operand instructions over all 2^32 inputs, 3,905 lines (64,452,030,208 results) identical | [record](../results/bitmanip/2026-10-02_e75223e/RECORD.md) |
| SHA-256 with the Zknh instructions against plain C, and the 17 Zbkb, Zbkx and Zknh instructions against RV32I code | `make bench-sha256` | `BENCH SHA256: PASS`: the NIST examples and equal digests in every build; 33,260 results compared, 0 mismatches | [record](../results/sha256/2026-10-02_bd800d8/RECORD.md) |
| M unit: all eight instructions and the stall protocol | `make test/sv/test_m_execute` | 6,268 checks passed | [record](../results/tests/2026-10-01_03386fd/RECORD.md) |
| M instructions against libgcc's software routines | `make test/c/m_extension` | `M-EXT PASS` after 200 checks; the testbench's summary line then reads `Inital test failed! (# Errors: 0)` ([why](#the-testbenchs-verdict-line)) | [record](../results/tests/2026-10-01_03386fd/RECORD.md) |
| Interrupts swept over every cycle offset, checked by an independent instruction-set model | `python3 test/trapsweep/sweep.py run` | 61 of 61 programs consistent | [record](../results/trapsweep/2026-10-01_03386fd/RECORD.md) |
| FreeRTOS differential campaign on HaDes-V+ and the golden CPU | `make freertos-stress` | 28 of 28 runs `PASS` | [record](../results/freertos-validate/2026-10-01_03386fd/RECORD.md) |
| FreeRTOS standard demo task set | `make freertos APP=full` | `PASS` after 150,681,199 cycles | [record](../results/tests/2026-10-01_03386fd/RECORD.md) |
| Scripted shell session; the same session on the golden CPU | `make freertos-shell-test`, `make freertos-shell-compare` | 120 of 120 expectations met; transcripts `SAME` | [record](../results/tests/2026-10-01_03386fd/RECORD.md) |
| Formal proofs, by k-induction: the multiply/divide unit computes the RISC-V result for all operand pairs, and, in Execute, each Zbb, Zbs, Zicond, Zbkb, Zbkx and Zknh instruction, as the decoder hands it over, gets the result of the ratified specifications for all operand values without making Execute stall or jump | `make formal` | `FORMAL RESULT: PASS`, 121 required checks and 41 negative controls ([recorded run](../formal/README.md#4-results-and-runtimes)) | [record](../results/formal/2026-10-02_bd800d8/RECORD.md) |

Four comparisons of single pipeline stages with the golden stages report a fixed number of expected differences, each explained under [Known Divergences](#known-divergences). The tests are themselves checked by [mutation testing](#mutation-testing): each trap and interrupt fix, reverted on its own, makes its regression test fail and the interrupt sweep flag programs ([record](../results/history/2026-09-27_6b19d41/RECORD.md)).

## Approach

Correctness is not asserted casually. The upstream project ships **frozen, closed-source reference models** (pre-compiled Verilator libraries in [`ref/`](../ref)) which every base-ISA change is compared against bit-exactly. Those models predate the new extensions and cannot validate them, so each extension is instead verified by **differential testing against an independent implementation** — for M, the same program compiled to libgcc's software routines and to native instructions must produce byte-identical output; for Zba, the same program built with and without the extension. Zbb, Zbs, Zicond, Zbkb, Zbkx and Zknh are checked in the same way and, in addition, against models written from the ratified ISA texts ([test/ext/](../test/ext/README.md)): the decoder and Execute stage are compared with a C model on every input of the one-operand instructions, and the Execute stage's results are formally proven.

Trap and interrupt behaviour — which the frozen models cover only partially, and where they themselves deviate from the specification in known places ([Known Divergences](#known-divergences)) — is checked by an **independent instruction-set model** ([`test/trapsweep/`](../test/trapsweep)) that replays each simulation at the interrupt boundaries the hardware chose, with interrupts swept over every cycle offset around several hundred trap-relevant instruction sequences.

The multiply/divide unit and the EXT unit (Zbb, Zbs, Zicond, Zbkb, Zbkx and Zknh) are additionally **formally verified** on the real RTL of this version: MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM and REMU are proven by k-induction to produce the RISC-V result for all 2⁶⁴ operand pairs in every reachable state, and, in Execute, each of the 45 Zbb, Zbs, Zicond, Zbkb, Zbkx and Zknh instructions, as the decoder hands it over, to get the result of the ratified specifications for all operand values without making Execute stall or jump; the decoding of the instruction words is checked by simulation — see [Formal Verification](#formal-verification).

Test suites are additionally validated by **mutation testing**: faults are deliberately injected into the RTL to confirm the tests actually fail, guarding against coverage that only appears to be thorough.

## Suites and Results

Every suite runs from the repository root. The results below are what the commands print in this version of the repository, with Verilator 5.042 and GCC 12.2.0. The simulations are deterministic, so the results are the same on every run. Each result is recorded with the exact output under [results/](../results/README.md): those of the first two tables in [results/tests](../results/tests/2026-10-01_03386fd/RECORD.md), except the rows of Zbb, Zbs and Zicond, which are recorded in [results/bitmanip](../results/bitmanip/2026-10-02_e75223e/RECORD.md), and of Zbkb, Zbkx and Zknh, in [results/crypto](../results/crypto/2026-10-02_bd800d8/RECORD.md), and those of the third in the record that its last column names. `make check-results` re-runs the repeatable records and compares the output with the stored values.

### Programs on the Complete Core

| Suite | Command | Result |
|---|---|---|
| Every RV32I instruction | `make test/asm/ops` | `All tests passed! (# Errors: 1 = initial test)` |
| Data forwarding | `make test/asm/forwarding` | the same |
| Exceptions and interrupts | `make test/asm/trap` | the same |
| Interrupts against traps and bus accesses | `make test/asm/trapirq`, `make test/asm/trapmpie`, `make test/asm/csrirq`, `make test/asm/memirq`, `make test/asm/mtvecirq` | the same, each |
| UART interrupt enables written by byte and halfword stores ([uartirq.s](../test/asm/uartirq.s)) | `make test/asm/uartirq` | the same |
| M | `make test/asm/mul`, `make test/asm/div` | the same, each |
| Zba | `make test/asm/zba`, `make test/asm/zbaadv` | the same, each |
| Zbb, Zbs, Zicond | `make test/asm/zbb`, `make test/asm/zbs`, `make test/asm/zicond` | the same, each |
| Zbkb, Zbkx, Zknh | `make test/asm/zbkb`, `make test/asm/zbkx`, `make test/asm/zknh` | the same, each |
| Hint encodings (`pause`, `ntl.*`) change nothing; the instructions of the Zkt list take a fixed number of cycles ([Zkt](EXTENSIONS.md#hints-zmmul-and-zkt)) | `make test/asm/hints`, `make test/asm/zkt` | the same, each |
| Zicntr | `make test/asm/zicntr` | the same |
| Zifencei and FENCE | `make test/asm/fencei`, `make test/asm/fencerd` | the same, each |
| Branch predictor | `make test/asm/bpred` | three `Test pass!` lines, then `Inital test failed! (# Errors: 0)`; see [The Testbench's Verdict Line](#the-testbenchs-verdict-line) |
| Interrupts next to predicted branches | `make test/asm/bpirq`, `make test/asm/bpirq2`, `make test/asm/bpirq3` | `All tests passed! (# Errors: 1 = initial test)`, each |
| M against libgcc | `make test/c/m_extension` | `M-EXT checks=200 errors=0`, `M-EXT PASS`, then `Inital test failed! (# Errors: 0)`; see [The Testbench's Verdict Line](#the-testbenchs-verdict-line) |
| Bootloader | `make test/c/bootloader` | `INFO: Bootloader started!`; the bootloader then waits for a program on the UART until the simulation's cycle limit (`Simulation timeout!`) |

### Module Benches

| Suite | Command | Result |
|---|---|---|
| Decode stage, including forwarding and hazards, against the golden Decode stage, over combinations of instruction, forwarding and status inputs | `make test/sv/test_decode_exhaustive` | `All 11026 checks PASSED — dut matches ref!` |
| Decode stage against the golden Decode stage, selected cases | `make test/sv/test_decode_compare` | `All 86 checks passed — dut matches ref!` |
| Decode-stage hazards | `make test/sv/test_decode_hazard` | `All tests passed! (# Errors: 0)` |
| Instruction-word sweep | `make test/sv/test_zba_encoding_sweep` | `All 486896 encoding checks passed — dut op matches ref everywhere except the Zba, M, Zbb, Zbs, Zicond, Zbkb, Zbkx and Zknh words` |
| M unit and its stall protocol | `make test/sv/test_m_execute` | `All 6268 M-extension checks passed` |
| The EXT unit of the Execute stage (Zbb, Zbs, Zicond, Zbkb, Zbkx, Zknh) | `make test/sv/test_ext_execute` | `All 1507647 EXT-unit checks passed` |
| Next PC with a branch prediction applied | `make test/sv/test_execute_bpred_nextpc` | `All 40000 branch-prediction next-PC checks passed` |
| Execute stage against the golden stage | `make test/sv/test_execute_compare` | `Tests: 142 Errors: 30` (baseline) |
| Memory stage against the golden stage | `make test/sv/test_memory_compare` | `Tests: 98 Errors: 6` (baseline) |
| Writeback stage against the golden stage | `make test/sv/test_writeback_compare` | `Tests: 111 Errors: 7` (baseline) |
| Writeback: traps that coincide with interrupts | `make test/sv/test_writeback_special_irq` | `Tests: 51 Errors: 24` (baseline) |

The four comparisons marked *baseline* report differences from the frozen stages that are expected in this version of the repository; [Module-Bench Baselines](#module-bench-baselines) explains them.

### System Level

| Suite | Command | Result | Record |
|---|---|---|---|
| Trap and interrupt sweep | `python3 test/trapsweep/sweep.py run` | `DUT: 61/61 programs ISS-consistent`; golden CPU 25/51 (its known deviations) | [trapsweep](../results/trapsweep/2026-10-01_03386fd/RECORD.md) |
| FreeRTOS, smallest program | `make freertos APP=minimal` | `FREERTOS RESULT: PASS`, `cycles=3169254` | [tests](../results/tests/2026-10-01_03386fd/RECORD.md) |
| FreeRTOS stress program | `make freertos APP=stress` | `FREERTOS RESULT: PASS`, `cycles=5156655` | [tests](../results/tests/2026-10-01_03386fd/RECORD.md) |
| FreeRTOS with M and Zba code | `make freertos APP=mzba MARCH=rv32im_zba` | `FREERTOS RESULT: PASS`, `cycles=5637099` | [tests](../results/tests/2026-10-01_03386fd/RECORD.md) |
| FreeRTOS standard demo task set | `make freertos APP=full` | `FREERTOS RESULT: PASS`, `cycles=150681199` | [tests](../results/tests/2026-10-01_03386fd/RECORD.md) |
| One program on both CPUs | `make freertos-compare APP=stress SEED=7` | `AGREE`: HaDes-V+ 5156380 cycles, golden CPU 5155907 | [tests](../results/tests/2026-10-01_03386fd/RECORD.md) |
| Differential campaign | `make freertos-stress` | `CAMPAIGN RESULT: PASS (28 runs: 0 DUT run(s) not passed, 0 golden run(s) not passed, 0 build failure(s))` | [freertos-validate](../results/freertos-validate/2026-10-01_03386fd/RECORD.md) |
| Rebuild after a changed setting | `make freertos-check-rebuild` | `REBUILD CHECK: PASS (8 runs, every run used the configuration it was given)` | [tests](../results/tests/2026-10-01_03386fd/RECORD.md) |
| Scripted shell session | `make freertos-shell-test` | `FREERTOS SHELL RESULT: PASS`, `cycles=2283594`, `expectations met: 120/120` | [tests](../results/tests/2026-10-01_03386fd/RECORD.md) |
| The same session on both CPUs | `make freertos-shell-compare` | `SHELL COMPARE: SAME  40 blocks, 158 lines equal after normalising numbers` | [tests](../results/tests/2026-10-01_03386fd/RECORD.md) |
| The interactive console | `make freertos-shell-tty-test` | `TTY TEST: PASS  (22 of 22 cases passed)` | [tests](../results/tests/2026-10-01_03386fd/RECORD.md) |
| Formal proofs of the M and EXT units | `make formal` | `FORMAL RESULT: PASS (mode=default)`: 121 required checks and 41 negative controls | [formal](../results/formal/2026-10-02_bd800d8/RECORD.md) |
| Zbb, Zbs, Zicond, Zbkb, Zbkx and Zknh against the C model | `make ext-check` | `EXT CHECK: PASS (45 of 45 forms identical)`: 125 digest lines, 1,034,153,728 vectors | [bitmanip](../results/bitmanip/2026-10-02_e75223e/RECORD.md) |
| The same, the one-operand instructions over all 2^32 inputs | `make ext-exhaustive` | `EXT CHECK: PASS (45 of 45 forms identical)`: 3,905 digest lines, 64,452,030,208 vectors | [bitmanip](../results/bitmanip/2026-10-02_e75223e/RECORD.md) |
| Random programs with Zbb, Zbs and Zicond, replayed by the instruction-set model | `python3 test/trapsweep/sweep.py fuzz --seeds 1001-2000 --variant b --targets dut` | `DUT: 1000/1000 programs ISS-consistent` | [bitmanip](../results/bitmanip/2026-10-02_e75223e/RECORD.md) |
| Interrupts swept around the 28 forms | `python3 test/trapsweep/sweep.py run --fam ext --targets dut` | `DUT: 3/3 programs ISS-consistent` | [bitmanip](../results/bitmanip/2026-10-02_e75223e/RECORD.md) |
| Random programs with the 17 Zbkb, Zbkx and Zknh instructions as well | `python3 test/trapsweep/sweep.py fuzz --seeds 2001-3000 --variant k --targets dut` | `DUT: 1000/1000 programs ISS-consistent` | [crypto](../results/crypto/2026-10-02_bd800d8/RECORD.md) |
| Interrupts swept around the 17 forms | `python3 test/trapsweep/sweep.py run --fam crypto --targets dut` | `DUT: 3/3 programs ISS-consistent` | [crypto](../results/crypto/2026-10-02_bd800d8/RECORD.md) |
| SHA-256 for `rv32i`, with Zbb and with Zknh, compared | `make bench-sha256` | `BENCH SHA256: PASS`; `crypto_diff`: 33,260 checks, 0 mismatches; 84.2, 63.4 and 49.8 cycles per byte at `-O2` | [sha256](../results/sha256/2026-10-02_bd800d8/RECORD.md) |
| C programs for `rv32i` and with Zbb and Zbs, compared | `make bench-zbb` | `BENCH ZBB: PASS`; `zbb_diff`: 52,436 checks, 0 mismatches | [zbb](../results/zbb/2026-10-02_e75223e/RECORD.md) |
| FreeRTOS programs built with Zbb and Zbs (HaDes-V+ only) | `python3 test/freertos/campaign.py --set bitmanip --seeds 8` | `CAMPAIGN RESULT: PASS (120 runs: ...)` | [bitmanip](../results/bitmanip/2026-10-02_e75223e/RECORD.md) |
| The loader's session with the app `bitmanip`, on HaDes-V+ and on the golden CPU | `make freertos-shell-test APP=loader SCRIPT=test/freertos/loader/session-ext.txt [CPU=golden]` | `FREERTOS SHELL RESULT: PASS`; `bitmanip: 4 of 4 sections passed` in both builds on HaDes-V+, in the `rv32i` build on the golden CPU, which refuses the other build | [bitmanip](../results/bitmanip/2026-10-02_e75223e/RECORD.md) |
| The loader's session with the app `sha256`, on HaDes-V+ and on the golden CPU | `make freertos-shell-test APP=loader SCRIPT=test/freertos/loader/session-crypto.txt [CPU=golden]` | `FREERTOS SHELL RESULT: PASS`; `sha256: self-test 4 of 4 NIST vectors: PASS` in both builds on HaDes-V+, in the `rv32i` build on the golden CPU, which refuses the Zknh build | [crypto](../results/crypto/2026-10-02_bd800d8/RECORD.md) |

The formal result is the recorded run in [formal/README.md](../formal/README.md#4-results-and-runtimes), made on 2026-10-02; the proved `rtl/execute_stage.sv`, SHA-256 `52201629…2bfa5d`, is the file of this version ([record](../results/formal/2026-10-02_bd800d8/RECORD.md)). The earlier runs of record proved the EXT unit with its 28 Zbb, Zbs and Zicond instructions on the file of commit c1a7c85 (`c36613c8…3ae969`, [record](../results/formal/2026-10-02_c1a7c85/RECORD.md)), and, on 2026-09-28, the M unit on the file of commits 588d76a to e75223e (`847dc018…fab1bb`), before Zbb, Zbs and Zicond added their unit ([record](../results/formal/2026-09-28_588d76a/RECORD.md)). The formal tools are listed under [Tools](../formal/README.md#tools).

The repository also contains programs and benches that print no verdict of their own; they are not listed above:

- the C programs [hello_world.c](../test/c/hello_world.c), [test_csr.c](../test/c/test_csr.c), [test_mcycle.c](../test/c/test_mcycle.c) and [bp_benchmark.c](../test/c/bp_benchmark.c), which end with the summary line `Inital test failed! (# Errors: 0)` ([why](#the-testbenchs-verdict-line)), and the demo [basys3_demo.c](../test/c/basys3_demo.c), which runs until the simulation's cycle limit (`Simulation timeout!`);
- the diagnostic benches [test_writeback_persephone_case1.sv](../test/sv/test_writeback_persephone_case1.sv), [case2](../test/sv/test_writeback_persephone_case2.sv) and [case13](../test/sv/test_writeback_persephone_case13.sv), which print the outputs of the HaDes-V+ and the golden Writeback stage side by side for inspection;
- the upstream example bench [test_example.sv](../test/sv/test_example.sv), which does not build with Verilator 5.042 (`%Error-FUNCTIMECTL: ... Functions cannot contain time-controlling statements`).

## Test Hierarchy

The [test/](../test/) tree has three progressively integrative tiers, plus two system-level stress suites:

| Tier | Location | What it exercises | Invocation |
|---|---|---|---|
| **Assembly** | [test/asm/](../test/asm/) | Small hand-written `.s` programs targeting a specific ISA feature — e.g. [trap.s](../test/asm/trap.s) for the full exception/interrupt path, [ops.s](../test/asm/ops.s) for every RV32I instruction, [forwarding.s](../test/asm/forwarding.s) for the data-hazard network, [bpred.s](../test/asm/bpred.s) for the branch predictor (modes 0/1/3, counter verification), [mul.s](../test/asm/mul.s) / [div.s](../test/asm/div.s) for the `M` extension, [zbb.s](../test/asm/zbb.s) / [zbs.s](../test/asm/zbs.s) / [zicond.s](../test/asm/zicond.s) for bit manipulation and conditional zero, [trapirq.s](../test/asm/trapirq.s) / [trapmpie.s](../test/asm/trapmpie.s) / [csrirq.s](../test/asm/csrirq.s) / [memirq.s](../test/asm/memirq.s) for interrupt-vs-trap and interrupt-vs-bus timing sweeps, [bpirq.s](../test/asm/bpirq.s) / [bpirq2.s](../test/asm/bpirq2.s) / [bpirq3.s](../test/asm/bpirq3.s) for interrupts landing next to correctly predicted taken branches in every predictor mode, [mtvecirq.s](../test/asm/mtvecirq.s) for an interrupt right after a `csrw mtvec`. | `make test/asm/trap` |
| **C** | [test/c/](../test/c/) | Full C programs linked against [std/](../std/). [bootloader.c](../test/c/bootloader.c) is the UART loader; [basys3_demo.c](../test/c/basys3_demo.c) wiggles every on-board peripheral; [m_extension.c](../test/c/m_extension.c) diffs the `M` hardware against libgcc's software routines. | `make test/c/basys3_demo` |
| **SystemVerilog** | [test/sv/](../test/sv/) | Module-level benches that run DUT vs. REF side-by-side and compare every cycle. Examples: [test_writeback_compare.sv](../test/sv/test_writeback_compare.sv), [test_execute_compare.sv](../test/sv/test_execute_compare.sv), [test_decode_hazard.sv](../test/sv/test_decode_hazard.sv), [test_execute_bpred_nextpc.sv](../test/sv/test_execute_bpred_nextpc.sv) (Execute with a branch prediction applied, against the predictor-less reference). Where the frozen reference cannot help — `Zba`, `M`, `Zbb`, `Zbs`, `Zicond` — the bench carries its own golden model instead: [test_m_execute.sv](../test/sv/test_m_execute.sv), [test_ext_execute.sv](../test/sv/test_ext_execute.sv). | `make test/sv/test_writeback_compare` |
| **FreeRTOS** | [test/freertos/](../test/freertos/) | FreeRTOS V11 programs (`minimal`, `stress`, `full` standard demo, `mzba`, and the `brk` RTOS breaker) with randomised, desynchronised interrupt timing, plus `campaign.py`, which runs every configuration on the DUT and on the golden CPU. `FRTOS_BPRED=1..3` runs a program with the branch predictor on. User guide: [docs/FREERTOS.md](FREERTOS.md); details: [test/freertos/README.md](../test/freertos/README.md). | `make freertos APP=stress`, `make freertos-compare APP=stress`, `make freertos-stress` |
| **Trap sweep** | [test/trapsweep/](../test/trapsweep/) | Interrupts swept over every cycle offset around 532 distinct probe instruction sequences, plus random programs. Every run is checked by an independent Python ISA model (`iss.py`) and compared with the golden CPU. This is the oracle for extensions that the frozen golden models cannot check. See [test/trapsweep/README.md](../test/trapsweep/README.md). | `python3 test/trapsweep/sweep.py run` |

Together these give coverage at the instruction level, the system level, and the per-module bit-level — catch a bug as early as possible in whichever tier first exposes it.

## Trap and Interrupt Sweep

The frozen golden models cover traps and interrupts only partially, and they deviate from the specification in places, so [test/trapsweep/](../test/trapsweep/README.md) adds an oracle that depends on neither them nor the RTL. Its probe programs arm an interrupt that becomes pending exactly `k` cycles later, for every `k` in a range, so that the interrupt lands on every cycle around a probe instruction sequence. The 574 probes in 15 families (532 of them distinct) cover CSR operations on every trap CSR, every exception kind, MRET, FENCE.I, WFI, branches and jumps, slow bus accesses, M and Zba instructions and the branch-predictor modes 1 to 3; random programs add to them. `iss.py`, an instruction-set model of the microcontroller written in Python, replays every run at the interrupt boundaries that the hardware chose and checks everything else: that each interrupt was enabled and armed where it was taken, that each exception was taken at the right instruction with the right cause, and every `mepc`, `mcause`, `mstatus`, result register, peripheral and memory value.

```bash
python3 test/trapsweep/sweep.py run
```

```text
DUT: 61/61 programs ISS-consistent
golden: 25/51 programs ISS-consistent (see the probe list: known golden deviations are tagged)
```

Of the 26 programs that the golden CPU fails, 25 are explained by its known deviations ([Known Divergences](#known-divergences)). The 26th, `race_ext_0`, carries only the expected flag of the `race` family, a bounded interrupt latency ([Expected flags](../test/trapsweep/README.md#expected-flags)), which `sweep.py` excuses for HaDes-V+ only ([record](../results/trapsweep/2026-10-01_03386fd/RECORD.md)). The sweep found two of the six trap and interrupt defects listed below: the predicted-branch next PC and the stale `mtvec` ([record](../results/history/2026-09-27_6b19d41/RECORD.md)). The families, the random-program fuzzing, the trace protocol and the mutation check are documented in [test/trapsweep/README.md](../test/trapsweep/README.md).

## FreeRTOS Differential Campaigns

**FreeRTOS is used here as a test, not a demo.** A system that merely boots proves little: interrupt-handling defects appear only when an interrupt meets a particular instruction in a particular pipeline cycle, and according to the development log, a tick-synchronised demo ran more than 5,000 ticks on a core that still had three such defects (the run itself was not kept and the figure could not be verified; [record](../results/history/2026-09-26_97ef211/RECORD.md)). The programs in [`test/freertos/`](../test/freertos) therefore randomise their interrupt timing from a run seed, check themselves continuously (queue sequences, critical sections, register integrity across context switches, tick drift, the UART transcript), and run both on HaDes-V+ and on the frozen golden CPU from [`ref/`](../ref). A run that passes on the golden CPU and fails on HaDes-V+ is a defect of the core.

Running FreeRTOS this way found the first four of the six trap and interrupt defects below; the [trap sweep](#trap-and-interrupt-sweep) found the last two. All six are fixed, and each is covered by a directed regression test that fails when its fix alone is reverted ([record](../results/history/2026-09-27_6b19d41/RECORD.md)):

| Defect | Effect under FreeRTOS | Regression |
|---|---|---|
| An exception in Writeback was dropped when an interrupt became pending in the same cycle | A yield `ECALL` vanished; the scheduler lists were corrupted | [trapirq.s](../test/asm/trapirq.s) |
| A trap taken with `MIE=0` left `MPIE=1` | A yield inside a critical section returned with interrupts enabled | [trapmpie.s](../test/asm/trapmpie.s) |
| The instruction in flight at a sequential interrupt lost its CSR write | `portDISABLE_INTERRUPTS` was lost | [csrirq.s](../test/asm/csrirq.s) |
| An interrupt during a slow bus access re-executed the access after the handler | Doubled UART characters | [memirq.s](../test/asm/memirq.s) |
| With the branch predictor on, an interrupt after a correctly predicted taken branch resumed on the not-taken path | Assertions, lost yields and hangs | [bpirq.s](../test/asm/bpirq.s) and variants |
| An interrupt right after `csrw mtvec` used the old vector (the golden CPU shares this defect) | None in practice (FreeRTOS writes `mtvec` once) | [mtvecirq.s](../test/asm/mtvecirq.s) |

On the fixed core the final differential campaign passed **794 of 794** FreeRTOS runs (102 of them with the branch predictor enabled, about 14.7 billion simulated cycles), with every one of the 523 golden-CPU twin runs agreeing, and the independent model in [`test/trapsweep/`](../test/trapsweep) found no architectural error across its full interrupt-offset sweep and random-program fuzzing. That campaign ran on 2026-09-27 as six `campaign.py` commands, on a working tree based on 97ef211 whose changes were committed the next day as 0d25ee6 and 6b19d41. Its sets, seeds and run lengths were recorded, and the six commands are now the suite `sep2026` of `campaign.py`. Re-run at 03386fd on 2026-10-01, the suite reproduced the campaign: the same 794 DUT runs and 523 golden runs, all passing, with 14,684,200,429 DUT cycles, and every per-run value of 2026-09-27 that survives ([record](../results/freertos-campaign/2026-10-01_03386fd/RECORD.md); the campaign of 2026-09-27: [record](../results/freertos-campaign/2026-09-27_6b19d41/RECORD.md)). The `validate` and `standard` sets share five variants and the seeds 0001 to 0008, so 40 of the DUT runs, and 40 of the golden runs, repeat another run exactly: 754 of the 794 DUT runs are distinct. The suite takes about 80 minutes with 12 parallel simulations; `--wall-limit 0` lifts the per-run wall-clock limit, which on a busy machine could otherwise stop a long run, and `--compare` checks the re-run run for run against the record:

```bash
python3 test/freertos/campaign.py --suite sep2026 --jobs 12 --wall-limit 0 \
    --compare results/freertos-campaign/2026-10-01_03386fd/results.csv
```

### The Validation Campaign

`make freertos-stress` runs the `validate` set of [test/freertos/campaign.py](../test/freertos/campaign.py): seven builds of the `stress`, `minimal` and `mzba` programs, each run with two interrupt-timing seeds on HaDes-V+ (`dut`) and on the golden CPU. A variant's name gives the program (`noyield`: without `taskYIELD()` inside critical sections), the instruction set, the optimisation level, preemption and time slicing (`p1s1`), the tick in clock cycles and the heap implementation; a result gives the verdict and the simulated clock cycles. The result in this version of the repository ([record](../results/freertos-validate/2026-10-01_03386fd/RECORD.md)):

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

| target | runs | PASS | FAIL | of which UART transcript only | HANG | CRASH | vs golden: runs with a golden twin | diverged |
|---|---|---|---|---|---|---|---|---|
| dut | 14 | 14 | 0 | 0 | 0 | 0 | 14 | 0 |
| golden | 14 | 14 | 0 | 0 | 0 | 0 | - | - |

```text
CAMPAIGN RESULT: PASS (28 runs: 0 DUT run(s) not passed, 0 golden run(s) not passed, 0 build failure(s))
```

The record keeps every run with its verdict and cycle count. Run directly with `--compare`, the campaign is checked run for run against it:

```bash
python3 test/freertos/campaign.py --set validate --seeds 2 --strict --jobs 4 \
    --compare results/freertos-validate/2026-10-01_03386fd/results.csv
```

The larger sets (`standard`, `full`, `realtick`, `bpred`, `breaker`, `breaker2`, `breaker-long` and others) are described in [test/freertos/README.md](../test/freertos/README.md#differential-campaign); [FREERTOS.md](FREERTOS.md#6-run-the-stress-tests) shows how to run them.

## Formal Verification

Two units of `rtl/execute_stage.sv` are formally verified: the multiply/divide unit and
the EXT unit of Zbb, Zbs, Zicond, Zbkb, Zbkx and Zknh. Both proofs were run on 2026-10-02
on the file of this version (SHA-256 `52201629…2bfa5d`, the file with the cryptography
half of the EXT unit). Earlier runs of record covered the EXT unit with its first 28
instructions (the file of c1a7c85, `c36613c8…3ae969`) and, on 2026-09-28, the M unit of
the file of 588d76a (`847dc018…fab1bb`); the re-runs of the M proof on the later files
gave the same result for every check.

Both proofs run on the real RTL. The only change is one inserted `include` line in the
sv2v translation, and the script checks that nothing else changed.

```bash
make formal         # both units: proofs, lemma checks, covers, negative controls, sanity checks (about 2.5 minutes)
make formal-full    # also the slow bitwuzla lemma proof, second solvers and two mutation campaigns (about 45 minutes; longer on a loaded machine)
make formal-ext     # the EXT unit alone (about a minute)
```

Each run ends with `FORMAL RESULT: PASS` or `FORMAL RESULT: FAIL`. The run of record took
2 min 22 s (`make formal`) and 45 min 07 s (`make formal-full`) ([record](../results/formal/2026-10-02_bd800d8/RECORD.md)). The tools
(SymbiYosys/Yosys, sv2v, bitwuzla, Yices, z3) install in user space, for example with
`pip install yowasp-yosys z3-solver` plus three release binaries.
[formal/README.md](../formal/README.md) explains the installation, the proof structure, the
runtimes, and exactly what is and is not proven.

### The M unit

The proof shows that MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM and REMU produce the RISC-V
M-extension result:

- for **all 2^64 operand pairs**;
- including division by zero and the `-2^31 / -1` overflow;
- in **every reachable state**, by k-induction, not a bounded check;
- with Memory stalls, pipeline flushes and resets arriving in any cycle.

It also shows that the divider never holds the pipeline for more than 33 consecutive
cycles.

#### How the M proof is built

The main steps are proven by k-induction:

| Step | Property |
|---|---|
| Control and shape invariants | The FSM stays consistent, the latched operands match the instruction, and the stall is bounded. |
| Division invariant | While the divider runs, its partial quotient and remainder are the quotient and remainder of the dividend bits consumed so far. |
| Results | Every M instruction leaving Execute, every forwarded M result, and every VALID hand-off to Memory carries the ISA result. The result is checked on the module's ports and decided from the opcode field, so an instruction the unit misdecodes is also caught. |

Six small arithmetic lemmas and one structural fact are assumed; each is checked on its
exact text. The hardest one, a single long-division step, is proven with z3 and again
with bitwuzla.
The following checks guard against a proof that is true only because it is empty or
misstated:

- non-vacuity covers;
- negative controls (deliberately broken lemmas and a buggy multiplier must fail);
- an independent Python model of the specification;
- a line-by-line bench comparison of the SystemVerilog and its sv2v translation;
- 19 seeded bugs, 18 of which are rejected. The 19th changes a bit that the proof shows
  is always zero.

### The Zbb, Zbs, Zicond, Zbkb, Zbkx and Zknh unit

For each of the 45 instructions (andn, orn, xnor, clz, ctz, cpop, max, maxu, min, minu,
sext.b, sext.h, zext.h, rol, ror, rori, orc.b, rev8, bclr, bclri, bext, bexti, binv,
binvi, bset, bseti, czero.eqz and czero.nez; pack, packh, brev8, zip, unzip, xperm4,
xperm8, the four sha256 and the six sha512 instructions), the proof shows, in every
reachable state and for **all operand values**, every rotate amount, bit index and
permutation index:

- the value forwarded in the instruction's own cycle is the result of the ratified
  specifications (Bit-Manipulation 1.0.0, Zicond 1.0, Scalar Cryptography 1.0.1), marked valid exactly when the
  instruction is VALID, with `rd` as its address;
- when the instruction leaves Execute, the next cycle hands Memory that result as VALID;
- an EXT instruction, whatever its payload, never makes Execute answer STALL or JUMP.

The specification is written from the ratified texts in the style of their Sail code (the
counts scan bit by bit, the rotates use two shifts, the SHA-512 halves are the Sail shift
expressions) and cross-checked against an independent Python model, which takes the SHA-2
functions from FIPS 180-4, on 1,157,509 vectors. The proof does not assume anything that
the M proof proves. Its guards against an empty or misstated proof are a cover for each
instruction, a check of the instruction-to-payload map against `defines/op.sv`, the
`test_ext_execute` bench in the sv2v comparison, and 37 seeded bugs, five of which leave
the computed result intact and break only how it is forwarded or handed to Memory, and one
of which stalls a cryptography instruction for one value of `rs1`: each is rejected, with
a concrete counterexample, by exactly the properties of the instructions it breaks. The
third property is also part of the evidence for [Zkt](EXTENSIONS.md#zkt-data-independent-latency).

### Limitations

- The proofs cover the Execute stage alone. The behaviour of Decode and Memory that it
  relies on (Decode holds its outputs while Execute stalls; Memory only signals
  READY/STALL/JUMP) is argued from the RTL, not proven. The rest of the pipeline
  (Memory, Writeback, forwarding consumers, traps) is covered by the simulation tests.
- The translation tool (sv2v), Yosys and the SMT solvers are trusted.
- The specifications are written from the RISC-V manual and the ratified extension
  texts. The golden reference models in `ref/` predate M and the bit-manipulation and
  cryptography extensions and cannot serve as an oracle.
- The EXT proof starts from the payload the decoder builds for each instruction. That the
  decoder builds it from the instruction word is checked by simulation (the decoder
  sweep and `make ext-check`), not proven.

## Mutation Testing

The evidence for the mutation testing described under [Approach](#approach) is documented with the suites it checks:

- **The trap and interrupt fixes.** Each of the six fixes was reverted on its own. For every revert, the trap sweep flags programs outside the expected `race` family, and the fix's own directed regression test fails. The reverts and the families they flag are tabulated in [test/trapsweep/README.md](../test/trapsweep/README.md#provenance-and-results) ([record](../results/history/2026-09-27_6b19d41/RECORD.md)).
- **The Zbb, Zbs and Zicond unit.** Hand-written faults in the decoder and in the Execute unit (wrong `funct3`, swapped signedness of `min`/`max`, `clz` off by one, the rotate direction reversed, `shamt[5]` not checked, the `czero` condition inverted, wrong sub-operation codes, results not forwarded, and more) were each applied to a copy of the RTL during development: every fault that changes a result is caught by the repository's suites, and the two that cannot change any result were shown equivalent ([record](../results/bitmanip/2026-10-02_e75223e/RECORD.md#mutation-testing)).
- **The multiply/divide unit.** `make formal-full` runs 19 mutants of the M unit against 32 proofs. Every mutant except `diff32` is rejected; `diff32` is an equivalent mutant, because it changes a bit that the proof shows to be always zero. The repository's `test_m_execute` bench detects every mutant except `diff32` as well; that was checked during development, outside the formal package, and `make formal-full` does not repeat it ([record](../results/formal/2026-10-02_c1a7c85/RECORD.md)). Details: [formal/README.md](../formal/README.md#3-how-the-proof-works).
- **The Zbkb, Zbkx and Zknh instructions.** 22 faults planted during the implementation and 46 by an independent review, in the decoder and in the cryptography half of the Execute unit (wrong rotate and shift amounts, swapped high and low halves, the index width and range test of `xperm`, the bytes of `packh`, the bit order of `brev8`, `zip` and `unzip` swapped, colliding sub-operation codes, a stall for one operand value), were each applied to a copy of the RTL: every fault that changes a result or the timing is caught, and three that cannot change anything are equivalent. A comparison of the old and new decoders on all 2^32 instruction words found every word outside the 17 forms decoded as before ([record](../results/crypto/2026-10-02_bd800d8/RECORD.md#mutation-testing)).
- **The EXT unit, formally.** `make formal` runs 37 mutants of the unit as negative controls, each against the property of an instruction it breaks, which must fail; five of them leave the computed result intact and break only the forwarding fields or the result registered for Memory, and one stalls a cryptography instruction for one value of `rs1`. `make formal-full` runs each against all 46 property proofs. All 37 are rejected, each by exactly the proofs of the instructions it changes ([record](../results/formal/2026-10-02_bd800d8/RECORD.md)). Details: [formal/README.md](../formal/README.md#the-ext-proof).

## Known Divergences

### The Frozen Golden Models

The golden CPU and the golden stages in [`ref/`](../ref) are the upstream implementation of the base core (RV32I and Zicsr), frozen as compiled libraries. HaDes-V+ differs from them in these documented ways; [test/trapsweep/README.md](../test/trapsweep/README.md#known-golden-deviations) has the details.

- **No M, Zba, Zbb, Zbs, Zicond, Zicntr or branch predictor.** The golden models decode M, Zba, Zbb, Zbs and Zicond instructions as illegal, the golden CPU's `time` CSR reads 0, and it reads `MHPMEVENT10` as 0 and ignores writes to it. Programs for the golden CPU are therefore built for `rv32i`.
- **`CSRRWI rd, csr, 0` writes 0 to `rd`** in the golden models, instead of the old CSR value that the specification requires. HaDes-V+ is correct.
- **An interrupt taken right after a retired `csrw mtvec`** enters the old vector on the golden CPU. HaDes-V+ had the same defect and uses the new vector since its fix (see [Hazards](ARCHITECTURE.md#hazards-and-how-theyre-handled)); here the specification and the independent ISA model decide.
- **`minstret` reads one higher** on the golden CPU than on HaDes-V+, from reset.
- **The golden CPU samples interrupts one cycle later.** The same program therefore interleaves differently on the two CPUs: cycle counts differ slightly, and an interrupt can be taken at a different but legal instruction boundary. The FreeRTOS comparisons therefore compare verdicts, not cycle counts.

### Module-Bench Baselines

The benches that compare a pipeline stage with its golden stage print every check on which the two differ. In this version of the repository four of them report a fixed number of differences. These counts are the baseline: a change in a count is a change of behaviour that has to be explained. Each of the differing checks is recorded verbatim in [baseline-diffs.txt](../results/tests/2026-10-01_03386fd/baseline-diffs.txt), so that a change can be compared line by line.

| Bench | Result | The differing checks concern |
|---|---|---|
| [test_execute_compare.sv](../test/sv/test_execute_compare.sv) | `Tests: 142 Errors: 30` | `JALR` to a target with bit 0 set (HaDes-V+ clears bit 0, as the ISA specifies; the golden stage does not), and the next-PC value of a `JAL` that carries `BUBBLE` or an exception status |
| [test_memory_compare.sv](../test/sv/test_memory_compare.sv) | `Tests: 98 Errors: 6` | the data returned by a misaligned load, which traps and does not write a register |
| [test_writeback_compare.sv](../test/sv/test_writeback_compare.sv) | `Tests: 111 Errors: 7` | read-back values of `mstatus` and of `CSRRWI`/`CSRRCI`, and an interrupt taken at an `MRET` or at the CSR write that enables it |
| [test_writeback_special_irq.sv](../test/sv/test_writeback_special_irq.sv) | `Tests: 51 Errors: 24` | `mstatus`, `mepc` and `mcause` around a trap that coincides with an interrupt, and an `MRET` with an interrupt pending |

The writeback differences are situations that the trap and interrupt rules under [Hazards](ARCHITECTURE.md#hazards-and-how-theyre-handled) define. HaDes-V+'s behaviour in them is checked by the trap sweep against the independent ISA model, which accepts every DUT program. The execute and memory differences are the ones described in the table.

### The Testbench's Verdict Line

The simulation's test device ([sim/top.sv](../sim/top.sv)) counts every `Test fail!` and expects exactly one: the deliberate "initial test" marker with which a test program starts. Its summary line therefore reads `All tests passed! (# Errors: 1 = initial test)` when it has counted exactly one, `Some test(s) failed!` when it has counted more, and `Inital test failed! (# Errors: 0)` (the simulator's spelling) when it has counted none.

Two kinds of program never write that marker: [test/asm/bpred.s](../test/asm/bpred.s), which reports its three checks without it, and the C programs in [test/c/](../test/c), which only ever write the code that ends the simulation (the start-up code writes it when `main` returns). When such a program passes and ends the simulation, the summary line reads `Inital test failed! (# Errors: 0)`. For them the verdict is the program's own output, not the summary line: for [test/c/m_extension.c](../test/c/m_extension.c) the line `M-EXT PASS` (or `M-EXT FAIL`); for `bpred.s` three `Test pass!` lines, where any `Test fail!` line is a failed check, whatever the summary line says.
