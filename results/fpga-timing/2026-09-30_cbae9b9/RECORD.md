# FPGA timing of the RTL of cbae9b9: WNS +0.016 ns (Vivado 2024.2, 2026-09-30)

A full `make synthesis` (Vivado 2024.2, Basys3 `xc7a35tcpg236-1`, 50 MHz) of the RTL of commit
cbae9b9, made on 2026-09-30 to check the documentation. The synthesized sources of cbae9b9 differ
from those of 03386fd only in the one-token UART fix of commit 03386fd
(`lib/wishbone/wishbone_uart.sv`, `wb_write_rx_status` → `wb_write_tx_status` in the transmit
interrupt-enable write-through), which was not implemented.

**Status: needs Vivado.** The run can be repeated with Vivado 2024.2 from a checkout of cbae9b9
(command below); it was not repeated for this record, because Vivado runs are paused until a board
is chosen. The 03386fd RTL itself has not been implemented.

## Figures and where they are quoted

| Figure as quoted | Quoted at | This run (verbatim from the reports) |
|---|---|---|
| worst negative slack **+0.016 ns**, no failing endpoint | README.md:114; docs/BUILDING.md:65; docs/EXTENSIONS.md:85 | `WNS(ns) 0.016`, `TNS(ns) 0.000`, `TNS Failing Endpoints 0` |
| 0 failing endpoints of 11070 | docs/EXTENSIONS.md:85 | `TNS Total Endpoints 11070` |
| "a repeated run gives the same result" | README.md:114; docs/BUILDING.md:65; docs/EXTENSIONS.md:85 | see *Repetition* below: three runs, byte-identical configuration data, the same timing |
| worst path from the block RAM (falling edge) through the branch predictor and the PC adder to the Fetch PC register, half a clock period | README.md:114; docs/BUILDING.md:65; docs/EXTENSIONS.md:85 | `Source: mcu/ram/memory_reg_bram_3/CLKARDCLK (falling edge-triggered cell RAMB36E1 ...)`, `Destination: mcu/cpu/i_fetch/pc_reg[26]/D`, `Requirement: 10.000ns (clk rise@20.000ns - clk fall@10.000ns)`, through `mcu/ram/fetch_bus\\.dat_miso[6]`, `.../i_branch_predictor/bp_prediction[predicted_taken]` and the `pc_reg[...]_i_5` carry chain |
| 14 logic levels, 7 of them carry-chain stages, about 53 % of the delay in logic | docs/EXTENSIONS.md:85 | `Logic Levels: 14 (CARRY4=7 LUT3=1 LUT4=1 LUT5=1 LUT6=3 MUXF7=1)`, `Data Path Delay: 9.801ns (logic 5.150ns (52.547%) route 4.651ns (47.453%))` |
| Vivado 2024.2 | README.md:114; docs/BUILDING.md:32,57,63,65 | `Vivado v.2024.2 (lin64) Build 5239630 Fri Nov 08 22:34:34 MST 2024` |
| (not quoted) worst hold slack | — | `WHS(ns) 0.069`, 0 failing of 11070 |
| (not quoted) utilization | — | Slice LUTs 5482 (26.36 %), Slice Registers 3091 (7.43 %), Block RAM Tile 46 of 50 (RAMB36 46, RAMB18 0), DSPs 4 of 90 |

The excerpts are in [`timing-summary.txt`](timing-summary.txt) (design timing summary, clock
summary, per-clock table), [`worst-paths.txt`](worst-paths.txt) (the worst setup path and the
worst hold path of `clk`, cell by cell) and [`utilization.txt`](utilization.txt) (slice logic,
memory, DSP, IO and clocking).

## Repetition

The configuration data of this run, `hades-v.bin`, has MD5 `e6ce9038129844e0b035e6e6feca0523`
(SHA-256 `ca500952c604e7801c358b49f5479a72199093161342b9e24a9d657ba3c2bb66`, 1,153,280 bytes). The
development log of 2026-09-28 records two earlier `make synthesis` runs of the same synthesized
sources, one with the default build directory and one with a relocated build directory (11 min 48 s
and 12 min 31 s), whose `hades-v.bin` had the same MD5, `e6ce9038129844e0b035e6e6feca0523`, and
whose `timing_pnr.rpt` reported `WNS 0.016 ns, TNS 0.000, 0 failing endpoints of 11070; WHS 0.069`.
That run was first quoted by commit 62b0407 (2026-09-28). Three runs on two days therefore gave
byte-identical configuration data and the same timing: Vivado 2024.2 is deterministic for this
flow on this machine. The synthesized sources (`rtl`, `lib`, `defines`, `synth`, `std`,
`test/c/bootloader.c`) are identical from commit 6b19d41 to cbae9b9.

## Command

From a clone at cbae9b9, at the repository root:

```bash
git checkout cbae9b9
make synthesis XILINX_VIVADO=<Vivado 2024.2 installation directory>
# reports: build/synth/reports/timing_pnr.rpt, utilization_pnr.rpt; bitstream: build/synth/hades-v.bit/.bin
```

