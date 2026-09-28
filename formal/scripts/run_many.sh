#!/bin/bash
# run_many.sh <work_dir> <sbyfile> <class> <parallel> <timeout_s> task...
#   bounded-parallel runner around run_task.sh; prints one line per task (in completion order)
HERE="$(cd "$(dirname "$0")" && pwd)"
W="$1"; sby="$2"; cls="$3"; par="$4"; to="$5"; shift 5
printf "%s\n" "$@" | xargs -P "$par" -I{} bash "$HERE/run_task.sh" "$W" "$sby" {} "$to" "$cls"
