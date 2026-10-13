#!/bin/bash
# SPDX-License-Identifier: MIT
# sim.sh <work_dir> <property> <config> <cycles>
#   The last step of the fallback ladder: a random simulation of the property's harness, the model
#   of the proofs (<work_dir>/gen) compiled by Verilator with FORMAL and FSIM defined (the checks
#   are sampled at the rising edge of clk, the arrays are read by hierarchical reference), driven
#   by a main from scripts/simtb.py that gives every input a random value in every cycle. It runs
#   <cycles> cycles in runs of 100000, each run with its own seed (a new tracked address and a new
#   free initial state). Verilator builds one at a time (a lock in <work_dir>/sim), with 4 jobs.
#   Last line: "SIM PASS <cycles, runs, seed>" or "SIM FAIL <where>".
HERE="$(cd "$(dirname "$0")" && pwd)"
W="$1"; P="$2"; C="$3"; N="$4"
source "$HERE/props.sh"
FH="-DFH_ICACHE -DFH_ARBITER -DFH_FULL"
model=$(model_of "$P" "$C" 0)
case "$P" in
    data_indep)  top=cache_pair_top;  defs="-DCHECK_DATA_INDEP";;
    ddata_indep) top=memsys_pair_top; defs="-DCHECK_DDATA_INDEP";;
    *) if is_id_prop "$P"; then
           top=memsys_top; defs="-DCHECK_$(echo "$P" | tr a-z A-Z) $FH -DFH_DCACHE"
       else
           top=cache_top;  defs="-DCHECK_$(echo "$P" | tr a-z A-Z) $FH"
       fi;;
esac
D="$W/sim/${P}_$C"
rm -rf "$D"; mkdir -p "$D"
python3 "$HERE/simtb.py" "$W/gen/$model.v" "$top" "$D/tb.cpp" || { echo "SIM FAIL (testbench)"; exit 1; }
(
    flock 9
    verilator --cc --exe --build -j 4 -O2 -sv --assert -Wno-fatal -Wno-lint -Wno-style \
        -DFORMAL -DFSIM $defs -I"$W/props" -I"$W/gen" --top-module "$top" --Mdir "$D/obj" \
        "$W/gen/$model.v" "$D/tb.cpp"
) 9> "$W/sim/.lock" > "$D/build.log" 2>&1 || { echo "SIM FAIL (build, $D/build.log)"; exit 1; }
"$D/obj/V$top" "$N" 100000 1 > "$D/run.log" 2>&1
r=$(grep -a "^SIM " "$D/run.log" | tail -1)
if [ -n "$r" ]; then
    echo "$r"
else
    echo "SIM FAIL ($(grep -a -m1 -i 'assert\|error' "$D/run.log" | cut -c1-200); $D/run.log)"
fi
