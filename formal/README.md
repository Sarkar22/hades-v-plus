# Formal verification of the M and EXT units

This directory holds machine-checked proofs about two units of `rtl/execute_stage.sv`:

- **The M unit.** The multiply/divide unit computes the RISC-V M-extension results. The
  proof covers MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM and REMU, including division by
  zero and the `-2^31 / -1` overflow. It holds for **all 2^64 operand pairs**, in
  **every reachable state** (unbounded, by k-induction), under any interleaving of Memory
  `STALL`/`JUMP` and of resets. No bug was found in the M unit.
- **The EXT unit (Zbb, Zbs, Zicond, Zbkb, Zbkx, Zknh).** For each of the 45
  instructions, the result that Execute forwards in the same cycle and registers for
  Memory in the next is the result defined by the ratified specifications. This holds
  for **all operand values**, every rotate amount, bit index and permutation index, in
  every reachable state. An EXT instruction also never
  makes Execute stall or jump. The proof uses the same environment as the M proof and
  assumes nothing of it. No bug was found in the EXT unit.

Both proofs were last run on 2026-10-02, on `rtl/execute_stage.sv` with SHA-256
`52201629…2bfa5d`, the file with the cryptography half of the EXT unit (Zbkb, Zbkx,
Zknh) ([record](../results/formal/2026-10-02_bd800d8/RECORD.md)).

```sh
make formal          # both units: every proof obligation + lemma checks + covers + controls + spec/sv2v checks (about 2.5 minutes)
make formal-full     # also H6 by bitwuzla, second solvers and both mutation campaigns (about 45 minutes; longer on a loaded machine)
make formal-ext      # the EXT unit alone (under a minute)
```

