# Self-checking suites at 03386fd

Every self-checking suite listed under *Suites and Results* in
[docs/VERIFICATION.md](../../../docs/VERIFICATION.md#suites-and-results), the programs that print
no verdict of their own, and the FreeRTOS figures of [docs/FREERTOS.md](../../../docs/FREERTOS.md),
re-run from a fresh clone at commit 03386fd on 2026-10-01.

**Status: repeatable.** Every command below reproduced the documented result exactly; the
simulations are deterministic, so the same commands give the same output on every run.

Covered elsewhere: the trap and interrupt sweep (`python3 test/trapsweep/sweep.py run`) in
[results/trapsweep/2026-10-01_03386fd](../../trapsweep/2026-10-01_03386fd/RECORD.md); the formal
proof (`make formal`) in [results/formal/2026-09-28_588d76a](../../formal/2026-09-28_588d76a/RECORD.md);
the validation campaign (`make freertos-stress`) in
[results/freertos-validate/2026-10-01_03386fd](../../freertos-validate/2026-10-01_03386fd/RECORD.md).

## Results

The output column is verbatim (only the key lines; `results.csv` has every extracted line). The
column *As documented* gives the text as the documentation quotes it.

| Suite | Command | Output (verbatim) | As documented | Quoted at |
|---|---|---|---|---|
| asm/ops | `make test/asm/ops` | `All tests passed! (# Errors: 1 = initial test)` | All tests passed! (# Errors: 1 = initial test) | docs/VERIFICATION.md:36; README.md:49,85 |
| asm/forwarding | `make test/asm/forwarding` | `All tests passed! (# Errors: 1 = initial test)` | All tests passed! (# Errors: 1 = initial test) | docs/VERIFICATION.md:37 |
| asm/trap | `make test/asm/trap` | `All tests passed! (# Errors: 1 = initial test)` | All tests passed! (# Errors: 1 = initial test) | docs/VERIFICATION.md:38 |
| asm/trapirq | `make test/asm/trapirq` | `All tests passed! (# Errors: 1 = initial test)` | All tests passed! (# Errors: 1 = initial test) | docs/VERIFICATION.md:39 |
| asm/trapmpie | `make test/asm/trapmpie` | `All tests passed! (# Errors: 1 = initial test)` | All tests passed! (# Errors: 1 = initial test) | docs/VERIFICATION.md:39 |
| asm/csrirq | `make test/asm/csrirq` | `All tests passed! (# Errors: 1 = initial test)` | All tests passed! (# Errors: 1 = initial test) | docs/VERIFICATION.md:39 |
| asm/memirq | `make test/asm/memirq` | `All tests passed! (# Errors: 1 = initial test)` | All tests passed! (# Errors: 1 = initial test) | docs/VERIFICATION.md:39 |
| asm/mtvecirq | `make test/asm/mtvecirq` | `All tests passed! (# Errors: 1 = initial test)` | All tests passed! (# Errors: 1 = initial test) | docs/VERIFICATION.md:39 |
| asm/uartirq | `make test/asm/uartirq` | `All tests passed! (# Errors: 1 = initial test)` | All tests passed! (# Errors: 1 = initial test) | docs/VERIFICATION.md:40 |
| asm/mul | `make test/asm/mul` | `All tests passed! (# Errors: 1 = initial test)` | All tests passed! (# Errors: 1 = initial test) | docs/VERIFICATION.md:41 |
| asm/div | `make test/asm/div` | `All tests passed! (# Errors: 1 = initial test)` | All tests passed! (# Errors: 1 = initial test) | docs/VERIFICATION.md:41 |
| asm/zba | `make test/asm/zba` | `All tests passed! (# Errors: 1 = initial test)` | All tests passed! (# Errors: 1 = initial test) | docs/VERIFICATION.md:42; docs/EXTENSIONS.md:113 |
| asm/zbaadv | `make test/asm/zbaadv` | `All tests passed! (# Errors: 1 = initial test)` | All tests passed! (# Errors: 1 = initial test) | docs/VERIFICATION.md:42; docs/EXTENSIONS.md:114 |
| asm/zicntr | `make test/asm/zicntr` | `All tests passed! (# Errors: 1 = initial test)` | All tests passed! (# Errors: 1 = initial test) | docs/VERIFICATION.md:43; docs/EXTENSIONS.md:147 |
| asm/fencei | `make test/asm/fencei` | `All tests passed! (# Errors: 1 = initial test)` | All tests passed! (# Errors: 1 = initial test) | docs/VERIFICATION.md:44 |
| asm/fencerd | `make test/asm/fencerd` | `All tests passed! (# Errors: 1 = initial test)` | All tests passed! (# Errors: 1 = initial test) | docs/VERIFICATION.md:44 |
| asm/bpred | `make test/asm/bpred` | `(  4380 ps) Test pass!`<br>`(  6800 ps) Test pass!`<br>`(  7900 ps) Test pass!`<br>`Inital test failed! (# Errors: 0)` | three `Test pass!` lines, then `Inital test failed! (# Errors: 0)` | docs/VERIFICATION.md:45; docs/EXTENSIONS.md:335-337 |
| asm/bpirq | `make test/asm/bpirq` | `M00000000 I00000140`<br>`All tests passed! (# Errors: 1 = initial test)` | All tests passed! (# Errors: 1 = initial test) | docs/VERIFICATION.md:46; docs/EXTENSIONS.md:349 |
| asm/bpirq2 | `make test/asm/bpirq2` | `M00000000 I00000180`<br>`All tests passed! (# Errors: 1 = initial test)` | All tests passed! (# Errors: 1 = initial test) | docs/VERIFICATION.md:46; docs/EXTENSIONS.md:350 |
| asm/bpirq3 | `make test/asm/bpirq3` | `D00000000 E00000000 F00000000 I000001e0 C00000500`<br>`All tests passed! (# Errors: 1 = initial test)` | All tests passed! (# Errors: 1 = initial test) | docs/VERIFICATION.md:46; docs/EXTENSIONS.md:351 |
| c/m_extension | `make test/c/m_extension` | `M-EXT checks=200 errors=0`<br>`M-EXT PASS`<br>`Inital test failed! (# Errors: 0)` | `M-EXT checks=200 errors=0`, `M-EXT PASS`, then `Inital test failed! (# Errors: 0)` | docs/VERIFICATION.md:47; README.md:89; docs/EXTENSIONS.md:73 |
| c/bootloader | `make test/c/bootloader` | `INFO: Bootloader started!`<br>`INFO: Ready to receive .hex file...`<br>`Simulation timeout!` | `INFO: Bootloader started!`; ... until the simulation's cycle limit (`Simulation timeout!`) | docs/VERIFICATION.md:48 |
| c/hello_world | `make test/c/hello_world` | `Inital test failed! (# Errors: 0)` | Inital test failed! (# Errors: 0) | docs/VERIFICATION.md:88 |
| c/test_csr | `make test/c/test_csr` | `Inital test failed! (# Errors: 0)` | Inital test failed! (# Errors: 0) | docs/VERIFICATION.md:88 |
| c/test_mcycle | `make test/c/test_mcycle` | `Inital test failed! (# Errors: 0)` | Inital test failed! (# Errors: 0) | docs/VERIFICATION.md:88 |
| c/bp_benchmark | `make test/c/bp_benchmark` | `M0: cyc=000005a1 NN=00000020 NT=000001cb TN=00000000 TT=00000000`<br>`M3: cyc=000004db NN=00000007 NT=00000004 TN=00000035 TT=0000036f`<br>`Inital test failed! (# Errors: 0)` | Inital test failed! (# Errors: 0) | docs/VERIFICATION.md:88 |
| c/basys3_demo | `make test/c/basys3_demo` | `Simulation timeout!` | runs until the simulation's cycle limit (`Simulation timeout!`) | docs/VERIFICATION.md:88 |
| sv/test_decode_exhaustive | `make test/sv/test_decode_exhaustive` | `All 11026 checks PASSED — dut matches ref!` | All 11026 checks PASSED — dut matches ref! | docs/VERIFICATION.md:54; README.md:51,86 |
| sv/test_decode_compare | `make test/sv/test_decode_compare` | `All 86 checks passed — dut matches ref!` | All 86 checks passed — dut matches ref! | docs/VERIFICATION.md:55 |
| sv/test_decode_hazard | `make test/sv/test_decode_hazard` | `All tests passed! (# Errors:    0)` | All tests passed! (# Errors: 0) | docs/VERIFICATION.md:56 |
| sv/test_zba_encoding_sweep | `make test/sv/test_zba_encoding_sweep` | `after A: checks=131072 errors=0 zba_hits=3`<br>`after B: checks=139264 errors=0 zba_hits=27`<br>`after C: checks=289264 errors=0 zba_hits=30`<br>`after D: checks=290288 errors=0`<br>`after E: checks=355824 errors=0 ext_hits=348`<br>`after F: checks=421360 errors=0 ext_hits=1600`<br>`after G: checks=486896 errors=0 ext_hits=0`<br>`All 486896 encoding checks passed — dut op matches ref everywhere except the Zba, M, Zbb, Zbs, Zicond, Zbkb, Zbkx and Zknh words` | All 486896 encoding checks passed — dut op matches ref everywhere except the Zba, M, Zbb, Zbs, Zicond, Zbkb, Zbkx and Zknh words | docs/VERIFICATION.md (Verification at a Glance, Module Benches); README.md (Verification in Depth); docs/EXTENSIONS.md (M, Zba, Zbb and Zbs: Verification; Zba: Implementation Notes) |
| sv/test_m_execute | `make test/sv/test_m_execute` | `MEASURED: multiply = 2 cycles, divide = 34 cycles, early-out divide = 1 cycle(s)`<br>`Checks: 6268   Errors: 0`<br>`All 6268 M-extension checks passed` | All 6268 M-extension checks passed | docs/VERIFICATION.md:58; README.md:88; docs/EXTENSIONS.md:70 |
| sv/test_execute_bpred_nextpc | `make test/sv/test_execute_bpred_nextpc` | `next_program_counter mismatches vs golden: 0`<br>`All 40000 branch-prediction next-PC checks passed` | All 40000 branch-prediction next-PC checks passed | docs/VERIFICATION.md:59; docs/EXTENSIONS.md:352 |
| sv/test_execute_compare | `make test/sv/test_execute_compare` | `Tests: 142   Errors: 30`<br>`SOME TESTS FAILED` | Tests: 142 Errors: 30 (baseline) | docs/VERIFICATION.md:60,256 |
| sv/test_memory_compare | `make test/sv/test_memory_compare` | `Tests: 98   Errors: 6`<br>`SOME TESTS FAILED` | Tests: 98 Errors: 6 (baseline) | docs/VERIFICATION.md:61,257 |
| sv/test_writeback_compare | `make test/sv/test_writeback_compare` | `Tests: 111   Errors: 7`<br>`SOME TESTS FAILED` | Tests: 111 Errors: 7 (baseline) | docs/VERIFICATION.md:62,258 |
| sv/test_writeback_special_irq | `make test/sv/test_writeback_special_irq` | `Tests: 51   Errors: 24`<br>`SOME TESTS FAILED` | Tests: 51 Errors: 24 (baseline) | docs/VERIFICATION.md:63,259 |
| sv/test_writeback_persephone_case1 | `make test/sv/test_writeback_persephone_case1` | `- test/sv/test_writeback_persephone_case1.sv:226: Verilog $finish` | prints both stages' outputs; no verdict of its own | docs/VERIFICATION.md:89 |
| sv/test_writeback_persephone_case2 | `make test/sv/test_writeback_persephone_case2` | `- test/sv/test_writeback_persephone_case2.sv:217: Verilog $finish` | prints both stages' outputs; no verdict of its own | docs/VERIFICATION.md:89 |
| sv/test_writeback_persephone_case13 | `make test/sv/test_writeback_persephone_case13` | `- test/sv/test_writeback_persephone_case13.sv:310: Verilog $finish` | prints both stages' outputs; no verdict of its own | docs/VERIFICATION.md:89 |
| sv/test_example | `make test/sv/test_example` (exit status 2) | `%Error-FUNCTIMECTL: test/sv/test_example.sv:134:9: Functions cannot contain time-controlling statements (IEEE 1800-2023 13.4)`<br>`%Error: Exiting due to 6 error(s)` | does not build with Verilator 5.042 (`%Error-FUNCTIMECTL: ... Functions cannot contain time-controlling statements`) | docs/VERIFICATION.md:90 |
| freertos minimal | `make freertos APP=minimal` | `FREERTOS RESULT: PASS  app=minimal cpu=dut isa=rv32i opt=-O2 tick=10000 bpred=0 seed=0 cycles=3169254`<br>`UART pattern lines intact: 3/3` | FREERTOS RESULT: PASS, cycles=3169254 | docs/VERIFICATION.md:72; README.md:53; docs/FREERTOS.md:160-176,189,192,198,201 |
| freertos stress | `make freertos APP=stress` | `FREERTOS RESULT: PASS  app=stress cpu=dut isa=rv32i opt=-O2 tick=10000 bpred=0 seed=0 cycles=5156655`<br>`UART pattern lines intact: 57/57` | FREERTOS RESULT: PASS, cycles=5156655 | docs/VERIFICATION.md:73; docs/FREERTOS.md:257,261 |
| freertos mzba (rv32im_zba) | `make freertos APP=mzba MARCH=rv32im_zba` | `FREERTOS RESULT: PASS  app=mzba cpu=dut isa=rv32im_zba opt=-O2 tick=10000 bpred=0 seed=0 cycles=5637099`<br>`UART pattern lines intact: 59/59` | FREERTOS RESULT: PASS, cycles=5637099 | docs/VERIFICATION.md:74; docs/EXTENSIONS.md:123 |
| freertos full | `make freertos APP=full` | `FREERTOS RESULT: PASS  app=full cpu=dut isa=rv32i opt=-O2 tick=10000 bpred=0 seed=0 cycles=150681199`<br>`UART pattern lines intact: 3/3` | FREERTOS RESULT: PASS, cycles=150681199 | docs/VERIFICATION.md:75; README.md:92,116 |
| freertos-compare stress seed 7 | `make freertos-compare APP=stress SEED=7` | `COMPARE  dut: PASS   (5156380 cycles)   golden: PASS   (5155907 cycles)`<br>`AGREE: the program passed on both CPUs. (...)` | AGREE: HaDes-V+ 5156380 cycles, golden CPU 5155907 | docs/VERIFICATION.md:76; docs/FREERTOS.md:258; docs/ARCHITECTURE.md:163 |
| freertos-compare minimal | `make freertos-compare APP=minimal` | `COMPARE  dut: PASS   (3169254 cycles)   golden: PASS   (3169246 cycles)`<br>`AGREE: the program passed on both CPUs. (...)` | COMPARE  dut: PASS   (3169254 cycles)   golden: PASS   (3169246 cycles) | docs/FREERTOS.md:223-243 |
| freertos-check-rebuild | `make freertos-check-rebuild` | `REBUILD CHECK: PASS (8 runs, every run used the configuration it was given)` | REBUILD CHECK: PASS (8 runs, every run used the configuration it was given) | docs/VERIFICATION.md:78; docs/FREERTOS.md:337-344; test/freertos/README.md:78-82 |
| freertos-shell-test | `make freertos-shell-test` | `FREERTOS SHELL RESULT: PASS  app=shell cpu=dut isa=rv32i opt=-Os tick=10000 bpred=0 seed=0 cycles=2283594`<br>`typed lines: 39, prompts: 39, expectations met: 120/120` | FREERTOS SHELL RESULT: PASS, cycles=2283594, expectations met: 120/120 | docs/VERIFICATION.md:79; README.md:93; docs/FREERTOS.md:625-639; test/freertos/README.md:102-103 |
| freertos-shell-compare | `make freertos-shell-compare` | `FREERTOS SHELL RESULT: PASS  app=shell cpu=dut isa=rv32i opt=-Os tick=10000 bpred=0 seed=0 cycles=2283594`<br>`typed lines: 39, prompts: 39, expectations met: 120/120`<br>`FREERTOS SHELL RESULT: PASS  app=shell cpu=golden isa=rv32i opt=-Os tick=10000 bpred=0 seed=0 cycles=2230630`<br>`typed lines: 39, prompts: 39, expectations met: 121/121`<br>`SHELL COMPARE: SAME  40 blocks, 158 lines equal after normalising numbers;` | SHELL COMPARE: SAME  40 blocks, 158 lines equal after normalising numbers | docs/VERIFICATION.md:80; README.md:93; docs/FREERTOS.md:644-655; test/freertos/README.md:102-103 |
| freertos-shell-tty-test | `make freertos-shell-tty-test` | `TTY TEST: PASS  (22 of 22 cases passed)` | TTY TEST: PASS  (22 of 22 cases passed) | docs/VERIFICATION.md:81; docs/FREERTOS.md:688-698 |
| freertos template with IRQ (myapp) | `make freertos-compare APP=myapp DEFS=-DTEMPLATE_WITH_IRQ=1` | `received 20 items in order; main/ISR stack used 172/1024 bytes; external interrupts 128`<br>`received 20 items in order; main/ISR stack used 172/1024 bytes; external interrupts 128`<br>`COMPARE  dut: PASS   (1097006 cycles)   golden: PASS   (1096985 cycles)` | PASS after 20 items; `external interrupts 128` | docs/FREERTOS.md:349,386-396 |
| freertos-list | `make freertos-list` | 8 programs listed, text as documented (brk 64 KiB, full 256 KiB, loader 256 KiB, minimal/mzba/shell/stress 32 KiB, template) | the program list | docs/FREERTOS.md:143-152 |
| campaign.py --set standard --list | `python3 test/freertos/campaign.py --set standard --list` | 55 variants listed | SET=standard runs 55 configurations | docs/FREERTOS.md:301 |
| vendored FreeRTOS checksums | `cd third_party/freertos && sha256sum -c MANIFEST` | 76 files ': OK', 0 other lines | 76 files; each matches MANIFEST | third_party/freertos/README.md:41-47,74 |

The four golden-comparison benches report the documented baseline counts (30 of 142, 6 of 98,
7 of 111, 24 of 51). [`baseline-diffs.txt`](baseline-diffs.txt) lists every one of those
67 differing checks verbatim, so that a later change of behaviour can be diffed line by line.

## Further figures checked in the same run

| Figure as quoted | Quoted at | Output of this run |
|---|---|---|
| `minimal: RAM 32 KiB, image+bss 15808 bytes (...)` | docs/FREERTOS.md:189 | `minimal: RAM 32 KiB, image+bss 15808 bytes (text 9536, rodata 856, data 16, bss 5400)` |
| `seed: switches=00000000 seed=641ed1ca` | docs/FREERTOS.md:162,195 | `seed: switches=00000000 seed=641ed1ca` |
| `ticks=309 notifications=113 idle=145732 isr-stack-peak=172/2048` | docs/FREERTOS.md:166 | the same |
| `FRTOS-RESULT: PASS mtime=0000000000305be6` | docs/FREERTOS.md:167 | the same |
| `(224280 ps) Test fail!`, `(63414400 ps) Test pass!` | docs/FREERTOS.md:168,192,198 | `(224280 ps) Test fail!`, `(63414400 ps) Test pass!` |
| `UART pattern lines intact: 3/3` | docs/FREERTOS.md:174 | the same |
| about 3.2 million clock cycles, about two seconds | docs/FREERTOS.md:156-157 | 3,169,254 cycles; the whole command took 3.2 s including the (cached) build |
| a single `stress` run: about 5 million cycles, a few seconds | docs/FREERTOS.md:261 | 5,156,655 cycles, 4.5 s |
| 1.6 to 1.9 million clock cycles per second | docs/FREERTOS.md:470 | `full`: `walltime 87.191 s; speed 34.571 us/s` = 1.73 million cycles/s (one cycle is 20 ps of simulated time). A speed, not a deterministic figure: it depends on the host and its load and is never compared (a run under load on the same host gave 1.54 million) |
| `(195860 ps) Test fail!` at shell start | docs/FREERTOS.md:427 | `(195860 ps) Test fail!` (scripted session, `session-dut.log`) |
| `heap: 1152 of 4608 bytes free, 1152 at the lowest (heap_4)`; RAM 32768, program and data 32032, unused 224, interrupt stack 512 (168 used at most) | docs/FREERTOS.md:518-520,737-739,811 | the same lines in the UART output of the scripted session (`session-dut.uart`) |
| `div -7 2`: `-3`, `-1`, `2147483644`, `1` | docs/FREERTOS.md:533-537 | the same four lines in that UART output |
| shell image fits 32 KiB | docs/FREERTOS.md:708,719; test/freertos/README.md:93 | `shell: RAM 32 KiB, image+bss 31900 bytes (text 21228, rodata 4652, data 28, bss 5992)` |
| 39 command lines; 120 expectations on the DUT, 121 on the golden CPU | docs/FREERTOS.md:626; test/freertos/README.md:102-103 | `typed lines: 39, prompts: 39, expectations met: 120/120` (DUT), `121/121` (golden) |
| 13 lines pasted at once | docs/FREERTOS.md:690 | `PASS  paste  13 lines pasted at once (104 characters): all ran, none dropped` |
| `freertos-check-rebuild`: minimal run eight times, 15-30 s | test/freertos/README.md:78-82; docs/FREERTOS.md:338 | steps 1 to 8 all `[ok]`; 16.6 s |
| `SET=standard` runs 55 configurations | docs/FREERTOS.md:301 | 55 variants listed by `campaign.py --set standard --list` |
| full: 256 KiB RAM | README.md:116; test/freertos/README.md:135 | `full: RAM 256 KiB, image+bss 208864 bytes (...)` |
| decoder sweep: every opcode × funct3 × funct7, 150,000 random words, every OP-IMM immediate, every OP funct7 × rs2 field, and every OP-32 and OP-IMM-32 funct7 × rs2 field; 486,896 checks | README.md (Verification in Depth); docs/VERIFICATION.md (Verification at a Glance, Module Benches); docs/EXTENSIONS.md (M, Zba, Zbb and Zbs: Verification) | `after A: checks=131072` (128 × 8 × 128), `SWEEP C: 150000 random 32-bit words`, `after G: checks=486896 errors=0 ext_hits=0` |
| `op::t` 6 bits, `instruction::t` 65 bits; ILLEGAL stays 49; Zba 50-52; M 53-60; 61 of 64 codes | docs/EXTENSIONS.md:89,128 | `WIDTH: $bits(op::t)=6  $bits(instruction::t)=65`; `ENUM: ILLEGAL=49 SH1ADD=50 SH2ADD=51 SH3ADD=52`; `ENUM: MUL=53 ... REMU=60` |
| multiply 2 cycles, divide 34, early-out 1 | README.md:70; docs/ARCHITECTURE.md:63; docs/EXTENSIONS.md:41,47-52 | `MEASURED: multiply = 2 cycles, divide = 34 cycles, early-out divide = 1 cycle(s)` (`test_m_execute`; the CPU-level measurement is a separate record, `results/m-unit-cycles/`) |
| zba.s 62 assertions, zbaadv.s 103 | docs/EXTENSIONS.md:113-114 | 61 and 102 `Test pass!` lines, plus the deliberate initial-test assertion each |
| zicntr.s: 36 write forms, 24 read forms | docs/EXTENSIONS.md:147 | 60 `Test pass!` lines |
| bpirq: modes 0-3 × delays 1-80; bpirq2: modes 0-3 × delays 1-32 × three shapes | docs/EXTENSIONS.md:349-350 | `I00000140` (320 = 4 × 80 interrupts), `I00000180` (384 = 4 × 32 × 3) |
| vendored FreeRTOS: 76 files, 2,091,517 bytes; 35 + 41 files; 21 kernel headers; 18 demo sources and 18 headers | third_party/freertos/README.md:74,81,89,97,102-103 | `sha256sum -c MANIFEST`: 76 lines `: OK`; the 76 files total 2,091,517 bytes; 35 under `FreeRTOS-Kernel/`, 41 under `FreeRTOS/`, 21 in `include/`, 18 + 18 demo files |

By-product: `make test/c/bp_benchmark` printed `M0: cyc=000005a1` and `M3: cyc=000004db
NN=00000007 NT=00000004 TN=00000035 TT=0000036f`, that is 1,243 instead of 1,441 cycles (13.7 %
fewer) and 886 of 943 branches predicted correctly (94.0 %) in mode 3. These are the
"~94% accuracy, ~13.7% fewer cycles" of the message of commit 15b0b85; the current
documentation does not quote them.

## Commands

From a clean clone, at the repository root, with the default build directory. The recorded
output of five FreeRTOS commands (`minimal`, `stress`, `mzba`, `full` and
`freertos-shell-test`) includes the program's size line (for example `minimal: RAM 32 KiB,
image+bss 15808 bytes ...`). It is printed only when the command links the program, that is in a
new build directory, in the order below, or after removing `build/test/freertos/<app>/out.elf`;
`results/check.sh` removes that file before each of these commands.

```bash
git clone <URL of this repository> hades-v-plus && cd hades-v-plus && git checkout 03386fd
for t in ops forwarding trap trapirq trapmpie csrirq memirq mtvecirq uartirq mul div zba zbaadv \
         zicntr fencei fencerd bpred bpirq bpirq2 bpirq3; do make test/asm/$t; done
for t in m_extension bootloader hello_world test_csr test_mcycle bp_benchmark basys3_demo; do make test/c/$t; done
for t in test_decode_exhaustive test_decode_compare test_decode_hazard test_zba_encoding_sweep \
         test_m_execute test_execute_bpred_nextpc test_execute_compare test_memory_compare \
         test_writeback_compare test_writeback_special_irq test_writeback_persephone_case1 \
         test_writeback_persephone_case2 test_writeback_persephone_case13 test_example; do make test/sv/$t; done
(cd third_party/freertos && sha256sum -c MANIFEST)
make freertos APP=minimal
make freertos APP=stress
make freertos APP=mzba MARCH=rv32im_zba
make freertos-compare APP=stress SEED=7
make freertos-compare APP=minimal
make freertos APP=full
make freertos-check-rebuild
make freertos-shell-test
make freertos-shell-compare
make freertos-shell-tty-test
make freertos-new NAME=myapp && make freertos-compare APP=myapp DEFS=-DTEMPLATE_WITH_IRQ=1 && rm -r test/freertos/myapp
make freertos-list
python3 test/freertos/campaign.py --set standard --list
```

`make test/sv/test_example` exits with status 2 (the documented build error); every other command
exits with status 0. On a disk that cannot execute programs, set `HADES_BUILD_DIR` first
(docs/FREERTOS.md, section 2.2); the build directory does not change any result.

## Inputs

Base commit `03386fdda932f4827cded26e8cfc2a2cc531b365`. Content fingerprints (`git rev-parse
03386fd:<path>`):

| Path | Tree or blob |
|---|---|
| `rtl` | `031b989be1f25dd20836028c5126a5b1dc562bd7` |
| `lib` | `f90a9a64ddc67db6642bc6654545f1509744426b` |
| `defines` | `36f0452de823189873ca8ac79d7a662918961ad6` |
| `sim` | `0dad5608c126445abb808c5addd7b6e9d4df54c7` |
| `std` | `05909d5f7dd5d23f80a2d11e127fdb79eb8a5468` |
| `ref` | `b1cd1eebbcd4c675f36085ebfc96416192423721` |
| `test/asm` | `31ad8c8119c7fc62ef082fbb6281fc7e8e9cbd40` |
| `test/c` | `62c6f3967752d8cb4a231b82b7f0f85a69dd3266` |
| `test/sv` | `69d1fb6e089a8de1473c4d31656ec70021b9e24b` |
| `test/freertos` | `5cb0c42ab14390f060bd6d09bff6903020ac3432` |
| `third_party/freertos` | `57da15398a605dce56c72d420bef3282ba2bb3cc` |
| `Makefile` | `c24da7fcabf3a320f4dd556b69de540f75fc6a6e` |

The SHA-256 of the eight golden libraries in `ref/` are in `meta.json`.
[`images.sha256`](images.sha256) holds the SHA-256 of the memory image (`init.mem`) of each of
the 33 programs that ran (20 assembly, 7 C, 6 FreeRTOS); the images contain no path of the
build machine, so a clone anywhere produces the same files with the same tools.

## Environment

- Date: 2026-10-01.
- Host: Intel Core Ultra 7 165H, 22 threads, Linux.
- Tools: `Verilator 5.042 2025-11-02 rev v5.042`; `riscv32-unknown-elf-gcc () 12.2.0` with
  `GNU assembler (GNU Binutils) 2.39`; `Python 3.12.3`; `GNU Make 4.3`; host compiler
  `g++ 13.3.0` with `ccache 4.9.1`; `git version 2.43.0`.
- Workers: three command streams at once (assembly and C programs; module benches; FreeRTOS),
  each running one command at a time.
- Wall time: 2 min 56 s for all of the above (08:24:55 to 08:27:51). Per-command times are in
  `results.csv`; the longest was `make freertos APP=full` (89.6 s).

## Caveats

- Every output equals the documented one. Where the documentation quotes a line it collapses
  runs of spaces: the benches print `All tests passed! (# Errors:    0)` and
  `  Tests: 142   Errors: 30`.
- The C programs and `bpred.s` end with `Inital test failed! (# Errors: 0)`, the simulator's
  spelling of the summary for a program that never writes the initial-test marker; their verdict
  is their own output (`M-EXT PASS`, three `Test pass!` lines), as docs/VERIFICATION.md explains.
- The simulator builds were ccache hits, so the per-command wall times are those of a warm
  machine. The first-build times quoted in docs/FREERTOS.md:155 and :229 (about 20 and 15
  seconds) were not measured.
- `make freertos-compare APP=myapp` reproduces the example of docs/FREERTOS.md section 8; the
  copy `test/freertos/myapp/` was removed again before `make freertos-list`, whose output is
  then exactly the documented list.

## Files

- `RECORD.md`: this file.
- `meta.json`: the same information, machine-readable, with every extracted output line.
- `results.csv`: one row per command: exit status, wall time, verbatim output, text as
  documented, where quoted.
- `baseline-diffs.txt`: the 67 differing checks of the four golden-comparison benches.
- `images.sha256`: SHA-256 of the 33 program images.

**Update, 2026-10-01 (app loader).** The app-loader change adds the FreeRTOS program `loader`, so `make freertos-list` lists eight programs. The stored output of `freertos-list` and its location in docs/FREERTOS.md were updated; every other result of this record is unchanged and was re-checked with `make check-results`.

**Update, 2026-10-02 (Zbb, Zbs and Zicond).** The decoder sweep `make test/sv/test_zba_encoding_sweep` was extended for the new instructions (one op, `op::EXT`, for all 28): sweeps A to D and their lines are unchanged, three sweeps were added (E: every OP-IMM immediate × funct3; F: every OP funct7 × rs2 field × funct3; each for two register pairs; G: every OP-32 and OP-IMM-32 funct7 × rs2 field × funct3, where the RV64-only word forms must stay illegal), the encoding of every EXT word is checked against the MATCH/MASK table of the ISA manual, and the sweep now prints `ENUM: EXT=61 ...`, `after E:`, `after F:`, `after G:` and `EXT hits per sweep:`. Its stored output (now 486,896 checks), the verdict line and the rules of `results/check.sh` for this command were updated; the stored wall time is still that of the original run. The new tests of Zbb, Zbs and Zicond are recorded in [bitmanip/2026-10-02_e75223e](../../bitmanip/2026-10-02_e75223e/RECORD.md), not here. Every other result of this record is unchanged and was re-checked with `make check-results`.

**Update, 2026-10-02 (the shell's `version` line).** The default shell now probes the CPU for Zbb, Zbs and Zicond as well, as the loader's build already did, and `version` prints one line for all six extensions: `cpu:       M yes, Zba yes, Zbb yes, Zbs yes, Zicntr yes, Zicond yes` on HaDes-V+ and `no` for each on the golden CPU (`test/freertos/shell/commands.c`, `shell.h`; the expectations of `session.txt` were changed to match). The shell's image grows by 284 bytes and still fits the board's 32 KiB at `-Os`: `image+bss 31900 bytes (text 21228, rodata 4652, data 28, bss 5992)`, and `mem` reports `program and data 32032 (with the heap), unused 224` (heap and interrupt-stack lines unchanged). The stored output of `freertos-shell-test` (size line and `cycles=2283594`, 120 of 120 expectations) and of `freertos-shell-compare` (`cycles=2283594` on HaDes-V+, `cycles=2230630` on the golden CPU, 121 of 121 expectations; the comparison is still `SAME  40 blocks, 158 lines`, and its note on the excluded lines now names Zbb, Zbs and Zicond), the corresponding lines of `results.csv` and the tables above, and the SHA-256 of `build/test/freertos/shell/init.mem` in `images.sha256` were updated. `make freertos-shell-tty-test` is unchanged (22 of 22 cases). Every other result of this record is unchanged and was re-checked with `make check-results`.

**Update, 2026-10-02 (Zbkb, Zbkx and Zknh).** The decoder sweep `make test/sv/test_zba_encoding_sweep` now also requires the exact payload of the 17 instructions of Zbkb, Zbkx and Zknh, which share `op::EXT` with the 28 of Zbb, Zbs and Zicond. The number of checks (486,896) and the lines of sweeps A to D and G are unchanged; the stored lines that changed are `after E` (`ext_hits=348`, was 334), `after F` (`ext_hits=1600`, was 962), `EXT hits per sweep: A=30 B=200 C=48 D=5 E=348 F=1600 G=0` (was `A=20 B=120 C=30 D=5 E=334 F=962 G=0`) and the verdict, which now names the new extensions; they were updated in `meta.json`, `results.csv` and the table above. One word of `test/asm/zbaadv.s` that the change makes legal (`xperm4`) was replaced by an illegal neighbour, so the SHA-256 of `build/test/asm/zbaadv/init.mem` in `images.sha256` changed (`3a25a50d…0fd236fce`); its output (`All tests passed!`, 102 `Test pass!` lines) is unchanged. The tests of the new instructions are recorded in [crypto/2026-10-02_bd800d8](../../crypto/2026-10-02_bd800d8/RECORD.md). Every other result of this record is unchanged and was re-checked with `make check-results`.
