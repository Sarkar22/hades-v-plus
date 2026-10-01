[instrguide]:https://repository.tugraz.at/oer/nytm4-grv34
[lvref]:https://online.tugraz.at/tug_online/wbLv.wbShowLVDetail?pStpSpNr=525082
[vivado]:https://www.xilinx.com/support/download.html
[verilator]:https://verilator.org
[basys]:https://digilent.com/reference/programmable-logic/basys-3/reference-manual?redirect=1
[gtkwave]:https://gtkwave.sourceforge.net/
[sv]:https://doi.org/10.1109/IEEESTD.2018.8299595
[rvgcc]:https://github.com/riscv-collab/riscv-gnu-toolchain

![image](https://www.scheipel.com/wp-content/uploads/2024/12/hades_logo.svg)
# HaDes-V+ — An Extended RISC-V Soft Core

[![RISC-V Community Challenge](https://img.shields.io/badge/RISC--V%20Community%20Challenge-Gold%20%C2%B7%20Silver%20%C2%B7%20Bronze-d4af37)](https://www.credly.com/badges/a78e3644-1597-450d-8020-f03662391719/public_url)
[![ISA](https://img.shields.io/badge/ISA-rv32im__zba__zicsr__zifencei__zicntr-1f6feb)](#instruction-set)
[![Target](https://img.shields.io/badge/target-Basys3%20%C2%B7%20Artix--7%20xc7a35t-e05d44)](#clocks--reset)
[![Simulation](https://img.shields.io/badge/simulation-Verilator-2ea44f)](#building-running-and-debugging)
[![License](https://img.shields.io/badge/license-MIT%20%C2%B7%20CC%20BY%204.0-8957e5)](#license)

**HaDes-V+** is an extended version of the [HaDes-V][lvref] 32-bit RISC-V soft core: a classic in-order, five-stage pipeline written in SystemVerilog, targeting the Digilent [Basys3][basys] (Xilinx Artix-7 `xc7a35tcpg236-1`) at 50 MHz. It boots bare-metal C, takes interrupts, drives real peripherals, and programs itself over UART.

The upstream HaDes-V is an **Open Educational Resource** developed by [Tobias Scheipel](https://www.scheipel.com), David Beikircher, and Florian Riedl of the Embedded Architectures & Systems Group at Graz University of Technology, and released under the MIT licence. This repository preserves that work and its licence in full — see [Attribution and Upstream](#attribution-and-upstream). Everything described under *Extensions* below is additional work by Emon Sarkar.

Development proceeded in two phases. The base core was implemented for the **RISC-V Community Challenge with HaDes-V**, a programme issued by The Linux Foundation, in which each pipeline module of a submitted design is assessed against a reference implementation. This submission scored full marks at every stage — 56/56 across Fetch, Decode, Register File, Instruction Decoder, Execute, Memory and Writeback — earning all three tiers: [Bronze](https://www.credly.com/badges/1f02699c-a9f7-4590-82f9-97f688cd0b7f/public_url), [Silver](https://www.credly.com/badges/6d03e72d-23fc-494a-bcad-b93a1da5c283/public_url) and [Gold](https://www.credly.com/badges/a78e3644-1597-450d-8020-f03662391719/public_url). The extensions catalogued below were developed subsequently and independently of the challenge.

## What This Repository Adds

The upstream core implements **RV32I + Zicsr**. This version extends it to **`rv32im_zba_zicsr_zifencei_zicntr`** and adds a branch predictor:

| Addition | Summary | Detail |
|---|---|---|
| **M** — multiply/divide | All eight instructions. 2-cycle registered multiply, 34-cycle restoring divider, and the first self-generated stall in the Execute stage | [§](#m--multiply-and-divide) |
| **Zba** — address generation | `sh1add`/`sh2add`/`sh3add`; **20.3 % fewer cycles** on address-heavy code | [§](#zba--scaled-index-address-generation) |
| **Zicntr** — user counters | `cycle`, `time`, `instret` (+ high halves), with `time` shadowing the real memory-mapped `mtime` | [§](#zicntr--user-mode-counters) |
| **Zifencei** — documented & tested | `FENCE.I` was implemented but never actually verified upstream; now proven against a measured 3-slot staleness window | [§](#zifencei--instruction-fetch-synchronisation) |
| **Branch predictor** | Bimodal, four runtime-selectable algorithms with dedicated performance counters | [§](#branch-predictor-extension) |
| **FreeRTOS** | The official RISC-V port boots unmodified; one-command build and run, a differential stress campaign against the golden CPU, a template for your own programs, and an interactive command shell (FreeRTOS+CLI) you type into from your terminal | [§](#freertos) |

Eight correctness fixes to the base core are also included. Two predate the RTOS work: a decoder defect that corrupted registers on stores and branches (which prevented the bootloader from running at all), and a forwarding defect that leaked a garbage value for `FENCE` instructions carrying a non-zero reserved field. The other six are trap and interrupt defects exposed by running FreeRTOS under randomised interrupt timing; see [FreeRTOS](#freertos).

### Verification

Correctness is not asserted casually. The upstream project ships **frozen, closed-source reference models** (pre-compiled Verilator libraries in [`ref/`](ref)) which every base-ISA change is compared against bit-exactly. Those models predate the new extensions and cannot validate them, so each extension is instead verified by **differential testing against an independent implementation** — for M, the same program compiled to libgcc's software routines and to native instructions must produce byte-identical output; for Zba, the same program built with and without the extension.

Trap and interrupt behaviour — which the frozen models cover only partially, and where they themselves deviate from the specification in three known places — is checked by an **independent instruction-set model** ([`test/trapsweep/`](test/trapsweep)) that replays each simulation at the interrupt boundaries the hardware chose, with interrupts swept over every cycle offset around several hundred trap-relevant instruction sequences.

The multiply/divide unit is additionally **formally verified**: MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM and REMU are proven by k-induction to produce the RISC-V result for all 2⁶⁴ operand pairs in every reachable state, on the real RTL — see [Formal Verification of the M Unit](#formal-verification-of-the-m-unit).

Test suites are additionally validated by **mutation testing**: faults are deliberately injected into the RTL to confirm the tests actually fail, guarding against coverage that only appears to be thorough.

### Known Limitations

- **FPGA timing at 50 MHz is marginal.** The most recent implementation of the current RTL met timing with a worst negative slack of **+0.016 ns**; an earlier revision missed by 0.120 ns on the same pre-existing path, and run-to-run variance on that path is around 1 ns. Treat closure as unconfirmed until repeated; the cause and the one-constant clock workaround are documented under [M — Multiply and Divide](#m--multiply-and-divide).
- **Not yet validated on physical hardware.** All results are from Verilator simulation and Vivado implementation.

## Quick Start

```bash
make test/asm/ops                      # every RV32I instruction, against the golden reference
make test/c/m_extension                # M hardware diffed against libgcc's software routines
make test/sv/test_decode_exhaustive    # 11,026 DUT-vs-reference decode checks
make formal                            # formal proof of the multiply/divide unit (tools: formal/README.md)
make freertos APP=minimal              # boot FreeRTOS (guide: docs/FREERTOS.md)
make synthesis                         # implement for the Basys3 (Vivado)
make help                              # all available targets
```

Requires [Verilator][verilator] and a `riscv32-unknown-elf` GCC toolchain; synthesis additionally needs AMD [Vivado][vivado]. Full list under [Tools and Dependencies](#tools-and-dependencies). If the repository sits on a disk that cannot execute programs, put the build directory elsewhere with `export HADES_BUILD_DIR=/abs/path` (or `make BUILD_DIR=/abs/path ...`); see [docs/FREERTOS.md](docs/FREERTOS.md).

## The HaDes-V Core

HaDes-V is a **32-bit, in-order, classic five-stage RISC-V soft core** written in SystemVerilog. It is small enough to read end-to-end, yet complete enough to boot a bare-metal C program, take interrupts, and drive real peripherals on a Basys3 FPGA.

### Instruction Set

| Class | Support |
|---|---|
| Base ISA | **RV32I** — all 37 integer instructions (LUI/AUIPC, arithmetic/logic reg–reg & reg–imm, loads/stores for byte/half/word with signed & unsigned variants, conditional branches, JAL/JALR) |
| Multiply / divide | **M** — `mul`, `mulh`, `mulhsu`, `mulhu`, `div`, `divu`, `rem`, `remu` |
| Control & Status | **Zicsr** — CSRRW / CSRRS / CSRRC and their immediate variants |
| Instruction fence | **Zifencei** — FENCE.I to resynchronise the fetch path after self-modifying writes |
| Counters | **Zicntr** — user-mode read-only `cycle`, `time`, `instret` (+ `*h` high halves) |
| Address generation | **Zba** — `sh1add` / `sh2add` / `sh3add`, single-cycle scaled-index addressing |
| Privilege | **Machine mode only** (M-mode) with a full trap model: ECALL, EBREAK, MRET, and all synchronous exceptions |
| Interrupts | **External** and **timer** (`mie.MEIE`, `mie.MTIE`); gated by `mstatus.MIE`; save/restore via `MPIE` |

The full ISA string is **`rv32im_zba_zicsr_zifencei_zicntr`** (pinned: `rv32i2p1_m2p0_zba1p0_zicsr2p0_zifencei2p0_zicntr2p0`). The `Zicsr` and `Zifencei` suffixes are load-bearing rather than decorative: base `I` version 2.0 included the CSR instructions and `FENCE.I`, but version 2.1 split them out into separately-named extensions. Note that no `Z*` extension can be advertised in `MISA` — its `Extensions` field has exactly one bit per single letter (bit 8 = `I`, bit 12 = `M`, …), so multi-letter extension names exist only in the ISA string.

Implemented M-mode CSRs include `MSTATUS`, `MISA`, `MIE`, `MIP`, `MTVEC`, `MSCRATCH`, `MEPC`, `MCAUSE`, `MCYCLE`/`MCYCLEH`, `MINSTRET`/`MINSTRETH`, and (as an extension) **`MHPMEVENT10`** and **`MHPMCOUNTER10–13`** for branch-predictor control and performance monitoring — see [defines/csr.sv](defines/csr.sv) for the full map.

### Pipeline

Instructions flow through five stages, each a dedicated module in [rtl/](rtl/), stitched together in [cpu.sv](rtl/cpu.sv): **Fetch → Decode → Execute → Memory → Writeback**.

Two signals travel with them, in opposite directions. The `forwards` path carries the instruction and its status downstream toward Writeback. The `backwards` path carries control — `READY`, `STALL` or `JUMP`. Any stage can originate it: Memory when the bus is busy, Execute during a multi-cycle divide, Decode on a data hazard, Writeback on a trap or `FENCE.I`. It propagates upstream one stage at a time, holding or redirecting everything ahead of it.

| Stage | File | Responsibility |
|---|---|---|
| **Fetch** | [fetch_stage.sv](rtl/fetch_stage.sv) | Drives the instruction-side Wishbone port, keeps the program counter, and reports `FETCH_MISALIGNED` / `FETCH_FAULT` to the downstream pipeline. Also instantiates [branch_predictor.sv](rtl/branch_predictor.sv) and speculatively updates the PC to the branch target when `predicted_taken = 1`. |
| **Decode** | [decode_stage.sv](rtl/decode_stage.sv) + [instruction_decoder.sv](rtl/instruction_decoder.sv) | Expands the raw 32-bit word into a typed `instruction::t`, reads rs1/rs2 from the [register_file](rtl/register_file.sv), and runs the forwarding mux. Raises `ILLEGAL_INSTRUCTION` for unknown encodings. Threads the `bp_data_t` prediction struct from Fetch to Execute as a pass-through pipeline register. |
| **Execute** | [execute_stage.sv](rtl/execute_stage.sv) | ALU, branch comparison, and jump-target computation. Branches and JAL/JALR are **resolved here**. With branch prediction enabled, only *mis*predicted branches flush the pipeline; correctly-predicted branches have zero penalty. Drives `bp_feedback_out` back to Fetch for 2-bit counter updates. |
| **Memory** | [memory_stage.sv](rtl/memory_stage.sv) | Data-side Wishbone loads and stores with alignment checking. Stalls the pipeline until the bus acks. Emits `LOAD/STORE_MISALIGNED` and `LOAD/STORE_FAULT`. |
| **Writeback** | [writeback_stage.sv](rtl/writeback_stage.sv) | Commits `rd` to the register file, services all CSR reads/writes, and is the single point where **exceptions and interrupts trap** into `MTVEC`. Also implements MRET and FENCE.I. Holds the branch-predictor control register (`MHPMEVENT10`) and the four prediction-outcome counters (`MHPMCOUNTER10–13`). |

Pipeline direction is encoded in two packed packages in [defines/pipeline_status.sv](defines/pipeline_status.sv):

- **forwards** — `VALID`, `BUBBLE`, or one of the exception codes, flowing Fetch → Writeback.
- **backwards** — `READY`, `STALL`, or `JUMP` (with an accompanying target address), flowing Writeback → Fetch.

### Hazards and How They're Handled

Being in-order and single-issue keeps the control story small, but every classical hazard still has to be covered:

- **Data hazards (RAW).** A three-level **forwarding network** bypasses results from Execute, Memory, and Writeback back into Decode, with *most-recent-wins* priority (E > M > WB). The ordinary arithmetic case is resolved with zero bubbles.
- **Load-use hazard.** A load's result isn't available until after Memory. If Decode sees Execute forwarding with `data_valid = 0` for a register it needs, it asserts `STALL` backwards for one cycle and a `BUBBLE` forwards — exactly one stall slot, no more.
- **CSR-use hazard.** A CSR read resolves in Writeback, so its forwarding is tagged `data_valid = 0` in earlier stages; the same stall mechanism as load-use covers it.
- **Control hazards (branches / JAL / JALR).** Resolved in Execute. On a taken jump, the younger instructions already in Fetch/Decode are squashed by driving `JUMP` with the target address backwards; Fetch reloads from the target next cycle. With the **branch predictor extension** enabled (see below), correctly-predicted branches incur zero flush penalty — Execute only generates a `JUMP` on *mis*predictions.
- **Structural hazards on the bus.** The fetch and data paths each have their own Wishbone port, so loads/stores never collide with instruction fetches. When the data bus is slow, Memory holds the rest of the pipeline with `STALL`.
- **Multi-cycle execute (M extension).** Execute is single-cycle for every RV32I operation, but `mul` needs two cycles and `div`/`rem` need 34. Execute therefore has its own `STALL` generator, the second one in the pipeline after Memory's. Priority is `JUMP` from behind > `STALL` from Memory > Execute's own stall: a flush always outranks an unfinished divide, which is abandoned and re-run after the trap returns. See [Multiply and Divide](#m--multiply-and-divide) below.
- **Exceptions.** Flow forwards through the pipeline as the instruction's status code and trap at Writeback — the faulting PC is saved to `MEPC`, the cause encoded into `MCAUSE`, and control jumps to `MTVEC`.
- **Interrupts.** External and timer lines are sampled at Writeback. They trap on the completion boundary of a `VALID` or `ERROR` instruction (never on a `BUBBLE`), honour `mstatus.MIE` / `mie.MEIE` / `mie.MTIE`, and save/restore the global enable via `MPIE`. MRET returning with a pending enabled interrupt traps in the same cycle.
- **Exception beats a same-cycle interrupt.** If the instruction in Writeback raises an exception (e.g. `ECALL`) in the very cycle an enabled interrupt becomes pending, the exception is taken (`MEPC` = its PC). The interrupt stays pending and is taken at the handler's `MRET`. This matches the frozen golden model; the earlier behaviour recorded the interrupt with `MEPC` = PC+4, so the `ECALL` vanished — under FreeRTOS a lost `portYIELD` corrupted the scheduler lists. Regression: [trapirq.s](test/asm/trapirq.s).
- **`MPIE ← MIE` on every trap entry.** As the privileged spec requires, trap entry copies `MIE` into `MPIE` and clears `MIE`, also when `MIE` was already 0, so `MRET` from that trap comes back with interrupts still disabled. The golden model does the same. (An earlier "nested-trap" rule left `MPIE` untouched when `MIE` was 0. That made a FreeRTOS yield taken inside a critical section resume with interrupts *enabled*, and it diverged from the golden model in exactly the stale-`FETCH_FAULT` sequence it was meant to handle.) Regression: [trapmpie.s](test/asm/trapmpie.s).
- **The instruction in flight at a sequential interrupt.** An interrupt decided at instruction *I* redirects one cycle later, when the next instruction *J* is already in Writeback and has passed Memory. *J* therefore normally **retires** before the trap (register and CSR write, `minstret`, `MEPC` = its next PC). The exception is when *J* would touch state the trap has already committed: a CSR op on `MSTATUS`/`MCAUSE`/`MIE`/`MTVEC`, or an `MRET`. That *J* is **replayed** instead, with no effects and `MEPC` = its own PC. Earlier, *J*'s CSR write was dropped while `MEPC` still skipped it, which lost FreeRTOS's `portDISABLE_INTERRUPTS` (`csrc mstatus,8`). A retired *J* was also missing from `minstret`, which the golden model does count. Regression: [csrirq.s](test/asm/csrirq.s).
- **An interrupt never flushes a bus access in flight.** If *J* is a load or store to a peripheral that answers a cycle or more later (UART, timer, LEDs, VGA, the test stall register), its access has already started when the interrupt is decided at *I*, and a Wishbone access cannot be aborted. Writeback therefore **holds** the interrupt's `JUMP` while Memory reports the access in flight, and *J* retires when it completes (`MEPC` = its next PC), as the golden model does. Earlier the `JUMP` flushed *J* with `MEPC` = *J*'s PC, so the access was performed a second time after `MRET` (a UART character printed twice); with a response of three or more cycles (VGA read, test stall register) Memory's `STALL` swallowed the one-cycle `JUMP` altogether, so the trap state was committed (`MIE` = 0, `MCAUSE`, `MEPC`) but the handler never ran. Regression: [memirq.s](test/asm/memirq.s).
- **Interrupt after a correctly predicted taken branch.** Writeback takes an interrupt's `MEPC` from the `next_program_counter` that Execute attaches to every instruction. That value is the architectural next PC, so for a taken branch it is the target even when the predictor already fetched the target and Execute did not flush. Earlier it was `pc + 4` for a correctly predicted taken branch, so the handler's `MRET` resumed on the not-taken path (predictor modes 1–3 only). Regression: [bpirq.s](test/asm/bpirq.s), [bpirq2.s](test/asm/bpirq2.s), [bpirq3.s](test/asm/bpirq3.s), [test_execute_bpred_nextpc.sv](test/sv/test_execute_bpred_nextpc.sv); see [Branch predictor](#branch-predictor-extension).
- **Interrupt right after a `csrw mtvec`.** A sequential interrupt decided at an instruction *I* that writes `MTVEC` is taken after *I* has retired (`MEPC` points past it), so it must use the *new* vector: every trap sets `pc` to `mtvec.BASE`, and a CSR write is seen by the very next instruction (Zicsr, "CSR Access Ordering"). The interrupt's `JUMP` used to take a copy of `MTVEC` made in the decision cycle, before *I*'s write, and entered the *old* handler. It now uses the live register. The frozen golden model has the same bug (one delay step earlier), so here the spec and the independent ISA model in [test/trapsweep/](test/trapsweep/) decide, not the golden model. FreeRTOS was never affected, because it writes `MTVEC` once, before enabling interrupts. Regression: [mtvecirq.s](test/asm/mtvecirq.s).
- **Pipeline flushes on trap.** The trap's `JUMP` propagates backwards exactly like a branch, draining younger instructions without architectural side effects.

## Extensions

Everything in this section is work added after the upstream lab; the baseline core implements RV32I with `Zicsr` only.

### M — Multiply and Divide

Eight instructions, all plain R-type on the existing `OP` opcode (`0110011`) with `funct7 = 0000001`, so `funct3` alone selects among them and no new instruction format is needed.

The unit is formally proven correct for all inputs; see [Formal Verification of the M Unit](#formal-verification-of-the-m-unit).

| Instruction | funct3 | Operation |
|---|---|---|
| `mul` | `000` | low 32 bits of `rs1 × rs2` |
| `mulh` | `001` | high 32 bits, `rs1` **signed** × `rs2` **signed** |
| `mulhsu` | `010` | high 32 bits, `rs1` **signed** × `rs2` **unsigned** |
| `mulhu` | `011` | high 32 bits, `rs1` **unsigned** × `rs2` **unsigned** |
| `div` | `100` | signed quotient, truncated toward zero |
| `divu` | `101` | unsigned quotient |
| `rem` | `110` | signed remainder, sign of the **dividend** |
| `remu` | `111` | unsigned remainder |

**Division never traps.** RISC-V has no divide-by-zero exception and no overflow exception; both cases produce a defined value:

| Case | `div` | `divu` | `rem` | `remu` |
|---|---|---|---|---|
| `rs2 == 0` | `-1` | `2³²-1` | `rs1` | `rs1` |
| `rs1 == -2³¹`, `rs2 == -1` | `-2³¹` | *(ordinary)* `0` | `0` | *(ordinary)* `-2³¹` |

Both are handled as a **combinational early-out** that skips iteration entirely, so a divide by zero costs one cycle rather than 34.

#### Execute learns to stall

This is the first extension that makes Execute multi-cycle. Until now Execute was purely combinational and only *relayed* Memory's `STALL`/`JUMP`; the divider gives it a reason of its own.

| Operation | Cycles in Execute | Measured |
|---|---|---|
| any RV32I ALU op | 1 | 1.00 |
| `mul` / `mulh` / `mulhsu` / `mulhu` | 2 | 2.00 |
| `div` / `divu` / `rem` / `remu` | 34 | 34.00 |
| `div` / `rem` by zero, or `-2³¹ / -1` | 1 | 1.00 |

*(Measured in the assembled core over 800 back-to-back operations, loop overhead subtracted.)*

The arbitration between the three reasons the pipeline can be redirected is the delicate part, and the order is fixed in [rtl/execute_stage.sv](rtl/execute_stage.sv) Part 5:

1. **`JUMP` from Memory/Writeback wins over everything.** A trap, interrupt, `MRET` or `FENCE.I` is squashing the instruction that owns the in-flight divide, so the divide is **abandoned** and the M unit resets. Holding `STALL` through a flush instead is the classic hang: Decode and Fetch would never see the redirect. The abandoned divide costs nothing — the flushed instruction is re-fetched from `mepc` and re-run.
2. **`STALL` from Memory wins over Execute's own stall,** because a Wishbone transaction cannot be aborted. The divider keeps iterating underneath it: Decode holds its output registers whenever anything downstream stalls, so the operands are bit-stable and the progress is free. A divide that finishes mid-stall simply parks until the instruction can leave.
3. **Execute's own stall.** Decode already honoured `STALL` from Execute (holding its registers and relaying to Fetch, which freezes the PC), so no upstream change was needed — only the generator was missing.

While stalling, Execute holds every data register and forwards `BUBBLE` to Memory — the same pattern `memory_stage` already uses for its bus stall — so the instruction Memory consumed on the previous edge is not re-executed.

#### Verification

The frozen reference models predate `M` and can only report every M encoding as illegal, so correctness rests on three independent oracles.

| Test | What it covers |
|---|---|
| [test/sv/test_m_execute.sv](test/sv/test_m_execute.sv) | 6,268 checks against a golden model written from SystemVerilog's own `*`, `/` and `%`. Corner×corner and random operand sweeps for all eight ops, plus the whole stall protocol: `JUMP` at all 36 points of a divide, `JUMP` on the exact cycle it finishes, Memory `STALL` during and outlasting a divide, back-to-back M ops, `BUBBLE` and exception-status M ops (which must not stall), and reset mid-divide. Every wait loop is bounded and reports `HANG`. |
| [test/asm/mul.s](test/asm/mul.s) | 19 operand rows × 4 forms plus aliasing, `x0` destination and forwarding cases. `mulhsu` is run in **both operand orders** for every mixed-sign case — it is the only one of the four that is not commutative, and the expected values differ. |
| [test/asm/div.s](test/asm/div.s) | All four quadrants of truncating division, divide-by-zero for all four instructions over six dividends, the `-2³¹ / -1` overflow, dependent divide chains, quotients used as load/store addresses, divides in front of taken and not-taken branches, and an external interrupt swept across the 34-cycle window — 20 of the sweep's flushes land on an unfinished divide. |
| [test/c/m_extension.c](test/c/m_extension.c) | 200 differential checks against **libgcc**: each pair is computed once by a hardware M instruction and once by `__mulsi3`/`__muldi3`/`__divsi3`/`__modsi3`/`__udivsi3`/`__umodsi3`, which are independent RV32I software running on the same core. The two inputs that are undefined behaviour in C are checked against the mandated constants instead. |
| [test/sv/test_zba_encoding_sweep.sv](test/sv/test_zba_encoding_sweep.sv) | The 290,288-word decoder sweep now also requires the DUT to match the reference everywhere except the Zba **and** M words, so a decode arm that is too broad still shows up as a leak. |

```bash
make test/sv/test_m_execute
make test/asm/mul
make test/asm/div
make test/c/m_extension
```

#### Implementation Notes

- **FPGA timing is marginal.** *Update:* after the trap and interrupt fixes, the current RTL met timing in its most recent implementation (WNS **+0.016 ns**, 0 failing endpoints) — a single deterministic data point on a path with about 1 ns of run-to-run variance. The history below explains why the margin is this thin. Measured on Vivado 2024.2 for the `xc7a35tcpg236-1` at 20 ns: this tree reports post-route **WNS −0.120 ns** with 2 failing endpoints of 11214, while the same flow on the immediately preceding commit reports **+0.026 ns** with none. A bitstream is still produced — `write_bitstream` does not check timing — so a successful `make synthesis` is *not* evidence of closure; read `build/synth/reports/timing_pnr.rpt`. Two caveats matter before blaming the multiplier. First, **no M cell appears in the 40 worst paths**: the multiply closes with +6.15 ns and the divider with +10.19 ns. The failing path is a pre-existing 21-level, ~85 %-route path from the Memory stage's instruction register, through the waived `LUTLP-1` combinational-loop tangle, to the `mcause` register's clock enable — M's ~9 % area growth degrades its routing rather than lengthening its logic. Second, **run-to-run variance on that path is around 1 ns**, far larger than the 0.15 ns M costs, so a single run cannot cleanly attribute blame. The honest summary is that the design has been running at roughly zero margin since before M, the stored `+0.221 ns` report predates the `Zicntr` and `Zba` commits, and the real fix is to shorten that interrupt path rather than to pipeline the multiplier further.
- **The M results bypass `alu_sel` entirely.** `alu_sel` is a 4-bit local with only `1110`/`1111` free, and it is internal to `execute_stage` (not a struct field or port), so widening it would have been safe with respect to the frozen models. It was not widened anyway: half the M results come out of a sequential FSM and cannot be arms of the `always_comb` case that computes `alu_result`, and this design has essentially no timing margin to spend restructuring a block already near the critical path (see the FPGA timing note below). `m_result` is a second result bus that meets the ALU at the `rd_data` mux — one extra 2:1 level instead of six extra arms inside the ALU mux.
- **The multiply is registered, not combinational.** A 33×33 signed product is an array of DSP48E1 tiles plus an adder tree; run with no internal pipeline register it is comfortably the deepest combinational block in the core, and it would land on a path that runs from Decode's output registers through the multiplier, the `rd_data` mux and the forwarding network back into Decode's output registers — one 20 ns period, in a design with almost no margin to give. Registering the product puts a flop directly on the multiplier output. The price is one stall cycle, and since the divider needs the stall generator anyway it costs no extra machinery. Measured on the routed design the multiply path closes with **+6.15 ns** of slack, so the decision is vindicated — though Vivado did *not* absorb the flop into the DSP48E1's `P` register as intended, because the `MUL`-vs-`MULH` output mux sits between the DSP cascade and the register. Registering the full 64-bit product and muxing after the flops would allow that, at the cost of 32 extra FFs; it is not needed at this margin.
- **Restoring division on magnitudes.** Restoring and non-restoring need the same 32 iterations, but restoring needs no final correction step: the inner loop is one 33-bit subtract whose borrow *is* the quotient bit. Signs are stripped on the way in and reapplied on the way out, which is exactly the truncate-toward-zero rounding RISC-V specifies — and it makes the remainder follow the dividend for free. `abs(0x80000000)` is `0x80000000`, which read as unsigned is the correct magnitude 2³¹, so the most-negative value needs no special case in the datapath.
- **New ops were again appended *after* `ILLEGAL`** in [defines/op.sv](defines/op.sv), for the reason the `Zba` notes give. Codes 0–52 are bit-identical and M claims 53–60: **61 of 64 codes used**, so `op::t` is still 6 bits and `instruction::t` still 65 bits. The encoding sweep asserts both widths and the exact enum positions on every run.
- **Assembled via a directive, not a global flag.** [test/asm/mul.s](test/asm/mul.s) and [test/asm/div.s](test/asm/div.s) carry `.option arch, +m`, and [test/c/m_extension.c](test/c/m_extension.c) wraps its inline asm in `.option push` / `.option arch, +m` / `.option pop`. The Makefile still specifies no `-march` anywhere, so every other test still assembles as strict RV32I.
- **Interrupt latency grows behind a divide.** Writeback only takes an interrupt on the completion boundary of a non-`BUBBLE` instruction, and Execute feeds `BUBBLE` to Memory for all 33 stall cycles. Once the pipeline drains, an interrupt raised mid-divide is therefore deferred until the divide retires — up to ~34 cycles of extra latency. This is legal (interrupt latency is implementation-defined) and it is not a hang, but it is real and worth knowing before using `div` in an interrupt-critical loop.

### Zba — Scaled-Index Address Generation

`Zba` adds three single-cycle instructions that fuse a small left shift with an add: `rd = (rs1 << N) + rs2` for N = 1, 2, 3. That is precisely the shape of an array subscript — `&a[i]` is `base + i*sizeof(elem)` — so one instruction replaces the `slli`/`add` pair RV32I needs.

| Instruction | funct7 | funct3 | Operation |
|---|---|---|---|
| `sh1add` | `0010000` | `010` | `rd = (rs1 << 1) + rs2` — 2-byte elements |
| `sh2add` | `0010000` | `100` | `rd = (rs1 << 2) + rs2` — 4-byte elements (`int`, pointers) |
| `sh3add` | `0010000` | `110` | `rd = (rs1 << 3) + rs2` — 8-byte elements (`long long`, `double`) |

All three are plain R-type on the existing `OP` opcode (`0110011`), so the decoder needs no new immediate format and the pipeline needs no new plumbing — they inherit forwarding, hazard detection and writeback like any other ALU operation. The shift is **logical** over the full 32 bits (bits pushed past bit 31 are discarded, never sign-extended) and the add wraps modulo 2³², with no trap and no flags.

**The compiler emits them for you.** Building with `-march=rv32i_zba` makes GCC 12 generate `sh2add`/`sh3add` automatically for ordinary indexing code — no intrinsics or inline assembly required.

#### Verification

The frozen reference models predate `Zba` and can only report it as illegal, so correctness is established by **differential testing against the toolchain** instead: the same C program is compiled twice, once as plain RV32I (`slli`+`add`) and once with `-march=rv32i_zba`, and both binaries must produce byte-identical output on the core. The two programs are semantically identical, so any divergence is a hardware fault.

| Test | What it covers |
|---|---|
| [test/asm/zba.s](test/asm/zba.s) | 23 blocks / 62 assertions: zero and `x0` operands, `rd`/`rs1`/`rs2` aliasing, negative `rs1` with the sign bit shifted out, 32-bit overflow wrap, and forwarding from all three stages including into load/store addresses |
| [test/asm/zbaadv.s](test/asm/zbaadv.s) | 49 adversarial tests / 103 assertions written independently, including operand-order traps and pipeline-position interactions |
| [test/sv/test_zba_encoding_sweep.sv](test/sv/test_zba_encoding_sweep.sv) | 290,288-word DUT-vs-reference decoder sweep, plus enum and struct width assertions |

```bash
make test/asm/zba
make test/asm/zbaadv
make test/sv/test_zba_encoding_sweep
```

Measured on an address-generation-heavy workload: **20.3 % fewer cycles** (1.26×) and 6–8 % smaller code, verified across 16,704 in-program operand comparisons with zero discrepancies.

#### Implementation Notes

- **Assembled via a directive, not a global flag.** [test/asm/zba.s](test/asm/zba.s) carries `.option arch, +zba` rather than adding `-march=rv32i_zba` to the Makefile. This keeps the requirement next to the file that needs it and preserves the Makefile's property of specifying no `-march` at all; a global flag would silently permit `Zba` in every other assembly test.
- **New ops were appended *after* `ILLEGAL` in [defines/op.sv](defines/op.sv).** `op::t` values are positional, and [test/sv/test_execute_compare.sv](test/sv/test_execute_compare.sv) feeds `op::ILLEGAL` directly into a frozen reference model. Inserting ahead of `ILLEGAL` would have renumbered it from 49 to 52 and handed the golden model a code it has never seen. The enum stays 6 bits and `instruction::t` stays 65 bits, so every reference port width is unchanged — `Zba` took the count to 53 of 64, and the `M` extension appended after it takes it to 61.
- **Three fixed shifts, not one variable shift.** Each `alu_sel` arm hardwires its shift amount, which is free wiring into the existing adder. A single parameterised arm would need a shift-amount signal crossing the `alu_sel` boundary and would likely infer a second barrel shifter beside the one `SLL`/`SRL`/`SRA` already share — a poor trade on a design with this timing margin.

### Zicntr — User-Mode Counters

`Zicntr` defines three read-only counters that unprivileged code can read without a system call: `cycle` (elapsed core cycles), `time` (wall-clock), and `instret` (instructions retired), each with a high half for the upper 32 bits of its 64-bit value.

| CSR | Address | Shadows | Notes |
|---|---|---|---|
| `cycle` / `cycleh` | `0xC00` / `0xC80` | `mcycle` / `mcycleh` | Counts every cycle, including during reset |
| `time` / `timeh` | `0xC01` / `0xC81` | the timer's memory-mapped `mtime` | True shadow — tracks software writes to `mtime` |
| `instret` / `instreth` | `0xC02` / `0xC82` | `minstret` / `minstreth` | +1 per `VALID` retire |

**`time` is wired to the real `mtime`.** The spec defines `time` as a shadow of the memory-mapped `mtime`, not of the cycle counter, so [lib/wishbone/wishbone_timer.sv](lib/wishbone/wishbone_timer.sv) exports its 64-bit `mtime` register, [rtl/mcu.sv](rtl/mcu.sv) routes it into the core, and [rtl/writeback_stage.sv](rtl/writeback_stage.sv) reads it. A core-private counter would have been simpler but wrong here in a way this repo can actually observe: [test/asm/trap.s](test/asm/trap.s) writes `mtime` over the Wishbone bus in its timer handler, so a private counter would desynchronise on the very first timer test.

**All six are read-only, and that came for free.** The decoder already traps any CSR write whose address has bits `[11:10] == 2'b11`, which covers the whole `0xC00`/`0xC80` range. Writes via `csrrw`/`csrrwi` always trap; `csrrs`/`csrrc`/`csrrsi`/`csrrci` trap only when their source field is nonzero, so a zero-source `csrrs` remains a legal pure read.

#### Verification

[test/asm/zicntr.s](test/asm/zicntr.s) proves the aliases are exact rather than merely plausible. Since `mcycle` is writable and `cycle` is not, it writes a marker through `mcycle` and reads it back through `cycle`; a separate argument measures the spacing of `mcycle→mcycle`, `mcycle→cycle` and `cycle→mcycle` reads, which forces any constant offset between the two counters to zero. `time` is proven a real shadow by writing `mtime`/`mtimeh` through the timer's bus registers and reading the values back out of the CSRs. All 36 write forms (6 CSRs × 6 instructions) are checked to trap with `mcause=2`, and all 24 read forms to succeed.

```bash
make test/asm/zicntr
```

#### Implementation Notes

- **Do not add `_zicntr` to `-march`.** binutils 2.39 rejects the token outright (`unknown prefixed ISA extension 'zicntr'`). None is needed: the stock default `-march=rv32i` already accepts all six CSRs by name, so `csrr t0, cycle` assembles as-is and no Makefile change is required.
- **`mcounteren` stays hardwired to zero.** It gates counter access from privilege modes below M, and this core is M-mode only. Reading zero is legal WARL; implementing a register that reads back nonzero would imply gating the hardware cannot perform. If U-mode is ever added, `mcounteren` must be implemented for real.
- **`time` ticks at the core clock.** `mtime` increments once per `clk`, the same clock driving `mcycle`, so on this platform the two advance at the same rate and differ only by an offset (`mcycle` counts during reset; `mtime` is software-writable). That is a legal fixed-frequency clock, not an independent oscillator.
- **Reading a 64-bit counter on RV32** needs the standard retry loop — read the high half, read the low half, read the high half again, and repeat if it changed — because the two halves cannot be sampled atomically.
- **Golden-model note.** `writeback_stage` gained an `mtime_in` port that the frozen reference does not have; the DUT-vs-REF testbenches simply leave it unconnected, exactly as they already do for the branch predictor's ports. To run a test on the golden CPU, append a `+define+USE_REF_CPU` line to [sim/files.txt](sim/files.txt) and rebuild — the guard in [rtl/mcu.sv](rtl/mcu.sv) then instantiates `ref_cpu` with the `mtime_in` pin excluded, and the simulation prints `REFERENCE IMPLEMENTATION OF "cpu.sv" USED!`.

### Zifencei — Instruction-Fetch Synchronisation

`FENCE` and `FENCE.I` look like they should both be no-ops on a machine this simple. One of them is; the other is not, and the difference is worth spelling out.

**Plain `FENCE` genuinely is a no-op here — correctly so.** A fence orders memory operations as seen by *other* observers (other harts, DMA engines, devices); a hart always sees its own accesses in program order regardless. This SoC has a single hart, no DMA, no store buffer, and a Memory stage that stalls the whole pipeline until each Wishbone access is acknowledged ([rtl/memory_stage.sv](rtl/memory_stage.sv), `mem_stall`). Every store is therefore globally visible before the next memory access can even begin, so every `pred`/`succ` combination is satisfied by construction. `FENCE` is decoded, flows down the pipe, and retires without side effects. It is still decoded rather than trapped because compilers emit fences unconditionally for `volatile` MMIO and atomics.

**`FENCE.I` does real work.** Instruction and data memory are one shared BRAM ([rtl/mcu.sv](rtl/mcu.sv) instantiates a single `wishbone_ram`: port A = fetch bus, port B = data bus), and the linker places everything in one `RAM(rwx)` region, so `.text` is writable. There is no instruction cache and no prefetch buffer — but the **pipeline itself is a four-instruction prefetch window**. A store that patches a nearby upcoming instruction lands in RAM *after* that instruction has already been latched into pipeline registers, so the stale copy executes. `FENCE.I` fixes exactly this: Writeback treats a `VALID` `FENCE_I` as a `JUMP` to `next_program_counter_in` (PC+4), squashing Fetch/Decode/Execute/Memory and refetching from the now-updated RAM.

| Aspect | Behaviour |
|---|---|
| Decode | Opcode `0001111` + `funct3=001` only — the reserved `rd`/`rs1`/`imm` fields are ignored, never trapped, as Zifencei v2.0 requires |
| Architectural effect | `status_backwards_out = JUMP` to PC+4 in [rtl/writeback_stage.sv](rtl/writeback_stage.sv); flushes all four younger stages |
| Register file | Never written — `forwarding_out.data_valid` is forced low |
| Ordering | The jump is decided in **Writeback**, strictly downstream of where a store commits in Memory, so a preceding `sw` is always visible to the refetch (≈3 half-cycles of margin) |
| Scope | Local hart only, per spec — there is no second hart to notify |

#### Verification

The assembly test [test/asm/fencei.s](test/asm/fencei.s) patches an upcoming instruction word with `sw`, executes `FENCE.I`, then falls through into the patched location:

| Test | Patch distance | Patched instruction | Assertion | Proves |
|---|---|---|---|---|
| **2** | 2 slots after the store (inside the pipeline window) | `addi a0,zero,11` → `addi a0,zero,22` | `a0 == 22` | The stale prefetched word was discarded |
| **3** | 13 slots (outside the window) | `addi a0,zero,12` → `addi a0,zero,33` | `a0 == 33` | `FENCE.I` does not break the ordinary case |
| **4** | 1 slot, **control flow** | `nop` → `jal zero,+8` | `a0 == 0` (the skipped instruction never ran) | A refetched *jump* is taken — rules out any operand-forwarding explanation |

Every case also reads the patched word back with `lw` and asserts the encoding changed, which separates "the store never landed" from "fetch was stale".

Run with:

```bash
make test/asm/fencei
```

At the writeback level, `FENCE.I` and plain `FENCE` are additionally validated against the golden reference model by SWEEP 14 and SWEEP 15 of [test/sv/test_writeback_compare.sv](test/sv/test_writeback_compare.sv).

#### Implementation Notes

- **The staleness window is 3 instruction slots.** Measured by sweeping the patch distance with `FENCE.I` removed: words at `sw+4`, `sw+8` and `sw+12` executed stale, while `sw+16` and beyond were fresh. Forcing extra stall cycles into the gap does not narrow it — Fetch holds both its PC and its instruction register while stalled, so stalling can never refresh an already-latched instruction.
- **The `sw+12` case is simulator-specific.** At that distance the patch is a same-cycle, cross-port read/write collision in the block RAM. Verilator resolves it deterministically to *read-old*; on real Xilinx BRAM, cross-port collision data is **undefined**. That boundary case is therefore reported as "not reliably fresh" rather than "definitely stale" — which is why [test/asm/fencei.s](test/asm/fencei.s) only ever asserts the *post-`FENCE.I`* behaviour, which is architecturally guaranteed on both simulator and silicon.
- **A taken jump happens to have the same effect — do not rely on it.** Any `JUMP` flushes the pipeline, so on this core a `JAL` also makes a preceding store visible to the refetch. That is an accident of the microarchitecture, not an architectural guarantee; portable software must use `FENCE.I`. (The bootloader's self-copy-then-jump sequence works for precisely this reason.)
- **No cache maintenance is involved.** On a machine with a writeback D-cache and a non-coherent I-cache, `FENCE.I` typically has to drain the store buffer, write back dirty data lines, and invalidate instruction lines. Here there are no caches at all, so the entire obligation reduces to the pipeline flush. `FENCE.I` is still not a data-cache maintenance instruction — it does not order stores against DMA or other harts.

### Branch Predictor Extension

Standard HaDes-V is a **predict-never-taken** machine: every branch is speculatively treated as not-taken, and a taken branch always costs **two bubble cycles** while Fetch/Decode are flushed and the correct PC is reloaded. For code with many backward-taken branches (tight loops), this is a significant throughput loss.

The branch predictor extension eliminates the flush penalty for correctly-predicted branches. It is implemented across four files:

| File | Role |
|---|---|
| [defines/bpredict.sv](defines/bpredict.sv) | `bpredict::bp_data_t` packed struct — 8 bits threading prediction state through the pipeline |
| [rtl/branch_predictor.sv](rtl/branch_predictor.sv) | Submodule instantiated inside Fetch; contains all four prediction algorithms |
| [rtl/fetch_stage.sv](rtl/fetch_stage.sv) | Speculatively updates the PC using the predictor's output |
| [rtl/execute_stage.sv](rtl/execute_stage.sv) | Detects mispredictions instead of flushing on every taken branch |

#### The `bp_data_t` Pipeline Struct

A single 8-bit struct travels with each instruction from Fetch through to Execute, carrying the prediction that was made when that instruction was fetched:

```
struct packed {
    logic       valid;            // 1 = this instruction is an aligned branch with a prediction
    logic       predicted_taken;  // the predictor's guess at fetch time
    logic       was_taken;        // actual outcome (filled in by Execute)
    logic [4:0] index;            // 2-bit counter table index (for feedback update)
}
```

#### Four Prediction Algorithms

The prediction algorithm is selected at runtime by writing to `MHPMEVENT10` (CSR `0x32A`). All four algorithms live in [rtl/branch_predictor.sv](rtl/branch_predictor.sv) and are mux'd by `bp_control_in[1:0]`:

| Mode | `MHPMEVENT10` value | Algorithm | Description |
|---|---|---|---|
| **0** | `0` | **Predict Never Taken** | Default HaDes-V behaviour. All branches are predicted not-taken. No pipeline change for taken branches (they still flush, as before). Zero prediction logic required. |
| **1** | `1` | **Predict Always Taken** | All aligned branches are predicted taken. Good for single loops but causes one flush on every exit. |
| **2** | `2` | **Predict Backward Taken** | Branches with a **negative offset** (bit 31 of the branch displacement = 1, i.e. the target is at a lower address) are predicted taken; forward branches are predicted not-taken. This fixed heuristic is free of state and correct for the dominant loop pattern. |
| **3** | `3` | **2-bit Saturating Counter Array** | Adaptive bimodal predictor. A table of 32 entries, each a 2-bit saturating counter (SNT → WNT → WT → ST). Indexed by `{branch_offset[31], pc[5:2]}` — one bit encodes direction (backward/forward), four bits address the instruction within its cache line. Updated by feedback from Execute after each resolved branch. On reset: the backward half initialises to *Weak Taken* and the forward half to *Weak Not-Taken*, matching the Backward-Taken heuristic as a zero-warmup starting point. |

Only **aligned** branch targets are predicted (`branch_offset[1:0] == 2'b00`). Misaligned branches fall through to the normal `FETCH_MISALIGNED` exception path unchanged.

#### Pipeline Integration

**Fetch stage — speculative PC update.**  
When `predicted_taken = 1`, the Fetch program counter advances to `pc + branch_offset` instead of `pc + 4`. The prediction is registered alongside the instruction word and the program counter into `bp_prediction_reg_out`, which travels through Decode (pass-through pipeline register) to Execute.

```
READY case (wb.ack):
    if (bp_prediction.predicted_taken)
        pc <= pc + bp_branch_offset;   // speculative jump
    else
        pc <= pc + 4;                  // normal advance
```

For mode 0 this is always `pc + 4` — functionally identical to the original core.

**Execute stage — misprediction detection.**  
The old Execute logic flushed the pipeline on *every taken branch*. With the predictor, Execute instead computes `is_mispredicted_branch` and only flushes when the prediction was wrong:

```
is_mispredicted_branch = is_branch
                       && (branch_taken != bp_prediction_in.predicted_taken)
                       && (status_forwards_in == VALID);

jump_detected = (is_mispredicted_branch || is_jump) && VALID;

// Corrected address when the prediction was wrong:
corrected_address = branch_taken ? jump_target : pc_plus_4;

// Architectural next PC, whatever the prediction was:
next_pc = (is_branch && VALID) ? corrected_address
        : is_jump              ? jump_target
        :                        pc_plus_4;
```

When a branch is **correctly** predicted (e.g. the 2-bit counter correctly predicted *taken* for a loop-back branch), `is_mispredicted_branch = false`, `jump_detected = false`, and the pipeline flows without any flush. Fetch has already loaded the right next instruction.

When a branch is **mispredicted**, Execute flushes exactly as it did before, but now redirects to `corrected_address` — the address the CPU *should* have taken — rather than unconditionally to `jump_target`.

`next_pc` is more than the flush address: it travels with the instruction to Writeback as `next_program_counter`, and Writeback uses it as `MEPC` when an interrupt is taken right after that instruction (the retiring instruction *J* in the interrupt's `JUMP` cycle, or the saved next PC of *I* when *J* is a bubble or carries an exception). It must therefore be the architectural successor, independent of the prediction. It used to be `is_mispredicted_branch ? corrected_address : …`, so a **correctly predicted taken** branch carried `pc + 4`, and an interrupt right after it returned to the *not-taken* path: loops exited early, a skipped instruction ran, and an `ECALL` at the branch target was skipped. Under FreeRTOS with the predictor on this caused `configASSERT`s, lost yields and hangs. Mode 0 never predicts taken, so it was not affected, and the new expression is identical to the old one when `predicted_taken = 0`. The `VALID` gate keeps `pc + 4` for a squashed branch, as the golden `ref_execute_stage` does. Regressions: [bpirq.s](test/asm/bpirq.s), [bpirq2.s](test/asm/bpirq2.s), [bpirq3.s](test/asm/bpirq3.s), and [test_execute_bpred_nextpc.sv](test/sv/test_execute_bpred_nextpc.sv), which checks `next_program_counter` against the golden execute stage for every prediction.

**Feedback loop.**  
After Execute resolves a branch, it drives `bp_feedback_out` combinationally back to the Fetch stage (directly via a wire in [cpu.sv](rtl/cpu.sv), bypassing Memory and Writeback):

```
bp_feedback_out.valid          = is_branch && VALID && !STALL;
bp_feedback_out.was_taken      = branch_taken;
bp_feedback_out.predicted_taken = bp_prediction_in.predicted_taken;
bp_feedback_out.index          = bp_prediction_in.index;
```

The branch predictor's `always_ff` block samples this at the next posedge and updates `counter_store[update_index]`. The feedback also reaches Writeback (same wire) for the performance counters.

#### New CSRs — Branch Predictor Control and Monitoring

Five new CSRs are implemented in [rtl/writeback_stage.sv](rtl/writeback_stage.sv). All are read/write. CSR addresses are already defined in [defines/csr.sv](defines/csr.sv).

| CSR name | Address | Description |
|---|---|---|
| `MHPMEVENT10` | `0x32A` | **Algorithm select.** Bits [1:0] choose the active predictor: 0 = Never Taken, 1 = Always Taken, 2 = Backward Taken, 3 = 2-bit Counter. Write this before running a benchmark to switch modes. |
| `MHPMCOUNTER10` | `0xB0A` | **NN** — count of branches where prediction = *not-taken* **and** actual = *not-taken* (correct prediction). |
| `MHPMCOUNTER11` | `0xB0B` | **NT** — count of branches where prediction = *not-taken* **but** actual = *taken* (misprediction — predictor too conservative). |
| `MHPMCOUNTER12` | `0xB0C` | **TN** — count of branches where prediction = *taken* **but** actual = *not-taken* (misprediction — over-predicted; expected once per loop at the exit). |
| `MHPMCOUNTER13` | `0xB0D` | **TT** — count of branches where prediction = *taken* **and** actual = *taken* (correct prediction). |

A correct predictor on a tight loop of *N* iterations produces `TT = N−1`, `TN = 1`, `NT = 0`, `NN = 0`. Accuracy = `(NN + TT) / (NN + NT + TN + TT)`.

Reading and writing from assembly:

```asm
# Select 2-bit counter mode
li   t0, 3
csrw mhpmevent10, t0         # or: csrw 0x32A, t0

# Reset all four counters before a run
csrwi mhpmcounter10, 0       # NN
csrwi mhpmcounter11, 0       # NT
csrwi mhpmcounter12, 0       # TN
csrwi mhpmcounter13, 0       # TT

# ... run benchmark ...

# Read results
csrr  a0, mhpmcounter13      # TT (correct taken)
csrr  a1, mhpmcounter11      # NT (mispredictions on taken branches)
```

#### Verification

The assembly test [test/asm/bpred.s](test/asm/bpred.s) verifies all three non-trivial predictor modes without using UART (pass/fail reported directly through the test peripheral at `TEST_ADDRESS = 0x480000`):

| Test | Mode | Loop iterations | Assertion | Expected result |
|---|---|---|---|---|
| **A** | 0 — Never Taken | 50 | NT ≥ 48 (predictor misses on almost every taken branch) | Confirms baseline penalty is real |
| **B** | 3 — 2-bit Counter | 50 | TT ≥ 47 **and** NT = 0 (predictor correct from first iteration due to *Weak Taken* initialisation of backward half) | Confirms adaptive predictor works |
| **C** | 1 — Always Taken | 20 | TT = 19 (all loop iterations correct) **and** TN = 1 (one misprediction at the exit branch) | Confirms always-taken mode and counter precision |

Run with:

```bash
make test/asm/bpred
```

Interrupts next to predicted branches are covered by four regression tests. The golden CPU has no predictor, ignores `MHPMEVENT10` and passes all three asm tests, so it is a valid twin for them:

| Test | What it sweeps | Check |
|---|---|---|
| [test/asm/bpirq.s](test/asm/bpirq.s) | Modes 0–3 × IRQ delays 1–80 over a 40-iteration backward loop. | The loop count must be 40. Prints `M<mismatches> I<irqs>`. |
| [test/asm/bpirq2.s](test/asm/bpirq2.s) | Modes 0–3 × delays 1–32, with three shapes: a backward loop, a forward branch over a poison instruction, and a load-use at the target. | Count exact, no poison executed. |
| [test/asm/bpirq3.s](test/asm/bpirq3.s) | The Writeback paths where `MEPC` comes from the *interrupted* branch's next PC. The branch is followed by a bubble (CSR-use stall at its target) or by an `ECALL` at its target. | Exact loop count, one `ECALL` per iteration, no poison. Prints `D/E/F` mismatches. |
| [test/sv/test_execute_bpred_nextpc.sv](test/sv/test_execute_bpred_nextpc.sv) | 20,000 random branches with random prediction and status, against `ref_execute_stage`. | `next_program_counter` must match golden for every prediction. Flushes happen exactly on mispredictions, to the golden next PC. |

```bash
make test/asm/bpirq test/asm/bpirq2 test/asm/bpirq3 test/sv/test_execute_bpred_nextpc
```

Under an RTOS, `FRTOS_BPRED=<mode>` makes a FreeRTOS program write `MHPMEVENT10` at start-up (the golden CPU ignores it and stays a valid twin). The campaign sets `bpred` (stress/minimal/mzba/full with the predictor on) and `breaker`/`breaker2`/`breaker-long` (the `brk` program, including random run-time mode changes) run the predictor in modes 1–3 against the golden CPU. The predictor-off sets never switch it on. `test/trapsweep` family `bp` sweeps interrupts around predicted branches in every mode:

```bash
python3 test/freertos/campaign.py --set bpred --seeds 4
python3 test/freertos/campaign.py --set breaker --seeds 8 --run-cycles 20000000
python3 test/trapsweep/sweep.py run --fam bp
```

#### Implementation Notes

- **No BTB.** This is a pure bimodal predictor — no branch-target buffer. The target address is always computed by Decode from the immediate field. Prediction only decides whether to speculatively advance the PC; misses are corrected in Execute with the same mechanism as the original taken-branch flush.
- **Only `Bxxx` instructions** (opcode `7'b1100011`) are predicted. `JAL` and `JALR` are unconditional and always cause a flush via `is_jump`, unchanged from the original design.
- **Alignment guard.** `predicted_taken` is suppressed for branches whose target is not 4-byte aligned (`branch_offset[1:0] != 2'b00`). These fall through to the existing `FETCH_MISALIGNED` exception path.
- **Mode 0 is zero-overhead.** When `MHPMEVENT10 = 0`, `predicted_taken = 0` unconditionally. `is_mispredicted_branch` reduces to `is_branch && branch_taken && VALID`, which is the original `jump_detected` formula, and `next_pc` reduces to the original expression. The pipeline behaves identically to unmodified HaDes-V.
- **The prediction never reaches architectural state.** It only decides whether Execute flushes. `next_program_counter`, which becomes `MEPC` for an interrupt taken right after the branch, is always the resolved successor (see [Execute stage](#branch-predictor-extension) above).
- **Simulator echo.** [lib/wishbone/wishbone_uart.sv](lib/wishbone/wishbone_uart.sv) includes an `always @(posedge clk)` block that calls `$write("%c", byte)` whenever a TX buffer write is detected, echoing UART output to Verilator's stdout. This is purely a simulation convenience; `$write` is ignored by synthesis tools.

## System Architecture

### Memory Subsystem

The core has **two completely independent memory ports** — an instruction-side port for Fetch and a data-side port for Memory — each a separate Wishbone master. This is a classic Harvard-style split at the boundary of the core:

- On-chip RAM is implemented by [lib/wishbone/wishbone_ram.sv](lib/wishbone/wishbone_ram.sv) as a **true dual-port block RAM**: `port_a` is bound to the fetch bus and `port_b` to the data bus, so an instruction fetch and a load/store land on the same cycle without arbitration. An `init.mem` hex image is loaded into the array at elaboration via `$readmemh`, which is how bootloader and test programs are pre-seeded.
- Because the fetch and data buses never share a master, there is **no structural contention** between the pipeline's fetch stream and its load/store traffic — the only stall the bus can introduce on HaDes-V is a slow-ack from a peripheral, which propagates through Memory's `STALL`.
- Writes are byte-enabled: the 4-bit `sel` strobe on Wishbone is driven by Memory to match SB / SH / SW widths, and the RAM honours each lane individually.
- Reset vector is derived from the RAM base in [defines/constants.sv](defines/constants.sv): `RESET_ADDRESS = MEMORY_START << 2 = 0x0004_0000` (byte address). Fetch powers up on that PC.

### System-Level Memory Map

All masters share a single 32-bit word-addressed address space decoded by [lib/wishbone/wishbone_interconnect.sv](lib/wishbone/wishbone_interconnect.sv). The numbers below come straight from [defines/constants.sv](defines/constants.sv):

| Region | Base (word) | Base (byte) | Size | Backed by |
|---|---|---|---|---|
| **RAM** (code + data) | `0x0001_0000` | `0x0004_0000` | 8 KiW ≈ 32 KiB | [wishbone_ram.sv](lib/wishbone/wishbone_ram.sv) |
| **LEDs** | `0x0008_0000` | `0x0020_0000` | 1 word | [wishbone_leds.sv](lib/wishbone/wishbone_leds.sv) |
| **Buttons** | `0x0008_1000` | `0x0020_4000` | 1 word | [wishbone_buttons.sv](lib/wishbone/wishbone_buttons.sv) |
| **Switches** | `0x0008_2000` | `0x0020_8000` | 1 word | [wishbone_switches.sv](lib/wishbone/wishbone_switches.sv) |
| **7-seg display** | `0x0008_3000` | `0x0020_C000` | 1 word | [wishbone_segments.sv](lib/wishbone/wishbone_segments.sv) |
| **UART** | `0x0008_4000` | `0x0021_0000` | 1 word | [wishbone_uart.sv](lib/wishbone/wishbone_uart.sv) |
| **Timer** | `0x0008_5000` | `0x0021_4000` | 5 words | [wishbone_timer.sv](lib/wishbone/wishbone_timer.sv) |
| **VGA framebuffer** | `0x0009_0000` | `0x0024_0000` | 38 400 words (640×480 @ 4bpp) | [wishbone_vga.sv](lib/wishbone/wishbone_vga.sv) |
| **Test device** | `0x0012_0000` | `0x0048_0000` | 5 words | [wishbone_test.sv](lib/wishbone/wishbone_test.sv) |

Any access that misses every window raises a bus `err` — which surfaces in the CPU as a `LOAD_FAULT` or `STORE_FAULT` trap.

### The Wishbone Fabric

HaDes-V speaks the **Wishbone B4 classic (non-pipelined) handshake** throughout — small, synchronous, and easy to reason about.

**Bus signals** — defined as a SystemVerilog interface in [lib/wishbone/wishbone_interface.sv](lib/wishbone/wishbone_interface.sv). Master drives `cyc`, `stb`, `we`, `adr`, `sel`, `dat_mosi`; slave drives `ack`, `err`, `dat_miso`. `cyc` marks an active bus cycle, `stb` marks the specific beat, `ack` closes a successful transfer, and `err` aborts one. The `.master` / `.slave` modports make the direction explicit at every instantiation.

**Interconnect.** The shared data bus is fanned out to 9 slaves by [wishbone_interconnect.sv](lib/wishbone/wishbone_interconnect.sv), which:

1. Decodes the master's address against each slave's `{BASE, SIZE}` window.
2. Routes `stb` only to the selected slave, OR-reduces `ack`/`err`, and muxes `dat_miso` back.
3. Flags `invalid_address` as a bus error if no window matches.
4. Runs a **255-cycle timeout counter** that asserts `err` if a slave never acknowledges — preventing a stuck peripheral from hanging the pipeline forever.

The fetch bus is simpler: it talks directly to RAM's port A, no interconnect needed.

### Peripherals

Every peripheral is a Wishbone slave living in [lib/wishbone/](lib/wishbone/). All of them sit on the CPU's data bus; three of them generate interrupts that the core sees as either *external* or *timer*.

| Peripheral | File | Registers / Behaviour | Interrupt |
|---|---|---|---|
| **RAM** | [wishbone_ram.sv](lib/wishbone/wishbone_ram.sv) | Dual-port byte-enabled BRAM, `init.mem`-preloaded. | — |
| **LEDs** | [wishbone_leds.sv](lib/wishbone/wishbone_leds.sv) | Single register driving the 16 Basys3 LEDs. | — |
| **Buttons** | [wishbone_buttons.sv](lib/wishbone/wishbone_buttons.sv) | Read-only register with the 5 debounced push-buttons (center button is reset). | — |
| **Switches** | [wishbone_switches.sv](lib/wishbone/wishbone_switches.sv) | Read-only register with the 16 slide switches. | — |
| **7-Segment** | [wishbone_segments.sv](lib/wishbone/wishbone_segments.sv) | Write a 32-bit word → rendered as 4 hex digits with anode multiplexing. | — |
| **UART** | [wishbone_uart.sv](lib/wishbone/wishbone_uart.sv) + [uart_tx.sv](lib/peripherals/uart_tx.sv) / [uart_rx.sv](lib/peripherals/uart_rx.sv) | 115200 8-N-1 by default; parametrised by `BAUD_RATE` and `CLK_FREQUENCY_MHZ`. TX/RX FIFOs exposed through the register file. | **External** (RX ready) |
| **Timer** | [wishbone_timer.sv](lib/wishbone/wishbone_timer.sv) | Programmable down-counter clocked off the CPU clock; reload, enable, and current-value registers. | **Timer** |
| **VGA** | [wishbone_vga.sv](lib/wishbone/wishbone_vga.sv) + [vga_memory.sv](lib/wishbone/vga_memory.sv) | 640×480 @ 60 Hz framebuffer, 4-bit packed colour (8 pixels per word), clocked off a dedicated `clk_vga`. | — |
| **Test device** | [wishbone_test.sv](lib/wishbone/wishbone_test.sv) | Simulation-only: pass/fail/halt reporting, a cycle counter, a deliberately-stalling register, and a down-counter interrupt for testbenches. | **External** |

In [mcu.sv](rtl/mcu.sv), the `external_interrupt` line into the CPU is the logical OR of the UART and test-device interrupts, while the timer peripheral is wired straight into `timer_interrupt_in`. Every async input (buttons, switches, UART RX) passes through [lib/synchronizer.sv](lib/synchronizer.sv) before entering the clock domain, keeping the design metastability-safe at the FPGA pads.

### Clocks & Reset

HaDes-V is a three-clock design, all generated on the FPGA from a single crystal — see [defines/clk_params.sv](defines/clk_params.sv) and [mcu.sv](rtl/mcu.sv):

| Clock | Used by | Note |
|---|---|---|
| `clk` | CPU core, most peripherals | Main system clock. |
| `clk_mem` | [wishbone_ram.sv](lib/wishbone/wishbone_ram.sv) | **Inverted** copy of `clk`. Lets the RAM read and deliver data within the same `clk` cycle, giving single-cycle loads without pipeline stalls. (Explicitly flagged as "do not replicate" elsewhere in the design.) |
| `clk_vga` | [wishbone_vga.sv](lib/wishbone/wishbone_vga.sv) | 25 MHz VGA pixel clock, asynchronous to `clk`. |

Reset is driven from the Basys3 center button, synchronised into `clk`, and distributed to every module as a synchronous `rst`. A power-on `initial rst = 1` in [mcu.sv](rtl/mcu.sv) guarantees a clean reset after FPGA configuration.

## Software Runtime

A bare-metal C program targets HaDes-V by linking against the runtime in [std/](std/) with the RISC-V GCC toolchain at `/opt/riscv32i/bin/riscv32-unknown-elf-gcc`. The build is driven by the top-level [Makefile](Makefile).

### FreeRTOS

HaDes-V+ runs the unmodified official RISC-V port of FreeRTOS (V11.1.0+) in machine mode, using the memory-mapped machine timer (`mtime` at `0x00214004`, `mtimecmp` at `0x0021400C`) as the tick source. No instruction-set extension is required: the port needs only RV32I, Zicsr, `mstatus.MIE`/`MPIE`, `mie.MTIE`/`MEIE`, direct-mode `mtvec`, `mepc`, `mcause` and `MRET`. Programs can be built for `rv32i`, `rv32im` or `rv32im_zba`.

**FreeRTOS is used here as a test, not a demo.** A system that merely boots proves little: interrupt-handling defects appear only when an interrupt meets a particular instruction in a particular pipeline cycle, and a tick-synchronised demo ran more than 5,000 ticks on a core that still had three such defects. The programs in [`test/freertos/`](test/freertos) therefore randomise their interrupt timing from a run seed, check themselves continuously (queue sequences, critical sections, register integrity across context switches, tick drift, the UART transcript), and run both on HaDes-V+ and on the frozen golden CPU from [`ref/`](ref). A run that passes on the golden CPU and fails on HaDes-V+ is a defect of the core.

This found six defects, all fixed and each covered by a directed regression test that fails when its fix alone is reverted:

| Defect | Effect under FreeRTOS | Regression |
|---|---|---|
| An exception in Writeback was dropped when an interrupt became pending in the same cycle | A yield `ECALL` vanished; the scheduler lists were corrupted | [trapirq.s](test/asm/trapirq.s) |
| A trap taken with `MIE=0` left `MPIE=1` | A yield inside a critical section returned with interrupts enabled | [trapmpie.s](test/asm/trapmpie.s) |
| The instruction in flight at a sequential interrupt lost its CSR write | `portDISABLE_INTERRUPTS` was lost | [csrirq.s](test/asm/csrirq.s) |
| An interrupt during a slow bus access re-executed the access after the handler | Doubled UART characters | [memirq.s](test/asm/memirq.s) |
| With the branch predictor on, an interrupt after a correctly predicted taken branch resumed on the not-taken path | Assertions, lost yields and hangs | [bpirq.s](test/asm/bpirq.s) and variants |
| An interrupt right after `csrw mtvec` used the old vector (the golden CPU shares this defect) | None in practice (FreeRTOS writes `mtvec` once) | [mtvecirq.s](test/asm/mtvecirq.s) |

On the fixed core the final differential campaign passed **794 of 794** FreeRTOS runs (102 of them with the branch predictor enabled, about 14.7 billion simulated cycles), with every one of the 523 golden-CPU twin runs agreeing, and the independent model in [`test/trapsweep/`](test/trapsweep) found no architectural error across its full interrupt-offset sweep and random-program fuzzing.

**Running it.** The FreeRTOS sources are vendored, unmodified, in [`third_party/freertos/`](third_party/freertos/README.md) at the tested commits, so no download step is needed. The guide, [docs/FREERTOS.md](docs/FREERTOS.md), covers setup (including building outside a disk that cannot execute programs), reading the output, every setting, and writing your own program.

```bash
make freertos-list                        # available programs
make freertos APP=minimal                 # boot FreeRTOS on HaDes-V+
make freertos-compare APP=stress SEED=7   # same program on HaDes-V+ and on the golden CPU
make freertos-stress                      # differential campaign, HaDes-V+ vs golden CPU
make freertos-new NAME=myapp              # start your own program from the template
make freertos-shell                       # interactive shell on the simulated UART (Ctrl-] quits)
```

Each run ends with a single verdict line — `FREERTOS RESULT: PASS`, `FAIL`, `HANG` or `CRASH` — and `make` exits with status 0 only on `PASS`.

### Linker Script & Memory Layout

[std/hades-v.ld](std/hades-v.ld) defines a single `RAM` region (`ORIGIN = 0x40000`, `LENGTH = 32K`) matching the Wishbone RAM window, and arranges the image as:

```
┌─────────────────────────────────┐  0x40000   <- RESET_ADDRESS
│ .reset      - __reset entry     │
├─────────────────────────────────┤
│ .text       - program code      │
│ .rodata                         │
│ .data       - initial data      │
│ .sdata / .sbss                  │
│ .bss                            │
│ ...stack grows down...          │
├─────────────────────────────────┤  __ram_end - 4 K
│ .boot       - bootloader        │
│ .reserved                       │
└─────────────────────────────────┘  0x48000   = __ram_end
```

The linker exports `__ram_start`, `__ram_end`, `__boot_start`, `__boot_end`, `__boot_load`, and `__global_pointer$` — the last one is loaded into `gp` in the startup code to enable GCC's linker relaxation (±2 KB small-data accesses). `NOCROSSREFS_TO` directives prevent the bootloader from accidentally touching the application sections it's busy replacing.

### C Startup

[std/src/start.c](std/src/start.c) is the first C code executed after `__reset`: it sets up `gp` and `sp`, zeroes `.bss`, copies `.data` into RAM if needed, and calls `main()`. [std/src/boot.c](std/src/boot.c) and [std/src/boot_internal.c](std/src/boot_internal.c) implement a UART-based bootloader that can receive a new image over the serial line and overwrite the application region at runtime — `run_bootloader()` from [std/include/boot.h](std/include/boot.h) is what the Basys3 demo calls when you hold a button at reset.

### Peripheral & Helper Headers

[std/include/peripherals.h](std/include/peripherals.h) exposes every MMIO region as typed `volatile` pointer macros — for example, `*LEDS_ADDRESS = value;` drives the 16 LEDs, `*UART_BUFFER_ADDRESS` is the UART FIFO, `TIMER_MTIMECMP_ADDRESS` sets a timer compare. Bit indices for button positions and UART status flags are also provided.

[std/include/helperfunctions.h](std/include/helperfunctions.h) layers ergonomic helpers on top: 7-segment digit encoding (`number2segment`), VGA primitives (`setPixel`, `clearPixel`, a `vga_color_t` palette of 16 colours, `rowCol2pxIdx` for 640×480 addressing), and machine/external/timer/UART interrupt enable wrappers (`enableDisable_machineInterrupts`, etc.). [test/c/basys3_demo.c](test/c/basys3_demo.c) is the canonical example that exercises every peripheral using these helpers.

## Tools and Dependencies

The following tools are required for the lab exercises (details in the [Instruction Guide][instrguide]):
- **[SystemVerilog][sv]**: HDL for processor and peripheral design.
- **[RISC-V Toolchain][rvgcc]**: Compiler for RV32I assembly and C programs.
- **[Vivado][vivado]**: FPGA synthesis and programming.
- **[Verilator][verilator]**: Open-source HDL simulator.
- **[GTKWave][gtkwave]**: Waveform viewer for debugging simulations.

## Building, Running, and Debugging

All flows are driven by [Makefile](Makefile) targets (`make help` prints this list):

```
make test/asm/<name>     # assemble, simulate, and run an asm program
make test/c/<name>       # compile C + runtime, simulate, and run
make test/sv/<name>      # build and run a SystemVerilog testbench
make show                # open the FST waveform of the most recent test in GTKWave
make bootloader          # build the UART bootloader image
make synthesis           # synthesise the full MCU for Basys3 via Vivado
make clean               # wipe build artefacts
make freertos APP=<name> # build and run a FreeRTOS program (make freertos-list, docs/FREERTOS.md)
```

All build output goes to `build/` inside the repository unless `BUILD_DIR=/abs/path` is given on the command line or `HADES_BUILD_DIR` is set in the environment; every target follows it. This is how to work from a checkout on a disk that cannot execute programs (such as an NTFS data disk): the simulators are built and run from the build directory, and the golden-model libraries are copied there.

The simulator is [Verilator][verilator]; synthesis uses [Vivado][vivado] 2023.2 (default path `/opt/Xilinx/Vivado/2023.2/`). Wave dumps land in the repository root as `*.fst` files and can be inspected with [GTKWave][gtkwave].

### Test Hierarchy

The [test/](test/) tree has three progressively integrative tiers, plus two system-level stress suites:

| Tier | Location | What it exercises | Invocation |
|---|---|---|---|
| **Assembly** | [test/asm/](test/asm/) | Small hand-written `.s` programs targeting a specific ISA feature — e.g. [trap.s](test/asm/trap.s) for the full exception/interrupt path, [ops.s](test/asm/ops.s) for every RV32I instruction, [forwarding.s](test/asm/forwarding.s) for the data-hazard network, [bpred.s](test/asm/bpred.s) for the branch predictor (modes 0/1/3, counter verification), [mul.s](test/asm/mul.s) / [div.s](test/asm/div.s) for the `M` extension, [trapirq.s](test/asm/trapirq.s) / [trapmpie.s](test/asm/trapmpie.s) / [csrirq.s](test/asm/csrirq.s) / [memirq.s](test/asm/memirq.s) for interrupt-vs-trap and interrupt-vs-bus timing sweeps, [bpirq.s](test/asm/bpirq.s) / [bpirq2.s](test/asm/bpirq2.s) / [bpirq3.s](test/asm/bpirq3.s) for interrupts landing next to correctly predicted taken branches in every predictor mode, [mtvecirq.s](test/asm/mtvecirq.s) for an interrupt right after a `csrw mtvec`. | `make test/asm/trap` |
| **C** | [test/c/](test/c/) | Full C programs linked against [std/](std/). [bootloader.c](test/c/bootloader.c) is the UART loader; [basys3_demo.c](test/c/basys3_demo.c) wiggles every on-board peripheral; [m_extension.c](test/c/m_extension.c) diffs the `M` hardware against libgcc's software routines. | `make test/c/basys3_demo` |
| **SystemVerilog** | [test/sv/](test/sv/) | Module-level benches that run DUT vs. REF side-by-side and compare every cycle. Examples: [test_writeback_compare.sv](test/sv/test_writeback_compare.sv), [test_execute_compare.sv](test/sv/test_execute_compare.sv), [test_decode_hazard.sv](test/sv/test_decode_hazard.sv), [test_execute_bpred_nextpc.sv](test/sv/test_execute_bpred_nextpc.sv) (Execute with a branch prediction applied, against the predictor-less reference). Where the frozen reference cannot help — `Zba`, `M` — the bench carries its own golden model instead: [test_m_execute.sv](test/sv/test_m_execute.sv). | `make test/sv/test_writeback_compare` |
| **FreeRTOS** | [test/freertos/](test/freertos/) | FreeRTOS V11 programs (`minimal`, `stress`, `full` standard demo, `mzba`, and the `brk` RTOS breaker) with randomised, desynchronised interrupt timing, plus `campaign.py`, which runs every configuration on the DUT and on the golden CPU. `FRTOS_BPRED=1..3` runs a program with the branch predictor on. User guide: [docs/FREERTOS.md](docs/FREERTOS.md); details: [test/freertos/README.md](test/freertos/README.md). | `make freertos APP=stress`, `make freertos-compare APP=stress`, `make freertos-stress` |
| **Trap sweep** | [test/trapsweep/](test/trapsweep/) | Interrupts swept over every cycle offset around 532 distinct probe instruction sequences, plus random programs. Every run is checked by an independent Python ISA model (`iss.py`) and compared with the golden CPU. This is the oracle for extensions that the frozen golden models cannot check. See [test/trapsweep/README.md](test/trapsweep/README.md). | `python3 test/trapsweep/sweep.py run` |

Together these give coverage at the instruction level, the system level, and the per-module bit-level — catch a bug as early as possible in whichever tier first exposes it.

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
[formal/README.md](formal/README.md) explains the installation, the proof structure, the
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

## Reference-Library ("Jigsaw Puzzle") Flow

HaDes-V can be built stage-by-stage without ever holding a broken pipeline, and the reason is the [ref/](ref/) directory. Every pipeline module ships in two forms:

- **The implementation** in [rtl/](rtl/) — plain, editable SystemVerilog.
- **A golden reference** in [ref/](ref/) — a pair of `ref_<stage>.sv` / `ref_<stage>_inner.sv` wrappers plus a precompiled `libref_<stage>_inner.so` produced by Verilator with `--protect-lib`. The `.so` is the actual implementation; the `.sv` wrapper is a DPI-C shim that makes it look like a normal SystemVerilog module to the simulator.

Testbenches in [test/sv/](test/sv/) instantiate **both** — the DUT and the golden REF — in parallel, clock them with the same stimulus, and flag any cycle where their outputs diverge. Because each stage has the same port list as its reference, you can freely mix: use your fetch + reference decode + your execute + reference memory + reference writeback, and the processor still runs a real program. That is what makes the "solve the puzzle one piece at a time" workflow possible.

## Repository Structure

- [`defines/`](defines): HDL constants and definitions.
- [`docs/`](docs): User guides; [FREERTOS.md](docs/FREERTOS.md) covers running FreeRTOS on the core.
- [`lib/`](lib): Peripheral modules (e.g., UART, timer).
- [`ref/`](ref): Precompiled reference libraries.
- [`formal/`](formal): Formal proof of the multiply/divide unit (SymbiYosys, k-induction); see [formal/README.md](formal/README.md).
- [`rtl/`](rtl): The processor implementation — pipeline stages, register file, instruction decoder, and branch predictor.
- [`synth/`](synth): Synthesis scripts and FPGA configuration files.
- [`test/`](test): Test files in assembly (`asm`), C (`c`), and SystemVerilog (`sv`); FreeRTOS programs and the differential campaign (`freertos`); the interrupt-offset sweeps with their independent ISA model (`trapsweep`).
- [`third_party/`](third_party): Third-party sources, included unmodified: the FreeRTOS kernel, its RISC-V port, the FreeRTOS standard demo tasks and FreeRTOS+CLI, at pinned upstream commits (MIT); see [third_party/freertos/README.md](third_party/freertos/README.md).
- [`.vscode/`](.vscode): Configuration files for Visual Studio Code.

Refer to the [Instruction Guide][instrguide] for a detailed project structure.

## Upstream Course Material

HaDes-V originates as the lab project for [Microcontroller Design, Lab][lvref] at Graz University of Technology, where students implement each pipeline stage themselves and validate it against the reference models in [`ref/`](ref) — the flow described under [Reference-Library](#reference-library-jigsaw-puzzle-flow). The upstream project provides the staged exercises — basic pipeline implementation, then memory/writeback and CSRs, then a free-form extension project — together with an [Instruction Guide][instrguide] (exercise instructions are in its Chapter 4) and a closed-source test-bench system available to educators on request.

A closed-source test-bench system is also available to educators for teaching purposes; see [Contact](#contact).

**If you are taking that course, work from the upstream template rather than this repository.** It is the canonical starting point, and implementing the stages yourself is the entire point of the exercise.

## Attribution and Upstream

This repository is a derivative work. The HaDes-V core, its build system, the Wishbone peripheral fabric, the reference models in [`ref/`](ref), and the original documentation were created by **Tobias Scheipel, David Beikircher, and Florian Riedl** (Embedded Architectures & Systems Group, Graz University of Technology) and published as an Open Educational Resource. Their copyright notices are retained in every file they authored, and both upstream licences apply unchanged — see [License](#license) below. If you use this work academically, please cite the upstream authors' publication linked under [Publication](#publication--risc-v-summit-europe-2025).

The following are original contributions by **Emon Sarkar**, added after completing the upstream lab:

- The **M**, **Zba**, and **Zicntr** extensions, and the substantiation of **Zifencei**
- The **bimodal branch predictor** and its performance-counter CSRs
- Eight correctness fixes to the base core: decoder `rd` handling for S/B-type instructions, `FENCE` forwarding suppression in the Memory stage, and six trap/interrupt defects found by running FreeRTOS
- The formal proof of the multiply/divide unit ([`formal/`](formal))
- FreeRTOS support ([`test/freertos/`](test/freertos), [docs/FREERTOS.md](docs/FREERTOS.md)) and the independent trap-sweep model ([`test/trapsweep/`](test/trapsweep))
- The test suites in [`test/asm/`](test/asm) and [`test/sv/`](test/sv) beyond the upstream set, including the golden-comparison, encoding-sweep, and adversarial suites
- Repairs to the synthesis flow ([`synth/synth.tcl`](synth/synth.tcl)) and the architectural documentation in this README

**Third-party component: FreeRTOS.** The directory [`third_party/freertos/`](third_party/freertos/README.md) contains unmodified sources of [FreeRTOS](https://www.freertos.org) — the FreeRTOS kernel with its RISC-V port, the FreeRTOS standard demo tasks, and FreeRTOS+CLI — taken from the [FreeRTOS-Kernel](https://github.com/FreeRTOS/FreeRTOS-Kernel) and [FreeRTOS](https://github.com/FreeRTOS/FreeRTOS) repositories at pinned commits. FreeRTOS is Copyright (C) Amazon.com, Inc. or its affiliates and is distributed under the MIT licence; it is neither part of the upstream HaDes-V work nor among the original contributions listed above. Its licence texts, the exact upstream commits and the complete list of vendored files are given in [third_party/freertos/README.md](third_party/freertos/README.md).

If you are looking for the original teaching material rather than this extended version, please go to the upstream source linked above — it is the canonical reference and the appropriate starting point for coursework.

## License

This OER and all of its creative material (text, logos, etc.) is licensed under the **CC BY 4.0 International License**, allowing you to share and adapt the resource, provided appropriate credit is given. See the full license details [here](https://creativecommons.org/licenses/by/4.0/).

>![CCBY](https://mirrors.creativecommons.org/presskit/buttons/88x31/svg/by.svg)\
>Tobias Scheipel, David Beikircher, Florian Riedl\
>TU Graz 2024

All the software files included in the repository are licensed under the **MIT License**. See the [LICENSE](./LICENSE) file for details. The third-party FreeRTOS code in [`third_party/freertos/`](third_party/freertos/README.md) is likewise MIT-licensed, but under its own licence and copyright (Amazon.com, Inc. or its affiliates); its licence texts are included in that directory.

Contributions to this OER are welcome and encouraged! The LaTeX sources for the [Instruction Guide][instrguide] can be requested as well. For more OERs, visit [https://www.scheipel.com/oer](https://www.scheipel.com/oer).

## Contact

For questions about the **extensions in this repository** (M, Zba, Zicntr, the branch predictor, or the verification work), please open an issue here.

For questions about the **upstream HaDes-V project**, its licensing, or the closed-source test-bench system, contact the original authors:
- **Email**: [tobias.scheipel@tugraz.at](mailto:tobias.scheipel@tugraz.at)
- **Website**: [https://www.scheipel.com/oer](https://www.scheipel.com/oer)

## Publication @ RISC-V Summit Europe 2025
The upstream authors published the HaDes-V OER at the [RISC-V Summit Europe 2025](https://riscv-europe.org/summit/2025/) as a [Poster](https://graz.elsevierpure.com/files/93678000/HaDes_V_Poster-CR_v1.pdf) and an extended [Abstract Paper](https://www.scheipel.com/wp-content/uploads/2025/05/HaDes_V_RISC_V_Summit_camera_ready-1.pdf). 

It was also featured on the official RISC-V International [Blog](https://riscv.org/blog/2025/05/hades-v-learning-by-puzzling-a-modular-approach-to-risc-v-processor-design-education/). Please cite that work rather than this repository when referring to the HaDes-V architecture itself.

