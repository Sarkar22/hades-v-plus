# ---------------------------------------------------------------------------------------------
# FreeRTOS programs for HaDes-V+ (included by the top-level Makefile). Guide: docs/FREERTOS.md
#
# Front end (knobs on the command line, all optional):
#   make freertos-list                    list the programs (test/freertos/<app>/)
#   make freertos APP=<app> [CPU=dut|golden] [MARCH=rv32i|rv32im|rv32im_zba] [OPT=-O2|-Os|-O0]
#                 [TICK=<cycles>] [BPRED=0..3] [SEED=<hex>] [TIMEOUT=<cycles>] [WAVES=1]
#                 [PREEMPT=0|1] [SLICE=0|1] [HEAP=1|4] [DEFS=<-D flags>] [RAM_KB=<KiB>] [VERBOSE=1]
#       build one program for one configuration (quietly, into build.log), run it with the
#       UART output streamed, and finish with one "FREERTOS RESULT: PASS|FAIL|HANG|CRASH"
#       line (exit status 0 = PASS)
#   make freertos-compare APP=<app> [...]  the same ELF on the DUT and on the golden CPU
#   make freertos-stress [SEEDS=2] [JOBS=4] [SET=validate]   differential campaign (campaign.py)
#   make freertos-new NAME=<name> [FROM=<app>]   copy test/freertos/template (or the program
#                                         <app>, e.g. FROM=shell) to test/freertos/<name>
#   make freertos-check-rebuild           regression test for the configuration tracking
#   make freertos-shell [PTY=1] [...]     the interactive shell (test/freertos/shell) on a
#                                         simulator whose UART is connected to this terminal
#                                         (Ctrl-] quits) or, with PTY=1, to a pseudo-terminal
#   make freertos-shell-test [SCRIPT=<file>] [...]   type a command script into the shell
#                                         and check the transcript (session.py)
#   make freertos-shell-compare [...]     the scripted session on the DUT and on the golden
#                                         CPU, transcripts compared (rv32i)
#   make freertos-shell-tty-test [...]    the interactive console driven through a pseudo-
#                                         terminal: keys, Ctrl-], signals, terminal restore
#   make freertos-shell APP=loader [UPLOAD=<app>] [...]   the shell with the app loader
#                                         (test/freertos/loader, 256 KiB): programs built on
#                                         the host are sent over the UART and run as a task:
#                                         'load <name>', then 'run'. UPLOAD= names the file
#                                         sent whenever 'load' without a name asks for one.
#                                         The other console targets take APP=loader as well;
#                                         the app SDK's targets (freertos-app, freertos-apps,
#                                         freertos-send) are in test/freertos/sdk/sdk.mk
#   make freertos-loader-test [CPU=golden] [...]   the app loader's scripted sessions,
#                                         loader/session.txt and loader/session-ext.txt, on
#                                         one CPU, with one verdict for both
#   make freertos-loader-compare [...]    both sessions on the DUT and on the golden CPU;
#                                         the transcripts of session.txt compared
# Every short knob is an alias of the FRTOS_<KNOB> variable below and is honoured only on the
# command line (so that a stray environment variable such as CPU or OPT changes nothing).
#
# Back end (used by the front end, campaign.py and check_rebuild.sh):
#   make test/freertos/<app> [FRTOS_MARCH=rv32im] [FRTOS_OPT=-Os] [FRTOS_TICK=3000] ...
#       build test/freertos/<app>/ for one configuration and run it
#   make frtos-elf   FRTOS_APP=<app> [knobs...]      build only (FRTOS_OUT/init.mem, out.elf)
#   make frtos-model FRTOS_CPU=dut|ref FRTOS_RAM_KB=<n>   build a simulator variant
#
# The FreeRTOS sources are vendored, unmodified, in third_party/freertos/ (pinned commits,
# file list and checksums: third_party/freertos/README.md). Each variable below may instead
# point to an external checkout with the same layout:
#   FREERTOS_HOME     directory holding both trees (default: third_party/freertos)
#   FREERTOS_KERNEL   FreeRTOS-Kernel            (vendored: 8be86d4, V11.1.0+)
#   FREERTOS_DEMO     FreeRTOS/FreeRTOS/Demo     (vendored: FreeRTOS/FreeRTOS f4fcc3b; only
#                     Demo/Common and Demo/RISC-V_RV32_QEMU_VIRT_GCC are needed)
#   FREERTOS_PLUS_CLI FreeRTOS-Plus-CLI          (vendored: FreeRTOS/FreeRTOS f4fcc3b; the
#                     command interpreter of the shell program, test/freertos/shell)
# test/freertos/campaign.py builds and runs many configurations differentially against
# the golden reference CPU; see test/freertos/README.md.
# ---------------------------------------------------------------------------------------------

FREERTOS_HOME     ?= $(CURDIR)/third_party/freertos
FREERTOS_KERNEL   ?= $(FREERTOS_HOME)/FreeRTOS-Kernel
FREERTOS_DEMO     ?= $(FREERTOS_HOME)/FreeRTOS/FreeRTOS/Demo
FREERTOS_PLUS_CLI ?= $(FREERTOS_HOME)/FreeRTOS/FreeRTOS-Plus/Source/FreeRTOS-Plus-CLI

