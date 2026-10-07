# trapsweep: interrupt-offset sweeps checked by an independent ISA model

The frozen golden models in `ref/` predate M, Zba, Zbb, Zbs, Zicond, Zicntr and
the branch predictor, and they have bugs of their own (see [below](#known-golden-deviations)).
They cannot check a new instruction, and "DUT == golden" is only as good as the
golden model. This directory adds a second oracle that does not depend on them:

* **`iss.py`**: a small RV32IM + Zba + Zbb + Zbs + Zicond + Zbkb + Zbkx +
  Zknh + Zicsr instruction-set model of the bare-metal MCU, written in Python.
  It is separate from the RTL and from the golden models, but it does encode
  this platform's CSR map, reset values and memory map. Its Zbb, Zbs, Zicond,
  Zbkb, Zbkx and Zknh instructions are checked against a second, differently
  written model
  (`python3 test/ext/ref.py --selftest`). It replays a recorded RTL run using only the RTL's choice of
  interrupt boundaries (the `minstret` value and `mcause` at every trap entry).
  It then checks that everything else the RTL did is architecturally correct:
  * every interrupt is taken at an instruction boundary where it is enabled
    (`mstatus.MIE`, `mie.MxIE`) and its source is armed;
  * every exception is taken exactly at the instruction that raises it, with
    the right cause, and is never lost or duplicated;
  * every trap entry records the right `mepc`, `mcause`, `mstatus` and `minstret`,
    and the handler enters the right vector;
  * result registers, CSR read-backs, peripheral snapshots (LEDs, VGA, stall
    register, RAM: this catches stores that were performed twice or lost), the
    `minstret` delta of every iteration and a final dump of all 31 registers
    all match.

  Timing-dependent values (`mip`, `mcycle`, `time`, peripheral counters) are
  tainted and compared as wildcards.
* **`probes.py`**: 574 *probes* in 15 families; 532 are distinct, because `pre_i`
  repeats the 42 M-free probes of `pre` for the golden CPU. They cover CSR ops on every trap CSR,
  every exception kind under four `mstatus` states, nested ECALL in a handler,
  MRET/FENCE.I/WFI/branches/jumps/load-use, slow-bus loads and stores, 15x15
  pairs, "what was in the pipeline just before", M/Zba, predictor modes 1..3,
  misaligned/faulting control flow and interrupt-source races. Each probe runs in
  a loop over a delay `k = 1..kmax`. The external interrupt (the `wishbone_test`
  countdown register) and/or the timer (`mtimecmp = mtime + k`) becomes pending
  exactly `k` cycles after it is armed, so the interrupt lands on every cycle
  around the probe.
* **`fuzz.py`**: random programs (40-60 segments of random instruction mixes,
  CSR ops, exceptions, faults, slow bus, MRET, loops) with random interrupt
  delays, using the same handlers and trace protocol.
* **`sweep.py`**: the driver. It builds the DUT and golden simulators, splits
  families into programs that fit the 32 KiB RAM, runs everything in parallel,
  checks every run with `iss.py`, and compares DUT and golden iteration by
  iteration where the golden CPU applies.

## Running

From the repository root (Verilator, the RISC-V toolchain and Python 3.9+; no
other dependencies):

```bash
python3 test/trapsweep/sweep.py list                     # families, probe counts
python3 test/trapsweep/sweep.py run                      # every family x ext/timer/both, DUT + golden
python3 test/trapsweep/sweep.py run --fam csr,exc --src ext --targets dut
python3 test/trapsweep/sweep.py fuzz --seeds 101-160                 # RV32I programs, DUT + golden
python3 test/trapsweep/sweep.py fuzz --seeds 201-240 --variant m     # + M/Zba (DUT only)
python3 test/trapsweep/sweep.py fuzz --seeds 301-360 --variant bp    # + branch predictor on (DUT only)
python3 test/trapsweep/sweep.py fuzz --seeds 401-430 --variant mt    # + csrrw mtvec (DUT + golden)
python3 test/trapsweep/sweep.py fuzz --seeds 501-560 --variant b     # + M/Zba/Zbb/Zbs/Zicond (DUT only)
python3 test/trapsweep/sweep.py fuzz --seeds 2001-3000 --variant k   # + Zbkb/Zbkx/Zknh as well (DUT only)
python3 test/trapsweep/sweep.py run --fam ext --targets dut          # Zbb/Zbs/Zicond probes (only when named)
python3 test/trapsweep/sweep.py run --fam crypto --targets dut       # Zbkb/Zbkx/Zknh probes (only when named)
python3 test/trapsweep/sweep.py run --tree ../other-checkout         # test another tree's RTL
python3 test/trapsweep/sweep.py file my_probe.s                      # a hand-written program
```

The simulators are the ordinary full-system `sim/top.sv`, built by `make
frtos-model FRTOS_CPU=dut|ref FRTOS_RAM_KB=32` into `build/frtos-model/`
(the same simulator-variant rule the FreeRTOS tests use; with `HADES_BUILD_DIR` set,
`build/` here and below means that directory, see docs/FREERTOS.md). `+trace` makes
`sim/top.sv` print every store to the trace window as `TRACE <cycle> <offset>
<data>`. It is passive: without `+trace` nothing changes. The full `run` (61
DUT and 51 golden programs, 62,868 + 49,566 iterations, 103,639 DUT trap
entries, 13.4M + 10.3M cycles; [record](../../results/trapsweep/2026-10-01_03386fd/RECORD.md)) takes about 20 s with the default 6 jobs. Output goes to `build/trapsweep/<mode>/`: `summary.txt`,
`results.json`, and per program `init.s`, `init.dis`, `ids.txt` (probe
numbers), `dut/sim.log` and `ref/sim.log`.

The exit status is 0 when every DUT program completed and is ISS-consistent.
The `race` family is the one expected exception (see below).

## Reading the summary

```
csr_ext_0 | dut:done ref:done | ISS[dut] groups_bad=0 violations=0 notes=0 ISS[ref] groups_bad=148 ... | DUT-vs-golden: 2205 iterations, 614 differ
   ref probe  62 csrrwi a1,mscratch,0 (uimm=0)    bad k=[1, 2, ...] [golden bug: CSRRWI rd,csr,0 returns 0 ...]
        k=1 rtl: 01c:3967e 010:45d4c 014:8000000b ... 040:0
              iss: 01c:3967e 010:45d4c 014:8000000b ... 040:1234
```

* `groups_bad`: iterations whose trace stream differs from the ISS. Each one is
  listed per probe with its `k` values and the first records of both streams
  (`offset:value`; `*` marks a tainted wildcard).
* `violations`: an interrupt taken where it was not enabled or armed, or an
  exception lost, duplicated or misplaced.
* `notes`: an interrupt that stayed enabled and armed for 400 instructions
  without being taken (informational).
* `DUT-vs-golden ... differ`: iterations where DUT and golden took the
  interrupt at a *different but legal* boundary. The golden CPU samples
  interrupts one cycle later than the DUT. When the next instruction raises an
  exception, the DUT takes the interrupt first and the golden CPU takes the
  exception first. A CSR op on `mstatus/mie/mcause/mtvec`, or an MRET, is
  replayed by the DUT and retired by the golden CPU. As long as the ISS accepts
  both runs these differences are not bugs.

### Trace protocol (`probes.py`)

| offset (from 0x47E00) | written by | content |
|---|---|---|
| `0x00` | loop | iteration header `probe_id << 16 \| k` |
| `0x38` | loop | `minstret` snapshot when the interrupt is armed |
| `0x1C` | vector stub | `minstret` at trap entry (= instructions retired before the trap) |
| `0x24` / `0x28` | vector B / C | handler marker (which `mtvec` was used) |
| `0x10 0x14 0x18 0x20` | handler | `mepc`, `mcause`, `mstatus`, `mip` |
| `0x0C 0x08 0x04 0x2C` | handler (peripheral mode) | stall register, LEDs, VGA[0], RAM target |
| `0x3C` | handler (nested mode) | `mstatus` after the nested ECALL's MRET |
| `0x30` | loop | `0xDEAD`: the interrupt was never taken |
| `0x34` | loop | `minstret` delta of the iteration |
| `0x40..` | loop | result registers, then `mstatus`, `mie` after the probe window |
| `0x80 + 4i` | end | final dump of `x1..x31` |

## Expected flags

* **Family `race`** (DUT and golden). A store that clears or disarms the
  interrupt source (`sw zero,4(s11)`, `mtimecmph = -1`) has retired, and the
  interrupt is still taken right after it. The line reaches the trap decision
  one cycle late. The privileged spec allows a bounded interrupt latency, so the
  handler sees a spurious interrupt. `sweep.py` reports these but does not fail
  on them.

## Known golden deviations

These are reported as failures of the `ref` target and tagged in the summary.
None of them is a DUT problem.

* **`CSRRWI rd, csr, 0` writes 0 to `rd`** instead of the old CSR value (the
  write itself happens). The spec requires `rd` to get the old value. The DUT
  is correct. This matters for anyone "moving the DUT toward golden".
* **An interrupt taken right after a retired `csrw mtvec` enters the OLD
  vector.** The DUT had the same bug until `writeback_stage.sv` switched the
  sequential-interrupt JUMP to the live `mtvec`. In the golden CPU it shows one
  delay step earlier. Example, probe `csrrw a1,mtvec,a0` at 0x45440: golden
  `k=10` gives `mepc=0x45444` (the csrw retired) but handler A (old). Regression
  test: `test/asm/mtvecirq.s`. In multi-source runs this desynchronises the ISS
  from the golden run for the rest of that iteration, so the other violations
  in the same `mtvec` probes are consequences, not separate bugs.
* **`minstret` reads one higher than the DUT's from reset.** Not a spec
  question: `iss.py` models it (`instret_off=1` for `ref`), and the
  DUT-vs-golden compare uses `minstret` relative to each iteration's snapshot.
* **No M, Zba, Zbb, Zbs, Zicond, Zbkb, Zbkx, Zknh, Zicntr or branch predictor.**
  `iss.py` models the golden CPU without them. Families `m`, `pre`, `bp`, `ext`
  and `crypto` and fuzz variants `m`/`bp`/`b`/`k` run on the DUT only. `pre_i` is
  the M-free subset of `pre`. `ext` (every Zbb, Zbs and Zicond form, dependent
  chains through them, their pipeline neighbours and illegal neighbours) and
  `crypto` (the same for Zbkb, Zbkx and Zknh, with crypto results as branch
  operand, store address and `jalr` base) run only when named with `--fam ext`
  or `--fam crypto`: they are not part of `all` or of `sweep.py list`, whose
  output the trapsweep record stores. Fuzz variant `k` adds the new forms to
  variant `b`'s mix (its choices are drawn only with `--k`, so variant `b`'s
  programs are unchanged). Their results are recorded with the tests of these
  extensions: fuzz variant `b` (seeds 1001 to 2000) and the `ext` family in
  [bitmanip](../../results/bitmanip/2026-10-02_e75223e/RECORD.md), fuzz variant
  `k` (seeds 2001 to 3000, 1,000 of 1,000 consistent) and the `crypto` family
  (27 probes, 3 of 3) in [crypto](../../results/crypto/2026-10-02_bd800d8/RECORD.md).

## Extending

* **New probe:** add a `dict(name=..., probe=..., [setup=..., dump=[regs],
  kmax=..., periph=True, nested=True, restore=..., readback=csr])` to a family
  function in `probes.py`, or add a new family to `FAMS`. The handler, the
  vectors A/B/C and the trace layout are shared.
* **New instruction or CSR (a future extension):** implement it in
  `ISS.step()`, and for a CSR in `CSR_VALID`, `csr_read` and `csr_write`, in
  `iss.py`. Then add probes that use it, e.g. next to ECALL, CSR ops, slow-bus
  accesses and taken branches, plus a fuzz generator entry. The ISS is the
  oracle, so run those families with `--targets dut` (add them to
  `probes.DUT_ONLY`).
* **Sanity-check a change to the oracle** by reverting an RTL fix. The sweep
  must flag it (see the mutation results below).

## Provenance and results

Developed during the trap/interrupt hardening of HaDes-V+, where it found two of
the six bugs fixed in that work (the branch-predictor `next_pc` and the stale
`mtvec` defects; [record](../../results/history/2026-09-27_6b19d41/RECORD.md)). Results
with the current RTL (`sweep.py run`, all families, ext/timer/both;
[record](../../results/trapsweep/2026-10-01_03386fd/RECORD.md)):

* DUT: 61/61 programs ISS-consistent. Only the three `race` programs carry
  flags, and those are the expected bounded-latency ones.
* golden: 25/51 ISS-consistent. Apart from the expected `race` flag of
  `race_ext_0`, every flagged probe is a CSRRWI-0 or `mtvec`-write probe, i.e. a
  known golden deviation. (`sweep.py` excuses the `race` family on the DUT only,
  so `race_ext_0` counts as one of the 26 golden programs that are not
  ISS-consistent.)
* Before the `mtvec` fix, the DUT failed 32/61 programs, and every flagged
  probe was one that writes `mtvec`
  ([record](../../results/history/2026-09-27_6b19d41/RECORD.md)).
* fuzz: `i` 101-160 DUT 60/60, golden 60/60; `m` 201-240 DUT 40/40; `bp`
  301-360 DUT 60/60; `mt` 401-430 DUT 30/30, golden 30/30 (before the `mtvec`
  fix: DUT 28/30, [record](../../results/history/2026-09-27_6b19d41/RECORD.md)).

**Mutation check.** Each RTL fix was reverted on its own in a copy of the
integrated tree. For every revert, `sweep.py run` (DUT) flags programs outside
the `race` family, and so does the fix's own directed test in `test/asm/`
([record](../../results/history/2026-09-27_6b19d41/RECORD.md)):

| reverted fix | `sweep.py run`, DUT ISS-consistent | families flagged | directed tests that fail |
|---|---|---|---|
| A: exception beats a same-cycle interrupt | 17/61 | bp bus ctl exc exc_mpie0 m nested pairs pre pre_i | trapirq, bpirq3 |
| B: `MPIE <= MIE` on every trap | 46/61 | exc_mie0 exc_mie0mpie0 m nested pairs | trapmpie |
| C: replay of a stale trap-state CSR op / MRET | 9/61 | bp bus csr ctl exc exc_mpie0 flow m nested pairs pre pre_i | csrirq, mtvecirq |
| D: interrupt held during a bus access | 39/61 | bus exc exc_mpie0 m nested pre pre_i | memirq |
| predicted-taken branch `next_pc` | 58/61 | bp | bpirq, bpirq2, bpirq3 |
| live `mtvec` for the interrupt JUMP | 29/61 | bus csr m pairs pre pre_i | mtvecirq |

With the predictor-`next_pc` fix reverted, fuzz `bp` 301-360 is 20/60
ISS-consistent.
