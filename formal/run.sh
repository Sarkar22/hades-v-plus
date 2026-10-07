#!/bin/bash
# =============================================================================
# formal/run.sh -- re-run the formal proofs of rtl/execute_stage.sv from the
# sources in this repository: the M unit (divider and multiplier) and the EXT
# unit (Zbb, Zbs, Zicond, Zbkb, Zbkx, Zknh).
#
#   bash formal/run.sh [--mode default|full|ext] [--out DIR] [--par N]
#   make formal            (= --mode default, output in $(BUILD_DIR)/formal)
#   make formal-full       (= --mode full)
#   make formal-ext        (= --mode ext, output in $(BUILD_DIR)/formal-ext)
#
#   default  M unit: every proof obligation of the chain, the lemma validity
#            checks (H6 by the z3 case split), the non-vacuity covers, the spec
#            checks and the multiplier formulation check; EXT unit: the spec
#            cross-check, the payload-map check, X1/X2 for each of the 45
#            instructions, X3, the covers and 37 negative controls; the sv2v
#            fidelity check (about 1.5 min on an idle 22-thread machine, --par 4)
#   full     additionally H6 by bitwuzla monolithically (about 20-35 min, runs in
#            the background from the start), second-solver runs of FINAL(mul),
#            A1 and the EXT results, the formal mutation campaign of the M unit
#            (19 mutants x 32 proofs) and that of the EXT unit (37 mutants x 46
#            proofs) (about 25-35 min, dominated by the bitwuzla H6 runs)
#   ext      only the EXT unit (the EXT checks of default, and the sv2v fidelity
#            check with the EXT bench only; about 30 s)
#
# The repository is only read: the sources are copied to DIR/work and every
# generated file, SBY run directory and log goes below DIR (default: build/formal
# of this checkout). Tools: see formal/README.md ("Tools") and scripts/env.sh.
# Result: DIR/work/runs/times.txt (one line per check), DIR/SUMMARY.txt, and the
# last line "FORMAL RESULT: PASS" or "FORMAL RESULT: FAIL ..."; exit status 0 only
# for PASS (2 = a tool is missing).
# =============================================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
MODE=default; OUT="$REPO/build/formal"; PAR="${FORMAL_PAR:-4}"
while [ $# -gt 0 ]; do
    case "$1" in
        --mode) MODE="$2"; shift 2;;
        --out)  OUT="$2"; shift 2;;
        --par)  PAR="$2"; shift 2;;
        -h|--help) sed -n '2,33p' "$0"; exit 0;;
        *) echo "unknown argument: $1"; exit 2;;
    esac
done
case "$MODE" in default|full|ext) ;; *) echo "unknown mode '$MODE' (default|full|ext)"; exit 2;; esac
mkdir -p "$OUT" || exit 2
OUT="$(cd "$OUT" && pwd)"
case "$OUT/" in "$HERE/"*) echo "the output directory must not be inside formal/"; exit 2;; esac

source "$HERE/scripts/env.sh" || exit 2
W="$OUT/work"
exec > >(tee "$OUT/run.log") 2>&1
T0=$(date +%s)
echo "formal/run.sh mode=$MODE par=$PAR out=$OUT  ($(date '+%F %T'))"
echo "repository: $REPO"
step() { echo; echo "=== $* ==="; }
record() {  # record <name> <status> <wall_s> <class>
    printf "%-34s %-13s rc=%-4s wall=%7ss class=%s  %s\n" "$1" "$2" "-" "$3" "$4" "$(date '+%F %T')" >> "$W/runs/times.txt"
}
now() { date +%s.%N; }
since() { awk -v a="$1" -v b="$(date +%s.%N)" 'BEGIN{printf "%.1f", b-a}'; }
many() { bash "$HERE/scripts/run_many.sh" "$W" "$@" | sed 's/^/    /'; }
tasks_of() {  # tasks_of <sby> <suffix-regex>
    sed -n '/^\[tasks\]/,/^$/p' "$W/sby/$1" | grep -v '^\[' | awk 'NF{print $1}' | grep -E "$2"
}

