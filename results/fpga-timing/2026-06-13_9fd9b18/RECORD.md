# FPGA timing of the baseline bitstream: WNS +0.242 ns (2026-06-13)

The implementation that produced `bitstream/hades-v-baseline-FIXED.bit` and `.bin` (committed in
9fd9b18): the base core without the branch predictor, with the decoder `rd` fix.

**Status: historical.** The figure comes from commit messages; no report or log of the build
survives, and the exact source tree was not preserved, so the build cannot be repeated exactly.

## Figures and where they are quoted

| Figure as quoted | Quoted at | Source |
|---|---|---|
| +0.242 ns, the upper end of "the recorded results of earlier revisions range from −0.120 ns to +0.242 ns" | docs/BUILDING.md:65; docs/EXTENSIONS.md:85 | commit 9fd9b18: "Verified baseline (no branch predictor) build with the store/branch rd-decode fix. Boots the bootloader and passes the full UART program-load flow in simulation; meets timing (WNS +0.242 ns)." |
| (not quoted in the docs) +0.004 ns with Vivado's default directives | — | commit 6c80a9e: "ExtraTimingOpt/AggressiveExplore directives: the mem-clk half-period critical path closes at only +0.004 ns with defaults, ~+0.24 ns with these ... Same script configuration that produced the submitted baseline bitstream." |

## What is known about the build

- The bitstream header of `bitstream/hades-v-baseline-FIXED.bit` reads
  `top;COMPRESS=TRUE;UserID=0XFFFFFFFF;Version=2024.2`, part `7a35tcpg236`, `2026/06/13 11:38:35`:
  Vivado 2024.2, built on 2026-06-13.
- Per commit 9fd9b18 the design was the baseline core without the branch predictor plus the
  store/branch `rd` decode fix; that fix was committed to the history later, as f8e2232. The tree
  of commit 9fd9b18 itself contains the branch-predictor RTL and not the decoder fix
  (`rtl` `f64c2fe8...` at 9fd9b18 against `a8f9747d...` at f8e2232), so the bitstream was not
  built from any commit of the history.
- Per commit 6c80a9e the flow was the one later committed in `synth/synth.tcl` (timing
  directives `ExtraTimingOpt`/`AggressiveExplore`, the `LUTLP-1` downgrade).
- File checksums: `hades-v-baseline-FIXED.bit` SHA-256
  `ac6469c82f9df1b1a2a690d5abb271b0898383afacc90234c1a059159891312d` (1,118,785 bytes),
  `hades-v-baseline-FIXED.bin` SHA-256 `b844d884f65c120848e50e73a5e4d338b17f8b4b5f106f4da318f3c789847c32`
  (1,118,672 bytes).
- Commit 9fd9b18, which added the files, is dated 2026-06-26.

See [results/history/2026-08-17_15b0b85](../../history/2026-08-17_15b0b85/RECORD.md) for both
bitstreams.

## Environment

- Date: 2026-06-13 (bitstream header).
- Tools: Vivado 2024.2 (bitstream header).
- Host, workers and wall time: not recorded.

## Caveats

- No timing report of this build exists any more; the only figure is the one in the commit
  message, and the worst path of this build is not recorded.
- The source tree cannot be reconstructed exactly from the history.
