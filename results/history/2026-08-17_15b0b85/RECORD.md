# The bitstreams in bitstream/

**Status: historical.** What is known about how the two committed bitstreams were built, from
the commit messages, the bitstream headers and, for the second one, its surviving build output.

## Figures and statements, and where they are quoted

| Statement as quoted | Quoted at |
|---|---|
| "Basys3 bitstreams of two earlier revisions, the base core and the base core with the branch predictor, built before the Zicntr, Zba and M extensions, the `FENCE` forwarding fix and the trap and interrupt fixes" | docs/BUILDING.md:80 |
| "It has not yet been run on a physical board"; "Not yet validated on physical hardware" | README.md:18,115 |
| timing of the two builds, +0.242 ns and +0.221 ns | docs/BUILDING.md:65, docs/EXTENSIONS.md:85 (see `results/fpga-timing/2026-06-13_9fd9b18/` and `results/fpga-timing/2026-08-17_15b0b85/`) |

## The files

| File | Bytes | SHA-256 | Header (design; part; date and time) | Added in |
|---|---|---|---|---|
| `hades-v-baseline-FIXED.bit` | 1,118,785 | `ac6469c82f9df1b1a2a690d5abb271b0898383afacc90234c1a059159891312d` | `top;COMPRESS=TRUE;UserID=0XFFFFFFFF;Version=2024.2`; `7a35tcpg236`; `2026/06/13 11:38:35` | 9fd9b18 (2026-06-26) |
| `hades-v-baseline-FIXED.bin` | 1,118,672 | `b844d884f65c120848e50e73a5e4d338b17f8b4b5f106f4da318f3c789847c32` | (raw configuration data) | 9fd9b18 |
| `hades-v-bpred-FIXED.bit` | 1,099,593 | `0abe0ec3e5a9cdff0d4774db0772bc00d9776c8f7f4dcf49ba753179090f0943` | `top;COMPRESS=TRUE;UserID=0XFFFFFFFF;Version=2024.2`; `7a35tcpg236`; `2026/08/17 01:47:29` | 15b0b85 (2026-08-17) |
| `hades-v-bpred-FIXED.bin` | 1,099,480 | `3c3a2f605a41f604ab8f356c7a7a3949822dace2469ff8254f148d18c6276bd9` | (raw configuration data) | 15b0b85 |

`git log -- bitstream/` lists exactly these two commits.

## How they were built

**Baseline** (`hades-v-baseline-FIXED`). Commit 9fd9b18: "Verified baseline (no branch predictor)
build with the store/branch rd-decode fix. Boots the bootloader and passes the full UART
program-load flow in simulation; meets timing (WNS +0.242 ns)." Built on 2026-06-13 with Vivado
2024.2 (header). The decoder fix was committed to the history later, as f8e2232, and the tree of
9fd9b18 contains the branch-predictor RTL but not that fix, so the bitstream was built from a
tree that is not a commit of the history. Commit 6c80a9e describes its flow: "Same script
configuration that produced the submitted baseline bitstream" (timing directives
`ExtraTimingOpt`/`AggressiveExplore`, `LUTLP-1` downgraded).

**Base core with the branch predictor** (`hades-v-bpred-FIXED`). Commit 15b0b85: "Replaces the
09.06 bpred build, which predated the decoder rd fix and carried the store/branch
register-corruption bug (never flash that one). Built with the repaired synth.tcl (bpredict.sv
sourced, LUTLP-1 waived, ExtraTimingOpt/AggressiveExplore); routed WNS +0.221 ns, 0 of 10511
endpoints failing, hold +0.019 ns, all constraints met." The synthesized sources are those of
15b0b85 (identical at 6c80a9e and 7ec449c). The build output, which survives outside the
repository, is byte-identical to both committed files; its reports are excerpted in
`results/fpga-timing/2026-08-17_15b0b85/`.

The message of 15b0b85 also lists the simulation checks made at its parent commit: "bootloader
banner and full UART hex-programming end-to-end (payload programmed, launched, output OK), asm
ops/forwarding/trap/bpred, decode_exhaustive 11026/11026, execute/writeback golden compares
exactly at their known 30/142 and 9/111 baselines, bp_benchmark: 2-bit counter ~94% accuracy,
~13.7% fewer cycles than never-taken." (The bp_benchmark figures reproduce at 03386fd:
`results/tests/2026-10-01_03386fd/`.)

## What they do not contain

Both predate the Zicntr (80dfaca), Zba (1f501f5) and M (c00c4db) extensions, the `FENCE`
forwarding fix (4261673), the six trap and interrupt fixes (0d25ee6) and the UART fix (03386fd),
as docs/BUILDING.md:80 says.

## Environment

- Builds: 2026-06-13 (baseline; host not recorded) and 2026-08-17 (branch predictor; Intel Core Ultra 7 165H, 22 threads, Linux).
- Tools: Vivado 2024.2 for both (bitstream headers); `Vivado v.2024.2 (lin64) Build 5239630` for the second (its log).

## Caveats

- Neither bitstream has been run on a board.
- The baseline cannot be rebuilt exactly (its source tree is not in the history); the branch
  predictor one could be rebuilt with Vivado 2024.2 from 15b0b85.
