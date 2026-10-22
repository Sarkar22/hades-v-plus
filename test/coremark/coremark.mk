# ---------------------------------------------------------------------------------------------
# CoreMark (included by the top-level Makefile). Guide: test/coremark/README.md.
#
#   make coremark [ITERATIONS=10] [MARCH=rv32im] [OPT=-O2] [CPU=golden] [RUN=performance|validation]
#                 [TIMEOUT=<cycles>] [BPRED=0..3]
#       Builds CoreMark (third_party/coremark, unmodified) with the port in this directory
#       for MARCH and OPT, runs it on the simulator of the assembly and C tests (HaDes-V+; CPU=golden:
#       the golden reference CPU, MARCH=rv32i only), and prints the summary of
#       test/coremark/coremark.py, which ends in one line, "COREMARK <label>: PASS" or
#       "COREMARK <label>: FAIL". The target fails unless it says PASS: CoreMark's own CRC
#       checks have to hold.
#
# Every short knob is an alias of the CM_<KNOB> variable and is honoured only on the command
# line. The simulator configurations of the Makefile (MEM_LAT=..., ICACHE=..., HPM_PRESET=...;
# make help) apply: the simulators and the outputs then go to the configuration's own build
# directory. With HPM_PRESET the port reads the seven programmable counters around the timed
# window and the summary breaks the cycles down by the preset's events.
#
# The run is a simulation: it cannot last CoreMark's 10 seconds, so CoreMark itself reports the
# missing seconds as an error and the figures are CoreMark/MHz estimates. See the guide.
# ---------------------------------------------------------------------------------------------

