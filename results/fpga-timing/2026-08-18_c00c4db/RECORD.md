# FPGA timing when M was added: WNS −0.120 ns at c00c4db, +0.026 ns at its parent (2026-08-18)

The implementation of the commit that added the M extension (c00c4db) and of its parent
(1f501f5, Zba), with the same flow on the same machine and day, Vivado 2024.2, Basys3
`xc7a35tcpg236-1`, 50 MHz.

**Status: historical.** The figures come from the message of commit c00c4db, the README of that
commit, and the development log of 2026-08-18; the reports were not kept. Each build could be
repeated with Vivado 2024.2 from a checkout of the commit, but has not been. The status is *historical* rather than *needs Vivado* because the figure is that of the original build, whose reports were not kept (or kept only in part); a rebuild would make a new record ([results/README.md](../../README.md#status)).

## Figures and where they are quoted

| Figure as quoted | Quoted at | Source |
|---|---|---|
| c00c4db: post-route **WNS −0.120 ns**, 2 failing endpoints of 11214 | docs/EXTENSIONS.md:85; README.md:114 ("missed timing by 0.120 ns ... from the Memory stage's instruction register to `mcause`"); docs/BUILDING.md:65 (range −0.120 to +0.242) | commit c00c4db: "post-route WNS -0.120 ns, 2 failing endpoints"; README.md of c00c4db, line 159: "2 failing endpoints of 11214" |
| its parent: **+0.026 ns** with none failing | docs/EXTENSIONS.md:85 | commit c00c4db: "against +0.026 ns on the preceding commit" |
| the 0.15 ns that M cost | docs/EXTENSIONS.md:85 | +0.026 − (−0.120) = 0.146 ns |
| no M cell in the 40 worst paths; multiply +6.15 ns, divider +10.19 ns | docs/EXTENSIONS.md:85,87 | commit c00c4db: "No M cell appears in the 40 worst paths (multiply closes +6.15 ns, divider +10.19 ns)" |
| failing path: pre-existing 21-level, ~85 %-route path from the Memory stage's instruction register through the waived `LUTLP-1` tangle to the `mcause` register's clock enable | docs/EXTENSIONS.md:85; README.md:114 | commit c00c4db: "the pre-existing 21-level, 85%-route interrupt path through the waived LUTLP-1 tangle to mcause" |
| M's ~9 % area growth | docs/EXTENSIONS.md:85 | commit c00c4db: "M's ~9% area growth" (see the numbers below) |
| Vivado did not absorb the multiply's output register into the DSP48E1 `P` register | docs/EXTENSIONS.md:87 | development log of 2026-08-18: the synthesis DSP mapping report of the M tree (4 DSP48E1 of 90; 0 before M) |

## What the development log of 2026-08-18 records

The log holds the report excerpts of four implementations made that morning (about 09:30 to
10:15 local time, before the commit at 10:18):

| Run | Tree | WNS / TNS | Failing / total endpoints | WHS | Slice LUTs | Slice registers | DSPs | Worst setup path |
|---|---|---|---|---|---|---|---|---|
| `make synthesis` | M tree (committed as c00c4db) | −0.120 / −0.240 ns | 2 / 11214 | +0.047 ns | 5376 | 3146 | 4 | `mcu/cpu/i_memory/instruction_reg_out_reg[csr][6]/C` → `mcu/cpu/i_writeback/mcause_reg[16]/CE`, requirement 20 ns, `Data Path Delay: 19.824ns (logic 3.060ns (15.436%) route 16.764ns (84.564%))`, `Logic Levels: 21 (LUT2=1 LUT3=1 LUT4=1 LUT5=5 LUT6=13)` |
| `make synthesis` | parent, 1f501f5 | +0.026 / 0.000 ns | 0 / 10595 | +0.054 ns | 4966 | 2937 | 0 | (not recorded) |
| the same placement and routing directives plus extra reports (top 40 paths, DSP, divider) | M tree | −1.054 / −13.450 ns | 27 / 11025 | +0.027 ns | 5309 | 3106 | 4 | `instruction_reg_out_reg[csr][2]` → `mcause_reg[10]/CE`; multiply path `+6.151ns` (`i_decode/instruction_reg_out_reg[op][1]` → `i_execute/m_mul_reg_reg[31]`, `Logic Levels: 12 (CARRY4=7 DSP48E1=2 ...)`); divider path `+10.191ns` (`i_execute/m_rem_reg[0]` → `i_decode/rs2_data_reg_out_reg[31]`); 0 M cells in the 40 worst paths |
| the same script | parent tree (M changes set aside) | −0.883 / −6.537 ns | 15 / 10433 | +0.010 ns | 4918 | 2906 | 0 | `instruction_reg_out_reg[csr][5]` → `mcause_reg[28]/CE`, `Data Path Delay: 20.571ns (logic 3.256ns (15.828%) route 17.315ns (84.172%))`, 21 levels |

The multiply and divider slacks and the "40 worst paths" statement therefore come from the third
run, the −0.120 ns from the first. The same RTL with the same directives gave −0.120 ns and
−1.054 ns (M tree), +0.026 ns and −0.883 ns (parent tree) when only the reporting commands of the
script differed: that is the "run-to-run variance ... ~1 ns" of the commit message.

The area growth: the two `make synthesis` runs give 4966 → 5376 Slice LUTs (+8.3 %) and 2937 →
3146 registers (+7.1 %); the two runs of the reporting script give 4918 → 5309 LUTs (+8.0 %). The
"~9 %" of the commit message equals 5376 against 4918 (+9.3 %), a pair from different scripts.

## Commands (to repeat them)

```bash
git checkout c00c4db && make synthesis XILINX_VIVADO=<Vivado 2024.2 installation directory>
git checkout 1f501f5 && make synthesis XILINX_VIVADO=<Vivado 2024.2 installation directory>
```

## Inputs

c00c4db `c00c4dbae728820ae6f3f94de568eac87b41a590`: `rtl` `184ba0352d5a21d130d7f31c215b0130c9b85685`,
`defines` `77ae7c8984915dc833bf68e1e5d32b267b8a02bf`. 1f501f5 `1f501f509ccb71b84e499bc3b4aea90f30f1cfe4`:
`rtl` `d990b12c0ed76026f7143c4e36357b943afd7325`, `defines` `5593f63e4478a326c1ce53f365d6385f16362689`.
Common to both: `lib` `10e725f3ea301c460e5cc6fe85372f7d7a56ff3b`, `synth`
`774b210bcaa097aac7812d08aa9d419851be5cbd`, `std` `05909d5f7dd5d23f80a2d11e127fdb79eb8a5468`,
`test/c/bootloader.c` `5e15beb78e087276670f5a5539881bc6be433333`.

## Environment

- Date: 2026-08-18. Host: Intel Core Ultra 7 165H, 22 threads, Linux.
- Tools: `Vivado v.2024.2 (lin64) Build 5239630`.

## Caveats

- The reports were not kept; the numbers above are those printed into the development log from
  the reports at the time.
- The M tree that was implemented is the working tree that was committed as c00c4db shortly
  afterwards; that the committed RTL is byte-identical to the implemented tree is not recorded.
- The worst path has moved since: at cbae9b9 it runs from the block RAM through the branch
  predictor to the Fetch PC (`../2026-09-30_cbae9b9/`).
