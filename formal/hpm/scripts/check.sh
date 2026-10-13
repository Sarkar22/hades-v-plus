#!/bin/bash
# SPDX-License-Identifier: MIT
# check.sh <work_dir> <step_limit_s> <bmc_depth> <check> <sby> <model> <task> [<gen_dir> <engine> <mode> <depth>]
#   One check of formal/hpm: SBY task <task> of sby/<sby>.sby on the model <gen_dir>/<model>.v
#   (gen_dir relative to <work_dir>, default gen).
#   Without the last four arguments, the ladder (formal/hpm/README.md, section 4): the proof by
#   k-induction (mode prove) with smtbmc and bitwuzla, then Yices, then z3; if no engine gives
#   PASS or FAIL, a bounded check to <bmc_depth> with each engine in turn (status BOUNDED when it
#   passes). Each engine gets a third of <step_limit_s> per step. Appends one line to
#   <work_dir>/runs/proofs.txt:
#     <check> <STATUS> engine=<e> mode=<prove|bmc> depth=<d> wall=<s>s run=<dir>
#   With <engine> <mode> <depth> (a negative control on a mutated model): exactly that run;
#   appends the line to <work_dir>/runs/controls.txt instead.
#   STATUS: PASS, FAIL, BOUNDED, UNKNOWN, TIMEOUT(...) or ERROR.
HERE="$(cd "$(dirname "$0")" && pwd)"
W="$1"; LIMIT="$2"; BMCD="$3"; CHK="$4"; SBYF="$5"; MODEL="$6"; TASK="$7"
GEN="${8:-gen}"; FIXE="${9:-}"; FIXM="${10:-}"; FIXD="${11:-}"
START=$(date +%s)
TO=$(( LIMIT / 3 ))

engine_line() {
    case "$1" in bw) echo "smtbmc bitwuzla";; yi) echo "smtbmc yices";; z3) echo "smtbmc z3";; esac
}
# derive <engine> <mode> <depth|->: a copy of sby/<sby>.sby for this model, engine and mode
derive() {
    local name="${SBYF}__${MODEL}__${GEN//\//_}__$1_$2"
    [ "$3" != - ] && name="${name}$3"
    if [ ! -f "$W/sby/$name.sby" ]; then
        local tmp="$W/sby/.$name.$$"
        sed -e "s#^\.\./gen/[a-z_]*_model\.v\$#../$GEN/$MODEL.v#" \
            -e "s#^\.\./gen/\($MODEL\.v\)\$#../$GEN/\1#" \
            -e "s#^read_verilog -sv -formal [a-z_]*_model\.v\$#read_verilog -sv -formal $MODEL.v#" \
            -e "s/^smtbmc bitwuzla\$/$(engine_line "$1")/" "$W/sby/$SBYF.sby" > "$tmp"
        if [ "$2" = bmc ]; then
            sed -i -e "s/^prove: mode prove\$/prove: mode bmc/" -e "s/^prove: depth [0-9]*\$/prove: depth $3/" "$tmp"
        fi
        mv -f "$tmp" "$W/sby/$name.sby"
    fi
    echo "$name"
}
depth_of() {   # the stated induction depth of the task's sby file
    sed -n 's/^prove: depth \([0-9]*\)$/\1/p' "$W/sby/$SBYF.sby" | head -1
}
attempt() {    # attempt <sby name> <class>: prints the status
    bash "$HERE/../../scripts/run_task.sh" "$W" "$1.sby" "$TASK" "$TO" "$2" > /dev/null
    grep "^${1}_${TASK} " "$W/runs/times.txt" | tail -1 | awk '{print $2}'
}
finish() {     # finish <status> <engine> <mode> <depth> <run> <file>
    printf "%-28s %-9s engine=%s mode=%s depth=%s wall=%ss run=runs/%s\n" "$CHK" "$1" "$2" "$3" "$4" \
        "$(( $(date +%s) - START ))" "$5" >> "$W/runs/$6"
    exit 0
}

if [ ! -f "$W/$GEN/$MODEL.v" ]; then
    printf "%-28s %-9s engine=- mode=- depth=- wall=0s run=- (no model %s)\n" "$CHK" ERROR "$GEN/$MODEL.v" \
        >> "$W/runs/$([ -n "$FIXE" ] && echo controls.txt || echo proofs.txt)"
    exit 0
fi
if [ -n "$FIXE" ]; then
    TO=$(( LIMIT / 3 ))
    s=$(derive "$FIXE" "$FIXM" "$([ "$FIXM" = bmc ] && echo "$FIXD" || echo -)")
    st=$(attempt "$s" CTL)
    finish "$st" "$FIXE" "$FIXM" "$FIXD" "${s}_$TASK" controls.txt
fi
last=""
for e in bw yi z3; do
    s=$(derive "$e" prove -)
    st=$(attempt "$s" STEP)
    case "$st" in
        PASS|FAIL) finish "$st" "$e" prove "$(depth_of)" "${s}_$TASK" proofs.txt;;
    esac
    last="$st"
done
for e in bw yi z3; do
    s=$(derive "$e" bmc "$BMCD")
    st=$(attempt "$s" STEP)
    case "$st" in
        PASS) finish BOUNDED "$e" bmc "$BMCD" "${s}_$TASK" proofs.txt;;
        FAIL) finish FAIL "$e" bmc "$BMCD" "${s}_$TASK" proofs.txt;;
    esac
done
finish "${last:-ERROR}" - prove "$(depth_of)" "-" proofs.txt
