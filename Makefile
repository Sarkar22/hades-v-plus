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
#                           Simulator Configurations                           #
################################################################################

# Simulation-only options that change what a simulator is built from. They apply to
# every simulator a flow builds (test/asm/*, test/c/*, test/memsys/*, the FreeRTOS targets
# including freertos-stress, lint-loops). The module benches (test/sv/*) are built in the
# configuration's directory too, but none contains the memory system, so they do not change.
# The standard configuration has none of them; any other one builds into a directory of its
# own, <build directory>/cfg-<name>, so the standard simulators and their results stay
# untouched. Give them on the command line:
#     make test/asm/ops MEM_LAT=2          make freertos APP=stress MEM_LAT=1:8
#     make sim-config MEM_LAT=1:8          (prints the configuration and its directory)
# Scripts that build their own simulators through make (test/freertos/campaign.py,
# test/trapsweep/sweep.py) take them from the environment as HADES_<option>, together
# with HADES_BUILD_DIR set to the configuration's directory; make sim-config prints that
# command line, and make freertos-stress sets it up by itself. A plain <option> in the
# environment is ignored.
#   MEM_LAT=<n>|<min>:<max>     a slow memory (sim/slow_memory.sv): every RAM read, and
#                               every write unless MEM_WR_LAT is given, waits <n> cycles,
#                               or a number of cycles drawn from [<min>, <max>] for each
#                               transfer (0 <= min <= max <= 1023; 0 behaves exactly as
#                               the standard RAM). The data port waits at most 254 cycles:
#                               the interconnect ends a data access after 255 cycles without
#                               an answer (lib/wishbone/wishbone_interconnect.sv)
#   MEM_WR_LAT=<n>|<min>:<max>  the wait of every RAM write
#   MEM_BEAT_LAT=<n>            burst mode: the wait of a further transfer to the next
#                               word while cyc stays high (default: off)
#   MEM_ONLY=fetch|data         the waits above apply to that RAM port only; the other one
#                               behaves as the standard RAM (default: both ports)
#   MEM_SEED=<n>                seed of the latency generator (default 1)
#   SCOREBOARD=0|1              the shadow-memory scoreboard of sim/top.sv (default: on
#                               with a slow memory, off otherwise)
#   BUSHASH=0|1                 print a hash of both CPU buses at the end of every run
#   BUSTRACE=0|1                write a per-cycle bus trace of HaDes-V+ to bustrace.bin (for
#                               the cache model test/memsys/cachemodel.py; default 0)
# They are compiled into the simulator as its defaults; the run-time options of
# sim/top.sv and sim/slow_memory.sv (+mem_lat=..., +noscoreboard, ...) override them.
# A simulator with a slow memory also prints, at the end of every run, the instructions
# HaDes-V+ retired and the cycles per instruction (RETIRED line; +noretired: not).
# test/memsys/programs.py runs all assembly, C and memory-system programs on both CPUs in a
# configuration.
# Each option below adds its part to the configuration's name, its Verilator defines and
# its description (SIM_CFG_NAME, SIM_CFG_DEFS, SIM_CFG_TEXT); a new option is one more
# such block and one more name in SIM_CFG_VARS.
SIM_CFG_VARS = MEM_LAT MEM_WR_LAT MEM_BEAT_LAT MEM_ONLY MEM_SEED SCOREBOARD BUSHASH BUSTRACE
$(foreach v,$(SIM_CFG_VARS),$(if $(filter command line,$(origin $(v))),,$(eval $(v) := $(HADES_$(v)))))
# the options that come from the environment
SIM_CFG_ENV := $(strip $(foreach v,$(SIM_CFG_VARS),$(if $(filter command line,$(origin $(v))),,$(if $($(v)),$(v)))))

