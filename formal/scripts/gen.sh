#!/bin/bash
# gen.sh <repo_root> <work_dir>
# Regenerates the formal model of the REAL rtl/execute_stage.sv of <repo_root>:
#   1. sv2v converts the SystemVerilog packages (defines/*.sv) + rtl/execute_stage.sv
#      to Verilog-2005 (Yosys cannot parse the original: named assignment patterns,
#      op::t inside another package) -> <work_dir>/gen/execute_stage_sv2v.v
#   2. exactly one line  `include "div_props.vh"  is inserted immediately before the
#      final `endmodule`, so the property file can observe internal signals (Yosys has
#      no bind / hierarchical references) -> <work_dir>/gen/execute_stage_formal.v.
#      The script checks that the diff against the sv2v output is exactly that line.
set -euo pipefail
R="$1"; W="$2"
command -v sv2v >/dev/null || { echo "sv2v not found"; exit 1; }
mkdir -p "$W/gen"
sv2v "$R/defines/op.sv" "$R/defines/csr.sv" "$R/defines/pipeline_status.sv" \
     "$R/defines/forwarding.sv" "$R/defines/bpredict.sv" "$R/defines/constants.sv" \
     "$R/defines/instruction.sv" "$R/defines/clk_params.sv" "$R/rtl/execute_stage.sv" \
     > "$W/gen/execute_stage_sv2v.v"
n_mod=$(grep -c '^module ' "$W/gen/execute_stage_sv2v.v")
[ "$n_mod" = 1 ] || { echo "expected exactly one module in the sv2v output, got $n_mod"; exit 1; }
awk '{ lines[NR]=$0 } END { last=0; for(i=1;i<=NR;i++) if (lines[i] ~ /^endmodule/) last=i;
      for(i=1;i<=NR;i++){ if(i==last) print "`include \"div_props.vh\""; print lines[i] } }' \
    "$W/gen/execute_stage_sv2v.v" > "$W/gen/execute_stage_formal.v"
d=$(diff "$W/gen/execute_stage_sv2v.v" "$W/gen/execute_stage_formal.v" | grep '^[<>]' || true)
[ "$d" = '> `include "div_props.vh"' ] || { echo "unexpected diff: $d"; exit 1; }
( cd "$R" && sha256sum rtl/execute_stage.sv ) > "$W/gen/SHA256SUMS"
( cd "$W" && sha256sum gen/execute_stage_sv2v.v ) >> "$W/gen/SHA256SUMS"
echo "model of $(sed -n 1p "$W/gen/SHA256SUMS" | awk '{print $2" (sha256 "substr($1,1,16)"...)"}') regenerated; only change: 1 inserted include line"
