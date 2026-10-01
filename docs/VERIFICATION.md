[HaDes-V+](../README.md) · [Architecture](ARCHITECTURE.md) · [Extensions](EXTENSIONS.md) · **Verification** · [Building](BUILDING.md) · [FreeRTOS](FREERTOS.md)

# Verification

This document describes how the behaviour of HaDes-V+ is checked: the approach, every self-checking suite with its result, the test hierarchy, the trap and interrupt sweep, the FreeRTOS differential campaigns, the formal proof of the multiply/divide unit, the mutation testing that checks the tests themselves, and the known differences from the frozen reference models.

**Contents**

1. [Approach](#approach)
2. [Suites and Results](#suites-and-results)
3. [Test Hierarchy](#test-hierarchy)
4. [Trap and Interrupt Sweep](#trap-and-interrupt-sweep)
5. [FreeRTOS Differential Campaigns](#freertos-differential-campaigns)
6. [Formal Verification of the M Unit](#formal-verification-of-the-m-unit)
7. [Mutation Testing](#mutation-testing)
8. [Known Divergences](#known-divergences)

## Approach

Correctness is not asserted casually. The upstream project ships **frozen, closed-source reference models** (pre-compiled Verilator libraries in [`ref/`](../ref)) which every base-ISA change is compared against bit-exactly. Those models predate the new extensions and cannot validate them, so each extension is instead verified by **differential testing against an independent implementation** — for M, the same program compiled to libgcc's software routines and to native instructions must produce byte-identical output; for Zba, the same program built with and without the extension.

Trap and interrupt behaviour — which the frozen models cover only partially, and where they themselves deviate from the specification in known places ([Known Divergences](#known-divergences)) — is checked by an **independent instruction-set model** ([`test/trapsweep/`](../test/trapsweep)) that replays each simulation at the interrupt boundaries the hardware chose, with interrupts swept over every cycle offset around several hundred trap-relevant instruction sequences.

The multiply/divide unit is additionally **formally verified**: MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM and REMU are proven by k-induction to produce the RISC-V result for all 2⁶⁴ operand pairs in every reachable state, on the real RTL — see [Formal Verification of the M Unit](#formal-verification-of-the-m-unit).

Test suites are additionally validated by **mutation testing**: faults are deliberately injected into the RTL to confirm the tests actually fail, guarding against coverage that only appears to be thorough.

## Suites and Results

Every suite runs from the repository root. The results below are what the commands print in this version of the repository, with Verilator 5.042 and GCC 12.2.0. The simulations are deterministic, so the results are the same on every run.

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
| Instruction-word sweep | `make test/sv/test_zba_encoding_sweep` | `All 290288 encoding checks passed — dut op matches ref everywhere except the Zba and M words` |
| M unit and its stall protocol | `make test/sv/test_m_execute` | `All 6268 M-extension checks passed` |
| Next PC with a branch prediction applied | `make test/sv/test_execute_bpred_nextpc` | `All 40000 branch-prediction next-PC checks passed` |
| Execute stage against the golden stage | `make test/sv/test_execute_compare` | `Tests: 142 Errors: 30` (baseline) |
| Memory stage against the golden stage | `make test/sv/test_memory_compare` | `Tests: 98 Errors: 6` (baseline) |
| Writeback stage against the golden stage | `make test/sv/test_writeback_compare` | `Tests: 111 Errors: 7` (baseline) |
| Writeback: traps that coincide with interrupts | `make test/sv/test_writeback_special_irq` | `Tests: 51 Errors: 24` (baseline) |

The four comparisons marked *baseline* report differences from the frozen stages that are expected in this version of the repository; [Module-Bench Baselines](#module-bench-baselines) explains them.

### System Level

| Suite | Command | Result |
|---|---|---|
| Trap and interrupt sweep | `python3 test/trapsweep/sweep.py run` | `DUT: 61/61 programs ISS-consistent`; golden CPU 25/51 (its known deviations) |
| FreeRTOS, smallest program | `make freertos APP=minimal` | `FREERTOS RESULT: PASS`, `cycles=3169254` |
| FreeRTOS stress program | `make freertos APP=stress` | `FREERTOS RESULT: PASS`, `cycles=5156655` |
| FreeRTOS with M and Zba code | `make freertos APP=mzba MARCH=rv32im_zba` | `FREERTOS RESULT: PASS`, `cycles=5637099` |
| FreeRTOS standard demo task set | `make freertos APP=full` | `FREERTOS RESULT: PASS`, `cycles=150681199` |
| One program on both CPUs | `make freertos-compare APP=stress SEED=7` | `AGREE`: HaDes-V+ 5156380 cycles, golden CPU 5155907 |
| Differential campaign | `make freertos-stress` | `CAMPAIGN RESULT: PASS (28 runs: 0 DUT run(s) not passed, 0 golden run(s) not passed, 0 build failure(s))` |
| Rebuild after a changed setting | `make freertos-check-rebuild` | `REBUILD CHECK: PASS (8 runs, every run used the configuration it was given)` |
| Scripted shell session | `make freertos-shell-test` | `FREERTOS SHELL RESULT: PASS`, `cycles=2278845`, `expectations met: 120/120` |
| The same session on both CPUs | `make freertos-shell-compare` | `SHELL COMPARE: SAME  40 blocks, 158 lines equal after normalising numbers` |
| The interactive console | `make freertos-shell-tty-test` | `TTY TEST: PASS  (22 of 22 cases passed)` |
| Formal proof of the M unit | `make formal` | `FORMAL RESULT: PASS (mode=default)`: 72 required checks and 4 negative controls |

The formal result is the recorded run in [formal/README.md](../formal/README.md#4-results-and-runtimes); the SHA-256 of the proved `rtl/execute_stage.sv` recorded there is that of the file in this version of the repository. The formal tools are listed under [Tools](../formal/README.md#tools).

The repository also contains programs and benches that print no verdict of their own; they are not listed above:

- the C programs [hello_world.c](../test/c/hello_world.c), [test_csr.c](../test/c/test_csr.c), [test_mcycle.c](../test/c/test_mcycle.c) and [bp_benchmark.c](../test/c/bp_benchmark.c), which end with the summary line `Inital test failed! (# Errors: 0)` ([why](#the-testbenchs-verdict-line)), and the demo [basys3_demo.c](../test/c/basys3_demo.c), which runs until the simulation's cycle limit (`Simulation timeout!`);
- the diagnostic benches [test_writeback_persephone_case1.sv](../test/sv/test_writeback_persephone_case1.sv), [case2](../test/sv/test_writeback_persephone_case2.sv) and [case13](../test/sv/test_writeback_persephone_case13.sv), which print the outputs of the HaDes-V+ and the golden Writeback stage side by side for inspection;
- the upstream example bench [test_example.sv](../test/sv/test_example.sv), which does not build with Verilator 5.042 (`%Error-FUNCTIMECTL: ... Functions cannot contain time-controlling statements`).

## Test Hierarchy

The [test/](../test/) tree has three progressively integrative tiers, plus two system-level stress suites:

| Tier | Location | What it exercises | Invocation |
|---|---|---|---|
| **Assembly** | [test/asm/](../test/asm/) | Small hand-written `.s` programs targeting a specific ISA feature — e.g. [trap.s](../test/asm/trap.s) for the full exception/interrupt path, [ops.s](../test/asm/ops.s) for every RV32I instruction, [forwarding.s](../test/asm/forwarding.s) for the data-hazard network, [bpred.s](../test/asm/bpred.s) for the branch predictor (modes 0/1/3, counter verification), [mul.s](../test/asm/mul.s) / [div.s](../test/asm/div.s) for the `M` extension, [trapirq.s](../test/asm/trapirq.s) / [trapmpie.s](../test/asm/trapmpie.s) / [csrirq.s](../test/asm/csrirq.s) / [memirq.s](../test/asm/memirq.s) for interrupt-vs-trap and interrupt-vs-bus timing sweeps, [bpirq.s](../test/asm/bpirq.s) / [bpirq2.s](../test/asm/bpirq2.s) / [bpirq3.s](../test/asm/bpirq3.s) for interrupts landing next to correctly predicted taken branches in every predictor mode, [mtvecirq.s](../test/asm/mtvecirq.s) for an interrupt right after a `csrw mtvec`. | `make test/asm/trap` |
| **C** | [test/c/](../test/c/) | Full C programs linked against [std/](../std/). [bootloader.c](../test/c/bootloader.c) is the UART loader; [basys3_demo.c](../test/c/basys3_demo.c) wiggles every on-board peripheral; [m_extension.c](../test/c/m_extension.c) diffs the `M` hardware against libgcc's software routines. | `make test/c/basys3_demo` |
| **SystemVerilog** | [test/sv/](../test/sv/) | Module-level benches that run DUT vs. REF side-by-side and compare every cycle. Examples: [test_writeback_compare.sv](../test/sv/test_writeback_compare.sv), [test_execute_compare.sv](../test/sv/test_execute_compare.sv), [test_decode_hazard.sv](../test/sv/test_decode_hazard.sv), [test_execute_bpred_nextpc.sv](../test/sv/test_execute_bpred_nextpc.sv) (Execute with a branch prediction applied, against the predictor-less reference). Where the frozen reference cannot help — `Zba`, `M` — the bench carries its own golden model instead: [test_m_execute.sv](../test/sv/test_m_execute.sv). | `make test/sv/test_writeback_compare` |
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

Every program the golden CPU fails is explained by its known deviations ([Known Divergences](#known-divergences)). The sweep found two of the six trap and interrupt defects listed below: the predicted-branch next PC and the stale `mtvec`. The families, the random-program fuzzing, the trace protocol and the mutation check are documented in [test/trapsweep/README.md](../test/trapsweep/README.md).

## FreeRTOS Differential Campaigns

**FreeRTOS is used here as a test, not a demo.** A system that merely boots proves little: interrupt-handling defects appear only when an interrupt meets a particular instruction in a particular pipeline cycle, and during development a tick-synchronised demo ran more than 5,000 ticks on a core that still had three such defects. The programs in [`test/freertos/`](../test/freertos) therefore randomise their interrupt timing from a run seed, check themselves continuously (queue sequences, critical sections, register integrity across context switches, tick drift, the UART transcript), and run both on HaDes-V+ and on the frozen golden CPU from [`ref/`](../ref). A run that passes on the golden CPU and fails on HaDes-V+ is a defect of the core.

Running FreeRTOS this way found the first four of the six trap and interrupt defects below; the [trap sweep](#trap-and-interrupt-sweep) found the last two. All six are fixed, and each is covered by a directed regression test that fails when its fix alone is reverted:

| Defect | Effect under FreeRTOS | Regression |
|---|---|---|
| An exception in Writeback was dropped when an interrupt became pending in the same cycle | A yield `ECALL` vanished; the scheduler lists were corrupted | [trapirq.s](../test/asm/trapirq.s) |
| A trap taken with `MIE=0` left `MPIE=1` | A yield inside a critical section returned with interrupts enabled | [trapmpie.s](../test/asm/trapmpie.s) |
| The instruction in flight at a sequential interrupt lost its CSR write | `portDISABLE_INTERRUPTS` was lost | [csrirq.s](../test/asm/csrirq.s) |
| An interrupt during a slow bus access re-executed the access after the handler | Doubled UART characters | [memirq.s](../test/asm/memirq.s) |
| With the branch predictor on, an interrupt after a correctly predicted taken branch resumed on the not-taken path | Assertions, lost yields and hangs | [bpirq.s](../test/asm/bpirq.s) and variants |
| An interrupt right after `csrw mtvec` used the old vector (the golden CPU shares this defect) | None in practice (FreeRTOS writes `mtvec` once) | [mtvecirq.s](../test/asm/mtvecirq.s) |

On the fixed core the final differential campaign passed **794 of 794** FreeRTOS runs (102 of them with the branch predictor enabled, about 14.7 billion simulated cycles), with every one of the 523 golden-CPU twin runs agreeing, and the independent model in [`test/trapsweep/`](../test/trapsweep) found no architectural error across its full interrupt-offset sweep and random-program fuzzing. These figures were recorded when the FreeRTOS support was added (commits 6b19d41 and 62b0407). The campaign sets and seeds of those 794 runs were not recorded, so that campaign cannot be repeated run for run; the validation campaign below, and the larger sets named after it, can.

### The Validation Campaign

`make freertos-stress` runs the `validate` set of [test/freertos/campaign.py](../test/freertos/campaign.py): seven builds of the `stress`, `minimal` and `mzba` programs, each run with two interrupt-timing seeds on HaDes-V+ (`dut`) and on the golden CPU. A variant's name gives the program (`noyield`: without `taskYIELD()` inside critical sections), the instruction set, the optimisation level, preemption and time slicing (`p1s1`), the tick in clock cycles and the heap implementation; a result gives the verdict and the simulated clock cycles. The result in this version of the repository:

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

The larger sets (`standard`, `full`, `realtick`, `bpred`, `breaker`, `breaker2`, `breaker-long` and others) are described in [test/freertos/README.md](../test/freertos/README.md#differential-campaign); [FREERTOS.md](FREERTOS.md#6-run-the-stress-tests) shows how to run them.

## Formal Verification of the M Unit

The multiply/divide unit of `rtl/execute_stage.sv` is formally verified. The proof shows
that MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM and REMU produce the RISC-V M-extension
result:

- for **all 2^64 operand pairs**;
- including division by zero and the `-2^31 / -1` overflow;
- in **every reachable state**, by k-induction, not a bounded check;
- with Memory stalls, pipeline flushes and resets arriving in any cycle.

It also shows that the divider never holds the pipeline for more than 33 consecutive
cycles.

The proof runs on the real RTL. The only change is one inserted `include` line in the
sv2v translation, and the script checks that nothing else changed.

```bash
make formal         # the proofs, lemma checks, covers and sanity checks (about 1-2 min)
make formal-full    # also the slow bitwuzla lemma proof and a mutation campaign (about 25-35 min)
```

Each run ends with `FORMAL RESULT: PASS` or `FORMAL RESULT: FAIL`. The tools
(SymbiYosys/Yosys, sv2v, bitwuzla, Yices, z3) install in user space, for example with
`pip install yowasp-yosys z3-solver` plus three release binaries.
[formal/README.md](../formal/README.md) explains the installation, the proof structure, the
runtimes, and exactly what is and is not proven.

### How it is built

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

### Limitations

- The proof covers the Execute stage alone. The behaviour of Decode and Memory that it
  relies on (Decode holds its outputs while Execute stalls; Memory only signals
  READY/STALL/JUMP) is argued from the RTL, not proven. The rest of the pipeline
  (Memory, Writeback, forwarding consumers, traps) is covered by the simulation tests.
- The translation tool (sv2v), Yosys and the SMT solvers are trusted.
- The specification is written from the RISC-V manual. The golden reference models in
  `ref/` predate the M extension and cannot serve as an oracle.

## Mutation Testing

The evidence for the mutation testing described under [Approach](#approach) is documented with the suites it checks:

- **The trap and interrupt fixes.** Each of the six fixes was reverted on its own. For every revert, the trap sweep flags programs outside the expected `race` family, and the fix's own directed regression test fails. The reverts and the families they flag are tabulated in [test/trapsweep/README.md](../test/trapsweep/README.md#provenance-and-results).
- **The multiply/divide unit.** `make formal-full` runs 19 mutants of the M unit against 32 proofs. Every mutant except `diff32` is rejected; `diff32` is an equivalent mutant, because it changes a bit that the proof shows to be always zero. The repository's `test_m_execute` bench detects every mutant except `diff32` as well. Details: [formal/README.md](../formal/README.md#3-how-the-proof-works).

## Known Divergences

### The Frozen Golden Models

The golden CPU and the golden stages in [`ref/`](../ref) are the upstream implementation of the base core (RV32I and Zicsr), frozen as compiled libraries. HaDes-V+ differs from them in these documented ways; [test/trapsweep/README.md](../test/trapsweep/README.md#known-golden-deviations) has the details.

- **No M, Zba, Zicntr or branch predictor.** The golden models decode M and Zba instructions as illegal, the golden CPU's `time` CSR reads 0, and it reads `MHPMEVENT10` as 0 and ignores writes to it. Programs for the golden CPU are therefore built for `rv32i`.
- **`CSRRWI rd, csr, 0` writes 0 to `rd`** in the golden models, instead of the old CSR value that the specification requires. HaDes-V+ is correct.
- **An interrupt taken right after a retired `csrw mtvec`** enters the old vector on the golden CPU. HaDes-V+ had the same defect and uses the new vector since its fix (see [Hazards](ARCHITECTURE.md#hazards-and-how-theyre-handled)); here the specification and the independent ISA model decide.
- **`minstret` reads one higher** on the golden CPU than on HaDes-V+, from reset.
- **The golden CPU samples interrupts one cycle later.** The same program therefore interleaves differently on the two CPUs: cycle counts differ slightly, and an interrupt can be taken at a different but legal instruction boundary. The FreeRTOS comparisons therefore compare verdicts, not cycle counts.

### Module-Bench Baselines

The benches that compare a pipeline stage with its golden stage print every check on which the two differ. In this version of the repository four of them report a fixed number of differences. These counts are the baseline: a change in a count is a change of behaviour that has to be explained.

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