FRTOS_DIR  = $(TEST_DIR)/freertos
FRTOS_APPS = $(patsubst $(FRTOS_DIR)/%/app.mk,%,$(wildcard $(FRTOS_DIR)/*/app.mk))

# ---- short command-line aliases: APP=minimal is FRTOS_APP=minimal, CPU=golden is FRTOS_CPU=ref
FRTOS_ALIASES = APP CPU MARCH OPT TICK SEED TIMEOUT BPRED PREEMPT SLICE HEAP DEFS RAM_KB PTY SCRIPT UPLOAD
$(foreach a,$(FRTOS_ALIASES),$(if $(filter command line,$(origin $(a))),$(eval FRTOS_$(a) := $$($(a)))))

# Goals that run a program with its UART connected to the terminal or a script
# (sim/console.cpp); their program is the shell unless APP= says otherwise (their
# recipes pass FRTOS_APP on to the sub-make that builds it).
# The loader's test targets always run the program loader.
FRTOS_LOADER_GOALS = freertos-loader-test freertos-loader-compare
ifneq ($(filter $(FRTOS_LOADER_GOALS),$(MAKECMDGOALS)),)
override FRTOS_APP := loader
endif
FRTOS_SHELL_GOALS = freertos-shell freertos-shell-test freertos-shell-compare freertos-shell-tty-test \
                    $(FRTOS_LOADER_GOALS)
ifneq ($(filter $(FRTOS_SHELL_GOALS),$(MAKECMDGOALS)),)
FRTOS_APP     ?= shell
endif
# UPLOAD= names the file that the app loader receives; no other program asks for one.
ifneq ($(and $(FRTOS_UPLOAD),$(filter freertos-shell,$(MAKECMDGOALS))),)
ifneq ($(FRTOS_APP),loader)
$(error UPLOAD= applies to the app loader only: make freertos-shell APP=loader UPLOAD=$(FRTOS_UPLOAD))
endif
endif

# ---- configuration knobs (the campaign sets all of them explicitly) ----
FRTOS_APP     ?= minimal
FRTOS_MARCH   ?= rv32i
FRTOS_OPT     ?= -O2
FRTOS_HEAP    ?= 4
FRTOS_TICK    ?= 10000
FRTOS_PREEMPT ?= 1
FRTOS_SLICE   ?= 1
FRTOS_DEFS    ?=
FRTOS_SEED    ?= 0
FRTOS_BPRED   ?= 0
FRTOS_OUT     ?= $(BUILD_DIR)/$(FRTOS_DIR)/$(FRTOS_APP)
FRTOS_CPU     ?= dut
override FRTOS_CPU := $(patsubst golden,ref,$(FRTOS_CPU))

# Goals that build a program (they read test/freertos/<app>/app.mk and track the flags).
FRTOS_BUILD_GOALS = frtos-elf frtos-run freertos freertos-compare $(FRTOS_SHELL_GOALS)
# Goals that need one program's settings (RAM size, timeout).
FRTOS_APP_GOALS   = $(filter frtos-% freertos freertos-compare $(FRTOS_SHELL_GOALS),$(MAKECMDGOALS))

# Per-program settings: APP_SRCS (C/asm, own march), APP_REF_SRCS (C, always compiled for
# plain rv32i with -DFRTOS_REF_BUILD, as an independent software reference), APP_DEMO_SRCS
# (file names in $(FREERTOS_DEMO)/Common/Minimal), APP_KERNEL_SRCS, APP_RAM_KB,
# APP_ISR_STACK, APP_DEFS, APP_INCLUDES (extra -I directories), APP_TIMEOUT, APP_CONSOLE
# (1: the program reads the UART, so it runs only under the console targets).
# APP_DIR is the program's own directory.
# For the console targets: APP_CONSOLE_DEPS (make goals built with the program before a
# console run), APP_CONSOLE_ARGS (extra simulator arguments of console runs, interactive and
# scripted), APP_TTY_TEST and APP_TTY_ARGS (the script of freertos-shell-tty-test and its
# extra arguments). APP_LINK_KB: the RAM size the program is linked for, if it is not the
# whole simulated RAM (the loader links the shell for the first 128 KiB of 256).
APP_DIR          = $(FRTOS_DIR)/$(FRTOS_APP)
APP_SRCS        :=
APP_REF_SRCS    :=
APP_DEMO_SRCS   :=
APP_KERNEL_SRCS := tasks.c queue.c list.c
APP_RAM_KB      := 32
APP_ISR_STACK   := 2048
APP_DEFS        :=
APP_INCLUDES    :=
APP_TIMEOUT     := 50000000
APP_CONSOLE     :=
APP_LINK_KB     :=
APP_CONSOLE_DEPS :=
APP_CONSOLE_ARGS :=
APP_TTY_TEST     = $(FRTOS_DIR)/shell/tty_test.py
APP_TTY_ARGS    :=
ifneq ($(FRTOS_APP_GOALS),)
ifeq ($(wildcard $(FRTOS_DIR)/$(FRTOS_APP)/app.mk),)
$(error FreeRTOS program '$(FRTOS_APP)' not found (no $(FRTOS_DIR)/$(FRTOS_APP)/app.mk). Programs: $(FRTOS_APPS). See: make freertos-list)
endif
include $(FRTOS_DIR)/$(FRTOS_APP)/app.mk
endif
ifneq ($(filter $(FRTOS_BUILD_GOALS),$(MAKECMDGOALS)),)
ifeq ($(wildcard $(FREERTOS_KERNEL)/tasks.c),)
$(error FreeRTOS kernel sources not found at $(FREERTOS_KERNEL). They are part of the repository, in third_party/freertos/: if FREERTOS_HOME, FREERTOS_KERNEL or FREERTOS_DEMO is set, unset it or point it to a complete checkout; if files are missing from third_party/freertos/, restore them with 'git checkout -- third_party/freertos'. See docs/FREERTOS.md)
endif
endif

FRTOS_RAM_KB  ?= $(APP_RAM_KB)
FRTOS_TIMEOUT ?= $(APP_TIMEOUT)
# The RAM size the program is linked for (__hades_ram_size): the simulated RAM, unless the
# program's app.mk says otherwise (APP_LINK_KB).
FRTOS_LINK_KB  = $(if $(strip $(APP_LINK_KB)),$(strip $(APP_LINK_KB)),$(FRTOS_RAM_KB))

FRTOS_SIZE     = $(patsubst %gcc,%size,$(CC))
FRTOS_PORT     = $(FREERTOS_KERNEL)/portable/GCC/RISC-V
FRTOS_INCLUDES = -I$(FRTOS_DIR)/$(FRTOS_APP) -I$(FRTOS_DIR)/common -I$(FREERTOS_KERNEL)/include \
                 -I$(FRTOS_PORT) -I$(FRTOS_PORT)/chip_specific_extensions/RISCV_MTIME_CLINT_no_extensions \
                 -I$(FREERTOS_DEMO)/Common/include
ifneq ($(strip $(APP_INCLUDES)),)
FRTOS_INCLUDES += $(APP_INCLUDES)
endif
FRTOS_KNOBS    = -DFRTOS_TICK_CYCLES=$(FRTOS_TICK) -DFRTOS_PREEMPT=$(FRTOS_PREEMPT) \
                 -DFRTOS_SLICE=$(FRTOS_SLICE) -DFRTOS_HEAP=$(FRTOS_HEAP) -DFRTOS_RAM_KB=$(FRTOS_RAM_KB) -DFRTOS_BPRED=$(FRTOS_BPRED) \
                 $(APP_DEFS) $(FRTOS_DEFS)
FRTOS_CFLAGS_COMMON = -mabi=ilp32 $(FRTOS_OPT) -g -ffunction-sections -fdata-sections \
                 -Wall -Wno-unused-function $(FRTOS_INCLUDES) $(FRTOS_KNOBS) -MMD -MP
FRTOS_CFLAGS     = -march=$(FRTOS_MARCH) $(FRTOS_CFLAGS_COMMON)
FRTOS_REF_CFLAGS = -march=rv32i $(FRTOS_CFLAGS_COMMON) -DFRTOS_REF_BUILD
FRTOS_LDFLAGS    = -march=$(FRTOS_MARCH) -mabi=ilp32 -nostdlib -nostartfiles \
                   -T $(FRTOS_DIR)/common/hades-freertos.ld \
                   -Wl,--defsym=__hades_ram_size=$(FRTOS_LINK_KB)K \
                   -Wl,--defsym=__isr_stack_size=$(APP_ISR_STACK) \
                   -Wl,--gc-sections -Wl,--no-warn-rwx-segments -Wl,-Map=$(FRTOS_OUT)/out.map

FRTOS_C_SRCS = $(addprefix $(FREERTOS_KERNEL)/,$(APP_KERNEL_SRCS)) \
               $(FREERTOS_KERNEL)/portable/MemMang/heap_$(FRTOS_HEAP).c \
               $(FRTOS_PORT)/port.c $(FRTOS_DIR)/common/hades_hal.c \
               $(addprefix $(FREERTOS_DEMO)/Common/Minimal/,$(APP_DEMO_SRCS)) \
               $(filter %.c,$(APP_SRCS))
FRTOS_S_SRCS = $(FRTOS_PORT)/portASM.S $(FRTOS_DIR)/common/start.S $(filter %.S,$(APP_SRCS))

FRTOS_OBJDIR = $(FRTOS_OUT)/obj
frtos_obj     = $(FRTOS_OBJDIR)/$(basename $(notdir $(1))).o
frtos_ref_obj = $(FRTOS_OBJDIR)/ref_$(basename $(notdir $(1))).o
FRTOS_OBJS    = $(foreach s,$(FRTOS_C_SRCS) $(FRTOS_S_SRCS),$(call frtos_obj,$(s))) \
                $(foreach s,$(APP_REF_SRCS),$(call frtos_ref_obj,$(s)))

# Rebuild everything when the flags change (the output dir is reused across configurations).
# The flags file is brought up to date while the makefile is parsed, i.e. before make
# compares any timestamps. (Doing it in a recipe was one invocation late: the first run
# after a knob change reused the ELF built with the previous knobs.)
FRTOS_FLAGS_FILE = $(FRTOS_OUT)/flags.txt
FRTOS_FLAGS_NOW  = $(FRTOS_CFLAGS) | $(FRTOS_REF_CFLAGS) | $(FRTOS_LDFLAGS) | $(FREERTOS_KERNEL) | $(FREERTOS_DEMO)
ifneq ($(filter $(FRTOS_BUILD_GOALS),$(MAKECMDGOALS)),)
FRTOS_FLAGS_SYNC := $(shell mkdir -p $(FRTOS_OBJDIR) && \
    if [ "$$(cat $(FRTOS_FLAGS_FILE) 2>/dev/null)" != '$(FRTOS_FLAGS_NOW)' ]; then \
        echo '$(FRTOS_FLAGS_NOW)' > $(FRTOS_FLAGS_FILE); fi)
endif
$(FRTOS_FLAGS_FILE):
	@ mkdir -p $(dir $@)
	@ echo '$(FRTOS_FLAGS_NOW)' > $@

define frtos_c_rule
$(call frtos_obj,$(1)): $(1) $(FRTOS_FLAGS_FILE)
	$$(CC) $$(FRTOS_CFLAGS) -c $$< -o $$@
endef
define frtos_ref_rule
$(call frtos_ref_obj,$(1)): $(1) $(FRTOS_FLAGS_FILE)
	$$(CC) $$(FRTOS_REF_CFLAGS) -c $$< -o $$@
endef
$(foreach s,$(FRTOS_C_SRCS) $(FRTOS_S_SRCS),$(eval $(call frtos_c_rule,$(s))))
$(foreach s,$(APP_REF_SRCS),$(eval $(call frtos_ref_rule,$(s))))
-include $(wildcard $(FRTOS_OBJDIR)/*.d)

$(FRTOS_OUT)/out.elf: $(FRTOS_OBJS) $(FRTOS_DIR)/common/hades-freertos.ld
	$(CC) $(FRTOS_LDFLAGS) -o $@ $(FRTOS_OBJS) -lc_nano -lgcc
	$(OBJDUMP) -d $@ > $(FRTOS_OUT)/out.dis
	$(OBJCOPY) -O binary $@ $(FRTOS_OUT)/out.bin
	$(OBJCOPY) -I binary -O verilog -S --verilog-data-width 4 --reverse-bytes=4 $(FRTOS_OUT)/out.bin $(FRTOS_OUT)/init.mem
	@ $(FRTOS_SIZE) -A $@ | awk '/^\.(reset|text|rodata|data|sdata|sbss|bss) /{s[$$1]=$$2; t+=$$2} END{printf "  %s: RAM %d KiB, image+bss %d bytes (text %d, rodata %d, data %d, bss %d)\n", "$(FRTOS_APP)", $(FRTOS_RAM_KB), t, s[".text"]+s[".reset"], s[".rodata"], s[".data"]+s[".sdata"], s[".bss"]+s[".sbss"]}'

.PHONY: frtos-elf
frtos-elf: $(FRTOS_OUT)/out.elf

# ---- simulator variants: DUT or golden reference CPU, any RAM size ----
# (explicit rules for both CPUs at the current RAM size, so freertos-compare can use both)
FRTOS_MODEL_DIR  = $(BUILD_DIR)/frtos-model/$(FRTOS_CPU)-$(FRTOS_RAM_KB)k
frtos_model_dir  = $(BUILD_DIR)/frtos-model/$(1)-$(FRTOS_RAM_KB)k
FRTOS_MODEL_DEFS_dut = +define+HADES_MEMORY_SIZE_WORDS=$(shell echo $$(( $(FRTOS_RAM_KB) * 256 )))
FRTOS_MODEL_DEFS_ref = $(FRTOS_MODEL_DEFS_dut) +define+USE_REF_CPU
-include $(wildcard $(call frtos_model_dir,dut)/top__ver.d $(call frtos_model_dir,ref)/top__ver.d)

define frtos_model_rules
$(call frtos_model_dir,$(1))/top.mk: $(REF_SO_DEPS)
	@ mkdir -p $$(@D)
	$$(VERILATOR) $$(VERILATOR_FLAGS) $$(FRTOS_MODEL_DEFS_$(1)) --trace-fst --trace-structs --timing --assert --main --exe --prefix top -Mdir $$(@D) --top-module top sim/top.sv

$(call frtos_model_dir,$(1))/top: $(call frtos_model_dir,$(1))/top.mk
	$$(MAKE) -C $$(@D) -f top.mk
endef
$(foreach c,dut ref,$(eval $(call frtos_model_rules,$(c))))

.PHONY: frtos-model
frtos-model: $(FRTOS_MODEL_DIR)/top

# The golden CPU implements RV32I + Zicsr only (no M, no Zba): refuse to build and run
# anything else for it rather than let it fail on the first illegal instruction.
FRTOS_GOLDEN_MARCH_ERROR = The golden CPU runs RV32I only (it has no M and no Zba), but MARCH/FRTOS_MARCH is '$(FRTOS_MARCH)'. Leave MARCH unset (rv32i is the default) to run on the golden CPU
ifneq ($(filter rv32i,$(FRTOS_MARCH)),rv32i)
ifneq ($(filter freertos-compare,$(MAKECMDGOALS)),)
$(error $(FRTOS_GOLDEN_MARCH_ERROR))
endif
ifneq ($(filter freertos-shell-compare freertos-loader-compare,$(MAKECMDGOALS)),)
$(error $(FRTOS_GOLDEN_MARCH_ERROR))
endif
ifeq ($(FRTOS_CPU),ref)
ifneq ($(filter frtos-run freertos freertos-shell freertos-shell-test freertos-shell-tty-test freertos-loader-test,$(MAKECMDGOALS)),)
$(error $(FRTOS_GOLDEN_MARCH_ERROR))
endif
endif
endif

# A program that reads the UART (APP_CONSOLE := 1 in its app.mk) would wait forever for
# input under the plain simulator.
ifeq ($(strip $(APP_CONSOLE)),1)
ifneq ($(filter frtos-run freertos freertos-compare,$(MAKECMDGOALS)),)
$(error '$(FRTOS_APP)' is an interactive program that reads the UART: run it with 'make freertos-shell$(if $(filter shell,$(FRTOS_APP)),, APP=$(FRTOS_APP))' (your terminal types into it; Ctrl-] quits) or check it with 'make $(if $(filter loader,$(FRTOS_APP)),freertos-loader-test,freertos-shell-test$(if $(filter shell,$(FRTOS_APP)),, APP=$(FRTOS_APP)))' (a scripted session). See docs/FREERTOS.md)
endif
endif

# ---- one-shot build + run (plain simulator output) ----
.PHONY: frtos-run
frtos-run: frtos-elf frtos-model
	cd $(FRTOS_OUT) && $(BUILD_ABS)/frtos-model/$(FRTOS_CPU)-$(FRTOS_RAM_KB)k/top +nodump +timeout=$(FRTOS_TIMEOUT) +switches=$(FRTOS_SEED)

FRTOS_TEST_NAMES = $(addprefix $(FRTOS_DIR)/,$(FRTOS_APPS))
.PHONY: $(FRTOS_TEST_NAMES)
$(FRTOS_TEST_NAMES): $(FRTOS_DIR)/%:
	$(MAKE) --no-print-directory frtos-run FRTOS_APP=$*

# ---- front end: build + run with a verdict ----
frtos_cpu_name = $(if $(filter ref,$(1)),golden,dut)
# run.sh <simulator> <run dir> <timeout> <seed> <log name> <label> <waves>
frtos_run_sh   = sh $(FRTOS_DIR)/run.sh $(BUILD_ABS)/frtos-model/$(1)-$(FRTOS_RAM_KB)k/top \
                 $(abspath $(FRTOS_OUT)) $(FRTOS_TIMEOUT) $(FRTOS_SEED) run-$(call frtos_cpu_name,$(1)).log \
                 "app=$(FRTOS_APP) cpu=$(call frtos_cpu_name,$(1)) isa=$(FRTOS_MARCH) opt=$(FRTOS_OPT) tick=$(FRTOS_TICK) bpred=$(FRTOS_BPRED) seed=$(FRTOS_SEED)" \
                 "$(WAVES)"
# Build the program and simulator(s) $(1) quietly into build.log (VERBOSE=1 shows everything).
# The sub-make gets the same command-line knobs, so it builds exactly this configuration.
FRTOS_BUILD_LOG = $(abspath $(FRTOS_OUT))/build.log
define frtos_quiet_build
@ mkdir -p $(FRTOS_OUT)
@ echo "build: $(FRTOS_APP) [$(FRTOS_MARCH) $(FRTOS_OPT) tick=$(FRTOS_TICK) bpred=$(FRTOS_BPRED)] and the $(2) simulator(s)"
@ echo "       (the first build of a simulator takes up to a minute; log: $(FRTOS_BUILD_LOG))"
@ if [ -n "$(VERBOSE)" ]; then $(MAKE) --no-print-directory $(1); else \
      $(MAKE) --no-print-directory $(1) > $(FRTOS_BUILD_LOG) 2>&1 || \
      { tail -n 40 $(FRTOS_BUILD_LOG); echo "BUILD FAILED -- full log: $(FRTOS_BUILD_LOG)"; exit 1; }; \
      grep -a 'image+bss' $(FRTOS_BUILD_LOG) || echo "  (program up to date, not rebuilt)"; fi
endef

.PHONY: freertos
freertos:
	$(call frtos_quiet_build,frtos-elf frtos-model,$(call frtos_cpu_name,$(FRTOS_CPU)))
	@ $(call frtos_run_sh,$(FRTOS_CPU))

.PHONY: freertos-compare
freertos-compare:
	$(call frtos_quiet_build,frtos-elf $(call frtos_model_dir,dut)/top $(call frtos_model_dir,ref)/top,dut and golden)
	@ $(call frtos_run_sh,dut); \
	  $(call frtos_run_sh,ref); \
	  sh $(FRTOS_DIR)/run.sh --compare $(abspath $(FRTOS_OUT))/run-dut.log $(abspath $(FRTOS_OUT))/run-golden.log

# ---- front end: list, new program, stress campaign, rebuild check ----
.PHONY: freertos-list
freertos-list:
	@ echo "FreeRTOS programs (make freertos APP=<name>; the interactive ones: make freertos-shell APP=<name>):"
	@ for f in $(sort $(wildcard $(FRTOS_DIR)/*/app.mk)); do \
	      n=$$(basename $$(dirname $$f)); \
	      d=$$(head -n 1 $$f | sed -e 's/^# *//' -e "s/^$$n: *//"); \
	      printf '  %-10s %s\n' "$$n" "$$d"; \
	  done

