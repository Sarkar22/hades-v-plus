[HaDes-V+](../README.md) · [Docs](README.md) · **Building** · [FreeRTOS](FREERTOS.md) · [Shell](SHELL.md) · [Apps](APPS.md) · [Architecture](ARCHITECTURE.md) · [Extensions](EXTENSIONS.md) · [Verification](VERIFICATION.md)

# Building and Running

This document lists the tools HaDes-V+ needs, the build targets and how to debug with waveforms, how to synthesise the design for the Basys3 and what to expect from its timing, how the screenshots in this documentation are recorded, and how the repository is organised. FreeRTOS has its own guide, [FREERTOS.md](FREERTOS.md), and so have its interactive shell and the app loader, [SHELL.md](SHELL.md) and [APPS.md](APPS.md); [README.md](README.md) lists every document.

**Contents**

1. [Tools and Dependencies](#tools-and-dependencies)
2. [Building, Running, and Debugging](#building-running-and-debugging)
3. [Synthesis and FPGA Timing](#synthesis-and-fpga-timing)
4. [Regenerating the Screenshots](#regenerating-the-screenshots)
5. [Repository Structure](#repository-structure)

## Tools and Dependencies

The following tools are required for the lab exercises (details in the [Instruction Guide][instrguide]):
- **[SystemVerilog][sv]**: HDL for processor and peripheral design.
- **[RISC-V Toolchain][rvgcc]**: Compiler for RV32I assembly and C programs.
- **[Vivado][vivado]**: FPGA synthesis and programming.
- **[Verilator][verilator]**: Open-source HDL simulator.
- **[GTKWave][gtkwave]**: Waveform viewer for debugging simulations.

The versions this repository is tested with:

| Tool | Tested version | Needed for |
|---|---|---|
| GNU make, a POSIX shell, coreutils | GNU Make 4.3 | every target |
| [Verilator][verilator] | 5.042 | every simulation |
| RISC-V GCC (`riscv32-unknown-elf`, with newlib-nano) in `/opt/riscv32i/bin`, the path set in the [Makefile](../Makefile) | GCC 12.2.0, binutils 2.39 | assembly, C and FreeRTOS programs |
| Python 3 | 3.12 (3.8 or newer; 3.9 or newer for the trap sweep) | the FreeRTOS front end, campaigns and shell tests, the trap sweep, the formal flow |
| [Vivado][vivado] | 2024.2, given with `XILINX_VIVADO=<install dir>` (the Makefile's default path, `/opt/Xilinx/Vivado/2023.2/`, names 2023.2, which is untested) | `make synthesis` |
| [GTKWave][gtkwave] | any | `make show` |
| SymbiYosys, Yosys, sv2v, bitwuzla, Yices, z3 | listed in [formal/README.md](../formal/README.md#tools) | `make formal` |
| `screen` or `picocom` | any | `make freertos-shell PTY=1` |
| Python package `rich` | 13.7 | regenerating the screenshots |

[FREERTOS.md](FREERTOS.md#1-prerequisites) shows how to check the toolchain, which needs newlib-nano to link FreeRTOS programs.

## Building, Running, and Debugging

All flows are driven by [Makefile](../Makefile) targets; the main ones are listed below, and `make help` prints a longer list with the FreeRTOS, formal and benchmark targets:

```
make test/asm/<name>     # assemble, simulate, and run an asm program
make test/c/<name>       # compile C + runtime, simulate, and run
make test/sv/<name>      # build and run a SystemVerilog testbench
make show                # open the FST waveform of the most recent test in GTKWave
make bootloader          # build the UART bootloader image
make synthesis           # synthesise the full MCU for Basys3 via Vivado
make clean               # wipe build artefacts
make freertos APP=<name> # build and run a FreeRTOS program (make freertos-list, docs/FREERTOS.md)
make bench               # the measurement programs behind the Zba, Zbb, SHA-256, M-unit and FENCE.I figures (test/bench/README.md)
make bench-sha256        # SHA-256 for rv32i, with Zbb and with Zknh: NIST examples, cycles per byte [OPT=-O2]
make ext-check           # Zbb, Zbs, Zicond, Zbkb, Zbkx, Zknh: the RTL against a C model of the ISA texts (test/ext/README.md)
make ext-exhaustive      # the same with the 15 one-operand instructions over all 2^32 inputs (under an hour)
make check-results       # re-run the repeatable records of results/ and compare (results/README.md)
```

All build output goes to `build/` inside the repository unless `BUILD_DIR=/abs/path` is given on the command line or `HADES_BUILD_DIR` is set in the environment; every target follows it. This is how to work from a checkout on a disk that cannot execute programs (such as an NTFS data disk): the simulators are built and run from the build directory, and the golden-model libraries are copied there.

The simulator is [Verilator][verilator]; synthesis uses [Vivado][vivado], tested with 2024.2 (how to give its path: [Synthesis and FPGA Timing](#synthesis-and-fpga-timing)). Each assembly and C test writes its waveform, `sim.fst`, to its own directory in the build directory, and so does each SystemVerilog bench (`<bench>.fst`) except `test_zba_encoding_sweep` and `test_execute_bpred_nextpc`, which write none; a FreeRTOS run (`make freertos` and the shell targets) writes one only when `WAVES=1` is given ([settings](FREERTOS.md#11-settings-reference)). `make show` opens in [GTKWave][gtkwave] the waveform of the assembly or C test that ran last, with the signal layout [`saves/pipeline.gtkw`](../saves/pipeline.gtkw), or of the SystemVerilog bench that was built last (no signal layout is provided for the benches), whichever of the two came later.

## Synthesis and FPGA Timing

`make synthesis` builds the bootloader image and implements the complete microcontroller for the Basys3 (`xc7a35tcpg236-1`) with Vivado in batch mode, in the `synth/` directory of the build directory. The flow is [synth/synth.tcl](../synth/synth.tcl) and the constraints are [synth/basys3.xdc](../synth/basys3.xdc); the result is the bitstream `hades-v.bit` with its `.bin` form, and the reports in `reports/` beside it, among them `timing_pnr.rpt`, `utilization_pnr.rpt` and `power_pnr.rpt` after routing.

The Makefile finds Vivado through `XILINX_VIVADO`, whose default is `/opt/Xilinx/Vivado/2023.2/`. The flow is tested with Vivado 2024.2 (2023.2 is untested), so give the installation on the command line, for example `make synthesis XILINX_VIVADO=/tools/Xilinx/Vivado/2024.2`.

Timing at 50 MHz is marginal. The RTL meets timing with a worst negative slack of +0.016 ns and no failing endpoint (Vivado 2024.2; a repeated run gives the same result), measured at commit cbae9b9; the current RTL differs from it by the one-line UART fix of 03386fd and by the EXT unit in the Execute stage and the decoder (Zbb, Zbs and Zicond, and its cryptography half, Zbkb, Zbkx and Zknh), and **has not been implemented** since ([record](../results/fpga-timing/2026-09-30_cbae9b9/RECORD.md)). The Zbb, Zbs and Zicond half lengthens the full-cycle path from the Execute stage's operands through the ALU select to the forwarding output by an estimated 3 to 5 LUT levels and adds an estimated 500 to 700 LUTs; the cryptography half is shallower, enters the ALU select on a code of its own and adds an estimated 300 to 600 LUTs, and it doubles the EXT loads on the operand registers. The recorded worst path does not pass through Execute, but the added area and fan-out may move it ([timing notes](EXTENSIONS.md#implementation-notes-5), [and](EXTENSIONS.md#implementation-notes-6)). When a board is chosen, run `make synthesis` and record the result before relying on 50 MHz. The worst path runs from the block RAM, which delivers the fetched instruction on the falling clock edge, through the branch predictor and its PC adder to the Fetch stage's PC register, so it has half a clock period. Small RTL changes move the worst path and change its slack: the recorded `make synthesis` results of earlier revisions range from −0.120 ns to +0.242 ns, and the same RTL implemented with extra reporting commands ended about 1 ns lower ([records](../results/README.md#fpga-timing)). `write_bitstream` does not check timing, so a bitstream is produced even when timing fails: read `timing_pnr.rpt` after every run. The critical path, its history and the effect of the M extension on it are analysed in the FPGA timing note under [M — Implementation Notes](EXTENSIONS.md#implementation-notes).

## Regenerating the Screenshots

The terminal images in [docs/img/](img/) are recorded from real sessions of `make freertos-shell` and `make freertos-shell APP=loader` by [docs/tools/screenshots.py](tools/screenshots.py). The script runs the shell in a pseudo-terminal, types a fixed sequence of commands with pauses as a person would, and renders what the terminal showed as SVG with the Python package `rich`:

```bash
python3 -m pip install rich           # once
python3 docs/tools/screenshots.py     # records new sessions and rewrites docs/img/*.svg
```

The output is kept as the terminal showed it: the script removes only the lines that contain paths or names of the machine (in the console bridge's notes of the files it sends, it shows the build directory as `...` instead) and the lines of progress dots that `load` prints, leaves out the control characters with which the loader paces a file transfer, which a terminal does not show, and colours the prompt, the typed commands, `PASS`, the bridge's notes and the report of an app that the shell stopped. All images are rendered for a terminal 86 columns wide, so that their text has the same size. Cycle counts and counters differ from session to session, because the moment a key arrives decides the cycle at which the program sees it. Like the make targets, the script uses the build directory named by `HADES_BUILD_DIR`, if it is set.

## Repository Structure

- [`bitstream/`](../bitstream): Basys3 bitstreams of two earlier revisions, the base core and the base core with the branch predictor, built before the Zicntr, Zba and M extensions, the `FENCE` forwarding fix and the trap and interrupt fixes ([record](../results/history/2026-08-17_15b0b85/RECORD.md)).
- [`defines/`](../defines): HDL constants and definitions.
- [`docs/`](../docs): User guides, listed in [README.md](README.md); [FREERTOS.md](FREERTOS.md) covers running FreeRTOS on the core, [SHELL.md](SHELL.md) its interactive shell and [APPS.md](APPS.md) the programs that the shell loads and runs. [ARCHITECTURE.md](ARCHITECTURE.md), [EXTENSIONS.md](EXTENSIONS.md), [VERIFICATION.md](VERIFICATION.md) and [BUILDING.md](BUILDING.md) describe the core, its extensions, its verification and its build; [`img/`](img) holds the screenshots and [`tools/`](tools) the script that records them.
- [`lib/`](../lib): Peripheral modules (e.g., UART, timer).
- [`ref/`](../ref): Precompiled reference libraries.
- [`formal/`](../formal): Formal proofs of the multiply/divide unit and of the Zbb, Zbs, Zicond, Zbkb, Zbkx and Zknh unit (SymbiYosys, k-induction); see [formal/README.md](../formal/README.md).
- [`results/`](../results/README.md): The records of the figures that the documentation quotes: the command, the inputs, the output as printed, and whether it can be re-run; `make check-results` re-runs the repeatable ones and compares the output with the stored values.
- [`rtl/`](../rtl): The processor implementation — pipeline stages, register file, instruction decoder, and branch predictor.
- [`saves/`](../saves): GTKWave signal layouts for `make show`.
- [`sim/`](../sim): The simulation top level with the test device and the console bridge, and the Verilator file lists.
- [`std/`](../std): The bare-metal C runtime: linker script, start-up code, bootloader and peripheral headers.
- [`synth/`](../synth): Synthesis scripts and FPGA configuration files.
- [`test/`](../test): Test files in assembly (`asm`), C (`c`), and SystemVerilog (`sv`); FreeRTOS programs and the differential campaign (`freertos`), among them the shell's app loader (`freertos/loader`) and the SDK for the programs it runs, with example apps (`freertos/sdk`); the interrupt-offset sweeps with their independent ISA model (`trapsweep`); the measurement programs behind the Zba, Zbb, SHA-256, M-unit and `FENCE.I` figures, run by `make bench` (`bench`, see [test/bench/README.md](../test/bench/README.md)).
- [`third_party/`](../third_party): Third-party sources, included unmodified: the FreeRTOS kernel, its RISC-V port, the FreeRTOS standard demo tasks and FreeRTOS+CLI, at pinned upstream commits (MIT); see [third_party/freertos/README.md](../third_party/freertos/README.md).
- [`.vscode/`](../.vscode): Configuration files for Visual Studio Code.

Refer to the [Instruction Guide][instrguide] for a detailed project structure.

[instrguide]:https://repository.tugraz.at/oer/nytm4-grv34
[vivado]:https://www.xilinx.com/support/download.html
[verilator]:https://verilator.org
[gtkwave]:https://gtkwave.sourceforge.net/
[sv]:https://doi.org/10.1109/IEEESTD.2018.8299595
[rvgcc]:https://github.com/riscv-collab/riscv-gnu-toolchain
