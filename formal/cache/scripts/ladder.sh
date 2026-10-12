#!/bin/bash
# SPDX-License-Identifier: MIT
# ladder.sh <work_dir> <property> <config> <step_limit_s> <sim_cycles> [<depth>]
#   The fallback ladder of one property in one configuration (formal/cache/README.md):
#     1. the stated depth (tiny 40, second 30) with each engine in turn: smtbmc with bitwuzla,
#        then Yices, then z3;
#     2. the property's minimum depth, with each engine in turn;
#     3. the decomposed harness (the I-cache alone, the arbiter alone; sby/split.sby): every share
#        of the property at the minimum depth, with each engine in turn;
#     4. the narrower memory (0 or 1 wait cycles) at the minimum depth, with each engine in turn;
#     5. no proof: a random simulation of the harness with the property's checks (scripts/sim.sh).
#   Each step has <step_limit_s> seconds, a third for each engine. A counterexample ends the ladder
#   with FAIL, except in step 3, whose harness allows more than the system does (its
#   counterexample is kept and the ladder goes on). <depth>, if given, replaces the stated depth.
#   Appends one line to <work_dir>/runs/ladder.txt:
#     <property>_<config> <STATUS> step=<n> depth=<d> engine=<e> harness=<h> wall=<s>s [<run>]
#   STATUS: PASS, FAIL, SIM (checked by simulation only) or NONE (no step succeeded).
HERE="$(cd "$(dirname "$0")" && pwd)"
W="$1"; P="$2"; C="$3"; LIMIT="$4"; SIMCYC="$5"; DOVR="${6:-}"
START=$(date +%s)
TO=$(( LIMIT / 3 ))

case "$C" in tiny) STATED=40;; second) STATED=30;; *) echo "ladder.sh: unknown configuration $C"; exit 2;; esac
case "$P" in
    fetch_data|line_data|store_fetch) MIN=35;;
    reset_state) MIN=18;;
    *) MIN=20;;
esac
[ -n "$DOVR" ] && STATED="$DOVR"
[ "$MIN" -gt "$STATED" ] && MIN="$STATED"
# the base sby file and task of the full harness, and the shares of the decomposed harness
if [ "$P" = data_indep ]; then BASE=pair; else BASE=cache; fi
TASK="${P}_${C}"
SHARES=$(sed -n '/^\[tasks\]/,/^$/p' "$W/sby/split.sby" | awk -v t="_${P}_${C}" 'NF && $1 ~ t"$" {print $1}' |
         grep -E "^(icache|arbiter)_${P}_${C}$")

engine_line() {
    case "$1" in
        bw) echo "smtbmc bitwuzla";;
        yi) echo "smtbmc yices";;
        z3) echo "smtbmc z3";;
    esac
}
# derive <base> <depth> <engine> <narrow 0|1>: prints the name of a copy of sby/<base>.sby with
# that depth, engine and memory (written once, atomically)
derive() {
    local name="${1}__d${2}_${3}"
    [ "$4" = 1 ] && name="${name}_narrow"
    if [ ! -f "$W/sby/$name.sby" ]; then
        local tmp="$W/sby/.$name.$$"
        sed -e "s/^\(tiny\|tiny_cpu\|second\|second_cpu\): depth [0-9]*$/\1: depth $2/" \
            -e "s/^depth [0-9]*$/depth $2/" \
            -e "s/^smtbmc bitwuzla$/$(engine_line "$3")/" "$W/sby/$1.sby" > "$tmp"
        if [ "$4" = 1 ]; then
            sed -i -e 's/\b\(cache\|pair\)_\(tiny\|second\)\(_cpu\)\{0,1\}\.v/\1_\2_narrow\3.v/g' "$tmp"
        fi
        mv -f "$tmp" "$W/sby/$name.sby"
    fi
    echo "$name"
}
# attempt <sby name> <task>: one SBY run; prints its status
attempt() {
    bash "$HERE/../../scripts/run_task.sh" "$W" "$1.sby" "$2" "$TO" STEP > /dev/null
    grep "^${1}_${2} " "$W/runs/times.txt" | tail -1 | awk '{print $2}'
}
finish() {   # finish <status> <step> <depth> <engine> <harness> [<run>]
    printf "%-26s %-5s step=%s depth=%s engine=%s harness=%s wall=%ss %s\n" "$TASK" "$1" "$2" "$3" "$4" "$5" \
        "$(( $(date +%s) - START ))" "${6:-}" >> "$W/runs/ladder.txt"
    exit 0
}

# steps 1 and 2: the full harness at the stated, then at the minimum depth
for step in 1 2; do
    if [ "$step" = 1 ]; then d=$STATED; else d=$MIN; [ "$MIN" -ge "$STATED" ] && continue; fi
    for e in bw yi z3; do
        s=$(derive "$BASE" "$d" "$e" 0)
        st=$(attempt "$s" "$TASK")
        case "$st" in
            PASS) finish PASS "$step" "$d" "$e" full;;
            FAIL) finish FAIL "$step" "$d" "$e" full "runs/${s}_${TASK}";;
        esac
    done
done
# step 3: the decomposed harness (a counterexample there does not end the ladder)
if [ -n "$SHARES" ]; then
    ok=1; used=""
    for sh in $SHARES; do
        got=""
        for e in bw yi z3; do
            s=$(derive split "$MIN" "$e" 0)
            st=$(attempt "$s" "$sh")
            [ "$st" = PASS ] && { got=$e; break; }
            [ "$st" = FAIL ] && break
        done
        [ -z "$got" ] && { ok=0; break; }
        used="$used ${sh%%_*}:$got"
    done
    [ "$ok" = 1 ] && finish PASS 3 "$MIN" "$(echo $used | tr ' ' ',')" split
fi
# step 4: the narrower memory at the minimum depth
for e in bw yi z3; do
    s=$(derive "$BASE" "$MIN" "$e" 1)
    st=$(attempt "$s" "$TASK")
    case "$st" in
        PASS) finish PASS 4 "$MIN" "$e" narrow;;
        FAIL) finish FAIL 4 "$MIN" "$e" narrow "runs/${s}_${TASK}";;
    esac
done
# step 5: no proof; a random simulation of the harness with the property's checks
r=$(bash "$HERE/sim.sh" "$W" "$P" "$C" "$SIMCYC" 2>&1 | tail -1)
case "$r" in
    "SIM PASS"*) finish SIM 5 - - sim "${r#SIM PASS }";;
    *)           finish FAIL 5 - - sim "$r";;
esac
