#!/bin/bash
# sv2v_fidelity.sh <repo_root> <work_dir> <out_dir> [bench...]
#   The proofs are about the sv2v translation of rtl/execute_stage.sv. This check
#   runs the repository's own Verilator benches twice -- on the SystemVerilog
#   execute_stage and with rtl/execute_stage.sv replaced by the sv2v output
#   (<work_dir>/gen/execute_stage_sv2v.v) -- each in a copy of the repository under
#   <out_dir>, and compares the simulation output line by line (only Verilator's
#   wall-time/footer lines are dropped). Prints one line per bench and exits 1 on
#   any difference. Default benches: test_m_execute test_execute_compare
#   test_execute_bpred_nextpc test_ext_execute (all exercise execute_stage alone).
set -u
R="$(cd "$1" && pwd)"; W="$(cd "$2" && pwd)"; O="$3"; shift 3
BENCHES=${*:-"test_m_execute test_execute_compare test_execute_bpred_nextpc test_ext_execute"}
mkdir -p "$O"; O="$(cd "$O" && pwd)"
# never inherit the calling make's variables (e.g. BUILD_DIR=...) or a relocated build dir
unset MAKEFLAGS MFLAGS MAKELEVEL HADES_BUILD_DIR BUILD_DIR
for v in sv sv2v; do
    rm -rf "$O/tree_$v"; mkdir -p "$O/tree_$v"
    ( cd "$R" && tar cf - --exclude=./build --exclude=./.git --exclude=./PATCH_SUMMARY.diff . ) | ( cd "$O/tree_$v" && tar xf - )
done
cp "$W/gen/execute_stage_sv2v.v" "$O/tree_sv2v/rtl/execute_stage.sv"
one() {   # one <variant> <bench>
    local t="$O/tree_$1" b="$2"
    ( cd "$t" && nice make "build/test/sv/$b/top" > "$O/build_${1}_$b.log" 2>&1 ) \
        || { echo "BUILD-FAILED" > "$O/sim_${1}_$b.log"; return; }
    ( cd "$t/build/test/sv/$b" && timeout 1800 nice ./top > "$O/sim_${1}_$b.raw" 2>&1 )
    grep -av -e '^- Verilator:' -e '^- S i m u l a t i o n' "$O/sim_${1}_$b.raw" > "$O/sim_${1}_$b.log"
}
rc=0
for b in $BENCHES; do
    one sv "$b" & one sv2v "$b" & wait
    last=$(grep -aE 'Checks:|Tests:|checks passed|CHECKS FAILED|PASSED' "$O/sim_sv_$b.log" | tail -1 | sed 's/\x1b\[[0-9;]*m//g' | tr -s ' ')
    n=$(wc -l < "$O/sim_sv_$b.log")
    if grep -q BUILD-FAILED "$O/sim_sv_$b.log" "$O/sim_sv2v_$b.log"; then
        echo "  $b: BUILD FAILED (see $O/build_*_$b.log)"; rc=1
    elif cmp -s "$O/sim_sv_$b.log" "$O/sim_sv2v_$b.log"; then
        echo "  $b: IDENTICAL output ($n lines) for SystemVerilog and sv2v model; last result line:${last}"
    else
        echo "  $b: DIFFERENT output (diff $O/sim_sv_$b.log $O/sim_sv2v_$b.log)"; rc=1
    fi
done
exit $rc
