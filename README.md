[instrguide]:https://repository.tugraz.at/oer/nytm4-grv34
[lvref]:https://online.tugraz.at/tug_online/wbLv.wbShowLVDetail?pStpSpNr=525082
[vivado]:https://www.xilinx.com/support/download.html
[verilator]:https://verilator.org
[basys]:https://digilent.com/reference/programmable-logic/basys-3/reference-manual?redirect=1
[gtkwave]:https://gtkwave.sourceforge.net/
[sv]:https://doi.org/10.1109/IEEESTD.2018.8299595
[rvgcc]:https://github.com/riscv-collab/riscv-gnu-toolchain

![image](https://www.scheipel.com/wp-content/uploads/2024/12/hades_logo.svg)
# Microcontroller Design, Lab: HaDes-V

***Ever thought about developing a processor from scratch and bringing it to life on an FPGA? With HaDes-V, you'll delve into hardware design and create your own pipelined 32-bit RISC-V processor, mastering efficient computing principles and practical FPGA implementation.***

The [Instruction Guide][instrguide] and this source code template for the [**Microcontroller Design, Lab**][lvref] is an **Open Educational Resource (OER)** developed by [Tobias Scheipel](https://www.scheipel.com), David Beikircher, and Florian Riedl, Embedded Architectures & Systems Group at Graz University of Technology. It is designed for teaching and learning microcontroller design and hardware description languages, using the **HaDes-V architecture**, a RISC-V-based processor.

## Project Overview

The lab is structured around designing, simulating, and synthesizing the HaDes-V processor. It integrates software and hardware design exercises using SystemVerilog, assembly, and C.

One of the standout features of HaDes-V is its **modular design**:  
- Implement each module of the pipeline individually in the [`rtl/`](rtl) directory and cross-check its functionality using pre-compiled Verilator libraries provided in [`ref/`](ref).  
- Validate that your implementation fits seamlessly into the overall processor—just like solving a jigsaw puzzle.  
- Focus on one stage at a time, integrate step-by-step, and build confidence as you progress.  

Key topics covered:
- **RISC-V Architecture**: Hands-on implementation of a pipelined processor with custom extensions.
- **FPGA Development**: Using the AMD [Vivado][vivado] toolchain and the [Basys3][basys] development board.
- **Hardware/Software Co-design**: Combining hardware description and software programming skills.

## The HaDes-V Core

HaDes-V is a **32-bit, in-order, classic five-stage RISC-V soft core** written in SystemVerilog. It is small enough to read end-to-end, yet complete enough to boot a bare-metal C program, take interrupts, and drive real peripherals on a Basys3 FPGA.

### Instruction Set

| Class | Support |
|---|---|
| Base ISA | **RV32I** — all 37 integer instructions (LUI/AUIPC, arithmetic/logic reg–reg & reg–imm, loads/stores for byte/half/word with signed & unsigned variants, conditional branches, JAL/JALR) |
| Control & Status | **Zicsr** — CSRRW / CSRRS / CSRRC and their immediate variants |
| Instruction fence | **Zifencei** — FENCE.I to resynchronise the fetch path after self-modifying writes |
| Privilege | **Machine mode only** (M-mode) with a full trap model: ECALL, EBREAK, MRET, and all synchronous exceptions |
| Interrupts | **External** and **timer** (`mie.MEIE`, `mie.MTIE`); gated by `mstatus.MIE`; save/restore via `MPIE` |

The full ISA string is **`rv32i_zicsr_zifencei`** (pinned: `rv32i2p1_zicsr2p0_zifencei2p0`, as ratified in the RISC-V Unprivileged ISA v20191213). The `Zicsr` and `Zifencei` suffixes are load-bearing rather than decorative: base `I` version 2.0 included the CSR instructions and `FENCE.I`, but version 2.1 split them out into separately-named extensions. Note that no `Z*` extension can be advertised in `MISA` — its `Extensions` field has exactly one bit per single letter (bit 8 = `I`, bit 12 = `M`, …), so multi-letter extension names exist only in the ISA string.

Implemented M-mode CSRs include `MSTATUS`, `MISA`, `MIE`, `MIP`, `MTVEC`, `MSCRATCH`, `MEPC`, `MCAUSE`, `MCYCLE`/`MCYCLEH`, `MINSTRET`/`MINSTRETH`, and (as an extension) **`MHPMEVENT10`** and **`MHPMCOUNTER10–13`** for branch-predictor control and performance monitoring — see [defines/csr.sv](defines/csr.sv) for the full map.

### Pipeline

Instructions flow through five stages, each a dedicated module in [rtl/](rtl/), stitched together in [cpu.sv](rtl/cpu.sv):

```
  ┌─────────┐   ┌─────────┐   ┌─────────┐   ┌─────────┐   ┌───────────┐
  │  FETCH  │──▶│ DECODE  │──▶│ EXECUTE │──▶│ MEMORY  │──▶│ WRITEBACK │
  └─────────┘   └─────────┘   └─────────┘   └─────────┘   └───────────┘
       ▲             ▲             ▲             ▲              │
       └─────────────┴─────────────┴─────────────┴──────────────┘
                    backwards control (READY / STALL / JUMP)
```

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
- **Exceptions.** Flow forwards through the pipeline as the instruction's status code and trap at Writeback — the faulting PC is saved to `MEPC`, the cause encoded into `MCAUSE`, and control jumps to `MTVEC`.
- **Interrupts.** External and timer lines are sampled at Writeback. They trap on the completion boundary of a `VALID` or `ERROR` instruction (never on a `BUBBLE`), honour `mstatus.MIE` / `mie.MEIE` / `mie.MTIE`, and save/restore the global enable via `MPIE`. MRET returning with a pending enabled interrupt traps in the same cycle.
- **Nested-trap MPIE preservation.** On a primary trap `MPIE ← MIE` captures the previous interrupt-enable state. If a *nested* trap fires while MIE is already 0 (CPU already in a handler), `MPIE` must **not** be overwritten — doing so would destroy the saved state from the outer trap. In the implementation: `mstatus_mpie` is only updated when `mie_eff = 1`; nested traps still update `MCAUSE`, `MEPC`, and clear `MIE`, but leave `MPIE` unchanged. Without this rule, a stale `FETCH_FAULT` arriving the cycle after a primary interrupt trap would clobber `MPIE` to 0, breaking the `MRET`-with-pending-interrupt path.
- **Pipeline flushes on trap.** The trap's `JUMP` propagates backwards exactly like a branch, draining younger instructions without architectural side effects.

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

next_pc = is_mispredicted_branch ? corrected_address
        : is_jump               ? jump_target
        :                         pc_plus_4;
```

When a branch is **correctly** predicted (e.g. the 2-bit counter correctly predicted *taken* for a loop-back branch), `is_mispredicted_branch = false`, `jump_detected = false`, and the pipeline flows without any flush. Fetch has already loaded the right next instruction.

When a branch is **mispredicted**, Execute flushes exactly as it did before, but now redirects to `corrected_address` — the address the CPU *should* have taken — rather than unconditionally to `jump_target`.

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

#### Implementation Notes

- **No BTB.** This is a pure bimodal predictor — no branch-target buffer. The target address is always computed by Decode from the immediate field. Prediction only decides whether to speculatively advance the PC; misses are corrected in Execute with the same mechanism as the original taken-branch flush.
- **Only `Bxxx` instructions** (opcode `7'b1100011`) are predicted. `JAL` and `JALR` are unconditional and always cause a flush via `is_jump`, unchanged from the original design.
- **Alignment guard.** `predicted_taken` is suppressed for branches whose target is not 4-byte aligned (`branch_offset[1:0] != 2'b00`). These fall through to the existing `FETCH_MISALIGNED` exception path.
- **Mode 0 is zero-overhead.** When `MHPMEVENT10 = 0`, `predicted_taken = 0` unconditionally. `is_mispredicted_branch` reduces to `is_branch && branch_taken && VALID`, which is the original `jump_detected` formula. The pipeline behaves identically to unmodified HaDes-V.
- **Simulator echo.** [lib/wishbone/wishbone_uart.sv](lib/wishbone/wishbone_uart.sv) includes an `always @(posedge clk)` block that calls `$write("%c", byte)` whenever a TX buffer write is detected, echoing UART output to Verilator's stdout. This is purely a simulation convenience; `$write` is ignored by synthesis tools.

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

### Linker Script & Memory Layout

[std/hades-v.ld](std/hades-v.ld) defines a single `RAM` region (`ORIGIN = 0x40000`, `LENGTH = 32K`) matching the Wishbone RAM window, and arranges the image as:

```
┌─────────────────────────────────┐ 0x40000  ← RESET_ADDRESS
│ .reset      — __reset entry    │
├─────────────────────────────────┤
│ .text       — program code     │
│ .rodata                        │
│ .data       — initial data     │
│ .sdata / .sbss                 │
│ .bss                           │
│ …stack grows down…             │
├─────────────────────────────────┤ __ram_end − 4 K
│ .boot       — bootloader       │
│ .reserved                      │
└─────────────────────────────────┘ 0x48000  = __ram_end
```

The linker exports `__ram_start`, `__ram_end`, `__boot_start`, `__boot_end`, `__boot_load`, and `__global_pointer$` — the last one is loaded into `gp` in the startup code to enable GCC's linker relaxation (±2 KB small-data accesses). `NOCROSSREFS_TO` directives prevent the bootloader from accidentally touching the application sections it's busy replacing.

### C Startup

[std/src/start.c](std/src/start.c) is the first C code executed after `__reset`: it sets up `gp` and `sp`, zeroes `.bss`, copies `.data` into RAM if needed, and calls `main()`. [std/src/boot.c](std/src/boot.c) and [std/src/boot_internal.c](std/src/boot_internal.c) implement a UART-based bootloader that can receive a new image over the serial line and overwrite the application region at runtime — `run_bootloader()` from [std/include/boot.h](std/include/boot.h) is what the Basys3 demo calls when you hold a button at reset.

### Peripheral & Helper Headers

[std/include/peripherals.h](std/include/peripherals.h) exposes every MMIO region as typed `volatile` pointer macros — for example, `*LEDS_ADDRESS = value;` drives the 16 LEDs, `*UART_BUFFER_ADDRESS` is the UART FIFO, `TIMER_MTIMECMP_ADDRESS` sets a timer compare. Bit indices for button positions and UART status flags are also provided.

[std/include/helperfunctions.h](std/include/helperfunctions.h) layers ergonomic helpers on top: 7-segment digit encoding (`number2segment`), VGA primitives (`setPixel`, `clearPixel`, a `vga_color_t` palette of 16 colours, `rowCol2pxIdx` for 640×480 addressing), and machine/external/timer/UART interrupt enable wrappers (`enableDisable_machineInterrupts`, etc.). [test/c/basys3_demo.c](test/c/basys3_demo.c) is the canonical example that exercises every peripheral using these helpers.

## Reference-Library ("Jigsaw Puzzle") Flow

The reason you can build HaDes-V stage-by-stage without ever having a broken pipeline is the [ref/](ref/) directory. Every pipeline module ships in two forms:

- **Your implementation** in [rtl/](rtl/) — plain SystemVerilog you edit.
- **A golden reference** in [ref/](ref/) — a pair of `ref_<stage>.sv` / `ref_<stage>_inner.sv` wrappers plus a precompiled `libref_<stage>_inner.so` produced by Verilator with `--protect-lib`. The `.so` is the actual implementation; the `.sv` wrapper is a DPI-C shim that makes it look like a normal SystemVerilog module to the simulator.

Testbenches in [test/sv/](test/sv/) instantiate **both** — student DUT and golden REF — in parallel, clock them with the same stimulus, and flag any cycle where their outputs diverge. Because each stage has the same port list as its reference, you can freely mix: use your fetch + reference decode + your execute + reference memory + reference writeback, and the processor still runs a real program. That is what makes the "solve the puzzle one piece at a time" workflow possible.

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
```

The simulator is [Verilator][verilator]; synthesis uses [Vivado][vivado] 2023.2 (default path `/opt/Xilinx/Vivado/2023.2/`). Wave dumps land in the repository root as `*.fst` files and can be inspected with [GTKWave][gtkwave].

### Test Hierarchy

The [test/](test/) tree has three progressively integrative tiers:

| Tier | Location | What it exercises | Invocation |
|---|---|---|---|
| **Assembly** | [test/asm/](test/asm/) | Small hand-written `.s` programs targeting a specific ISA feature — e.g. [trap.s](test/asm/trap.s) for the full exception/interrupt path, [ops.s](test/asm/ops.s) for every RV32I instruction, [forwarding.s](test/asm/forwarding.s) for the data-hazard network, [bpred.s](test/asm/bpred.s) for the branch predictor (modes 0/1/3, counter verification). | `make test/asm/trap` |
| **C** | [test/c/](test/c/) | Full C programs linked against [std/](std/). [bootloader.c](test/c/bootloader.c) is the UART loader; [basys3_demo.c](test/c/basys3_demo.c) wiggles every on-board peripheral. | `make test/c/basys3_demo` |
| **SystemVerilog** | [test/sv/](test/sv/) | Module-level benches that run DUT vs. REF side-by-side and compare every cycle. Examples: [test_writeback_compare.sv](test/sv/test_writeback_compare.sv), [test_execute_compare.sv](test/sv/test_execute_compare.sv), [test_decode_hazard.sv](test/sv/test_decode_hazard.sv). | `make test/sv/test_writeback_compare` |

Together these give coverage at the instruction level, the system level, and the per-module bit-level — catch a bug as early as possible in whichever tier first exposes it.

## Why HaDes-V?

- **Learn by Building**: Design a pipelined RISC-V processor from scratch.
- **Modular Design**: Implement, test, and integrate each module of the pipeline step by step—just like solving a jigsaw puzzle.
- **Immediate Validation**: Use golden references in [`ref/`](ref) to ensure your functionality matches expectations.
- **Hands-On Debugging**: Simulate and verify your work with tools like [Verilator][verilator] and [GTKWave][gtkwave].
- **Real Hardware Integration**: Bring your design to life on an FPGA using the [Basys3][basys]  board.

## Learning Outcomes  
By completing the lab, students will:  
- **Design** a modular, pipelined 32-bit RISC-V processor with multiple stages.  
- **Implement** CPU functionality using SystemVerilog.  
- **Program** software for the processor in RISC-V Assembly and C.  
- **Deploy** the processor design onto FPGA boards.  
- **Analyze** the processor using simulation and waveform tools.

## Tools and Dependencies

The following tools are required for the lab exercises (details in the [Instruction Guide][instrguide]):
- **[SystemVerilog][sv]**: HDL for processor and peripheral design.
- **[RISC-V Toolchain][rvgcc]**: Compiler for RV32I assembly and C programs.
- **[Vivado][vivado]**: FPGA synthesis and programming.
- **[Verilator][verilator]**: Open-source HDL simulator.
- **[GTKWave][gtkwave]**: Waveform viewer for debugging simulations.

## Repository Structure

- [`defines/`](defines): HDL constants and definitions.
- [`lib/`](lib): Peripheral modules (e.g., UART, timer).
- [`ref/`](ref): Precompiled reference libraries.
- [`rtl/`](rtl): The actual student implementation. Contains code stubs for further development.
- [`synth/`](synth): Synthesis scripts and FPGA configuration files.
- [`test/`](test): Test files in assembly (`asm`), C (`c`), and SystemVerilog (`sv`).
- [`.vscode/`](.vscode): Configuration files for Visual Studio Code.

Refer to the [Instruction Guide][instrguide] for a detailed project structure.

## Exercises

The laboratory includes several exercises to progressively build the HaDes-V processor:
- **Basic Implementation**: CPU module, instruction fetch, decode, and execution stages.
- **Advanced Features**: Memory stage, writeback stage, and control/status registers.
- **Extensions**: Final project to extend the processor with custom peripherals or functionality.

Each exercise allows you to implement and test individual modules while leveraging the **golden references** in [`ref/`](ref) for validation—ensuring seamless integration like solving a puzzle.

See the detailed exercise instructions in Chapter 4 of the [Instruction Guide][instrguide].

## Test Benches
A closed-source test bench system is available for teaching purposes. For more information, please refer to the [Contact](#contact) section.

## License

This OER and all of its creative material (text, logos, etc.) is licensed under the **CC BY 4.0 International License**, allowing you to share and adapt the resource, provided appropriate credit is given. See the full license details [here](https://creativecommons.org/licenses/by/4.0/).

>![CCBY](https://mirrors.creativecommons.org/presskit/buttons/88x31/svg/by.svg)\
>Tobias Scheipel, David Beikircher, Florian Riedl\
>TU Graz 2024

All the software files included in the repository are licensed under the **MIT License**. See the [LICENSE](./LICENSE) file for details.

Contributions to this OER are welcome and encouraged! The LaTeX sources for the [Instruction Guide][instrguide] can be requested as well. For more OERs, visit [https://www.scheipel.com/oer](https://www.scheipel.com/oer).

## Contact

For questions, licensing, test bench inquiries, or further information, please contact and/or consult:
- **Email**: [tobias.scheipel@tugraz.at](mailto:tobias.scheipel@tugraz.at)
- **Website**: [https://www.scheipel.com/oer](https://www.scheipel.com/oer)

## Publication @ RISC-V Summit Europe 2025
We published this OER at the [RISC-V Summit Europe 2025](https://riscv-europe.org/summit/2025/) as a [Poster](https://graz.elsevierpure.com/files/93678000/HaDes_V_Poster-CR_v1.pdf) and an extended [Abstract Paper](https://www.scheipel.com/wp-content/uploads/2025/05/HaDes_V_RISC_V_Summit_camera_ready-1.pdf). 

**The work also got featured on the official RISC-V International [Blog](https://riscv.org/blog/) [here](https://riscv.org/blog/2025/05/hades-v-learning-by-puzzling-a-modular-approach-to-risc-v-processor-design-education/).**