step "0. tools"
echo "$FORMAL_TOOL_REPORT"
if [ -n "$FORMAL_TOOLS_MISSING" ]; then
    echo "MISSING:$FORMAL_TOOLS_MISSING  -- see formal/README.md (Tools); nothing was run"
    echo "FORMAL RESULT: FAIL (missing tools)"
    exit 2
fi
printf "    versions: %s | %s | bitwuzla %s | %s | %s | sv2v %s | %s\n" \
    "$($SBY --help >/dev/null 2>&1 && echo sby ok)" "$(yosys -V 2>/dev/null | cut -d' ' -f1-2)" \
    "$(bitwuzla --version 2>/dev/null)" "$(yices-smt2 --version 2>/dev/null | head -1)" \
    "$(z3 --version 2>/dev/null)" "$(sv2v --version 2>/dev/null)" "$(verilator --version 2>/dev/null | cut -d' ' -f1-2)"

rm -rf "$W"; mkdir -p "$W/runs"
for d in sby props harness lemmas mul spec_check mutants; do cp -r "$HERE/$d" "$W/"; done

step "1. formal model of the REAL rtl/execute_stage.sv (sv2v + one inserted include line)"
s=$(now)
if bash "$HERE/scripts/gen.sh" "$REPO" "$W" | sed 's/^/    /'; [ "${PIPESTATUS[0]}" = 0 ]; then
    record gen PASS "$(since $s)" REQ
else
    record gen FAIL "$(since $s)" REQ; echo "FORMAL RESULT: FAIL (model generation)"; exit 1
fi

H6PID=""
# ---- the M unit (steps 1b to 12; not in --mode ext) ----------------------------------
if [ "$MODE" != ext ]; then
if [ "$MODE" = full ]; then
    step "1b. H6 validity by bitwuzla, monolithic, through SBY (slow; started in the background)"
    ( SOLVER_VMEM_KB=${H6_VMEM_KB:-6000000} bash "$HERE/scripts/run_many.sh" "$W" hint_validity.sby REQ 2 14400 h6_bw h6_bwn \
          > "$W/runs/h6_bitwuzla.out" 2>&1 ) &
    H6PID=$!
    echo "    started (pid $H6PID); results at the end"
fi

step "2. spec cross-check: props/spec.vh (both formulations) vs an independent Python model"
s=$(now)
r=$(cd "$W/spec_check" && bash run.sh 1000000 2>&1 | tail -3); echo "$r" | sed 's/^/    /'
echo "$r" | grep -q ", 0 mismatches" && record spec_check_python PASS "$(since $s)" REQ || record spec_check_python FAIL "$(since $s)" REQ

step "3. H1 justification: fan-in cone of mul_result (structural, yosys)"
s=$(now)
r=$(cd "$W" && yosys -s lemmas/mul_result_cone.ys 2>&1 | grep -E "CONE-CHECK-OK|ERROR")
echo "$r" | sed 's/^/    /'
echo "$r" | grep -q CONE-CHECK-OK && record h1_cone_check PASS "$(since $s)" REQ || record h1_cone_check FAIL "$(since $s)" REQ
# negative control: the same check pointed at m_result (fed by registers) must fail
sed -e 's/w:mul_result/w:m_result/' -e 's/CONE-CHECK-OK/NEG-CONTROL-UNEXPECTEDLY-OK/' \
    "$W/lemmas/mul_result_cone.ys" > "$W/lemmas/neg_cone.ys"
r=$(cd "$W" && yosys -s lemmas/neg_cone.ys 2>&1 | grep -E "UNEXPECTEDLY-OK|ERROR" | head -1)
if echo "$r" | grep -q "ERROR: Assertion failed"; then
    echo "    negative control (same check on m_result): ${r:0:60}... -- fails, as required"; record h1_cone_check_negctl FAIL 0 CTL
else
    echo "    negative control (same check on m_result) did not fail as required: $r"; record h1_cone_check_negctl PASS 0 CTL
fi