# "<n>" or "<min>:<max>" with 0 <= min <= max <= 1023 -> "<min> <max>" (empty if invalid)
sim_cfg_range = $(shell echo '$(1)' | awk -F: 'NF <= 2 && $$1 ~ /^[0-9]+$$/ && $$NF ~ /^[0-9]+$$/ && $$1 + 0 <= $$NF + 0 && $$NF + 0 <= 1023 { print $$1 + 0, $$NF + 0 }')
# "<min> <max>" -> "<n>" or "<min>_<max>" (in names), "<n>" or "<min>..<max>" (in text)
sim_cfg_rname  = $(if $(filter-out $(word 1,$(1)),$(word 2,$(1))),$(word 1,$(1))_$(word 2,$(1)),$(word 1,$(1)))
sim_cfg_rtext  = $(if $(filter-out $(word 1,$(1)),$(word 2,$(1))),$(word 1,$(1))..$(word 2,$(1)),$(word 1,$(1)))
sim_cfg_lat_error = $(error $(1)='$($(1))' is not a latency: give <n> or <min>:<max> with 0 <= min <= max <= 1023)
# the longest wait of the data port, which the interconnect limits to 254 cycles
SIM_MEM_DATA_MAX = 254
sim_cfg_data_error = $(error $(1)='$($(1))': the data port waits at most $(SIM_MEM_DATA_MAX) cycles (the interconnect ends a data access after 255 cycles without an answer, lib/wishbone/wishbone_interconnect.sv); longer waits are possible on the fetch port alone, with MEM_ONLY=fetch)

# SIM_CFG_NAME: the configuration's name (empty: standard), SIM_CFG_DEFS: its Verilator
# defines, SIM_CFG_TEXT: its description
SIM_CFG_NAME :=
SIM_CFG_DEFS :=
SIM_CFG_TEXT :=
ifneq ($(strip $(MEM_LAT)$(MEM_WR_LAT)$(MEM_BEAT_LAT)$(MEM_ONLY)$(MEM_SEED)),)
SIM_MEM_RD   := $(call sim_cfg_range,$(or $(MEM_LAT),0))
SIM_MEM_WR   := $(call sim_cfg_range,$(or $(MEM_WR_LAT),$(MEM_LAT),0))
SIM_MEM_BEAT := $(if $(MEM_BEAT_LAT),$(call sim_cfg_range,$(MEM_BEAT_LAT)))
SIM_MEM_SEED := $(shell echo '$(or $(MEM_SEED),1)' | awk '/^[0-9]+$$/ && $$1 + 0 < 2147483648 { print $$1 + 0 }')
$(if $(SIM_MEM_RD),,$(call sim_cfg_lat_error,MEM_LAT))
$(if $(SIM_MEM_WR),,$(call sim_cfg_lat_error,$(if $(MEM_WR_LAT),MEM_WR_LAT,MEM_LAT)))
ifneq ($(MEM_BEAT_LAT),)
ifneq ($(words $(sort $(SIM_MEM_BEAT))),1)
$(error MEM_BEAT_LAT='$(MEM_BEAT_LAT)': give one number from 0 to 1023)
endif
endif
ifeq ($(SIM_MEM_SEED),)
$(error MEM_SEED='$(MEM_SEED)': give a number from 0 to 2147483647)
endif
ifneq ($(MEM_ONLY),)
ifeq ($(filter fetch data,$(MEM_ONLY)),)
$(error MEM_ONLY='$(MEM_ONLY)': give fetch or data)
endif
endif
ifneq ($(MEM_ONLY),fetch)
ifeq ($(shell [ $(word 2,$(SIM_MEM_RD)) -le $(SIM_MEM_DATA_MAX) ] && echo ok),)
$(call sim_cfg_data_error,MEM_LAT)
endif
ifeq ($(shell [ $(word 2,$(SIM_MEM_WR)) -le $(SIM_MEM_DATA_MAX) ] && echo ok),)
$(call sim_cfg_data_error,$(if $(MEM_WR_LAT),MEM_WR_LAT,MEM_LAT))
endif
ifeq ($(shell [ $(or $(word 1,$(SIM_MEM_BEAT)),0) -le $(SIM_MEM_DATA_MAX) ] && echo ok),)
$(call sim_cfg_data_error,MEM_BEAT_LAT)
endif
endif
SIM_CFG_NAME += mem$(call sim_cfg_rname,$(SIM_MEM_RD))
ifneq ($(SIM_MEM_WR),$(SIM_MEM_RD))
SIM_CFG_NAME += wr$(call sim_cfg_rname,$(SIM_MEM_WR))
endif
ifneq ($(SIM_MEM_BEAT),)
SIM_CFG_NAME += beat$(word 1,$(SIM_MEM_BEAT))
endif
ifneq ($(MEM_ONLY),)
SIM_CFG_NAME += $(MEM_ONLY)only
endif
ifneq ($(SIM_MEM_SEED),1)
SIM_CFG_NAME += seed$(SIM_MEM_SEED)
endif
SIM_CFG_DEFS += +define+HADES_SLOW_MEM \
                +define+HADES_MEM_RD_LAT_MIN=$(word 1,$(SIM_MEM_RD)) +define+HADES_MEM_RD_LAT_MAX=$(word 2,$(SIM_MEM_RD)) \
                +define+HADES_MEM_WR_LAT_MIN=$(word 1,$(SIM_MEM_WR)) +define+HADES_MEM_WR_LAT_MAX=$(word 2,$(SIM_MEM_WR)) \
                +define+HADES_MEM_BEAT_LAT=$(or $(word 1,$(SIM_MEM_BEAT)),-1) +define+HADES_MEM_SEED=$(SIM_MEM_SEED) \
                $(if $(MEM_ONLY),+define+HADES_MEM_ONLY_$(if $(filter fetch,$(MEM_ONLY)),FETCH,DATA))
