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
[ "${P#ic_}" != "$P" ] && TASK="$P"

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
    sed -e "s/^\(tiny\|tiny_cpu\|second\|second_cpu\): depth [0-9]*$/\1: depth $2/" \
        -e "s/^smtbmc bitwuzla$/$(engine_line "$3")/" \
        -e "s#^\.\./gen/#../mut/$M/gen/#" "$W/sby/$1.sby" > "$W/sby/$name.sby"
    [ "$2" = - ] && sed -i -e '/: depth -$/d' "$W/sby/$name.sby"
    if [ "$4" = 1 ]; then
        sed -i -e 's/\b\(cache\|pair\)_\(tiny\|second\)\(_cpu\)\{0,1\}\.v/\1_\2_narrow\3.v/g' "$W/sby/$name.sby"
    fi
    # the mutant's directory holds only the models this control needs: list only those
    local f
    for f in $(sed -n "s#^\.\./mut/$M/gen/##p" "$W/sby/$name.sby"); do
        [ -f "$MD/gen/$f" ] || sed -i -e "\#^\.\./mut/$M/gen/$f\$#d" "$W/sby/$name.sby"
    done
    echo "$name"
}
run() {   # run <sby name> <task>: prints the status
    bash "$HERE/../../scripts/run_task.sh" "$W" "$1.sby" "$2" "$TO" CTL > /dev/null
    grep "^${1}_${2} " "$W/runs/times.txt" | tail -1 | awk '{print $2}'
}
record() {
    printf "%-30s %-26s %-13s wall=%ss %s\n" "$M" "$TASK" "$1" "$(( $(date +%s) - START ))" "${2:-}" \
        >> "$W/runs/controls.txt"
    exit 0
}

if [ ! -f "$MD/gen/.done" ]; then
    record ERROR "$(cat "$MD/gen.log" 2>/dev/null | tail -1)"
fi
case "$H" in
    full|narrow)
        if [ "$P" = data_indep ]; then base=pair; else base=cache; fi
        s=$(mutsby "$base" "$D" "$E" "$([ "$H" = narrow ] && echo 1 || echo 0)")
        record "$(run "$s" "$TASK")" "runs/${s}_${TASK}";;
    split)
        st=PASS
        for pair in ${E//,/ }; do
            share="${pair%%:*}_${TASK}"; eng="${pair##*:}"
            s=$(mutsby split "$D" "$eng" 0)
            r=$(run "$s" "$share")
            [ "$r" != PASS ] && st="$r"
            [ "$r" = FAIL ] && break
        done
        record "$st" "runs/${s}_${share}";;
    ic)
        s=$(mutsby interconnect - "$E" 0)
        record "$(run "$s" "$TASK")" "runs/${s}_${TASK}";;
    sim)
        mkdir -p "$MD/sim"; rm -rf "$MD/props"; cp -r "$W/props" "$MD/props"
        r=$(bash "$HERE/sim.sh" "$MD" "$P" "$C" "$D" 2>&1 | tail -1)
        case "$r" in "SIM PASS"*) record PASS "$r";; *) record FAIL "$r";; esac;;
    *)
        record ERROR "unknown harness $H";;
esac
