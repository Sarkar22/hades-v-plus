#!/bin/bash
# run_mutants.sh <work_dir> <parallel> <timeout_s>
#   Formal mutation campaign: every mutant of mutants/mutants.txt (one textual change
#   of the sv2v model of the real RTL) against the proof chain:
#     div.sby     ctrl_bw divf1_bwn fdiv_yn mulreg_bw
#     fmul_ops    the 12 *_yn tasks
#     iface       the 16 a1_*_yn / a3a_*_yn tasks
#   A mutant is REJECTED if any of these does not PASS (FAIL = concrete counter-
#   example; UNKNOWN = the induction no longer closes; TIMEOUT). A mutant on which
#   every proof still passes is SURVIVED: it must then be an equivalent mutant, or
#   the properties are too weak. Summary: <work_dir>/runs/mutants_summary.txt.
HERE="$(cd "$(dirname "$0")" && pwd)"
W="$1"; PAR="$2"; TO="$3"
python3 "$HERE/mutate.py" "$W" | sed 's/^/    /' || exit 1
MUTS=$(awk -F'|' '!/^#/ && NF>1 {print $1}' "$W/mutants/mutants.txt")
fm=$(sed -n '/^\[tasks\]/,/^$/p' "$W/sby/fmul_ops.sby" | grep -v '^\[' | awk 'NF{print $1}' | grep '_yn$')
fi=$(sed -n '/^\[tasks\]/,/^$/p' "$W/sby/iface.sby"    | grep -v '^\[' | awk 'NF{print $1}' | grep '_yn$')
for m in $MUTS; do
    for t in ctrl_bw divf1_bwn fdiv_yn mulreg_bw; do echo "mut_${m}_div.sby $t"; done
    for t in $fm; do echo "mut_${m}_fmul_ops.sby $t"; done
    for t in $fi; do echo "mut_${m}_iface.sby $t"; done
done | xargs -P "$PAR" -L1 bash -c 'bash "$0/run_task.sh" "$1" "$3" "$4" "$2" MUT > /dev/null' "$HERE" "$W" "$TO"
# (bash -c gets $0=HERE $1=W $2=TO, and xargs -L1 appends "<sby> <task>" as $3 $4)
{
    echo "mutant results (source: runs/times.txt; non-PASS tasks listed)"
    for m in $MUTS; do
        lines=$(grep "^mut_${m}_" "$W/runs/times.txt")
        n=$(echo "$lines" | grep -c .)
        bad=$(echo "$lines" | grep -v " PASS " | awk '{print $1":"$2}' | sed "s/^mut_${m}_//" | tr '\n' ' ')
        printf "%-20s %-9s (%2d tasks) %s\n" "$m" "$([ -n "$bad" ] && echo REJECTED || echo SURVIVED)" "$n" "${bad:+non-PASS: $bad}"
    done
} > "$W/runs/mutants_summary.txt"
sed 's/^/    /' "$W/runs/mutants_summary.txt"