step "4. validity of the lemma instances H5a H5b H7 H8 H9"
many hint_validity.sby REQ "$PAR" 600 h5a_bw h5a_z3 h5b_bw h5b_z3 h7_bw h7_z3 h8_z3 h9_bw h9_z3

step "4a. validity of H6 by z3: exhaustive 33-way case split on the divisor bit length"
s=$(now)
r=$(bash "$W/lemmas/h6_split/run_split.sh" "$W/props" "$W/lemmas" "$W/runs/h6_split" z3 600 "$PAR"); echo "    $r"
echo "$r" | grep -q "33/33 unsat" && record h6_split_z3 PASS "$(since $s)" REQ || record h6_split_z3 FAIL "$(since $s)" REQ
# negative controls of the pipeline (generation + flattening + split + solver): a broken
# H6 must give sat in exactly the cases where it is false
h6neg() {   # h6neg <name> <sed expression> <expected summary> <description>
    mkdir -p "$W/runs/h6_split_$1/props"
    sed "$2" "$W/props/hints.vh" > "$W/runs/h6_split_$1/props/hints.vh"
    if cmp -s "$W/props/hints.vh" "$W/runs/h6_split_$1/props/hints.vh"; then
        echo "    $1: could not create the broken hint"; record "h6_split_z3_$1" ERROR 0 CTL; return
    fi
    local s r; s=$(now)
    r=$(bash "$W/lemmas/h6_split/run_split.sh" "$W/runs/h6_split_$1/props" "$W/lemmas" "$W/runs/h6_split_$1" z3 600 "$PAR")
    echo "    $1 ($4): ${r%%; non-unsat*}"
    echo "$r" | grep -q "$3" && record "h6_split_z3_$1" FAIL "$(since $s)" CTL || record "h6_split_z3_$1" PASS "$(since $s)" CTL
}
# quotient bit inverted: false for every divisor != 0 (B == 0 falsifies the premise)
h6neg negctl1 's/{f_h_q\[30:0\], f_h_tk}/{f_h_q[30:0], !f_h_tk}/' "1/33 unsat, 32 sat" \
      "quotient bit inverted; expected 32 sat"
# premise T < 2^31 dropped: false for every divisor >= 2 (B == 1 and B == 0 stay unsat)
h6neg negctl2 "s/!(f_q_B != 32'd0 \&\& !f_q_T\[31\])/!(f_q_B != 32'd0)/" "2/33 unsat, 31 sat" \
      "premise T<2^31 dropped; expected 31 sat"

step "4b. the two spec formulations agree for all inputs (per opcode)"
many spec_equiv.sby REQ "$PAR" 600 $(tasks_of spec_equiv.sby '_bw$')

step "5. CTRL (control + linear shape invariants, bounded stall; k=2)"
many div.sby REQ 2 1800 ctrl_bw ctrl_yn
step "6. DIVF (X == T/B, R == T%B; assumes CTRL; lemmas H6-H9; k=1 and k=2)"
many div.sby REQ "$PAR" 1800 divf1_bwn divf1_yn divf_bwn divf_yn
step "7. MULREG (parked product == product of the held operands; assumes CTRL; lemma H1)"
many div.sby REQ 2 900 mulreg_bw mulreg_yn
step "8. FINAL F1/F2/F3 for DIV/DIVU/REM/REMU (assumes CTRL, DIVF; lemmas H5a/H5b)"
many div.sby REQ 3 1800 fdiv_yn fdiv_bwn fdiv_bw
step "9. FINAL F1/F2/F3 for MUL/MULH/MULHSU/MULHU (assumes CTRL, MULREG; per opcode x property)"
many fmul_ops.sby REQ "$PAR" 600 $(tasks_of fmul_ops.sby '_yn$')
[ "$MODE" = full ] && { echo "    second solver (bitwuzla, reported only):"; many fmul_ops.sby AUX "$PAR" 300 $(tasks_of fmul_ops.sby '_bwn$'); }
step "10. port-level A1 (result) and A3a (hand-off), per opcode (assumes CTRL, DIVF, MULREG; lemmas H1, H5a/b)"
many iface.sby REQ "$PAR" 600 $(tasks_of iface.sby '_yn$')
[ "$MODE" = full ] && { echo "    second solver for A1 (bitwuzla, reported only):"; many iface.sby AUX "$PAR" 600 $(tasks_of iface.sby '_bwn$'); }
step "11. non-vacuity covers (C1-C6 bare / everything assumed, depth 45; every M opcode leaves Execute, depth 40)"
many cover.sby REQ 3 2400 env_bw all_bw iface_bw
for t in env_bw all_bw iface_bw; do
    c=$(grep -a "Reached cover statement" "$W/runs/cover_$t.log" 2>/dev/null | wc -l)
    u=$(grep -a "Unreached cover statement" "$W/runs/cover_$t.log" 2>/dev/null | wc -l)
    echo "    cover_$t: $c cover statement(s) reached, $u unreached"
