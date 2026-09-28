#!/bin/bash
# run_task.sh <work_dir> <sbyfile> <task> <timeout_s> <class>
#   Runs one SBY task in <work_dir>/runs/<sby>_<task>/ (log <sby>_<task>.log) and
#   appends one line to <work_dir>/runs/times.txt:
#       <sby>_<task>  <STATUS>  rc=<rc>  wall=<s>s  class=<REQ|CTL|AUX|MUT>  <date>
#   STATUS is SBY's DONE status (PASS / FAIL / UNKNOWN / ERROR) or TIMEOUT(<t>s).
#   Classes: REQ must PASS; CTL (negative control) must FAIL; AUX is reported only
#   (second-solver corroboration); MUT belongs to the mutation campaign.
W="$1"; sby="$2"; t="$3"; to="$4"; cls="$5"; base=$(basename "$sby" .sby)
mkdir -p "$W/runs"; cd "$W/runs" || exit 1
rm -rf "${base}_$t"
s=$(date +%s.%N)
timeout -k 10 "$to" nice -n 10 $SBY -f -d "${base}_$t" "$W/sby/$sby" "$t" > "${base}_$t.log" 2>&1; rc=$?
e=$(awk -v a="$s" -v b="$(date +%s.%N)" 'BEGIN{printf "%.1f", b-a}')
st=$(grep -ao 'DONE ([A-Z]*' "${base}_$t.log" | tail -1 | sed 's/DONE (//')
[ -z "$st" ] && { [ $rc = 124 ] || [ $rc = 137 ]; } && st="TIMEOUT(${to}s)"
[ -z "$st" ] && st="ERROR"
printf "%-34s %-13s rc=%-4s wall=%7ss class=%s  %s\n" "${base}_$t" "$st" "$rc" "$e" "$cls" "$(date '+%F %T')" >> "$W/runs/times.txt"
printf "%-34s %-13s %8ss  [%s]\n" "${base}_$t" "$st" "$e" "$cls"
