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
#   make freertos-new NAME=<name>         copy test/freertos/template to test/freertos/<name>
#   make freertos-check-rebuild           regression test for the configuration tracking
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
#   FREERTOS_PLUS_CLI FreeRTOS-Plus-CLI          (vendored: FreeRTOS/FreeRTOS f4fcc3b; not yet
#                     compiled by any program)
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
FRTOS_ALIASES = APP CPU MARCH OPT TICK SEED TIMEOUT BPRED PREEMPT SLICE HEAP DEFS RAM_KB
$(foreach a,$(FRTOS_ALIASES),$(if $(filter command line,$(origin $(a))),$(eval FRTOS_$(a) := $$($(a)))))

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
FRTOS_BUILD_GOALS = frtos-elf frtos-run freertos freertos-compare
# Goals that need one program's settings (RAM size, timeout).
FRTOS_APP_GOALS   = $(filter frtos-% freertos freertos-compare,$(MAKECMDGOALS))

# Per-program settings: APP_SRCS (C/asm, own march), APP_REF_SRCS (C, always compiled for
# plain rv32i with -DFRTOS_REF_BUILD, as an independent software reference), APP_DEMO_SRCS
# (file names in $(FREERTOS_DEMO)/Common/Minimal), APP_KERNEL_SRCS, APP_RAM_KB,
# APP_ISR_STACK, APP_DEFS, APP_TIMEOUT. APP_DIR is the program's own directory.
APP_DIR          = $(FRTOS_DIR)/$(FRTOS_APP)
APP_SRCS        :=
APP_REF_SRCS    :=
APP_DEMO_SRCS   :=
APP_KERNEL_SRCS := tasks.c queue.c list.c
APP_RAM_KB      := 32
APP_ISR_STACK   := 2048
APP_DEFS        :=
APP_TIMEOUT     := 50000000
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

FRTOS_SIZE     = $(patsubst %gcc,%size,$(CC))
FRTOS_PORT     = $(FREERTOS_KERNEL)/portable/GCC/RISC-V
FRTOS_INCLUDES = -I$(FRTOS_DIR)/$(FRTOS_APP) -I$(FRTOS_DIR)/common -I$(FREERTOS_KERNEL)/include \
                 -I$(FRTOS_PORT) -I$(FRTOS_PORT)/chip_specific_extensions/RISCV_MTIME_CLINT_no_extensions \
                 -I$(FREERTOS_DEMO)/Common/include
FRTOS_KNOBS    = -DFRTOS_TICK_CYCLES=$(FRTOS_TICK) -DFRTOS_PREEMPT=$(FRTOS_PREEMPT) \
                 -DFRTOS_SLICE=$(FRTOS_SLICE) -DFRTOS_HEAP=$(FRTOS_HEAP) -DFRTOS_RAM_KB=$(FRTOS_RAM_KB) -DFRTOS_BPRED=$(FRTOS_BPRED) \
                 $(APP_DEFS) $(FRTOS_DEFS)
FRTOS_CFLAGS_COMMON = -mabi=ilp32 $(FRTOS_OPT) -g -ffunction-sections -fdata-sections \
                 -Wall -Wno-unused-function $(FRTOS_INCLUDES) $(FRTOS_KNOBS) -MMD -MP
FRTOS_CFLAGS     = -march=$(FRTOS_MARCH) $(FRTOS_CFLAGS_COMMON)
FRTOS_REF_CFLAGS = -march=rv32i $(FRTOS_CFLAGS_COMMON) -DFRTOS_REF_BUILD
FRTOS_LDFLAGS    = -march=$(FRTOS_MARCH) -mabi=ilp32 -nostdlib -nostartfiles \
                   -T $(FRTOS_DIR)/common/hades-freertos.ld \
                   -Wl,--defsym=__hades_ram_size=$(FRTOS_RAM_KB)K \
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
ifeq ($(FRTOS_CPU),ref)
ifneq ($(filter frtos-run freertos,$(MAKECMDGOALS)),)
$(error $(FRTOS_GOLDEN_MARCH_ERROR))
endif
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
	@ echo "FreeRTOS programs (make freertos APP=<name>):"
	@ for f in $(sort $(wildcard $(FRTOS_DIR)/*/app.mk)); do \
	      n=$$(basename $$(dirname $$f)); \
	      d=$$(head -n 1 $$f | sed -e 's/^# *//' -e "s/^$$n: *//"); \
	      printf '  %-10s %s\n' "$$n" "$$d"; \
	  done

.PHONY: freertos-new
freertos-new:
	@ case '$(NAME)' in '') echo "usage: make freertos-new NAME=<name>   (letters, digits, - and _)"; exit 1;; \
	      *[!A-Za-z0-9_-]*) echo "invalid program name '$(NAME)': use letters, digits, - and _"; exit 1;; esac
	@ if [ -e $(FRTOS_DIR)/$(NAME) ]; then echo "$(FRTOS_DIR)/$(NAME) already exists"; exit 1; fi
	@ mkdir -p $(FRTOS_DIR)/$(NAME)
	@ cp $(FRTOS_DIR)/template/app_config.h $(FRTOS_DIR)/template/main.c $(FRTOS_DIR)/$(NAME)/
	@ sed -e '1s/^# template:.*/# $(NAME): my FreeRTOS program (created from test\/freertos\/template)/' \
	      $(FRTOS_DIR)/template/app.mk > $(FRTOS_DIR)/$(NAME)/app.mk
	@ echo "created $(FRTOS_DIR)/$(NAME)/ (app.mk, app_config.h, main.c)"
	@ echo "edit $(FRTOS_DIR)/$(NAME)/main.c, then run it with:  make freertos APP=$(NAME)"

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