CM_DIR     = $(TEST_DIR)/coremark
CM_SRC_DIR = third_party/coremark
CM_FILES   = core_list_join core_main core_matrix core_state core_util
CM_SIZE    = $(patsubst %gcc,%size,$(CC))
CM_STD_SRC = $(sort $(wildcard $(STD_LIB_DIR)/src/*.c))

CM_ALIASES = ITERATIONS MARCH OPT CPU RUN TIMEOUT BPRED
$(foreach a,$(CM_ALIASES),$(if $(filter command line,$(origin $(a))),$(eval CM_$(a) := $$($(a)))))

CM_CPU ?= dut
override CM_CPU := $(patsubst golden,ref,$(CM_CPU))
CM_MARCH      ?= $(if $(filter ref,$(CM_CPU)),rv32i,rv32im)
CM_OPT        ?= -O2
CM_ITERATIONS ?= 10
CM_RUN        ?= performance
# the cycle limit: enough for a slow, uncached memory (about 15 million cycles per iteration)
CM_TIMEOUT    ?= $(shell echo $$(( 20000000 + $(CM_ITERATIONS) * 15000000 )))

ifneq ($(filter coremark,$(MAKECMDGOALS)),)
ifeq ($(filter dut ref,$(CM_CPU)),)
$(error coremark: CPU must be golden or dut, not '$(CM_CPU)')
endif
ifneq ($(words $(CM_OPT)) $(filter -O0 -O1 -O2 -O3 -Os -Og,$(CM_OPT)),1 $(CM_OPT))
$(error coremark: OPT must be one optimisation level (-O0, -O1, -O2, -O3, -Os or -Og), not '$(CM_OPT)')
endif
ifeq ($(shell echo '$(CM_ITERATIONS)' | awk '/^[1-9][0-9]*$$/ { print "ok" }'),)
$(error coremark: ITERATIONS='$(CM_ITERATIONS)': give a positive number (0, CoreMark's automatic choice for 10 seconds, cannot end in a simulation))
endif
ifneq ($(CM_BPRED),)
ifeq ($(filter 0 1 2 3,$(CM_BPRED)),)
$(error coremark: BPRED must be 0, 1, 2 or 3 (the predictor's algorithm, docs/EXTENSIONS.md), not '$(CM_BPRED)')
endif
ifeq ($(CM_CPU),ref)
$(error coremark: the golden CPU has no branch predictor: leave BPRED unset)
endif
endif
ifeq ($(filter performance validation,$(CM_RUN)),)
$(error coremark: RUN must be performance or validation, not '$(CM_RUN)')
endif
ifeq ($(CM_CPU),ref)
ifneq ($(CM_MARCH),rv32i)
$(error coremark: the golden CPU runs RV32I only (no M, no Zba), but MARCH is '$(CM_MARCH)': leave MARCH unset for CPU=golden)
endif
endif
endif

CM_TAG    = $(if $(filter ref,$(CM_CPU)),golden,dut)-$(CM_MARCH)-$(subst -,,$(CM_OPT))-$(CM_RUN)-i$(CM_ITERATIONS)$(if $(CM_BPRED),-bp$(CM_BPRED))$(if $(HPM_PRESET),-hpm)
CM_OUT    = $(BUILD_DIR)/$(CM_DIR)/$(CM_TAG)
CM_FLAGS  = $(CM_OPT) -march=$(CM_MARCH) -mabi=ilp32
CM_DEFS   = -DITERATIONS=$(CM_ITERATIONS) -D$(if $(filter validation,$(CM_RUN)),VALIDATION_RUN,PERFORMANCE_RUN)=1 \
            -DHADES_INSTRET=$(if $(filter ref,$(CM_CPU)),0,1) -DHADES_HPM=$(if $(HPM_PRESET),1,0)$(if $(CM_BPRED), -DHADES_BPRED=$(CM_BPRED))
CM_CFLAGS = -fdata-sections -ffunction-sections $(CM_FLAGS) -I $(CM_DIR) -I $(CM_SRC_DIR) -I $(STD_LIB_DIR)/include \
            $(CM_DEFS) '-DFLAGS_STR="$(CM_FLAGS)"'
CM_OBJS     = $(addprefix $(CM_OUT)/,$(addsuffix .o,$(CM_FILES) core_portme))
CM_STD_OBJS = $(patsubst $(STD_LIB_DIR)/src/%.c,$(CM_OUT)/std/%.o,$(CM_STD_SRC))

# CoreMark's files and the port, all with the same flags (a CoreMark run rule)
$(CM_OUT)/core_portme.o: $(CM_DIR)/core_portme.c $(CM_DIR)/core_portme.h $(CM_SRC_DIR)/coremark.h
	@ mkdir -p $(@D)
	$(CC) $(CM_CFLAGS) -c -o $@ $<
$(CM_OUT)/core_%.o: $(CM_SRC_DIR)/core_%.c $(CM_DIR)/core_portme.h $(CM_SRC_DIR)/coremark.h
	@ mkdir -p $(@D)
	$(CC) $(CM_CFLAGS) -c -o $@ $<

# The std objects (start code; nothing of them runs in the timed window) are built for rv32i,
# as for the other benchmarks
$(CM_OUT)/std/%.o: $(STD_LIB_DIR)/src/%.c $(wildcard $(STD_LIB_DIR)/include/*.h)
	@ mkdir -p $(@D)
	$(CC) -fdata-sections -ffunction-sections $(CM_OPT) -march=rv32i -mabi=ilp32 -I $(STD_LIB_DIR)/include -c -o $@ $<

$(CM_OUT)/out.elf: $(CM_OBJS) $(CM_STD_OBJS) $(STD_LIB_DIR)/hades-v.ld
	$(CC) -o $@ -nostdlib -nostartfiles -T $(STD_LIB_DIR)/hades-v.ld $(CM_FLAGS) $(CM_OBJS) $(CM_STD_OBJS) -lgcc -Wl,--no-warn-rwx-segments -Wl,--gc-sections
$(CM_OUT)/out.bin: $(CM_OUT)/out.elf
	$(OBJCOPY) -O binary $< $@
$(CM_OUT)/init.mem: $(CM_OUT)/out.bin
	$(OBJCOPY) -I binary -O verilog -S --verilog-data-width 4 --reverse-bytes=4 $< $@
$(CM_OUT)/out.dis: $(CM_OUT)/out.elf
	$(OBJDUMP) -d -x $< > $@

# The golden CPU's simulator (the standard one is $(BUILD_DIR)/sim/top), in the configuration
CM_GOLDEN_DIR = $(BUILD_DIR)/coremark-model/golden
-include $(CM_GOLDEN_DIR)/top__ver.d
$(CM_GOLDEN_DIR)/top.mk: $(REF_SO_DEPS)
	@ mkdir -p $(@D)
	$(VERILATOR) $(VERILATOR_FLAGS) +define+USE_REF_CPU --trace-fst --trace-structs --timing --assert --main --exe --prefix top -Mdir $(@D) --top-module top sim/top.sv
$(CM_GOLDEN_DIR)/top: $(CM_GOLDEN_DIR)/top.mk
	$(MAKE) -C $(@D) -f top.mk
CM_SIM = $(if $(filter ref,$(CM_CPU)),$(abspath $(CM_GOLDEN_DIR))/top,$(BUILD_ABS)/$(SIM_DIR)/top)

# The caches' counts (CACHE_STATS) are wanted whenever there is a cache
CM_SIM_ARGS = $(if $(SIM_ICACHE),+cache_stats)

.PHONY: coremark
coremark: $(CM_OUT)/init.mem $(CM_OUT)/out.dis $(if $(filter ref,$(CM_CPU)),$(CM_GOLDEN_DIR)/top,$(BUILD_DIR)/$(SIM_DIR)/top)
	@ echo "coremark: $(CM_TAG)$(if $(SIM_CFG_NAME), [configuration $(SIM_CFG_NAME): $(SIM_CFG_TEXT)]), cycle limit $(CM_TIMEOUT)"
	@ cd $(CM_OUT) && { $(CM_SIM) +nodump +timeout=$(CM_TIMEOUT) $(CM_SIM_ARGS) $(SIM_ARGS) > run.log 2>&1 \
	                    || echo "SIMULATOR EXIT STATUS $$?" >> run.log; }
	@ python3 $(CM_DIR)/coremark.py $(CM_OUT) --label '$(CM_TAG)$(if $(SIM_CFG_NAME), cfg=$(SIM_CFG_NAME))' \
	      --iterations $(CM_ITERATIONS) --run $(CM_RUN) --cpu $(if $(filter ref,$(CM_CPU)),golden,dut) \
	      --size-tool $(CM_SIZE) \
	      $(if $(HPM_PRESET),--preset $(HPM_PRESET))