The run of record used a relocated build directory (`BUILD_DIR=<dir>`); the 2026-09-28 runs show
that the build directory does not change the result. The flow is `synth/synth.tcl`:
`synth_design`, `opt_design`, `place_design -directive ExtraTimingOpt`,
`phys_opt_design -directive AggressiveExplore`, `route_design -directive AggressiveExplore`,
`phys_opt_design -directive AggressiveExplore`, then `write_bitstream` with the `LUTLP-1`
combinational-loop check downgraded to a warning.

## Inputs

Base commit `cbae9b9` (synthesized sources identical to those of 499d488; they differ from 03386fd
only in `lib/wishbone/wishbone_uart.sv`). Fingerprints (`git rev-parse cbae9b9:<path>`):
`rtl` `031b989be1f25dd20836028c5126a5b1dc562bd7` (the same at 03386fd), `lib`
`fc6d9f8f3f684a11f5d5d1314edac9b84283493a` (03386fd: `f90a9a64ddc67db6642bc6654545f1509744426b`),
`defines` `36f0452de823189873ca8ac79d7a662918961ad6`, `synth` `e3daf996a9888deb3461729e7b38821ff92089e2`,
`std` `05909d5f7dd5d23f80a2d11e127fdb79eb8a5468`, `test/c/bootloader.c`
`5e15beb78e087276670f5a5539881bc6be433333` (the bootloader image is the initial content of the
RAM). The checked-out files of the tree that was implemented were compared with cbae9b9 file by
file (48 files under `rtl`, `lib`, `defines`, `synth`, `std`, `sim`): identical.

## Environment

- Date: 2026-09-30 (Vivado session 23:45:34 to 23:57:18).
- Host: Intel Core Ultra 7 165H, 22 threads, Linux.
- Tools: `Vivado v.2024.2 (lin64) Build 5239630 Fri Nov 08 22:34:34 MST 2024`; the bootloader
  image built with `riscv32-unknown-elf-gcc () 12.2.0`.
- Workers: Vivado's default (`Running DRC with 8 threads`).
- Wall time: 705.45 s for `make synthesis`.
- Bitstream header: `top;COMPRESS=TRUE;UserID=0XFFFFFFFF;Version=2024.2`, part `7a35tcpg236`,
  `2026/09/30 23:54:18`. Neither the bitstream nor the full reports are stored here.

## Verbatim summary output

```text
    WNS(ns)      TNS(ns)  TNS Failing Endpoints  TNS Total Endpoints      WHS(ns)      THS(ns)  THS Failing Endpoints  THS Total Endpoints     WPWS(ns)     TPWS(ns)  TPWS Failing Endpoints  TPWS Total Endpoints
    -------      -------  ---------------------  -------------------      -------      -------  ---------------------  -------------------     --------     --------  ----------------------  --------------------
      0.016        0.000                      0                11070        0.069        0.000                      0                11070        2.633        0.000                       0                  3200


All user specified timing constraints are met.
```

```text
Synthesis finished with 0 errors, 3 critical warnings and 196 warnings.
CRITICAL WARNING: [DRC LUTLP-1] Combinatorial Loop Alert: 16 LUT cells ...   (downgraded before write_bitstream, as synth/synth.tcl does)
INFO: [Route 35-20] Post Routing Timing Summary | WNS=-1.028 | TNS=-34.704| WHS=0.069  | THS=0.000  |
INFO: [Physopt 32-668] Current Timing Summary | WNS=0.016 | TNS=0.000 | WHS=0.069 | THS=0.000 |
write_bitstream completed successfully
```

## Caveats

- The margin is marginal by any measure: +0.016 ns on a 10 ns half-period path.
- Routing alone ended at WNS −1.028 ns (TNS −34.704 ns); the final `phys_opt_design` after
  routing, which `synth/synth.tcl` runs, transformed logic on the failing paths and reached
  +0.016 ns. The result therefore depends on that post-route step.
- The documentation's statement that the worst path "runs from the block RAM ... through the
  branch predictor and its PC adder to the Fetch stage's PC register" describes this run's worst
  path; earlier revisions had different worst paths (see the other records under
  `results/fpga-timing/`).
- `write_bitstream` does not check timing; only `timing_pnr.rpt` shows whether timing is met.
- The 03386fd RTL (with the UART fix) has not been implemented. The fix changes the source of one
  multiplexer select in the UART, so its timing is expected to be close, but that is not measured.
- Not validated on physical hardware.

## Files

- `RECORD.md`: this file. `meta.json`: the same, machine-readable.
- `timing-summary.txt`, `worst-paths.txt`, `utilization.txt`: verbatim excerpts of the reports
  (the reports' `Host` lines are left out).

**Update, 2026-10-02 (Zbb, Zbs and Zicond).** This record was titled "FPGA timing of the current RTL"; it no longer is. Zbb, Zbs and Zicond add a unit to the Execute stage (`rtl/execute_stage.sv`, Part 2c) whose result joins the ALU's result select, and new decoding to `rtl/instruction_decoder.sv`. That RTL has not been implemented, because Vivado runs are paused until a board is chosen, so whether it meets 50 MHz is unknown. The figures above are unchanged and still describe commit cbae9b9.