# FROM=<app> starts the new program from a copy of another one instead of the template:
# every file of test/freertos/<app>/ except its Python tools (FROM=shell gives a shell of
# your own, to which you can add commands; see docs/FREERTOS.md, section 9).
FRTOS_NEW_FROM = $(if $(filter command line,$(origin FROM)),$(FROM),template)

.PHONY: freertos-new
freertos-new:
	@ case '$(NAME)' in '') echo "usage: make freertos-new NAME=<name>   (letters, digits, - and _)"; exit 1;; \
	      *[!A-Za-z0-9_-]*) echo "invalid program name '$(NAME)': use letters, digits, - and _"; exit 1;; esac
	@ if [ -e $(FRTOS_DIR)/$(NAME) ]; then echo "$(FRTOS_DIR)/$(NAME) already exists"; exit 1; fi
ifeq ($(FRTOS_NEW_FROM),template)
	@ mkdir -p $(FRTOS_DIR)/$(NAME)
	@ cp $(FRTOS_DIR)/template/app_config.h $(FRTOS_DIR)/template/main.c $(FRTOS_DIR)/$(NAME)/
	@ sed -e '1s/^# template:.*/# $(NAME): my FreeRTOS program (created from test\/freertos\/template)/' \
	      $(FRTOS_DIR)/template/app.mk > $(FRTOS_DIR)/$(NAME)/app.mk
	@ echo "created $(FRTOS_DIR)/$(NAME)/ (app.mk, app_config.h, main.c)"
	@ echo "edit $(FRTOS_DIR)/$(NAME)/main.c, then run it with:  make freertos APP=$(NAME)"
