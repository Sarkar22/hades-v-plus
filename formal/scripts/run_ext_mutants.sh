#!/bin/bash
# run_ext_mutants.sh <work_dir> <parallel> <timeout_s>
#   Formal mutation campaign of the EXT unit: every mutant of mutants/ext_mutants.txt
#   (one textual change of the sv2v model of the real RTL; created by
#   scripts/ext_mutants.py, which run.sh has already run) against the 46 required
#   property tasks of ext.sby (res_*_yn and nostall_yn). A mutant is REJECTED if any
#   of them does not PASS, SURVIVED otherwise. The summary also names the failing
#   tasks, which shows how precisely the properties locate each fault.
#   Summary: <work_dir>/runs/ext_mutants_summary.txt (names prefixed ext_).
HERE="$(cd "$(dirname "$0")" && pwd)"
W="$1"; PAR="$2"; TO="$3"
[ -s "$W/runs/ext_mutants.list" ] || python3 "$HERE/ext_mutants.py" "$W" > "$W/runs/ext_mutants.list" || exit 1
MUTS=$(awk '{print $1}' "$W/runs/ext_mutants.list")
TASKS=$(sed -n '/^\[tasks\]/,/^$/p' "$W/sby/ext.sby" | grep -v '^\[' | awk 'NF{print $1}' | grep '_yn$')
for m in $MUTS; do
    for t in $TASKS; do echo "mut_ext_${m}_ext.sby $t"; done
done | xargs -P "$PAR" -L1 bash -c 'bash "$0/run_task.sh" "$1" "$3" "$4" "$2" MUT > /dev/null' "$HERE" "$W" "$TO"
# (bash -c gets $0=HERE $1=W $2=TO, and xargs -L1 appends "<sby> <task>" as $3 $4)
{
    echo "EXT mutant results (source: runs/times.txt; non-PASS tasks listed)"
    for m in $MUTS; do
        lines=$(grep "^mut_ext_${m}_ext_" "$W/runs/times.txt" | grep "class=MUT")
        n=$(echo "$lines" | grep -c .)
        bad=$(echo "$lines" | grep -v " PASS " | awk '{print $1":"$2}' | sed "s/^mut_ext_${m}_ext_//" | tr '\n' ' ')
        printf "%-20s %-9s (%2d tasks) %s\n" "ext_$m" "$([ -n "$bad" ] && echo REJECTED || echo SURVIVED)" "$n" "${bad:+non-PASS: $bad}"
    done
} > "$W/runs/ext_mutants_summary.txt"
sed 's/^/    /' "$W/runs/ext_mutants_summary.txt"
