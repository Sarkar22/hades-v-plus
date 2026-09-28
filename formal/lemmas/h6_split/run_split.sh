#!/bin/bash
# run_split.sh <hints_dir> <lemmas_dir> <out_dir> <solver> [timeout_s] [parallel]
#   Validity of hint H6 by an exhaustive 33-way case split on the bit length of
#   the divisor argument: builds the Yosys SMT2 model of <hints_dir>/hints.vh,
#   flattens it into 33 single-state QF_BV queries (flatten.py) and runs <solver>
#   (z3 | bitwuzla | yices-smt2, found on PATH) on each. Prints one summary line
#   "<solver>: N/33 unsat; non-unsat: ..." and writes <out_dir>/results_<solver>.txt.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HD="$(cd "$1" && pwd)"; LD="$(cd "$2" && pwd)"; OUT="$3"; SOLVER="$4"; TO="${5:-600}"; PAR="${6:-3}"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
# relative paths: the YoWASP (WebAssembly) Yosys cannot open absolute host paths
HDR=$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$HD" "$OUT")
LDR=$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$LD" "$OUT")
sed -e "s#@HINTDIR@#$HDR#" -e "s#@LEMMADIR@#$LDR#" "$HERE/model.ys.in" > "$OUT/model.ys"
( cd "$OUT" && yosys -q -s model.ys ) || { echo "$SOLVER: model generation FAILED"; exit 1; }
python3 "$HERE/flatten.py" "$OUT" > "$OUT/flatten.log" || { echo "$SOLVER: flatten FAILED"; exit 1; }
export SOLVER TO OUT
{ echo zero; seq 0 31 | sed 's/^/k/'; } | xargs -P "$PAR" -I{} bash -c '
  s=$(date +%s.%N)
  r=$(timeout "$TO" "$SOLVER" "$OUT/h6_{}.smt2" 2>&1 | head -1)
  printf "%-5s %-10s %8.2fs\n" {} "${r:-TIMEOUT}" "$(awk -v a="$s" -v b="$(date +%s.%N)" "BEGIN{print b-a}")"' \
  | sort -V > "$OUT/results_$SOLVER.txt"
tot=$(awk '{s+=$3} END{printf "%.2f", s}' "$OUT/results_$SOLVER.txt")
echo "$SOLVER: $(grep -c ' unsat ' "$OUT/results_$SOLVER.txt")/33 unsat, $(grep -c ' sat ' "$OUT/results_$SOLVER.txt") sat; non-unsat: $(grep -v ' unsat ' "$OUT/results_$SOLVER.txt" | awk '{print $1":"$2}' | tr '\n' ' ')(sum of case times ${tot} s)"