`make formal` and `make formal-full` write only to `$(BUILD_DIR)/formal/`,
`make formal-ext` only to `$(BUILD_DIR)/formal-ext/`. Each finishes with one line,
`FORMAL RESULT: PASS` or `FORMAL RESULT: FAIL ...`. `make` exits with status 0 only
for `PASS`. The tools are listed in [Tools](#tools).

Contents:

1. [What is proven](#1-what-is-proven): [the M unit](#the-m-unit), [the EXT unit](#the-ext-unit-zbb-zbs-zicond-zbkb-zbkx-zknh)
2. [Environment assumptions](#2-environment-assumptions)
3. [How the proof works](#3-how-the-proof-works) ([the EXT proof](#the-ext-proof))
4. [Results and runtimes](#4-results-and-runtimes)
5. [What is not proven](#5-what-is-not-proven)
6. [Tools](#tools)
7. [Running the proofs](#7-running-the-proofs)
8. [Files](#8-files)
9. [History and independent audits](#9-history-and-independent-audits)

---------------------------------------------------------------------------------------

## 1. What is proven

### The M unit

**Target.** The proof reads the real `rtl/execute_stage.sv` of this checkout. No hand
restatement of the design is used. `scripts/gen.sh` translates the file and the
`defines/` packages with sv2v, because Yosys cannot parse the original. It then inserts
exactly one line, `` `include "div_props.vh" ``, before `endmodule`, and it checks that
this is the only difference. `run.sh` prints the SHA-256 of the file it proved. The
model is regenerated on every run, so the proof always refers to the RTL currently in
the tree.

**Model.** The model is the `execute_stage` module alone. Every input is free in every
cycle (`harness/top.v`), apart from the assumptions E0-E2 in section 2.

**Properties.** The following hold in every reachable state, for all operands.
`spec(op, rs1, rs2)` is the RV32M result as written in `props/spec.vh`, taken from the
ISA manual.

| Group | Property |
|---|---|
| **F1** | A VALID M instruction leaves Execute when Memory is `READY`, the unit is not self-stalling, and there is no reset. In that cycle, the value Execute registers is `spec(op, rs1, rs2)`. |
| **F2** | Whenever the forwarding bus marks an M result as valid, its data is `spec(op, rs1, rs2)`. There is no early or stale forwarding. |
| **F3** | In the cycle after retirement, `rd_data_reg_out == spec` of the retired operands, and `status_forwards_out == VALID`. |
| **A1** | Port-level result, one proof per opcode, gated only by the opcode *field* and the ports. If a VALID instruction with an M opcode leaves Execute (Memory `READY`, Execute not answering `STALL`, no reset), then in the next cycle `rd_data_reg_out == spec` and `status_forwards_out == VALID`. |
| **A3a** | Port-level hand-off, one proof per opcode. Execute's output registers are loaded from an M instruction in a Memory-`READY` cycle, and the result is presented as VALID, only in the cycle that instruction leaves Execute. |
| **A3** (= A1 ∧ A3a) | Every VALID hand-off of an M instruction made in a Memory-`READY` cycle carries the ISA result. |
| **CTRL** | FSM consistency: the unused state encoding is never reached. A busy FSM always belongs to the VALID, non-early-out M instruction currently in Execute. The latched divisor and signs equal that instruction's. The restoring-division shape invariants hold (partial remainder < divisor, remainder ≤ consumed prefix, prefix/quotient bit relations, `!div_shifted[32]`). The unit never stalls anything but a VALID M instruction. **Bounded stall:** the unit never holds the pipeline for more than 33 consecutive cycles, so it cannot hang. |

F1-F3 are checked for DIV/DIVU/REM/REMU in one proof and for each multiply opcode
separately. A1 and A3a are checked per opcode, so the eight runs together cover every
M opcode.

**Why A1/A3a exist next to F1-F3.** F1-F3 are gated by the RTL's own decode (`is_m_div`,
`is_m_mul`, `m_active`, `m_stall`). An M instruction that the RTL misclassifies is
therefore never compared, and nothing in F1-F3 constrains what Execute hands to Memory
while it stalls. An independent audit demonstrated this with real-bug mutants that pass
F1-F3. A1 and A3a close the gap: the mutants `rem_not_decoded`, `mulh_not_decoded` and
`stall_valid_to_mem` are rejected *only* by A1/A3a (section 4).

### The EXT unit (Zbb, Zbs, Zicond, Zbkb, Zbkx, Zknh)

**Target and model.** The same as for the M unit: the sv2v model of the real
`rtl/execute_stage.sv` with the one inserted line, every input free apart from E0-E2
(section 2). The top is `harness/top_ext.v`. None of the M unit's proven groups and none
of its lemmas is assumed, so the EXT proof does not depend on the M proof.

**Which instruction.** Execute sees an EXT instruction as the opcode `op::EXT` (entry 61
of `op::t`) and a payload in the immediate field, `op::ext_payload_t`: the sub-operation
`sel` in bits 11:6, `use_imm` in bit 5, and `shamt` in bits 4:0 (the instruction's
`inst[24:20]` for the five immediate forms, otherwise 0), with bits 31:12 zero. Bit 11,
the top bit of `sel`, selects the cryptography half of the unit: it is 0 for the 28
Zbb, Zbs and Zicond instructions and 1 for the 17 Zbkb, Zbkx and Zknh instructions. For
each instruction the harness requires exactly the payload that the decoder builds for
it; `rs1_data_in`, `rs2_data_in` and, for the immediate forms, `shamt` are free. The
map from instruction to payload is written in the harness as numbers, and
`scripts/ext_codes.py` checks every entry against the definitions in `defines/op.sv`.

**Specification.** `spec_ext(insn, rs1, rs2, shamt)` is `f_spec_ext` in
`props/ext_spec.vh`, written from the ratified specifications (RISC-V Bit-Manipulation
ISA-extensions 1.0.0 for Zbb and Zbs; Zicond 1.0; RISC-V Cryptography Extensions
Volume I, Scalar & Entropy Source Instructions, 1.0.1, for Zbkb, Zbkx and Zknh), not
from the RTL. It follows the specifications' Sail operations: the counts scan bit by
bit, the rotates use the two-shift formula, `orc.b` and `rev8` loop over bytes, and the
single-bit instructions build the mask `1 << (rs2 & 31)`. For the cryptography
instructions, `pack` and `packh` concatenate the two halves, `brev8`, `zip` and `unzip`
are the Sail loops over bytes and bits, `xperm4` and `xperm8` look up
`(rs1 >> (idx @ 0b00))[3..0]` and `(rs1 >> (idx @ 0b000))[7..0]` (0 for an index past
the end of `rs1`), the four `sha256` functions use a `ror32` written as two shifts, and
the six `sha512` functions are the Sail shift expressions verbatim.

**Properties.** The following hold in every reachable state (k-induction), for each of
the 45 instructions `insn` (andn, orn, xnor, clz, ctz, cpop, max, maxu, min, minu,
sext.b, sext.h, zext.h, rol, ror, rori, orc.b, rev8, bclr, bclri, bext, bexti, binv,
binvi, bset, bseti, czero.eqz, czero.nez; pack, packh, brev8, zip, unzip, xperm4,
xperm8, sha256sig0, sha256sig1, sha256sum0, sha256sum1, sha512sig0h, sha512sig0l,
sha512sig1h, sha512sig1l, sha512sum0r, sha512sum1r):

| Group | Property |
|---|---|
| **X1** | Forwarding, same cycle. While `insn` is in Execute, the forwarding bus carries `spec_ext(insn, rs1, rs2, shamt)`, its `data_valid` is set exactly when the instruction is VALID, and its address is `rd` when VALID and 0 otherwise. |
| **X2** | Result. If a VALID `insn` leaves Execute (Memory `READY`, Execute not answering `STALL`, no reset), then in the next cycle `rd_data_reg_out == spec_ext` of its operands and `status_forwards_out == VALID`. |
| **X3** | No stall, no jump. Out of reset, with Memory `READY`, an instruction with the `op::EXT` opcode and **any** immediate field makes Execute answer `READY`, neither `STALL` nor `JUMP`. |

X1 and X2 are checked in one proof per instruction (45 proofs), X3 in one. Like A1, they
look only at the module's ports and the opcode field; nothing is gated by an internal
signal of the RTL. X2 and X3 together give: every VALID EXT instruction that Memory
accepts leaves Execute in that cycle and hands Memory the specified result.

---------------------------------------------------------------------------------------

## 2. Environment assumptions

These are the only restrictions on the inputs (`props/div_props.vh` section 0). Each is
justified by the RTL text of this tree; none is proven in a multi-module model.

| Id | Assumption | Justification in the RTL |
|---|---|---|
| E0 | The first cycle of a base-case trace is a reset. `rst` is otherwise free, so a reset may arrive in any cycle. | Standard. |
| E1 | `status_backwards_in != 2'd3`: Memory only drives `READY`, `STALL` or `JUMP`. | `rtl/memory_stage.sv` lines 334-349 drive `STALL`, `JUMP`, or Writeback's status passed through. `rtl/writeback_stage.sv` lines 451-486 drive only `READY` or `JUMP`. `backwards_t` has three values (`defines/pipeline_status.sv`). |
| E2 | If Execute drove `STALL` backwards in cycle *t*, and there was no reset, then every input coming from Decode is unchanged in *t+1*. These inputs are `instruction_in`, `rs1/rs2_data_in`, `program_counter_in`, `status_forwards_in` and `bp_prediction_in`. | `rtl/decode_stage.sv` lines 259-261 hold all output registers on `STALL`, second only to `rst`. Line 237 makes `status_forwards_out` that held register. `rtl/cpu.sv` lines 122-164 wire those registers directly into Execute. |

**What is left free.** Memory's `STALL`/`JUMP`/`READY` in every cycle, the jump address,
resets after the first cycle, and all Decode outputs whenever Execute does not stall.
The FSM's starting state in an induction trace is also free.

---------------------------------------------------------------------------------------

## 3. How the proof works

### Chain of property groups

Every group is proven by k-induction (SBY `mode prove`) on the real RTL. A group that
another group assumes is proven in the same `run.sh` invocation. The dependency graph
is acyclic, so assuming it is sound. The overall verdict is `PASS` only if every group
passes in that run.

```
            CTRL  (k=2, no lemmas)
           /    \
       DIVF      MULREG         DIVF   : assumes CTRL;            lemmas H6 H7 H8 H9  (k=1 and k=2)
        |          |            MULREG : assumes CTRL;            lemma  H1
   FINAL(div)  FINAL(mul)       FINAL  : assumes CTRL+DIVF / CTRL+MULREG; lemmas H5a H5b
          \      /
         A1, A3a                A1/A3a : assume CTRL, DIVF, MULREG; lemmas H1 H5a H5b
```

**DIVF** is the strengthening invariant that makes the induction close. It is stated in
*division form*, with no multiplication:

```
divider busy  ->  f_X == f_T / m_divisor  &&  m_rem == f_T % m_divisor
```

Here `f_T` is a ghost register holding the dividend bits consumed so far, and `f_X` the
quotient bits produced so far. At `M_READY`, CTRL gives `f_T == |a|` and
`f_X == m_quo`, so the divider holds `|a| / |b|` and `|a| % |b|`. FINAL then only has to
check the sign fix-up and the special cases.

### Lemmas ("hints")

A hint is a formula that is true for all values of its arguments. Assuming it removes no
behaviour of the design; it hands the solver a fact it cannot derive quickly. The text
of each hint exists once, in `props/hints.vh`. The proof includes that file with
`` `define HINT(p) assume(p) ``. `lemmas/hint_validity.v` includes the *same* file
with `` `define HINT(p) assert(p) `` and every argument free, where a depth-1 BMC PASS
means the formula is valid.

| Hint | Statement | Validity check in `run.sh` |
|---|---|---|
| H6 | One step of long division, for 32-bit T, B and 1-bit a, with B ≠ 0 and T < 2^31: `(2T+a)/B == 2(T/B) + [2(T%B)+a ≥ B]` and `(2T+a)%B == 2(T%B)+a − (that bit ? B : 0)` | z3, by an exhaustive 33-way case split on the bit length of B (default mode). Bitwuzla, monolithically through SBY, is run too (full mode). |
| H7, H8 | Congruence of `/` and `%` (step case, hold case) | H7: bitwuzla and z3. H8: z3 only (bitwuzla takes more than 300 s). |
| H9 | `0/B == 0` and `0%B == 0` for B ≠ 0 | bitwuzla and z3 |
| H5a, H5b | Congruence between the divider's prefix/divisor and the spec's operands: magnitudes for DIV/REM (H5a), raw operands for DIVU/REMU (H5b) | bitwuzla and z3 |
| H1 | `mul_result` is equal across a clock edge when `instruction_in`, `rs1` and `rs2` are equal | Structural: `lemmas/mul_result_cone.ys` asserts that the fan-in cone of `mul_result` contains no state element and no input other than those three. Negative control: the same check on `m_result` must fail. |

The cross-cycle hints are instantiated on `f_q_*` registers that latch unconditionally
every cycle. In the first state of an induction trace those are free ghosts, so there
the hints only relate free ghost values.

**The H6 case split** (`lemmas/h6_split/`) builds the Yosys SMT2 model of the exact hint
text with the same passes SBY uses. `flatten.py` replaces each free-input function of the
single state by a constant; this preserves the meaning, because the query mentions one
state only. It then writes 33 queries: `B == 0`, and `2^k ≤ B < 2^(k+1)` for
k = 0..31, with k = 31 open-ended. These 33 cases cover every 32-bit value. All 33 must
be `unsat`. Two negative controls run through the same pipeline and must give `sat`
exactly where the broken hint is false:

- Quotient bit inverted: 32 of 33 cases `sat`.
- Premise `T < 2^31` dropped: 31 of 33 cases `sat`.

### Supporting checks (all run by `run.sh`)

- **Spec vs an independent model.** `spec_check/` simulates both spec formulations with
  Verilator and compares them with a Python RV32M model. That model derives truncating
  division from floor division, without using magnitudes. It runs on 2,592 corner
  vectors plus 1,000,000 random vectors and must give 0 mismatches.
- **Spec self-consistency.** `sby/spec_equiv.sby` proves `f_spec_m == f_spec_ref` for all
  inputs, per opcode. `f_spec_ref` uses Verilog's signed `/` and `%`. Only `f_spec_m`
  is used by the proofs.
- **Non-vacuity.** `sby/cover.sby` must reach every cover:
  - C1-C6 of `div_props.vh`, under the bare environment and again with every group and
    every hint assumed, at depth 45. They include a real DIV and a real REMU retiring
    at step 34, a finished divide parked in READY by a Memory stall, a JUMP flushing a
    divide mid-way, a MULHSU retiring, and a DIVU with a divisor ≥ 2^31 and a
    remainder ≥ 2^31.
  - Every one of the 8 M opcodes leaving Execute with a non-special operand pair, at
    depth 40.
- **sv2v fidelity.** The proofs are about the sv2v translation. `scripts/sv2v_fidelity.sh`
  runs the repository's benches `test_m_execute`, `test_execute_compare` (against the
  golden execute stage), `test_execute_bpred_nextpc` and `test_ext_execute` (the EXT
  unit) twice: once on the SystemVerilog, once with `rtl/execute_stage.sv` replaced by
  the sv2v output. The simulation output must be identical line for line. In
  `--mode ext` only `test_ext_execute` runs.
- **Multiplier formulation** (`sby/mul_formulation.sby`). This is the earlier experiment,
  kept for reference. `mul/mul_formulation.sv` is a *hand copy* of the RTL's 33×33
  multiply, checked against riscv-formal-style expressions. A negative control with the
  wrong MULHSU signedness must fail. The real-RTL multiplier proof is FINAL(mul),
  MULREG and A1/A3a.
- **Mutation campaign** (full mode). Each of the 19 mutants in `mutants/mutants.txt` is one
  textual change of the sv2v model. Each is run against 32 proofs:
  - CTRL, DIVF (k=1), FINAL(div), MULREG;
  - the 12 FINAL(mul) tasks;
  - the 16 A1/A3a tasks.

  A mutant is *rejected* if any of them does not pass. Every mutant except `diff32` must
  be rejected. `diff32` drops bit 32 of the 33-bit shifted remainder, and it is an
  *equivalent* mutant: CTRL proves `m_rem ≤ f_T < 2^n ≤ 2^31` before every step, hence
  `!div_shifted[32]` in every reachable RUN state (a CTRL property).

  This is an observation, not a bug. The RTL comment's bound ("as large as
  2*divisor-1") is loose; the 33-bit subtract is still what produces the borrow.

### The EXT proof

The EXT unit is combinational: each result is one step from `rs1`, `rs2` and the
payload, and the unit has no state. X1-X3 are therefore proven directly, by
k-induction at depth 3 with yices (`sby/ext.sby`), with no invariant and no lemma. The
depth is 3, not 2, because cycle 0 is a reset: only a base case of three cycles reaches
a cycle in which X2 applies, so that a fault confined to the registered result is
rejected by a counterexample (`FAIL`); at depth 2 the base case cannot see it, and only
the induction step rejects it, as `UNKNOWN`. The checks around them (all run by `run.sh`
in every mode):

- **Specification vs an independent model.** `spec_check/run_ext.sh` simulates
  `f_spec_ext` with Verilator and compares it with a Python model of the 45
  instructions (`spec_check/check_ext_spec.py`), written differently again: string
  slicing for the rotates, `bit_length` for the counts, byte conversions for `rev8`,
  `brev8` and `xperm8`, nibble lists for `xperm4`, bit strings for `zip` and `unzip`,
  the SHA-256 functions of FIPS 180-4, and the SHA-512 halves taken from the 64-bit
  SHA-512 functions of FIPS 180-4 through the identities in the specification's notes
  (for example σ0(x) = {sha512sig0h(hi, lo), sha512sig0l(lo, hi)}), not from the
  instructions' shift expressions. The model must also reproduce 21 known answers and
  the identities `brev8(brev8(x)) = x` and `unzip(zip(x)) = x`. The check runs 37 × 37
  corner pairs and every shift amount and bit index for each instruction, every index
  value in every element of `xperm4` and `xperm8` (157,509 vectors in all), plus
  1,000,000 random vectors, and must give 0 mismatches.
- **Payload map.** `scripts/ext_codes.py` checks that `op::EXT` is entry 61 of `op::t`,
  that `op::ext_payload_t` has the layout the harness assumes, that each of the 45
  entries of the harness's map has the `sel` of the `op::ext_t` constant it names and
  `use_imm` set exactly for rori, bclri, bexti, binvi and bseti, that every constant is
  used, and that the harness and `ext_spec.vh` number the instructions alike.
- **Non-vacuity.** `cover_bw` must reach, for each of the 45 instructions, a cycle after
  a reset in which it leaves Execute VALID with non-zero operands (depth 4).
- **Negative controls.** Each of the 37 mutants in `mutants/ext_mutants.txt` is one
  textual change of the sv2v model, as for the M unit. The first 17 concern the Zbb, Zbs
  and Zicond half (Part 2c, `alu_sel` 1110). Thirteen of them break a result or the
  stall: andn computing and, clz/ctz of 0 giving 31, ctz counting leading zeros, a wrong
  cpop adder, min/max with the signedness swapped, sext.h zero-extending, rol rotating
  right, orc.b using AND in one byte, rev8 leaving the middle bytes in place, bext
  returning the neighbouring bit, the immediate single-bit forms reading `rs2`, czero
  testing `rs1`, and an EXT instruction stalling Execute for one operand value. Four
  leave the computed result intact and break only how it leaves Execute: the result
  registered for Memory with one bit inverted, an EXT instruction handed to Memory as
  `BUBBLE` (both X2 only), the forwarded result marked not valid, and the forwarding
  address taken from the `rs1` field (both X1). The other 20 concern the cryptography
  half (Part 2d, `alu_sel` 1111), at least one per instruction: `pack` with its halves
  swapped, `packh` taking `rs2[15:8]`, `brev8` reversing the bytes, `zip` computing
  `unzip`, `unzip` with its halves swapped, `xperm4` wrapping an index of 8 or more
  instead of giving 0, `xperm8`'s range test ignoring index bit 7, `sha256sig0` rotating
  by 3 instead of shifting, `sha256sig1` shifting by 11, `sha256sum0` rotating left,
  `sha256sum1` rotating by 24, the `rs2 << 25` term moved from `sha512sig0l` to
  `sha512sig0h`, `sha512sig0l` without that term, `sha512sig1h` with the `rs2 << 26`
  term of `sha512sig1l`, both `sha512sig1` halves shifting `rs1` by 18, `sha512sum0r`
  reading `rs1` for `rs2` in one term, `sha512sum1r` shifting by 13 for 14, the
  cryptography half never selected (`alu_sel` 1110 for every EXT instruction), a
  cryptography instruction stalling Execute when `rs1[31:24]` is `0xA5` (X3), and the
  cryptography result registered for Memory with bit 31 inverted (X2 only). In every
  mode, each mutant is run against the property of an instruction it breaks (X3 for the
  stalls), which must `FAIL` with a counterexample.
- **Mutation campaign** (full mode). Each of the 37 mutants is also run against all 46
  required property tasks. Every mutant must be rejected; the summary names the tasks
  that fail, which shows how precisely the properties locate each fault.
- **sv2v fidelity** includes the bench `test_ext_execute` (see above).

---------------------------------------------------------------------------------------

## 4. Results and runtimes

**Run of record: 2026-10-02**, on `rtl/execute_stage.sv` with SHA-256
`52201629…2bfa5d`, the file with both halves of the EXT unit
([record](../results/formal/2026-10-02_bd800d8/RECORD.md)). The machine has 22 hardware threads; parallelism was `--par 4`. Wall
times are per task.

| Run | Flow | Verdict | Wall |
|---|---|---|---|
| `make formal-full` | this directory (M and EXT) | `FORMAL RESULT: PASS (mode=full)`: 123 required checks, all PASS; 41 negative controls, all FAIL as required; 65 second-solver runs; 2,310 mutant runs (608 of the M unit, 1,702 of the EXT unit) | 45 min 07 s |
| `make formal` | this directory (M and EXT) | `FORMAL RESULT: PASS (mode=default)`: 121 required checks, 41 negative controls | 2 min 22 s |
| `make formal-ext` | this directory (EXT only) | `FORMAL RESULT: PASS (mode=ext)`: 51 required checks, 37 negative controls | 57 s |

The M unit's checks gave the verdicts that the tables below record for the earlier runs,
including the same four second-solver time-outs, and every M mutant the verdict of the
mutation table. The full run is longer than the one of c1a7c85 (26 min 18 s) because of
the EXT mutation campaign (1,702 runs instead of 493) and the monolithic H6 by bitwuzla
(`hint_validity_h6_bwn` 1,699 s, `h6_bw` 826 s), which ran alongside.

**Run of record of the first EXT unit: 2026-10-02**, on the file of commit c1a7c85
(`c36613c8…3ae969`), with the 28 Zbb, Zbs and Zicond instructions
([record](../results/formal/2026-10-02_c1a7c85/RECORD.md)): `make formal-full` 106
required checks, 21 negative controls, 48 second-solver runs, 1,101 mutant runs, 26 min
18 s; `make formal` 104 required checks, 1 min 40 s; `make formal-ext` 34 required
checks, 27 s. The same record holds the M flow of c1a7c85 re-run unchanged on that file
(74 and 72 required checks, the verdicts of 2026-09-28).

**Earlier run of record: 2026-09-28**, `make formal-full` at commit 588d76a
([record](../results/formal/2026-09-28_588d76a/RECORD.md)), on `rtl/execute_stage.sv`
with SHA-256 `847dc018…fab1bb`, the file before Zbb, Zbs and Zicond: `FORMAL RESULT:
PASS (mode=full)` after 24 min 33 s (74 required checks, 4 negative controls, 20
second-solver runs, 608 mutant runs); `make formal` after 1 min 07 s (72 required
checks, 4 negative controls). The tables of the M unit below are from that run; the
verdicts of 2026-10-02 are the same, and its times are in its record.

Engines: bw = bitwuzla, bwn/yn = bitwuzla/yices restarted per `check-sat`, z3.

**Proof chain on the real RTL** (all unbounded, k-induction):

| Property | Engine | k | Result | Wall |
|---|---|---|---|---|
| CTRL | bw / yn | 2 | PASS / PASS | 1.9 s / 13.4 s |
| DIVF | bwn / yn | 1 | PASS / PASS | 3.7 s / 2.9 s |
| DIVF | bwn / yn | 2 | PASS / PASS | 4.2 s / 3.2 s |
| MULREG | bw / yn | 2 | PASS / PASS | 1.2 s / 1.2 s |
| FINAL F1-F3, DIV/DIVU/REM/REMU | bw / bwn / yn | 2 | PASS / PASS / PASS | 4.5 s / 4.8 s / 7.0 s |
| FINAL F1-F3 × MUL/MULH/MULHSU/MULHU (12 tasks) | yn | 2 | 12/12 PASS | 1.2-1.4 s each |
| same, second solver | bwn | 2 | 10/12 PASS; MULH-F3 and MULHSU-F3 TIMEOUT 300 s (reported only) | 1.3 s |
| A1 × 8 opcodes | yn | 2 | 8/8 PASS | 1.6-1.7 s each |
| A1, second solver | bwn | 2 | 6/8 PASS; MULH and MULHSU TIMEOUT 600 s (reported only) | 1.7-2.8 s |
| A3a × 8 opcodes | yn | 2 | 8/8 PASS | 1.4-1.5 s each |

**Lemma validity:**

| Check | Engine | Result | Wall |
|---|---|---|---|
| H5a, H5b, H7, H9 | bw and z3 (depth 1) | PASS (each with both solvers) | 0.7-0.9 s |
| H8 | z3 | PASS | 0.8 s |
| H6, 33-way case split | z3 | 33/33 unsat | 1.1 s (sum of the case times 3.3 s) |
| H6 split, negative control 1 (quotient bit inverted) | z3 | 1/33 unsat, 32 sat, as required | 1.0 s |
| H6 split, negative control 2 (premise T < 2^31 dropped) | z3 | 2/33 unsat, 31 sat, as required | 5.1 s |
| H6 monolithic, through SBY (full mode) | bw / bwn | PASS / PASS | 804.5 s / 1472.5 s |
| H1 fan-in cone of `mul_result` | yosys | `CONE-CHECK-OK`; the same check on `m_result` fails, as required | 0.2 s |

**Spec, non-vacuity, fidelity, controls:**

| Check | Result | Wall |
|---|---|---|
| Spec vs Python model (Verilator) | 1,002,592 vectors (2,592 corner, 1,000,000 random), 0 mismatches | 4.2 s |
| `f_spec_m == f_spec_ref`, 8 opcodes | bw 8/8 PASS | 0.9 s each |
| Covers C1-C6, bare environment, depth 45 | 6/6 reached | 14.9 s |
| Covers C1-C6, everything assumed, depth 45 | 6/6 reached | 24.4 s |
| Covers, every M opcode leaves Execute, depth 40 | 8/8 reached | 4.6 s |
| sv2v fidelity: `test_m_execute`, `test_execute_compare`, `test_execute_bpred_nextpc` | Identical output (24, 53 and 8 lines) for SystemVerilog and sv2v. Results: `All 6268 M-extension checks passed`, `Tests: 142 Errors: 30` (the known golden baseline), `All 40000 branch-prediction next-PC checks passed` | 2.8 s (with ccache) |
| Multiplier formulation (hand copy), 4 ops × bw, y | 8/8 PASS; the MULHSU negative control FAILs, as required | 0.8-1.0 s |

**Mutation campaign** (full mode; 19 mutants × 32 proofs; 300 s per task):

| Mutant | Verdict | Non-PASS proofs |
|---|---|---|
| rem_sign_divisor, count31, quo_sign_or, stop_early, rem_no_restore, take_ge, divisor_raw | rejected | CTRL `UNKNOWN` |
| jump_noreset | rejected | CTRL, DIVF, MULREG `UNKNOWN` |
| rem_ovf_one, divu_zero, ovf_ungated | rejected | FINAL(div) `FAIL` (concrete counterexample), A1 `UNKNOWN` |
| mag_onescomp, ready_in_run | rejected | FINAL(div), A1 `UNKNOWN` |
| mulhsu_swap, mulh_unsigned | rejected | FINAL(mul) of that opcode, A1 `UNKNOWN` |
| **rem_not_decoded**, **mulh_not_decoded** | rejected | **only** A1 of that opcode `UNKNOWN`; F1-F3 all pass |
| **stall_valid_to_mem** | rejected | **only** A3a `UNKNOWN` (all 8 opcodes); F1-F3 and A1 pass |
| diff32 | survives | Equivalent mutant (section 3) |

`FORMAL RESULT` also requires every mutant except `diff32` to be rejected.

**EXT unit** (run of 2026-10-02, full mode; the same checks run in default and ext mode,
without the second solver and the mutation campaign):

| Check | Engine | Result | Wall |
|---|---|---|---|
| `f_spec_ext` vs Python model (Verilator) | - | 1,157,509 vectors (157,509 corner, shift and index, 1,000,000 random), 0 mismatches | 5.2 s |
| Payload map vs `defines/op.sv` | - | 45 entries, 40 `op::ext_t` constants, `op::EXT` = 61: PASS | < 0.1 s |
| X1 + X2 × 45 instructions, depth 3 | yn | 45/45 PASS | 1.5-3.2 s each for the 17 cryptography instructions; 1.6-5.8 s for the others, rol, ror, rori 16.2-21.8 s |
| same, second solver | bwn | 45/45 PASS (reported only) | 2.0-5.4 s each |
| X3 (no stall, no jump, any payload) | yn | PASS | 1.4 s |
| Covers, each instruction leaves Execute VALID after a reset, depth 4 | bw | 45/45 reached | 2.6 s |
| Negative controls, 37 mutants × a property each breaks | yn | 37/37 FAIL (counterexample), as required | 1.4-2.4 s each |
| sv2v fidelity: `test_ext_execute` | - | Identical output (14 lines) for SystemVerilog and sv2v; `All 1507647 EXT-unit checks passed` | (within the fidelity check) |

The full run ran these tasks alongside the monolithic H6 proof, so its times are longer
than those of `make formal-ext` (1.1-2.2 s for the cryptography instructions).

**EXT mutation campaign** (full mode; 37 mutants × 46 proofs; 300 s per task). Every
mutant is rejected by a concrete counterexample, and only by the proofs of the
instructions whose result, or whose hand-off of the result, it changes:

| Mutant | Fault | Failing proofs |
|---|---|---|
| andn_and | andn computes and | andn |
| lzc_zero31 | clz and ctz of 0 give 31 | clz, ctz |
| ctz_no_reverse | ctz counts leading zeros | ctz |
| pop_pair | cpop counts every even bit twice and no odd bit | cpop |
| minmax_sign | min/max compare unsigned, minu/maxu signed | max, maxu, min, minu |
| sexth_zero | sext.h zero-extends | sext.h |
| rol_as_ror | rol rotates right | rol |
| orcb_and | orc.b tests byte 1 with AND | orc.b |
| rev8_middle | rev8 leaves the middle bytes in place | rev8 |
| bext_bit1 | bext returns the bit above the index | bext, bexti |
| bseti_rs2 | the single-bit immediate forms read rs2 instead of shamt | bclri, binvi, bseti |
| czero_rs1 | czero tests rs1 instead of rs2 | czero.eqz, czero.nez |
| stall_dead | an EXT instruction stalls Execute for one operand value | X3 |
| reg_flip | the result registered for Memory has bit 8 inverted (X2 only) | the 28 result proofs of Part 2c |
| reg_bubble | an EXT instruction is handed to Memory as `BUBBLE` (X2 only) | the 28 result proofs of Part 2c |
| fwd_invalid | the forwarded result is marked not valid (X1) | the 28 result proofs of Part 2c |
| fwd_addr_rs1 | the forwarding address is taken from the `rs1` field (X1) | the 28 result proofs of Part 2c |
| pack_swap | pack puts rs1 in the high half | pack |
| packh_byte1 | packh takes rs2[15:8] | packh |
| brev8_bytes | brev8 reverses the byte order | brev8 |
| zip_unzip | zip computes unzip | zip |
| unzip_halves | unzip swaps the halves of its result | unzip |
| xperm4_wrap | xperm4 ignores index bit 3 (an index of 8 or more wraps) | xperm4 |
| xperm8_bound | xperm8's range test ignores index bit 7 | xperm8 |
| sig0_ror3 | sha256sig0 rotates by 3 instead of shifting | sha256sig0 |
| sig1_srl11 | sha256sig1 shifts by 11 instead of 10 | sha256sig1 |
| sum0_rol2 | sha256sum0 rotates left by 2 | sha256sum0 |
| sum1_ror24 | sha256sum1 rotates by 24 instead of 25 | sha256sum1 |
| sig0h_gate | the `rs2 << 25` term goes to sha512sig0h instead of sha512sig0l | sha512sig0h, sha512sig0l |
| sig0l_no25 | sha512sig0l without the `rs2 << 25` term | sha512sig0l |
| sig1h_with26 | sha512sig1h with the `rs2 << 26` term | sha512sig1h |
| sig1_srl18 | sha512sig1h/l shift rs1 by 18 instead of 19 | sha512sig1h, sha512sig1l |
| sum0r_swap | sha512sum0r reads rs1 for rs2 in one term | sha512sum0r |
| sum1r_13 | sha512sum1r shifts rs2 by 13 instead of 14 | sha512sum1r |
| crypto_never | the cryptography half is never selected | the 17 result proofs of Part 2d |
| stall_crypto | a cryptography instruction stalls Execute when `rs1[31:24]` is `0xA5` | X3 |
| reg_flip_k | the cryptography result registered for Memory has bit 31 inverted (X2 only) | the 17 result proofs of Part 2d |

`FORMAL RESULT` also requires every EXT mutant to be rejected.

---------------------------------------------------------------------------------------

## 5. What is not proven

1. **Scope: `execute_stage` alone.** E1 and E2 are argued from the RTL text of Decode,
   Memory, Writeback and `cpu.sv` (section 2), not proven in a multi-module model.
   Several things downstream are not covered formally:
   - what Memory, Writeback and the register file do with the result;
   - forwarding consumers in Decode (F2 covers the value Execute puts on its forwarding
     bus, not its use);
   - the trap and interrupt logic.

   Flushes are covered, because Memory `JUMP` is free in every cycle. The system-level
   evidence for M instructions is the CPU tests (`test/asm/mul.s`, `div.s`,
   `test/c/m_extension.c`) and the FreeRTOS `rv32im` builds.
2. **Timing and liveness.** Only the bounded-stall safety property is proven: at most 33
   consecutive M-stall cycles. That a divide eventually leaves Execute additionally needs
   Memory to stop stalling eventually, which is not proven. The exact latency is not
   part of this proof. An earlier, separate proof and the CPU-level test measured 34
   cycles in Execute for a non-early divide, 1 for an early-out and a 1-cycle stall for
   a multiply (section 9).
3. **Hand-off while Memory stalls.** A3 speaks about hand-offs made in Memory-`READY`
   cycles. That Execute's output registers hold still while Memory stalls is RTL-evident
   (the `STALL` branch of the output register block is empty), but it is not a stated
   property.
4. **Trusted tools.**
   - sv2v 0.0.13. It is backed by the bench comparison in section 3, not by a proof.
   - Yosys 0.69 (YoWASP) front end, `write_smt2` and SBY/yosys-smtbmc.
   - bitwuzla 0.9.1, Yices 2.7.0 and z3 (the pip wheel reports version 5.1.0).
   - `/` and `%` are SMT-LIB `bvudiv`/`bvurem`. The spec never divides by zero (special
     cases first), and H6/H9 carry `B ≠ 0`.
   - The semantics are 2-state: X and Z are not modelled.
5. **Lemma checks with a single solver or extra steps.**
   - H6 in default mode rests on z3 plus the case-split pipeline. That pipeline adds two
     trusted steps: the constant substitution in `flatten.py`, and the exhaustiveness
     of the 33 cases, which can be seen by reading `flatten.py`. Both negative controls
     must behave as described, but they only show the pipeline is sensitive, not that
     it is correct. Full mode additionally proves H6 monolithically with bitwuzla
     through SBY, with no split.
   - H8 is proven by z3 only.
   - H1 is a structural cone check, not an SMT query.
6. **The spec is hand-written** from the ISA manual. It is validated against an
   independent Python model and cross-proven against a second formulation, but it is not
   derived from a formal ISA model such as Sail. The golden reference models in `ref/`
   predate the M extension and cannot serve as an oracle (see `defines/op.sv`).
7. **Second-solver gaps** (reported, not required). Bitwuzla does not close FINAL(mul)
   MULH-F3 and MULHSU-F3 within 300 s; yices proves both. Incremental SMT engines do not
   close DIVF within 900 s; the non-incremental ones do, in seconds.
8. **Mutation evidence.** Most mutants are rejected because the induction no longer closes
   (`UNKNOWN`), not by a concrete counterexample. Only the constant errors give `FAIL`.
   Every mutant is a real bug: the repository's `test_m_execute` bench detects all of
   them except the equivalent `diff32`. This was checked outside this package: by the
   development campaign for the first 15 mutants, and by audit 1 for the four it added.
9. **The EXT unit: what lies outside its proof.**
   - **The decoder.** X1 and X2 start from the payload the decoder builds; that the
     decoder turns each 32-bit instruction word into `op::EXT` and that payload, and
     rejects every other word, is not proven. It is checked by simulation: the decoder
     sweep (`test_zba_encoding_sweep`, 486,896 checks, the exact payload of every word of
     the 45 forms that it meets) and `make ext-check`, which runs
     `instruction_decoder` and `execute_stage` together against a C model
     ([record](../results/bitmanip/2026-10-02_e75223e/RECORD.md)). A one-off comparison of
     the decoder with that of the previous commit on all 2^32 instruction words is recorded
     in [crypto](../results/crypto/2026-10-02_bd800d8/RECORD.md#checks-made-once).
   - **Payloads the decoder never builds** (an unused `sel` code, such as the reserved
     codes `1_110_xx` and `1_111_xx` of the cryptography half, `use_imm` on a register
     form, non-zero bits 31:12) are covered by X3 only: Execute still neither stalls nor
     jumps, but their result is not specified.
   - **Data-independent latency (Zkt).** X3 says that every EXT instruction, with any
     payload and any operand values, leaves Execute in its own cycle when Memory is
     `READY`; the stall control `stall_crypto` must fail it. That is the EXT unit's part
     of the Zkt evidence; the pipeline around it (hazards, forwarding, Memory stalls) is
     outside this proof.
   - **Downstream,** as for the M unit (item 1): what Memory, Writeback, the register
     file and Decode's forwarding consumers do with the result.
   - **The specification** is hand-written from the ratified text and validated against
     an independent Python model; it is not derived from the Sail model. The golden
     reference models in `ref/` decode these instructions as illegal and cannot serve as
     an oracle.
   - **Timing.** The proof says nothing about the unit's delay on the FPGA.

   The EXT negative controls and mutants give `FAIL` with a concrete counterexample,
   not `UNKNOWN`: the properties need no invariant, and at depth 3 the base case reaches
   a cycle in which X2 applies. At depth 2 it does not (cycle 0 is a reset), and a fault
   confined to the result registered for Memory, such as the controls `reg_flip` and
   `reg_bubble`, is rejected only by the induction step, as `UNKNOWN`.

---------------------------------------------------------------------------------------

## Tools

Tested combination: Python ≥ 3.8 with YoWASP Yosys 0.69 (which includes SBY and
yosys-smtbmc), bitwuzla 0.9.1, Yices 2.7.0, z3 from the `z3-solver` pip wheel
(reports 5.1.0), sv2v 0.0.13 and Verilator 5.042. Everything installs in user space; no
root is needed. Other versions are untested. Solver versions can change the runtime of
H6 by large factors. The runs of 2026-09-28 and 2026-10-02 both used this combination.

**Where to install.** Put the tools in a persistent directory in your home directory,
such as `~/formal-tools`, not under `/tmp`: many systems clear `/tmp` at every boot, and
the tools then have to be installed again. The directory must allow programs to be
executed (not a `noexec` mount).

**Option A: pip and release binaries** (what these proofs were run with):

```sh
mkdir -p ~/formal-tools && cd ~/formal-tools

# Yosys with SBY and yosys-smtbmc, and z3. Either for the user:
python3 -m pip install --user yowasp-yosys z3-solver
#   -> yowasp-yosys, yowasp-yosys-smtbmc, yowasp-sby, z3 in ~/.local/bin
# or, where pip refuses --user with "externally-managed-environment" (PEP 668; for
# example on Ubuntu 24.04), in a virtual environment inside the tool directory:
python3 -m venv ~/formal-tools/venv
~/formal-tools/venv/bin/python -m pip install yowasp-yosys z3-solver
#   -> the same programs in ~/formal-tools/venv/bin
# The first YoWASP run compiles the WebAssembly binary (about a minute) and caches it,
# by default in ~/.cache/YoWASP; YOWASP_CACHE_DIR moves the cache.

# bitwuzla 0.9.1, static Linux binary: https://github.com/bitwuzla/bitwuzla/releases
#   unzip Bitwuzla-Linux-x86_64-static.zip          -> Bitwuzla-Linux-x86_64-static/bin/bitwuzla
# Yices 2.7.0, Linux x86_64 binary tarball: https://yices.csl.sri.com/
#   tar xzf yices-2.7.0-x86_64-pc-linux-gnu-static-gmp.tar.gz -> yices-2.7.0/bin/yices-smt2
# sv2v 0.0.13: https://github.com/zachjs/sv2v/releases/tag/v0.0.13
#   unzip sv2v-Linux.zip                            -> sv2v-Linux/sv2v

cat > ~/formal-tools/env.sh <<'EOF'
export PATH="$HOME/formal-tools/venv/bin:$HOME/.local/bin:$HOME/formal-tools/Bitwuzla-Linux-x86_64-static/bin:$HOME/formal-tools/yices-2.7.0/bin:$HOME/formal-tools/sv2v-Linux:$PATH"
EOF
```

**Option B: OSS CAD Suite.** Unpack a release from
https://github.com/YosysHQ/oss-cad-suite-build/releases and `source <dir>/environment`.
It provides `yosys`, `sby`, `yosys-smtbmc`, `bitwuzla`, `yices-smt2` and `z3`. Add
sv2v from its release page if the suite does not include it.

**How `run.sh` finds them** (`scripts/env.sh`):

1. `HADES_FORMAL_ENV=<file>` is sourced first, if set. For example,
   `export HADES_FORMAL_ENV=~/formal-tools/env.sh`.
2. The tools are then looked up on `PATH`: `sby` or else `yowasp-sby`; `yosys` or else
   `yowasp-yosys`; and so on.
3. `BITWUZLA`, `YICES_SMT2`, `Z3`, `SV2V`, `VERILATOR` and `SBY` override single tools.

The solvers are wrapped in `<out>/bin` with a memory cap (`ulimit -v`, `SOLVER_VMEM_KB`,
default 4 GB; 6 GB for the H6 runs via `H6_VMEM_KB`) and `nice`. Nothing in the
repository needs to be executable. Scripts are started with `bash`, and every generated
program lives in the output directory. The flow therefore works from a checkout on a
`noexec` disk when `BUILD_DIR`/`HADES_BUILD_DIR` points elsewhere (see
`docs/FREERTOS.md`).

A missing tool stops the run before anything is proven. The run then prints
`FORMAL RESULT: FAIL (missing tools)` and exits with status 2.

---------------------------------------------------------------------------------------

## 7. Running the proofs

```sh
export HADES_FORMAL_ENV=~/formal-tools/env.sh     # if the tools are not on PATH
make formal                                       # default mode
make formal-full                                  # full mode
make formal-ext                                   # the EXT unit only, output in $(BUILD_DIR)/formal-ext
make formal FORMAL_PAR=2                          # fewer parallel solver processes (default 4)
make formal BUILD_DIR=/abs/path                   # output in /abs/path/formal
bash formal/run.sh --mode full --out /tmp/f --par 4   # the same without make (modes default, full, ext)
```

**Output** (`<out>` = `$(BUILD_DIR)/formal`):

| Path | Contents |
|---|---|
| `<out>/run.log` | Everything printed |
| `<out>/SUMMARY.txt` | The table and the verdict |
| `<out>/work/runs/times.txt` | One line per check: status, wall time, class |
| `<out>/work/runs/<sby>_<task>/` | SBY run directories, with counterexample traces when a check fails |

**Classes** in the summary:

| Class | Meaning |
|---|---|
| `REQ` | Must PASS. |
| `CTL` | A negative control that must FAIL. |
| `AUX` | Second-solver run, reported only. |
| `MUT` | Mutation campaign. |

**Re-running one task** after a run, from the repository root:

```sh
PATH=<out>/bin:$PATH SBY=yowasp-sby bash formal/scripts/run_task.sh <out>/work div.sby ctrl_bw 600 REQ
```

Use `SBY=sby` with OSS CAD Suite. The task names are listed in the `[tasks]` section of
each `sby/*.sby` file.

**If a proof fails after an RTL change:**

- A `FAIL` comes with a counterexample trace in the run directory
  (`engine_0/trace*.vcd`).
- An `UNKNOWN` from `mode prove` means the induction step found a state that violates
  the property. That state is either reachable, which is a bug, or unreachable, in which
  case an invariant has to be strengthened.
- Run a BMC from reset for a concrete trace. Copy the task, set `mode bmc` and a depth of
  about 40, which is enough for a full 34-cycle divide.
- A `FAIL` of an EXT task (`ext.sby`) names the instruction in the task name; the
  trace shows the operands, the forwarded or registered value, and `x_spec`.

**Changing the M unit.** `props/div_props.vh` observes internal RTL signals by name, for
example `m_state`, `m_count`, `m_quo`, `m_rem`, `m_divisor`, `div_shifted` and
`mul_result`. Renaming them breaks the elaboration. A change of the algorithm needs new
CTRL/DIVF invariants. The mutants are textual patterns on the sv2v output, and
`mutate.py` stops if a pattern no longer occurs exactly once.

**Changing the EXT unit.** The EXT proof reads no internal signal, so a restructured
unit needs no change to the properties. A new instruction needs a line in
`f_spec_ext`, a line in `f_ext_payload` of `harness/top_ext.v`, a case in the Python
model and a task in `sby/ext.sby`. A changed payload encoding in `defines/op.sv` makes
`scripts/ext_codes.py` fail until the harness's map is updated. The EXT mutants in
`mutants/ext_mutants.txt` are textual patterns like the M mutants (`\n` and `\t` stand
for a newline and a tab, so that a pattern can span lines); `ext_mutants.py` stops if one
no longer occurs exactly once.

---------------------------------------------------------------------------------------

## 8. Files

| Path | Contents |
|---|---|
| `run.sh` | Driver: modes, steps, summary and verdict |
| `scripts/env.sh` | Tool discovery and solver wrappers |
| `scripts/gen.sh` | sv2v translation and the one inserted include line (checked) |
| `scripts/run_task.sh`, `run_many.sh` | Bounded, timed SBY runners |
| `scripts/sv2v_fidelity.sh` | Bench comparison SystemVerilog vs sv2v |
| `scripts/mutate.py`, `run_mutants.sh` | Mutation campaign of the M unit |
| `scripts/ext_codes.py` | Check of the EXT payload map against `defines/op.sv` |
| `scripts/ext_mutants.py`, `run_ext_mutants.sh` | EXT negative controls and mutation campaign |
| `harness/top.v` | Formal top: the real `execute_stage`, all inputs free |
| `harness/top_iface.v` | The same, plus the port-level properties A1/A3a and the per-opcode covers |
| `harness/top_ext.v` | The same, plus the EXT payload map, the properties X1-X3 and the per-instruction covers |
| `props/div_props.vh` | Environment E0-E2, ghost state, CTRL, DIVF, MULREG, FINAL (F1-F3), covers C1-C6 |
| `props/hints.vh` | The lemma instances (written once, assumed by the proof, asserted by the validity check) |
| `props/spec.vh` | RV32M spec: `f_spec_m` (used) and `f_spec_ref` (cross-check) |
| `props/ext_spec.vh` | Zbb, Zbs, Zicond, Zbkb, Zbkx and Zknh spec: `f_spec_ext` |
| `sby/div.sby` | CTRL, DIVF, MULREG, FINAL(div) |
| `sby/fmul_ops.sby` | FINAL(mul), per opcode and property |
| `sby/iface.sby` | A1, A3a per opcode |
| `sby/cover.sby` | Non-vacuity |
| `sby/ext.sby` | EXT unit: X1/X2 per instruction, X3, covers |
| `sby/hint_validity.sby`, `spec_equiv.sby`, `mul_formulation.sby` | Lemma validity, spec equivalence, multiplier formulation |
| `lemmas/hint_validity.v`, `spec_equiv.v`, `mul_result_cone.ys` | Lemma/spec checks and the H1 cone check |
| `lemmas/h6_split/` | z3 case split of H6 (`model.ys.in`, `flatten.py`, `run_split.sh`) |
| `spec_check/` | Verilator + Python cross-checks of the specs (`run.sh` for RV32M, `run_ext.sh` for the EXT unit) |
| `mul/` | Hand-copy multiplier formulation and its negative control |
| `mutants/mutants.txt` | The 19 mutants of the M unit |
| `mutants/ext_mutants.txt` | The 37 mutants of the EXT unit, each with the property it must fail |

---------------------------------------------------------------------------------------

## 9. History and independent audits

The proof was developed against `rtl/execute_stage.sv` of commit `97ef211` (SHA-256
`50bed4cf…5111`). The file of the run of 2026-09-28 (`847dc018…fab1bb`) additionally
contains fix E: the architectural `next_pc`, independent of the branch prediction. Its
sv2v model differs from the `97ef211` one in exactly one line, `assign next_pc = ...`,
which is outside the M unit. `run.sh` re-proves everything on the file in the tree.

**2026-10-02: Zbkb, Zbkx and Zknh.** The cryptography half of the EXT unit (Part 2d,
reached through `alu_sel` 1111 when bit 11 of the payload is set) and the sixth bit of
`sel` were added to `rtl/execute_stage.sv` (now `52201629…2bfa5d`) and `defines/op.sv`;
Part 2c and the M unit did not change. The EXT proof was extended to the 17 new
instructions: `f_spec_ext` from the scalar cryptography specification, the Python model
(with the SHA-512 halves taken from the 64-bit FIPS 180-4 functions), the harness's map
(6-bit `sel`, 45 rows), 17 new result proofs and second-solver runs, 45 covers and 20
new mutants. X3 was not changed: it already covered every payload. The 28 existing
result proofs and the 17 existing mutants kept their meaning, because every existing
payload is unchanged (bit 11 is 0).

**2026-10-02: Zbb, Zbs and Zicond.** Commit c1a7c85 added the EXT unit (Part 2c), an
`EXT` arm in the ALU's operation decode and one arm of its result select to
`rtl/execute_stage.sv` (now `c36613c8…3ae969`), and appended `op::EXT` to
`defines/op.sv`; the M unit's code did not change. The M flow of c1a7c85 ran on the new
file without any change to it and gave every verdict of the earlier run (section 4): the
new unit inside the same module did not disturb the sv2v translation, the one-module
check of `gen.sh`, or any property. The EXT proof (`harness/top_ext.v`,
`props/ext_spec.vh`, `sby/ext.sby`, its checks and its mutants) was added the same day,
together with `test_ext_execute` in the sv2v fidelity check, `--mode ext` and
`make formal-ext`.

**Earlier chain, not included.** A first chain used the multiplicative invariant
`T == X*B + R`. It needed a Euclidean-uniqueness lemma, `A == Q*B + R, R < B → Q == A/B`,
that no available solver checks at 32 bits:

- bitwuzla took 961 s at 16 bits and more than 1 h at 20 bits;
- the one-step lemma H6 in division form, by comparison, took 971 s at 32 bits.

That chain's divider "PASS" rested on the unchecked lemma and is not claimed. It was
replaced by the division-form chain above.

**Independent audits.** Two auditors re-ran the proofs, checked E1/E2 against the RTL and
checked the spec against their own models. They wrote their own mutants: 15 SystemVerilog
mutants in one audit and 21 in the other.

Audit 1 judged CTRL, DIVF, MULREG, FINAL and the lemma checks sound. It judged F1-F3
*partly vacuous*, because they are gated by the RTL's decode and the stall hand-off is
unconstrained, and it formulated A1/A3a. Those are included here and are required.

Audit 2 examined a second, separate proof of the divider: a compositional proof that
chains lemmas through a pure step function. It judged that proof sound, but it contains
hand steps: a bit-vector-to-integer translation of the Euclid step, and the lemma
chaining itself. That proof is **not packaged here**, because the chain in this directory
is fully machine-checked.

The second proof and its CPU-level test also established:

- the exact latencies: 34 cycles in Execute for a non-early divide, 1 for an early-out,
  and a 1-cycle stall for a multiply;
- 10^9 cycles of co-simulation of the SystemVerilog against the sv2v model and an
  independent C++ reference, with no mismatch.

Neither result is re-run by `run.sh`.
