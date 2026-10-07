# ---------------------------------------------------------------------------------------------
# ext.mk -- the check of the Zbb, Zbs, Zicond, Zbkb, Zbkx and Zknh results (included by the
# top-level Makefile).
# Guide: test/ext/README.md.
#
#   make ext-check [JOBS=4]        the RTL (instruction_decoder -> execute_stage) against the
#                                  C reference model test/ext/ref_exh.c on the quick vector set:
#                                  125 digest lines
#   make ext-exhaustive [JOBS=4]   every part, the fifteen unary forms over all 2^32 inputs:
#                                  3,905 digest lines
#
# test/ext/run.py builds the harness (Verilator) into $(BUILD_DIR)/test/ext/harness/ and the
# model into $(BUILD_DIR)/test/ext/, runs both, compares their lines and ends with
# "EXT CHECK: PASS" or "EXT CHECK: FAIL"; the target fails unless it says PASS.
# ---------------------------------------------------------------------------------------------

EXT_JOBS = $(if $(filter command line,$(origin JOBS)),$(JOBS),4)

.PHONY: ext-check ext-exhaustive
ext-check:
	python3 $(TEST_DIR)/ext/run.py --quick --jobs $(EXT_JOBS) --build $(BUILD_ABS)

ext-exhaustive:
	python3 $(TEST_DIR)/ext/run.py --exhaustive --jobs $(EXT_JOBS) --build $(BUILD_ABS)
