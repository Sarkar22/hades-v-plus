[HaDes-V+](../README.md) · [Docs](README.md) · [Building](BUILDING.md) · [FreeRTOS](FREERTOS.md) · [Shell](SHELL.md) · [Apps](APPS.md) · [Architecture](ARCHITECTURE.md) · [Extensions](EXTENSIONS.md) · [Verification](VERIFICATION.md) · **Caches**

# Caches (Simulation Only)

This document describes the instruction cache that the simulators can be built with: where it sits, how it behaves cycle by cycle, how it stays coherent with stores, how it shares the RAM's one memory port with the data side, how to build and run a cached simulator, what the simulator prints, how the cache is checked, what is not built, and the rules that any later use of the design must keep.

**The caches exist only in the simulators.** The standard build, every simulator without the options below and the Basys 3 bitstream have no cache: `make synthesis` reads `rtl/*.sv`, which does not include `rtl/cache/`, the cached wiring of [rtl/mcu.sv](../rtl/mcu.sv) is selected by a Verilator define that synthesis never sets, and the Makefile refuses `make synthesis` together with any simulator option. Nothing in this document describes the hardware on the board. The results of the cached configurations (cycles per instruction, miss rates, run times) are not published; this document quotes none.

**Contents**

1. [Overview](#overview)
2. [The Instruction Cache](#the-instruction-cache)
3. [Coherence: Snooping, FENCE and FENCE.I](#coherence-snooping-fence-and-fencei)
4. [Reset, Interrupts and Traps](#reset-interrupts-and-traps)
5. [One Memory Port and the Arbiter](#one-memory-port-and-the-arbiter)
6. [Building and Running a Cached Simulator](#building-and-running-a-cached-simulator)
7. [What the Simulator Prints](#what-the-simulator-prints)
8. [Events and the Counter Work](#events-and-the-counter-work)
9. [Legality Checks and Run-Time Assertions](#legality-checks-and-run-time-assertions)
10. [Verification and How to Re-Run It](#verification-and-how-to-re-run-it)
11. [What Is Not Built](#what-is-not-built)
12. [Limits and Rules for Later Use](#limits-and-rules-for-later-use)

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
              +-----------> mem_arbiter <------+
                                | memory port (+ continuation tag)
                         slow_memory (PORT "memory", simulation only)
                                |
                     wishbone_ram port A        (port B idle)
```

- **Placement.** The cache is outside both CPUs. It sits on the fetch bus between a CPU and the RAM, in [rtl/mcu.sv](../rtl/mcu.sv), under `` `ifdef HADES_ICACHE_BYTES ``. The CPU-side buses `fetch_bus` and `mem_bus` are the ones of the standard build, so every monitor of [sim/top.sv](../sim/top.sv) (the trace, the scoreboard, the bus hash, the test device) keeps working on the CPU side, and the cache works with HaDes-V+ and with the golden CPU alike. No CPU file is changed.
- **Split.** Only instruction fetches are cached. The data side passes through uncached: every load and store to the RAM reaches the RAM as it does without a cache, once and unchanged.
- **One memory port.** The standard RAM is a dual-port block RAM, one port per CPU bus. In the cached configuration a hit needs no RAM access, and a refill and a data access are the only two things that can want the RAM, so there is one memory port that [rtl/cache/mem_arbiter.sv](../rtl/cache/mem_arbiter.sv) shares between the data side and the cache's refills. Port B of the RAM is idle. The port goes through one instance of [sim/slow_memory.sv](../sim/slow_memory.sv) (`PORT "memory"`), which gives the memory its latencies and, in burst mode, the cheaper further beats of a refill.
- **Files.** `rtl/cache/icache.sv` (the cache), `rtl/cache/cache_ram.sv` (its two arrays behind a small wrapper), `rtl/cache/mem_arbiter.sv`, and the changed [sim/slow_memory.sv](../sim/slow_memory.sv), [lib/wishbone/wishbone_interconnect.sv](../lib/wishbone/wishbone_interconnect.sv) and `rtl/mcu.sv`. The header comment of each file describes its part.

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

## Coherence: Snooping, FENCE and FENCE.I

Instruction and data memory are one RAM and the program may write its own code, so a cached line must never differ from the RAM. The cache is kept coherent by **snooping**: at the end of every cycle in which a store is acknowledged at interconnect slave 0 (the RAM window of the data bus), the cache reads the tag of the stored-to word's set through a second read port of the tag array, and if that line is valid with an equal tag, it clears the valid bit. Whichever bytes the store writes, the whole line is invalidated. A snoop never writes an array and never sets a valid bit.

The argument has three lines:

1. every valid line was filled while no write could reach the memory, because the arbiter never grants the data side inside a refill block;
2. every later store to a line clears it at the edge at which the store is acknowledged;
3. a refill reads the memory after every earlier store has been acknowledged and written.

Every store to the RAM passes slave 0 on both CPUs, there is one hart and no DMA, and the fetch port never writes, so the snoop sees every write to the RAM.

Two cases show how this meets the pipeline. A fetch that hits the word of a line in the cycle in which a store to that line is acknowledged gets the old word, and the line is invalid from the next cycle, as a read beside a write of the same word returns the old word in the standard build. And the staleness window stays what it is without a cache: instructions fetched in or before the cycle of a store may be stale, and while a store is in Memory, Fetch is at most three instructions ahead. A cache can only shrink the window: a slot whose word is fetched after the store, because its line missed, runs the new word.

**`FENCE` and `FENCE.I`.** Both stay as they are. `FENCE` is a no-op: the cache adds no store buffer, and a store is still acknowledged only after the RAM has written it, so every store is visible to the next access. `FENCE.I` stays the pipeline flush that [the Zifencei section of EXTENSIONS.md](EXTENSIONS.md#zifencei--instruction-fetch-synchronisation) describes: because the cache snoops every store, the refetch after the flush finds either an invalidated line, which it refills from the updated RAM, or a line that no store has touched. There is no invalidate port, no memory-mapped invalidate-all and no cache-maintenance instruction.

## Reset, Interrupts and Traps

**Reset.** At the end of a cycle with `rst` high, every valid bit is cleared, the cache returns to `LOOKUP` with its beat counter at 0, and the arbiter releases the port; a refill or a data transfer in progress is dropped (the memory wrapper drops a held transfer too). The arrays keep their contents. Nothing acknowledged is lost: the RAM answers nothing while `rst` is high, a store is acknowledged only after the RAM has written it, and a dropped data request belongs to a CPU that is itself in reset. After a reset the first fetch, of the reset address, misses. The cache and the arbiter do not depend on the memory dropping a request at a reset: they ignore an answer that arrives without a grant. All events are 0 in cycles with `rst` high.

**Interrupts and traps.** The interrupt logic is unchanged. An interrupt is taken only when a non-bubble instruction is in Writeback, so a miss adds to the interrupt latency, as a divide does. A sequential interrupt decided while the next instruction's data access waits fires when that access ends, and that wait now includes waiting for the port behind a refill. If an interrupt, a trap or `mret` redirects Fetch during a refill, the refill completes and the handler's first word is looked up in the second-lookup cycle, where it may miss in turn. A cache slows only RAM accesses, which never clear an interrupt cause, so I/O keeps its latency. `+irq_latency` measures the latency of every interrupt ([below](#testbench-options)).

**The timeout exemption.** The interconnect ends a bus access that has had no answer for 255 cycles with `err`. With one port shared by refills and data accesses, a RAM access can legitimately wait longer than that behind a refill block. The cached configuration therefore passes `TIMEOUT_EXEMPT = 9'b0_0000_0001` to the interconnect: the timeout counter does not count while slave 0 (the RAM) is selected, so a RAM access is never ended with `err` however long it waits, and every I/O slave keeps its 255-cycle timeout. The parameter defaults to all zeros, which is the interconnect of the standard build (the equivalence is proved, see [Verification](#verification-and-how-to-re-run-it)); the standard and the slow-memory branches of `rtl/mcu.sv` pass no mask. In its place the simulator checks that every request is answered within a bound that follows from the memory's latencies ([below](#legality-checks-and-run-time-assertions)), and the check of [sim/top.sv](../sim/top.sv) that stops a run when the interconnect times out on a RAM access stays, so it fires only if the exemption is broken.

## One Memory Port and the Arbiter

The arbiter has two requesters: the data side (interconnect slave 0, which raises `stb` only for RAM-window addresses, so an I/O access never asks for the port) and the cache's refill port. Its rules:

- **Data first.** On a free port a data request is granted in the cycle it is made; the cache is granted only if the data side does not request in that cycle. The grant is combinational, so an uncached data access on an idle port takes exactly as long as without the arbiter.
- **A grant is never taken away.** A data grant lasts until its transfer is answered, a refill grant until its block ends, which is the first cycle in which the cache does not request (the port is free in that cycle). There is no fairness state.
- **Pass-through.** The granted side's request reaches the memory unchanged and once; the answer returns to that side only, and the other side sees `ack = err = 0`. Data transfers are never widened, split, repeated or reordered. An idle port is all zeros.
- **No write inside a refill block.** It follows from the rules above and is checked in simulation and proved.
- **No assumption about the memory.** An answer in a cycle with no grant reaches no side and stops the simulation. The memory side is a plain Wishbone block port plus one simulation-only tag, so a register slice or an adapter could be added there without touching the state machines.

The bounds that follow: a data request waits at most for the rest of one refill block; a refill waits at most for three data transfers. Three, because once the cache is in `REFILL` no `ack` lets a new instruction enter, and only the at most three older instructions held in the output registers of Fetch, Decode and Execute can still make a data request, one each.

**Burst mode.** `slow_memory` normally charges every transfer a latency drawn from its range. With a beat latency (`MEM_BEAT_LAT`, or `+mem_beat_lat`) a transfer costs the beat latency instead if it is a read of the next word, `cyc` has been held since the previous answer, and the master marks it as continuing its block. In the cached configuration the mark is the continuation tag, which the cache raises for beats 1 to the last of a refill and the arbiter passes on only while the cache is granted. So only the further beats of a refill get the cheap beat, never a data transfer, even if two loads of consecutive words come back to back: a DRAM adapter turns lines, not single words, into bursts. The wrapper stops the simulation if the tag is set for a transfer that does not continue a read block, so a wrong tag cannot give a silent discount. Without burst mode a refill costs `LINE_WORDS * (L + 1)` cycles for latencies `L` drawn per beat; with a beat latency `b` it costs `(L + 1) + (LINE_WORDS - 1) * (b + 1)`. A transfer of latency `L` takes `L + 1` cycles.

## Building and Running a Cached Simulator

### The options

Two options of any make target that builds a simulator, next to the memory options of [test/memsys/README.md](../test/memsys/README.md#simulator-configurations); `make help` lists them.

| Option | Values | Meaning |
|---|---|---|
| `ICACHE=<bytes>` | `0` or unset: no cache. Otherwise a decimal number without sign or leading zero that is a power of two of at least two lines (32 with 16-byte lines) | Builds the cached configuration: the slow-memory configuration (latency 0 unless `MEM_LAT=...` and the other memory options say otherwise), an instruction cache of that size, one memory port, and the RAM exempt from the interconnect timeout |
| `LINE=<bytes>` | 8, 16, 32 or 64; default 16; only together with a non-zero `ICACHE` | The line size |

Refused, each with a message that names the option and the rule: `LINE` without a non-zero `ICACHE`; an illegal value of either; `MEM_ONLY` together with `ICACHE` (there is one memory port); `DCACHE` with any value (there is no data cache); `make synthesis` together with any simulator option. The data port's limit of 254 cycles of latency applies only without a cache.

```bash
make test/asm/ops ICACHE=512                          # cache of 512 bytes, memory at latency 0
make test/memsys/stores ICACHE=512 MEM_LAT=2          # every memory transfer waits 2 cycles
make freertos APP=minimal ICACHE=8192 MEM_LAT=1:8     # 8 KiB, random latencies, the automatic tick
make freertos-shell ICACHE=512 MEM_LAT=2              # the shell on a cached core
make sim-config ICACHE=512 MEM_LAT=1:8 MEM_SEED=2     # name, build directory and environment of a configuration
python3 test/memsys/programs.py run ICACHE=512 MEM_LAT=2
```

The configuration's name has the parts `i<size>` (bytes below 1024, otherwise `<n>k`) and `l<line>` after the memory parts, and its simulators are built in `build/cfg-<name>`, so they never mix with the standard simulators or those of another configuration. Examples: `ICACHE=512` is `mem0-i512-l16`; `ICACHE=512 MEM_LAT=1:8 MEM_SEED=2` is `mem1_8-seed2-i512-l16`; `ICACHE=8192 MEM_LAT=8:24 MEM_WR_LAT=1:4 MEM_BEAT_LAT=0` is `mem8_24-wr1_4-beat0-i8k-l16`. Scripts that build their own simulators get the options as the environment variables `HADES_ICACHE` and `HADES_LINE` (`make sim-config` prints them). `ICACHE=0` is the same as no cache.

### Latency profiles

The memory behind the cache is configured with the memory options (`MEM_LAT`, `MEM_WR_LAT`, `MEM_BEAT_LAT`, `MEM_SEED`), which in a cached configuration set the one memory port's latencies; the port has its own latency sequence, seeded by `MEM_SEED`. [test/memsys/matrix.py](../test/memsys/matrix.py) names the profiles it uses: `lat0` (no memory option), `lat2` (`MEM_LAT=2`), `rand1` to `rand3` (`MEM_LAT=1:8` with seeds 1 to 3), `burst` (`MEM_LAT=1:8 MEM_BEAT_LAT=0`), `stress` (`MEM_LAT=1:64`, beyond the interconnect timeout without the exemption) and `dram` (`MEM_LAT=8:24 MEM_WR_LAT=1:4 MEM_BEAT_LAT=0`, for measurements). `MEM_BEAT_LAT=0` is the fastest burst: one cycle per further beat.

### Run-time options

The options are compiled in as the simulator's defaults; these run-time options (`SIM_ARGS='+...'` through make, or on the simulator's command line) override them. The options of [sim/slow_memory.sv](../sim/slow_memory.sv) are described in [test/memsys/README.md](../test/memsys/README.md#simulator-configurations).

| Option | Meaning |
|---|---|
| `+mem_lat`, `+mem_rd_lat`, `+mem_wr_lat`, `+mem_beat_lat`, `+mem_seed` | Latencies of the one memory port; `+mem_seed` also seeds the random initial arrays of the cache |
| `+mem_only` | Refused in a cached simulator (one port) |
| `+timeout=<cycles>` | The cycle limit of the run; without it the cached default applies ([below](#the-default-cycle-limit)) |
| `+cache_stats`, `+nocache_stats` | The `CACHE_STATS` line at the end of the run; on by default in a cached simulator |
| `+cache_stats_marks` | Also a `CACHE_STATS_MARK` line (`i_done`, `i_abandoned`, `snoop_inval` so far) at every report of the program (`Test pass!` / `Test fail!`), to attribute counts to the parts of a test |
| `+reset_at=<cycle>[,<cycle>...]` | Resets in the middle of the run ([below](#testbench-options)) |
| `+cache_phase_log=<file>` | One byte per cycle with the phase of the cache and of the data side, for placing resets |
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

A cached program is slowed by its misses, each of which costs a whole refill, not a single wait; this factor is never smaller than the one of an uncached slow memory and only delays the detection of a hang. The simulator prints the limit at its first clock edge:

```
SLOW MEMORY cycle limit <n>: 100000 times 1 + the longest refill or data transfer (<k> cycles); +timeout=<cycles> sets it
```

`programs.py` computes the same limit for its runs and passes `+timeout`; FreeRTOS runs do too, so their logs carry no such line. `make help` states the rule.

### FreeRTOS

FreeRTOS programs count their tick in clock cycles, so a slower memory makes the tasks slower against the tick. In every configuration with a slow memory, cached or not, `freertos.mk` sets the tick automatically, unless `TICK=` is given, and scales the programs' interrupt intervals and the cycle limit with it; with a cache the factor is one larger, because a miss costs a whole refill. The rule, the programs it scales and the console pace of the shell with a cache are in [FREERTOS.md](FREERTOS.md#slow-memory-and-cached-configurations).

## What the Simulator Prints

A cached run prints, besides the usual lines:

- at time 0, the configuration line of the cached branch of `rtl/mcu.sv`, for example for 512 bytes with 16-byte lines:

  ```
  CACHE I-cache 512 bytes, 16-byte lines, 32 sets, direct-mapped; tag adr[29:7], index adr[6:2], word adr[1:0]; window 0x00040000-0x00047fff; random initial arrays, seed 1; one memory port, data side first; RAM exempt from the interconnect timeout
  ```

- the wrapper's line `SLOW MEMORY memory port: read latency <r>, write latency <w>, burst beats <b|off> (cache refill blocks only), seed <s>`;
- at the first clock edge, the `SLOW MEMORY cycle limit` line above (without `+timeout`);
- at the end of the run, the `SCOREBOARD`, `RETIRED` and `BUSHASH` lines as in any slow-memory simulator, and the `CACHE_STATS` line.

### CACHE_STATS

One line at the end of the run (`+nocache_stats` turns it off):

```
CACHE_STATS cycles=<n> i_hits=<n> i_refills=<n> i_done=<n> i_beats=<n> i_abandoned=<n> snoop_inval=<n> i_refill_cycles=<n> wait_i_for_port=<n> wait_d_for_port=<n> port_irefill=<n> port_data=<n> d_loads=<n> d_stores=<n> i_inflight=<0|1> i_inflight_beats=<n> i_inflight_port=<n> d_inflight=<0|1> d_inflight_port=<n>
```

The counters count the cycles in which the events of [the next section](#events-and-the-counter-work) are 1; the key of each event is in that table. Every counter restarts at every reset, and `cycles` counts the cycles with `rst` low since the last reset. `RETIRED` and `BUSHASH` do not restart (they count from time 0), so `CACHE_STATS` and `RETIRED` cover the same cycles only in a run without a mid-run reset; everything that combines them (a miss rate, the identities below, `rtlcheck`) is taken only from runs without a `RESET` line.

**The state at the end.** A run stops at the test device's `$finish`, at an arbitrary point of Fetch's run-ahead, often in the middle of a refill. `i_inflight` is 1 if the cache is in `REFILL` after the last counted edge, and `i_inflight_beats` and `i_inflight_port` are the beats answered and the port cycles that refill has had; `d_inflight` is 1 if the arbiter's owner is the data side, and `d_inflight_port` the port cycles of that transfer. They are states, not event counts, and they make the identities exact.

**Identities** that hold in every run without a reset:

```
i_refills        = i_done + i_inflight
i_refill_cycles  = wait_i_for_port + port_irefill
i_beats          = (words per line) * i_done + i_inflight_beats
```

and `i_hits`, `d_loads` and `d_stores` equal the fetches, loads and stores of the `SCOREBOARD` line, and `cycles` equals the cycles of the `RETIRED` line.

**Interpretation.** `i_hits` counts every cycle in which the cache acknowledged a fetch, and the pipeline does not use all of them: Fetch repeats a lookup in `STALL` cycles and discards the answer in `JUMP` cycles. So `i_hits` over-counts the fetches that the pipeline consumed, and it is not a hit rate. The miss rate of the instruction side is taken as `i_done` per 1000 retired instructions (the `RETIRED` line), from a run without a reset. Not counted, because Fetch's status is inside the CPU: the cause of a refill (sequential, stalled, jump, flushed). The CPU's own events (stalls, flushes, branch outcomes) belong to the counter work.

### Testbench options

**`+reset_at=<c>[,<c>...]`** drives the reset button for exactly one cycle at each listed cycle of the testbench's cycle count, so that `rst` is high for one cycle three cycles later (two synchroniser stages and the `rst` flip-flop). The cycles are decimal, at least 1, strictly ascending and at least 2 apart (checked at time 0). It works in every slow-memory simulator, cached or not, on both CPUs. In the cycle in which `rst` is high a line is printed:

```
RESET at cycle <n> (+reset_at=<c>): I-cache <phase>, data side <phase>
```

The cache's phase is `idle`, `refill waiting for the port` or `refill beat <b> of <n>` (counted from 0); the data side's is `idle`, `RAM load waiting`, `RAM store waiting`, `I/O access waiting`, `granted (RAM load)` or `granted (RAM store)`. The scoreboard keeps its copy of the memory across the reset (the RAM keeps its contents), skips the reset cycle and clears its request-stability state. After a mid-run restart a program may legitimately misbehave; its verdict is not judged, the scoreboard and the assertions are.

**`+cache_phase_log=<file>`** writes one byte per cycle from the first clock edge: bit 0 the cache is granted the port, bit 1 a refill waits for the port, bit 2 a data request on the CPU's data bus waits for its answer, bit 3 that request is a RAM access, bit 4 it is a write, bit 5 the data side is granted the port, bit 6 `rst`, bit 7 0. A run with `+reset_at` is identical to the same run without it up to the reset, so a reset wanted in cycle `t` is requested with `+reset_at=<t-3>`.

**`+irq_latency`** (HaDes-V+ only) measures, for every interrupt the CPU takes, the cycles from the first cycle in which an interrupt is pending and enabled in Writeback to the first fetch `ack` after the interrupt's jump cycle, and prints `IRQLAT interrupts=<n> max=<cycles> mean=<cycles>` at the end. It is an observed maximum of the runs made, not a worst case. The monitor is checked against latencies derived by hand: `test/memsys/irqlat.s` and the matrix leg `irq-latency-validation` ([README](../test/memsys/README.md#directed-tests-with-an-instruction-cache)).

**`+ram_words=<byte address>[,...]`** prints `RAM_WORDS <address>=<value> ...` at the end, for word-aligned addresses inside the RAM (`irqchain.s` records its interrupt positions this way). **`+retired_every=<n>`** (HaDes-V+ only) prints `RETIRED_AT instructions=<i> cycles=<c>` each time `RETIRED`'s count reaches another multiple of n.

## Events and the Counter Work

The cache and the arbiter expose thirteen one-bit **event** outputs. Each is 1 exactly in the cycles in which its event happens, is 0 in cycles with `rst` high, is combinational and unregistered on `clk`, and is never used inside the design: they are outputs for counting. In the cached branch of `rtl/mcu.sv` they are the signals below, whose names and conditions are fixed. Outside the design, only the counting of [sim/top.sv](../sim/top.sv) reads them.

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
| `cache_ev_port_load` | `mem_arbiter` | a RAM load is answered on the memory port | `d_loads` | `d_loads` |
| `cache_ev_port_store` | `mem_arbiter` | a RAM store is answered on the memory port | `d_stores` | `d_stores` |
| `cache_ev_i_refill` | `icache` | the cache is in `REFILL`: every cycle of a refill, waiting or granted | `i_refill_cycles` | none |

`wait_i`, `wait_d`, `grant_i`, `grant_d` and `i_refill` are cycle events: they are 1 in every cycle their condition holds, not once per transfer. The rows are in the order in which the names are declared in `rtl/mcu.sv`, which is the order in which a counter unit would wire the first twelve; `cache_ev_i_refill` comes last, and its count equals the sum of the counts of `cache_ev_wait_i` and `cache_ev_grant_i` (`i_refill_cycles = wait_i_for_port + port_irefill`). The two data events count answers on the memory port; a data cache, when there is one, will not send its hits there, so it will need events of its own.

**For the counter work.** The signals are declared only in the cached branch; without a cache the names do not exist, and a counter unit that reads them must tie its inputs to 0 itself. The cache and the arbiter build no event vector and never drive a counter unit's inputs; which signal is counted under which code, the vector's bit order and its mask belong to the counter work, which reads the signals by name. The events of the pipeline itself (stalls, flushes, branch outcomes) are inside the CPU and are not provided here, since reading them needs CPU changes.

## Legality Checks and Run-Time Assertions

**When the design is built**, each check names the parameter, its value and the rule, and stops the run at time 0, before the first clock edge:

| Check | Where |
|---|---|
| `BYTES` a power of two, at least two lines | `icache` |
| `LINE_BYTES` in {8, 16, 32, 64} | `icache` |
| The tag has at least one bit | `icache` |
| `WINDOW_START` and `WINDOW_WORDS` multiples of the words per line, `WINDOW_WORDS` above 0, `WINDOW_START + WINDOW_WORDS` at most 2^30 | `icache` |
| `WIDTH` at least 1, `DEPTH` a power of two of at least 2 | `cache_ram` |
| The cache's window equals the RAM's window and interconnect slave 0's | cached branch of `rtl/mcu.sv` |
| `HADES_SLOW_MEM` is defined | cached branch of `rtl/mcu.sv` |

Make refuses illegal `ICACHE` and `LINE` values before Verilator runs, so these checks are exercised by negative builds that call Verilator directly (`legality.py`). At time 0 the simulator also checks the latency ranges, that `+mem_only` is not given, the syntax and spacing of `+reset_at`, that `+retired_every` is above 0 and that `+ram_words` lie inside the RAM.

**While running.** Every simulator is built with `--assert`; a violation stops the run with the cycle and the signals. Each assertion samples at the rising edge of `clk`, is not evaluated in a cycle with `rst` high, and has its history cleared by a reset.

| Assertion | Where |
|---|---|
| The fetch port has `we = 0` and `sel = 1111` whenever `cyc && stb` | `icache` |
| A data request stays the same until it is answered or a reset drops it | scoreboard; `mem_arbiter` for the granted data side |
| `ack` and `err` never together | `icache`, `mem_arbiter`, scoreboard |
| `ack` or `err` only with `cyc && stb` | `icache`, `mem_arbiter`, scoreboard |
| The memory never answers `err` to the cache | `icache` |
| No memory write while a refill block holds the port | `mem_arbiter` |
| No memory answer in a cycle without a grant | `mem_arbiter` |
| Every request is answered within the bound below | `sim/top.sv` |
| The interconnect timeout never fires while slave 0 is selected | `sim/top.sv` |
| The continuation tag is set only for a read that continues the previous transfer | `sim/slow_memory.sv` |

**Bounded answers.** With the costs `D` and `R` of [the default cycle limit](#the-default-cycle-limit), a cached simulator stops if: a slave-0 data request is not answered within `R + D` cycles of its first cycle; a refill is not granted within `3 * D` cycles of its first `REFILL` cycle; a granted refill's last beat is not answered within `R` cycles of its first granted cycle; or the fetch port gets neither `ack` nor `err` within `8 * (R + 3 * D + 2)` cycles while it presents in-window requests. A correct design can meet the second and the third bound exactly in the worst case, and the first with one cycle to spare; the last is a deliberate margin for a deadlock detector. An interval that contains a reset cycle is abandoned. If an assertion fires, the argument or the design is wrong and has to be investigated; the bound is never raised to make a run pass. The bound of three older data transfers follows, for HaDes-V+, from its stage registers and its combinational data request. For the golden CPU, a protected library whose source cannot be read, it rests on indirect evidence: one wrapper per stage with the same registered outputs, bus traces identical to HaDes-V+'s, and the same fetch-bus behaviour under wait states. An assertion that fails only on the golden CPU is a finding about the golden CPU, and the bound is not changed for it.

## Verification and How to Re-Run It

The evidence has six parts, each with a different weakness, so that no part is the only witness of a property. All of them are simulation-side tools, and none of them needs a board.

| Part | What it is | How to run it |
|---|---|---|
| The cache bench | [test/sv/test_icache.sv](../test/sv/test_icache.sv): the cache and the arbiter next to a reference model (module `icache_ref`) that was written from the behaviour in this document without reading the RTL. Both get the same inputs; every output of the pair and the thirteen events are compared in every cycle, reset cycles included. The bench also checks, independently of the model, that every fetch and load answer equals memory, that the cache never writes, that exactly one memory write is answered per answered store, the answer bounds and the identities of the event counts. Stimulus is random (jumps in any cycle, addresses outside the window and aliases of cached lines, garbage on idle buses, resets at random cycles), with directed sequences for the rare cases, in seven cache configurations and in a system configuration with the real wrapper and RAM, each with several memory profiles; it counts every case it is meant to reach | `make test/sv/test_icache SIM_ARGS='+seed=2 +mem_seed=2'`. It ends with `ICACHE BENCH: PASS (...)` and exit status 0, or `FAIL (...)`. The default run simulates millions of cycles per configuration; the options (`+cycles`, `+only`, `+compare`, `+negative`, the memory options) are listed at the head of the file |
| Formal proofs | [formal/cache/](../formal/cache/README.md): bounded proofs on tiny configurations of the properties that matter (a fetch `ack` delivers memory's word, the window, no `ack` with `err`, grant rules, no write inside a refill, the bounded answers, reset, coherence after stores, one memory write per store) with negative controls, k-induction on the cache alone, data independence of the answers, and unbounded proofs about the interconnect: with the default mask it equals the original, with the cached mask the RAM never times out, and every I/O slave keeps its timeout | `make formal-cache` (last line `FORMAL CACHE RESULT: PASS` or `FAIL ...`); `make formal`, `make formal-full` and `make formal-ext` do not run it |
| The transparency matrix | [test/memsys/matrix.py](../test/memsys/matrix.py): the programs, module benches, timing benches, FreeRTOS programs, shell and loader, trap sweeps and a comparison with the golden CPU, run in cached configurations against the standard build, with the `CACHE_STATS` identities checked on every log, mid-run resets, and the model agreement | `python3 test/memsys/matrix.py list`, `run <leg>...`, `summary` |
| Directed tests | `irqchain.s`, `fetchredirect.s`, `icoherence.s` with eviction steps and coherence cases; the warm-cache variants of the timing-exact tests; the trap-sweep family `window` | [test/memsys/README.md](../test/memsys/README.md) |
| Mutants | [test/memsys/mutants.py](../test/memsys/mutants.py): each known way to get the cache wrong (ignoring the valid bits, a late `ack`, a missed snoop, a narrow tag, a grant taken away, a burst for data transfers, a broken timeout exemption, and more) is written as a source patch of a temporary copy and must be caught by the check named for it; `--map` also makes every run-time assertion fire on its own negative control | `python3 test/memsys/mutants.py list`, `anchors`, `dryrun`, `run all --map` |
| Model agreement | [test/memsys/cachemodel.py](../test/memsys/cachemodel.py) in its I-cache-only mode against a cached simulator run: the refills, the invalidations and the loads and stores must agree exactly | `python3 test/memsys/cachemodel.py rtlcheck <prepared trace> <log>` ([README](../test/memsys/README.md#cache-model)) |

[test/memsys/legality.py](../test/memsys/legality.py) checks the refusals, the negative builds and the options (`python3 test/memsys/legality.py run`). The standard build is checked to be unchanged: the text of `rtl/mcu.sv` that the build selects without the cache defines is the text it had, the CPU files are untouched, and the recorded results of [results/](../results/README.md) reproduce. The cached simulators are compared against the same programs in the standard simulator; timing-exact checks that a cache must change are judged by the warm variants and by the rules of `programs.py` ([test/memsys/README.md](../test/memsys/README.md#with-an-instruction-cache)).

## What Is Not Built

| Not built | Why |
|---|---|
| A data cache and a `DCACHE` option | Only the instruction side is cached. Make refuses `DCACHE` |
| A write buffer, posted stores | Stores go straight to the RAM through the arbiter and are acknowledged after the RAM has written them. It would be built only if the stalls of stores, measured with a data cache, asked for it |
| Abort on a redirect | A started refill always completes. Aborting would save memory traffic only |
| A second way, replacement policy | Direct mapping needs no way multiplexer in front of the branch predictor; two ways would need the synthesis to price it |
| Early restart, critical word first | They need a bypass multiplexer on the predictor path and bring back the risk of answering for a stale address |
| Hit under miss, several misses in flight | The CPU cannot use them |
| Prefetching, a victim buffer | Excluded; they would be modelled before they are built |
| Software-visible counters (CSRs or memory-mapped), a shell `cache` command | Separate work: the counter design. The events above are what it reads |
| An invalidate port for `FENCE.I`, memory-mapped invalidate-all, `Zicbom` | Snooping keeps the cache coherent |
| A run-time enable, flush or bypass switch | The cache is a compile-time choice |
| Refill error paths | The refill cannot get `err` from this memory; if it does, the simulation stops |
| Narrow tags, a block-RAM array style, register slices, a DRAM adapter, a clock crossing, a second cacheable region | Needed only for hardware |
| Other sizes and lines as configurations that are checked in full | The options accept them and one matrix leg runs other line sizes; 512 bytes and 8 KiB with 16-byte lines are the configurations of the proofs and the long runs |
| Write-back | Not planned |
| Any synthesis, and an I-cache-only hardware build | See the limits below |
| Any change to either CPU | The cache is outside the CPUs |

## Limits and Rules for Later Use

- **Simulation only.** The cached configurations have not been synthesised and no run of Vivado is part of them. The standard build and the Basys 3 bitstream have no cache.
- **No I-cache-only hardware build is planned.** In a build with an instruction cache and no data cache, the data side's path from the RAM, which starts at the falling clock edge, would pass through the arbiter and get longer; the timing of the board has no margin to spare for it (see [Building](BUILDING.md#synthesis-and-fpga-timing)). Any use of a cache in hardware would need a synthesis run and a new look at that path.
- **Other writers of the RAM.** The coherence argument rests on every write to the RAM passing interconnect slave 0 while the caches snoop it. Any other writer of the RAM (a DMA engine, a second hart, a debug port) must go through the arbiter with the caches snooping its stores, or use memory that is not cached.
- **A memory that can fail.** The refill has no error path and a data `err` from the RAM is not expected; a memory that can answer `err` needs rules first for what a refill does with it and what the data side sees.
- **A memory adapter that cannot cancel a request.** The simulation wrapper drops a held request at a reset. An adapter that cannot do that must absorb the answers to requests issued before a reset; the cache and the arbiter ignore an answer that arrives without a grant, and do not rely on the memory having dropped the request.
- **What an acknowledged write is.** A write is acknowledged when it is accepted into an in-order queue that later reads cannot overtake. The snoop clears the line at that acknowledgement, and a refill that follows reads the memory after it.
- **The memory port.** It stays a plain Wishbone block port, plus the simulation-only continuation tag, which hardware may leave unconnected. A register slice can be added to it without touching the cache or the arbiter.