else
	@ case '$(FRTOS_NEW_FROM)' in ''|*[!A-Za-z0-9_-]*) echo "invalid program name FROM='$(FRTOS_NEW_FROM)'"; exit 1;; esac
	@ if [ ! -f $(FRTOS_DIR)/$(FRTOS_NEW_FROM)/app.mk ]; then \
	      echo "FreeRTOS program '$(FRTOS_NEW_FROM)' not found (FROM=); programs: $(FRTOS_APPS)"; exit 1; fi
	@ mkdir -p $(FRTOS_DIR)/$(NAME)
	@ for f in $(FRTOS_DIR)/$(FRTOS_NEW_FROM)/*; do \
	      case "$$f" in */app.mk|*.py) ;; *) cp "$$f" $(FRTOS_DIR)/$(NAME)/;; esac; done
	@ sed -e '1s/^# $(FRTOS_NEW_FROM):/# $(NAME): created from test\/freertos\/$(FRTOS_NEW_FROM):/' \
	      $(FRTOS_DIR)/$(FRTOS_NEW_FROM)/app.mk > $(FRTOS_DIR)/$(NAME)/app.mk
	@ echo "created $(FRTOS_DIR)/$(NAME)/ ($$(cd $(FRTOS_DIR)/$(NAME) && ls | tr '\n' ' ' | sed 's/ $$//'))"
	@ if grep -q '^APP_CONSOLE *:= *1' $(FRTOS_DIR)/$(NAME)/app.mk; then \
	      echo "edit the files in $(FRTOS_DIR)/$(NAME)/, then run it with:  make freertos-shell APP=$(NAME)"; \
	  else echo "edit the files in $(FRTOS_DIR)/$(NAME)/, then run it with:  make freertos APP=$(NAME)"; fi