done
step "12. multiplier FORMULATION check (hand copy of the RTL formula; mulhsu_bug_y is a control that must FAIL)"
many mul_formulation.sby REQ "$PAR" 300 mul_bw mul_y mulh_bw mulh_y mulhsu_bw mulhsu_y mulhu_bw mulhu_y
many mul_formulation.sby CTL 1 300 mulhsu_bug_y
fi
# ---- end of the M unit ------------------------------------------------------------------

# ---- the EXT unit: Zbb, Zbs, Zicond, Zbkb, Zbkx, Zknh (steps E1 to E4; every mode) ----
step "E1. EXT reference: props/ext_spec.vh vs an independent Python model"
s=$(now)
r=$(cd "$W/spec_check" && bash run_ext.sh 1000000 2>&1 | tail -3); echo "$r" | sed 's/^/    /'
echo "$r" | grep -q ", 0 mismatches" && record ext_spec_check_python PASS "$(since $s)" REQ || record ext_spec_check_python FAIL "$(since $s)" REQ

step "E2. EXT payload map of harness/top_ext.v vs defines/op.sv"
s=$(now)
r=$(python3 "$HERE/scripts/ext_codes.py" "$REPO" "$W" 2>&1); echo "$r" | sed 's/^/    /'
echo "$r" | grep -q "^ext payload map: op::EXT = 61" && record ext_payload_map PASS "$(since $s)" REQ || record ext_payload_map FAIL "$(since $s)" REQ

step "E3. EXT X1/X2 for each of the 45 instructions, X3 (no stall), covers (bare environment; nothing of the M proof assumed)"
many ext.sby REQ "$PAR" 600 $(tasks_of ext.sby '_yn$') cover_bw
c=$(grep -a "Reached cover statement" "$W/runs/ext_cover_bw.log" 2>/dev/null | wc -l)
u=$(grep -a "Unreached cover statement" "$W/runs/ext_cover_bw.log" 2>/dev/null | wc -l)
echo "    ext_cover_bw: $c cover statement(s) reached, $u unreached"
[ "$MODE" = full ] && { echo "    second solver (bitwuzla, reported only):"; many ext.sby AUX "$PAR" 600 $(tasks_of ext.sby '_bwn$'); }

step "E4. EXT negative controls: each mutant of mutants/ext_mutants.txt must FAIL its target property"
if python3 "$HERE/scripts/ext_mutants.py" "$W" > "$W/runs/ext_mutants.list"; then
    awk '{ n = $1; $1 = ""; $2 = ""; sub(/^ +/, ""); print "    " n ": " $0 }' "$W/runs/ext_mutants.list"
    awk '{print "mut_ext_" $1 "_ext.sby " $2}' "$W/runs/ext_mutants.list" \
        | xargs -P "$PAR" -L1 bash -c 'bash "$0/run_task.sh" "$1" "$2" "$3" 300 CTL' "$HERE/scripts" "$W" | sed 's/^/    /'
else
    record ext_mutants_generate ERROR 0 CTL
fi

step "13. sv2v fidelity: the repository's execute-stage benches on the SystemVerilog vs the sv2v model"
s=$(now)
FIDELITY_BENCHES=""; [ "$MODE" = ext ] && FIDELITY_BENCHES=test_ext_execute
if bash "$HERE/scripts/sv2v_fidelity.sh" "$REPO" "$W" "$OUT/sv2v_fidelity" $FIDELITY_BENCHES; then
    record sv2v_fidelity PASS "$(since $s)" REQ
