#!/bin/sh
# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------------------------------
# run.sh -- run one FreeRTOS program on a HaDes-V+ simulator, stream its UART output to the
# terminal, keep a log, and finish with one verdict line. Called by `make freertos` and
# `make freertos-compare` (test/freertos/freertos.mk); see docs/FREERTOS.md.
#
#   sh run.sh <simulator> <run dir> <timeout cycles> <seed hex> <log name> <label> [<waves>]
#   sh run.sh --compare <dut log> <golden log>
#
# Verdicts (exit status 0 only for PASS):
#   PASS   the program printed "FRTOS-RESULT: PASS", the test-register protocol ended in
#          "All tests passed! (# Errors: 1 = initial test)", and every UART pattern line
#          (HADES_PATTERN_LINE in common/hades_hal.h) arrived intact
#   FAIL   the program reported a failure ("FRTOS-RESULT: FAIL <reason>"), or the protocol or
#          the UART transcript was broken
#   HANG   no result within the cycle limit ("Simulation timeout!")
#   CRASH  the simulator stopped without any result
# Invoked with `sh`, so it needs no execute permission (the repository may be on a disk
# that cannot execute files).
# ---------------------------------------------------------------------------------------------
set -u
ESC=$(printf '\033')
PATTERN='~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz~'
RULE='=============================================================================='

verdict_of() {   # <log> -> "STATUS cycles" from the FREERTOS RESULT line written below
    sed -n 's/^FREERTOS RESULT: \([A-Z]*\) .*cycles=\([0-9]*\).*/\1 \2/p' "$1" 2>/dev/null | tail -n 1
}

if [ "${1:-}" = "--compare" ]; then
    d=$(verdict_of "$2"); g=$(verdict_of "$3")
    ds=${d%% *}; gs=${g%% *}
    echo "$RULE"
    printf 'COMPARE  dut: %-6s (%s cycles)   golden: %-6s (%s cycles)\n' \
        "${ds:-NONE}" "${d#* }" "${gs:-NONE}" "${g#* }"
    if [ "$ds" = PASS ] && [ "$gs" = PASS ]; then
        echo "AGREE: the program passed on both CPUs. (Cycle counts differ legitimately: the golden"
        echo "CPU samples interrupts one cycle later, so the two runs interleave differently.)"
        rc=0
    elif [ "$gs" = PASS ]; then
        echo "DISAGREE: the golden CPU passed and the DUT did not -- a DUT bug, or a program that"
        echo "depends on DUT-only behaviour. Logs: $2 and $3"
        rc=1
    elif [ "$ds" = PASS ]; then
        echo "DISAGREE: the DUT passed and the golden CPU did not. Check the golden log: $3"
        rc=1
    else
        echo "BOTH FAILED: the program or its configuration is at fault, not the DUT. Logs: $2 and $3"
        rc=1
    fi
    echo "$RULE"
    exit $rc
fi

if [ $# -lt 6 ]; then
    echo "usage: sh run.sh <simulator> <run dir> <timeout> <seed> <log name> <label> [<waves>]" >&2
    exit 2
fi
sim=$1; dir=$2; timeout=$3; seed=$4; log=$5; label=$6; waves=${7:-}

if [ ! -x "$sim" ]; then
    echo "run.sh: simulator $sim is missing or not executable" >&2
    exit 2
fi
dump=+nodump
case "$waves" in ''|0) ;; *) dump= ;; esac

cd "$dir" || exit 2
# Line-buffer the simulator's stdout so the UART output appears as it is produced
# (through a pipe, it would otherwise arrive in large blocks).
buf=
command -v stdbuf >/dev/null 2>&1 && buf="stdbuf -oL -eL"

echo "$RULE"
echo "RUN  $label  timeout=$timeout cycles"
echo "     (the first 'Test fail!' line is the program's deliberate 'initial test' marker)"
echo "$RULE"
rm -f "$log" "$log.rc"
{ $buf "$sim" $dump +timeout="$timeout" +switches="$seed" 2>&1; echo $? > "$log.rc"; } | tee "$log"
simrc=$(cat "$log.rc" 2>/dev/null || echo '?')
rm -f "$log.rc"

clean=$(sed "s/${ESC}\[[0-9;]*m//g" "$log")
result=$(printf '%s\n' "$clean" | grep -a 'FRTOS-RESULT:' | tail -n 1)
npat=$(printf '%s\n' "$clean" | grep -a -c '^~')
nbad=$(printf '%s\n' "$clean" | grep -a '^~' | grep -a -v -c -x -F "$PATTERN")
mtime=$(printf '%s\n' "$result" | sed -n 's/.*mtime=\([0-9a-fA-F]\{16\}\).*/\1/p')
if [ -n "$mtime" ]; then
    cycles=$(printf '%d' "0x$mtime" 2>/dev/null || echo 0)
else
    ps=$(printf '%s\n' "$clean" | sed -n 's/^( *\([0-9]*\) ps) Test.*/\1/p' | tail -n 1)
    cycles=$(( ${ps:-0} / 20 ))
fi

if printf '%s\n' "$clean" | grep -a -q 'Simulation timeout!'; then
    status=HANG
    why="no FRTOS-RESULT within $timeout cycles (a hang, or a program that needs a larger TIMEOUT=)"
    cycles=$timeout
elif [ -z "$result" ]; then
    status=CRASH
    last=$(printf '%s\n' "$clean" | grep -a -E '%(Fatal|Error)' | head -n 1)
    [ -n "$last" ] || last=$(printf '%s\n' "$clean" | grep -a -v -E '^[[:space:]]*$' | tail -n 1)
    why="the simulator stopped without a result (exit status $simrc): $last"
else
    case "$result" in
    *"FRTOS-RESULT: PASS"*)
        if ! printf '%s\n' "$clean" | grep -a -q -F 'All tests passed! (# Errors: 1 = initial test)'; then
            status=FAIL; why="PASS printed, but the test-register protocol is broken"
        elif [ "$nbad" -ne 0 ]; then
            status=FAIL; why="UART transcript corrupted in $nbad of $npat pattern lines (a UART store performed twice or lost)"
        else
            status=PASS; why=""
        fi ;;
    *)
        status=FAIL
        why=$(printf '%s\n' "$result" | sed -e 's/.*FRTOS-RESULT: FAIL *//' -e 's/ mtime=[0-9a-fA-F]*$//') ;;
    esac
fi

line="FREERTOS RESULT: $status  $label cycles=$cycles"
echo "$RULE"
echo "$line"
[ -n "$why" ] && echo "  reason: $why"
echo "  UART pattern lines intact: $((npat - nbad))/$npat"
echo "  log: $dir/$log"
[ -n "$dump" ] || echo "  waveform: $dir/sim.fst"
echo "$RULE"
echo "$line" >> "$log"
[ "$status" = PASS ]