endif

FRTOS_STRESS_SET   = $(if $(filter command line,$(origin SET)),$(SET),validate)
FRTOS_STRESS_SEEDS = $(if $(filter command line,$(origin SEEDS)),$(SEEDS),2)
FRTOS_STRESS_JOBS  = $(if $(filter command line,$(origin JOBS)),$(JOBS),4)
.PHONY: freertos-stress
freertos-stress:
	$(if $(filter build,$(BUILD_DIR)),,HADES_BUILD_DIR=$(BUILD_ABS)) python3 $(FRTOS_DIR)/campaign.py \
	    --set $(FRTOS_STRESS_SET) --seeds $(FRTOS_STRESS_SEEDS) --jobs $(FRTOS_STRESS_JOBS) --strict \
	    --kernel $(FREERTOS_KERNEL) --demo $(FREERTOS_DEMO) --out $(BUILD_ABS)/freertos-campaign/$(FRTOS_STRESS_SET)

.PHONY: freertos-check-rebuild
freertos-check-rebuild:
	sh $(FRTOS_DIR)/check_rebuild.sh $(BUILD_DIR)/freertos-rebuild-check

# ---- interactive console: a program's UART connected to a terminal or a script ----
# The console simulators are separate variants (frtos-model/<cpu>-<n>k-console), verilated
# with +define+HADES_CONSOLE and the DPI bridge sim/console.cpp; the plain simulators above
# are unchanged. Run options of sim/top.sv in this variant: +console_pty (a pseudo-terminal
# instead of this terminal), +console_pty_link=<path> (a symlink to it), +console_script=<file>
# (type a script, one line per prompt), +console_log=<file> (copy of the UART output),
# +console_prompt=<text> (the program's prompt, which paces scripts and pastes; default
# "hades> "), +console_upload=<file>, +console_upload_dir=<dir> and +console_app_dir=<dir> (the
# file sent when the program asks for one, the directory of relative file names, and that of
# the apps the program asks for by name: the app loader, test/freertos/loader/SPEC.md). See
# docs/FREERTOS.md, section 9.
FRTOS_CONSOLE_CPP   = $(SIM_DIR)/console.cpp
frtos_con_model_dir = $(BUILD_DIR)/frtos-model/$(1)-$(FRTOS_RAM_KB)k-console
frtos_con_sim       = $(BUILD_ABS)/frtos-model/$(1)-$(FRTOS_RAM_KB)k-console/top
-include $(wildcard $(call frtos_con_model_dir,dut)/top__ver.d $(call frtos_con_model_dir,ref)/top__ver.d)

