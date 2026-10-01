# ---------------------------------------------------------------------------------------------
# Benchmarks and measurement programs (included by the top-level Makefile). Guide:
# test/bench/README.md; recorded results: results/.
#
#   make bench-zba [OPT=-O2|-Os|-O0]  Zba: zba_bench.c and zba_arr.c built for rv32i and for
#                                     rv32i_zba, their output must be equal; cycles, image
#                                     size and Zba instruction counts compared; zba_diff.c,
#                                     built for rv32i only, checks the Zba results
#   make bench-mcost                  cycles of each M instruction in the assembled core
#   make bench-fencei-window          the instructions that still run stale after a store
#                                     patches them, without FENCE.I
#   make bench                        all three
#
# The programs are built into $(BUILD_DIR)/test/bench/ (the objects of the assembly and C
# tests are not touched) and run on $(BUILD_DIR)/sim/top, the simulator of the assembly and
# C tests. They run again on every invocation; test/bench/bench.py then checks the results
# and prints a summary that ends in one line, "BENCH <NAME>: PASS" or "BENCH <NAME>: FAIL".
# The target fails unless it says PASS.
# ---------------------------------------------------------------------------------------------

BENCH_DIR     = $(TEST_DIR)/bench
BENCH_OUT     = $(BUILD_DIR)/$(BENCH_DIR)
BENCH_LD      = $(STD_LIB_DIR)/hades-v.ld
BENCH_STD_SRC = $(sort $(wildcard $(STD_LIB_DIR)/src/*.c))
BENCH_STD_H   = $(wildcard $(STD_LIB_DIR)/include/*.h)
BENCH_PY      = python3 $(BENCH_DIR)/bench.py
# Cycle limit of one run. The simulator's own default, 100000, is too short for mcost.c and,
# at -O0, for zba_diff; a program that finishes is not affected by the limit.
BENCH_TIMEOUT = 5000000

# Run the program whose init.mem is in directory $(1), output to $(1)/run.log
bench_run = cd $(1) && { $(BUILD_ABS)/$(SIM_DIR)/top +nodump +timeout=$(BENCH_TIMEOUT) > run.log 2>&1 \
                         || echo "SIMULATOR EXIT STATUS $$?" >> run.log; }

.PHONY: bench bench-zba bench-mcost bench-fencei-window bench-rerun
bench: bench-zba bench-mcost bench-fencei-window

# Every run log depends on this target, so the programs are run on every invocation.
bench-rerun:

# Assembly programs, built with the commands of the assembly tests: $(1) = path below
# test/bench without .s
define bench_asm_rules
$(BENCH_OUT)/$(1)/init.elf: $(BENCH_DIR)/$(1).s $(BENCH_LD)
	@ mkdir -p $$(@D)
	$$(CC) -nostdlib -nostartfiles -T $(BENCH_LD) -o $$@ $$<
	$$(OBJDUMP) -d -r -t -S $$@ > $$(@D)/init.dis
	$$(OBJCOPY) -O binary $$@ $$(@D)/init.bin
	$$(OBJCOPY) -I binary -O verilog --verilog-data-width 4 --reverse-bytes=4 $$(@D)/init.bin $$(@D)/init.mem
$(BENCH_OUT)/$(1)/run.log: $(BENCH_OUT)/$(1)/init.elf $(BUILD_DIR)/$(SIM_DIR)/top bench-rerun
	$$(call bench_run,$$(@D))
endef

# C programs, built with the commands of the C tests plus the program's own flags, and with
# their own copies of the std objects: $(1) = output directory, $(2) = source, $(3) = flags
# (-O level and -march; also given to the std objects and the link), $(4) = flags for the
# program only
bench_std_objs = $(patsubst $(STD_LIB_DIR)/src/%.c,$(1)/std/%.o,$(BENCH_STD_SRC))
define bench_c_rules
$(1)/std/%.o: $(STD_LIB_DIR)/src/%.c $(BENCH_STD_H)
	@ mkdir -p $$(@D)
	$$(CC) -fdata-sections -ffunction-sections $(3) -I $(STD_LIB_DIR)/include -c -o $$@ $$<
$(1)/out.o: $(2) $(BENCH_STD_H)
	@ mkdir -p $$(@D)
	$$(CC) -fdata-sections -ffunction-sections $(3) $(4) -I $(STD_LIB_DIR)/include -c -o $$@ $$<
$(1)/out.elf: $(1)/out.o $(call bench_std_objs,$(1)) $(BENCH_LD)
	$$(CC) -o $$@ -nostdlib -nostartfiles -T $(BENCH_LD) $(3) $$< $(call bench_std_objs,$(1)) -lgcc -Wl,--no-warn-rwx-segments -Wl,--gc-sections
	$$(OBJCOPY) -O binary $$@ $$(@D)/out.bin
	$$(OBJCOPY) -I binary -O verilog -S --verilog-data-width 4 --reverse-bytes=4 $$(@D)/out.bin $$(@D)/init.mem
	$$(OBJDUMP) -d -x $$@ > $$(@D)/out.dis
$(1)/run.log: $(1)/out.elf $(BUILD_DIR)/$(SIM_DIR)/top bench-rerun
	$$(call bench_run,$$(@D))
endef

# ---- bench-zba: Zba against plain RV32I, see test/bench/README.md ----------------------------
# OPT=<level> on the command line sets the optimisation level (default -O2); every level has
# its own output directory.
ZBA_OPT := -O2
ifneq ($(filter bench bench-zba,$(MAKECMDGOALS)),)
ifeq ($(origin OPT),command line)
ZBA_OPT := $(OPT)
endif
ifneq ($(words $(ZBA_OPT)) $(filter -O0 -O1 -O2 -O3 -Os -Og,$(ZBA_OPT)),1 $(ZBA_OPT))
$(error bench-zba: OPT must be one optimisation level (-O0, -O1, -O2, -O3, -Os or -Og), not '$(ZBA_OPT)')
endif
endif
ZBA_OUT = $(BENCH_OUT)/zba/$(subst -,,$(ZBA_OPT))

# The variants: zba_bench and zba_arr for both instruction sets; zba_diff for rv32i only (it
# issues its Zba instructions as .insn words), once with its defaults and three times with
# 1400 random operand pairs only, from three seeds.
ZBA_VARIANTS = zba_bench-rv32i zba_bench-rv32i_zba zba_arr-rv32i zba_arr-rv32i_zba zba_diff \
               zba_diff-B5297A4D zba_diff-1F123BB5 zba_diff-9E3779B9
$(eval $(call bench_c_rules,$(ZBA_OUT)/zba_bench-rv32i,$(BENCH_DIR)/zba/zba_bench.c,$(ZBA_OPT) -march=rv32i))
$(eval $(call bench_c_rules,$(ZBA_OUT)/zba_bench-rv32i_zba,$(BENCH_DIR)/zba/zba_bench.c,$(ZBA_OPT) -march=rv32i_zba))
$(eval $(call bench_c_rules,$(ZBA_OUT)/zba_arr-rv32i,$(BENCH_DIR)/zba/zba_arr.c,$(ZBA_OPT) -march=rv32i))
$(eval $(call bench_c_rules,$(ZBA_OUT)/zba_arr-rv32i_zba,$(BENCH_DIR)/zba/zba_arr.c,$(ZBA_OPT) -march=rv32i_zba))
$(eval $(call bench_c_rules,$(ZBA_OUT)/zba_diff,$(BENCH_DIR)/zba/zba_diff.c,$(ZBA_OPT) -march=rv32i))
$(foreach s,B5297A4D 1F123BB5 9E3779B9,$(eval $(call bench_c_rules,$(ZBA_OUT)/zba_diff-$(s),$(BENCH_DIR)/zba/zba_diff.c,$(ZBA_OPT) -march=rv32i,-DSKIP_POOL -DN_RANDOM=1400 -DSEED=0x$(s)u)))

bench-zba: $(foreach v,$(ZBA_VARIANTS),$(ZBA_OUT)/$(v)/run.log)
	@ $(BENCH_PY) zba $(ZBA_OUT) $(ZBA_OPT)

# ---- bench-mcost: cycles per M instruction, see test/bench/README.md -------------------------
MCOST_OUT   = $(BENCH_OUT)/mcost
MCOST_LOOPS = loop_empty loop_addi loop_mul loop_div loop_div0
$(foreach p,$(MCOST_LOOPS),$(eval $(call bench_asm_rules,mcost/$(p))))
$(eval $(call bench_c_rules,$(MCOST_OUT)/mcost,$(BENCH_DIR)/mcost/mcost.c,-O2 -march=rv32im))

bench-mcost: $(foreach p,$(MCOST_LOOPS) mcost,$(MCOST_OUT)/$(p)/run.log)
	@ $(BENCH_PY) mcost $(MCOST_OUT)

# ---- bench-fencei-window: instruction-fetch staleness without FENCE.I -------------------------
FENCEI_OUT = $(BENCH_OUT)/fencei-window
$(foreach p,fencei_stale stall_probe,$(eval $(call bench_asm_rules,fencei-window/$(p))))

bench-fencei-window: $(FENCEI_OUT)/fencei_stale/run.log $(FENCEI_OUT)/stall_probe/run.log
	@ $(BENCH_PY) fencei-window $(FENCEI_OUT)
