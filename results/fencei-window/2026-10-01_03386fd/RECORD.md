# FENCE.I staleness window: 2026-10-01, 03386fd

**Status: repeatable.** `make bench-fencei-window` reproduces the window exactly.

## The figures and where they are quoted

[README.md](../../../README.md) line 73: "`FENCE.I` was implemented but never actually verified upstream; now tested against a measured 3-slot staleness window".

[docs/EXTENSIONS.md](../../../docs/EXTENSIONS.md) lines 199 and 200:

> - **The staleness window is 3 instruction slots.** Measured by sweeping the patch distance with `FENCE.I` removed: words at `sw+4`, `sw+8` and `sw+12` executed stale, while `sw+16` and beyond were fresh. Forcing extra stall cycles into the gap does not narrow it — Fetch holds both its PC and its instruction register while stalled, so stalling can never refresh an already-latched instruction.
> - **The `sw+12` case is simulator-specific.** At that distance the patch is a same-cycle, cross-port read/write collision in the block RAM. Verilator resolves it deterministically to *read-old*; on real Xilinx BRAM, cross-port collision data is **undefined**. [...]

| Quoted | Measured here |
|---|---|
| `sw+4`, `sw+8` and `sw+12` executed stale | the old word executes at 4, 8 and 12 bytes after the store |
| `sw+16` and beyond were fresh | the new word executes at 16 and 20 bytes |
| extra stall cycles do not narrow it | at 12 bytes, with two loads from the test peripheral's stall register in the gap (6 cycles where two `nop`s take 3: 3 stall cycles), the old word still executes |
| (control) | with `FENCE.I` in the gap, the new word executes at 8 bytes |

## Commands

From the repository root, on 03386fd with `test/bench/` and the bench targets of the `Makefile` added (the files and their sha256 are listed in [`inputs.sha256`](inputs.sha256)):

```
make bench-fencei-window
```

## Inputs

- Base commit `03386fdda932f4827cded26e8cfc2a2cc531b365`; its trees (`git rev-parse 03386fd:<dir>`): rtl `031b989be1f25dd20836028c5126a5b1dc562bd7`, lib `f90a9a64ddc67db6642bc6654545f1509744426b`, defines `36f0452de823189873ca8ac79d7a662918961ad6`, sim `0dad5608c126445abb808c5addd7b6e9d4df54c7`, std `05909d5f7dd5d23f80a2d11e127fdb79eb8a5468`.
- Added on top of it: the `Makefile` with the bench targets, `test/bench/bench.mk`, `test/bench/bench.py` and the programs, with their sha256 in [`inputs.sha256`](inputs.sha256). After their license headers, `fencei_stale.s` and `stall_probe.s` are byte-identical to the programs of 2026-08-17. Those fingerprints are of the files the run used. Some of them changed afterwards, before they were committed (the `Makefile` gained the `check-results` target and help text, `bench.mk` and `fencei_stale.s` header comments): [`rechecked.sha256`](rechecked.sha256) lists the changed files as committed, with which `make check-results` reproduced this record exactly; `sha256sum -c inputs.sha256` reports those files as `FAILED`. Correction (2026-10-01): the `Makefile` line of `inputs.sha256` had been changed to the extended file (sha256 `2cd15d50…834a`); it again names the file the run used.
- Products: the `init.mem` images are fingerprinted in [`meta.json`](meta.json) (the assembled ELFs are not, because the assembler records a temporary file name in them); [`results.csv`](results.csv) has one row per case.

## Environment

- Date: 2026-10-01
- Host: Intel Core Ultra 7 165H, 22 threads, Linux
- Tools: Verilator 5.042 2025-11-02 rev v5.042; riscv32-unknown-elf-gcc () 12.2.0 with GNU Binutils 2.39; Python 3.12.3; GNU Make 4.3
- Workers: 1. Wall time of `make bench-fencei-window` with the simulator already built: 0.06 s (programs built and run), 0.04 s when only run.

## Output

`make bench-fencei-window`, the summary printed after the build commands (verbatim):

```
FENCE.I staleness window (test/bench/fencei-window/fencei_stale.s)
A store patches the instruction D bytes after it, which then runs; the gap holds nops
(or the instruction named); OLD = the word before the store executed, NEW = the patched one.

  sw+4  (0 nops in gap)   : OLD (STALE)
  sw+8  (1 nop  in gap)   : OLD (STALE)
  sw+12 (2 nops in gap)   : OLD (STALE)
  sw+16 (3 nops in gap)   : NEW (fresh)
  sw+20 (4 nops in gap)   : NEW (fresh)
  sw+8  (fence.i in gap)  : NEW (fresh)
  sw+12 (2 stalling lw )  : OLD (STALE)

  the program's own checks: All tests passed! (# Errors: 1 = initial test)
  stall_probe.s, cycles between two mcycle reads: two nops 3, the two loads of the
  "2 stalling lw" case 6, two loads that do not stall 3

  window: the 3 instruction slots after the store (sw+4, sw+8, sw+12) run the old
  word, sw+16 and later the new one; FENCE.I at sw+8 gives the new word; 3 stall
  cycles in the gap leave sw+12 old.
  caveat: at sw+12 the fetch reads the word in the same cycle as the store writes it,
  through the other port of the block RAM. Verilator returns the old word; on a Xilinx
  block RAM the data read in that case is undefined, so sw+12 is "not reliably fresh".

BENCH FENCEI-WINDOW: PASS
```

The run logs of both programs are in [`logs/`](logs) (colour codes removed).

## Caveats

- "With `FENCE.I` removed" means that the measuring program does not execute `FENCE.I`; the RTL is not changed.
- At 12 bytes the fetch reads the word through one port of the block RAM in the same cycle as the store writes it through the other. Verilator returns the old word, deterministically; on a Xilinx block RAM the data read in that case is undefined. On the FPGA, the `sw+12` instruction is therefore not reliably fresh, rather than certainly stale. `sw+4` and `sw+8` are stale on both, because those instructions are already in pipeline registers when the store writes the memory.
- That `sw+12` is such a collision was inferred from the RTL (`lib/wishbone/wishbone_ram.sv` is clocked on the inverted clock, port A fetching, port B for data) and from the boundary falling at exactly three slots; it has not been confirmed in a waveform.
- The program checks the window itself and, like every assembly test, fails its first check on purpose: a correct run ends in `All tests passed! (# Errors: 1 = initial test)`.
- The same programs give the same output, including the time of each check, on a simulator built from 15b0b85: see [the first measurement](../2026-08-17_15b0b85/RECORD.md).
