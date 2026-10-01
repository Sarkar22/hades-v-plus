[HaDes-V+](../README.md) · [Architecture](ARCHITECTURE.md) · **Extensions** · [Verification](VERIFICATION.md) · [Building](BUILDING.md) · [FreeRTOS](FREERTOS.md)

# Extensions

Everything in this document is work added after the upstream lab; the baseline core implements RV32I with `Zicsr`, and its `FENCE.I` was present but untested (see [Zifencei](#zifencei--instruction-fetch-synchronisation)).

With them the core implements `rv32im_zba_zicsr_zifencei_zicntr`, summarised under [Instruction Set](ARCHITECTURE.md#instruction-set). Each section below describes one extension: its design, how it is verified, and implementation notes.

**Contents**

1. [M — Multiply and Divide](#m--multiply-and-divide)
2. [Zba — Scaled-Index Address Generation](#zba--scaled-index-address-generation)
3. [Zicntr — User-Mode Counters](#zicntr--user-mode-counters)
4. [Zifencei — Instruction-Fetch Synchronisation](#zifencei--instruction-fetch-synchronisation)
5. [Branch Predictor Extension](#branch-predictor-extension)

## M — Multiply and Divide

Eight instructions, all plain R-type on the existing `OP` opcode (`0110011`) with `funct7 = 0000001`, so `funct3` alone selects among them and no new instruction format is needed.

The unit's results are formally proven correct for all operand pairs; see [Formal Verification of the M Unit](VERIFICATION.md#formal-verification-of-the-m-unit).

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

### Execute learns to stall

This is the first extension that makes Execute multi-cycle. Until now Execute was purely combinational and only *relayed* Memory's `STALL`/`JUMP`; the divider gives it a reason of its own.

| Operation | Cycles in Execute | Measured |
|---|---|---|
| any RV32I ALU op | 1 | 1.00 |
| `mul` / `mulh` / `mulhsu` / `mulhu` | 2 | 2.00 |
| `div` / `divu` / `rem` / `remu` | 34 | 34.00 |
| `div` / `rem` by zero, or `-2³¹ / -1` | 1 | 1.00 |

*(Measured in the assembled core over 800 back-to-back operations, loop overhead subtracted.)*

The arbitration between the three reasons the pipeline can be redirected is the delicate part, and the order is fixed in [rtl/execute_stage.sv](../rtl/execute_stage.sv) Part 5:

1. **`JUMP` from Memory/Writeback wins over everything.** A trap, interrupt, `MRET` or `FENCE.I` is squashing the instruction that owns the in-flight divide, so the divide is **abandoned** and the M unit resets. Holding `STALL` through a flush instead is the classic hang: Decode and Fetch would never see the redirect. The abandoned divide costs nothing — the flushed instruction is re-fetched from `mepc` and re-run.
2. **`STALL` from Memory wins over Execute's own stall,** because a Wishbone transaction cannot be aborted. The divider keeps iterating underneath it: Decode holds its output registers whenever anything downstream stalls, so the operands are bit-stable and the progress is free. A divide that finishes mid-stall simply parks until the instruction can leave.
3. **Execute's own stall.** Decode already honoured `STALL` from Execute (holding its registers and relaying to Fetch, which freezes the PC), so no upstream change was needed — only the generator was missing.

While stalling, Execute holds every data register and forwards `BUBBLE` to Memory — the same pattern `memory_stage` already uses for its bus stall — so the instruction Memory consumed on the previous edge is not re-executed.

### Verification

The frozen reference models predate `M` and can only report every M encoding as illegal, so correctness rests on three independent oracles.

| Test | What it covers |
|---|---|
| [test/sv/test_m_execute.sv](../test/sv/test_m_execute.sv) | 6,268 checks against a golden model written from SystemVerilog's own `*`, `/` and `%`. Corner×corner and random operand sweeps for all eight ops, plus the whole stall protocol: `JUMP` at all 36 points of a divide, `JUMP` on the exact cycle it finishes, Memory `STALL` during and outlasting a divide, back-to-back M ops, `BUBBLE` and exception-status M ops (which must not stall), and reset mid-divide. Every wait loop is bounded and reports `HANG`. |
| [test/asm/mul.s](../test/asm/mul.s) | 19 operand rows × 4 forms plus aliasing, `x0` destination and forwarding cases. `mulhsu` is run in **both operand orders** for every mixed-sign case — it is the only one of the four that is not commutative, and the expected values differ. |
| [test/asm/div.s](../test/asm/div.s) | All four quadrants of truncating division, divide-by-zero for all four instructions over six dividends, the `-2³¹ / -1` overflow, dependent divide chains, quotients used as load/store addresses, divides in front of taken and not-taken branches, and an external interrupt swept across the 34-cycle window — 20 of the sweep's flushes land on an unfinished divide. |
| [test/c/m_extension.c](../test/c/m_extension.c) | 200 differential checks against **libgcc**: each pair is computed once by a hardware M instruction and once by `__mulsi3`/`__muldi3`/`__divsi3`/`__modsi3`/`__udivsi3`/`__umodsi3`, which are independent RV32I software running on the same core. The two inputs that are undefined behaviour in C are checked against the mandated constants instead. |
| [test/sv/test_zba_encoding_sweep.sv](../test/sv/test_zba_encoding_sweep.sv) | The 290,288-word decoder sweep now also requires the DUT to match the reference everywhere except the Zba **and** M words, so a decode arm that is too broad still shows up as a leak. |

```bash
make test/sv/test_m_execute
make test/asm/mul
make test/asm/div
make test/c/m_extension
```

### Implementation Notes

- **FPGA timing is marginal.** The current RTL meets timing on the `xc7a35tcpg236-1` at 20 ns (50 MHz): post-route **WNS +0.016 ns**, 0 failing endpoints of 11070 (Vivado 2024.2; a repeated run of the same flow gives the same result). Its worst path starts at the block RAM, which delivers the fetched instruction on the falling clock edge, and runs through the branch predictor and the adder of the speculative PC to the Fetch stage's PC register, so it has half a clock period, 10 ns: 14 logic levels, 7 of them carry-chain stages, with about 53 % of the delay in logic. The history below explains why the margin is this thin. With the same flow, the commit that added M (c00c4db) reported post-route **WNS −0.120 ns** with 2 failing endpoints of 11214, while its parent reported **+0.026 ns** with none. A bitstream is still produced — `write_bitstream` does not check timing — so a successful `make synthesis` is *not* evidence of closure; read `build/synth/reports/timing_pnr.rpt`. Two caveats matter before blaming the multiplier. First, **no M cell appeared in the 40 worst paths**: the multiply closed with +6.15 ns and the divider with +10.19 ns. The failing path was a pre-existing 21-level, ~85 %-route path from the Memory stage's instruction register, through the waived `LUTLP-1` combinational-loop tangle, to the `mcause` register's clock enable — M's ~9 % area growth degraded its routing rather than lengthening its logic. Second, **small RTL changes move the worst path and change its slack**: the recorded results range from −0.120 ns to +0.242 ns, and the worst path has moved since, so a single result cannot cleanly attribute the 0.15 ns that M cost. The honest summary is that the design has been running at roughly zero margin since before M — the +0.221 ns recorded with the branch-predictor bitstream (commit 15b0b85) predates the `Zicntr` and `Zba` commits — and the real fix is to shorten these long paths rather than to pipeline the multiplier further.
- **The M results bypass `alu_sel` entirely.** `alu_sel` is a 4-bit local with only `1110`/`1111` free, and it is internal to `execute_stage` (not a struct field or port), so widening it would have been safe with respect to the frozen models. It was not widened anyway: half the M results come out of a sequential FSM and cannot be arms of the `always_comb` case that computes `alu_result`, and this design has essentially no timing margin to spend restructuring a block already near the critical path (see the FPGA timing note above). `m_result` is a second result bus that meets the ALU at the `rd_data` mux — one extra 2:1 level instead of six extra arms inside the ALU mux.
- **The multiply is registered, not combinational.** A 33×33 signed product is an array of DSP48E1 tiles plus an adder tree; run with no internal pipeline register it is comfortably the deepest combinational block in the core, and it would land on a path that runs from Decode's output registers through the multiplier, the `rd_data` mux and the forwarding network back into Decode's output registers — one 20 ns period, in a design with almost no margin to give. Registering the product puts a flop directly on the multiplier output. The price is one stall cycle, and since the divider needs the stall generator anyway it costs no extra machinery. Measured on the routed design the multiply path closes with **+6.15 ns** of slack, so the decision is vindicated — though Vivado did *not* absorb the flop into the DSP48E1's `P` register as intended, because the `MUL`-vs-`MULH` output mux sits between the DSP cascade and the register. Registering the full 64-bit product and muxing after the flops would allow that, at the cost of 32 extra FFs; it is not needed at this margin.
- **Restoring division on magnitudes.** Restoring and non-restoring need the same 32 iterations, but restoring needs no final correction step: the inner loop is one 33-bit subtract whose borrow *is* the quotient bit. Signs are stripped on the way in and reapplied on the way out, which is exactly the truncate-toward-zero rounding RISC-V specifies — and it makes the remainder follow the dividend for free. `abs(0x80000000)` is `0x80000000`, which read as unsigned is the correct magnitude 2³¹, so the most-negative value needs no special case in the datapath.
- **New ops were again appended *after* `ILLEGAL`** in [defines/op.sv](../defines/op.sv), for the reason the `Zba` notes give. Codes 0–52 are bit-identical and M claims 53–60: **61 of 64 codes used**, so `op::t` is still 6 bits and `instruction::t` still 65 bits. The encoding sweep asserts both widths and the exact enum positions on every run.
- **Assembled via a directive, not a global flag.** [test/asm/mul.s](../test/asm/mul.s) and [test/asm/div.s](../test/asm/div.s) carry `.option arch, +m`, and [test/c/m_extension.c](../test/c/m_extension.c) wraps its inline asm in `.option push` / `.option arch, +m` / `.option pop`. The Makefile still specifies no `-march` anywhere, so every other test still assembles as strict RV32I.
- **Interrupt latency grows behind a divide.** Writeback only takes an interrupt on the completion boundary of a non-`BUBBLE` instruction, and Execute feeds `BUBBLE` to Memory for all 33 stall cycles. Once the pipeline drains, an interrupt raised mid-divide is therefore deferred until the divide retires — up to ~34 cycles of extra latency. This is legal (interrupt latency is implementation-defined) and it is not a hang, but it is real and worth knowing before using `div` in an interrupt-critical loop.

## Zba — Scaled-Index Address Generation

`Zba` adds three single-cycle instructions that fuse a small left shift with an add: `rd = (rs1 << N) + rs2` for N = 1, 2, 3. That is precisely the shape of an array subscript — `&a[i]` is `base + i*sizeof(elem)` — so one instruction replaces the `slli`/`add` pair RV32I needs.

| Instruction | funct7 | funct3 | Operation |
|---|---|---|---|
| `sh1add` | `0010000` | `010` | `rd = (rs1 << 1) + rs2` — 2-byte elements |
| `sh2add` | `0010000` | `100` | `rd = (rs1 << 2) + rs2` — 4-byte elements (`int`, pointers) |
| `sh3add` | `0010000` | `110` | `rd = (rs1 << 3) + rs2` — 8-byte elements (`long long`, `double`) |

All three are plain R-type on the existing `OP` opcode (`0110011`), so the decoder needs no new immediate format and the pipeline needs no new plumbing — they inherit forwarding, hazard detection and writeback like any other ALU operation. The shift is **logical** over the full 32 bits (bits pushed past bit 31 are discarded, never sign-extended) and the add wraps modulo 2³², with no trap and no flags.

**The compiler emits them for you.** Building with `-march=rv32i_zba` makes GCC 12 generate `sh2add`/`sh3add` automatically for ordinary indexing code — no intrinsics or inline assembly required.

### Verification

The frozen reference models predate `Zba` and can only report it as illegal, so correctness is established by **differential testing against the toolchain** instead: the same C program is compiled twice, once as plain RV32I (`slli`+`add`) and once with `-march=rv32i_zba`, and both binaries must produce byte-identical output on the core. The two programs are semantically identical, so any divergence is a hardware fault.

| Test | What it covers |
|---|---|
| [test/asm/zba.s](../test/asm/zba.s) | 23 blocks / 62 assertions: zero and `x0` operands, `rd`/`rs1`/`rs2` aliasing, negative `rs1` with the sign bit shifted out, 32-bit overflow wrap, and forwarding from all three stages including into load/store addresses |
| [test/asm/zbaadv.s](../test/asm/zbaadv.s) | 49 adversarial tests / 103 assertions written independently, including operand-order traps and pipeline-position interactions |
| [test/sv/test_zba_encoding_sweep.sv](../test/sv/test_zba_encoding_sweep.sv) | 290,288-word DUT-vs-reference decoder sweep, plus enum and struct width assertions |

```bash
make test/asm/zba
make test/asm/zbaadv
make test/sv/test_zba_encoding_sweep
```

Measured during development (commit 1f501f5) with a benchmark that is not included in the repository, on an address-generation-heavy workload: **20.3 % fewer cycles** (1.26×) and 6–8 % smaller code, verified across 16,704 in-program operand comparisons with zero discrepancies. A differential check of the same kind is in the repository: built with `MARCH=rv32im_zba`, the `mzba` FreeRTOS program compares every result computed with the M and Zba instructions with the same computation built for plain RV32I (`make freertos APP=mzba MARCH=rv32im_zba`). The performance figure has no such command.

### Implementation Notes

- **Assembled via a directive, not a global flag.** [test/asm/zba.s](../test/asm/zba.s) carries `.option arch, +zba` rather than adding `-march=rv32i_zba` to the Makefile. This keeps the requirement next to the file that needs it and preserves the Makefile's property of specifying no `-march` at all; a global flag would silently permit `Zba` in every other assembly test.
- **New ops were appended *after* `ILLEGAL` in [defines/op.sv](../defines/op.sv).** `op::t` values are positional, and [test/sv/test_execute_compare.sv](../test/sv/test_execute_compare.sv) feeds `op::ILLEGAL` directly into a frozen reference model. Inserting ahead of `ILLEGAL` would have renumbered it from 49 to 52 and handed the golden model a code it has never seen. The enum stays 6 bits and `instruction::t` stays 65 bits, so every reference port width is unchanged — `Zba` took the count to 53 of 64, and the `M` extension appended after it takes it to 61.
- **Three fixed shifts, not one variable shift.** Each `alu_sel` arm hardwires its shift amount, which is free wiring into the existing adder. A single parameterised arm would need a shift-amount signal crossing the `alu_sel` boundary and would likely infer a second barrel shifter beside the one `SLL`/`SRL`/`SRA` already share — a poor trade on a design with this timing margin.

## Zicntr — User-Mode Counters

`Zicntr` defines three read-only counters that unprivileged code can read without a system call: `cycle` (elapsed core cycles), `time` (wall-clock), and `instret` (instructions retired), each with a high half for the upper 32 bits of its 64-bit value.

| CSR | Address | Shadows | Notes |
|---|---|---|---|
| `cycle` / `cycleh` | `0xC00` / `0xC80` | `mcycle` / `mcycleh` | Counts every cycle, including during reset |
| `time` / `timeh` | `0xC01` / `0xC81` | the timer's memory-mapped `mtime` | True shadow — tracks software writes to `mtime` |
| `instret` / `instreth` | `0xC02` / `0xC82` | `minstret` / `minstreth` | +1 per `VALID` retire |

**`time` is wired to the real `mtime`.** The spec defines `time` as a shadow of the memory-mapped `mtime`, not of the cycle counter, so [lib/wishbone/wishbone_timer.sv](../lib/wishbone/wishbone_timer.sv) exports its 64-bit `mtime` register, [rtl/mcu.sv](../rtl/mcu.sv) routes it into the core, and [rtl/writeback_stage.sv](../rtl/writeback_stage.sv) reads it. A core-private counter would have been simpler but wrong here in a way this repo can actually observe: [test/asm/trap.s](../test/asm/trap.s) writes `mtime` over the Wishbone bus in its timer handler, so a private counter would desynchronise on the very first timer test.

**All six are read-only, and that came for free.** The decoder already traps any CSR write whose address has bits `[11:10] == 2'b11`, which covers the whole `0xC00`/`0xC80` range. Writes via `csrrw`/`csrrwi` always trap; `csrrs`/`csrrc`/`csrrsi`/`csrrci` trap only when their source field is nonzero, so a zero-source `csrrs` remains a legal pure read.

### Verification

[test/asm/zicntr.s](../test/asm/zicntr.s) proves the aliases are exact rather than merely plausible. Since `mcycle` is writable and `cycle` is not, it writes a marker through `mcycle` and reads it back through `cycle`; a separate argument measures the spacing of `mcycle→mcycle`, `mcycle→cycle` and `cycle→mcycle` reads, which forces any constant offset between the two counters to zero. `time` is proven a real shadow by writing `mtime`/`mtimeh` through the timer's bus registers and reading the values back out of the CSRs. All 36 write forms (6 CSRs × 6 instructions) are checked to trap with `mcause=2`, and all 24 read forms to succeed.

```bash
make test/asm/zicntr
```

### Implementation Notes

- **Do not add `_zicntr` to `-march`.** binutils 2.39 rejects the token outright (`unknown prefixed ISA extension 'zicntr'`). None is needed: the stock default `-march=rv32i` already accepts all six CSRs by name, so `csrr t0, cycle` assembles as-is and no Makefile change is required.
- **`mcounteren` stays hardwired to zero.** It gates counter access from privilege modes below M, and this core is M-mode only. Reading zero is legal WARL; implementing a register that reads back nonzero would imply gating the hardware cannot perform. If U-mode is ever added, `mcounteren` must be implemented for real.
- **`time` ticks at the core clock.** `mtime` increments once per `clk`, the same clock driving `mcycle`, so on this platform the two advance at the same rate and differ only by an offset (`mcycle` counts during reset; `mtime` is software-writable). That is a legal fixed-frequency clock, not an independent oscillator.
- **Reading a 64-bit counter on RV32** needs the standard retry loop — read the high half, read the low half, read the high half again, and repeat if it changed — because the two halves cannot be sampled atomically.
- **Golden-model note.** `writeback_stage` gained an `mtime_in` port that the frozen reference does not have; the DUT-vs-REF testbenches simply leave it unconnected, exactly as they already do for the branch predictor's ports. To run a test on the golden CPU, append a `+define+USE_REF_CPU` line to [sim/files.txt](../sim/files.txt) and rebuild — the guard in [rtl/mcu.sv](../rtl/mcu.sv) then instantiates `ref_cpu` with the `mtime_in` pin excluded, and the simulation prints `REFERENCE IMPLEMENTATION OF "cpu.sv" USED!`.

## Zifencei — Instruction-Fetch Synchronisation

`FENCE` and `FENCE.I` look like they should both be no-ops on a machine this simple. One of them is; the other is not, and the difference is worth spelling out.

**Plain `FENCE` genuinely is a no-op here — correctly so.** A fence orders memory operations as seen by *other* observers (other harts, DMA engines, devices); a hart always sees its own accesses in program order regardless. This SoC has a single hart, no DMA, no store buffer, and a Memory stage that stalls the whole pipeline until each Wishbone access is acknowledged ([rtl/memory_stage.sv](../rtl/memory_stage.sv), `mem_stall`). Every store is therefore globally visible before the next memory access can even begin, so every `pred`/`succ` combination is satisfied by construction. `FENCE` is decoded, flows down the pipe, and retires without side effects. It is still decoded rather than trapped because compilers emit fences unconditionally for `volatile` MMIO and atomics.

**`FENCE.I` does real work.** Instruction and data memory are one shared BRAM ([rtl/mcu.sv](../rtl/mcu.sv) instantiates a single `wishbone_ram`: port A = fetch bus, port B = data bus), and the linker places everything in one `RAM(rwx)` region, so `.text` is writable. There is no instruction cache and no prefetch buffer — but the **pipeline itself is a four-instruction prefetch window**. A store that patches a nearby upcoming instruction lands in RAM *after* that instruction has already been latched into pipeline registers, so the stale copy executes. `FENCE.I` fixes exactly this: Writeback treats a `VALID` `FENCE_I` as a `JUMP` to `next_program_counter_in` (PC+4), squashing Fetch/Decode/Execute/Memory and refetching from the now-updated RAM.

| Aspect | Behaviour |
|---|---|
| Decode | Opcode `0001111` + `funct3=001` only — the reserved `rd`/`rs1`/`imm` fields are ignored, never trapped, as Zifencei v2.0 requires |
| Architectural effect | `status_backwards_out = JUMP` to PC+4 in [rtl/writeback_stage.sv](../rtl/writeback_stage.sv); flushes all four younger stages |
| Register file | Never written — `forwarding_out.data_valid` is forced low |
| Ordering | The jump is decided in **Writeback**, strictly downstream of where a store commits in Memory, so a preceding `sw` is always visible to the refetch (≈3 half-cycles of margin) |
| Scope | Local hart only, per spec — there is no second hart to notify |

### Verification

The assembly test [test/asm/fencei.s](../test/asm/fencei.s) patches an upcoming instruction word with `sw`, executes `FENCE.I`, then falls through into the patched location:

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

At the writeback level, `FENCE.I` and plain `FENCE` are additionally validated against the golden reference model by SWEEP 14 and SWEEP 15 of [test/sv/test_writeback_compare.sv](../test/sv/test_writeback_compare.sv).

### Implementation Notes

- **The staleness window is 3 instruction slots.** Measured by sweeping the patch distance with `FENCE.I` removed: words at `sw+4`, `sw+8` and `sw+12` executed stale, while `sw+16` and beyond were fresh. Forcing extra stall cycles into the gap does not narrow it — Fetch holds both its PC and its instruction register while stalled, so stalling can never refresh an already-latched instruction.
- **The `sw+12` case is simulator-specific.** At that distance the patch is a same-cycle, cross-port read/write collision in the block RAM. Verilator resolves it deterministically to *read-old*; on real Xilinx BRAM, cross-port collision data is **undefined**. That boundary case is therefore reported as "not reliably fresh" rather than "definitely stale" — which is why [test/asm/fencei.s](../test/asm/fencei.s) only ever asserts the *post-`FENCE.I`* behaviour, which is architecturally guaranteed on both simulator and silicon.
- **A taken jump happens to have the same effect — do not rely on it.** Any `JUMP` flushes the pipeline, so on this core a `JAL` also makes a preceding store visible to the refetch. That is an accident of the microarchitecture, not an architectural guarantee; portable software must use `FENCE.I`. (The bootloader's self-copy-then-jump sequence works for precisely this reason.)
- **No cache maintenance is involved.** On a machine with a writeback D-cache and a non-coherent I-cache, `FENCE.I` typically has to drain the store buffer, write back dirty data lines, and invalidate instruction lines. Here there are no caches at all, so the entire obligation reduces to the pipeline flush. `FENCE.I` is still not a data-cache maintenance instruction — it does not order stores against DMA or other harts.

## Branch Predictor Extension

Standard HaDes-V is a **predict-never-taken** machine: every branch is speculatively treated as not-taken, and a taken branch always costs **two bubble cycles** while Fetch/Decode are flushed and the correct PC is reloaded. For code with many backward-taken branches (tight loops), this is a significant throughput loss.

The branch predictor extension eliminates the flush penalty for correctly-predicted branches. It is implemented across four files:

| File | Role |
|---|---|
| [defines/bpredict.sv](../defines/bpredict.sv) | `bpredict::bp_data_t` packed struct — 8 bits threading prediction state through the pipeline |
| [rtl/branch_predictor.sv](../rtl/branch_predictor.sv) | Submodule instantiated inside Fetch; contains all four prediction algorithms |
| [rtl/fetch_stage.sv](../rtl/fetch_stage.sv) | Speculatively updates the PC using the predictor's output |
| [rtl/execute_stage.sv](../rtl/execute_stage.sv) | Detects mispredictions instead of flushing on every taken branch |

### The `bp_data_t` Pipeline Struct

A single 8-bit struct travels with each instruction from Fetch through to Execute, carrying the prediction that was made when that instruction was fetched:

```
struct packed {
    logic       valid;            // 1 = this instruction is an aligned branch with a prediction
    logic       predicted_taken;  // the predictor's guess at fetch time
    logic       was_taken;        // actual outcome (filled in by Execute)
    logic [4:0] index;            // 2-bit counter table index (for feedback update)
}
```

### Four Prediction Algorithms

The prediction algorithm is selected at runtime by writing to `MHPMEVENT10` (CSR `0x32A`). All four algorithms live in [rtl/branch_predictor.sv](../rtl/branch_predictor.sv) and are mux'd by `bp_control_in[1:0]`:

| Mode | `MHPMEVENT10` value | Algorithm | Description |
|---|---|---|---|
| **0** | `0` | **Predict Never Taken** | Default HaDes-V behaviour. All branches are predicted not-taken. No pipeline change for taken branches (they still flush, as before). Zero prediction logic required. |
| **1** | `1` | **Predict Always Taken** | All aligned branches are predicted taken. Good for single loops but causes one flush on every exit. |
| **2** | `2` | **Predict Backward Taken** | Branches with a **negative offset** (bit 31 of the branch displacement = 1, i.e. the target is at a lower address) are predicted taken; forward branches are predicted not-taken. This fixed heuristic is free of state and correct for the dominant loop pattern. |
| **3** | `3` | **2-bit Saturating Counter Array** | Adaptive bimodal predictor. A table of 32 entries, each a 2-bit saturating counter (SNT → WNT → WT → ST). Indexed by `{branch_offset[31], pc[5:2]}` — one bit encodes direction (backward/forward), four bits address the instruction within its cache line. Updated by feedback from Execute after each resolved branch. On reset: the backward half initialises to *Weak Taken* and the forward half to *Weak Not-Taken*, matching the Backward-Taken heuristic as a zero-warmup starting point. |

Only **aligned** branch targets are predicted (`branch_offset[1:0] == 2'b00`). Misaligned branches fall through to the normal `FETCH_MISALIGNED` exception path unchanged.

### Pipeline Integration

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

`next_pc` is more than the flush address: it travels with the instruction to Writeback as `next_program_counter`, and Writeback uses it as `MEPC` when an interrupt is taken right after that instruction (the retiring instruction *J* in the interrupt's `JUMP` cycle, or the saved next PC of *I* when *J* is a bubble or carries an exception). It must therefore be the architectural successor, independent of the prediction. It used to be `is_mispredicted_branch ? corrected_address : …`, so a **correctly predicted taken** branch carried `pc + 4`, and an interrupt right after it returned to the *not-taken* path: loops exited early, a skipped instruction ran, and an `ECALL` at the branch target was skipped. Under FreeRTOS with the predictor on this caused `configASSERT`s, lost yields and hangs. Mode 0 never predicts taken, so it was not affected, and the new expression is identical to the old one when `predicted_taken = 0`. The `VALID` gate keeps `pc + 4` for a squashed branch, as the golden `ref_execute_stage` does. Regressions: [bpirq.s](../test/asm/bpirq.s), [bpirq2.s](../test/asm/bpirq2.s), [bpirq3.s](../test/asm/bpirq3.s), and [test_execute_bpred_nextpc.sv](../test/sv/test_execute_bpred_nextpc.sv), which checks `next_program_counter` against the golden execute stage for every prediction.

**Feedback loop.**  
After Execute resolves a branch, it drives `bp_feedback_out` combinationally back to the Fetch stage (directly via a wire in [cpu.sv](../rtl/cpu.sv), bypassing Memory and Writeback):

```
bp_feedback_out.valid          = is_branch && VALID && !STALL;
bp_feedback_out.was_taken      = branch_taken;
bp_feedback_out.predicted_taken = bp_prediction_in.predicted_taken;
bp_feedback_out.index          = bp_prediction_in.index;
```

The branch predictor's `always_ff` block samples this at the next posedge and updates `counter_store[update_index]`. The feedback also reaches Writeback (same wire) for the performance counters.

### New CSRs — Branch Predictor Control and Monitoring

Five new CSRs are implemented in [rtl/writeback_stage.sv](../rtl/writeback_stage.sv). All are read/write. CSR addresses are already defined in [defines/csr.sv](../defines/csr.sv).

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

### Verification

The assembly test [test/asm/bpred.s](../test/asm/bpred.s) verifies all three non-trivial predictor modes without using UART (pass/fail reported directly through the test peripheral at `TEST_ADDRESS = 0x480000`):

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
| [test/asm/bpirq.s](../test/asm/bpirq.s) | Modes 0–3 × IRQ delays 1–80 over a 40-iteration backward loop. | The loop count must be 40. Prints `M<mismatches> I<irqs>`. |
| [test/asm/bpirq2.s](../test/asm/bpirq2.s) | Modes 0–3 × delays 1–32, with three shapes: a backward loop, a forward branch over a poison instruction, and a load-use at the target. | Count exact, no poison executed. |
| [test/asm/bpirq3.s](../test/asm/bpirq3.s) | The Writeback paths where `MEPC` comes from the *interrupted* branch's next PC. The branch is followed by a bubble (CSR-use stall at its target) or by an `ECALL` at its target. | Exact loop count, one `ECALL` per iteration, no poison. Prints `D/E/F` mismatches. |
| [test/sv/test_execute_bpred_nextpc.sv](../test/sv/test_execute_bpred_nextpc.sv) | 20,000 random branches with random prediction and status, against `ref_execute_stage`. | `next_program_counter` must match golden for every prediction. Flushes happen exactly on mispredictions, to the golden next PC. |

```bash
make test/asm/bpirq test/asm/bpirq2 test/asm/bpirq3 test/sv/test_execute_bpred_nextpc
```

Under an RTOS, `FRTOS_BPRED=<mode>` makes a FreeRTOS program write `MHPMEVENT10` at start-up (the golden CPU ignores it and stays a valid twin). The campaign sets `bpred` (stress/minimal/mzba/full with the predictor on) and `breaker`/`breaker2`/`breaker-long` (the `brk` program, including random run-time mode changes) run the predictor in modes 1–3 against the golden CPU. The predictor-off sets never switch it on. `test/trapsweep` family `bp` sweeps interrupts around predicted branches in every mode:

```bash
python3 test/freertos/campaign.py --set bpred --seeds 4
python3 test/freertos/campaign.py --set breaker --seeds 8 --run-cycles 20000000
python3 test/trapsweep/sweep.py run --fam bp
```

### Implementation Notes

- **No BTB.** This is a pure bimodal predictor — no branch-target buffer. The target address is always computed by Decode from the immediate field. Prediction only decides whether to speculatively advance the PC; misses are corrected in Execute with the same mechanism as the original taken-branch flush.
- **Only `Bxxx` instructions** (opcode `7'b1100011`) are predicted. `JAL` and `JALR` are unconditional and always cause a flush via `is_jump`, unchanged from the original design.
- **Alignment guard.** `predicted_taken` is suppressed for branches whose target is not 4-byte aligned (`branch_offset[1:0] != 2'b00`). These fall through to the existing `FETCH_MISALIGNED` exception path.
- **Mode 0 is zero-overhead.** When `MHPMEVENT10 = 0`, `predicted_taken = 0` unconditionally. `is_mispredicted_branch` reduces to `is_branch && branch_taken && VALID`, which is the original `jump_detected` formula, and `next_pc` reduces to the original expression. The pipeline behaves identically to unmodified HaDes-V.
- **The prediction never reaches architectural state.** It only decides whether Execute flushes. `next_program_counter`, which becomes `MEPC` for an interrupt taken right after the branch, is always the resolved successor (see [Execute stage](#branch-predictor-extension) above).
- **Simulator echo.** [lib/wishbone/wishbone_uart.sv](../lib/wishbone/wishbone_uart.sv) includes an `always @(posedge clk)` block that calls `$write("%c", byte)` whenever a TX buffer write is detected, echoing UART output to Verilator's stdout. This is purely a simulation convenience; `$write` is ignored by synthesis tools.