SIM_CFG_TEXT += slow memory$(if $(MEM_ONLY), on the $(MEM_ONLY) port only): reads wait $(call sim_cfg_rtext,$(SIM_MEM_RD)) and writes $(call sim_cfg_rtext,$(SIM_MEM_WR)) cycles,
SIM_CFG_TEXT += $(if $(SIM_MEM_BEAT),a further beat of a burst waits $(word 1,$(SIM_MEM_BEAT)),bursts off), seed $(SIM_MEM_SEED);
SIM_SCOREBOARD_DEFAULT := 1
else
SIM_SCOREBOARD_DEFAULT := 0
endif
ifneq ($(SCOREBOARD),)
ifeq ($(filter 0 1,$(SCOREBOARD)),)
$(error SCOREBOARD='$(SCOREBOARD)': give 0 or 1)
endif
ifneq ($(SCOREBOARD),$(SIM_SCOREBOARD_DEFAULT))
SIM_CFG_NAME += $(if $(filter 1,$(SCOREBOARD)),sb,nosb)
SIM_CFG_DEFS += +define+HADES_SCOREBOARD=$(SCOREBOARD)
endif
endif
SIM_CFG_TEXT += scoreboard $(if $(filter 1,$(or $(SCOREBOARD),$(SIM_SCOREBOARD_DEFAULT))),on,off),
ifneq ($(BUSHASH),)
ifeq ($(filter 0 1,$(BUSHASH)),)
$(error BUSHASH='$(BUSHASH)': give 0 or 1)
endif
ifeq ($(BUSHASH),1)
SIM_CFG_NAME += hash
SIM_CFG_DEFS += +define+HADES_BUSHASH=1
endif
endif
sim_cfg_comma := ,
SIM_CFG_TEXT += bus hash $(if $(filter 1,$(BUSHASH)),on,off)$(if $(filter 1,$(BUSTRACE)),$(sim_cfg_comma))
ifneq ($(BUSTRACE),)
ifeq ($(filter 0 1,$(BUSTRACE)),)
$(error BUSTRACE='$(BUSTRACE)': give 0 or 1)
endif
ifeq ($(BUSTRACE),1)
SIM_CFG_NAME += trace
SIM_CFG_DEFS += +define+HADES_BUSTRACE
SIM_CFG_TEXT += bus trace on
endif
endif
sim_cfg_empty :=
sim_cfg_space := $(sim_cfg_empty) $(sim_cfg_empty)
SIM_CFG_NAME := $(subst $(sim_cfg_space),-,$(strip $(SIM_CFG_NAME)))
SIM_CFG_DEFS := $(strip $(SIM_CFG_DEFS))
SIM_CFG_TEXT := $(strip $(SIM_CFG_TEXT))

