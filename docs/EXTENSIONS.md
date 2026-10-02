[HaDes-V+](../README.md) · [Docs](README.md) · [Building](BUILDING.md) · [FreeRTOS](FREERTOS.md) · [Shell](SHELL.md) · [Apps](APPS.md) · [Architecture](ARCHITECTURE.md) · **Extensions** · [Verification](VERIFICATION.md)

# Extensions

Everything in this document is work added after the upstream lab; the baseline core implements RV32I with `Zicsr`, and its `FENCE.I` was present but untested (see [Zifencei](#zifencei--instruction-fetch-synchronisation)).

With them the core implements `rv32imb_zicntr_zicond_zicsr_zifencei` (B = Zba + Zbb + Zbs), summarised under [Instruction Set](ARCHITECTURE.md#instruction-set). Each section below describes one extension: its design, how it is verified, and implementation notes. The output of every test in the tables below is recorded in [results/tests](../results/tests/2026-10-01_03386fd/RECORD.md); each measured figure links its own record.

**Contents**

1. [What HaDes-V+ Adds](#what-hades-v-adds)
2. [M — Multiply and Divide](#m--multiply-and-divide)
3. [Zba — Scaled-Index Address Generation](#zba--scaled-index-address-generation)
4. [Zicntr — User-Mode Counters](#zicntr--user-mode-counters)
5. [Zifencei — Instruction-Fetch Synchronisation](#zifencei--instruction-fetch-synchronisation)
6. [Branch Predictor Extension](#branch-predictor-extension)
7. [Zbb and Zbs — Bit Manipulation (B)](#zbb-and-zbs--bit-manipulation-b)
8. [Zicond — Conditional Zero](#zicond--conditional-zero)

## What HaDes-V+ Adds

| Addition | Summary | Detail |
|---|---|---|
| **M** — multiply/divide | All eight instructions. 2-cycle registered multiply, 34-cycle restoring divider ([record](../results/m-unit-cycles/2026-10-01_03386fd/RECORD.md)), and the first self-generated stall in the Execute stage | [§](#m--multiply-and-divide) |
| **Zba** — address generation | `sh1add`/`sh2add`/`sh3add`, which replace the `slli` + `add` pair of a scaled array index; GCC emits them for ordinary indexing code when it optimises (`-O2`, `-Os`) | [§](#zba--scaled-index-address-generation) |
| **Zicntr** — user counters | `cycle`, `time`, `instret` (+ high halves), with `time` shadowing the real memory-mapped `mtime` | [§](#zicntr--user-mode-counters) |
| **Zifencei** — documented & tested | `FENCE.I` was implemented but never actually verified upstream; now tested ([fencei.s](../test/asm/fencei.s)), and the 3-slot staleness window that it closes is measured (`make bench-fencei-window`, [record](../results/fencei-window/2026-10-01_03386fd/RECORD.md)) | [§](#zifencei--instruction-fetch-synchronisation) |
| **Zbb**, **Zbs** — bit manipulation | 26 instructions on RV32: counts (`clz`, `ctz`, `cpop`), `min`/`max`, sign and zero extension, `andn`/`orn`/`xnor`, rotates, `orc.b`, `rev8`, and single-bit set, clear, invert and extract. With Zba they make the ratified **B** extension. One new op for all of them, single-cycle; GCC emits most of them from plain C; `make bench-zbb` ([record](../results/zbb/2026-10-02_e75223e/RECORD.md)) | [§](#zbb-and-zbs--bit-manipulation-b) |
| **Zicond** — conditional zero | `czero.eqz` and `czero.nez`, a branch-free select; usable from C through [std/include/zicond.h](../std/include/zicond.h) | [§](#zicond--conditional-zero) |
| **Branch predictor** | Four run-time selectable algorithms — never-taken (the reset default), always-taken, backward-taken and bimodal 2-bit counters — with four outcome counters as CSRs; a correctly predicted branch causes no pipeline flush | [§](#branch-predictor-extension) |
| **FreeRTOS** | The official RISC-V port boots unmodified; one-command build and run, a differential stress campaign against the golden CPU, a template for your own programs, and an interactive command shell (FreeRTOS+CLI) you type into from your terminal. In simulation, the shell can also receive programs compiled on the host over the UART and run them as a task (`make freertos-shell APP=loader UPLOAD=hello`, then `load` and `run`); an app that raises an exception is stopped and reported while the shell carries on, as far as machine mode without memory protection allows ([guide](APPS.md)) | [§](FREERTOS.md) |

Nine correctness fixes to the upstream design are also included. Two predate the RTOS work: a decoder defect that corrupted registers on stores and branches (which prevented the bootloader from running at all), and a forwarding defect that leaked a garbage value for `FENCE` instructions carrying a non-zero reserved field. Six are trap and interrupt defects: four exposed by running FreeRTOS under randomised interrupt timing, and two by the interrupt-offset sweep against the independent instruction-set model ([record](../results/history/2026-09-27_6b19d41/RECORD.md)); see [the defects and their regression tests](VERIFICATION.md#freertos-differential-campaigns). The ninth is in the UART: a byte store to a status byte drove the transmit interrupt from the wrong enable bit for one cycle, which could raise an interrupt without a source ([test/asm/uartirq.s](../test/asm/uartirq.s)).

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

*(Measured in the assembled core over 800 back-to-back operations, minus the loop overhead, which the same loop with an empty body measures: `make bench-mcost`, [test/bench/mcost/](../test/bench/mcost) ([record](../results/m-unit-cycles/2026-10-01_03386fd/RECORD.md)). Its `mcost.c`, which times 512 of each of the eight instructions with `mcycle`, gives the same values.)*

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
| [test/asm/div.s](../test/asm/div.s) | All four quadrants of truncating division, divide-by-zero for all four instructions over six dividends, the `-2³¹ / -1` overflow, dependent divide chains, quotients used as load/store addresses, divides in front of taken and not-taken branches, and an external interrupt swept across the 34-cycle window — when the unit was added, 20 of the sweep's flushes landed on an unfinished divide ([record](../results/history/2026-08-18_c00c4db/RECORD.md)). |
| [test/c/m_extension.c](../test/c/m_extension.c) | 200 differential checks against **libgcc**: each pair is computed once by a hardware M instruction and once by `__mulsi3`/`__muldi3`/`__divsi3`/`__modsi3`/`__udivsi3`/`__umodsi3`, which are independent RV32I software running on the same core. The two inputs that are undefined behaviour in C are checked against the mandated constants instead. |
| [test/sv/test_zba_encoding_sweep.sv](../test/sv/test_zba_encoding_sweep.sv) | The decoder sweep (486,896 words; 290,288 before the Zbb, Zbs and Zicond sweeps were added) also requires the DUT to match the reference everywhere except the Zba **and** M words (and, since they were added, the Zbb, Zbs and Zicond words), so a decode arm that is too broad still shows up as a leak. |

```bash
make test/sv/test_m_execute
make test/asm/mul
make test/asm/div
make test/c/m_extension
```

### Implementation Notes

- **FPGA timing is marginal.** The RTL meets timing on the `xc7a35tcpg236-1` at 20 ns (50 MHz): post-route **WNS +0.016 ns**, 0 failing endpoints of 11070 (Vivado 2024.2; a repeated run of the same flow gives the same result). That was measured at commit cbae9b9; the current RTL differs from it by the one-line UART fix of 03386fd and by the Zbb, Zbs and Zicond unit in Execute (and its decoder), and has not itself been implemented ([record](../results/fpga-timing/2026-09-30_cbae9b9/RECORD.md)); see the [timing note of Zbb and Zbs](#implementation-notes-5). Its worst path starts at the block RAM, which delivers the fetched instruction on the falling clock edge, and runs through the branch predictor and the adder of the speculative PC to the Fetch stage's PC register, so it has half a clock period, 10 ns: 14 logic levels, 7 of them carry-chain stages, with about 53 % of the delay in logic. The history below explains why the margin is this thin. With the same flow, the commit that added M (c00c4db) reported post-route **WNS −0.120 ns** with 2 failing endpoints of 11214, while its parent reported **+0.026 ns** with none ([record](../results/fpga-timing/2026-08-18_c00c4db/RECORD.md)). A bitstream is still produced — `write_bitstream` does not check timing — so a successful `make synthesis` is *not* evidence of closure; read `build/synth/reports/timing_pnr.rpt`. Two caveats matter before blaming the multiplier. First, **no M cell appeared in the 40 worst paths** of a second implementation of the same RTL, run with extra reporting commands (WNS −1.054 ns): there the multiply closed with +6.15 ns and the divider with +10.19 ns. The failing path was a pre-existing 21-level, ~85 %-route path from the Memory stage's instruction register, through the waived `LUTLP-1` combinational-loop tangle, to the `mcause` register's clock enable — M's ~9 % area growth degraded its routing rather than lengthening its logic. Second, **small RTL changes move the worst path and change its slack**: the recorded `make synthesis` results of earlier revisions range from −0.120 ns to +0.242 ns, the same RTL implemented with extra reporting commands ended about 1 ns lower (−1.054 ns for c00c4db, −0.883 ns for its parent; [records](../results/README.md#fpga-timing)), and the worst path has moved since, so a single result cannot cleanly attribute the 0.15 ns that M cost. The honest summary is that the design has been running at roughly zero margin since before M — the +0.221 ns recorded with the branch-predictor bitstream (commit 15b0b85, [record](../results/fpga-timing/2026-08-17_15b0b85/RECORD.md)) predates the `Zicntr` and `Zba` commits — and the real fix is to shorten these long paths rather than to pipeline the multiplier further.
- **The M results bypass `alu_sel` entirely.** `alu_sel` is a 4-bit local with only `1110`/`1111` free (`1110` has since been taken by the Zbb, Zbs and Zicond unit), and it is internal to `execute_stage` (not a struct field or port), so widening it would have been safe with respect to the frozen models. It was not widened anyway: half the M results come out of a sequential FSM and cannot be arms of the `always_comb` case that computes `alu_result`, and this design has essentially no timing margin to spend restructuring a block already near the critical path (see the FPGA timing note above). `m_result` is a second result bus that meets the ALU at the `rd_data` mux — one extra 2:1 level instead of six extra arms inside the ALU mux.
- **The multiply is registered, not combinational.** A 33×33 signed product is an array of DSP48E1 tiles plus an adder tree; run with no internal pipeline register it is comfortably the deepest combinational block in the core, and it would land on a path that runs from Decode's output registers through the multiplier, the `rd_data` mux and the forwarding network back into Decode's output registers — one 20 ns period, in a design with almost no margin to give. Registering the product puts a flop directly on the multiplier output. The price is one stall cycle, and since the divider needs the stall generator anyway it costs no extra machinery. Measured on the routed design the multiply path closes with **+6.15 ns** of slack ([record](../results/fpga-timing/2026-08-18_c00c4db/RECORD.md)), so the decision is vindicated — though Vivado did *not* absorb the flop into the DSP48E1's `P` register as intended, because the `MUL`-vs-`MULH` output mux sits between the DSP cascade and the register. Registering the full 64-bit product and muxing after the flops would allow that, at the cost of 32 extra FFs; it is not needed at this margin.
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

**The compiler emits them for you.** Building with `-march=rv32i_zba` and optimisation (`-O2`, `-Os`) makes GCC 12 generate `sh1add`/`sh2add`/`sh3add` automatically for ordinary indexing code — no intrinsics or inline assembly required.

### Verification

The frozen reference models predate `Zba` and can only report it as illegal, so correctness is established by **differential testing against the toolchain** instead: the same C program is compiled twice, once as plain RV32I (`slli`+`add`) and once with `-march=rv32i_zba`, and both binaries must produce byte-identical output on the core. The two programs are semantically identical, so any divergence is a hardware fault.

| Test | What it covers |
|---|---|
| [test/asm/zba.s](../test/asm/zba.s) | 23 blocks / 62 assertions: zero and `x0` operands, `rd`/`rs1`/`rs2` aliasing, negative `rs1` with the sign bit shifted out, 32-bit overflow wrap, and forwarding from all three stages including into load/store addresses |
| [test/asm/zbaadv.s](../test/asm/zbaadv.s) | 49 adversarial tests / 103 assertions written independently, including operand-order traps and pipeline-position interactions |
| [test/sv/test_zba_encoding_sweep.sv](../test/sv/test_zba_encoding_sweep.sv) | DUT-vs-reference decoder sweep, plus enum and struct width assertions: 486,896 words, 290,288 of them before the [Zbb, Zbs and Zicond](#verification-5) sweeps were added |

```bash
make test/asm/zba
make test/asm/zbaadv
make test/sv/test_zba_encoding_sweep
```

`make bench-zba` measures the effect ([test/bench/zba/](../test/bench/zba), [guide](../test/bench/README.md#make-bench-zba)). It builds `zba_bench` and `zba_arr` for `rv32i` and for `rv32i_zba` and requires the same output from both builds; `zba_diff`, built for `rv32i` only, issues the Zba instructions as `.insn` words. Its timed program, `zba_bench`, is a best case: a loop of scaled-index array accesses and multiplications by small constants. At `-O2` it runs in **20.3 % fewer cycles** with Zba (45,350 → 36,133, 1.26×), and the program images are 6–8 % smaller (`zba_bench` 940 → 868, `zba_arr` 1,680 → 1,576 bytes); `zba_diff` compares 16,704 results of the Zba instructions with the same computations in RV32I code, with zero discrepancies. At `-Os` the gain is 14.0 % (`make bench-zba OPT=-Os`); at `-O0` GCC emits no Zba instruction, and the two builds are identical. The `-O2` figures were first measured on 2026-08-18 on the tree committed as 1f501f5, and all of them reproduce exactly at 03386fd ([record](../results/zba/2026-10-01_03386fd/RECORD.md)). The `mzba` FreeRTOS program makes a differential check of the same kind under the RTOS: built with `MARCH=rv32im_zba`, it compares every result computed with the M and Zba instructions with the same computation built for plain RV32I (`make freertos APP=mzba MARCH=rv32im_zba`).

### Implementation Notes

- **Assembled via a directive, not a global flag.** [test/asm/zba.s](../test/asm/zba.s) carries `.option arch, +zba` rather than adding `-march=rv32i_zba` to the Makefile. This keeps the requirement next to the file that needs it and preserves the Makefile's property of specifying no `-march` at all; a global flag would silently permit `Zba` in every other assembly test.
- **New ops were appended *after* `ILLEGAL` in [defines/op.sv](../defines/op.sv).** `op::t` values are positional, and [test/sv/test_execute_compare.sv](../test/sv/test_execute_compare.sv) feeds `op::ILLEGAL` directly into a frozen reference model. Inserting ahead of `ILLEGAL` would have renumbered it from 49 to 52 and handed the golden model a code it has never seen. The enum stays 6 bits and `instruction::t` stays 65 bits, so every reference port width is unchanged — `Zba` took the count to 53 of 64, the `M` extension appended after it took it to 61, and `EXT`, the one op of [Zbb, Zbs and Zicond](#design-one-op-the-sub-operation-in-the-immediate), to 62.
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

- **The staleness window is 3 instruction slots.** A program that patches the instruction 4 to 20 bytes after a store, without executing `FENCE.I`, measures it (`make bench-fencei-window`, [test/bench/fencei-window/](../test/bench/fencei-window)): the words at `sw+4`, `sw+8` and `sw+12` executed stale, while `sw+16` and `sw+20` were fresh. Forcing extra stall cycles into the gap does not narrow it — with two loads in the gap that add 3 stall cycles, `sw+12` is still stale — because Fetch holds both its PC and its instruction register while stalled, so stalling can never refresh an already-latched instruction. The window was first measured on 2026-08-17 at 15b0b85 and reproduces exactly at 03386fd ([record](../results/fencei-window/2026-10-01_03386fd/RECORD.md)).
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

Interrupts next to predicted branches are covered by four regression tests. The golden CPU has no predictor, ignores `MHPMEVENT10` and passes all three asm tests (observed during development, not recorded), so it is a valid twin for them:

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

## Zbb and Zbs — Bit Manipulation (B)

`Zbb` (basic bit manipulation, 18 instructions on RV32) and `Zbs` (single-bit instructions, 8) are the other two parts of the ratified **B** extension. With Zba, Zbb and Zbs, HaDes-V+ implements the ratified B extension (B = Zba + Zbb + Zbs, "'B' Extension for Bit Manipulation", Version 1.0.0). Every instruction is a single-cycle operation in Execute with the forwarding of an `add`; none of them can raise an exception.

`misa` reads 0 on HaDes-V+ (it is not implemented, as before), so its B bit (bit 1) is not set either; unlike the Z extensions, B is a single letter and has a `misa` bit, but the core reports no extension there.

**Zbb** (OP = `0110011`, OP-IMM = `0010011`; for the unary forms the `rs2` field is part of the opcode):

| Instruction | Opcode | funct7 | rs2 field | funct3 | Operation |
|---|---|---|---|---|---|
| `andn` | OP | `0100000` | rs2 | `111` | `rd = rs1 & ~rs2` |
| `orn` | OP | `0100000` | rs2 | `110` | `rd = rs1 \| ~rs2` |
| `xnor` | OP | `0100000` | rs2 | `100` | `rd = ~(rs1 ^ rs2)` |
| `clz` | OP-IMM | `0110000` | `00000` | `001` | leading zeros of rs1 (32 for 0) |
| `ctz` | OP-IMM | `0110000` | `00001` | `001` | trailing zeros of rs1 (32 for 0) |
| `cpop` | OP-IMM | `0110000` | `00010` | `001` | set bits of rs1 |
| `max` / `maxu` | OP | `0000101` | rs2 | `110` / `111` | the larger of rs1, rs2 (signed / unsigned) |
| `min` / `minu` | OP | `0000101` | rs2 | `100` / `101` | the smaller of rs1, rs2 (signed / unsigned) |
| `sext.b` | OP-IMM | `0110000` | `00100` | `001` | rs1[7:0] sign-extended |
| `sext.h` | OP-IMM | `0110000` | `00101` | `001` | rs1[15:0] sign-extended |
| `zext.h` | OP | `0000100` | `00000` | `100` | rs1[15:0] zero-extended |
| `rol` / `ror` | OP | `0110000` | rs2 | `001` / `101` | rs1 rotated left / right by rs2[4:0] |
| `rori` | OP-IMM | `0110000` | shamt | `101` | rs1 rotated right by shamt |
| `orc.b` | OP-IMM | `0010100` | `00111` | `101` | each byte of rs1 becomes `0x00` if it is zero, else `0xFF` |
| `rev8` | OP-IMM | `0110100` | `11000` | `101` | the byte order of rs1 reversed |

**Zbs** (the bit number is rs2[4:0] or shamt):

| Instruction | Opcode | funct7 | funct3 | Operation |
|---|---|---|---|---|
| `bclr` / `bclri` | OP / OP-IMM | `0100100` | `001` | `rd = rs1 & ~(1 << n)` |
| `bext` / `bexti` | OP / OP-IMM | `0100100` | `101` | `rd = (rs1 >> n) & 1` |
| `binv` / `binvi` | OP / OP-IMM | `0110100` | `001` | `rd = rs1 ^ (1 << n)` |
| `bset` / `bseti` | OP / OP-IMM | `0010100` | `001` | `rd = rs1 \| (1 << n)` |

On RV32 the immediate forms (`rori`, `bclri`, `bexti`, `binvi`, `bseti`) are legal only with `shamt[5] = 0`; the other half of their encodings, the RV64-only word forms under OP-32 and OP-IMM-32 (`clzw`, `rolw`, the RV64 `zext.h`, ...) and every other neighbour stay illegal instructions, as before.

**The compiler emits most of them for you.** Built with `-march=rv32im_zba_zbb_zbs` (GCC 12 does not accept the single letter `b`) and optimisation, GCC turns ordinary C into these instructions: `__builtin_popcount` into `cpop`, `__builtin_clz`/`__builtin_ctz` into `clz`/`ctz`, `a < b ? a : b` into `min`/`minu`, casts to `int8_t`/`int16_t`/`uint16_t` into `sext.b`/`sext.h`/`zext.h`, `a & ~b` into `andn`, `(x >> n) | (x << (32 - n))` into `ror`/`rori`, and `x | (1u << n)` into `bset`. Three need inline assembly with GCC 12 on RV32: `rev8` (`__builtin_bswap32` becomes a call to `__bswapsi2`), `orc.b`, and, depending on the idiom, `bclr`, `bext` and `binv` (when GCC sees the bit number masked with `& 31`, it uses `bset` with `andn`, `srl` with `andi`, or `bset` with `xor`). The example app [`bitmanip`](APPS.md#the-example-apps) shows each idiom.

### Design: one op, the sub-operation in the immediate

`op::t` had three free codes left (61 to 63), not 28, and its 6-bit width and the 65-bit `instruction::t` are shared with the frozen golden stage libraries, so neither could grow. All 28 Zbb, Zbs and Zicond instructions therefore share **one** new op, `op::EXT` = 61, appended after `REMU` as Zba and M were appended after `ILLEGAL` (62 of 64 codes in use). The decoder says which instruction it is through the `immediate` field of `instruction::t`, which R-type instructions never used: a 32-bit payload, `op::ext_payload_t` in [defines/op.sv](../defines/op.sv), with a 5-bit sub-operation `{group, variant}`, a `use_imm` bit and the 5-bit shift amount of the immediate forms. The payload is canonical (unused bits are 0), so the decoder sweep can require it exactly. The sub-operation reaches Execute in a field that already exists, without a new port.

In [rtl/execute_stage.sv](../rtl/execute_stage.sv) (Part 2c) the eight groups are computed in parallel from rs1, rs2 and the payload, and one 8-way select picks the group; the result enters the ALU's result mux through the free `alu_sel` code `1110`, so it is written, forwarded and committed like an `add`:

| Group | Instructions | Hardware |
|---|---|---|
| LOGIC | `andn`, `orn`, `xnor` | rs1 combined with `~rs2`, one gate level |
| COUNT | `clz`, `ctz`, `cpop` | one leading-zero counter built as a tree (`ctz` is `clz` of the bit-reversed word, which is wiring) and an adder tree for `cpop` |
| MINMAX | `min`, `minu`, `max`, `maxu` | one comparator; flipping both sign bits turns the unsigned compare into a signed one |
| EXTEND | `sext.b`, `sext.h`, `zext.h` | wiring and a select |
| ROTATE | `rol`, `ror`, `rori` | one right-rotator; `rol` by s is `ror` by (32 − s) mod 32 |
| BYTE | `orc.b`, `rev8` | gates and wiring |
| BIT | `bclr`, `bext`, `binv`, `bset` and the immediate forms | a one-hot mask `1 << n`; `bext` reuses the rotator |
| CZERO | `czero.eqz`, `czero.nez` | a zero test of rs2 and a select ([Zicond](#zicond--conditional-zero)) |

Hazards, interrupts and the rest of the pipeline are unchanged: every op-dependent site of the RTL treats `EXT` as an ordinary ALU operation (no stall, no jump, no bus access, counted in `minstret`). A dependent instruction right behind an `EXT` instruction gets its result forwarded without a stall; a load followed by an `EXT` instruction that reads the loaded register stalls one cycle, as for any ALU instruction.

### Verification

The frozen reference models decode every Zbb, Zbs and Zicond word as an illegal instruction, so they cannot check these instructions; the golden CPU never runs them. Correctness rests on models written from the ratified ISA text without reading the RTL: [test/ext/ref.py](../test/ext/ref.py) (Python, on bit strings), [test/ext/ref_exh.c](../test/ext/ref_exh.c) (C, fast enough for all 2^32 inputs) and the instruction-set model [test/trapsweep/iss.py](../test/trapsweep/iss.py), which `ref.py --selftest` checks against each other ([test/ext/README.md](../test/ext/README.md)). The outputs below are recorded in [results/bitmanip](../results/bitmanip/2026-10-02_e75223e/RECORD.md), and the decoder sweep in [results/tests](../results/tests/2026-10-01_03386fd/RECORD.md).

| Test | What it covers |
|---|---|
| [test/sv/test_zba_encoding_sweep.sv](../test/sv/test_zba_encoding_sweep.sv) | The decoder sweep, extended: 486,896 words, among them every OP-IMM immediate × `funct3`, every OP `funct7` × rs2 field × `funct3`, and every OP-32 and OP-IMM-32 `funct7` × rs2 field × `funct3` (the RV64 word forms). Each of the 28 forms must decode to `op::EXT` with the exact payload, checked against the MATCH/MASK table of the ISA manual; every other word must decode as the golden decoder decodes it |
| [test/sv/test_ext_execute.sv](../test/sv/test_ext_execute.sv) | 927,129 checks of the Execute stage alone: known answers, every form on a 144-value corner set, random operands, and the pipeline protocol (forwarded in its own cycle, no stall) |
| `make ext-check` | The decoder feeding Execute ([test/ext/harness.sv](../test/ext/harness.sv)) against `ref_exh.c`, compared through digests: 75 digest lines, 553,624,832 vectors, identical |
| `make ext-exhaustive` | The same with the eight unary instructions (`clz`, `ctz`, `cpop`, `sext.b`, `sext.h`, `zext.h`, `orc.b`, `rev8`) over **all 2^32 inputs**: 2,091 digest lines, 34,376,492,288 vectors, identical (about 14 minutes with 4 jobs) |
| [test/asm/zbb.s](../test/asm/zbb.s), [zbs.s](../test/asm/zbs.s) | 442 and 374 assertions on the whole core: the known answers of the ISA text and corner operands, every rotate amount and bit index (with the upper 27 bits of rs2 set, which must be ignored), `x0` and aliased registers, forwarding into rs1 and rs2 at distance 1 to 3 and out into an ALU operation, a branch, a load address, store data, a `jalr` base and a CSR write, the shadow of a taken branch, an interrupt at every position of a chain, `minstret`, a dependent chain as fast as a chain of `add`, and the illegal neighbours (RV32-reserved, Zbc, Zbkb, Zbkx and RV64 encodings), which must trap with `mcause = 2` |
| Random programs (`sweep.py fuzz --variant b`) | 1,000 random programs mixing the 28 forms with RV32IM, Zba, loads, stores and branches, each run replayed by the instruction-set model: 1,000 of 1,000 consistent |
| Interrupt-offset sweep (`sweep.py run --fam ext`) | 31 probes (every form, dependent chains, a load result used at once, M neighbours, `ecall`, `mret`, results to `x0`, illegal neighbours, use in the interrupt handler) swept over every interrupt offset with the external and timer interrupts: 3 of 3 programs consistent with the model |
| `make bench-zbb` | The same C programs built for `rv32i`, `rv32i_zbb_zbs` and `rv32im_zba_zbb_zbs` must print the same values; `zbb_diff` compares 52,436 results of all 28 forms with RV32I code, with no mismatch (below) |
| FreeRTOS (`campaign.py --set bitmanip`) | The existing FreeRTOS programs built for `rv32im_zba_zbb_zbs` (the `brk` program for `rv32im_zba_zbb`, see below) at `-O2`, `-Os` and `-O0`, with preemption and the branch predictor varied, 8 seeds each: 120 of 120 runs passed on HaDes-V+ (their own self-checks; the golden CPU cannot run them) |
| The app [`bitmanip`](APPS.md#the-example-apps) | Its four sections pass on HaDes-V+ in the `rv32im_zba_zbb_zbs` build, which contains all 28 forms, with the values of its `rv32i` build, which passes on both CPUs |

```bash
make test/sv/test_zba_encoding_sweep
make test/sv/test_ext_execute
make ext-check                      # under a minute; make ext-exhaustive: all 2^32 inputs
make test/asm/zbb
make test/asm/zbs
make bench-zbb                      # OPT=-Os, OPT=-O0
python3 test/trapsweep/sweep.py fuzz --seeds 1001-2000 --variant b --targets dut --jobs 4
```

`make bench-zbb` measures the effect ([test/bench/zbb/](../test/bench/zbb), [guide](../test/bench/README.md#make-bench-zbb)). Its timed program, `zbb_bench`, is a best case: a loop of the code these extensions were made for (population counts, bit scans, clamps, packed samples, masks, rotates and a bitmap). At `-O2` it runs in **59.8 % fewer cycles** with Zbb and Zbs (302,330 → 121,388, 2.49×; with M and Zba as well, 119,852), and its image shrinks from 1,636 to 904 bytes; at `-Os` the gain is 62.0 %, and at `-O0`, where GCC still uses some of the instructions, 27.4 % ([record](../results/zbb/2026-10-02_e75223e/RECORD.md)). On ordinary code the gain is much smaller: in the FreeRTOS programs, GCC uses 12 of the 26 Zbb and Zbs forms, mostly `sext.b`, `zext.h`, `andn` and `bset`.

A mutation campaign during development checked that these tests can fail: hand-written faults in the decoder and in Execute (a wrong `funct3`, swapped signedness of `min`/`max`, `clz` off by one, the rotate direction reversed, `shamt[5]` not checked, the `czero` condition inverted, wrong sub-operation codes, and more) were each applied to a copy of the RTL. Every fault that changes a result was caught; two that cannot change any result were shown equivalent ([record](../results/bitmanip/2026-10-02_e75223e/RECORD.md#mutation-testing)).

### Implementation Notes

- **One op instead of 28.** See the design above. A consequence that applies to M and Zba already: in a mixed pipeline of HaDes-V+ and golden stages, the HaDes-V+ Decode stage would hand a golden Execute stage code 61, which it does not know; only the full HaDes-V+ pipeline executes the extension ops.
- **Assembled via a directive.** As with Zba, [test/asm/zbb.s](../test/asm/zbb.s) and [zbs.s](../test/asm/zbs.s) carry `.option arch, +zbb, +zbs`; the Makefile still gives no `-march`. The RV32-reserved words (`shamt[5] = 1`) cannot be written as mnemonics, so the tests write them with `.word`; binutils 2.39 disassembles them as if they were legal, so its output is no legality oracle for them.
- **A GCC 12.2 crash with Zbs.** With Zbs enabled, GCC 12.2 stops with an internal compiler error ("unrecognizable insn") on a conditional set or clear of bit 11, for example `e ? m | 2048u : m & ~2048u`. Two existing sources contain such code: `std/src/helperfunctions.c` (`enableDisable_externalInterrupts`) and the FreeRTOS program `brk`. `make bench-zbb` therefore builds the std objects for `rv32i`, and the campaign builds `brk` for `rv32im_zba_zbb`. Newer GCC versions were not tried.
- **Timing was not measured after this change.** The unit adds about 3 to 5 LUT levels before the ALU select on the full-cycle Execute → forwarding path and an estimated 500 to 700 LUTs (an estimate, not a measurement). The recorded worst path does not pass through Execute, but its margin is within routing noise, so the area may move it. The RTL has not been implemented since the change; see [Status and Limitations](../README.md#status-and-limitations).
- **Data-independent timing.** Every instruction of these extensions takes one cycle whatever its operands hold (the Execute unit has no state and never stalls). [test/asm/zkt.s](../test/asm/zkt.s) times blocks of identical instructions with `mcycle` for a set of operand values and requires exactly one cycle per instruction for the RV32I ALU instructions, the Zbb instructions of the Zkt list and `czero.*`, and exactly two for `mul`/`mulh`/`mulhsu`/`mulhu` (199 assertions); [test/asm/hints.s](../test/asm/hints.s) checks that the hint encodings `pause` and `ntl.*` change nothing and retire as one instruction each (57 assertions). The ISA string does not claim Zkt, Zihintpause or Zihintntl.

## Zicond — Conditional Zero

`Zicond` adds two instructions that make a value zero depending on a condition register. With an `or` they form a branch-free select, which replaces a short branch that the predictor might get wrong:

| Instruction | Opcode | funct7 | funct3 | Operation |
|---|---|---|---|---|
| `czero.eqz` | OP | `0000111` | `101` | `rd = (rs2 == 0) ? 0 : rs1` |
| `czero.nez` | OP | `0000111` | `111` | `rd = (rs2 != 0) ? 0 : rs1` |

They are part of `op::EXT` (the CZERO group, see [the design](#design-one-op-the-sub-operation-in-the-immediate)) and take one cycle; the condition is rs2, never rs1.

**How to use Zicond from C.** GCC 12.2 and binutils 2.39 cannot assemble the `czero` mnemonics and never emit them, and `-march` does not accept `_zicond`. [std/include/zicond.h](../std/include/zicond.h) emits the instructions with `.insn`, which works whatever `-march` says:

```c
#include "zicond.h"

uint32_t czero_eqz( uint32_t value, uint32_t condition );                        /* condition == 0 ? 0 : value */
uint32_t czero_nez( uint32_t value, uint32_t condition );                        /* condition != 0 ? 0 : value */
uint32_t zicond_select( uint32_t condition, uint32_t if_nonzero, uint32_t if_zero );   /* czero.eqz, czero.nez, or */
uint32_t zicond_add_if( uint32_t condition, uint32_t a, uint32_t b );            /* condition != 0 ? a + b : a */

/* for example, a clamp without a branch */
x = zicond_select( ( uint32_t ) ( lX < -1000 ), ( uint32_t ) -1000, x );
```

`std/include` is on the include path of the C tests, the benchmarks and the app SDK. The functions are `static inline`, and the `asm` statements are not `volatile`, so GCC may combine or drop them like other arithmetic. A program that must also run on a CPU without Zicond (the golden CPU, for example, where `czero` raises an illegal-instruction exception) defines `ZICOND_PORTABLE` before the include and gets the same functions in branch-free C. An app of the loader can ask at run time: `app_cpu() & HADES_APP_CPU_ZICOND` ([APPS.md](APPS.md#the-app-api)).

### Verification

The tests of [Zbb and Zbs](#verification-5) cover Zicond as well: the decoder sweep, `test_ext_execute`, `make ext-check` (including 4,096 zero conditions per form), the random programs and the interrupt sweep. [test/asm/zicond.s](../test/asm/zicond.s) (190 assertions) checks the polarity of both instructions with every single-bit condition (the value rs1 is never tested), the select idiom, `x0` as destination, value and condition, aliased registers, a zero condition forwarded, forwarding in and out as for Zbb, an interrupt at every position of a chain, and the illegal neighbours. `zbb_diff` and phase 8 of `zbb_arr` in `make bench-zbb` use `zicond.h`, and the `rv32i` build of `zbb_arr` (with `ZICOND_PORTABLE`) must print the same values.