define frtos_con_model_rules
$(call frtos_con_model_dir,$(1))/top.mk: $(REF_SO_DEPS)
	@ mkdir -p $$(@D)
	$$(VERILATOR) $$(VERILATOR_FLAGS) $$(FRTOS_MODEL_DEFS_$(1)) +define+HADES_CONSOLE --trace-fst --trace-structs --timing --assert --main --exe --prefix top -Mdir $$(@D) --top-module top sim/top.sv $$(abspath $$(FRTOS_CONSOLE_CPP))

$(call frtos_con_model_dir,$(1))/top: $(call frtos_con_model_dir,$(1))/top.mk $$(FRTOS_CONSOLE_CPP)
	$$(MAKE) -C $$(@D) -f top.mk
endef
$(foreach c,dut ref,$(eval $(call frtos_con_model_rules,$(c))))

# An interactive session has no cycle limit unless TIMEOUT= is given; a scripted one uses
# the program's APP_TIMEOUT (or TIMEOUT=).
FRTOS_SHELL_TIMEOUT = $(if $(filter command line,$(origin TIMEOUT) $(origin FRTOS_TIMEOUT)),$(FRTOS_TIMEOUT),9000000000000000000)
FRTOS_SHELL_SCRIPT  = $(abspath $(if $(FRTOS_SCRIPT),$(FRTOS_SCRIPT),$(APP_DIR)/session.txt))
FRTOS_SHELL_DUMP    = $(if $(filter-out 0,$(WAVES)),,+nodump)
frtos_shell_label   = app=$(FRTOS_APP) cpu=$(call frtos_cpu_name,$(1)) isa=$(FRTOS_MARCH) opt=$(FRTOS_OPT) tick=$(FRTOS_TICK) bpred=$(FRTOS_BPRED) seed=$(FRTOS_SEED)
# What a console run builds (quietly): the program, the simulator(s) $(1), and the goals of
# the program's APP_CONSOLE_DEPS.
frtos_con_goals     = FRTOS_APP=$(FRTOS_APP) frtos-elf $(1) $(APP_CONSOLE_DEPS)
# UPLOAD=<app> (freertos-shell only): the file that the console bridge sends whenever the
# program asks for one (+console_upload=<absolute path>). sdk.mk turns the value into that
# path, and names the goal that builds the file.
FRTOS_UPLOAD_FILE   = $(if $(FRTOS_UPLOAD),$(call sdk_upload_file,$(FRTOS_UPLOAD)))
FRTOS_UPLOAD_GOAL   = $(if $(FRTOS_UPLOAD),$(call sdk_upload_goal,$(FRTOS_UPLOAD)))
# session.py run ... : run the script on simulator $(1), stream and check the transcript; the
# script $(2) instead of SCRIPT's, and the logs named $(3)-<cpu>.log/.uart, if they are given
frtos_session = python3 $(FRTOS_DIR)/shell/session.py run --sim $(call frtos_con_sim,$(1)) \
                --dir $(abspath $(FRTOS_OUT)) --script $(if $(2),$(2),$(FRTOS_SHELL_SCRIPT)) --cpu $(call frtos_cpu_name,$(1)) \
                $(if $(3),--name $(3)) \
                --timeout $(FRTOS_TIMEOUT) --seed $(FRTOS_SEED) --label "$(call frtos_shell_label,$(1))" \
                $(if $(filter-out 0,$(WAVES)),--waves) $(foreach a,$(APP_CONSOLE_ARGS),--sim-arg $(a))