# Pass the options on to the scripts the recipes run, and to the make commands those run
$(foreach v,$(SIM_CFG_VARS),$(if $($(v)),$(eval export HADES_$(v) := $($(v)))))

# The simulator configurations are simulation only: synthesis always builds the standard design
# (checked here, before anything below creates a build directory).
ifneq ($(SIM_CFG_NAME),)
ifneq ($(filter synthesis,$(MAKECMDGOALS)),)
$(error The simulator configuration $(SIM_CFG_NAME) is for simulation only; synthesis always builds the standard design: run it without $(strip $(foreach v,$(SIM_CFG_VARS),$(if $($(v)),$(if $(filter $(v),$(SIM_CFG_ENV)),HADES_)$(v)=$($(v))))))
endif
endif

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
# A simulator configuration other than the standard one (see above) builds into its own
# directory, cfg-<name> below the build directory, which counts as a relocated build
# directory (absolute spelling, its own copies of the golden libraries). A script started
# with the configuration in its environment passes that directory itself, or a directory
# below it (campaign.py and sweep.py build other trees in <its directory>/other-trees/).
ifneq ($(SIM_CFG_NAME),)
ifeq ($(filter cfg-$(SIM_CFG_NAME),$(subst /, ,$(BUILD_DIR))),)
ifneq ($(SIM_CFG_ENV),)
$(error The simulator configuration $(SIM_CFG_NAME) comes from the environment ($(foreach v,$(SIM_CFG_ENV),HADES_$(v)=$($(v)))), so the build directory must be the configuration's own directory or one below it, not $(BUILD_DIR): set HADES_BUILD_DIR=$(abspath $(BUILD_DIR))/cfg-$(SIM_CFG_NAME) too, or give the options on the make command line instead (see make sim-config))
endif
ifneq ($(filter cfg-%,$(notdir $(BUILD_DIR))),)
$(error $(BUILD_DIR) is the build directory of the simulator configuration $(patsubst cfg-%,%,$(notdir $(BUILD_DIR))), not of $(SIM_CFG_NAME))
endif
override BUILD_DIR := $(abspath $(BUILD_DIR)/cfg-$(SIM_CFG_NAME))
endif
else ifneq ($(filter cfg-%,$(notdir $(BUILD_DIR))),)
$(error $(BUILD_DIR) is the build directory of the simulator configuration $(patsubst cfg-%,%,$(notdir $(BUILD_DIR))): give its options as well (make sim-config shows a configuration's name), or use another build directory)
endif
BUILD_ABS := $(abspath $(BUILD_DIR))

ifneq ($(BUILD_DIR),build)
ifeq ($(filter clean sim-config help,$(MAKECMDGOALS)),)
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
ifneq ($(SIM_CFG_DEFS),)
VERILATOR_FLAGS += $(SIM_CFG_DEFS)
endif

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
	@echo "Simulator configurations (simulation only; any of these options builds the simulators of"
	@echo "every target into <build directory>/cfg-<name>, the standard ones stay untouched):"
	@echo "  MEM_LAT=<n>|<min>:<max>     slow memory: wait states of every RAM read and write, fixed or"
	@echo "                              drawn per transfer (0..1023, at most 254 on the data port;"
	@echo "                              0 behaves as the standard RAM)"
	@echo "  MEM_WR_LAT=<n>|<min>:<max>  wait states of every RAM write (default: MEM_LAT; at most 254)"
	@echo "  MEM_BEAT_LAT=<n>            burst mode: wait states of a further beat to the next word (default off)"
	@echo "  MEM_ONLY=fetch|data         wait states on that RAM port only (default: both)"
	@echo "  MEM_SEED=<n>                seed of the latency generator (default 1)"
	@echo "  SCOREBOARD=0|1              shadow-memory scoreboard (default: 1 with a slow memory, else 0)"
	@echo "  BUSHASH=0|1                 print a hash of both CPU buses at the end of every run (default 0)"
	@echo "  BUSTRACE=0|1                write a per-cycle bus trace to bustrace.bin, HaDes-V+ only (default 0;"
	@echo "                              for python3 test/memsys/cachemodel.py)"
	@echo "  e.g. make test/asm/ops MEM_LAT=2    make freertos APP=stress MEM_LAT=1:8    make freertos-stress MEM_LAT=2"
	@echo "  sim-config        Print the configuration, its build directory and the environment for scripts"
	@echo "  lint-loops        List the combinational loops of the configuration (Verilator, no UNOPTFLAT waiver)"
	@echo "  SIM_ARGS='<opts>' Run-time options for the simulator of test/asm/*, test/c/*, test/memsys/*"
	@echo "                    (+scoreboard, +bushash, +retired, +mem_lat=<n>, ... see sim/top.sv and"
	@echo "                    sim/slow_memory.sv; with a slow memory the default +timeout is 100000"
	@echo "                    times 1 + the longest wait)"
	@echo "  python3 test/memsys/programs.py run [options]   all assembly, C and memory-system programs, both CPUs"
	@echo "  make test/memsys/<name>     an assembly program of the memory-system checks (test/memsys/*.s)"
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

# (A simulator configuration is refused for synthesis, see Simulator Configurations above.)
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

# Run-time options for the simulator of the assembly, C and memory-system tests (command line
# only), e.g.
#     make test/asm/ops SIM_ARGS='+scoreboard +bushash'
SIM_ARGS := $(if $(filter command line,$(origin SIM_ARGS)),$(SIM_ARGS))

# Include dependency file (if it exists)
-include $(BUILD_DIR)/$(SIM_DIR)/top__ver.d

# Verilate simulation
$(BUILD_DIR)/$(SIM_DIR)/top.mk: $(REF_SO_DEPS)
	@ mkdir -p $(BUILD_DIR)/$(SIM_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) --trace-fst --trace-structs --timing --assert --main --exe --prefix top -Mdir $(BUILD_DIR)/$(SIM_DIR) --top-module top sim/top.sv

# Build simulation executable
$(BUILD_DIR)/$(SIM_DIR)/top: $(BUILD_DIR)/$(SIM_DIR)/top.mk
	$(MAKE) -C $(BUILD_DIR)/$(SIM_DIR) -f top.mk

# The simulator configuration selected by the options above, its build directory, and
# what a script that builds its own simulators needs in its environment
.PHONY: sim-config
sim-config:
	@ echo "simulator configuration: $(or $(SIM_CFG_NAME),standard) ($(SIM_CFG_TEXT))"
	@ echo "  build directory:   $(BUILD_DIR)"
	@ echo "  Verilator defines: $(or $(SIM_CFG_DEFS),(none))"
	@ echo "  environment for test/freertos/campaign.py, test/trapsweep/sweep.py and other scripts that build"
	@ echo "  their own simulators:"
	@ echo "      $(strip HADES_BUILD_DIR=$(BUILD_ABS) $(foreach v,$(SIM_CFG_VARS),$(if $($(v)),HADES_$(v)=$($(v)))))"

# The combinational loops of the configuration, on both CPUs, as Verilator reports them
# without the UNOPTFLAT waiver of sim/config.vlt: one line per signal that Verilator finds
# on a loop, followed by the signals of its example path. The lists go to
# $(BUILD_DIR)/lint/loops-dut.txt and loops-golden.txt; compare two configurations with
#     diff build/lint/loops-dut.txt build/cfg-<name>/lint/loops-dut.txt
# (-fno-dfg keeps Verilator from naming loops after signals of its own. The golden CPU is
# a compiled library, so every one of its outputs counts as depending on all its inputs.)
LINT_LOOPS_AWK = function flush() { if (sig != "") print sig ":" path; sig = "" } ; \
                 /^%Warning-UNOPTFLAT/ { flush(); sig = substr($$NF, 2, length($$NF) - 2); path = ""; next } ; \
                 sig != "" && /Example path: top\./ { path = path " " $$NF; next } ; \
                 /^[%-]/ { flush() } ; \
                 END { flush() }

.PHONY: lint-loops
lint-loops:
	@ mkdir -p $(BUILD_DIR)/lint
	@ grep -v '^$(SIM_DIR)/config.vlt$$' $(SIM_DIR)/files.txt > $(BUILD_DIR)/lint/files.txt
	@ for cpu in dut golden; do \
	      def=; if [ $$cpu = golden ]; then def=+define+USE_REF_CPU; fi; \
	      $(VERILATOR) --lint-only -Wall -Wno-fatal -fno-dfg -f $(BUILD_DIR)/lint/files.txt $(SIM_CFG_DEFS) $$def \
	          --timing --assert --top-module top $(SIM_DIR)/top.sv > $(BUILD_DIR)/lint/verilator-$$cpu.log 2>&1 || \
	          { cat $(BUILD_DIR)/lint/verilator-$$cpu.log; exit 1; }; \
	      awk '$(LINT_LOOPS_AWK)' $(BUILD_DIR)/lint/verilator-$$cpu.log | sort > $(BUILD_DIR)/lint/loops-$$cpu.txt; \
	      echo "$$cpu ($(or $(SIM_CFG_NAME),standard)): $$(wc -l < $(BUILD_DIR)/lint/loops-$$cpu.txt) signal(s) on combinational loops, in $(BUILD_DIR)/lint/loops-$$cpu.txt"; \
	      sed -e 's/:.*//' -e 's/^/    /' $(BUILD_DIR)/lint/loops-$$cpu.txt; \
	  done

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
	cd $(BUILD_DIR)/$(ASM_DIR)/$* && $(BUILD_ABS)/$(SIM_DIR)/top$(if $(SIM_ARGS), $(SIM_ARGS))
	@echo 'gtkwave $(BUILD_DIR)/$(ASM_DIR)/$*/sim.fst $(SAVES_DIR)/pipeline.gtkw' > $(BUILD_DIR)/show.sh

# Assembly programs of the memory-system checks (test/memsys/*.s), built and run the same way;
# test/memsys/programs.py runs them together with the programs above
MEMSYS_DIR = $(TEST_DIR)/memsys
MEMSYS_TEST_NAMES = $(patsubst %.s, %, $(wildcard $(MEMSYS_DIR)/*.s))

$(BUILD_DIR)/$(MEMSYS_DIR)/%/init.elf: $(MEMSYS_DIR)/%.s $(STD_LIB_DIR)/hades-v.ld
	@ mkdir -p $(BUILD_DIR)/$(MEMSYS_DIR)/$*
	$(CC) -nostdlib -nostartfiles -T $(STD_LIB_DIR)/hades-v.ld -o $@ $<
	$(OBJDUMP) -d -r -t -S $@ > $(@:.elf=.dis)

$(BUILD_DIR)/$(MEMSYS_DIR)/%/init.bin: $(BUILD_DIR)/$(MEMSYS_DIR)/%/init.elf
	$(OBJCOPY) -O binary $< $@

$(BUILD_DIR)/$(MEMSYS_DIR)/%/init.mem: $(BUILD_DIR)/$(MEMSYS_DIR)/%/init.bin
	$(OBJCOPY) -I binary -O verilog --verilog-data-width 4 --reverse-bytes=4 $< $@

.PHONY: $(MEMSYS_TEST_NAMES)
$(MEMSYS_TEST_NAMES): $(MEMSYS_DIR)/%: $(BUILD_DIR)/$(MEMSYS_DIR)/%/init.mem $(BUILD_DIR)/$(SIM_DIR)/top
	cd $(BUILD_DIR)/$(MEMSYS_DIR)/$* && $(BUILD_ABS)/$(SIM_DIR)/top$(if $(SIM_ARGS), $(SIM_ARGS))
	@echo 'gtkwave $(BUILD_DIR)/$(MEMSYS_DIR)/$*/sim.fst $(SAVES_DIR)/pipeline.gtkw' > $(BUILD_DIR)/show.sh

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
	cd $(BUILD_DIR)/$(C_DIR)/$* && $(BUILD_ABS)/$(SIM_DIR)/top$(if $(SIM_ARGS), $(SIM_ARGS))
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
