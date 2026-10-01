# Formal verification of the M unit

This directory holds a machine-checked proof that the multiply/divide unit of
`rtl/execute_stage.sv` computes the RISC-V M-extension results. It covers MUL, MULH,
MULHSU, MULHU, DIV, DIVU, REM and REMU, including division by zero and the
`-2^31 / -1` overflow. The proof holds for **all 2^64 operand pairs**, in **every
reachable state** (unbounded, by k-induction), under any interleaving of Memory
`STALL`/`JUMP` and of resets. No bug was found in the M unit.

```sh
make formal          # every proof obligation + lemma checks + covers + spec/sv2v checks (about a minute)
make formal-full     # also H6 by bitwuzla and the mutation campaign (about 25 minutes; longer on a loaded machine)
```

Both targets write only to `$(BUILD_DIR)/formal/` and finish with one line,
`FORMAL RESULT: PASS` or `FORMAL RESULT: FAIL ...`. `make` exits with status 0 only
for `PASS`. The tools are listed in [Tools](#tools).

Contents:

1. [What is proven](#1-what-is-proven)
2. [Environment assumptions](#2-environment-assumptions)
3. [How the proof works](#3-how-the-proof-works)
4. [Results and runtimes](#4-results-and-runtimes)
5. [What is not proven](#5-what-is-not-proven)
6. [Tools](#tools)
7. [Running the proofs](#7-running-the-proofs)
8. [Files](#8-files)
9. [History and independent audits](#9-history-and-independent-audits)

---------------------------------------------------------------------------------------

## 1. What is proven

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
  golden execute stage) and `test_execute_bpred_nextpc` twice: once on the
  SystemVerilog, once with `rtl/execute_stage.sv` replaced by the sv2v output. The
  simulation output must be identical line for line.
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

---------------------------------------------------------------------------------------

## 4. Results and runtimes

Run of record: `make formal-full` in this tree, 2026-09-28 ([record](../results/formal/2026-09-28_588d76a/RECORD.md)). It reported
`FORMAL RESULT: PASS (mode=full)` after 24 min 33 s:

- 74 required checks, all PASS;
- 4 negative controls, all FAIL as required;
- 20 second-solver runs;
- 608 mutant runs.

`make formal` (default mode) reported `FORMAL RESULT: PASS (mode=default)` after
1 min 07 s: 72 required checks and 4 negative controls.

The proved file was `rtl/execute_stage.sv`, SHA-256 `847dc018…fab1bb`. The machine has
22 hardware threads and was shared with other jobs. Parallelism was `--par 4`. Wall
times are per task.

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

---------------------------------------------------------------------------------------

## Tools

Tested combination: Python ≥ 3.8 with YoWASP Yosys 0.69 (which includes SBY and
yosys-smtbmc), bitwuzla 0.9.1, Yices 2.7.0, z3 from the `z3-solver` pip wheel
(reports 5.1.0), sv2v 0.0.13 and Verilator 5.042. Everything installs in user space; no
root is needed. Other versions are untested. Solver versions can change the runtime of
H6 by large factors.

**Option A: pip and release binaries** (what this proof was run with):

```sh
python3 -m pip install --user yowasp-yosys z3-solver
#   -> yowasp-yosys, yowasp-yosys-smtbmc, yowasp-sby, z3 in ~/.local/bin
#   The first YoWASP run compiles the WebAssembly binary (about a minute; cached).

mkdir -p ~/formal-tools && cd ~/formal-tools
# bitwuzla 0.9.1, static Linux binary: https://github.com/bitwuzla/bitwuzla/releases
#   unzip Bitwuzla-Linux-x86_64-static.zip          -> Bitwuzla-Linux-x86_64-static/bin/bitwuzla
# Yices 2.7.0, Linux x86_64 binary tarball: https://yices.csl.sri.com/
#   tar xzf yices-2.7.0-*-linux-*.tar.gz            -> yices-2.7.0/bin/yices-smt2
# sv2v 0.0.13: https://github.com/zachjs/sv2v/releases/tag/v0.0.13
#   unzip sv2v-Linux.zip                            -> sv2v-Linux/sv2v

cat > ~/formal-tools/env.sh <<'EOF'
export PATH="$HOME/.local/bin:$HOME/formal-tools/Bitwuzla-Linux-x86_64-static/bin:$HOME/formal-tools/yices-2.7.0/bin:$HOME/formal-tools/sv2v-Linux:$PATH"
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
make formal FORMAL_PAR=2                          # fewer parallel solver processes (default 4)
make formal BUILD_DIR=/abs/path                   # output in /abs/path/formal
bash formal/run.sh --mode full --out /tmp/f --par 4   # the same without make
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

**Changing the M unit.** `props/div_props.vh` observes internal RTL signals by name, for
example `m_state`, `m_count`, `m_quo`, `m_rem`, `m_divisor`, `div_shifted` and
`mul_result`. Renaming them breaks the elaboration. A change of the algorithm needs new
CTRL/DIVF invariants. The mutants are textual patterns on the sv2v output, and
`mutate.py` stops if a pattern no longer occurs exactly once.

---------------------------------------------------------------------------------------

## 8. Files

| Path | Contents |
|---|---|
| `run.sh` | Driver: modes, steps, summary and verdict |
| `scripts/env.sh` | Tool discovery and solver wrappers |
| `scripts/gen.sh` | sv2v translation and the one inserted include line (checked) |
| `scripts/run_task.sh`, `run_many.sh` | Bounded, timed SBY runners |
| `scripts/sv2v_fidelity.sh` | Bench comparison SystemVerilog vs sv2v |
| `scripts/mutate.py`, `run_mutants.sh` | Mutation campaign |
| `harness/top.v` | Formal top: the real `execute_stage`, all inputs free |
| `harness/top_iface.v` | The same, plus the port-level properties A1/A3a and the per-opcode covers |
| `props/div_props.vh` | Environment E0-E2, ghost state, CTRL, DIVF, MULREG, FINAL (F1-F3), covers C1-C6 |
| `props/hints.vh` | The lemma instances (written once, assumed by the proof, asserted by the validity check) |
| `props/spec.vh` | RV32M spec: `f_spec_m` (used) and `f_spec_ref` (cross-check) |
| `sby/div.sby` | CTRL, DIVF, MULREG, FINAL(div) |
| `sby/fmul_ops.sby` | FINAL(mul), per opcode and property |
| `sby/iface.sby` | A1, A3a per opcode |
| `sby/cover.sby` | Non-vacuity |
| `sby/hint_validity.sby`, `spec_equiv.sby`, `mul_formulation.sby` | Lemma validity, spec equivalence, multiplier formulation |
| `lemmas/hint_validity.v`, `spec_equiv.v`, `mul_result_cone.ys` | Lemma/spec checks and the H1 cone check |
| `lemmas/h6_split/` | z3 case split of H6 (`model.ys.in`, `flatten.py`, `run_split.sh`) |
| `spec_check/` | Verilator + Python cross-check of the spec |
| `mul/` | Hand-copy multiplier formulation and its negative control |
| `mutants/mutants.txt` | The 19 mutants |

---------------------------------------------------------------------------------------

## 9. History and independent audits

The proof was developed against `rtl/execute_stage.sv` of commit `97ef211` (SHA-256
`50bed4cf…5111`). The file in this tree additionally contains fix E: the architectural
`next_pc`, independent of the branch prediction. Its sv2v model differs from the
`97ef211` one in exactly one line, `assign next_pc = ...`, which is outside the M unit.
`run.sh` re-proves everything on the file in the tree.

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