.PHONY: freertos-shell
freertos-shell:
	$(call frtos_quiet_build,$(call frtos_con_goals,$(call frtos_con_model_dir,$(FRTOS_CPU))/top) $(FRTOS_UPLOAD_GOAL),$(call frtos_cpu_name,$(FRTOS_CPU)) console)
	@ echo "run: $(call frtos_shell_label,$(FRTOS_CPU))  (UART copy: $(abspath $(FRTOS_OUT))/console.log)"
	@ echo "     (the first 'Test fail!' line is the program's deliberate 'initial test' marker)"
	@ cd $(FRTOS_OUT) && $(call frtos_con_sim,$(FRTOS_CPU)) $(FRTOS_SHELL_DUMP) +timeout=$(FRTOS_SHELL_TIMEOUT) \
	      +switches=$(FRTOS_SEED) +console_log=console.log \
	      $(if $(filter-out 0,$(FRTOS_PTY)),+console_pty +console_pty_link=$(abspath $(FRTOS_OUT))/pty) \
	      $(APP_CONSOLE_ARGS) $(if $(FRTOS_UPLOAD_FILE),+console_upload=$(FRTOS_UPLOAD_FILE))

.PHONY: freertos-shell-test
freertos-shell-test:
	$(call frtos_quiet_build,$(call frtos_con_goals,$(call frtos_con_model_dir,$(FRTOS_CPU))/top),$(call frtos_cpu_name,$(FRTOS_CPU)) console)
	@ $(call frtos_session,$(FRTOS_CPU))

