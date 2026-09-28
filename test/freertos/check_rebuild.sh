#!/bin/sh
# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------------------------------
# check_rebuild.sh -- regression test for the configuration tracking in freertos.mk.
#
# `make test/freertos/<app>` reuses one output directory for every configuration, so a
# changed knob (FRTOS_TICK, FRTOS_MARCH, FRTOS_BPRED, ...) must rebuild the ELF BEFORE it is
# run. freertos.mk used to update its flags file in a recipe, after make had already compared
# timestamps, so the first run after a knob change silently ran the ELF of the PREVIOUS
# configuration (and only the run after that one used the new build).
#
# This script builds and runs the `minimal` program in a scratch output directory, changes
# one knob at a time, and checks from the program's own start-up banner
# ("config: tick=... isa=... opt=... bpred=...") that the very next run used the new build.
# It also checks that re-running an unchanged configuration does not rebuild the ELF.
#
# usage (from the repository root, with the FreeRTOS sources where the Makefile finds them,
# see docs/FREERTOS.md):
#     make freertos-check-rebuild
#     sh test/freertos/check_rebuild.sh [output-dir]
#         (default: $HADES_BUILD_DIR/freertos-rebuild-check, else build/freertos-rebuild-check)
# Exit status 0 and "REBUILD CHECK: PASS" on success.
# ---------------------------------------------------------------------------------------------
set -u

OUT=${1:-${HADES_BUILD_DIR:-build}/freertos-rebuild-check}
MAKE=${MAKE:-make}
rm -rf "$OUT"
mkdir -p "$OUT"
LOGDIR=$(cd "$OUT" && pwd)/logs
mkdir -p "$LOGDIR"
fails=0
step=0

# run <expected banner fragment> <knobs...>: build + run minimal, check banner and result
run() {
    want=$1; shift
    step=$((step + 1))
    log=$LOGDIR/step$step.log
    $MAKE --no-print-directory test/freertos/minimal FRTOS_OUT="$OUT/minimal" "$@" > "$log" 2>&1
    banner=$(grep -a -m1 'config: tick=' "$log" | sed 's/^ *//')
    result=$(grep -a -m1 'FRTOS-RESULT:' "$log")
    status=ok
    case "$banner" in *"$want"*) ;; *) status=FAIL ;; esac
    case "$result" in *"FRTOS-RESULT: PASS"*) ;; *) status=FAIL ;; esac
    printf 'step %d [%s] knobs: %s\n    expect: %s\n    banner: %s\n    result: %s\n' \
        "$step" "$status" "${*:-(defaults)}" "$want" "${banner:-<none>}" "${result:-<none>}"
    [ "$status" = ok ] || { fails=$((fails + 1)); echo "    log: $log"; }
}

elf_id() { cksum < "$OUT/minimal/out.elf" 2>/dev/null; }

run 'tick=10000cyc preempt=1 slice=1 heap_4 isa=rv32i opt=2 ram=32K bpred=0'
run 'tick=5000cyc preempt=1 slice=1 heap_4 isa=rv32i opt=2 ram=32K bpred=0'  FRTOS_TICK=5000

# unchanged configuration: the ELF must be reused, not rebuilt
before=$(elf_id)
run 'tick=5000cyc'                                                          FRTOS_TICK=5000
if [ "$(elf_id)" != "$before" ] || grep -q -- '-c .*hades_hal.c' "$LOGDIR/step$step.log"; then
    echo "    FAIL: an unchanged configuration was rebuilt"; fails=$((fails + 1))
else
    echo "    (unchanged configuration: nothing recompiled, same ELF)"
fi

run 'tick=5000cyc preempt=1 slice=1 heap_4 isa=rv32i opt=2 ram=32K bpred=3'  FRTOS_TICK=5000 FRTOS_BPRED=3
run 'isa=rv32im opt=2'                                                      FRTOS_MARCH=rv32im
run 'isa=rv32im opt=s'                                                      FRTOS_MARCH=rv32im FRTOS_OPT=-Os
run 'tick=10000cyc preempt=0 slice=1 heap_4 isa=rv32i opt=2'                FRTOS_PREEMPT=0
run 'tick=10000cyc preempt=1 slice=1 heap_4 isa=rv32i opt=2 ram=32K bpred=0'

if [ $fails -eq 0 ]; then
    echo "REBUILD CHECK: PASS ($step runs, every run used the configuration it was given)"
    exit 0
fi
echo "REBUILD CHECK: FAIL ($fails of the checks above failed)"
exit 1
