[HaDes-V+](../README.md) · [Docs](README.md) · [Building](BUILDING.md) · [FreeRTOS](FREERTOS.md) · [Shell](SHELL.md) · [Apps](APPS.md) · [Architecture](ARCHITECTURE.md) · [Extensions](EXTENSIONS.md) · [Verification](VERIFICATION.md) · **Caches**

# Caches (Simulation Only)

This document describes the two caches that the simulators can be built with, an instruction cache and, together with it, a data cache: where they sit, how they behave cycle by cycle, how they stay coherent with stores, how they share the RAM's one memory port, how to build and run a cached simulator, what the simulator prints, how the caches are checked, what is not built, and the rules that any later use of the design must keep.

**The caches exist only in the simulators.** The standard build, every simulator without the options below and the Basys 3 bitstream have no cache: `make synthesis` reads `rtl/*.sv`, which does not include `rtl/cache/`, the cached wiring of [rtl/mcu.sv](../rtl/mcu.sv) is selected by a Verilator define that synthesis never sets, and the Makefile refuses `make synthesis` together with any simulator option. Nothing in this document describes the hardware on the board. The results of the cached configurations (cycles per instruction, miss rates, run times) are not published; this document quotes none.

**Contents**

1. [Overview](#overview)
2. [The Instruction Cache](#the-instruction-cache)
3. [The Data Cache](#the-data-cache)
4. [Coherence: Snooping, FENCE and FENCE.I](#coherence-snooping-fence-and-fencei)
5. [Reset, Interrupts and Traps](#reset-interrupts-and-traps)
6. [One Memory Port and the Arbiter](#one-memory-port-and-the-arbiter)
7. [Building and Running a Cached Simulator](#building-and-running-a-cached-simulator)
8. [What the Simulator Prints](#what-the-simulator-prints)
9. [Events and the Counter Work](#events-and-the-counter-work)
10. [Legality Checks and Run-Time Assertions](#legality-checks-and-run-time-assertions)
11. [Verification and How to Re-Run It](#verification-and-how-to-re-run-it)
12. [What Is Not Built](#what-is-not-built)
13. [Limits and Rules for Later Use](#limits-and-rules-for-later-use)

## Overview

```
     HaDes-V+ (cpu) or golden CPU (ref_cpu), unchanged
         fetch_bus (CPU side)                 mem_bus (CPU side)
              |                                     |
           icache  <-- snoop: store acks at slave 0 |
              | refill port (+ continuation tag)    |
              |                           wishbone_interconnect  (TIMEOUT_EXEMPT bit 0 = 1)
              |                           slave 0 (RAM window)   slaves 1-8: I/O, unchanged
              |                                |
              |                           dcache  (only with DCACHE; without it slave 0
              |                                |   is the arbiter's data side itself)
              |                                | refill reads and store writes (+ continuation tag)
              +-----------> mem_arbiter <------+
                                | memory port (+ continuation tag)
                         slow_memory (PORT "memory", simulation only)
                                |
                     wishbone_ram port A        (port B idle)
```

- **Placement.** The caches are outside both CPUs. The instruction cache sits on the fetch bus between a CPU and the RAM, in [rtl/mcu.sv](../rtl/mcu.sv), under `` `ifdef HADES_ICACHE_BYTES ``. The data cache, when the simulator is built with one (`DCACHE=<bytes>`, which needs the instruction cache as well), is the RAM's port of the data-bus interconnect, slave 0, under `` `ifdef HADES_DCACHE_BYTES `` inside that branch. The CPU-side buses `fetch_bus` and `mem_bus` are the ones of the standard build, so every monitor of [sim/top.sv](../sim/top.sv) (the trace, the scoreboard, the bus hash, the test device) keeps working on the CPU side, and the caches work with HaDes-V+ and with the golden CPU alike. No CPU file is changed.
- **Split.** The instruction cache caches instruction fetches. Without a data cache the data side passes through uncached: every load and store to the RAM reaches the RAM as it does without a cache, once and unchanged. With a data cache, loads from the RAM window are cached, stores go through to the RAM unchanged, and nothing else is cached: I/O accesses are not cached and never use the memory port.
- **One memory port.** The standard RAM is a dual-port block RAM, one port per CPU bus. In the cached configuration a hit needs no RAM access, and a refill and a data access are the only two things that can want the RAM, so there is one memory port that [rtl/cache/mem_arbiter.sv](../rtl/cache/mem_arbiter.sv) shares between the data side and the instruction cache's refills. The data side is interconnect slave 0 itself, or with a data cache the data cache's memory port, which carries its refill reads and its store writes. Port B of the RAM is idle. The port goes through one instance of [sim/slow_memory.sv](../sim/slow_memory.sv) (`PORT "memory"`), which gives the memory its latencies and, in burst mode, the cheaper further beats of a refill.
- **Files.** `rtl/cache/icache.sv` (the instruction cache), `rtl/cache/dcache.sv` (the data cache), `rtl/cache/cache_ram.sv` (the arrays of both behind a small wrapper), `rtl/cache/mem_arbiter.sv`, and the changed [sim/slow_memory.sv](../sim/slow_memory.sv), [lib/wishbone/wishbone_interconnect.sv](../lib/wishbone/wishbone_interconnect.sv) and `rtl/mcu.sv`. The header comment of each file describes its part.

## The Instruction Cache

**Organisation.** Direct-mapped, with full tags and one valid flip-flop per line. The sizes of the configurations that are checked are 512 bytes and 8 KiB with 16-byte lines; `ICACHE` accepts any power of two of at least two lines and `LINE` accepts 8, 16, 32 and 64 bytes (the legal values are in [the options](#the-options)). For a word address `a` (the bus address, a byte address shifted right by two), with `O = log2(words per line)`, `I = log2(lines)` and `T = 30 - I - O`:

| Field | Bits of `a` |
|---|---|
| Word in the line | `a[O-1:0]` |
| Index | `a[O+I-1:O]` |
| Tag | `a[29:O+I]`, stored in full |

| Configuration | O | I | T | Tag | Index | Valid flip-flops |
|---|---|---|---|---|---|---|
| 512 bytes, 16-byte lines | 2 | 5 | 23 | `adr[29:7]` | `adr[6:2]` | 32 |
| 8 KiB, 16-byte lines | 2 | 9 | 19 | `adr[29:11]` | `adr[10:2]` | 512 |

A hit also requires `adr[31:30] == 0`, which the tag array does not store, so the compare covers the whole word address. The tag array and the data array are read within the cycle (asynchronously), and the data array's word reaches the fetch bus's `dat_miso` without any logic in between. The valid bits are flip-flops in `icache`, not part of the arrays.

**The answer rule.** In every cycle with `cyc && stb` on the fetch bus the cache answers `ack` if and only if the address presented in that cycle is valid in the cache (the line is valid and its tag equals the address's tag). The answer is computed from that address alone, never from a latched address or a stored flag. This matters because both CPUs may change the fetch address in any cycle (a jump, a branch, a trap, `mret`) while `cyc` and `stb` stay high, and a cache that answered for an address it had latched earlier would hand the CPU the wrong word. A repeated address that hits is acknowledged again; the cache never assumes that its `ack` was consumed. A hit does not wait for the memory port.

**Fetches outside the window.** The cacheable window is the RAM's window (word addresses `MEMORY_START` to `MEMORY_START + MEMORY_SIZE - 1`). A fetch outside it gets `err` and nothing else: it never hits, never starts a refill and changes no state, so a fetch of a wrong-path address outside the RAM does not reach the memory and the CPU turns the `err` into its usual fetch fault. The window check only produces `err`; whether an address hits is decided by the full tag compare. A cut-down tag compare would show as `ack` and `err` together for an out-of-window address that aliases a cached line; the trap-sweep family `window` probes exactly that ([test/memsys/README.md](../test/memsys/README.md#fetches-outside-the-ram-trap-sweep)).

**Miss, refill and the second lookup.** A fetch inside the window that does not hit is a miss. In that cycle the cache gives no answer and no request; at the end of it the line's valid bit is cleared, the line to refill is recorded and the cache enters `REFILL`. In `REFILL` the cache requests the line's words on the memory port, one block of reads starting at word 0 of the line, `cyc` held from the first cycle through the cycle of the last beat. Each answered beat is written to the data array; with the last beat the tag is written, the valid bit is set and the cache returns to `LOOKUP`. In `REFILL` the cache answers nothing on the fetch bus (no hit under a miss), whatever address is presented and however the CPU changes it: a started refill always completes (there is no abort on a redirect), unless a reset drops it. The first `LOOKUP` cycle after the last beat is an ordinary lookup of whatever address is presented then (the second lookup), so a refill costs one cycle more than its beats. A refill that ends while the CPU presents no address of the refilled line is counted as abandoned.

The memory cannot answer a refill with `err`: the window is aligned to whole lines and lies inside the RAM. If the memory ever does, the simulation stops with the cycle and the address.

**Initial contents.** In the simulators the tag and data arrays start with seeded pseudo-random contents (the tags are tags of lines inside the window, the data words are random), so that a cache that ignores its valid bits returns wrong words. The seed is `+mem_seed`. The valid bits are cleared by the reset at time 0. The arrays are not cleared by a reset.

## The Data Cache

The data cache is optional and exists only together with the instruction cache (`DCACHE=<bytes>` needs `ICACHE=<bytes>`; the two share the memory port and the line size). It is **direct-mapped, write-through, with no write-allocate and no write buffer**. It is `rtl/cache/dcache.sv`, and it takes the place of the RAM's port of the data-bus interconnect: the interconnect's slave 0 is the data cache's CPU port, and the data cache's memory port is the arbiter's data side.

**Organisation.** The address split, the full tags and the one valid flip-flop per line are those of [the instruction cache](#the-instruction-cache), with the same line size (`LINE`, shared by the two caches). The sizes of the configurations that are checked are 512 bytes and 4 KiB with 16-byte lines; `DCACHE` accepts any power of two of at least two lines.

| Configuration | O | I | T | Tag | Index | Valid flip-flops |
|---|---|---|---|---|---|---|
| 512 bytes, 16-byte lines | 2 | 5 | 23 | `adr[29:7]` | `adr[6:2]` | 32 |
| 4 KiB, 16-byte lines | 2 | 8 | 20 | `adr[29:10]` | `adr[9:2]` | 256 |

The tag array is the instruction cache's, without the snoop port. The data array is four arrays of 8 bits, one per byte lane, each with its own write enable, so that a store writes exactly the lanes its `sel` selects. All arrays are read within the cycle, and the four lanes' read data reach the CPU bus's `dat_miso` without any logic in between. A request is *present* if its set is valid and holds its tag (compared in full, `adr[29:O+I]`). A request outside the RAM window cannot occur, because the interconnect raises `stb` at slave 0 only for addresses inside it; the data cache asserts that it never sees one.

**I/O.** During every access to another slave the interconnect gives slave 0 `cyc` without `stb`, and the data cache then does nothing. I/O accesses are never cached, never reach the memory port and never wait for it.

**Loads.** In a cycle with a load request the data cache answers `ack` if and only if the address presented in that cycle is present, with the whole word of the four lanes; `sel` is ignored (the Memory stage selects the bytes). A load hit is answered in its own cycle **whatever the arbiter does**, for example while an instruction refill holds the memory port, and makes no memory request. As for the instruction cache, the answer depends only on the request presented in that cycle and on the state, and `err` is never produced.

A load that is not present is a miss. In that cycle the data cache gives no answer and no request; at the end of it the set's valid bit is cleared, the line to refill is recorded and the cache enters `REFILL`. In `REFILL` it requests the line's words on its memory port, one block of reads from word 0, `cyc` held through the block, with the continuation tag on beats 1 to the last. Each answered beat is written into all four lanes; the last also writes the tag and sets the valid bit, and the cache returns to `LOOKUP`. Nothing is answered in `REFILL`, and requests that arrive wait. The first `LOOKUP` cycle after the last beat looks up the presented request again (the second lookup): the CPU still holds its load and nothing can have invalidated the line, so it hits and is answered. A load that misses is therefore answered in the cycle after its last beat is answered, and a miss never starts a second refill.

**Stores.** A store is presented on the memory port in the same cycle in which it reaches the data cache, unchanged (`we`, address, `sel`, data), so with the arbiter's same-cycle grant a store takes as long as without a data cache. The cycle in which the memory answers it is the **store-accept cycle**. In that cycle the data cache answers the CPU, and if the store's line is present the lanes that `sel` selects take the store's bytes at the end of the cycle; the other lanes, the tag and the valid bits do not change. If the line is not present the data cache does not change at all: a store miss allocates nothing, so the next load of that line misses. Bytes of `dat_mosi` that `sel` does not select go to the memory unchanged, masked by `sel`, and never into the data cache.

There is no write buffer and no posted store: the CPU waits for each store's answer from the RAM, and the cycles in which a store waits are counted (`DC_STORE_WAIT`, [below](#events-and-the-counter-work)). **Every effect of a completed store depends on the store-accept condition alone**: the answer to the CPU, the lane write, the store events and, through the acknowledge at slave 0, the instruction cache's snoop. A write buffer would only have to redefine that one condition ([What Is Not Built](#what-is-not-built)).

**Initial contents.** As the instruction cache's: the window's tags per set and random data words, valid bits cleared by the reset at time 0, seeded by `+mem_seed` mixed with a constant of its own that differs from the instruction cache's.

## Coherence: Snooping, FENCE and FENCE.I

Instruction and data memory are one RAM and the program may write its own code, so a cached line must never differ from the RAM. **The instruction cache** is kept coherent by **snooping**: at the end of every cycle in which a store is acknowledged at interconnect slave 0 (the RAM window of the data bus), the cache reads the tag of the stored-to word's set through a second read port of the tag array, and if that line is valid with an equal tag, it clears the valid bit. Whichever bytes the store writes, the whole line is invalidated. A snoop never writes an array and never sets a valid bit. The snoop is the same with a data cache: it still watches slave 0, where the store acknowledgements of an I+D build are the data cache's store-accept cycles, and in no other cycle.

The argument has three lines:

1. every valid line was filled while no write could reach the memory, because the arbiter never grants the data side inside a refill block;
2. every later store to a line clears it at the edge at which the store is acknowledged;
3. a refill reads the memory after every earlier store has been acknowledged and written.

Every store to the RAM passes slave 0 on both CPUs, there is one hart and no DMA, and the fetch port never writes, so the snoop sees every write to the RAM. (With a data cache the second line holds as well: a store waits at the data cache's memory port while an instruction refill holds the port, so no memory write happens inside a refill block either.)

**The data cache** needs no snoop, because it is write-through and its only writer is this CPU's data port, through the data cache itself: a store writes the memory and, if the line is present, the same bytes of the line at the same edge (the store-accept edge), and no store can be presented while a data refill runs, because the CPU makes one data request at a time. So every valid data line equals the memory at every clock edge. A line of code that the program also reads as data is therefore in both caches, and a store to it updates the data line (if present) and invalidates the instruction line; the program's `FENCE.I` then makes Fetch look the patched word up again.

Two cases show how this meets the pipeline. A fetch that hits the word of a line in the cycle in which a store to that line is acknowledged gets the old word, and the line is invalid from the next cycle, as a read beside a write of the same word returns the old word in the standard build. And the staleness window stays what it is without a cache: instructions fetched in or before the cycle of a store may be stale, and while a store is in Memory, Fetch is at most three instructions ahead. A cache can only shrink the window: a slot whose word is fetched after the store, because its line missed, runs the new word.

**`FENCE` and `FENCE.I`.** Both stay as they are. `FENCE` is a no-op: the caches add no store buffer, and a store is still acknowledged only after the RAM has written it, so every store is visible to the next access. `FENCE.I` stays the pipeline flush that [the Zifencei section of EXTENSIONS.md](EXTENSIONS.md#zifencei--instruction-fetch-synchronisation) describes: because the instruction cache snoops every store, the refetch after the flush finds either an invalidated line, which it refills from the updated RAM, or a line that no store has touched. There is no invalidate port, no flush of the data cache (it never holds a line that differs from the RAM), no memory-mapped invalidate-all and no cache-maintenance instruction.

## Reset, Interrupts and Traps

**Reset.** At the end of a cycle with `rst` high, every valid bit is cleared, each cache returns to `LOOKUP` with its beat counter at 0, and the arbiter releases the port; a refill or a data transfer in progress, of either cache, is dropped (the memory wrapper drops a held transfer too). The arrays keep their contents. Nothing acknowledged is lost: the RAM answers nothing while `rst` is high, a store is acknowledged only after the RAM has written it, a store that a reset drops was therefore never written and never acknowledged, and a dropped data request belongs to a CPU that is itself in reset. After a reset the first fetch, of the reset address, misses, and so does the first load of any line. The cache and the arbiter do not depend on the memory dropping a request at a reset: they ignore an answer that arrives without a grant. All events are 0 in cycles with `rst` high.

**Interrupts and traps.** The interrupt logic is unchanged. An interrupt is taken only when a non-bubble instruction is in Writeback, so a miss adds to the interrupt latency, as a divide does. A sequential interrupt decided while the next instruction's data access waits fires when that access ends, and that wait now includes waiting for the port behind a refill; with a data cache, a load that misses adds its miss cycle, its wait for the port, its own refill and its second lookup. A data request is never withdrawn (the CPU holds it, and slave 0 is exempt from the timeout), so an interrupt held for it fires after a completed access. If an interrupt, a trap or `mret` redirects Fetch during a refill, the refill completes and the handler's first word is looked up in the second-lookup cycle, where it may miss in turn. A cache slows only RAM accesses, which never clear an interrupt cause, so I/O keeps its latency. `+irq_latency` measures the latency of every interrupt ([below](#testbench-options)).

**The timeout exemption.** The interconnect ends a bus access that has had no answer for 255 cycles with `err`. With one port shared by refills and data accesses, a RAM access can legitimately wait longer than that behind a refill block. The cached configuration therefore passes `TIMEOUT_EXEMPT = 9'b0_0000_0001` to the interconnect (with or without a data cache): the timeout counter does not count while slave 0 (the RAM, or with a data cache its cache) is selected, so a RAM access is never ended with `err` however long it waits, and every I/O slave keeps its 255-cycle timeout. The parameter defaults to all zeros, which is the interconnect of the standard build (the equivalence is proved, see [Verification](#verification-and-how-to-re-run-it)); the standard and the slow-memory branches of `rtl/mcu.sv` pass no mask. In its place the simulator checks that every request is answered within a bound that follows from the memory's latencies ([below](#legality-checks-and-run-time-assertions)), and the check of [sim/top.sv](../sim/top.sv) that stops a run when the interconnect times out on a RAM access stays, so it fires only if the exemption is broken.

## One Memory Port and the Arbiter

The arbiter has two requesters: the data side and the instruction cache's refill port. The data side is interconnect slave 0, which raises `stb` only for RAM-window addresses, so an I/O access never asks for the port; with a data cache it is the data cache's memory port, which presents its refill blocks and its stores (a load hit asks for nothing). Its rules:

- **Data first.** On a free port a data request is granted in the cycle it is made; the instruction cache is granted only if the data side does not request in that cycle. The grant is combinational, so an uncached data access, or a store, on an idle port takes exactly as long as without the arbiter.
- **A grant is never taken away.** A data grant lasts until its transfer is answered, an instruction refill grant until its block ends, which is the first cycle in which the cache does not request (the port is free in that cycle). There is no fairness state.
- **A data refill block is not interrupted either.** The data cache requests the beats of its refill in consecutive cycles, each beat a data transfer of its own; after each answered beat the port is free, and the next beat, requested in the next cycle, is granted at once because the data side goes first. The data cache tags beats 1 to the last with `data_cont`, an input of the arbiter without a default value (a build without a data cache ties it to 0), and an assertion stops the simulation if a continuing data beat is not granted.
- **Pass-through.** The granted side's request reaches the memory unchanged and once; the answer returns to that side only, and the other side sees `ack = err = 0`. Data transfers are never widened, split, repeated or reordered. An idle port is all zeros.
- **No write inside an instruction refill block.** It follows from the rules above (a store waits for the port, as every data request does) and is checked in simulation and proved. The data cache's refill blocks contain no write either.
- **Hits use no port.** An instruction hit is answered during a data refill or a store, and a data load hit during an instruction refill.
- **No assumption about the memory.** An answer in a cycle with no grant reaches no side and stops the simulation. The memory side is a plain Wishbone block port plus one simulation-only tag, so a register slice or an adapter could be added there without touching the state machines.

**Both caches refill.** If both refills request on a free port, the data refill wins. A fetch miss while a data refill runs waits for the data cache's second-lookup cycle, in which it does not request, and a data miss while an instruction refill runs waits for the instruction cache's. The worst case is a load that misses in the very cycle in which the instruction fetch misses (likely, because Fetch runs ahead): neither cache requests in that cycle, from the next cycle both request, the data refill is granted and holds the port for its whole block, the instruction refill waits, and the data cache's second lookup, in which it does not request, frees the port.

The bounds that follow, without a data cache: a data request waits at most for the rest of one refill block; a refill waits at most for three data transfers. Three, because once the cache is in `REFILL` no `ack` lets a new instruction enter, and only the at most three older instructions held in the output registers of Fetch, Decode and Execute can still make a data request, one each. With a data cache the bounds are those of [the bounded answers](#legality-checks-and-run-time-assertions): the instruction refill waits for three stores or for the coincident data refill, whichever is longer.

**Burst mode.** `slow_memory` normally charges every transfer a latency drawn from its range. With a beat latency (`MEM_BEAT_LAT`, or `+mem_beat_lat`) a transfer costs the beat latency instead if it is a read of the next word, `cyc` has been held since the previous answer, and the master marks it as continuing its block. In the cached configuration the mark is the continuation tag, which a cache raises for beats 1 to the last of a refill and the arbiter passes on only while that cache is granted (`irefill_cont` with the instruction cache, `data_cont` with the data cache). So only the further beats of a refill get the cheap beat, of either cache, never a single data transfer, even if two loads of consecutive words come back to back: a DRAM adapter turns lines, not single words, into bursts. The wrapper stops the simulation if the tag is set for a transfer that does not continue a read block, so a wrong tag cannot give a silent discount. Without burst mode a refill, of either cache, costs `LINE_WORDS * (L + 1)` cycles for latencies `L` drawn per beat; with a beat latency `b` it costs `(L + 1) + (LINE_WORDS - 1) * (b + 1)`. A transfer of latency `L` takes `L + 1` cycles.

## Building and Running a Cached Simulator

### The options

Three options of any make target that builds a simulator, next to the memory options of [test/memsys/README.md](../test/memsys/README.md#simulator-configurations); `make help` lists them.

| Option | Values | Meaning |
|---|---|---|
| `ICACHE=<bytes>` | `0` or unset: no cache. Otherwise a decimal number without sign or leading zero that is a power of two of at least two lines (32 with 16-byte lines) | Builds the cached configuration: the slow-memory configuration (latency 0 unless `MEM_LAT=...` and the other memory options say otherwise), an instruction cache of that size, one memory port, and the RAM exempt from the interconnect timeout |
| `DCACHE=<bytes>` | `0` or unset: no data cache. Otherwise the same rule as `ICACHE`: a decimal number without sign or leading zero that is a power of two of at least two lines. Only together with a non-zero `ICACHE` | Adds a data cache of that size to the cached configuration: direct-mapped, write-through, no write-allocate, no write buffer, as the RAM's port of the data bus; its refills and its stores use the one memory port. The sizes that are checked in full are 512 bytes next to an instruction cache of 512 bytes, and 4096 next to 8192 |
| `LINE=<bytes>` | 8, 16, 32 or 64; default 16; only together with a non-zero `ICACHE` | The line size, of both caches |

Refused, each with a message that names the option and the rule: `LINE` without a non-zero `ICACHE`; an illegal value of any of the three (`ICACHE` or `DCACHE` of `00512`, `+512`, `512.0` or `24`, or of less than two lines, such as `DCACHE=16` with 16-byte lines); a non-zero `DCACHE` without a non-zero `ICACHE` (unset, empty or `0`: "a D-cache needs an I-cache"), also when the options come from the environment as `HADES_DCACHE` and `HADES_ICACHE`; `MEM_ONLY` together with a cache (there is one memory port); `make synthesis` together with any simulator option. `DCACHE=0` is accepted with or without `ICACHE`, and means no data cache. A plain `DCACHE` in the environment is ignored, like every option (only the `HADES_` names count). The data port's limit of 254 cycles of latency applies only without a cache.

```bash
make test/asm/ops ICACHE=512                          # cache of 512 bytes, memory at latency 0
make test/memsys/stores ICACHE=512 MEM_LAT=2          # every memory transfer waits 2 cycles
make freertos APP=minimal ICACHE=8192 MEM_LAT=1:8     # 8 KiB, random latencies, the automatic tick
make freertos-shell ICACHE=512 MEM_LAT=2              # the shell on a cached core
make test/memsys/dcache ICACHE=512 DCACHE=512 MEM_LAT=2   # with a data cache as well
make freertos APP=minimal ICACHE=8192 DCACHE=4096 MEM_LAT=8:24 MEM_WR_LAT=1:4 MEM_BEAT_LAT=0   # 8 KiB and 4 KiB
make sim-config ICACHE=512 MEM_LAT=1:8 MEM_SEED=2     # name, build directory and environment of a configuration
python3 test/memsys/programs.py run ICACHE=512 DCACHE=512 MEM_LAT=2
```

The configuration's name has the parts `i<size>` (bytes below 1024, otherwise `<n>k`), `d<size>` (only with a data cache, in the same notation) and `l<line>` after the memory parts, and its simulators are built in `build/cfg-<name>`, so they never mix with the standard simulators or those of another configuration. Examples: `ICACHE=512` is `mem0-i512-l16`; `ICACHE=512 MEM_LAT=1:8 MEM_SEED=2` is `mem1_8-seed2-i512-l16`; `ICACHE=8192 MEM_LAT=8:24 MEM_WR_LAT=1:4 MEM_BEAT_LAT=0` is `mem8_24-wr1_4-beat0-i8k-l16`; with a data cache, `ICACHE=512 DCACHE=512` is `mem0-i512-d512-l16` and `ICACHE=8192 DCACHE=4096 MEM_LAT=8:24 MEM_WR_LAT=1:4 MEM_BEAT_LAT=0` is `mem8_24-wr1_4-beat0-i8k-d4k-l16`. The names of configurations without a data cache are as they were. Scripts that build their own simulators get the options as the environment variables `HADES_ICACHE`, `HADES_DCACHE` and `HADES_LINE` (`make sim-config` prints them). `ICACHE=0` is the same as no cache. `make sim-config` and `make help` show the description, which for a data cache says `D-cache <size> bytes, write-through, no write-allocate`.

### Latency profiles

The memory behind the cache is configured with the memory options (`MEM_LAT`, `MEM_WR_LAT`, `MEM_BEAT_LAT`, `MEM_SEED`), which in a cached configuration set the one memory port's latencies; the port has its own latency sequence, seeded by `MEM_SEED`. [test/memsys/matrix.py](../test/memsys/matrix.py) names the profiles it uses: `lat0` (no memory option), `lat2` (`MEM_LAT=2`), `rand1` to `rand3` (`MEM_LAT=1:8` with seeds 1 to 3), `burst` (`MEM_LAT=1:8 MEM_BEAT_LAT=0`), `stress` (`MEM_LAT=1:64`, beyond the interconnect timeout without the exemption) and `dram` (`MEM_LAT=8:24 MEM_WR_LAT=1:4 MEM_BEAT_LAT=0`, for measurements). `MEM_BEAT_LAT=0` is the fastest burst: one cycle per further beat.

### Run-time options

The options are compiled in as the simulator's defaults; these run-time options (`SIM_ARGS='+...'` through make, or on the simulator's command line) override them. The options of [sim/slow_memory.sv](../sim/slow_memory.sv) are described in [test/memsys/README.md](../test/memsys/README.md#simulator-configurations).

| Option | Meaning |
|---|---|
| `+mem_lat`, `+mem_rd_lat`, `+mem_wr_lat`, `+mem_beat_lat`, `+mem_seed` | Latencies of the one memory port; `+mem_seed` also seeds the random initial arrays of the caches |
| `+mem_only` | Refused in a cached simulator (one port) |
| `+timeout=<cycles>` | The cycle limit of the run; without it the cached default applies ([below](#the-default-cycle-limit)) |
| `+cache_stats`, `+nocache_stats` | The `CACHE_STATS` line at the end of the run; on by default in a cached simulator |
| `+cache_stats_marks` | Also a `CACHE_STATS_MARK` line (`i_done`, `i_abandoned`, `snoop_inval` so far) at every report of the program (`Test pass!` / `Test fail!`), to attribute counts to the parts of a test |
| `+reset_at=<cycle>[,<cycle>...]` | Resets in the middle of the run ([below](#testbench-options)) |
| `+cache_phase_log=<file>` | One byte per cycle with the state of the caches and of the data side, for placing resets |
| `+ram_words=<byte address>[,...]` | At the end, one `RAM_WORDS` line with these RAM words |
| `+retired_every=<n>` | A `RETIRED_AT` line each time HaDes-V+ has retired another n instructions |
| `+irq_latency` | The `IRQLAT` line at the end of the run |
| `+scoreboard`, `+bushash`, `+retired`, `+nodump`, `+trace` | Unchanged; the scoreboard and `RETIRED` are on by default because the configuration has a slow memory |

### The default cycle limit

Without `+timeout`, a cached simulator multiplies the default limit of 100000 cycles by `1 + max(R, D)`, where `R` is the number of cycles the longest granted refill can take and `D` the number of cycles the longest granted data transfer can take, from the memory's configured maxima: with `RD` and `WR` the longest read and write latency, `B` the beat latency in burst mode (otherwise `RD`) and `n` the words per line,

```
D = max(RD, WR) + 1
R = (RD + 1) + (n - 1) * (B + 1)
```

A cached program is slowed by its misses, each of which costs a whole refill, not a single wait; this factor is never smaller than the one of an uncached slow memory and only delays the detection of a hang. A data cache changes neither `R` (its refills are blocks of the same line size) nor `D` (its stores are data transfers). The simulator prints the limit at its first clock edge:

```
SLOW MEMORY cycle limit <n>: 100000 times 1 + the longest refill or data transfer (<k> cycles); +timeout=<cycles> sets it
```

`programs.py` computes the same limit for its runs and passes `+timeout`; FreeRTOS runs do too, so their logs carry no such line. `make help` states the rule.

### FreeRTOS

FreeRTOS programs count their tick in clock cycles, so a slower memory makes the tasks slower against the tick. In every configuration with a slow memory, cached or not, `freertos.mk` sets the tick automatically, unless `TICK=` is given, and scales the programs' interrupt intervals and the cycle limit with it; with a cache the factor is one larger, because a miss costs a whole refill (a data cache changes nothing here). The rule, the programs it scales and the console pace of the shell with a cache are in [FREERTOS.md](FREERTOS.md#slow-memory-and-cached-configurations).

## What the Simulator Prints

A cached run prints, besides the usual lines:

- at time 0, the configuration line of the cached branch of `rtl/mcu.sv`, for example for 512 bytes with 16-byte lines:

  ```
  CACHE I-cache 512 bytes, 16-byte lines, 32 sets, direct-mapped; tag adr[29:7], index adr[6:2], word adr[1:0]; window 0x00040000-0x00047fff; random initial arrays, seed 1; one memory port, data side first; RAM exempt from the interconnect timeout
  ```

  and, in a build with a data cache, a second line after it (the first is unchanged):

  ```
  CACHE D-cache 512 bytes, 16-byte lines, 32 sets, direct-mapped, write-through, no write-allocate; tag adr[29:7], index adr[6:2], word adr[1:0]; window 0x00040000-0x00047fff; random initial arrays, seed 1
  ```

- the wrapper's line `SLOW MEMORY memory port: read latency <r>, write latency <w>, burst beats <b|off> (cache refill blocks only), seed <s>`;
- at the first clock edge, the `SLOW MEMORY cycle limit` line above (without `+timeout`);
- at the end of the run, the `SCOREBOARD`, `RETIRED` and `BUSHASH` lines as in any slow-memory simulator, and the `CACHE_STATS` line.

### CACHE_STATS

One line at the end of the run (`+nocache_stats` turns it off):

```
CACHE_STATS cycles=<n> i_hits=<n> i_refills=<n> i_done=<n> i_beats=<n> i_abandoned=<n> snoop_inval=<n> i_refill_cycles=<n> wait_i_for_port=<n> wait_d_for_port=<n> port_irefill=<n> port_data=<n> d_loads=<n> d_stores=<n> i_inflight=<0|1> i_inflight_beats=<n> i_inflight_port=<n> d_inflight=<0|1> d_inflight_port=<n>
```

In a build with a data cache the line continues with the fields of the data cache, in this order:

```
 dc_lookup_hits=<n> dc_load_misses=<n> dc_done=<n> dc_beats=<n> dc_store_hits=<n> dc_store_misses=<n> dc_store_wait=<n> dc_refill_cycles=<n> dc_inflight=<0|1> dc_inflight_beats=<n> dc_inflight_port=<n>
```

The lines of builds without a data cache are as they were. The counters count the cycles in which the events of [the next section](#events-and-the-counter-work) are 1; the key of each event is in that table. Every counter restarts at every reset, and `cycles` counts the cycles with `rst` low since the last reset. `RETIRED` and `BUSHASH` do not restart (they count from time 0), so `CACHE_STATS` and `RETIRED` cover the same cycles only in a run without a mid-run reset; everything that combines them (a miss rate, the identities below, `rtlcheck`) is taken only from runs without a `RESET` line.

**The state at the end.** A run stops at the test device's `$finish`, at an arbitrary point of Fetch's run-ahead, often in the middle of a refill. `i_inflight` is 1 if the cache is in `REFILL` after the last counted edge, and `i_inflight_beats` and `i_inflight_port` are the beats answered and the port cycles that refill has had; `d_inflight` is 1 if the arbiter's owner is the data side, and `d_inflight_port` the port cycles of that transfer. With a data cache `dc_inflight`, `dc_inflight_beats` and `dc_inflight_port` describe a data refill in the same way, and `d_inflight` then describes a store in flight only (the data side holds the port and the request is a write). They are states, not event counts, and they make the identities exact. A run that ends with the test device's halting store has `dc_inflight = 0`.

**Identities** that hold in every run without a reset:

```
i_refills        = i_done + i_inflight
i_refill_cycles  = wait_i_for_port + port_irefill
i_beats          = (words per line) * i_done + i_inflight_beats
```

and `i_hits`, `d_loads` and `d_stores` equal the fetches, loads and stores of the `SCOREBOARD` line, and `cycles` equals the cycles of the `RETIRED` line.

With a data cache the loads and stores of the `SCOREBOARD` line no longer pass the port one for one, so the identities of its side are these, again for every run without a reset in its middle:

```
dc_load_misses   = dc_done + dc_inflight
dc_beats         = (words per line) * dc_done + dc_inflight_beats
d_loads          = dc_beats
dc_lookup_hits   = the loads of the SCOREBOARD line
dc_store_hits + dc_store_misses = d_stores = the stores of the SCOREBOARD line
```

(`d_loads` counts the words read from the RAM, which are the data refills' beats; `d_stores` the stores written.) At a fixed latency without bursts also `port_data = (words per line) * (RD + 1) * dc_done + (WR + 1) * d_stores + dc_inflight_port + d_inflight_port`, with `RD` and `WR` the read and write latency.

**Interpretation.** `i_hits` counts every cycle in which the cache acknowledged a fetch, and the pipeline does not use all of them: Fetch repeats a lookup in `STALL` cycles and discards the answer in `JUMP` cycles. So `i_hits` over-counts the fetches that the pipeline consumed, and it is not a hit rate. The miss rate of the instruction side is taken as `i_done` per 1000 retired instructions (the `RETIRED` line), from a run without a reset. Not counted, because Fetch's status is inside the CPU: the cause of a refill (sequential, stalled, jump, flushed). **The data cache's counts.** `dc_lookup_hits` counts every load answered from the arrays, including the answer of a missed load at its second lookup, so it equals the number of RAM loads and is **not a count of load hits**: the load hits, the loads answered at their first lookup, are `dc_lookup_hits - dc_load_misses`, exact in a run without a reset in its middle and while no refill is in flight at the end. The load miss rate is `dc_load_misses` per 1000 retired instructions or per load, like the instruction side's `i_done`. `dc_store_hits` and `dc_store_misses` count stores by whether their line was present at the store-accept cycle; a store miss changes nothing in the cache. `dc_store_wait` counts the cycles in which the CPU waits for a store's answer, which is the cost that a write buffer would take away, and `dc_refill_cycles` the cycles in a data refill (waiting for the port or granted). The CPU's own events (stalls, flushes, branch outcomes) are counted by the performance counters ([EXTENSIONS.md](EXTENSIONS.md#hardware-performance-counters)).

### Testbench options

**`+reset_at=<c>[,<c>...]`** drives the reset button for exactly one cycle at each listed cycle of the testbench's cycle count, so that `rst` is high for one cycle three cycles later (two synchroniser stages and the `rst` flip-flop). The cycles are decimal, at least 1, strictly ascending and at least 2 apart (checked at time 0). It works in every slow-memory simulator, cached or not, on both CPUs. In the cycle in which `rst` is high a line is printed:

```
RESET at cycle <n> (+reset_at=<c>): I-cache <phase>, data side <phase>
```

The instruction cache's part is `idle`, `refill waiting for the port` or `refill beat <b> of <n>` (counted from 0); the data side's is `idle`, `RAM load waiting`, `RAM store waiting`, `I/O access waiting`, `granted (RAM load)` or `granted (RAM store)`. With a data cache a load is not sent to the port itself: `RAM load waiting` is then its miss cycle, `granted (RAM load)` does not occur, and while the data cache refills the load's line the data side reads `RAM load: refill waiting for the port` or `RAM load: refill beat <b> of <n>` (counted from 0); `RAM store waiting` and `granted (RAM store)` are a store waiting for the port or its answer and a store granted. The scoreboard keeps its copy of the memory across the reset (the RAM keeps its contents), skips the reset cycle and clears its request-stability state. After a mid-run restart a program may legitimately misbehave; its verdict is not judged, the scoreboard and the assertions are.

**`+cache_phase_log=<file>`** writes one byte per cycle from the first clock edge: bit 0 the cache is granted the port, bit 1 a refill waits for the port, bit 2 a data request on the CPU's data bus waits for its answer, bit 3 that request is a RAM access, bit 4 it is a write, bit 5 the data side is granted the port (with a data cache: a store or a data refill beat), bit 6 `rst`, bit 7 the data cache is in `REFILL` (0 without a data cache). A run with `+reset_at` is identical to the same run without it up to the reset, so a reset wanted in cycle `t` is requested with `+reset_at=<t-3>`.

**`+irq_latency`** (HaDes-V+ only) measures, for every interrupt the CPU takes, the cycles from the first cycle in which an interrupt is pending and enabled in Writeback to the first fetch `ack` after the interrupt's jump cycle, and prints `IRQLAT interrupts=<n> max=<cycles> mean=<cycles>` at the end. It is an observed maximum of the runs made, not a worst case. The monitor is checked against latencies derived by hand: `test/memsys/irqlat.s` and the matrix leg `irq-latency-validation` ([README](../test/memsys/README.md#directed-tests-with-caches)).

**`+ram_words=<byte address>[,...]`** prints `RAM_WORDS <address>=<value> ...` at the end, for word-aligned addresses inside the RAM (`irqchain.s` records its interrupt positions this way). **`+retired_every=<n>`** (HaDes-V+ only) prints `RETIRED_AT instructions=<i> cycles=<c>` each time `RETIRED`'s count reaches another multiple of n.

## Events and the Counter Work

The instruction cache and the arbiter expose thirteen one-bit **event** outputs, and the data cache eight more. Each is 1 exactly in the cycles in which its event happens, is 0 in cycles with `rst` high, is combinational and unregistered on `clk`, and is never used inside the design: they are outputs for counting. In the cached branch of `rtl/mcu.sv` they are the signals below, whose names and conditions are fixed (the data cache's in the second table, declared only in builds with a data cache). Outside the design, only the counting of [sim/top.sv](../sim/top.sv) reads them.

| Signal in `rtl/mcu.sv` | From | 1 in cycle t if | `CACHE_STATS` key | Cache-model field |
|---|---|---|---|---|
| `cache_ev_i_hit` | `icache` | the cache acknowledges a fetch from its arrays | `i_hits` | none (it counts discarded answers too) |
| `cache_ev_i_miss` | `icache` | a `LOOKUP` cycle with a request inside the window that does not hit: a refill starts at the end of t | `i_refills` | sum of `i_refills` over its causes |
| `cache_ev_i_beat` | `icache` | in `REFILL`, the memory answers a beat | `i_beats` | none |
| `cache_ev_i_fill` | `icache` | the last beat is answered: the line becomes valid at the end of t | `i_done` | `i_done` |
| `cache_ev_i_abandoned` | `icache` | the last beat is answered and the presented request is not an in-window address of the refilled line | `i_abandoned` | close to `i_left` (the model evaluates it one cycle later) |
| `cache_ev_i_snoop_inval` | `icache` | a store is acknowledged at slave 0 and its line is valid with an equal tag: the line is invalidated at the end of t. Counted also when a miss in the same set clears the same valid bit in t | `snoop_inval` | `snoop_inval` |
| `cache_ev_wait_i` | `mem_arbiter` | the refill requests and is not granted, because the data side holds the port | `wait_i_for_port` | `wait_i_for_port` |
| `cache_ev_wait_d` | `mem_arbiter` | the data side requests and is not granted, because a refill holds the port | `wait_d_for_port` | `wait_d_for_port` |
| `cache_ev_grant_i` | `mem_arbiter` | a cycle of the port used by a refill | `port_irefill` | `port_irefill` |
| `cache_ev_grant_d` | `mem_arbiter` | a cycle of the port used by a data transfer | `port_data` | `port_store + port_load` in the I-cache-only mode |
| `cache_ev_port_load` | `mem_arbiter` | a RAM load is answered on the memory port (with a data cache: a data refill beat) | `d_loads` | `d_loads` |
| `cache_ev_port_store` | `mem_arbiter` | a RAM store is answered on the memory port | `d_stores` | `d_stores` |
| `cache_ev_i_refill` | `icache` | the cache is in `REFILL`: every cycle of a refill, waiting or granted | `i_refill_cycles` | none |

`wait_i`, `wait_d`, `grant_i`, `grant_d` and `i_refill` are cycle events: they are 1 in every cycle their condition holds, not once per transfer. The rows are in the order in which the names are declared in `rtl/mcu.sv`, which is the order in which a counter unit would wire the first twelve; `cache_ev_i_refill` comes last, and its count equals the sum of the counts of `cache_ev_wait_i` and `cache_ev_grant_i` (`i_refill_cycles = wait_i_for_port + port_irefill`). The two data events count answers on the memory port; a data cache does not send its hits there, so it has events of its own.

The data cache's eight events, in the order in which they are declared in `rtl/mcu.sv`:

| Signal in `rtl/mcu.sv` | 1 in cycle t if | `CACHE_STATS` key | Cache-model field |
|---|---|---|---|
| `cache_ev_d_lookup_hit` | the data cache answers a load from its arrays: a load that is present, and a missed load once more at its second lookup | `dc_lookup_hits` | `d_loads` |
| `cache_ev_d_load_miss` | a `LOOKUP` cycle with a load that is not present: a data refill starts at the end of t | `dc_load_misses` | `d_load_misses` |
| `cache_ev_d_beat` | in `REFILL`, the memory answers a beat | `dc_beats` | none |
| `cache_ev_d_fill` | the last beat is answered: the line becomes valid at the end of t | `dc_done` | none |
| `cache_ev_d_store_hit` | a store is accepted (the store-accept cycle) and its line is present | `dc_store_hits` | `d_store_hits` |
| `cache_ev_d_store_miss` | a store is accepted and its line is not present | `dc_store_misses` | `d_stores - d_store_hits` |
| `cache_ev_d_store_wait` | a store is presented and not yet answered: the CPU waits for it | `dc_store_wait` | `st_store` |
| `cache_ev_d_refill` | the data cache is in `REFILL`: every cycle of a data refill, waiting or granted | `dc_refill_cycles` | none |

`cache_ev_d_store_wait` and `cache_ev_d_refill` are cycle events. A store that is presented while the data cache is in `REFILL` (which a CPU, making one data request at a time, never does) would count a wait in each such cycle without being presented on the memory port.

**For the performance counters.** The signals are declared only in the cached branch (the data cache's only in a build with a data cache); without the cache the names do not exist, and a counter unit that reads them must tie its inputs to 0 itself. The cache and the arbiter build no event vector; `rtl/mcu.sv` wires them to bits 0-11 of `hpm_ext`, event codes 128-139 of the [performance counters](EXTENSIONS.md#hardware-performance-counters) (`cache_ev_i_refill` is not wired). In a build with a data cache it wires the data cache's eight events to bits 12-19, event codes 140-147, in the order of the table above (`DC_LOOKUP_HIT`, `DC_LOAD_MISS`, `DC_BEAT`, `DC_FILL`, `DC_STORE_HIT`, `DC_STORE_MISS`, `DC_STORE_WAIT`, `DC_REFILL_CYCLE`), and drives the matching bits of `hpm_ext_present`; bits 20-31 stay reserved and 0. The bit order is also written in `defines/hpm.sv` (`EXT_DC_*`), which no module reads; [sim/top.sv](../sim/top.sv) compares the vector with the event signals in every cycle of a data-cache build and stops the run on a swapped bit. **The load hits are code 140 minus code 141** (`DC_LOOKUP_HIT - DC_LOAD_MISS`, as for `CACHE_STATS`): code 140 is named for what it counts, every answer from the arrays, and so counts a missed load a second time. Codes 148-159 and 162-191 stay free. [std/include/hpm.h](../std/include/hpm.h) names the codes (`HPM_EV_DC_*`), and `make hpm-codes` compares those names with the monitor's table in `sim/top.sv` and with `defines/hpm.sv`. The events of the pipeline itself (stalls, flushes, branch outcomes) are inside the CPU and are not provided here, since reading them needs CPU changes.

## Legality Checks and Run-Time Assertions

**When the design is built**, each check names the parameter, its value and the rule, and stops the run at time 0, before the first clock edge:

| Check | Where |
|---|---|
| `BYTES` a power of two, at least two lines | `icache`, `dcache` |
| `LINE_BYTES` in {8, 16, 32, 64} | `icache`, `dcache` |
| The tag has at least one bit | `icache`, `dcache` |
| `WINDOW_START` and `WINDOW_WORDS` multiples of the words per line, `WINDOW_WORDS` above 0, `WINDOW_START + WINDOW_WORDS` at most 2^30 | `icache`, `dcache` |
| `WIDTH` at least 1, `DEPTH` a power of two of at least 2 | `cache_ram` |
| The cache's window equals the RAM's window and interconnect slave 0's | cached branch of `rtl/mcu.sv` (for each cache) |
| `HADES_SLOW_MEM` is defined | cached branch of `rtl/mcu.sv` |
| `HADES_DCACHE_BYTES` comes with `HADES_ICACHE_BYTES` | `rtl/mcu.sv` |

Make refuses illegal `ICACHE`, `DCACHE` and `LINE` values before Verilator runs, so these checks are exercised by negative builds that call Verilator directly (`legality.py`). At time 0 the simulator also checks the latency ranges, that `+mem_only` is not given, the syntax and spacing of `+reset_at`, that `+retired_every` is above 0 and that `+ram_words` lie inside the RAM.

**While running.** Every simulator is built with `--assert`; a violation stops the run with the cycle and the signals. Each assertion samples at the rising edge of `clk`, is not evaluated in a cycle with `rst` high, and has its history cleared by a reset.

| Assertion | Where |
|---|---|
| The fetch port has `we = 0` and `sel = 1111` whenever `cyc && stb` | `icache` |
| A data request stays the same until it is answered or a reset drops it | scoreboard; `mem_arbiter` for the granted data side |
| The data cache's memory-side request (a refill beat or a store) stays the same until it is answered or a reset drops it | `dcache` |
| `ack` and `err` never together | `icache`, `dcache`, `mem_arbiter`, scoreboard |
| `ack` or `err` only with `cyc && stb` | `icache`, `dcache`, `mem_arbiter`, scoreboard |
| The data cache never answers `err` and never answers in `REFILL`; every request it gets lies inside the window | `dcache` |
| The memory never answers `err` to the cache (a refill beat or a store) | `icache`, `dcache` |
| No memory write while an instruction refill block holds the port | `mem_arbiter` |
| A continuing data beat is granted | `mem_arbiter` |
| Bit 12 + k of `hpm_ext` is the k-th event of the data cache | `sim/top.sv` |
| No memory answer in a cycle without a grant | `mem_arbiter` |
| Every request is answered within the bound below | `sim/top.sv` |
| The interconnect timeout never fires while slave 0 is selected | `sim/top.sv` |
| The continuation tag is set only for a read that continues the previous transfer | `sim/slow_memory.sv` |

**Bounded answers.** With the costs `D` and `R` of [the default cycle limit](#the-default-cycle-limit), a cached simulator without a data cache stops if: a slave-0 data request is not answered within `R + D` cycles of its first cycle; a refill is not granted within `3 * D` cycles of its first `REFILL` cycle; a granted refill's last beat is not answered within `R` cycles of its first granted cycle; or the fetch port gets neither `ack` nor `err` within `8 * (R + 3 * D + 2)` cycles while it presents in-window requests. A correct design can meet the second and the third bound exactly in the worst case, and the first with one cycle to spare; the last is a deliberate margin for a deadlock detector. An interval that contains a reset cycle is abandoned. If an assertion fires, the argument or the design is wrong and has to be investigated; the bound is never raised to make a run pass. The bound of three older data transfers follows, for HaDes-V+, from its stage registers and its combinational data request. For the golden CPU, a protected library whose source cannot be read, it rests on indirect evidence: one wrapper per stage with the same registered outputs, bus traces identical to HaDes-V+'s, and the same fetch-bus behaviour under wait states. An assertion that fails only on the golden CPU is a finding about the golden CPU, and the bound is not changed for it.

**Bounded answers with a data cache.** A load hit uses no port, a load miss holds it for a data refill of `R` cycles, and a store holds it for at most `WR + 1` cycles, with `WR` the longest write wait. Counting as above (an interval's first cycle is its cycle 1, and a check fails if the event has not happened by the end of cycle N), a simulator with a data cache stops if:

| Bound | Starts | N |
|---|---|---|
| (a) a slave-0 request is answered | its first presented cycle | `R + max(R + 1, WR)` |
| (b) an instruction refill is granted | its first `REFILL` cycle | `max(K_OLDER * (WR + 1), R + 1)`, `K_OLDER = 3` |
| (c) a granted instruction refill's last beat is answered | its first granted cycle | `R` |
| (d) the fetch port gets `ack` or `err` | its first unanswered cycle | `8 * (R + N_b + 2)`, `N_b` the value of (b) |
| (e) a data refill is granted | its first `REFILL` cycle | `R` |
| (f) a granted data refill's last beat is answered | its first granted cycle | `R` |

For (a): a load that misses in its first cycle can find an instruction refill granted in that cycle, which holds the port for `R` cycles, then wait for its own refill (`R`) and the second lookup (one cycle), which is `2R + 1`; a store behind an instruction refill granted earlier is granted in cycle `R` at the latest and answered by `R + WR`. For (b): only the at most three older instructions, held in the pipeline when the instruction cache misses, can still use the port, and a load hit uses none, so the refill waits for three stores (`K_OLDER * (WR + 1)`) or, if a load in the Memory stage misses in the very cycle of the fetch miss, for that load's data refill, which wins the free port and frees it again in its second-lookup cycle: the instruction refill is granted in cycle `R + 1`. Either term of the maximum is met exactly by a run built for it. Bound (b) rests on two facts about the CPU (the three older instructions, and that the load in the Memory stage is presented in the fetch-miss cycle or not at all), which the proofs state as the environment of one property. The same rule applies as above: a bound that fires means the design or the argument is wrong, and it is never raised to make a run pass. Builds without a data cache keep the bounds of the previous paragraph.

## Verification and How to Re-Run It

The evidence has six parts, each with a different weakness, so that no part is the only witness of a property. All of them are simulation-side tools, and none of them needs a board.

| Part | What it is | How to run it |
|---|---|---|
| The instruction-cache bench | [test/sv/test_icache.sv](../test/sv/test_icache.sv): the cache and the arbiter next to a reference model (module `icache_ref`) that was written from the behaviour in this document without reading the RTL. Both get the same inputs; every output of the pair and the thirteen events are compared in every cycle, reset cycles included. The bench also checks, independently of the model, that every fetch and load answer equals memory, that the cache never writes, that exactly one memory write is answered per answered store, the answer bounds and the identities of the event counts. Stimulus is random (jumps in any cycle, addresses outside the window and aliases of cached lines, garbage on idle buses, resets at random cycles), with directed sequences for the rare cases, in seven cache configurations and in a system configuration with the real wrapper and RAM, each with several memory profiles; it counts every case it is meant to reach | `make test/sv/test_icache SIM_ARGS='+seed=2 +mem_seed=2'`. It ends with `ICACHE BENCH: PASS (...)` and exit status 0, or `FAIL (...)`. The default run simulates millions of cycles per configuration; the options (`+cycles`, `+only`, `+compare`, `+negative`, the memory options) are listed at the head of the file |
| The data-cache bench | [test/sv/test_dcache.sv](../test/sv/test_dcache.sv): the instruction cache, the data cache and the arbiter wired as `rtl/mcu.sv` wires them with both caches, next to a reference model (module `memsys_ref`) of both caches and the arbiter that was written from the behaviour in this document, without reading the RTL of the data cache, one procedural step per cycle. Both CPU-side buses, both caches' memory-side requests and continuation tags, the memory port, both sides' answers and the twenty-one events are compared in every cycle, reset cycles included. Independently of the model the bench checks that every fetch and load answer equals memory as it was at the start of the cycle, that exactly one memory write is answered per acknowledged store with its byte enables and data and that no other write happens, the answer bounds of [the previous section](#legality-checks-and-run-time-assertions), and the identities of the event counts. The data driver issues loads and stores of every size and offset with random data on the unselected lanes, addresses biased to cached lines, to lines one cache size apart and to the line in refill, and I/O-like intervals; it works in a CPU-like mode (one request at a time, with the rule of the older instructions behind bound (b)) and in a free mode (requests may change during a refill, which reaches states a CPU never reaches). Resets come at random cycles, more often in refill beats, store waits and second lookups. Directed sequences are counted as coverage: every `sel` pattern on a store hit and a store miss, a store miss then a load, a load miss then a store, stores and load hits and misses during an instruction refill, both caches missing in one cycle (the coincident miss, which must be granted in exactly the cycle bound (b) gives), an instruction miss during a data refill, three back-to-back stores behind an instruction miss. Seven cache configurations, each with a small window and the 32 KiB window and five memory profiles, and a system configuration with the real wrapper and RAM | `make test/sv/test_dcache SIM_ARGS='+seed=2 +mem_seed=2'`. It ends with `DCACHE BENCH: PASS (...)` and exit status 0, or `FAIL (...)`; with `+compare=0` or `+compare=bounds`, which leave only the assertions inside the design (and the bounds) to stop the run, it ends with `COMPARE OFF` and a non-zero status. `+negative=<case>` injects a fault that an assertion must stop (`d-request-change`, `d-refill-err`, `d-store-err`, `d-out-of-window`, `ack-err`, `spontaneous-answer`). Options (`+cycles`, `+only`, `+cover`, `+selftest`, the memory options) are listed at the head of the file |
| Formal proofs | [formal/cache/](../formal/cache/README.md): bounded proofs on tiny configurations of the properties that matter (a fetch or load `ack` delivers memory's word, a valid data line equals memory lane by lane, the window, no `ack` with `err`, grant rules, a granted data refill keeps the port, no write inside an instruction refill, the bounded answers, reset, coherence after stores, one memory write per store and exactly the lanes `sel` selects) with negative controls, data independence of the answers of both caches, and unbounded proofs: about the interconnect (with the default mask it equals the original, with the cached mask the RAM never times out, and every I/O slave keeps its timeout), that the arbiter with `data_cont` tied to 0 equals the arbiter without that input (outputs and owner in every cycle), and, by k-induction on each cache alone with helper invariants, the instruction cache's `fetch_data`, `line_data`, `window` and `reset_state` and the data cache's `load_data` and `dline_data`. The k-induction results are reported, not required by the verdict | `make formal-cache` (last line `FORMAL CACHE RESULT: PASS` or `FAIL ...`); `make formal`, `make formal-full` and `make formal-ext` do not run it |
| The transparency matrix | [test/memsys/matrix.py](../test/memsys/matrix.py): the programs, module benches, timing benches, FreeRTOS programs, shell and loader, trap sweeps and a comparison with the golden CPU, run in cached configurations against the standard build, with the `CACHE_STATS` identities checked on every log, mid-run resets, and the model agreement. The legs whose names begin with `d-` run the same suites with both caches (an instruction cache of 512 bytes with a data cache of 512, and 8 KiB with 4 KiB) and add the counter programs, the FreeRTOS runs with the counter presets, the coherence programs, resets in data refill beats, in refills waiting for the port and in store waits, and the cycles-per-instruction rows at three write latencies; `i-only-regression` runs the instruction-cache-only configurations on this tree and on an earlier revision and requires equal output, bus hashes and `CACHE_STATS` lines | `python3 test/memsys/matrix.py list`, `run <leg>...`, `summary` |
| Directed tests | `irqchain.s`, `fetchredirect.s`, `icoherence.s` with eviction steps and coherence cases; the warm-cache variants of the timing-exact tests; the trap-sweep family `window`; for the data cache `dcache.s` (stores of every size to present and absent lines, read back at every lane, conflicting lines, a store to a line of code), `dcoherence.s` (code read as data, patched by stores, run after `fence.i`) and `hpmdcache.s` (the data cache's counter events), and the data-cache forms of the checks in `hpmcache.s` | [test/memsys/README.md](../test/memsys/README.md#directed-tests-with-caches) |
| Mutants | [test/memsys/mutants.py](../test/memsys/mutants.py): each known way to get the caches wrong (ignoring the valid bits, a late `ack`, a missed snoop, a narrow tag, a grant taken away, a burst for data transfers, a broken timeout exemption, and for the data cache a lane enable that is never set, a store miss that allocates, a store hit that skips the memory or that invalidates its line or ignores its tag, a refill word in the wrong place, a memory `ack` forwarded to the held load, a gap in a refill block, wrong continuation tags, events in reset, a swapped event bit, a reset that keeps state, a data-dependent store hit, and more: 68 in all, 24 of them for the data cache) is written as a source patch of a temporary copy and must be caught by the check named for it; some are also run with the scoreboard's comparison of loaded words switched off, so that the directed test alone must catch them; `--map` also makes every run-time assertion fire on its own negative control | `python3 test/memsys/mutants.py list`, `anchors`, `dryrun`, `run all --map` |
| Model agreement | [test/memsys/cachemodel.py](../test/memsys/cachemodel.py) in its I-cache-only mode, and in its mode with a data cache, against a cached simulator run: the refills, the invalidations, the loads, the load misses, the store hits and the stores must agree exactly (the model's `d_loads` against `dc_lookup_hits`, `d_load_misses` against `dc_load_misses`, `d_store_hits` against `dc_store_hits`, `d_stores` against `dc_store_hits + dc_store_misses`), and the cycles, the waits and the store stalls are reported | `python3 test/memsys/cachemodel.py rtlcheck <prepared trace> <log>` ([README](../test/memsys/README.md#cache-model)) |

[test/memsys/legality.py](../test/memsys/legality.py) checks the refusals, the negative builds and the options (`python3 test/memsys/legality.py run`; groups `make-options`, `build-checks`, `run-options`, `resets`, `cycle-limit`, `simulators` and `bench`, including the negative cases of both benches). The standard build is checked to be unchanged: the text of `rtl/mcu.sv` that the build selects without the cache defines is the text it had, the CPU files are untouched, the images and bus hashes of the standard builds are as they were, and the recorded results of [results/](../results/README.md) reproduce. The configurations with an instruction cache alone are checked to behave as before the data cache existed: their bus hashes and `CACHE_STATS` lines are equal. The cached simulators are compared against the same programs in the standard simulator; timing-exact checks that a cache must change are judged by the warm variants and by the rules of `programs.py` ([test/memsys/README.md](../test/memsys/README.md#with-an-instruction-cache-and-with-both-caches)). No result of these checks on a cached configuration (cycles per instruction, miss rates, run times) is recorded in `results/` yet.

## What Is Not Built

| Not built | Why |
|---|---|
| A data cache without an instruction cache | The memory port and the arbiter are built with the instruction cache's refill port as the second requester; a data cache alone would need the raw fetch port on the arbiter, which is not built. Make refuses `DCACHE` without `ICACHE` |
| A write buffer, posted stores | Stores go through the data cache to the RAM and are acknowledged after the RAM has written them; the CPU waits for each one (`DC_STORE_WAIT` counts the cycles). Whether to build a buffer is open: it would be built only if the store stalls, measured with the data cache, asked for it, and the longer the RAM takes to acknowledge a write (`MEM_WR_LAT`), the more the stores stall. What it would move is small by design: the data cache's answer to the CPU, its lane write, the store events and, through the acknowledge at slave 0, the instruction cache's snoop all depend on the store-accept condition alone, which a buffer would redefine as "the buffer takes the store"; the proof that each accepted store writes the memory (`store_mem`) would then hold once the buffer is empty |
| Abort on a redirect | A started refill always completes. Aborting would save memory traffic only |
| A second way, replacement policy | Direct mapping needs no way multiplexer in front of the branch predictor; two ways would need the synthesis to price it |
| Early restart, critical word first | They need a bypass multiplexer on the predictor path and bring back the risk of answering for a stale address |
| Hit under miss, several misses in flight | The CPU cannot use them |
| Prefetching, a victim buffer | Excluded; they would be modelled before they are built |
| Software-visible counters (CSRs or memory-mapped), a shell `cache` command | Done for both caches: [Hardware Performance Counters](EXTENSIONS.md#hardware-performance-counters); a shell `cache` command is not provided |
| An invalidate port for `FENCE.I`, a flush of the data cache, memory-mapped invalidate-all, `Zicbom` | Snooping keeps the instruction cache coherent, and the write-through data cache never differs from the RAM |
| A run-time enable, flush or bypass switch | The caches are a compile-time choice |
| Refill error paths | A refill (of either cache) or a store cannot get `err` from this memory; if it does, the simulation stops |
| Narrow tags, a block-RAM array style, register slices, a DRAM adapter, a clock crossing, a second cacheable region | Needed only for hardware |
| Other sizes and lines as configurations that are checked in full | The options accept them and one matrix leg runs other line sizes; an instruction cache of 512 bytes with a data cache of 512, and 8 KiB with 4 KiB, all with 16-byte lines, are the configurations of the long runs (the proofs use tiny configurations, the data-cache bench seven) |
| Write-back, dirty bits, write-allocate | Not planned |
| Any synthesis, and a cached hardware build | See the limits below |
| Any change to either CPU | The caches are outside the CPUs |

## Limits and Rules for Later Use

- **Simulation only.** The cached configurations have not been synthesised and no run of Vivado is part of them. The standard build and the Basys 3 bitstream have no cache.
- **No cached hardware build is planned.** In a build with an instruction cache and no data cache, the data side's path from the RAM, which starts at the falling clock edge, would pass through the arbiter and get longer; the timing of the board has no margin to spare for it (see [Building](BUILDING.md#synthesis-and-fpga-timing)). The data cache answers a hit in its own cycle from arrays that are read within the cycle, a style written for simulation; a hardware version would need block-RAM arrays, which answer a cycle later. Any use of a cache in hardware would need a synthesis run and a new look at those paths.
- **Other writers of the RAM.** The coherence argument rests on every write to the RAM passing interconnect slave 0 while the instruction cache snoops it, and on this CPU's data port being the only writer that the data cache has to follow, through the data cache itself. The data cache does not snoop. Any other writer of the RAM (a DMA engine, a second hart, a debug port) must go through the arbiter with the instruction cache snooping its stores and the data cache updated or invalidated by them, or use memory that is not cached.
- **A memory that can fail.** Neither refill has an error path and a data `err` from the RAM, for a refill or a store, is not expected; a memory that can answer `err` needs rules first for what a refill does with it and what the data side sees.
- **Store completion.** Every effect of a completed store, the answer to the CPU, the data cache's lane write, the store events and the instruction cache's snoop, depends on one condition, the memory's answer to the store. A change that completes a store earlier (a write buffer) has to redefine that condition and nothing else, and has to restate what "acknowledged" means below.
- **A memory adapter that cannot cancel a request.** The simulation wrapper drops a held request at a reset. An adapter that cannot do that must absorb the answers to requests issued before a reset; the caches and the arbiter ignore an answer that arrives without a grant, and do not rely on the memory having dropped the request.
- **What an acknowledged write is.** A write is acknowledged when it is accepted into an in-order queue that later reads cannot overtake. The snoop clears the instruction line, and the data cache writes a present line, at that acknowledgement, and a refill of either cache that follows reads the memory after it.
- **The memory port.** It stays a plain Wishbone block port, plus the simulation-only continuation tag, which hardware may leave unconnected. A register slice can be added to it without touching the caches or the arbiter.
