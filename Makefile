# Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
# Embedded Architectures & Systems Group, Graz University of Technology
# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: Makefile
#
# Sanity check (taken from verilator examples)
ifneq ($(words $(CURDIR)),1)
 $(error Unsupported: GNU Make cannot build in directories containing spaces, build elsewhere: '$(CURDIR)')
endif

# Binaries
VERILATOR ?= verilator

CC = /opt/riscv32i/bin/riscv32-unknown-elf-gcc
OBJCOPY = /opt/riscv32i/bin/riscv32-unknown-elf-objcopy
OBJDUMP = /opt/riscv32i/bin/riscv32-unknown-elf-objdump

XILINX_VIVADO ?= /opt/Xilinx/Vivado/2023.2/
VIVADO ?= $(XILINX_VIVADO)/bin/vivado

# Directories
SIM_DIR = sim
RTL_DIR = rtl
REF_DIR = ref
LIB_DIR = lib
SAVES_DIR = saves
STD_LIB_DIR = std
SYNTH_DIR = synth
DEFINES_DIR = defines

TEST_DIR = test
ASM_DIR = $(TEST_DIR)/asm
C_DIR = $(TEST_DIR)/c
SV_DIR = $(TEST_DIR)/sv

################################################################################
#                               Build Directory                                #
################################################################################

# Everything the flows generate (Verilator models, ELFs, logs, waveforms) goes to
# BUILD_DIR. The default is build/ inside the repository, exactly as before. It can
# live anywhere else, for instance when the repository sits on a disk that cannot
# execute programs (see docs/FREERTOS.md):
#     make BUILD_DIR=/abs/path <target>      or      export HADES_BUILD_DIR=/abs/path
# Use one build directory per checkout (a relocated one records its owner and refuses
# to serve another checkout, so a model built from other RTL is never reused).
ifneq ($(HADES_BUILD_DIR),)
BUILD_DIR = $(HADES_BUILD_DIR)
else
BUILD_DIR = build
endif
# A relocated build directory is always spelled as one normalised absolute path:
# Verilator writes its dependency files with the path it was given, and a second
# spelling of the same directory would silently disable those dependencies.
# build/ inside the repository keeps its original relative spelling.
ifeq ($(strip $(BUILD_DIR)),)
$(error BUILD_DIR is empty: leave it unset for build/ inside the repository, or give a directory)
endif
override BUILD_DIR := $(abspath $(BUILD_DIR))
ifeq ($(BUILD_DIR),$(CURDIR)/build)
override BUILD_DIR := build
endif
BUILD_ABS := $(abspath $(BUILD_DIR))

ifneq ($(BUILD_DIR),build)
ifeq ($(filter clean,$(MAKECMDGOALS)),)
BUILD_OWNER := $(shell cat '$(BUILD_DIR)/.hades-source-dir' 2>/dev/null)
ifeq ($(BUILD_OWNER),)
BUILD_OWNER := $(shell mkdir -p '$(BUILD_DIR)' && echo '$(CURDIR)' > '$(BUILD_DIR)/.hades-source-dir' && echo '$(CURDIR)')
endif
ifneq ($(BUILD_OWNER),$(CURDIR))
$(error Build directory $(BUILD_DIR) belongs to the checkout $(BUILD_OWNER), not to $(CURDIR). Use a separate BUILD_DIR/HADES_BUILD_DIR for every checkout, or remove the old one)
endif
endif
endif

