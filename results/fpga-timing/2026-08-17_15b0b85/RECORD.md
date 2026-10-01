# FPGA timing of the branch-predictor bitstream: WNS +0.221 ns (2026-08-17)

The implementation that produced `bitstream/hades-v-bpred-FIXED.bit` and `.bin` (committed in
15b0b85): the base core with the branch predictor and the decoder `rd` fix, before the Zicntr,
Zba and M extensions.

**Status: historical.** The figures come from the commit message of 15b0b85 and from the
build's own reports, which survive outside the repository and are excerpted here. The build
could be repeated with Vivado 2024.2 from a checkout of 15b0b85, but it has not been. The status is *historical* rather than *needs Vivado* because the figure is that of the original build, whose reports were not kept (or kept only in part); a rebuild would make a new record ([results/README.md](../../README.md#status)).

## Figures and where they are quoted

| Figure as quoted | Quoted at | Source |
|---|---|---|
| "the +0.221 ns recorded with the branch-predictor bitstream (commit 15b0b85) predates the `Zicntr` and `Zba` commits" | docs/EXTENSIONS.md:85 | commit 15b0b85: "routed WNS +0.221 ns, 0 of 10511 endpoints failing, hold +0.019 ns, all constraints met"; report: `0.221  0.000  0  10511  0.019  0.000  0  10511` |
| the recorded results of earlier revisions range from −0.120 ns to +0.242 ns | README.md:114 (missed by 0.120 ns); docs/BUILDING.md:65; docs/EXTENSIONS.md:85 | this record is one of them; see also `../2026-08-18_c00c4db/` and `../2026-06-13_9fd9b18/` |

From the report excerpts ([`timing-excerpt.txt`](timing-excerpt.txt),
[`utilization-excerpt.txt`](utilization-excerpt.txt)):

- `WNS(ns) 0.221`, `TNS(ns) 0.000`, `TNS Failing Endpoints 0`, `TNS Total Endpoints 10511`;
  `WHS(ns) 0.019`; `All user specified timing constraints are met.`
- Worst setup path: `Source: mcu/cpu/i_memory/instruction_reg_out_reg[csr][4]/C`,
  `Destination: mcu/ram/memory_reg_bram_6/WEBWE[3]` (falling edge), `Requirement: 10.000ns`,
  `Data Path Delay: 9.182ns (logic 1.882ns (20.497%) route 7.300ns (79.503%))`,
  `Logic Levels: 11 (LUT4=3 LUT5=2 LUT6=6)`: from the Memory stage's instruction register to the
  RAM's write enable, within half a clock period.
- Utilization: Slice LUTs 4752, Slice Registers 2909, Block RAM Tile 46 (of 50), DSPs 0.

## Provenance

- The build ran on 2026-08-17 from 01:41:47 to 01:50:30 (Vivado session times), with
  `Vivado v.2024.2 (lin64) Build 5239630`, the repaired flow of commit 6c80a9e (`bpredict.sv`
  sourced, `LUTLP-1` downgraded to a warning, `ExtraTimingOpt`/`AggressiveExplore` directives).
  Its log reports `Post Routing Timing Summary | WNS=0.221 | TNS=0.000 | WHS=0.019 | THS=0.000`
  and a `LUTLP-1` combinational-loop alert over 15 LUT cells, waived as the flow does.
- The build's `hades-v.bit` and `hades-v.bin` are byte-identical to the committed
  `bitstream/hades-v-bpred-FIXED.bit` (SHA-256 `0abe0ec3e5a9cdff0d4774db0772bc00d9776c8f7f4dcf49ba753179090f0943`)
  and `bitstream/hades-v-bpred-FIXED.bin` (SHA-256 `3c3a2f605a41f604ab8f356c7a7a3949822dace2469ff8254f148d18c6276bd9`).
  The bitstream header reads `top;COMPRESS=TRUE;UserID=0XFFFFFFFF;Version=2024.2`, part
  `7a35tcpg236`, `2026/08/17 01:47:29`.
- The synthesized sources are identical at 6c80a9e, 7ec449c and 15b0b85 (15b0b85 adds only the
  bitstream files): `rtl` `a8f9747d507b5ae806db6bb9b8f352f7fd8fcf13`, `lib`
  `9273a2fb0857718dc9e0ca7d2f98afbba2bdab03`, `defines` `699b7071bdae814c98f9eb7e18a141b5f9cab705`,
  `synth` `774b210bcaa097aac7812d08aa9d419851be5cbd`, `std` `05909d5f7dd5d23f80a2d11e127fdb79eb8a5468`,
  `test/c/bootloader.c` `5e15beb78e087276670f5a5539881bc6be433333`.
- Host: Intel Core Ultra 7 165H, 22 threads, Linux.

## Command (to repeat it)

```bash
git checkout 15b0b85
make synthesis XILINX_VIVADO=<Vivado 2024.2 installation directory>
```

## Caveats

- One run. On this design, runs of the same RTL with a different script have differed by about
  1 ns (see `../2026-08-18_c00c4db/`), so the figure is a single data point.
- The worst path of this build (Memory instruction register to the RAM write enable) is not the
  worst path of later revisions.
- The reports quoted here are those of the build itself, kept outside the repository; only the
  excerpts are stored.
