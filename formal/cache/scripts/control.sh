#!/bin/bash
# SPDX-License-Identifier: MIT
# control.sh <work_dir> <timeout_s> <mutant> <property> <config> <step> <depth> <engine> <harness>
#   One negative control: the property, in the configuration, step, depth, engine and harness at
#   which run.sh accepted it, on the model built from the mutated sources in
#   <work_dir>/mut/<mutant>/gen. The control is shown when the check FAILS. Appends one line to
#   <work_dir>/runs/controls.txt:  <mutant> <property>_<config> <STATUS> wall=<s>s <run>
#   (STATUS is the check's: FAIL is the required outcome).
HERE="$(cd "$(dirname "$0")" && pwd)"
W="$1"; TO="$2"; M="$3"; P="$4"; C="$5"; STEP="$6"; D="$7"; E="$8"; H="$9"
START=$(date +%s)
MD="$W/mut/$M"
TASK="${P}_${C}"
case "$H" in ic|eq) TASK="$P";; esac
source "$HERE/props.sh"

engine_line() {
    case "$1" in
        bw) echo "smtbmc bitwuzla";;
        yi) echo "smtbmc yices";;
        z3) echo "smtbmc z3";;
    esac
}
# mutsby <base> <depth|-> <engine> <narrow 0|1>: a copy of sby/<base>.sby for this mutant
mutsby() {
    local name="${1}__${2}_${3}"
    [ "$4" = 1 ] && name="${name}_narrow"
    name="${name}__${M//-/_}"
    # written to a temporary file and renamed, so that controls of one mutant running at the same
    # time never read a half-written file (they write the same content)
    local tmp="$W/sby/.$name.$$"
    sed -e "s/^\([a-z_]*\): depth [0-9]*$/\1: depth $2/" \
        -e "s/^smtbmc bitwuzla$/$(engine_line "$3")/" \
        -e "s#^\.\./gen/#../mut/$M/gen/#" "$W/sby/$1.sby" > "$tmp"
    [ "$2" = - ] && sed -i -e '/: depth -$/d' "$tmp"
    if [ "$4" = 1 ]; then
        sed -i -e "$NARROW_SED" "$tmp"
    fi
    # the mutant's directory holds only the models this control needs: list only those
    local f
    for f in $(sed -n "s#^\.\./mut/$M/gen/##p" "$tmp"); do
        [ -f "$MD/gen/$f" ] || sed -i -e "\#^\.\./mut/$M/gen/$f\$#d" "$tmp"
    done
    mv -f "$tmp" "$W/sby/$name.sby"
    echo "$name"
}
run() {   # run <sby name> <task>: prints the status
    bash "$HERE/../../scripts/run_task.sh" "$W" "$1.sby" "$2" "$TO" CTL > /dev/null
    grep "^${1}_${2} " "$W/runs/times.txt" | tail -1 | awk '{print $2}'
}
record() {   # record <status> [<run directory, relative to the work directory>]
    local why=""
    # the assertion that failed (file:line of the property), from the run's engine log
    if [ "$1" = FAIL ] && [ -n "${2:-}" ] && [ -d "$W/${2%% *}" ]; then
        why=$(grep -ah -m1 -o 'Assert failed in [^ ]*: [^ ]*' "$W/${2%% *}"/logfile.txt 2>/dev/null |
              sed 's/^Assert failed in [^ ]*: //; s/ *$//')
    fi
    printf "%-30s %-26s %-13s wall=%ss %s%s\n" "$M" "$TASK" "$1" "$(( $(date +%s) - START ))" "${2:-}" \
        "${why:+ (assertion $why)}" >> "$W/runs/controls.txt"
    exit 0
}

if [ ! -f "$MD/gen/.done" ]; then
    record ERROR "$(cat "$MD/gen.log" 2>/dev/null | tail -1)"
fi
case "$H" in
    full|narrow)
        base=$(prop_sby "$P")
        s=$(mutsby "$base" "$D" "$E" "$([ "$H" = narrow ] && echo 1 || echo 0)")
        record "$(run "$s" "$TASK")" "runs/${s}_${TASK}";;
    split)
        st=PASS
        for pair in ${E//,/ }; do
            share="${pair%%:*}_${TASK}"; eng="${pair##*:}"
            s=$(mutsby "$(prop_split "$P")" "$D" "$eng" 0)
            r=$(run "$s" "$share")
            [ "$r" != PASS ] && st="$r"
            [ "$r" = FAIL ] && break
        done
        record "$st" "runs/${s}_${share}";;
    ic)
        s=$(mutsby interconnect - "$E" 0)
        record "$(run "$s" "$TASK")" "runs/${s}_${TASK}";;
    eq)
        s=$(mutsby arbiter_equiv - "$E" 0)
        record "$(run "$s" "$TASK")" "runs/${s}_${TASK}";;
    sim)
        mkdir -p "$MD/sim"; rm -rf "$MD/props"; cp -r "$W/props" "$MD/props"
        r=$(bash "$HERE/sim.sh" "$MD" "$P" "$C" "$D" 2>&1 | tail -1)
        case "$r" in "SIM PASS"*) record PASS "$r";; *) record FAIL "$r";; esac;;
    *)
        record ERROR "unknown harness $H";;
esac