else
    record sv2v_fidelity FAIL "$(since $s)" REQ
fi

MUTRES=""
if [ "$MODE" = full ]; then
    step "14. formal mutation campaign (mutants/mutants.txt x 32 proofs each)"
    bash "$HERE/scripts/run_mutants.sh" "$W" "$PAR" 300
    MUTRES="$W/runs/mutants_summary.txt"
    step "14b. EXT mutation campaign (mutants/ext_mutants.txt x the 46 required property tasks of ext.sby)"
    bash "$HERE/scripts/run_ext_mutants.sh" "$W" "$PAR" 300
    cat "$W/runs/ext_mutants_summary.txt" >> "$MUTRES"
fi

if [ -n "$H6PID" ]; then
    step "waiting for H6 by bitwuzla"
    wait "$H6PID"; sed 's/^/    /' "$W/runs/h6_bitwuzla.out"
fi

step "SUMMARY ($(( $(date +%s) - T0 )) s)"
{
    echo "formal/run.sh mode=$MODE  $(date '+%F %T')  model of: $(sed -n 1p "$W/gen/SHA256SUMS")"
    printf "%-34s %-13s %9s  %s\n" CHECK STATUS WALL CLASS
    grep -v "class=MUT" "$W/runs/times.txt" | awk '{
        w=""; c="";
        for (i=1;i<=NF;i++) { if ($i ~ /^wall=/) { w=$i; if (w=="wall=") w=$(i+1); sub(/^wall=/,"",w) }
                              if ($i ~ /^class=/) { c=$i; sub(/^class=/,"",c) } }
        printf "%-34s %-13s %9s  %s\n", $1, $2, w, c }'
    [ -n "$MUTRES" ] && { echo; cat "$MUTRES"; }
    echo
    bad_req=$(grep "class=REQ" "$W/runs/times.txt" | grep -v " PASS " | awk '{print $1":"$2}' | tr '\n' ' ')
    bad_ctl=$(grep "class=CTL" "$W/runs/times.txt" | grep -v " FAIL " | awk '{print $1":"$2}' | tr '\n' ' ')
    aux=$(grep "class=AUX" "$W/runs/times.txt" | grep -v " PASS " | awk '{print $1":"$2}' | tr '\n' ' ')
    n_req=$(grep -c "class=REQ" "$W/runs/times.txt"); n_ctl=$(grep -c "class=CTL" "$W/runs/times.txt")
    echo "required checks: $n_req, not PASS: ${bad_req:-none}"
    echo "negative controls: $n_ctl, not FAIL (as required): ${bad_ctl:-none}"
    [ -n "$aux" ] && echo "second-solver runs not PASS (reported only, each also proven by the required engine): $aux"
    surv=""
    if [ -n "$MUTRES" ]; then
        surv=$(grep " SURVIVED " "$MUTRES" | awk '{print $1}' | grep -vx diff32 | tr '\n' ' ')
        echo "mutants: $(grep -v '^ext_' "$MUTRES" | grep -c ' REJECTED ') rejected, $(grep -v '^ext_' "$MUTRES" | grep -c ' SURVIVED ') survived" \
             "(diff32 is a proven-equivalent mutant, see README); unexpected survivors: ${surv:-none}"
        echo "EXT mutants: $(grep '^ext_' "$MUTRES" | grep -c ' REJECTED ') rejected, $(grep '^ext_' "$MUTRES" | grep -c ' SURVIVED ') survived"
    fi
    if [ -z "$bad_req" ] && [ -z "$bad_ctl" ] && [ -z "$surv" ]; then
        echo "FORMAL RESULT: PASS (mode=$MODE)"
    else
        echo "FORMAL RESULT: FAIL (mode=$MODE)"
    fi
} | tee "$OUT/SUMMARY.txt"
grep -q "^FORMAL RESULT: PASS" "$OUT/SUMMARY.txt"