# Golden reference libraries. With build/ inside the repository the simulators link
# them in place, as before. A relocated build links copies kept in the build
# directory, so that no simulator maps executable code from the repository's disk.
REF_SO_SRC = $(wildcard $(REF_DIR)/*.so)
ifeq ($(BUILD_DIR),build)
REF_SO      = $(abspath $(REF_SO_SRC))
REF_SO_DEPS =
else
REF_SO      = $(addprefix $(BUILD_DIR)/ref/,$(notdir $(REF_SO_SRC)))
REF_SO_DEPS = $(REF_SO)
$(BUILD_DIR)/ref/%.so: $(REF_DIR)/%.so
	@ mkdir -p $(dir $@)
	cp $< $@
endif

# Verilator Flags
VERILATOR_FLAGS =
VERILATOR_FLAGS += -cc
VERILATOR_FLAGS += -Wall -Wno-fatal
VERILATOR_FLAGS += -f $(SIM_DIR)/files.txt
VERILATOR_FLAGS += $(REF_SO) -j

################################################################################
#                                  Print Help                                  #
################################################################################

.PHONY: help
help:
	@echo "Usage: make TARGET"
	@echo ""
	@echo "The following options exist for TARGET:"
	@echo "  help        Prints this help message"
	@echo "  clean       Deletes build artifacts"
	@echo "  test/...    Builds and runs the specified test"
	@echo "              (test/freertos/<app>: FreeRTOS program, see test/freertos/README.md)"
	@echo "  show        Show the waveform of the most recently run test (if available)"
	@echo "  bootloader  Build the bootloader"
	@echo "  synthesis   Synthesize the MCU using Vivado"
	@echo ""
	@echo "FreeRTOS (guide: docs/FREERTOS.md; sources vendored in third_party/freertos):"
	@echo "  freertos-list     List the FreeRTOS programs"
	@echo "  freertos          Build and run one program: make freertos APP=minimal [CPU=golden]"
	@echo "                    [MARCH=rv32im_zba] [OPT=-Os] [TICK=5000] [BPRED=3] [SEED=2a] [TIMEOUT=<cycles>]"
	@echo "  freertos-compare  Run one program on the DUT and on the golden CPU and compare"
	@echo "  freertos-stress   Differential stress campaign, DUT vs golden CPU [SEEDS=2] [JOBS=4] [SET=validate]"
	@echo "  freertos-new      Start a new program from the template: make freertos-new NAME=<name>"
	@echo "  freertos-shell    Interactive shell, typed into from this terminal (Ctrl-] quits) [PTY=1] [CPU=golden]"
	@echo "  freertos-shell-test"
	@echo "                    Type a command script into the shell and check the transcript [SCRIPT=<file>]"
	@echo "  freertos-shell-compare"
	@echo "                    The scripted shell session on the DUT and on the golden CPU, compared"
	@echo "  freertos-shell-tty-test"
	@echo "                    The interactive console through a pseudo-terminal (keys, quitting, restore)"
	@echo "  freertos-shell APP=loader [UPLOAD=<app>]"
	@echo "                    The shell with the app loader: load and run programs built on the host (simulation)"
	@echo "  freertos-app      Build an app for the loader: make freertos-app NAME=<name> [MARCH=rv32im_zba_zbb_zbs] [OPT=-Os]"
	@echo "                    (MARCH: rv32i, rv32im, rv32i_zba, rv32im_zba, rv32im_zba_zbb_zbs, rv32im_zba_zbb_zbkb_zbkx_zbs_zknh)"
	@echo "  freertos-apps     Build the example apps and the loader's test files"
	@echo "  freertos-send     Send an app to a running 'freertos-shell APP=loader PTY=1': UPLOAD=<app>"
	@echo "  freertos-loader-test"
	@echo "                    The loader's scripted sessions [CPU=golden]"
	@echo "  freertos-loader-compare"
	@echo "                    The loader's scripted sessions on the DUT and on the golden CPU, compared"
	@echo ""
	@echo "Formal verification of the M and EXT units (guide: formal/README.md):"
	@echo "  formal            Re-run the M (divider/multiplier) and EXT (Zbb/Zbs/Zicond/Zbkb/Zbkx/Zknh) proofs (a few minutes) [FORMAL_PAR=4]"
	@echo "  formal-full       Also H6 by bitwuzla, second solvers and the mutation campaigns (~45 min)"
	@echo "  formal-ext        Only the EXT proof (about a minute)"
	@echo ""
	@echo "Benchmarks (guide: test/bench/README.md; recorded results: results/):"
	@echo "  bench-zba         Zba: two C programs for rv32i and rv32i_zba, compared [OPT=-O2]"
	@echo "  bench-zbb         Zbb, Zbs, Zicond: two C programs for rv32i and with the extensions, compared [OPT=-O2]"
	@echo "  bench-sha256      SHA-256 for rv32i, with Zbb and with Zknh: NIST examples, cycles per byte [OPT=-O2]"
	@echo "  bench-mcost       Cycles of each M instruction in the assembled core"
	@echo "  bench-fencei-window"
	@echo "                    Instructions that still run stale after a store patches them (no FENCE.I)"
	@echo "  bench             All five"
	@echo ""
	@echo "Zbb, Zbs, Zicond, Zbkb, Zbkx and Zknh (guide: test/ext/README.md):"
	@echo "  ext-check         The RTL's results against the C reference model, quick vector set (about a minute) [JOBS=4]"
	@echo "  ext-exhaustive    The same, the one-operand instructions over all 2^32 inputs (under an hour) [JOBS=4]"
	@echo ""
	@echo "Recorded results (guide: results/README.md):"
	@echo "  check-results     Re-run the repeatable records of results/ and compare [CHECK_ARGS=--list]"
	@echo ""
	@echo "Build directory: $(BUILD_DIR)  (relocate with BUILD_DIR=/abs/path or HADES_BUILD_DIR)"


################################################################################
#                                 Clean Project                                #
################################################################################

.PHONY: clean
clean::
	@ b='$(BUILD_ABS)'; \
	  case "$$b" in ''|/) echo "refusing to delete '$$b'"; exit 1;; esac; \
	  case '$(CURDIR)/' in "$$b"/*) echo "refusing to delete $$b: it contains the repository"; exit 1;; esac; \
	  case "$$b" in '$(HOME)'|'$(HOME)/') echo "refusing to delete the home directory $$b"; exit 1;; esac
	rm -rf $(BUILD_DIR)

################################################################################
#                                   Synthesis                                  #
################################################################################

MODE ?= batch

.PHONY: synthesis
synthesis: $(BUILD_DIR)/$(C_DIR)/bootloader/init.mem
	@ mkdir -p $(BUILD_DIR)/$(SYNTH_DIR)
	cd $(BUILD_DIR)/$(SYNTH_DIR) && HADES_BOOTLOADER_MEM=$(BUILD_ABS)/$(C_DIR)/bootloader/init.mem $(VIVADO) -mode $(MODE) -source $(CURDIR)/$(SYNTH_DIR)/synth.tcl

# Bootloader image (init.mem for synthesis, out.hex/out.elf/out.dis alongside)
.PHONY: bootloader
bootloader: $(BUILD_DIR)/$(C_DIR)/bootloader/init.mem $(BUILD_DIR)/$(C_DIR)/bootloader/out.hex $(BUILD_DIR)/$(C_DIR)/bootloader/out.dis

################################################################################
#                                  Simulation                                  #
################################################################################

# Include dependency file (if it exists)
-include $(BUILD_DIR)/$(SIM_DIR)/top__ver.d

# Verilate simulation
$(BUILD_DIR)/$(SIM_DIR)/top.mk: $(REF_SO_DEPS)
	@ mkdir -p $(BUILD_DIR)/$(SIM_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) --trace-fst --trace-structs --timing --assert --main --exe --prefix top -Mdir $(BUILD_DIR)/$(SIM_DIR) --top-module top sim/top.sv

# Build simulation executable
$(BUILD_DIR)/$(SIM_DIR)/top: $(BUILD_DIR)/$(SIM_DIR)/top.mk
	$(MAKE) -C $(BUILD_DIR)/$(SIM_DIR) -f top.mk

################################################################################
#                                Assembly Tests                                #
################################################################################

# Collect asembly tests
ASM_TESTS = $(wildcard $(ASM_DIR)/*.s)
ASM_TEST_NAMES = $(patsubst $(ASM_DIR)/%.s, $(ASM_DIR)/%, $(ASM_TESTS))

# Compile assembly to elf
$(BUILD_DIR)/$(ASM_DIR)/%/init.elf: $(ASM_DIR)/%.s $(STD_LIB_DIR)/hades-v.ld
	@ mkdir -p $(BUILD_DIR)/$(ASM_DIR)/$*
	$(CC) -nostdlib -nostartfiles -T $(STD_LIB_DIR)/hades-v.ld -o $@ $<
	$(OBJDUMP) -d -r -t -S $@ > $(@:.elf=.dis)

# Copy elf to bin
$(BUILD_DIR)/$(ASM_DIR)/%/init.bin: $(BUILD_DIR)/$(ASM_DIR)/%/init.elf
	$(OBJCOPY) -O binary $< $@

# Copy elf to mem
$(BUILD_DIR)/$(ASM_DIR)/%/init.mem: $(BUILD_DIR)/$(ASM_DIR)/%/init.bin
	$(OBJCOPY) -I binary -O verilog --verilog-data-width 4 --reverse-bytes=4 $< $@

# Run test
.PHONY: $(ASM_TEST_NAMES)
$(ASM_TEST_NAMES): $(ASM_DIR)/%: $(BUILD_DIR)/$(ASM_DIR)/%/init.mem $(BUILD_DIR)/$(SIM_DIR)/top
	cd $(BUILD_DIR)/$(ASM_DIR)/$* && $(BUILD_ABS)/$(SIM_DIR)/top
	@echo 'gtkwave $(BUILD_DIR)/$(ASM_DIR)/$*/sim.fst $(SAVES_DIR)/pipeline.gtkw' > $(BUILD_DIR)/show.sh

################################################################################
#                                   C Tests                                    #
################################################################################

# Collect c tests
C_TESTS = $(wildcard $(C_DIR)/*.c)
C_TEST_NAMES = $(patsubst $(C_DIR)/%.c, $(C_DIR)/%, $(C_TESTS))

# Collect std lib
C_LIB_SRC = $(wildcard $(STD_LIB_DIR)/src/*.c)
C_LIB_OBJ = $(patsubst $(STD_LIB_DIR)/src/%.c, $(BUILD_DIR)/$(STD_LIB_DIR)/%.o, $(C_LIB_SRC))

# Compile std lib c files
$(BUILD_DIR)/$(STD_LIB_DIR)/%.o: $(STD_LIB_DIR)/src/%.c
	@ mkdir -p $(BUILD_DIR)/$(STD_LIB_DIR)
	$(CC) -fdata-sections -ffunction-sections -c -o $@ -I $(STD_LIB_DIR)/include $<

# Compile test c file
$(BUILD_DIR)/$(C_DIR)/%/out.o: $(C_DIR)/%.c
	@ mkdir -p $(BUILD_DIR)/$(C_DIR)/$*
	$(CC) -fdata-sections -ffunction-sections -c -o $@ -I $(STD_LIB_DIR)/include $<

# Link binary
$(BUILD_DIR)/$(C_DIR)/%/out.elf: $(BUILD_DIR)/$(C_DIR)/%/out.o $(C_LIB_OBJ) $(STD_LIB_DIR)/hades-v.ld
	$(CC) -o $@ -nostdlib -nostartfiles -T $(STD_LIB_DIR)/hades-v.ld $< $(C_LIB_OBJ) -lgcc -Wl,--no-warn-rwx-segments -Wl,--gc-sections

# Create hex file (for sending to bootloader)
$(BUILD_DIR)/$(C_DIR)/%/out.hex: $(BUILD_DIR)/$(C_DIR)/%/out.elf
	$(OBJCOPY) -O ihex $< $@

# Create bin file (intermediate step for creating mem file)
$(BUILD_DIR)/$(C_DIR)/%/out.bin: $(BUILD_DIR)/$(C_DIR)/%/out.elf
	$(OBJCOPY) -O binary $< $@

# Create mem file (for simulation and synthesis)
$(BUILD_DIR)/$(C_DIR)/%/init.mem: $(BUILD_DIR)/$(C_DIR)/%/out.bin
	$(OBJCOPY) -I binary -O verilog -S --verilog-data-width 4 --reverse-bytes=4 $< $@

# Create disassembly view (for debugging)
$(BUILD_DIR)/$(C_DIR)/%/out.dis: $(BUILD_DIR)/$(C_DIR)/%/out.elf
	$(OBJDUMP) -d -x $< > $@

# Run test
.PHONY: $(C_TEST_NAMES)
$(C_TEST_NAMES): $(C_DIR)/%: $(BUILD_DIR)/$(C_DIR)/%/init.mem $(BUILD_DIR)/$(C_DIR)/%/out.hex $(BUILD_DIR)/$(C_DIR)/%/out.elf $(BUILD_DIR)/$(C_DIR)/%/out.dis $(BUILD_DIR)/$(SIM_DIR)/top
	cd $(BUILD_DIR)/$(C_DIR)/$* && $(BUILD_ABS)/$(SIM_DIR)/top
	@echo 'gtkwave $(BUILD_DIR)/$(C_DIR)/$*/sim.fst $(SAVES_DIR)/pipeline.gtkw' > $(BUILD_DIR)/show.sh

################################################################################
#                             SystemVerilog Tests                              #
################################################################################

SV_TESTS = $(wildcard $(SV_DIR)/*.sv)
SV_TEST_NAMES = $(patsubst $(SV_DIR)/%.sv, $(SV_DIR)/%, $(SV_TESTS))

# Include dependency files (if they exist)
-include $(wildcard $(BUILD_DIR)/$(SV_DIR)/*/top__ver.d)

# Run test bench
.PHONY: $(SV_TEST_NAMES)
$(SV_TEST_NAMES): $(SV_DIR)/%: $(BUILD_DIR)/$(SV_DIR)/%/top
	cd $(BUILD_DIR)/$(SV_DIR)/$* && $(BUILD_ABS)/$(SV_DIR)/$*/top

# Build system verilog executable
$(BUILD_DIR)/$(SV_DIR)/%/top: $(BUILD_DIR)/$(SV_DIR)/%/top.mk
	$(MAKE) -j -C $(BUILD_DIR)/$(SV_DIR)/$* -f top.mk

# Verilate system verilog testbench
$(BUILD_DIR)/$(SV_DIR)/%/top.mk: $(REF_SO_DEPS)
	@ mkdir -p $(BUILD_DIR)/$(SV_DIR)/$*
	$(VERILATOR) $(VERILATOR_FLAGS) -f $(SV_DIR)/files.txt --trace-fst --trace-structs --timing --assert --main --exe --prefix top -Mdir $(BUILD_DIR)/$(SV_DIR)/$* --top-module $* $(SV_DIR)/$*.sv
	@echo 'gtkwave $(BUILD_DIR)/$(SV_DIR)/$*/$*.fst $(SAVES_DIR)/$*.gtkw' > $(BUILD_DIR)/show.sh

################################################################################
#                               FreeRTOS Programs                              #
################################################################################

# Multi-file FreeRTOS programs in test/freertos/<app>/ (the FreeRTOS sources are vendored
# in third_party/freertos/, see docs/FREERTOS.md and test/freertos/README.md):
# make freertos APP=<app>, make test/freertos/<app>
include $(TEST_DIR)/freertos/freertos.mk

################################################################################
#                                  Benchmarks                                  #
################################################################################

# Measurement programs in test/bench/ that reproduce figures quoted in the documentation
# (make bench-zba, bench-mcost, bench-fencei-window, bench): guide test/bench/README.md,
# recorded results in results/
include $(TEST_DIR)/bench/bench.mk

################################################################################
#                       Zbb, Zbs and Zicond: value checks                      #
################################################################################

# The RTL's results of the 28 Zbb, Zbs and Zicond forms against the C reference model
# (make ext-check, ext-exhaustive): guide test/ext/README.md
include $(TEST_DIR)/ext/ext.mk

################################################################################
#                               Recorded Results                               #
################################################################################

# Re-run the repeatable records of results/ and compare the output with the stored values
# (guide: results/README.md): make check-results [CHECK_ARGS='--list | --campaign | <check> ...']
.PHONY: check-results
check-results:
	HADES_BUILD_DIR='$(BUILD_ABS)' sh results/check.sh $(CHECK_ARGS)

################################################################################
#                              Formal Verification                             #
################################################################################

# Formal proofs of rtl/execute_stage.sv: the M unit (divider + multiplier) and the
# EXT unit (Zbb, Zbs, Zicond), see formal/README.md. Tools (SymbiYosys/Yosys, sv2v,
# bitwuzla, yices, z3) are found on PATH or through HADES_FORMAL_ENV. Everything is
# written to $(BUILD_DIR)/formal ($(BUILD_DIR)/formal-ext for formal-ext).
FORMAL_PAR ?= 4

.PHONY: formal formal-full formal-ext
formal:
	bash formal/run.sh --mode default --par $(FORMAL_PAR) --out $(BUILD_ABS)/formal

formal-full:
	bash formal/run.sh --mode full --par $(FORMAL_PAR) --out $(BUILD_ABS)/formal

formal-ext:
	bash formal/run.sh --mode ext --par $(FORMAL_PAR) --out $(BUILD_ABS)/formal-ext

################################################################################
#                                   Waveform                                   #
################################################################################

.PHONY: show
show:
	$(file < $(BUILD_DIR)/show.sh)
