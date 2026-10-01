# FENCE.I staleness window: first measurement, 2026-08-17, 15b0b85

**Status: historical.** This is the measurement behind the "3-slot staleness window", made with a program that was never committed. It was recovered from the development log, and `make bench-fencei-window` now runs it: see [the record of 2026-10-01](../2026-10-01_03386fd/RECORD.md).

## The figures and where they are quoted

[README.md](../../../README.md) line 73: "`FENCE.I` was implemented but never actually verified upstream; now tested against a measured 3-slot staleness window".

[docs/EXTENSIONS.md](../../../docs/EXTENSIONS.md) lines 199 and 200:

> - **The staleness window is 3 instruction slots.** Measured by sweeping the patch distance with `FENCE.I` removed: words at `sw+4`, `sw+8` and `sw+12` executed stale, while `sw+16` and beyond were fresh. Forcing extra stall cycles into the gap does not narrow it — Fetch holds both its PC and its instruction register while stalled, so stalling can never refresh an already-latched instruction.
> - **The `sw+12` case is simulator-specific.** At that distance the patch is a same-cycle, cross-port read/write collision in the block RAM. Verilator resolves it deterministically to *read-old*; on real Xilinx BRAM, cross-port collision data is **undefined**. [...]

As found in the development log of 2026-08-17, 19:16 to 19:25 (UTC−4). The program `test/asm/fencei_stale.s` patches, with `sw`, the instruction D bytes after the store, which then runs; the gap holds only `nop`s, and the patched instruction records whether its old (`addi a0, zero, 1`) or new (`addi a0, zero, 2`) word executed. Two controls: `FENCE.I` in the gap at 8 bytes, and at 12 bytes two loads from the test peripheral's stall register. Its final version printed (verbatim, the end of the output, colour codes removed):

```
--- fence.i negative control: instruction patched at sw+D, no fence.i ---
  sw+4  (0 nops in gap) : OLD (STALE)
  sw+8  (1 nop  in gap) : OLD (STALE)
  sw+12 (2 nops in gap) : OLD (STALE)
  sw+16 (3 nops in gap) : NEW (fresh)
  sw+20 (4 nops in gap) : NEW (fresh)
  sw+8  (fence.i in gap): NEW (fresh)
  sw+12 (2 stalling lw ) : OLD (STALE)
( 71260 ps) Test pass!
( 71380 ps) Test pass!
( 71500 ps) Test pass!
( 71620 ps) Test pass!
( 71740 ps) Test pass!
( 71860 ps) Test pass!
( 71980 ps) Test pass!
( 72100 ps) Test pass!
( 72200 ps) Test pass!
( 72300 ps) Test pass!
( 72400 ps) Test pass!
( 72500 ps) Test pass!
( 72600 ps) Test pass!
( 72700 ps) Test pass!
( 72800 ps) Test pass!
- sim/top.sv:94: Verilog $finish

All tests passed! (# Errors: 1 = initial test)
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!!!!!!!!!!!!!!!!!!!! TEST DONE !!!!!!!!!!!!!!!!!!!!
```

The program's own checks lock the result in: stale at 4, 8 and 12 bytes, fresh at 16 and 20, fresh with `FENCE.I`, and the stalling case equal to the plain one at 12 bytes. A probe, `stall_probe.s`, measured with `mcycle` the cycles of two `nop`s, of the two stalling loads and of two loads that do not stall (verbatim):

```
3 6 3 
```

That is, the stalling loads add 3 cycles to the gap.

## Where it was measured

In a clean working copy of 15b0b85 ("Add bpred bitstream built from fixed RTL"), to which only the new program was added. The documentation text was committed later that evening in 37e2d67, "Substantiate the Zifencei claim: real FENCE.I test + README section", together with `test/asm/fencei.s`; `fencei_stale.s` itself was not committed. Trees of 15b0b85 (`git rev-parse 15b0b85:<dir>`): rtl `a8f9747d507b5ae806db6bb9b8f352f7fd8fcf13`, lib `9273a2fb0857718dc9e0ca7d2f98afbba2bdab03`, defines `699b7071bdae814c98f9eb7e18a141b5f9cab705`, sim `b9ea689e3115da8714c525858c64d7131505378f`, std `05909d5f7dd5d23f80a2d11e127fdb79eb8a5468`.

## How it was measured

Both programs were assembled and run as assembly tests (`make test/asm/fencei_stale`, `make test/asm/zz_probe`). They are now `test/bench/fencei-window/fencei_stale.s` (sha256 of the original `920a95c924a978d4608c7cf730e389aff86165b25c06255228d3ad719f5d21ac`) and `stall_probe.s` (original `530d1a3a819baf0cf125b6b8fba241fbac8483bd753d922532e8f15d7553a03c`), unchanged after the license header. `fencei_stale.s` was reconstructed from its first version and the four edits recorded in the log: the line numbers that the log shows after the third edit, and the addresses of its final disassembly, match the reconstruction.

## Environment

- Date: 2026-08-17
- Tools named in the log: Verilator 5.042 2025-11-02; riscv32-unknown-elf-gcc 12.2.0, binutils 2.39.
- Host and wall time: not recorded.

## Re-runs on 2026-10-01

- On a simulator built from 15b0b85, the recovered programs, whose images are byte-identical to those that `make bench-fencei-window` builds, print exactly the lines above, including the times of the 15 passing checks (71260 to 72800), and the probe prints `3 6 3`.
- On 03386fd, `make bench-fencei-window` gives the same result: [the record of 2026-10-01](../2026-10-01_03386fd/RECORD.md).

## Caveats

- "With `FENCE.I` removed" in the documentation means that the program does not execute `FENCE.I`; no RTL was changed.
- The `sw+12` result depends on a same-cycle cross-port read/write of the block RAM: the old word in Verilator, undefined on a Xilinx block RAM. The log already said so, and that the mechanism was inferred from the RTL and the measured boundary, not confirmed in a waveform.
- The comment of check 5 in the program speaks of "6 cycles of pipeline stall": the two loads take 6 cycles where two `nop`s take 3, so they add 3 stall cycles, as the probe shows.