.PHONY: freertos-shell-compare
freertos-shell-compare:
	$(call frtos_quiet_build,$(call frtos_con_goals,$(call frtos_con_model_dir,dut)/top $(call frtos_con_model_dir,ref)/top),dut and golden console)
	@ rc=0; $(call frtos_session,dut) || rc=1; $(call frtos_session,ref) || rc=1; \
	  python3 $(FRTOS_DIR)/shell/session.py compare --script $(FRTOS_SHELL_SCRIPT) \
	      $(abspath $(FRTOS_OUT))/session-dut.log $(abspath $(FRTOS_OUT))/session-golden.log || rc=1; \
	  exit $$rc

.PHONY: freertos-shell-tty-test
freertos-shell-tty-test:
	$(call frtos_quiet_build,$(call frtos_con_goals,$(call frtos_con_model_dir,$(FRTOS_CPU))/top),$(call frtos_cpu_name,$(FRTOS_CPU)) console)
	@ python3 $(APP_TTY_TEST) --sim $(call frtos_con_sim,$(FRTOS_CPU)) --dir $(abspath $(FRTOS_OUT)) $(APP_TTY_ARGS)

# ---- the app loader's scripted sessions (test/freertos/loader/): session.txt (every example
# app, crash containment, Ctrl-C, every rejected file; RV32I apps only, so that it runs on both
# CPUs) and session-ext.txt (compute built for rv32im_zba: run on HaDes-V+, refused by the
# golden CPU). Each prints its own verdict; the last line sums them up, and make's exit status
# is 0 only if every part passed. The logs: session-<cpu> and session-ext-<cpu>.log/.uart.
FRTOS_LOADER_SCRIPT = $(abspath $(FRTOS_DIR)/loader/session.txt)
FRTOS_LOADER_EXT    = $(abspath $(FRTOS_DIR)/loader/session-ext.txt)
frtos_verdict       = if [ $$rc = 0 ]; then echo "$(1): PASS  $$sum"; else echo "$(1): FAIL  $$sum"; fi; exit $$rc

.PHONY: freertos-loader-test freertos-loader-compare
freertos-loader-test:
	$(call frtos_quiet_build,$(call frtos_con_goals,$(call frtos_con_model_dir,$(FRTOS_CPU))/top),$(call frtos_cpu_name,$(FRTOS_CPU)) console)
	@ rc=0; a=PASS; b=PASS; \
	  $(call frtos_session,$(FRTOS_CPU),$(FRTOS_LOADER_SCRIPT)) || { a='not passed'; rc=1; }; \
	  $(call frtos_session,$(FRTOS_CPU),$(FRTOS_LOADER_EXT),session-ext) || { b='not passed'; rc=1; }; \
	  sum="cpu=$(call frtos_cpu_name,$(FRTOS_CPU))  session.txt $$a, session-ext.txt $$b"; \
	  $(call frtos_verdict,LOADER TEST)

freertos-loader-compare:
	$(call frtos_quiet_build,$(call frtos_con_goals,$(call frtos_con_model_dir,dut)/top $(call frtos_con_model_dir,ref)/top),dut and golden console)
	@ rc=0; a=PASS; b=PASS; c=PASS; d=PASS; e=SAME; \
	  $(call frtos_session,dut,$(FRTOS_LOADER_SCRIPT)) || { a='not passed'; rc=1; }; \
	  $(call frtos_session,ref,$(FRTOS_LOADER_SCRIPT)) || { b='not passed'; rc=1; }; \
	  python3 $(FRTOS_DIR)/shell/session.py compare --script $(FRTOS_LOADER_SCRIPT) \
	      $(abspath $(FRTOS_OUT))/session-dut.log $(abspath $(FRTOS_OUT))/session-golden.log || { e='not the same'; rc=1; }; \
	  $(call frtos_session,dut,$(FRTOS_LOADER_EXT),session-ext) || { c='not passed'; rc=1; }; \
	  $(call frtos_session,ref,$(FRTOS_LOADER_EXT),session-ext) || { d='not passed'; rc=1; }; \
	  sum="session.txt: dut $$a, golden $$b, transcripts $$e; session-ext.txt: dut $$c, golden $$d"; \
	  $(call frtos_verdict,LOADER COMPARE)

# ---- the app SDK (test/freertos/sdk/): freertos-app, freertos-apps, freertos-send, SDK_OUT,
# and the functions sdk_upload_file and sdk_upload_goal used above ----
include $(FRTOS_DIR)/sdk/sdk.mk
