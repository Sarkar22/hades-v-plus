# Formal verification of the caches

This directory holds the formal proofs of the simulation-only caches and their memory system.
The caches exist only in the simulators; the standard build and the Basys 3 bitstream have no
cache, and nothing here is part of `make formal`. The proofs cover:

- **the I-cache**, `rtl/cache/icache.sv` with its array wrapper `rtl/cache/cache_ram.sv`;
- **the memory arbiter**, `rtl/cache/mem_arbiter.sv`, which shares the single memory port
  between the I-cache's refills and the data side;
- **the interconnect's timeout exemption**: the `TIMEOUT_EXEMPT` mask of
  `lib/wishbone/wishbone_interconnect.sv` and the mask that the cached branch of `rtl/mcu.sv`
  passes to it;
- **the D-cache**, `rtl/cache/dcache.sv`, and **the memory system with both caches**: the
  I-cache, the D-cache, the arbiter with D-refill blocks and a tiny memory together, the
  arbiter's equivalence with the base commit's when its data continuation tag is 0, and a
  k-induction attempt on the D-cache alone (section 10).

Sections 1 to 9 describe the proofs of the I-cache and the arbiter, which also run unchanged
with the D-cache present (their harnesses tie the arbiter's `data_cont` input to 0); section 10
describes what the D-cache adds.

```sh
make formal-cache        # every proof, cover and negative control; output in $(BUILD_DIR)/formal-cache
```

The run ends with one line, `FORMAL CACHE RESULT: PASS` or `FORMAL CACHE RESULT: FAIL (...)`, and
`make` exits with status 0 only for `PASS`. It needs the tools of `make formal` (SymbiYosys, Yosys,
sv2v, bitwuzla, Yices, z3; see [Tools](../README.md#tools)), found on `PATH` or through
`HADES_FORMAL_ENV`, and Verilator only for the last step of the fallback ladder. `make formal`,
`make formal-full` and `make formal-ext` are separate and unchanged.

Contents:

1. [What is proven](#1-what-is-proven)
2. [The model](#2-the-model)
3. [Environment assumptions](#3-environment-assumptions)
4. [Depths and the fallback ladder](#4-depths-and-the-fallback-ladder)
5. [Negative controls](#5-negative-controls)
6. [k-induction on the I-cache alone](#6-k-induction-on-the-i-cache-alone)
7. [Results](#7-results)
8. [Running the proofs](#8-running-the-proofs)
9. [Files](#9-files)
10. [The memory system with both caches](#10-the-memory-system-with-both-caches)

---------------------------------------------------------------------------------------------

## 1. What is proven

### The I-cache and the arbiter

Bounded proofs on two tiny configurations (section 2). Each property has a name; its tasks in
`sby/` are `<name>_tiny` and `<name>_second`, and `run.sh` reports it under that name.

| Name | Property |
|---|---|
| `fetch_data` | A fetch `ack` delivers memory's word of the presented address, as it was at the start of the cycle (for the tracked address). |
| `line_data` | If the line holding the tracked address is valid with its tag, its cached word equals memory's word. |
| `window` | `err` exactly for fetch requests outside the window; no `ack` outside the window. |
| `ack_err` | Never `ack` and `err` together on any port: the I-cache's CPU port and both slave sides of the arbiter. |
| `answer_req` | `ack` and `err` only with `cyc` and `stb`, on the same three ports. |
| `grant_route` | At most one side is granted; the memory port carries exactly the granted side's request (and the continuation tag only for a refill) and is all zeros when idle; answers go only to the granted side, the other side sees `ack = err = 0` and `dat_miso = 0`; the arbiter's grant events are these grants. |
| `refill_no_write` | No memory write from a refill's first grant through its last beat, unless a reset comes in between. |
| `grant_kept` | A granted refill keeps the grant in every cycle until its last beat, a granted data transfer until its answer, unless a reset comes in between. |
| `bound` | Bounded response: a data request is answered by cycle `R + D` of its wait, and a granted refill's last beat by cycle `R` of its grant (an interval's first cycle is its cycle 1; an interval with a reset cycle is abandoned). In the tiny configuration `R = 6` and `D = 3`. |
| `bound_cpu` | With the data side of a CPU (section 3): a refill is granted by cycle `3 * D` of its wait, counted from its first refill cycle. |
| `reset_state` | In the cycle after a reset cycle no valid bit is set, the I-cache is in `LOOKUP` with `beat == 0`, its refill request is idle, and the arbiter's owner is `NONE` (the data side may request). |
| `store_fetch` | After a store to the tracked address is answered, no later fetch `ack` of that address returns any value other than memory's. |
| `refill_window` | Every refill beat address lies inside the window. |
| `refill_stable` | The I-cache's memory-side request (address, `we`, `sel`, write data, continuation tag) does not change until it is answered, unless a reset comes in between. |
| `store_once` | A data store answered on the data side has updated memory at that edge, and exactly one memory write is answered per answered data store: in the same cycle, with the store's address, `sel` and data. |
| `data_indep` | Non-interference: two copies of the I-cache and the arbiter with equal inputs except data values (memory's read data, the data side's write data, the initial contents of the data arrays) produce equal `ack` and `err` on every port, equal request control signals of the memory port and of the refill port, equal continuation tags, equal grants and equal events. |

`R` is the longest a granted refill can take and `D` the longest a granted data transfer can
take, with the memory of section 3 (at most 2 wait cycles per transfer): `D = 3`, and `R = 3`
cycles per word of a line, 6 in the tiny and 12 in the second configuration. A grant in `refill_no_write`, `grant_kept`, `bound` and `bound_cpu` is the grant that the
arbiter gives, as its grant events show it; `grant_route` checks those events against the rules
of the arbiter (data side first on a free port, a grant held to the end of its transfer or
block), computed from its `owner` and the two requests.

Every property is checked from the cycle after the first one: the first cycle is a reset from a
free state. Unless its row says otherwise, a property is also checked in later reset cycles, in
which the design's outputs follow the same rules from the state before the reset.

### The interconnect's timeout exemption

The interconnect is read as the tree has it (`dut`) and as the base commit had it before the
mask was added (`base`: `wishbone_interconnect_base.sv`, a copy of that file with only its module
name changed; `run.sh` checks the copy against the commit when the repository has it). Both get
the slave map of `rtl/mcu.sv` (nine slaves, slave 0 the RAM, the addresses and sizes of
`defines/constants.sv`).

| Name | Property |
|---|---|
| `ic_default` | The module with its default mask equals the base module, from a common reset, for every input sequence: equal outputs (the master's `ack`, `err` and read data, every slave's request signals) and equal timeout counters in every cycle. Unbounded, by induction with the equal counters as the invariant. |
| `ic_ram_exempt` | With the mask read from the cached branch of `rtl/mcu.sv`: if the master holds `cyc`, `stb`, the address, `we`, `sel` and the write data until `ack` or `err` (and so drops `cyc` only after one of them), then, with free slave answers, the timeout never fires while slave 0 is selected, and the counter is 0 in every cycle in which slave 0 is selected. Unbounded. |
| `ic_io_timeout` | The module with that mask and the base module have equal outputs and equal counters in every cycle, for every input sequence that never selects slave 0: every I/O slave keeps its timeout. Unbounded. |

`run.sh` also checks the mask itself: the cached branch of `rtl/mcu.sv` (the text between
`` `ifdef HADES_ICACHE_BYTES `` and its `` `else ``, `` `elsif `` or `` `endif ``) must pass exactly one
`.TIMEOUT_EXEMPT(...)`, equal to `9'b0_0000_0001`, and no other part of the file may pass one.

### Covers

Each cover must be reached; they show that the properties are not vacuous. In both
configurations, with the full harness: a refill completes; a second refill completes in the other
set; a snoop invalidates a valid line; the fetch address changes during a refill; a reset comes
during a refill, and while it requests its last beat; a data request waits behind a refill; the
data side has `cyc` without `stb` during a refill beat; a data transfer is granted and answered in
the second-lookup cycle; a hit in the cycle after a fill; a store in the second-lookup cycle to the
line just filled; a hit while the data side holds the port; an `err` during a refill; and the
trigger of each property (the tracked word fetched, the tracked line valid, a fetch of the tracked
word after a store to it, a store waiting for a refill, the longest data wait `R + D - 1`, the
longest refill `R`, a refill beat that waits, a store to the tracked word, a refill waiting for the
port). With the data side of a CPU: three back-to-back data transfers of `D` cycles between a
miss and its refill's first grant, the first granted in the miss cycle, so that the refill is
granted in the last cycle that `bound_cpu` allows. For the pair of copies: a refill, a hit
during a data grant and an answered store. For the interconnect: an I/O access still times out,
and with the mask a RAM access waits 256 cycles without a timeout.

---------------------------------------------------------------------------------------------

## 2. The model

**Sources.** `run.sh` copies the RTL of the tree (`rtl/cache/*.sv`, `rtl/mcu.sv`,
`lib/wishbone/wishbone_interface.sv`, `lib/wishbone/wishbone_interconnect.sv`, `defines/*.sv`)
to its work directory and converts it with sv2v, with `SYNTHESIS` defined (so the simulation-only
initial contents of the arrays, the prints and the assertions are absent, and the arrays start
free) and `HADES_FORMAL` defined (it is defined only here). The repository is never written.

**Harnesses** (`harness/`). One plain top module per proof, without interface ports: it
instantiates the `wishbone_interface` instances and the modules under proof and brings every free
choice out as an input.

| Harness | Modules | Used for |
|---|---|---|
| `cache_top.sv` | `icache` and `mem_arbiter`, connected as the cached branch of `rtl/mcu.sv` connects them | every property but `data_indep`; the covers |
| `cache_pair_top.sv` | two copies of both | `data_indep` |
| `icache_top.sv` | `icache` alone; an abstract port grants its refills and answers them | k-induction; the I-cache's share in the decomposed step of the fallback ladder |
| `arbiter_top.sv` | `mem_arbiter` alone; a refill master that behaves as the I-cache's refill port | the arbiter's share in the decomposed step |
| `interconnect_top.sv` | `wishbone_interconnect` of the tree and the base copy | the three interconnect properties |

The snoop of the harnesses is the connection that the cached branch of `rtl/mcu.sv` makes:
`scripts/model.py` reads the expressions connected to the I-cache's `snoop_store` and `snoop_adr`
there and writes them, with `mem_bus_slaves[0]` replaced by the harness's slave-0 interface, to
`snoop.svh`. Without such a connection it uses `cyc && stb && we && ack` of slave 0 and its
address, and says so.

**Internal names.** sv2v converts a module with interface ports by inlining it into the module
that instantiates it, so `icache` and `mem_arbiter` become named blocks of the harness, and their
internal names are visible there as `icache.<name>` and `mem_arbiter.<name>`. The state and the
owner are values of named constants of the RTL (`LOOKUP` and `REFILL`; `NONE`, `DATA` and
`IREFILL`: constants rather than enumerations, because Verilator cannot follow a hierarchical
reference to an enumeration value), which the converted model shows only as numbers, so
`scripts/model.py` inserts one include line before the final `endmodule` of its copies of
`icache.sv` and `mem_arbiter.sv`, before the conversion:
`props/observe_icache.svh` gives the state by name (`f_obs_lookup`, `f_obs_refill`), the valid
bits as a vector with bit k for set k (`f_obs_valid`, whether the design keeps them packed or
unpacked), and `beat` and `refill_line` zero-extended (`f_obs_beat`, `f_obs_refill_line`);
`props/observe_arbiter.svh` gives the owner by name (`f_obs_owner_none`, `f_obs_owner_data`,
`f_obs_owner_irefill`). They read only the fixed names of the cache design: the states `LOOKUP`
and `REFILL`, `beat`, `refill_line`, `valid`, `owner` with `NONE`, `DATA` and `IREFILL`, and the
parameters `BYTES` and `LINE_BYTES`. `cache_ram` has no interface ports and stays a module; one
include line before its final `endmodule` in the sv2v output (`props/observe_ram.vh.in`, with the
name of the module's only memory array filled in) exports every word of the array, and the
properties read the tag and data arrays (instances `tag_ram` and `data_ram`; the tag array holds
the tag bits `adr[29:O+I]` per set, the data array the words at `{index, word}`) through wires
named `icache.tag_ram.f_obs_words` and `icache.data_ram.f_obs_words`, which Yosys connects when it
flattens the design (their `hierconn` attribute). One more include line before the final
`endmodule` of the converted harness adds the properties (`props/*.vh`). `scripts/model.py`
checks that each of these lines is the only difference from the RTL and from the sv2v output.
`cache_ram` must therefore keep its words in exactly one unpacked array, as its contract
describes it; the run stops with a message otherwise.

**Yosys** reads the converted model with `-formal`, flattens it and maps the small arrays to
flip-flops (`memory_map`), which keeps the bounded proofs fast.

**Configurations** (`harness/config.svh`; word addresses):

| Configuration | Size | Lines | Sets | Window | Used for |
|---|---|---|---|---|---|
| tiny | 16 bytes | 8 bytes (two words) | 2 | words 8 to 15 | every property |
| second | 32 bytes | 16 bytes (four words) | 2 | words 16 to 31 | `fetch_data`, `line_data`, `window`, `reset_state`, `store_fetch`, `refill_window`, `refill_stable` |

Each window holds four lines, two per set, and leaves addresses below and above it. The proofs
cover what does not depend on the sizes: protocol, arbitration, ordering, coherence and bounds.
What depends on the sizes, the address slicing and the counter widths, is checked at the sizes
of the simulators by the I-cache bench, by the scoreboard of the system runs and by review; the
second configuration adds a beat counter of two bits.

---------------------------------------------------------------------------------------------

## 3. Environment assumptions

Every input of a harness is free in every cycle. The harness turns the free choices into a legal
environment by construction, without `assume` statements, so the same model also runs in the
random simulation of the ladder's last step:

- **Reset.** The first cycle is a reset; in every later cycle a reset is free.
- **Fetch side.** `adr`, `cyc` and `stb` free in every cycle; `we = 0`, `sel = 1111` and write
  data 0, as both CPUs drive them.
- **Data side** (interconnect slave 0). A request (`cyc` and `stb`) is free and lies in the window
  (slave 0 is selected only there); it is held unchanged (address, `we`, `sel`, write data) until
  it is answered or until a reset cycle drops it (it may already change in the reset cycle); `we`,
  `sel` and the write data are free. Between requests `cyc` is free and may be 1 with `stb` 0, as
  at slave 0 during every I/O access (the interconnect gives slave 0 the master's `cyc`, but `stb`
  only for the RAM window). `stb` is never 1 without `cyc`.
- **Memory.** It answers a transfer only in a cycle in which the transfer is presented, after 0 to
  2 wait cycles of it (when, within that bound, is free); never in a cycle with a reset, and so
  never to a transfer that a reset dropped. Reads return the tracked word at the tracked address
  and free values elsewhere; a write answered at the tracked address updates the tracked word by
  its `sel` lanes; `err` only outside the window, never together with `ack`.
- **Tracked address.** A free word address that never changes; the tracked word's first value is
  free, and so are the first contents of the arrays (all valid bits come from the reset).
- **The data side of a CPU** (`bound_cpu` only; every other property and the other bounds hold
  without it). After a fetch misses, only the older instructions already in the pipeline can still
  access data, and the oldest of them requests in the miss cycle or not at all. So from the miss
  cycle (the `LOOKUP` cycle in which the refill starts) up to the refill's first grant, at most
  three data transfers hold the port, and at most two of them begin (are granted for the first
  time) after the miss cycle. The harness counts the data transfers that begin in refill cycles
  before the refill's first grant and starts no new request once two have begun.
- **Interconnect.** The slaves' answers are free in every cycle. The master is free for
  `ic_default`; for `ic_ram_exempt` it holds its request until `ack` or `err` (a reset cycle ends a
  request too: it may change in the cycle after the reset); for `ic_io_timeout` it is free except
  that it never selects slave 0.

The I-cache-alone harness replaces the arbiter by an abstract port: a refill that requests is
granted in a free cycle and then holds the port while it requests; memory answers it only while it
holds the port; stores acknowledged at slave 0 are free, in the window, never in a reset cycle and
never while a refill holds the port. The arbiter-alone harness replaces the I-cache by a refill
master: in a cycle without a request it may refill an in-window line, requests the line's words in
order from word 0 as one block (each beat held until it is answered, the continuation tag on every
beat but the first), and has no request in the cycle after the last beat.

---------------------------------------------------------------------------------------------

## 4. Depths and the fallback ladder

The bounded proofs run to depth 40 in the tiny configuration (two refills and a snoop with
time to spare: a refill takes at most 6 cycles once granted and waits at most 9) and to depth 30
in the second one (a refill of four beats takes at most 12 cycles). Each property has a minimum
depth: 35 for `fetch_data`, `line_data` and `store_fetch`, 18 for `reset_state`, 20 for the
others (in the second configuration at most 30).

If a property cannot be proved at the stated depth, `run.sh` tries, in this order, and records
the first step that succeeds:

1. the stated depth with each engine in turn: `smtbmc` with bitwuzla, then Yices, then z3;
2. the property's minimum depth, with each engine in turn;
3. the decomposed harness: the property's share on the I-cache alone and on the arbiter alone
   (`sby/split.sby`), each at the minimum depth, with each engine in turn (`data_indep` has no
   decomposed harness and skips this step);
4. the narrower memory (every transfer answered after 0 or 1 wait cycles) at the minimum depth,
   with each engine in turn;
5. no proof: the property's checks run in a random simulation of the harness (Verilator, at least
   10^7 cycles, `scripts/sim.sh`), and the result is "checked by simulation only". Such a property
   also runs as an assertion in the I-cache bench, and needs the maintainer's acceptance:
   `run.sh` counts it as passed only when it is named in `--accept-sim`.

Each step has a time limit per property and configuration (`--step-limit`, default 2 hours), a
third of it for each engine. A counterexample ends the ladder with `FAIL`, except in step 3,
whose harness allows more than the system does: its counterexample is kept and the ladder goes on.

The interconnect properties are unbounded proofs by induction (each engine in turn); their
fallback is a bounded check to depth 260 (each engine in turn).

---------------------------------------------------------------------------------------------

## 5. Negative controls

Each property must fail, where it was proved (the same configuration, step, depth, engine and
harness), on each of its negative controls: source changes of the RTL, listed in `mutants.txt`
under the names of the repository's cache mutation campaign:

| Property | Negative controls |
|---|---|
| `fetch_data` | `no-second-lookup`, `latched-lookup`, `ignore-valid`, `refill-word-off-by-one`, `ack-in-refill`, `snoop-late` |
| `line_data` | `no-snoop`, `grant-free-between-beats`, `refill-word-off-by-one` |
| `window` | `no-window-check`, `narrow-tag` |
| `ack_err` | `narrow-tag` |
| `answer_req` | `ack-without-request` (the I-cache's CPU port), `answer-to-any-side` (the data side), `irefill-answer-by-owner` (the refill side) |
| `grant_route` | `answer-to-any-side`, `irefill-answer-by-owner` |
| `refill_no_write` | `grant-free-between-beats` |
| `grant_kept` | `grant-free-between-beats` |
| `bound` | `grant-never-released`, `refill-never-ends` |
| `bound_cpu` | `i-side-starved` |
| `reset_state` | `reset-keeps-valid`, `reset-keeps-state` |
| `store_fetch` | `no-snoop`, `snoop-wrong-index`, `snoop-full-words-only`, `second-snoop-lost` |
| `refill_window` | `no-window-check`, `refill-follows-cpu-adr` |
| `refill_stable` | `refill-follows-cpu-adr` |
| `store_once` | `store-sel-forced`, `write-replay` |
| `data_indep` | `data-dependent-hit` |
| `ic_default` | `interconnect-default-exempt` |
| `ic_ram_exempt` | `ram-not-exempt` |
| `ic_io_timeout` | `all-exempt` |

Each mutant is written once, as a patch of the repository's mutation campaign
(`test/memsys/mutants.py`, whose `apply` command writes a copy of the RTL with one mutant
applied); the rows of `mutants.txt` name the properties that each one must make fail and leave the
text empty, and `run.sh` builds the mutated models from such a copy in `<out>/work/mut/<name>`
(never in the tree). A row may instead give the file, an exact text that must occur exactly once
in it, and its replacement (several rows with one name make one mutant); `scripts/model.py` then
applies that change to its own copy of the sources. A control is shown when the check FAILS; a
control that passes, or whose change does not apply, fails the run. `snoop-full-words-only`
changes the snoop connection of `rtl/mcu.sv` (the I-cache has no `sel` input), which the harness
uses. With `--mutant-cmd CMD`, `run.sh` runs `CMD <name> <dir>` for every mutant to obtain a copy
of the tree with the mutant applied.

---------------------------------------------------------------------------------------------

## 6. k-induction on the I-cache alone

`sby/induction.sby` attempts an unbounded proof of `fetch_data`, `line_data`, `window` and
`reset_state` on the I-cache alone, by k-induction, with helper invariants (`INDUCTION` in
`props/cache_props.vh`): exactly one state and `beat == 0` outside a refill; the line being
refilled lies in the window and its set's valid bit is clear; after its first beat a refill holds
the port; the words of the tracked line that the current refill has already written are memory's;
every valid line holds the tag of a line inside the window. The outcome is reported (class
`AUX`), not required: `PASS` is an unbounded proof; otherwise the induction step's counterexample
is in the run directory.

---------------------------------------------------------------------------------------------

## 7. Results

The tables below are the outcome of one run of `run.sh --par 4` (four jobs at a time) with the
tools used then (Yosys 0.69, bitwuzla 0.9.1, Yices 2.7.0, Z3 5.1.0, sv2v 0.0.13): 38 required
checks, all `PASS`, and 37 negative controls, all `FAIL` as required; the whole run took 386 s.
`run.sh` writes the same table in `SUMMARY.txt` ("Outcome table"). The times are wall-clock
seconds of that run on one machine, for orientation only; they are not part of what is proved.

Every bounded property was proved at its stated depth (40 in the tiny configuration, 30 in the
second one) at step 1 of the ladder of section 4, by the first engine (`smtbmc` with bitwuzla), on
the full harness: no property needed a smaller depth, a decomposed harness, a narrower memory or a
simulation. The three interconnect properties were proved unbounded by induction, also at step 1.

| Property | Configuration | Depth proved | Step of the ladder | Engine | Time |
|---|---|---|---|---|---|
| `ack_err` | tiny | 40 | 1 (the stated depth, first engine) | bitwuzla | 4 s |
| `answer_req` | tiny | 40 | 1 (the stated depth, first engine) | bitwuzla | 5 s |
| `bound` | tiny | 40 | 1 (the stated depth, first engine) | bitwuzla | 6 s |
| `bound_cpu` | tiny | 40 | 1 (the stated depth, first engine) | bitwuzla | 5 s |
| `data_indep` | tiny | 40 | 1 (the stated depth, first engine) | bitwuzla | 19 s |
| `fetch_data` | tiny | 40 | 1 (the stated depth, first engine) | bitwuzla | 98 s |
| `fetch_data` | second | 30 | 1 (the stated depth, first engine) | bitwuzla | 78 s |
| `grant_kept` | tiny | 40 | 1 (the stated depth, first engine) | bitwuzla | 3 s |
| `grant_route` | tiny | 40 | 1 (the stated depth, first engine) | bitwuzla | 6 s |
| `line_data` | tiny | 40 | 1 (the stated depth, first engine) | bitwuzla | 31 s |
| `line_data` | second | 30 | 1 (the stated depth, first engine) | bitwuzla | 35 s |
| `refill_no_write` | tiny | 40 | 1 (the stated depth, first engine) | bitwuzla | 4 s |
| `refill_stable` | tiny | 40 | 1 (the stated depth, first engine) | bitwuzla | 5 s |
| `refill_stable` | second | 30 | 1 (the stated depth, first engine) | bitwuzla | 3 s |
| `refill_window` | tiny | 40 | 1 (the stated depth, first engine) | bitwuzla | 4 s |
| `refill_window` | second | 30 | 1 (the stated depth, first engine) | bitwuzla | 4 s |
| `reset_state` | tiny | 40 | 1 (the stated depth, first engine) | bitwuzla | 5 s |
| `reset_state` | second | 30 | 1 (the stated depth, first engine) | bitwuzla | 3 s |
| `store_fetch` | tiny | 40 | 1 (the stated depth, first engine) | bitwuzla | 114 s |
| `store_fetch` | second | 30 | 1 (the stated depth, first engine) | bitwuzla | 80 s |
| `store_once` | tiny | 40 | 1 (the stated depth, first engine) | bitwuzla | 6 s |
| `window` | tiny | 40 | 1 (the stated depth, first engine) | bitwuzla | 4 s |
| `window` | second | 30 | 1 (the stated depth, first engine) | bitwuzla | 4 s |
| `ic_default` | interconnect | unbounded (induction) | 1 (induction, first engine) | bitwuzla | 1 s |
| `ic_ram_exempt` | interconnect | unbounded (induction) | 1 (induction, first engine) | bitwuzla | 2 s |
| `ic_io_timeout` | interconnect | unbounded (induction) | 1 (induction, first engine) | bitwuzla | 1 s |

Covers (every cover statement must be reached): all eight runs passed, with no unreached cover.

| Cover run | Reached | Unreached | Time |
|---|---|---|---|
| tiny | 22 | 0 | 4.3 s |
| tiny, CPU-like data side | 23 | 0 | 5.7 s |
| second | 22 | 0 | 9.1 s |
| second, CPU-like data side | 23 | 0 | 11.0 s |
| I-cache pair, tiny | 3 | 0 | 1.3 s |
| interconnect, default mask | 1 | 0 | 34.7 s |
| interconnect, I/O timeout | 1 | 0 | 35.9 s |
| interconnect, RAM exemption | 1 | 0 | 160.7 s |

Negative controls (section 5): all 37 controls fail on the property they target, in the tiny
configuration, at the step, depth and engine at which that property was proved (1 to 3 s each).

k-induction on the I-cache alone (section 6): `PASS`, an unbounded proof of `fetch_data`,
`line_data`, `window` and `reset_state`, in both the tiny (1.6 s) and the second (1.9 s)
configuration.

---------------------------------------------------------------------------------------------

## 8. Running the proofs

```sh
export HADES_FORMAL_ENV=~/formal-tools/env.sh     # if the tools are not on PATH
make formal-cache                                 # everything
make formal-cache FORMAL_PAR=2                    # fewer parallel solver processes (default 4)
make formal-cache FORMAL_CACHE_ARGS='--only fetch_data,grant_kept,ic_default --configs tiny --depth 10'
                                                  # further options of run.sh, here a short trial with
                                                  # the negative controls of those three checks
bash formal/cache/run.sh --out /tmp/fc --par 4    # the same without make
bash formal/cache/run.sh --only fetch_data,grant_kept,ic_default --configs tiny --depth 10 --no-controls
                                                  # a quick first run: two properties at depth 10, and the
                                                  # interconnect's equivalence
```

Options (`bash formal/cache/run.sh --help`): `--only`, `--configs`, `--depth`, `--step-limit`,
`--dind-limit`, `--sim-cycles`, `--accept-sim`, `--no-controls`, `--mutants`, `--mutant-cmd`,
`--src` (prove the RTL of another tree), `--base` and `--arb-base` (the commits of the base
copies). `--only` takes property names, `covers`, `induction` and `dinduction`; a run with
`--only` checks only those (and their negative controls), so its verdict covers only them.
`--configs` takes `tiny`, `nowait` and `second` (default all three; `nowait` concerns only the
properties of section 10). A run without negative controls never ends with `PASS`. The random
simulation of the ladder's last step builds with Verilator, one model at a time, with 4 jobs.

**Output** (`<out>` = `$(BUILD_DIR)/formal-cache`):

| Path | Contents |
|---|---|
| `<out>/run.log` | Everything printed |
| `<out>/SUMMARY.txt` | The ladder's results, the table of checks and the verdict |
| `<out>/work/runs/checks.txt` | One line per check: status, class, wall time |
| `<out>/work/runs/ladder.txt` | One line per property and configuration: status, step, depth, engine, harness |
| `<out>/work/runs/controls.txt` | One line per negative control |
| `<out>/work/runs/<sby>_<task>/` | SBY run directories, with the counterexample trace when a check fails |
| `<out>/work/gen/` | The models: the sv2v outputs (`*_sv2v.v`) and the models with the include lines (`*.v`) |

**Classes** in the summary: `REQ` must pass, `CTL` (a negative control) must fail, `AUX` is
reported only.

**Re-running one task** after a run, from the repository root (`SBY=sby` with OSS CAD Suite):

```sh
PATH=<out>/bin:$PATH SBY=yowasp-sby bash formal/scripts/run_task.sh <out>/work cache.sby fetch_data_tiny 600 REQ
```

**If a proof fails after an RTL change**, the run directory holds the counterexample
(`engine_0/trace.vcd`). The properties read only the internal names listed in section 2 and the
ports; a renamed state, beat counter, refill line, valid vector, owner or array instance, a
renamed state or owner constant, or a `cache_ram` without a single memory array stops the model
generation with a message.

---------------------------------------------------------------------------------------------

## 9. Files

| Path | Contents |
|---|---|
| `run.sh` | Driver: models, ladders, covers, controls, summary and verdict |
| `scripts/props.sh` | The bounded properties: their configurations, depths, `.sby` files and models |
| `scripts/model.py` | Copies the sources, applies a mutant, inserts and checks the include lines, runs sv2v, reads the mask and the snoop connection of `rtl/mcu.sv`, checks the base copies |
| `scripts/ladder.sh` | The fallback ladder of one property in one configuration |
| `scripts/control.sh` | One negative control |
| `scripts/sim.sh`, `scripts/simtb.py` | The random simulation of the ladder's last step |
| `harness/cache_top.sv`, `cache_pair_top.sv`, `icache_top.sv`, `arbiter_top.sv`, `interconnect_top.sv` | The harnesses |
| `harness/config.svh`, `env_common.svh`, `env_data.svh`, `env_memory.svh` | Configurations and environment |
| `props/cache_props.vh` | The properties, covers and induction helpers of the I-cache and the arbiter |
| `props/pair_props.vh` | Non-interference |
| `props/interconnect_props.vh` | The interconnect properties |
| `props/observe_icache.svh`, `observe_arbiter.svh`, `observe_ram.vh.in` | The observers inserted into the copies of the RTL |
| `sby/cache.sby` | The bounded proofs, per property and configuration |
| `sby/pair.sby`, `cover.sby`, `split.sby`, `induction.sby`, `interconnect.sby` | Non-interference, covers, the decomposed harness, k-induction, the interconnect |
| `mutants.txt` | The negative controls |
| `wishbone_interconnect_base.sv` | The base commit's `lib/wishbone/wishbone_interconnect.sv` with only its module name changed |
| `harness/memsys_top.sv`, `memsys_pair_top.sv`, `dcache_top.sv`, `arbiter_id_top.sv`, `arbiter_equiv_top.sv` | The harnesses of section 10 |
| `harness/config_memsys.svh`, `env_ddata.svh` | The bounds with both caches; the data requests at the D-cache's CPU port |
| `props/dcache_props.vh`, `dpair_props.vh`, `equiv_props.vh` | The properties, covers and induction helpers of section 10; non-interference with both caches; the arbiter's equivalence |
| `props/observe_dcache.svh` | The observer inserted into the copy of `rtl/cache/dcache.sv` |
| `sby/memsys.sby`, `memsys_cover.sby`, `memsys_pair.sby`, `dsplit.sby`, `dinduction.sby`, `arbiter_equiv.sby` | The bounded proofs, covers, non-interference, decomposed harness, k-induction and equivalence of section 10 |
| `mem_arbiter_base.sv` | The base commit's `rtl/cache/mem_arbiter.sv` with only its module name changed |

---------------------------------------------------------------------------------------------

## 10. The memory system with both caches

The D-cache (`rtl/cache/dcache.sv`: direct-mapped, write-through, no write-allocate, interconnect
slave 0) adds a harness with both caches, the arbiter and a tiny memory, the D-cache's own
properties, the I-cache's properties again with the D-cache's stores writing memory, and the
arbiter's equivalence with the base commit's arbiter when its new input `data_cont` is 0. They run
in `make formal-cache` with everything above; `run.sh` reports them under the names below.

### 10.1 What is proven

Bounded proofs in three configurations (10.4): tasks `<name>_tiny`, `<name>_nowait` and
`<name>_second` of `sby/memsys.sby`.

| Name | Property | Configurations |
|---|---|---|
| `load_data` | A load `ack` delivers memory's word of the presented address as it was at the start of the cycle: the last value written there (for the tracked address). | tiny, second |
| `dline_data` | A valid D-line holding the tracked address (valid with its tag) equals memory, lane by lane. | tiny, second |
| `store_mem` | At the edge of each accepted store (`st_accept`) memory holds the store's `sel` lanes; exactly one memory write is answered per acknowledged store, in the same cycle, with the store's address, `sel` and data; no other write. The D-cache acknowledges a store exactly in its `st_accept` cycles. | tiny, nowait, second |
| `id_refill_no_write` | No memory write from an I-refill's first grant through its last beat, unless a reset comes in between, with the D-cache's stores and D-refills on the data side. | tiny |
| `dfill_kept` | A granted D-refill keeps the port to its last beat (unless a reset comes in between); a continuing data beat (`data_cont`) is always granted; the D-cache requests a read in every refill cycle and tags exactly beats 1 to `LINE_WORDS - 1` as continuing; the memory port's tag is `gi && irefill_cont \|\| gd && data_cont`. | tiny |
| `dbound` | Bounded response: (a) a request at the D-cache's CPU port is answered by cycle `R + max(R + 1, WR)` of its interval; (c) a granted I-refill's last beat by cycle `R` of its grant; (e) a D-refill is granted by cycle `R` of its refill; (f) a granted D-refill's last beat by cycle `R` of its grant. | tiny, nowait |
| `dbound_cpu` | With the data side of a CPU (10.3): (b) an I-refill is granted by cycle `max(K_OLDER * (WR + 1), R + 1)` of its wait, counted from its first refill cycle. | tiny, nowait, second |
| `dack_req` | The D-cache answers `ack` only with `cyc && stb`, never `err`, and no `ack` in `REFILL`. | tiny (free mode) |
| `dwindow` | Every memory-side request of the D-cache (refill beats and stores) lies inside the window. | tiny (free mode) |
| `drefill_stable` | The D-cache's memory-side request (address, `we`, `sel`, write data, continuation tag) does not change until it is answered, unless a reset comes in between: a refill beat's in any case, a store's while the CPU holds the store. | tiny (free mode) |
| `dreset_state` | In the cycle after a reset cycle no D valid bit is set and the D-cache is in `LOOKUP` with `beat == 0`; its state register is two bits wide. | tiny, nowait, second |
| `ddata_indep` | Non-interference: two copies of both caches and the arbiter with equal inputs except data values (memory's read data, the write data of the CPU's stores, the initial contents of the data arrays) produce equal `ack` and `err` on every port, equal request control signals of the memory port and of both caches' memory ports, equal continuation tags, equal grants and the 21 equal events. | tiny |
| `id_fetch_data` | `fetch_data` (section 1) with the D-cache's stores writing memory. | tiny |
| `id_store_fetch` | `store_fetch` (section 1) with the stores acknowledged at slave 0 by the D-cache. | tiny |
| `arb_equiv` | The arbiter of the tree with `data_cont` tied to 0 and the base commit's arbiter (`mem_arbiter_base.sv`), with the same free inputs from a common reset, have equal outputs (memory request, continuation tag, both sides' answers, events) and the same owner in every cycle. Unbounded, by induction. | - |

`R`, `WR`, `K_OLDER` as in 10.4. A grant in `dfill_kept`, `dbound`, `dbound_cpu` and
`id_refill_no_write` is the grant that the arbiter gives, as its grant events show it.

### 10.2 The harnesses

| Harness | Modules | Used for |
|---|---|---|
| `memsys_top.sv` | `icache`, `dcache` and `mem_arbiter`, connected as the branch of `rtl/mcu.sv` with both caches connects them (slave 0 to the D-cache's CPU port, the D-cache's memory port and `mem_cont` to the arbiter's data side and `data_cont`, the snoop on slave 0's acknowledged stores), and the memory of `env_memory.svh` | every bounded property but `ddata_indep`; the covers |
| `memsys_pair_top.sv` | two copies of all three | `ddata_indep` |
| `dcache_top.sv` | `dcache` alone; an abstract port grants its requests in free cycles, holds a grant until the answer and answers it | the k-induction attempt; the D-cache's share in the decomposed step of the ladder |
| `arbiter_id_top.sv` | `mem_arbiter` alone, with the I-side refill master of `arbiter_top.sv` and a data-side master that issues single transfers or refill blocks tagged with `data_cont` | the arbiter's share in the decomposed step |
| `arbiter_equiv_top.sv` | `mem_arbiter` of the tree and `mem_arbiter_base` | `arb_equiv` |

`scripts/model.py` inserts `props/observe_dcache.svh` before the final `endmodule` of its copy of
`rtl/cache/dcache.sv`, as for the I-cache (section 2). It reads the fixed names of the D-cache:
the states `LOOKUP` and `REFILL` of the two-bit register `state`, `beat`, `refill_line`, `valid`,
`present` and `st_accept`. The tag array (instance `tag_ram`) and the four 8-bit data lanes
(generate block `lane[0..3]`, each with one `cache_ram` instance `data_ram`) are read through the
wires `dcache.tag_ram.f_obs_words` and `dcache.lane[k].data_ram.f_obs_words`. It also copies
`mem_arbiter_base.sv` with the arbiter's observer inserted; `run.sh` checks that file against
`git show <commit>:rtl/cache/mem_arbiter.sv` with the module name changed (`--arb-base`, default
3c15c40) when the repository has that commit.

### 10.3 Environment

As section 3, with these differences:

- **Data side at the D-cache's CPU port** (`env_ddata.svh`): as section 3's data side, at the
  D-cache's CPU port: a request in the window, held until it is answered or a reset drops it,
  one at a time (a new request at the earliest in the cycle after the previous answer), `cyc`
  free between requests. **Free mode** (`dack_req`, `dwindow`, `drefill_stable`): nothing is held,
  the request is a free choice in every cycle; it allows every sequence of the held mode and more,
  in particular requests that change while the D-cache refills, the only way to reach a request
  for another line in `REFILL` (`data-ack-in-refill`, `data-refill-follows-cpu-adr`).
- **Memory** (`env_memory.svh`): unchanged, so a read of the tracked address returns the last
  value written there and a write answered there updates it by its `sel` lanes; with the macro
  `FCACHE_WRITE_NOWAIT` (configuration `nowait`) every write is answered in its first cycle and
  reads keep 0 to 2 wait cycles. Only the D-cache writes memory; the I-cache only reads.
- **The data side of a CPU** (`dbound_cpu` only): after an I-miss, only the older instructions
  can still access data: from the I-miss cycle up to the I-refill's first grant at most `K_OLDER =
  3` CPU data requests are served, at most two of them started after the I-miss cycle. The
  harness counts the requests that start at the D-cache's CPU port in I-refill cycles before
  that grant and starts no new request once two have started. With the one-at-a-time rule this
  is also "the load in the Memory stage is presented in the I-miss cycle or never": a load that
  misses there makes both caches miss in one cycle, its D-refill wins the port for `R` cycles and
  its second lookup frees it, so the I-refill is granted in cycle `R + 1`.

### 10.4 Configurations and bounds

Both caches have the sizes, lines and window of the configuration (section 2). `R` is the
longest a granted refill takes (every beat a read of at most `F_MAX_WAIT` wait cycles), `WR` the
longest wait of a write (`harness/config_memsys.svh`).

| Configuration | Sizes, lines, window | Waits | `R` | `WR` | (a) | (b) | Binding term of (b) | Depth |
|---|---|---|---|---|---|---|---|---|
| tiny | 16 bytes each, 8-byte lines, window words 8 to 15 | reads and writes 0 to 2 | 6 | 2 | 13 | 9 | `K_OLDER * (WR + 1)` = 9 > `R + 1` = 7 | 50 |
| nowait | as tiny, `FCACHE_WRITE_NOWAIT` | reads 0 to 2, writes 0 | 6 | 0 | 13 | 7 | `R + 1` = 7 > 3 | 50 |
| second | 32 bytes each, 16-byte lines, window words 16 to 31 | reads and writes 0 to 2 | 12 | 2 | 25 | 13 | `R + 1` = 13 > 9 | 30 |

`dbound_cpu` is proved in all three, so each term of the maximum in (b) is the binding one in at
least one proof, and a cover reaches it exactly (10.7).

### 10.5 Depths and the fallback ladder

The stated depths are 50 (tiny, nowait) and 30 (second). Minimum depths: 40 for `load_data`,
`dline_data`, `id_fetch_data` and `id_store_fetch`, 20 for `dreset_state`, 25 for the others (in
the second configuration at most 30). The ladder is that of section 4. Its decomposed step uses
`sby/dsplit.sby`: the D-cache's share on `dcache_top.sv` (`load_data`, `dline_data`, `store_mem`,
`dfill_kept`, `dack_req`, `dwindow`, `drefill_stable`, `dreset_state`), the I-cache's share on
`icache_top.sv` (`id_fetch_data`, `id_store_fetch`: the shares of `fetch_data` and `store_fetch`,
whose free stores include the D-cache's) and the arbiter's share on `arbiter_id_top.sv`
(`store_mem`, `id_refill_no_write`, `dfill_kept`); `dbound`, `dbound_cpu` and `ddata_indep` have
no decomposed harness and skip that step. `arb_equiv` is proved by induction with each engine in
turn; its fallback is a bounded check to depth 50.

`load_data` is checked together with its lemma, the D-line invariant of `dline_data`, asserted
in the same task: bounded model checking assumes the assertions of the earlier steps when it
checks a step, which spares the solver the history of the line. The lemma is asserted, never
assumed, so it can make the task fail but never hide a failure; a control's line in
`controls.txt` names the assertion that failed.

### 10.6 Negative controls

Each property must fail, where it was proved in the tiny configuration, on each of its controls
(the mutants of the repository's cache mutation campaign, `mutants.txt`):

| Property | Negative controls |
|---|---|
| `load_data` | `drop-lane-enable`, `valid-on-store-miss`, `ignore-valid-data`, `forward-memory-ack`, `data-refill-word-off-by-one` |
| `dline_data` | `drop-lane-enable`, `valid-on-store-miss`, `data-refill-word-off-by-one`, `store-writes-all-lanes`, `store-hit-ignores-tag` |
| `store_mem` | `store-hit-skips-memory`, `forward-memory-ack` |
| `id_refill_no_write` | `grant-free-between-beats` |
| `dfill_kept` | `data-refill-gap`, `refill-beats-continuing-data`, `data-cont-on-first-beat`, `data-cont-ignored` |
| `dbound` | `data-refill-gap`, `refill-beats-continuing-data` |
| `dbound_cpu` | `i-side-starved` |
| `dack_req` | `forward-memory-ack`, `data-ack-in-refill` |
| `dwindow`, `drefill_stable` | `data-refill-follows-cpu-adr` |
| `dreset_state` | `data-reset-keeps-state`, `data-reset-keeps-valid` |
| `ddata_indep` | `data-dependent-store-hit` |
| `id_fetch_data` | `no-snoop`, `no-second-lookup` |
| `id_store_fetch` | `no-snoop` |
| `arb_equiv` | `data-always-continues` |

`data-cont-ignored` (the arbiter's tag ignores `data_cont`) changes no timing in this memory,
whose refill cost `R` counts every beat at the longest wait (it has no burst mode); `dbound`
cannot see it, and `dfill_kept`'s check of the memory port's tag does.

### 10.7 Covers

Each must be reached (`sby/memsys_cover.sby`, `memsys_pair.sby`, `arbiter_equiv.sby`). In the
tiny and the second configuration: a D-refill completes; a store hit and a store miss; a load hit
while an I-refill holds the port; both caches miss in the same cycle; an I-miss during a D-refill;
a reset during a D-refill beat and while a store waits for its answer; bound (a) reached exactly
by a load; bounds (c), (e) and (f) reached exactly; and the trigger of each property (the tracked
word loaded, the tracked D-line valid, a store to the tracked word, a store hit, a store waiting
behind an I-refill, a granted D-refill continuing, a D request waiting, a fetch of the tracked
word, also after a store to it). In the second configuration also: a load misses while an
I-refill holds the port, is answered, and a later load hits the same line, within depth 30. With
the data side of a CPU, in each configuration: the I-miss and the load's miss in the same cycle
with the I-refill granted in cycle `R + 1` exactly; in the tiny configuration also bound (b)
reached exactly by `K_OLDER` stores. For the pair: both caches' refills, a store hit and a load
answered from the arrays. For the equivalence: a data transfer, then a continuing refill beat.

### 10.8 k-induction on the D-cache alone

`sby/dinduction.sby` attempts unbounded proofs of `load_data` and of `dline_data` on the D-cache
alone (`dcache_top.sv`, memory side abstract), one task each per configuration, each time-boxed
(`--dind-limit`, default 4 hours), with helper invariants (`INDUCTION` in
`props/dcache_props.vh`): exactly one of the two named states and `beat == 0` outside a refill;
the line being refilled lies in the window and its set's valid bit is clear; the words of the
tracked line that the current refill has already written are memory's; the D-line invariant;
the CPU's held request lies in the window; every valid D-line holds the tag of a line inside the
window. The outcome and the time are
reported (class `AUX`), not required.

### 10.9 Results

`run.sh` writes the outcome table of every run to `SUMMARY.txt`; the table of the run on the
tree with the D-cache is to be pasted here, with the depth, step, engine and time of each
property, as in section 7.
