# Formal verification of the hardware performance counters

This directory holds the formal proofs of the hardware performance counters: the counter unit
(`rtl/hpm_events.sv` and `rtl/hpm.sv`), the instruction decoder's one new legal CSR address
(0x320, `mcountinhibit`), and the Writeback stage, whose trap and interrupt behaviour must stay as
it was at the base commit `c5fe2e4`. Nothing here is part of `make formal`, whose inputs and record
are unchanged.

```sh
make formal-hpm          # every proof, cover and negative control; output in $(BUILD_DIR)/formal-hpm
```

The run ends with one line, `FORMAL HPM RESULT: PASS` or `FORMAL HPM RESULT: FAIL (...)`, and
`make` exits with status 0 only for `PASS`. It needs the tools of `make formal` (SymbiYosys, Yosys,
sv2v, bitwuzla, Yices, z3; see [Tools](../README.md#tools)), found on `PATH` or through
`HADES_FORMAL_ENV`. `make formal`, `make formal-full`, `make formal-ext` and `make formal-cache`
are separate and unchanged.

Contents:

1. [What is proven](#1-what-is-proven)
2. [The model](#2-the-model)
3. [Environment assumptions](#3-environment-assumptions)
4. [Method and the ladder](#4-method-and-the-ladder)
5. [Negative controls](#5-negative-controls)
6. [Results](#6-results)
7. [Running the proofs](#7-running-the-proofs)
8. [Files](#8-files)

---------------------------------------------------------------------------------------------

## 1. What is proven

Every proof below is unbounded (k-induction), unless the summary of a run says otherwise
(section 4).

### The counter unit

`rtl/hpm_events.sv` and `rtl/hpm.sv` together, with every input free in every cycle (section 3).
Notation: counter n = 3 + k, k = 0 .. N - 1, of W bits; `cnt'` is its value one cycle later; a
write is the unit's write strobe with the counter's address (low half 0xB00 + n, high half
0xB80 + n, selector 0x320 + n, `mcountinhibit` 0x320); `step` is the event of the selected code,
when the counter is not inhibited.

| Name | Property |
|---|---|
| `increment` | No write and no reset: `cnt' = cnt` or `cnt + 1` (mod 2^W), and `cnt' = cnt` when the counter is inhibited or its selector is 0. |
| `write_rule` | A low write: `cnt'[31:0]` is the written value and the high half is that of `cnt + step`. A high write: `cnt'[W-1:32]` is the written value's low W - 32 bits and the low half is that of `cnt + step`. With W = 32 a high write changes nothing. |
| `event_timing` | No write and no reset: `cnt' = cnt + step`, where the event of each code is its condition written again in the properties from the event tables: class A (codes 1-20) in the same cycle, class B1 (47-49, 128-159, 160-161) one cycle later, class B2 (21-26, 32-46) two cycles later; 0 in a reset cycle; and a reset drops the events still on their way. |
| `selector_warl` | Every selector holds 0 or a code this build has (an invariant: 1-26 and 32-49 always, 128 + k when bit k of the present mask is set, 160 and 161 with bits 0 and 1); after a write it holds the written value if bits 31:8 are 0 and bits 7:0 are such a code, else 0. The selectors of counters 11-13 read 18, 19 and 20. |
| `inhibit` | `mcountinhibit` has only the implemented bits (CY, IR, 3 .. 2 + N, 10-13) and TM is 0 (an invariant); after a write it is the written value masked to those bits; the unit's `inh_cy`, `inh_ir` and `inh_bp` are its bits 0, 2 and 13:10. |
| `isolation` | A selector changes only through its own write, `mcountinhibit` only through its write, and a counter that is not written and has no event keeps its value. |
| `read_value` | For every address, the read value is the specified one: `mcountinhibit`, the selector `{24'b0, code}`, the counter's low half, its high half zero-extended (0 with W = 32), 18/19/20 at 0x32B-0x32D, and 0 at every other address, including the selectors and counters above 2 + N. Not checked at the addresses whose value Writeback itself answers (0x300, 0x304, 0x305, 0x340-0x342, 0x344, 0xB00, 0xB02, 0xB80, 0xB82, 0xC00-0xC02, 0xC80-0xC82, 0x32A, 0xB0A-0xB0D), where the unit's value is never used. |
| `reset_state` | In the cycle after a reset cycle every counter, selector and `mcountinhibit` is 0. |

Each property is proved in five configurations (`HADES_HPM_COUNTERS` N and `HADES_HPM_WIDTH` W):
`n7w48` (the default build), `n7w32`, `n7w64`, `n1w48` and `n0w48`.

### The decoder

Combinational: the instruction word is free, so each proof covers all 2^32 words.

| Name | Property |
|---|---|
| `decoder_miter` | `rtl/instruction_decoder.sv` equals the base commit's decoder on every word and every output field (op, rd, rs1, rs2, csr, immediate), except on the CSR words (opcode 1110011, funct3 1, 2, 3, 5, 6 or 7) at address 0x320: there the base decoder gives `ILLEGAL` and the new one the CSR operation of funct3, with every other field equal. |
| `decoder_legal` | On every CSR word, the op is not `ILLEGAL` exactly when the address is in the legal set of the trap-sweep ISS (`CSR_VALID` of `test/trapsweep/iss.py`) and the word is not a write form at a read-only address (bits 11:10 = 11; CSRRW and CSRRWI always write, the other forms when the rs1 or uimm field is not 0); and then the op is the CSR operation of funct3. |

### The Writeback miter

The Writeback stage of the tree (`rtl/writeback_stage.sv`, with the counter unit it
instantiates) against the base commit's, with the same inputs; the inputs that only the new
stage has are free.

| Name | Property |
|---|---|
| `writeback_miter` | In every cycle the two stages have equal outputs (`status_backwards_out`, `jump_address_backwards_out`, `forwarding_out`, `bp_control_out`) and equal state (`mstatus` MIE and MPIE, `mtvec`, `mie` MEIE and MTIE, the registered `mip` bits, `mepc`, `mcause`, `mscratch`, `mcycle`, `minstret`, `bp_control`, `int_jump_reg`, `imm_jump_reg`, `int_next_pc_reg`), and the counter unit's inhibit outputs are 0. The equalities are the induction's invariants. This covers the interrupt-enable values that the interrupt logic now computes from the registers instead of from the CSR read value, and the exact predictor counters, whose changes must leave the trap and interrupt behaviour as it was. |
| `writeback_events` | With the counter unit only. In every cycle without reset, the class-A events that Writeback gives the unit (its port `ev_a`, bit c = code c, codes 2-20) and the six trap events (`trap_raw`, bit k = code 21 + k) are the conditions of the event tables, computed from the base stage's own signals: retirement (`VALID` and not replayed), the op classes, `rd_data_in[0]` for a taken branch, the replay of the stale instruction, the predictor record of Execute delayed by two cycles, the trap decision (an exception taken, an interrupt taken, its cause). This task also asserts the miter's equalities, which its induction needs. |

The intended differences are excluded by assumption (section 3): the new counter CSRs, the
predictor counters 10-13 (they now count retired branches), and CSRRS/CSRRC writes to `mcycle`
and `minstret` (all six write forms now write them).

### Covers

Each cover must be reached: in the counter unit (default configuration), a class-A, a class-B1, a
class-B2, a trap and a combined event counted, a carry from the low into the high half, a wrap at
2^W, a low and a high write in a cycle with the counter's event, a legal and an illegal selector
write, and an inhibited counter whose event happens; in the decoder, `csrrw` and `csrrci` at 0x320,
an illegal 0x321, a write form at a legal read-only address and a read of one; in the Writeback
miter, an exception, a sequential interrupt, a stale instruction that retires and one that is
replayed, a held interrupt jump, an immediate interrupt after `mret` and after CSR writes to
`mstatus` and `mie`, a write to `mcycle` and an access to 0x32A.

---------------------------------------------------------------------------------------------

## 2. The model

**Sources.** `scripts/model.py` copies the sources of the tree under proof (the package files in
the order of the `defines/` lines of `sim/files.txt`, and the modules each model needs) to the work
directory and converts them with sv2v, with `SYNTHESIS` and `HADES_FORMAL` defined. The repository
is never written. Yosys reads the converted model with `-formal`, runs `proc -norom` (a `case`
turned into a ROM would have free contents in the induction step), and flattens it.

**Harnesses** (`harness/`):

| Harness | Modules | Used for |
|---|---|---|
| `unit_top.sv` with `unit_bind.svh` | `hpm_events` and `hpm` | the counter-unit properties and covers |
| `decoder_top.sv` | `instruction_decoder` and `instruction_decoder_base` | the decoder properties and covers |
| `writeback_top` (written by `scripts/model.py`) with `wb_fields.sv` | `writeback_stage` and `writeback_stage_base` | the Writeback miter, its event check and covers |

**What the proofs rely on by name.** These are the only places to change when the RTL names
something differently:

- `harness/unit_bind.svh` names the ports of `hpm_events` and `hpm` (the counter unit's ports are
  `clk`, `rst`, `ev_a` (codes 1-20), `trap_raw` (codes 21-26), `late` (a struct, `hpm_pkg::late_t`,
  that carries the class-B1 and the first stage of the class-B2 events, every field indexed by
  event code), `csr_addr`, `csr_we`, `csr_wdata`, `hpm_ext_present`, `rdata`, `inh_cy`, `inh_ir`,
  `inh_bp`). The counter unit's instance must be `u_hpm`.
- `props/observe_hpm.svh`, inserted as one include line before the final `endmodule` of the copy of
  `rtl/hpm.sv`, exports the unit's state as `f_obs_cnt`, `f_obs_sel` and `f_obs_inh`. It reads the
  parameters `N` and `W` and the registers `cnt` and `sel` (arrays indexed 3 .. 9, of which counters
  3 .. 2 + N exist) and `inhibit`.
- The package `defines/hpm.sv` must take `HADES_HPM_COUNTERS` and `HADES_HPM_WIDTH` into
  `hpm_pkg::COUNTERS` and `hpm_pkg::WIDTH`; `scripts/model.py` checks that each configuration was built
  with its values.
- The Writeback miter reads the registers listed in section 1 by their names in both stages (the
  model is not built if one is missing or has another width), the base stage's own signals
  (`is_valid`, `stale_replay`, `is_exception`, `is_interrupt_seq`, `is_interrupt_imm`,
  `ext_int_pending`, `int_hold`, `int_jump_fire`), and, when the new stage instantiates the counter
  unit as `i_hpm`, its ports `ev_a` (which must hold bits 2-20), `trap_raw` (6 bits, `[5:0]` or `[26:21]`) and the
  inhibit outputs. Without an `i_hpm` the miter runs without the inhibit invariant and
  `writeback_events` is not run.
- The base copies `base/writeback_stage_base.sv` and `base/instruction_decoder_base.sv` are the base
  commit's files with only the module name changed; `run.sh` checks them against the commit
  (`--base`) when the repository has it.
- The decoder's legal set is read from `CSR_VALID` of `test/trapsweep/iss.py` without running the
  ISS: the assignment may use only literals, `set`, `list`, `range` and `+`.

**The Writeback top module.** `scripts/model.py` reads both stages' port lists from the sv2v output
with Yosys and writes `writeback_top`: one free input per port of the base stage (shared by both
stages), one free input per input that only the new stage has, and both stages' outputs. An
output of the base stage that the new stage lacks, or a shared port of another width, stops the
model generation.

---------------------------------------------------------------------------------------------

## 3. Environment assumptions

- **Reset.** The first cycle is a reset; in every later cycle a reset is free.
- **Counter unit.** Every input is free in every cycle: the backward status of Decode, Execute,
  Memory and Writeback (the unused encoding 3 is read as `READY`), the fetch port's `ack` and `err`,
  the instructions in Execute and Memory, Decode's load-use hazard, the data port's `cyc`, pending
  flag and address, the memory-system event vector, the class-A and trap events, and the CSR access
  (address, write strobe, write value). Class-A code 1 (`CYCLE`) is 1 in every cycle, as Writeback
  drives it. The present mask is one free constant for the whole run.
- **Decoder.** None.
- **Writeback miter.** Every input is free in every cycle. Assumed, as the intended differences:
  the instruction in Writeback, when its status is `VALID`, is not a CSR operation on 0x320,
  0x323-0x329, 0x32B-0x32D, 0xB03-0xB0D or 0xB83-0xB89, and not CSRRS, CSRRC, CSRRSI or CSRRCI with
  a non-zero rs1 field on 0xB00, 0xB02, 0xB80 or 0xB82. In the first cycle the two states are equal
  (`mcycle` is not reset). With `--assume-x0-source` also: a CSRRS, CSRRC, CSRRSI or CSRRCI whose
  rs1 field is 0 has source operand 0, as in the CPU (x0 reads 0; the uimm forms take the field).
  Without it, the miter also covers inputs the pipeline never produces.

---------------------------------------------------------------------------------------------

## 4. Method and the ladder

Every property is a proof by k-induction (SBY `mode prove`): depth 5 for the counter unit, 4 for
the Writeback miter, 1 for the combinational decoder. The counter unit's and the miter's tasks
also assert the invariants their induction needs (the selector and inhibit invariants; the
miter's equalities).

If a proof neither passes nor fails, `scripts/check.sh` tries, in this order, and records the
first step that succeeds:

1. the proof by k-induction with `smtbmc` and bitwuzla, then Yices, then z3;
2. a bounded check from reset to depth 20 (`--bmc-depth`) with each engine in turn: status
   `BOUNDED`, which counts as passed only for the checks named in `--accept-bounded`.

Each step has a time limit per check (`--step-limit`, default 3600 s), a third of it for each
engine. A counterexample ends the ladder with `FAIL`; its trace is in the run directory.

---------------------------------------------------------------------------------------------

## 5. Negative controls

Each property must fail on each of its negative controls, source changes listed in `mutants.txt`.
`run.sh` runs the property on the mutated model with the engine that proved it, in the first
configuration of `--configs`, as a bounded check from reset to the depth of `--bmc-depth`: a
control counts only with a concrete counterexample (`FAIL`).

| Property | Negative controls |
|---|---|
| `increment` | `increment-by-two`, `inhibit-ignored-hpm5` |
| `write_rule` | `increment-beats-write` |
| `event_timing` | `b2-event-one-cycle-early` |
| `selector_warl` | `selector-not-legalised` |
| `inhibit` | `tm-writable` |
| `isolation` | `selector-write-aliased` |
| `read_value` | `selector-read-off-by-one` |
| `reset_state` | `reset-keeps-selector` |
| `decoder_miter`, `decoder_legal` | `decoder-accepts-0x321`, `decoder-rejects-0x320` |
| `writeback_miter` | `writeback-ext-cause`, `mstatus-enable-csrrc-or` |
| `writeback_events` | `int-timer-ext-swapped` |

A row of `mutants.txt` either gives the file, an exact text that must occur exactly once in it and
its replacement (several rows with one name make one mutant), or leaves the text empty: then the
change comes from the repository's counter mutation campaign, `test/hpm/mutants.py apply --src
<tree> <name> <dir>`, or from `--mutant-cmd`. A control that passes, or whose change cannot be
applied, fails the run.

---------------------------------------------------------------------------------------------

## 6. Results

The record of a run is `results/formal-hpm/<date>_<commit>/`. `run.sh` writes the outcome of every
check in `SUMMARY.txt`: the proofs with their engine, mode and depth, the covers, the negative
controls and the verdict.

---------------------------------------------------------------------------------------------

## 7. Running the proofs

```sh
export HADES_FORMAL_ENV=~/formal-tools/env.sh     # if the tools are not on PATH
make formal-hpm                                   # everything
make formal-hpm FORMAL_PAR=2                      # fewer parallel solver processes (default 4)
make formal-hpm FORMAL_HPM_ARGS='--only writeback_miter,writeback_events --no-controls'
bash formal/hpm/run.sh --out /tmp/fh --par 4      # the same without make
```

Options (`bash formal/hpm/run.sh --help`): `--only`, `--configs`, `--step-limit`, `--bmc-depth`,
`--accept-bounded`, `--assume-x0-source`, `--no-controls`, `--mutants`, `--mutant-cmd`, `--src`
(prove the RTL of another tree), `--base` (the commit of the base copies). `--only` takes property
names and `covers`; a run with `--only` checks only those (and their negative controls), so its
verdict covers only them. A run without negative controls never ends with `PASS`.

**Output** (`<out>` = `$(BUILD_DIR)/formal-hpm`):

| Path | Contents |
|---|---|
| `<out>/run.log` | Everything printed |
| `<out>/SUMMARY.txt` | The proofs, the table of checks and the verdict |
| `<out>/work/runs/checks.txt` | One line per check: status, class, wall time |
| `<out>/work/runs/proofs.txt` | One line per proof: status, engine, mode, depth, run directory |
| `<out>/work/runs/controls.txt` | One line per negative control |
| `<out>/work/runs/<sby>__<model>__..._<task>/` | SBY run directories, with the counterexample trace when a check fails |
| `<out>/work/gen/` | The models: the sv2v outputs (`*_sv2v.v`) and the models with the include lines (`*.v`) |

**Classes** in the summary: `REQ` must pass, `CTL` (a negative control) must fail, `AUX` is
reported only.

---------------------------------------------------------------------------------------------

## 8. Files

| Path | Contents |
|---|---|
| `run.sh` | Driver: base copies, models, proofs, covers, controls, summary and verdict |
| `scripts/model.py` | Copies the sources, applies a mutant, inserts the observer and the property include lines, runs sv2v, writes the Writeback top module, reads the ISS's legal set, checks the base copies |
| `scripts/check.sh` | One check with its ladder, or one negative control |
| `harness/unit_top.sv`, `unit_bind.svh` | The counter-unit harness with its event model, and the instances of the two modules |
| `harness/decoder_top.sv` | The decoder harness |
| `harness/wb_fields.sv` | The fields and classes of the instruction in Writeback, for the miter's properties |
| `props/unit_props.vh`, `decoder_props.vh`, `writeback_props.vh` | The properties and covers |
| `props/observe_hpm.svh` | The observer inserted into the copy of `rtl/hpm.sv` |
| `sby/unit.sby`, `decoder.sby`, `writeback.sby` | The SBY tasks |
| `base/writeback_stage_base.sv`, `base/instruction_decoder_base.sv` | The base commit's files with only the module name changed |
| `mutants.txt` | The negative controls |
