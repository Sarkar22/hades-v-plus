[HaDes-V+](../README.md) · **Architecture** · [Extensions](EXTENSIONS.md) · [Verification](VERIFICATION.md) · [Building](BUILDING.md) · [FreeRTOS](FREERTOS.md)

# Architecture

This document describes the HaDes-V+ core and the microcontroller built around it: the instruction set, the five-stage pipeline and its hazard handling, the memory system, the Wishbone fabric, the peripherals and clocks, the software runtime, and the reference-library flow of the upstream project. The instruction-set extensions are described in [EXTENSIONS.md](EXTENSIONS.md), the verification in [VERIFICATION.md](VERIFICATION.md).

**Contents**

1. [The HaDes-V Core](#the-hades-v-core): [Instruction Set](#instruction-set), [Pipeline](#pipeline), [Hazards](#hazards-and-how-theyre-handled)
2. [System Architecture](#system-architecture): [Memory Subsystem](#memory-subsystem), [Memory Map](#system-level-memory-map), [Wishbone Fabric](#the-wishbone-fabric), [Peripherals](#peripherals), [Clocks & Reset](#clocks--reset)
3. [Software Runtime](#software-runtime): [FreeRTOS](#freertos), [Linker Script](#linker-script--memory-layout), [C Startup](#c-startup), [Headers](#peripheral--helper-headers)
4. [Reference-Library ("Jigsaw Puzzle") Flow](#reference-library-jigsaw-puzzle-flow)

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

Implemented M-mode CSRs include `MSTATUS`, `MIE`, `MIP`, `MTVEC` (direct mode only), `MSCRATCH`, `MEPC`, `MCAUSE`, `MCYCLE`/`MCYCLEH`, `MINSTRET`/`MINSTRETH`, and (as an extension) **`MHPMEVENT10`** and **`MHPMCOUNTER10–13`** for branch-predictor control and performance monitoring — see [defines/csr.sv](../defines/csr.sv) for the full map. `MISA`, `MTVAL` and the other machine-mode CSRs that the decoder accepts but that are not listed here read as zero.

### Pipeline

Instructions flow through five stages, each a dedicated module in [rtl/](../rtl/), stitched together in [cpu.sv](../rtl/cpu.sv): **Fetch → Decode → Execute → Memory → Writeback**.

Two signals travel with them, in opposite directions. The `forwards` path carries the instruction and its status downstream toward Writeback. The `backwards` path carries control — `READY`, `STALL` or `JUMP`. Any stage can originate it: Memory when the bus is busy, Execute during a multi-cycle divide, Decode on a data hazard, Writeback on a trap or `FENCE.I`. It propagates upstream one stage at a time, holding or redirecting everything ahead of it.

| Stage | File | Responsibility |
|---|---|---|
| **Fetch** | [fetch_stage.sv](../rtl/fetch_stage.sv) | Drives the instruction-side Wishbone port, keeps the program counter, and reports `FETCH_MISALIGNED` / `FETCH_FAULT` to the downstream pipeline. Also instantiates [branch_predictor.sv](../rtl/branch_predictor.sv) and speculatively updates the PC to the branch target when `predicted_taken = 1`. |
| **Decode** | [decode_stage.sv](../rtl/decode_stage.sv) + [instruction_decoder.sv](../rtl/instruction_decoder.sv) | Expands the raw 32-bit word into a typed `instruction::t`, reads rs1/rs2 from the [register_file](../rtl/register_file.sv), and runs the forwarding mux. Raises `ILLEGAL_INSTRUCTION` for unknown encodings. Threads the `bp_data_t` prediction struct from Fetch to Execute as a pass-through pipeline register. |
| **Execute** | [execute_stage.sv](../rtl/execute_stage.sv) | ALU, branch comparison, and jump-target computation. Branches and JAL/JALR are **resolved here**. With branch prediction enabled, only *mis*predicted branches flush the pipeline; correctly-predicted branches have zero penalty. Drives `bp_feedback_out` back to Fetch for 2-bit counter updates. |
| **Memory** | [memory_stage.sv](../rtl/memory_stage.sv) | Data-side Wishbone loads and stores with alignment checking. Stalls the pipeline until the bus acks. Emits `LOAD/STORE_MISALIGNED` and `LOAD/STORE_FAULT`. |
| **Writeback** | [writeback_stage.sv](../rtl/writeback_stage.sv) | Commits `rd` to the register file, services all CSR reads/writes, and is the single point where **exceptions and interrupts trap** into `MTVEC`. Also implements MRET and FENCE.I. Holds the branch-predictor control register (`MHPMEVENT10`) and the four prediction-outcome counters (`MHPMCOUNTER10–13`). |

Pipeline direction is encoded in two packed packages in [defines/pipeline_status.sv](../defines/pipeline_status.sv):

- **forwards** — `VALID`, `BUBBLE`, or one of the exception codes, flowing Fetch → Writeback.
- **backwards** — `READY`, `STALL`, or `JUMP` (with an accompanying target address), flowing Writeback → Fetch.

### Hazards and How They're Handled

Being in-order and single-issue keeps the control story small, but every classical hazard still has to be covered:

- **Data hazards (RAW).** A three-level **forwarding network** bypasses results from Execute, Memory, and Writeback back into Decode, with *most-recent-wins* priority (E > M > WB). The ordinary arithmetic case is resolved with zero bubbles.
- **Load-use hazard.** A load's result isn't available until after Memory. If Decode sees Execute forwarding with `data_valid = 0` for a register it needs, it asserts `STALL` backwards for one cycle and a `BUBBLE` forwards — exactly one stall slot, no more.
- **CSR-use hazard.** A CSR read resolves in Writeback, so its forwarding is tagged `data_valid = 0` in earlier stages; the same stall mechanism as load-use covers it.
- **Control hazards (branches / JAL / JALR).** Resolved in Execute. On a taken jump, the younger instructions already in Fetch/Decode are squashed by driving `JUMP` with the target address backwards; Fetch reloads from the target next cycle. With the **branch predictor extension** enabled (see [Branch Predictor Extension](EXTENSIONS.md#branch-predictor-extension)), correctly-predicted branches incur zero flush penalty — Execute only generates a `JUMP` on *mis*predictions.
- **Structural hazards on the bus.** The fetch and data paths each have their own Wishbone port, so loads/stores never collide with instruction fetches. When the data bus is slow, Memory holds the rest of the pipeline with `STALL`.
- **Multi-cycle execute (M extension).** Execute is single-cycle for every RV32I operation, but `mul` needs two cycles and `div`/`rem` need 34. Execute therefore has its own `STALL` generator, the third in the pipeline after Decode's and Memory's. Priority is `JUMP` from behind > `STALL` from Memory > Execute's own stall: a flush always outranks an unfinished divide, which is abandoned and re-run after the trap returns. See [Multiply and Divide](EXTENSIONS.md#m--multiply-and-divide).
- **Exceptions.** Flow forwards through the pipeline as the instruction's status code and trap at Writeback — the faulting PC is saved to `MEPC`, the cause encoded into `MCAUSE`, and control jumps to `MTVEC`.
- **Interrupts.** External and timer lines are sampled at Writeback. They trap on the completion boundary of a `VALID` or `ERROR` instruction (never on a `BUBBLE`), honour `mstatus.MIE` / `mie.MEIE` / `mie.MTIE`, and save/restore the global enable via `MPIE`. MRET returning with a pending enabled interrupt traps in the same cycle.
- **Exception beats a same-cycle interrupt.** If the instruction in Writeback raises an exception (e.g. `ECALL`) in the very cycle an enabled interrupt becomes pending, the exception is taken (`MEPC` = its PC). The interrupt stays pending and is taken at the handler's `MRET`. This matches the frozen golden model; the earlier behaviour recorded the interrupt with `MEPC` = PC+4, so the `ECALL` vanished — under FreeRTOS a lost `portYIELD` corrupted the scheduler lists. Regression: [trapirq.s](../test/asm/trapirq.s).
- **`MPIE ← MIE` on every trap entry.** As the privileged spec requires, trap entry copies `MIE` into `MPIE` and clears `MIE`, also when `MIE` was already 0, so `MRET` from that trap comes back with interrupts still disabled. The golden model does the same. (An earlier "nested-trap" rule left `MPIE` untouched when `MIE` was 0. That made a FreeRTOS yield taken inside a critical section resume with interrupts *enabled*, and it diverged from the golden model in exactly the stale-`FETCH_FAULT` sequence it was meant to handle.) Regression: [trapmpie.s](../test/asm/trapmpie.s).
- **The instruction in flight at a sequential interrupt.** An interrupt decided at instruction *I* redirects one cycle later, when the next instruction *J* is already in Writeback and has passed Memory. *J* therefore normally **retires** before the trap (register and CSR write, `minstret`, `MEPC` = its next PC). The exception is when *J* would touch state the trap has already committed: a CSR op on `MSTATUS`/`MCAUSE`/`MIE`/`MTVEC`, or an `MRET`. That *J* is **replayed** instead, with no effects and `MEPC` = its own PC. Earlier, *J*'s CSR write was dropped while `MEPC` still skipped it, which lost FreeRTOS's `portDISABLE_INTERRUPTS` (`csrc mstatus,8`). A retired *J* was also missing from `minstret`, which the golden model does count. Regression: [csrirq.s](../test/asm/csrirq.s).
- **An interrupt never flushes a bus access in flight.** If *J* is a load or store to a peripheral that answers a cycle or more later (UART, timer, LEDs, VGA, the test stall register), its access has already started when the interrupt is decided at *I*, and a Wishbone access cannot be aborted. Writeback therefore **holds** the interrupt's `JUMP` while Memory reports the access in flight, and *J* retires when it completes (`MEPC` = its next PC), as the golden model does. Earlier the `JUMP` flushed *J* with `MEPC` = *J*'s PC, so the access was performed a second time after `MRET` (a UART character printed twice); with a response of three or more cycles (VGA read, test stall register) Memory's `STALL` swallowed the one-cycle `JUMP` altogether, so the trap state was committed (`MIE` = 0, `MCAUSE`, `MEPC`) but the handler never ran. Regression: [memirq.s](../test/asm/memirq.s).
- **Interrupt after a correctly predicted taken branch.** Writeback takes an interrupt's `MEPC` from the `next_program_counter` that Execute attaches to every instruction. That value is the architectural next PC, so for a taken branch it is the target even when the predictor already fetched the target and Execute did not flush. Earlier it was `pc + 4` for a correctly predicted taken branch, so the handler's `MRET` resumed on the not-taken path (predictor modes 1–3 only). Regression: [bpirq.s](../test/asm/bpirq.s), [bpirq2.s](../test/asm/bpirq2.s), [bpirq3.s](../test/asm/bpirq3.s), [test_execute_bpred_nextpc.sv](../test/sv/test_execute_bpred_nextpc.sv); see [Branch predictor](EXTENSIONS.md#branch-predictor-extension).
- **Interrupt right after a `csrw mtvec`.** A sequential interrupt decided at an instruction *I* that writes `MTVEC` is taken after *I* has retired (`MEPC` points past it), so it must use the *new* vector: every trap sets `pc` to `mtvec.BASE`, and a CSR write is seen by the very next instruction (Zicsr, "CSR Access Ordering"). The interrupt's `JUMP` used to take a copy of `MTVEC` made in the decision cycle, before *I*'s write, and entered the *old* handler. It now uses the live register. The frozen golden model has the same bug (one delay step earlier), so here the spec and the independent ISA model in [test/trapsweep/](../test/trapsweep/) decide, not the golden model. FreeRTOS was never affected, because it writes `MTVEC` once, before enabling interrupts. Regression: [mtvecirq.s](../test/asm/mtvecirq.s).
- **Pipeline flushes on trap.** The trap's `JUMP` propagates backwards exactly like a branch, draining younger instructions without architectural side effects.

## System Architecture

### Memory Subsystem

The core has **two completely independent memory ports** — an instruction-side port for Fetch and a data-side port for Memory — each a separate Wishbone master. This is a classic Harvard-style split at the boundary of the core:

- On-chip RAM is implemented by [lib/wishbone/wishbone_ram.sv](../lib/wishbone/wishbone_ram.sv) as a **true dual-port block RAM**: `port_a` is bound to the fetch bus and `port_b` to the data bus, so an instruction fetch and a load/store land on the same cycle without arbitration. An `init.mem` hex image is loaded into the array at elaboration via `$readmemh`, which is how bootloader and test programs are pre-seeded.
- Because the fetch and data buses never share a master, there is **no structural contention** between the pipeline's fetch stream and its load/store traffic — the only stall the bus can introduce on HaDes-V is a slow-ack from a peripheral, which propagates through Memory's `STALL`.
- Writes are byte-enabled: the 4-bit `sel` strobe on Wishbone is driven by Memory to match SB / SH / SW widths, and the RAM honours each lane individually.
- Reset vector is derived from the RAM base in [defines/constants.sv](../defines/constants.sv): `RESET_ADDRESS = MEMORY_START << 2 = 0x0004_0000` (byte address). Fetch powers up on that PC.

### System-Level Memory Map

All masters share a single 32-bit word-addressed address space decoded by [lib/wishbone/wishbone_interconnect.sv](../lib/wishbone/wishbone_interconnect.sv). The numbers below come straight from [defines/constants.sv](../defines/constants.sv):

| Region | Base (word) | Base (byte) | Size | Backed by |
|---|---|---|---|---|
| **RAM** (code + data) | `0x0001_0000` | `0x0004_0000` | 8 KiW ≈ 32 KiB | [wishbone_ram.sv](../lib/wishbone/wishbone_ram.sv) |
| **LEDs** | `0x0008_0000` | `0x0020_0000` | 1 word | [wishbone_leds.sv](../lib/wishbone/wishbone_leds.sv) |
| **Buttons** | `0x0008_1000` | `0x0020_4000` | 1 word | [wishbone_buttons.sv](../lib/wishbone/wishbone_buttons.sv) |
| **Switches** | `0x0008_2000` | `0x0020_8000` | 1 word | [wishbone_switches.sv](../lib/wishbone/wishbone_switches.sv) |
| **7-seg display** | `0x0008_3000` | `0x0020_C000` | 1 word | [wishbone_segments.sv](../lib/wishbone/wishbone_segments.sv) |
| **UART** | `0x0008_4000` | `0x0021_0000` | 1 word | [wishbone_uart.sv](../lib/wishbone/wishbone_uart.sv) |
| **Timer** | `0x0008_5000` | `0x0021_4000` | 5 words | [wishbone_timer.sv](../lib/wishbone/wishbone_timer.sv) |
| **VGA framebuffer** | `0x0009_0000` | `0x0024_0000` | 38 400 words (640×480 @ 4bpp) | [wishbone_vga.sv](../lib/wishbone/wishbone_vga.sv) |
| **Test device** | `0x0012_0000` | `0x0048_0000` | 5 words | [wishbone_test.sv](../lib/wishbone/wishbone_test.sv) |

Any access that misses every window raises a bus `err` — which surfaces in the CPU as a `LOAD_FAULT` or `STORE_FAULT` trap.

### The Wishbone Fabric

HaDes-V speaks the **Wishbone B4 classic (non-pipelined) handshake** throughout — small, synchronous, and easy to reason about.

**Bus signals** — defined as a SystemVerilog interface in [lib/wishbone/wishbone_interface.sv](../lib/wishbone/wishbone_interface.sv). Master drives `cyc`, `stb`, `we`, `adr`, `sel`, `dat_mosi`; slave drives `ack`, `err`, `dat_miso`. `cyc` marks an active bus cycle, `stb` marks the specific beat, `ack` closes a successful transfer, and `err` aborts one. The `.master` / `.slave` modports make the direction explicit at every instantiation.

**Interconnect.** The shared data bus is fanned out to 9 slaves by [wishbone_interconnect.sv](../lib/wishbone/wishbone_interconnect.sv), which:

1. Decodes the master's address against each slave's `{BASE, SIZE}` window.
2. Routes `stb` only to the selected slave, OR-reduces `ack`/`err`, and muxes `dat_miso` back.
3. Flags `invalid_address` as a bus error if no window matches.
4. Runs a **255-cycle timeout counter** that asserts `err` if a slave never acknowledges — preventing a stuck peripheral from hanging the pipeline forever.

The fetch bus is simpler: it talks directly to RAM's port A, no interconnect needed.

### Peripherals

Every peripheral is a Wishbone slave living in [lib/wishbone/](../lib/wishbone/). All of them sit on the CPU's data bus; three of them generate interrupts that the core sees as either *external* or *timer*.

| Peripheral | File | Registers / Behaviour | Interrupt |
|---|---|---|---|
| **RAM** | [wishbone_ram.sv](../lib/wishbone/wishbone_ram.sv) | Dual-port byte-enabled BRAM, `init.mem`-preloaded. | — |
| **LEDs** | [wishbone_leds.sv](../lib/wishbone/wishbone_leds.sv) | Single register driving the 16 Basys3 LEDs. | — |
| **Buttons** | [wishbone_buttons.sv](../lib/wishbone/wishbone_buttons.sv) | Read-only register with the 5 push-buttons, synchronised but not debounced (center button is reset). | — |
| **Switches** | [wishbone_switches.sv](../lib/wishbone/wishbone_switches.sv) | Read-only register with the 16 slide switches. | — |
| **7-Segment** | [wishbone_segments.sv](../lib/wishbone/wishbone_segments.sv) | Write a 32-bit word → rendered as 4 hex digits with anode multiplexing. | — |
| **UART** | [wishbone_uart.sv](../lib/wishbone/wishbone_uart.sv) + [uart_tx.sv](../lib/peripherals/uart_tx.sv) / [uart_rx.sv](../lib/peripherals/uart_rx.sv) | 115200 8-N-1 by default; parametrised by `BAUD_RATE` and `CLK_FREQUENCY_MHZ`. Single-byte TX and RX buffers, with their status and interrupt-enable bits, in one register word. | **External** (RX buffer full and/or TX buffer empty, each enabled separately) |
| **Timer** | [wishbone_timer.sv](../lib/wishbone/wishbone_timer.sv) | RISC-V machine timer: a status word (nanoseconds per clock cycle), the 64-bit `mtime`, which counts `clk` cycles, and the 64-bit `mtimecmp`. | **Timer** (while `mtime` ≥ `mtimecmp`) |
| **VGA** | [wishbone_vga.sv](../lib/wishbone/wishbone_vga.sv) + [vga_memory.sv](../lib/wishbone/vga_memory.sv) | 640×480 @ 60 Hz framebuffer, 4-bit packed colour (8 pixels per word), clocked off a dedicated `clk_vga`. | — |
| **Test device** | [wishbone_test.sv](../lib/wishbone/wishbone_test.sv) | Simulation-only: pass/fail/halt reporting, a counter that increments on every read, a deliberately-stalling register, and a down-counter interrupt for testbenches. | **External** |

In [mcu.sv](../rtl/mcu.sv), the `external_interrupt` line into the CPU is the logical OR of the UART and test-device interrupts, while the timer peripheral is wired straight into `timer_interrupt_in`. Every async input (buttons, switches, UART RX) passes through [lib/synchronizer.sv](../lib/synchronizer.sv) before entering the clock domain, keeping the design metastability-safe at the FPGA pads.

### Clocks & Reset

HaDes-V is a three-clock design, all generated on the FPGA from a single crystal — see [defines/clk_params.sv](../defines/clk_params.sv) and [mcu.sv](../rtl/mcu.sv):

| Clock | Used by | Note |
|---|---|---|
| `clk` | CPU core, most peripherals | Main system clock. |
| `clk_mem` | [wishbone_ram.sv](../lib/wishbone/wishbone_ram.sv) | **Inverted** copy of `clk`. Lets the RAM read and deliver data within the same `clk` cycle, giving single-cycle loads without pipeline stalls. (Explicitly flagged as "do not replicate" elsewhere in the design.) |
| `clk_vga` | [wishbone_vga.sv](../lib/wishbone/wishbone_vga.sv) | 25 MHz VGA pixel clock, asynchronous to `clk`. |

Reset is driven from the Basys3 center button, synchronised into `clk`, and distributed to every module as a synchronous `rst`. A power-on `initial rst = 1` in [mcu.sv](../rtl/mcu.sv) guarantees a clean reset after FPGA configuration.

## Software Runtime

A bare-metal C program targets HaDes-V by linking against the runtime in [std/](../std/) with the RISC-V GCC toolchain at `/opt/riscv32i/bin/riscv32-unknown-elf-gcc`. The build is driven by the top-level [Makefile](../Makefile).

### FreeRTOS

HaDes-V+ runs the unmodified official RISC-V port of FreeRTOS (V11.1.0+) in machine mode, using the memory-mapped machine timer (`mtime` at `0x00214004`, `mtimecmp` at `0x0021400C`) as the tick source. No instruction-set extension is required: the port needs only RV32I, Zicsr, `mstatus.MIE`/`MPIE`, `mie.MTIE`/`MEIE`, direct-mode `mtvec`, `mepc`, `mcause` and `MRET`. Programs can be built for `rv32i`, `rv32im` or `rv32im_zba`.

How FreeRTOS is used to test the core, and the defects it found, is described in [VERIFICATION.md](VERIFICATION.md#freertos-differential-campaigns).

**Running it.** The FreeRTOS sources are vendored, unmodified, in [`third_party/freertos/`](../third_party/freertos/README.md) at the tested commits, so no download step is needed. The guide, [docs/FREERTOS.md](FREERTOS.md), covers setup (including building outside a disk that cannot execute programs), reading the output, every setting, and writing your own program.

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

[std/hades-v.ld](../std/hades-v.ld) defines a single `RAM` region (`ORIGIN = 0x40000`, `LENGTH = 32K`) matching the Wishbone RAM window, and arranges the image as:

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

[std/src/start.c](../std/src/start.c) is the first C code executed after `__reset`: it sets up `gp` and `sp`, zeroes `.bss`, copies `.data` into RAM if needed, and calls `main()`. [std/src/boot.c](../std/src/boot.c) and [std/src/boot_internal.c](../std/src/boot_internal.c) implement a UART-based bootloader that can receive a new image over the serial line and overwrite the application region at runtime — `run_bootloader()` from [std/include/boot.h](../std/include/boot.h) is what the Basys3 demo calls when you hold a button at reset.

### Peripheral & Helper Headers

[std/include/peripherals.h](../std/include/peripherals.h) exposes every MMIO region as typed `volatile` pointer macros — for example, `*LEDS_ADDRESS = value;` drives the 16 LEDs, `*UART_BUFFER_ADDRESS` is the UART's data byte, `TIMER_MTIMECMP_ADDRESS` sets a timer compare. Bit indices for button positions and UART status flags are also provided.

[std/include/helperfunctions.h](../std/include/helperfunctions.h) layers ergonomic helpers on top: 7-segment digit encoding (`number2segment`), VGA primitives (`setPixel`, `clearPixel`, a `vga_color_t` palette of 16 colours, `rowCol2pxIdx` for 640×480 addressing), and machine/external/timer/UART interrupt enable wrappers (`enableDisable_machineInterrupts`, etc.). [test/c/basys3_demo.c](../test/c/basys3_demo.c) is the canonical example that exercises every peripheral using these helpers.

## Reference-Library ("Jigsaw Puzzle") Flow

HaDes-V can be built stage-by-stage without ever holding a broken pipeline, and the reason is the [ref/](../ref/) directory. Every pipeline module ships in two forms:

- **The implementation** in [rtl/](../rtl/) — plain, editable SystemVerilog.
- **A golden reference** in [ref/](../ref/) — a pair of `ref_<stage>.sv` / `ref_<stage>_inner.sv` wrappers plus a precompiled `libref_<stage>_inner.so` produced by Verilator with `--protect-lib`. The `.so` is the actual implementation; the `.sv` wrapper is a DPI-C shim that makes it look like a normal SystemVerilog module to the simulator.

Testbenches in [test/sv/](../test/sv/) instantiate **both** — the DUT and the golden REF — in parallel, clock them with the same stimulus, and flag any cycle where their outputs diverge. Because each stage has the same port list as its reference, you can freely mix: use your fetch + reference decode + your execute + reference memory + reference writeback, and the processor still runs a real program. That is what makes the "solve the puzzle one piece at a time" workflow possible.
