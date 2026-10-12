#!/bin/bash
# SPDX-License-Identifier: MIT
# =============================================================================================
# formal/cache/run.sh -- formal proofs of the simulation-only instruction cache
# (rtl/cache/icache.sv with rtl/cache/cache_ram.sv), the memory arbiter
# (rtl/cache/mem_arbiter.sv) and the interconnect's timeout exemption
# (lib/wishbone/wishbone_interconnect.sv and its mask in rtl/mcu.sv), with their covers and
# negative controls. Guide: formal/cache/README.md.
#
#   bash formal/cache/run.sh [options]
#   make formal-cache          (output in $(BUILD_DIR)/formal-cache, FORMAL_PAR solver processes)
#
#   --out DIR          output directory (default: build/formal-cache of this checkout)
#   --par N            parallel solver processes (default: FORMAL_PAR, else 4)
#   --src DIR          the tree whose RTL is proved (default: this checkout)
#   --only LIST        only these checks, comma-separated: property names, covers, induction
#   --configs LIST     tiny,second (default both; the second configuration proves seven properties)
#   --depth N          replaces the stated depths (tiny 40, second 30) of the bounded proofs
#   --step-limit S     seconds for one step of the fallback ladder of one property in one
#                      configuration (default 7200; each of the step's three engines gets a third)
#   --sim-cycles N     cycles of the ladder's random simulation (default 10000000)
#   --accept-sim LIST  properties whose simulation-only result the maintainer has accepted
#   --no-controls      skip the negative controls
#   --mutants FILE     the table of the negative controls (default formal/cache/mutants.txt); a
#                      mutant whose row gives no text is applied by the repository's mutation
#                      script, test/memsys/mutants.py apply (the same patch as its campaign)
#   --mutant-cmd CMD   instead of the table: "CMD <mutant> <dir>" writes a copy of the source tree
#                      with that mutant applied into <dir>
#   --base COMMIT      the commit whose wishbone_interconnect.sv the base copy must equal, with
#                      only the module name changed (default 642b86f; not checked when the
#                      repository does not have it)
#
# The repository is only read: the sources are copied to <out>/work, and every generated file,
# SBY run directory and log goes below <out>. Result: <out>/SUMMARY.txt and the last line
# "FORMAL CACHE RESULT: PASS" or "FORMAL CACHE RESULT: FAIL (...)"; exit status 0 only for PASS
# (2: a tool is missing).
# =============================================================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="$REPO/build/formal-cache"; PAR="${FORMAL_PAR:-4}"; SRC="$REPO"; ONLY=""; CONFIGS="tiny,second"
DEPTH=""; LIMIT=7200; SIMCYC=10000000; ACCEPT=""; CONTROLS=1; MUTANTS="$HERE/mutants.txt"
MUTCMD=""; BASE=642b86f
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift 2;;
        --par) PAR="$2"; shift 2;;
        --src) SRC="$2"; shift 2;;
        --only) ONLY="$2"; shift 2;;
        --configs) CONFIGS="$2"; shift 2;;
        --depth) DEPTH="$2"; shift 2;;
        --step-limit) LIMIT="$2"; shift 2;;
        --sim-cycles) SIMCYC="$2"; shift 2;;
        --accept-sim) ACCEPT="$2"; shift 2;;
        --no-controls) CONTROLS=0; shift;;
        --mutants) MUTANTS="$2"; shift 2;;
        --mutant-cmd) MUTCMD="$2"; shift 2;;
        --base) BASE="$2"; shift 2;;
        -h|--help) sed -n '2,36p' "$0"; exit 0;;
        *) echo "unknown argument: $1"; exit 2;;
    esac
done
mkdir -p "$OUT" || exit 2
OUT="$(cd "$OUT" && pwd)"
SRC="$(cd "$SRC" && pwd)" || exit 2
MUTANTS="$(cd "$(dirname "$MUTANTS")" && pwd)/$(basename "$MUTANTS")"
case "$OUT/" in "$REPO/formal/"*) echo "the output directory must not be inside formal/"; exit 2;; esac

source "$REPO/formal/scripts/env.sh" || exit 2
W="$OUT/work"
exec > >(tee "$OUT/run.log") 2>&1
START=$(date +%s)
echo "formal/cache/run.sh par=$PAR configs=$CONFIGS out=$OUT  ($(date '+%F %T'))"
echo "sources: $SRC"
step() { echo; echo "=== $* ==="; }
check() {   # check <name> <status> <class> <wall_s> [detail]: one line of the summary
    printf "%-30s %-13s %-4s wall=%7ss %s\n" "$1" "$2" "$3" "$4" "${5:-}" >> "$W/runs/checks.txt"
}
now() { date +%s; }
times_of() {   # times_of <class>: "<name> <status> <wall_s>" for the runs of that class
    grep " class=$1 " "$W/runs/times.txt" | awk '{
        w = ""; for (i = 1; i <= NF; i++) if ($i ~ /^wall=/) { w = $i; if (w == "wall=") w = $(i+1) }
        sub(/^wall=/, "", w); sub(/s$/, "", w); print $1, $2, w }'
}
wanted() {  # wanted <name>: selected by --only
    [ -z "$ONLY" ] && return 0
    case ",$ONLY," in *",$1,"*) return 0;; esac
    return 1
}
has_cfg() { case ",$CONFIGS," in *",$1,"*) return 0;; esac; return 1; }

PROPS_TINY="fetch_data line_data window ack_err answer_req grant_route refill_no_write grant_kept bound bound_cpu reset_state store_fetch refill_window refill_stable store_once data_indep"
PROPS_SECOND="fetch_data line_data window reset_state store_fetch refill_window refill_stable"
IC_CHECKS="ic_default ic_ram_exempt ic_io_timeout"

step "0. tools"
echo "$FORMAL_TOOL_REPORT"
if [ -n "$FORMAL_TOOLS_MISSING" ]; then
    echo "MISSING:$FORMAL_TOOLS_MISSING  -- see formal/README.md (Tools); nothing was run"
    echo "FORMAL CACHE RESULT: FAIL (missing tools)"
    exit 2
fi
printf "    versions: %s | %s | bitwuzla %s | %s | %s | sv2v %s | %s\n" \
    "$($SBY --help >/dev/null 2>&1 && echo sby ok)" "$(yosys -V 2>/dev/null | cut -d' ' -f1-2)" \
    "$(bitwuzla --version 2>/dev/null)" "$(yices-smt2 --version 2>/dev/null | head -1)" \
    "$(z3 --version 2>/dev/null)" "$(sv2v --version 2>/dev/null)" "$(verilator --version 2>/dev/null | cut -d' ' -f1-2)"

rm -rf "$W"; mkdir -p "$W/runs" "$W/sim" "$W/mut"
cp -r "$HERE/sby" "$HERE/props" "$W/"
: > "$W/runs/checks.txt"; : > "$W/runs/ladder.txt"; : > "$W/runs/controls.txt"; : > "$W/runs/times.txt"

step "1. sources: the base copy of the interconnect, the mask of rtl/mcu.sv, the cache RTL"
s=$(now)
r=$(python3 "$HERE/scripts/model.py" base "$REPO" "$BASE" "$HERE/wishbone_interconnect_base.sv")
case "$r" in
    SAME)      echo "    wishbone_interconnect_base.sv equals $BASE:lib/wishbone/wishbone_interconnect.sv (module name apart)"
               check ic_base_copy PASS REQ "$(( $(now) - s ))";;
    DIFFERENT) echo "    wishbone_interconnect_base.sv DIFFERS from $BASE:lib/wishbone/wishbone_interconnect.sv"
               check ic_base_copy FAIL REQ "$(( $(now) - s ))";;
    *)         echo "    base commit $BASE not available: the copy is not checked"
               check ic_base_copy NOT-RUN AUX 0 "base commit not available";;
esac
MASK_OK=0
if wanted ic_ram_exempt || wanted ic_io_timeout || [ -z "$ONLY" ]; then
    r=$(python3 "$HERE/scripts/model.py" mask "$SRC/rtl/mcu.sv")
    echo "    rtl/mcu.sv, cached branch: TIMEOUT_EXEMPT $r"
    case "$r" in
        "9'b000000001 "*) MASK_OK=1; check ic_mask PASS REQ 0 "$r";;
        "NO MASK"*)       check ic_mask FAIL REQ 0 "$r";;
        *)                MASK_OK=1; check ic_mask FAIL REQ 0 "$r (expected 9'b0_0000_0001)";;
    esac
fi
CACHE_OK=1
for f in rtl/cache/icache.sv rtl/cache/cache_ram.sv rtl/cache/mem_arbiter.sv; do
    [ -f "$SRC/$f" ] || { echo "    $f: MISSING"; CACHE_OK=0; }
done

step "2. formal models (sv2v with SYNTHESIS defined; observer and property include lines, checked)"
CACHE_MODELS="cache_tiny cache_tiny_cpu cache_tiny_narrow cache_tiny_narrow_cpu pair_tiny pair_tiny_narrow icache_tiny arbiter_tiny arbiter_tiny_cpu"
CACHE_MODELS="$CACHE_MODELS cache_second cache_second_cpu cache_second_narrow cache_second_narrow_cpu icache_second arbiter_second arbiter_second_cpu"
gen() {   # gen <log> <models...>
    local log="$1"; shift
    python3 "$HERE/scripts/model.py" gen "$SRC" "$HERE" "$W/gen" "$@" >> "$W/$log" 2>&1
}
s=$(now)
if [ "$CACHE_OK" = 1 ] && gen gen_cache.log $CACHE_MODELS; then
    check gen_cache PASS REQ "$(( $(now) - s ))"; GEN_CACHE=1
else
    check gen_cache FAIL REQ "$(( $(now) - s ))" "$(tail -1 "$W/gen_cache.log" 2>/dev/null)"; GEN_CACHE=0
fi
sed 's/^/    /' "$W/gen_cache.log" 2>/dev/null
s=$(now)
if gen gen_ic.log ic_default; then GEN_ICD=1; else GEN_ICD=0; fi
GEN_ICM=0
[ "$MASK_OK" = 1 ] && gen gen_ic.log ic_ram_exempt ic_io_timeout && GEN_ICM=1
sed 's/^/    /' "$W/gen_ic.log"
[ "$GEN_ICD" = 1 ] && check gen_interconnect PASS REQ "$(( $(now) - s ))" || \
    check gen_interconnect FAIL REQ "$(( $(now) - s ))" "$(tail -1 "$W/gen_ic.log")"
[ -f "$W/gen/SHA256SUMS" ] && sed 's/^/    sha256 /' "$W/gen/SHA256SUMS"
# the .sby files list every model; drop the ones that were not built (SBY copies every listed file)
for f in "$W"/sby/*.sby; do
    for g in $(sed -n 's#^\.\./gen/##p' "$f"); do
        [ -f "$W/gen/$g" ] || sed -i -e "\#^\.\./gen/$g\$#d" "$f"
    done
done

# ---- 3. the bounded proofs, each with its fallback ladder ------------------------------------
step "3. bounded proofs with the fallback ladder (step limit ${LIMIT}s, ${PAR} at a time)"
: > "$W/runs/ladder.jobs"
if [ "$GEN_CACHE" = 1 ]; then
    for p in $PROPS_TINY; do wanted "$p" && has_cfg tiny && echo "$p tiny" >> "$W/runs/ladder.jobs"; done
    for p in $PROPS_SECOND; do wanted "$p" && has_cfg second && echo "$p second" >> "$W/runs/ladder.jobs"; done
fi
if [ -s "$W/runs/ladder.jobs" ]; then
    awk -v l="$LIMIT" -v c="$SIMCYC" -v d="$DEPTH" '{print $1, $2, l, c (d == "" ? "" : " " d)}' "$W/runs/ladder.jobs" |
        xargs -P "$PAR" -L1 bash "$HERE/scripts/ladder.sh" "$W"
fi
sort "$W/runs/ladder.txt" -o "$W/runs/ladder.txt"
sed 's/^/    /' "$W/runs/ladder.txt"
while read -r name st rest; do
    p="${name%_*}"
    wall=$(echo "$rest" | sed -n 's/.*wall=\([0-9]*\)s.*/\1/p')
    case "$st" in
        PASS) check "$name" PASS REQ "$wall" "$rest";;
        SIM)  case ",$ACCEPT," in
                  *",$p,"*) check "$name" PASS REQ "$wall" "checked by simulation only, accepted: $rest";;
                  *)        check "$name" SIM REQ "$wall" "checked by simulation only, not accepted: $rest";;
              esac;;
        *)    check "$name" "$st" REQ "$wall" "$rest";;
    esac
done < "$W/runs/ladder.txt"

# ---- 4. covers ----------------------------------------------------------------------------
step "4. covers (every cover statement must be reached)"
if [ "$GEN_CACHE" = 1 ] && wanted covers; then
    COV=""
    has_cfg tiny && COV="$COV cover_tiny cover_cpu_tiny"
    has_cfg second && COV="$COV cover_second cover_cpu_second"
    [ -n "$COV" ] && bash "$REPO/formal/scripts/run_many.sh" "$W" cover.sby COV "$PAR" "$LIMIT" $COV | sed 's/^/    /'
    has_cfg tiny && bash "$REPO/formal/scripts/run_many.sh" "$W" pair.sby COV 1 "$LIMIT" cover_pair_tiny | sed 's/^/    /'
fi
if wanted covers; then
    ICC="cover_ic_default"
    [ "$GEN_ICM" = 1 ] && ICC="$ICC cover_ic_ram_exempt cover_ic_io_timeout"
    [ "$GEN_ICD" = 1 ] && bash "$REPO/formal/scripts/run_many.sh" "$W" interconnect.sby COV "$PAR" "$LIMIT" $ICC | sed 's/^/    /'
fi
times_of COV | while read -r name st wall; do
    r=$(grep -a -c "Reached cover statement" "$W/runs/$name.log" 2>/dev/null)
    u=$(grep -a -c "Unreached cover statement" "$W/runs/$name.log" 2>/dev/null)
    echo "    $name: $r reached, $u unreached"
    check "$name" "$st" REQ "$wall" "$r reached, $u unreached"
done

# ---- 5. the interconnect: unbounded proofs, fallback a bounded check to depth 260 ------------
step "5. interconnect: induction, else a bounded check to depth 260"
for e in bw yi z3; do
    case $e in bw) l="smtbmc bitwuzla";; yi) l="smtbmc yices";; z3) l="smtbmc z3";; esac
    sed -e "s/^smtbmc bitwuzla$/$l/" "$W/sby/interconnect.sby" > "$W/sby/interconnect__$e.sby"
done
ic_ladder() {   # ic_ladder <check>: induction with each engine, then depth 260 with each engine
    local c="$1" s task e st stepno; s=$(now)
    for task in "$c" "${c}_bmc"; do
        stepno=1; [ "$task" != "$c" ] && stepno=2
        for e in bw yi z3; do
            bash "$REPO/formal/scripts/run_task.sh" "$W" "interconnect__$e.sby" "$task" "$(( LIMIT / 3 ))" STEP > /dev/null
            st=$(grep "^interconnect__${e}_${task} " "$W/runs/times.txt" | tail -1 | awk '{print $2}')
            if [ "$st" = PASS ] || [ "$st" = FAIL ]; then
                printf "%-26s %-5s step=%s depth=%s engine=%s harness=ic wall=%ss task=%s\n" "$c" "$st" "$stepno" \
                    "$([ "$stepno" = 1 ] && echo unbounded || echo 260)" "$e" "$(( $(now) - s ))" "$task" \
                    >> "$W/runs/ladder_ic.txt"
                return
            fi
        done
    done
    printf "%-26s %-5s step=- depth=- engine=- harness=ic wall=%ss\n" "$c" NONE "$(( $(now) - s ))" >> "$W/runs/ladder_ic.txt"
}
: > "$W/runs/ladder_ic.txt"
for c in $IC_CHECKS; do
    wanted "$c" || continue
    if { [ "$c" = ic_default ] && [ "$GEN_ICD" = 1 ]; } || { [ "$c" != ic_default ] && [ "$GEN_ICM" = 1 ]; }; then
        ic_ladder "$c"
    else
        check "$c" ERROR REQ 0 "no model (see the mask and model checks)"
    fi
done
sed 's/^/    /' "$W/runs/ladder_ic.txt"
while read -r name st rest; do
    check "$name" "$st" REQ "$(echo "$rest" | sed -n 's/.*wall=\([0-9]*\)s.*/\1/p')" "$rest"
done < "$W/runs/ladder_ic.txt"

# ---- 6. k-induction on the I-cache alone (reported) ---------------------------------------
step "6. k-induction attempt on the I-cache alone (reported, not required)"
if [ "$GEN_CACHE" = 1 ] && wanted induction; then
    IND=""
    has_cfg tiny && IND="$IND induction_tiny"
    has_cfg second && IND="$IND induction_second"
    bash "$REPO/formal/scripts/run_many.sh" "$W" induction.sby AUX "$PAR" "$LIMIT" $IND | sed 's/^/    /'
    times_of AUX | grep '^induction_' | while read -r name st wall; do
        check "$name" "$st" AUX "$wall" "PASS: an unbounded proof; otherwise see runs/$name"
    done
fi

# ---- 7. negative controls ------------------------------------------------------------------
step "7. negative controls: each mutant must make its properties FAIL where they were proved"
if [ "$CONTROLS" = 1 ]; then
    # accepted results: property_config -> step depth engine harness
    cat "$W/runs/ladder.txt" "$W/runs/ladder_ic.txt" > "$W/runs/accepted.txt"
    python3 "$HERE/scripts/model.py" mutants "$MUTANTS" > "$W/runs/mutants.list" || exit 1
    : > "$W/runs/control.jobs"
    while read -r m props defined; do
        for p in ${props//,/ }; do
            wanted "$p" || continue
            line=""
            if [ "${p#ic_}" != "$p" ]; then
                line=$(grep -E "^$p +PASS " "$W/runs/accepted.txt" | head -1)
                [ -z "$line" ] && { echo "    $m: $p was not proved, no control run"; continue; }
                task=$(echo "$line" | sed -n 's/.*task=\([a-z_]*\).*/\1/p')
                eng=$(echo "$line" | sed -n 's/.*engine=\([a-z0-9]*\).*/\1/p')
                echo "$m $task - - - $eng ic $defined" >> "$W/runs/control.jobs"
            else
                line=$(grep -E "^${p}_tiny +(PASS|SIM) " "$W/runs/accepted.txt" | head -1)
                [ -z "$line" ] && { echo "    $m: ${p}_tiny was not proved, no control run"; continue; }
                stp=$(echo "$line" | sed -n 's/.*step=\([0-9]*\).*/\1/p')
                dep=$(echo "$line" | sed -n 's/.*depth=\([0-9-]*\).*/\1/p')
                eng=$(echo "$line" | sed -n 's/.*engine=\([a-z0-9:,-]*\).*/\1/p')
                har=$(echo "$line" | sed -n 's/.*harness=\([a-z]*\).*/\1/p')
                [ "$har" = sim ] && dep="$SIMCYC"
                echo "$m $p tiny $stp $dep $eng $har $defined" >> "$W/runs/control.jobs"
            fi
        done
    done < "$W/runs/mutants.list"
    # the mutated models, one directory per mutant
    for m in $(awk '{print $1}' "$W/runs/control.jobs" | sort -u); do
        defined=$(awk -v m="$m" '$1 == m {print $8; exit}' "$W/runs/control.jobs")
        md="$W/mut/$m"; mkdir -p "$md/gen"
        models=$(awk -v m="$m" '$1 == m {print $2, $3, $7}' "$W/runs/control.jobs" | while read -r p c h; do
            case "$h" in
                ic) echo "${p%_bmc}";;
                split) echo "icache_tiny arbiter_tiny arbiter_tiny_cpu";;
                *) case "$p" in data_indep) b=pair;; *) b=cache;; esac
                   n=""; [ "$h" = narrow ] && n=_narrow
                   cpu=""; [ "$p" = bound_cpu ] && cpu=_cpu
                   echo "${b}_tiny${n}${cpu}";;
            esac
        done | tr ' ' '\n' | sort -u | tr '\n' ' ')
        if [ -n "$MUTCMD" ]; then
            rm -rf "$md/tree"
            if $MUTCMD "$m" "$md/tree" > "$md/gen.log" 2>&1 &&
               python3 "$HERE/scripts/model.py" gen "$md/tree" "$HERE" "$md/gen" $models >> "$md/gen.log" 2>&1; then
                touch "$md/gen/.done"
            fi
        elif [ "$defined" = defined ]; then
            python3 "$HERE/scripts/model.py" gen "$SRC" "$HERE" "$md/gen" --mutant "$m" --mutants "$MUTANTS" \
                $models > "$md/gen.log" 2>&1 && touch "$md/gen/.done"
        elif [ -f "$SRC/test/memsys/mutants.py" ]; then
            # the patch of the mutation campaign, applied to a copy of the RTL
            rm -rf "$md/tree"
            if python3 "$SRC/test/memsys/mutants.py" apply --src "$SRC" --subset rtl,lib,defines "$m" "$md/tree" \
                    > "$md/gen.log" 2>&1 &&
               python3 "$HERE/scripts/model.py" gen "$md/tree" "$HERE" "$md/gen" $models >> "$md/gen.log" 2>&1; then
                touch "$md/gen/.done"
            fi
        else
            echo "model.py: mutant $m is not defined in $(basename "$MUTANTS")" > "$md/gen.log"
        fi
    done
    awk '{print $1, $2, $3, $4, $5, $6, $7}' "$W/runs/control.jobs" |
        xargs -P "$PAR" -L1 bash "$HERE/scripts/control.sh" "$W" "$(( LIMIT / 3 ))"
fi
sort "$W/runs/controls.txt" -o "$W/runs/controls.txt"
sed 's/^/    /' "$W/runs/controls.txt"
while read -r m task st wall rest; do
    check "ctl:$m:$task" "$st" CTL "$(echo "$wall" | sed 's/^wall=//; s/s$//')" "$rest"
done < "$W/runs/controls.txt"

# ---- summary ---------------------------------------------------------------------------------
step "SUMMARY ($(( $(now) - START )) s)"
{
    echo "formal/cache/run.sh  $(date '+%F %T')  sources: $SRC"
    [ -f "$W/gen/SHA256SUMS" ] && sed 's/^/  sha256 /' "$W/gen/SHA256SUMS"
    echo
    echo "Fallback ladder (property_configuration status step depth engine harness):"
    cat "$W/runs/ladder.txt" "$W/runs/ladder_ic.txt" | sed 's/^/  /'
    echo
    echo "Outcome table for formal/cache/README.md, section 7:"
    echo "| Check | Configuration | Outcome |"
    echo "|---|---|---|"
    cat "$W/runs/ladder.txt" "$W/runs/ladder_ic.txt" | awk '{
        name = $1; st = $2; cfg = "-"
        for (i = 3; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] }
        if (name ~ /_(tiny|second)$/) { cfg = name; sub(/^.*_/, "", cfg); sub(/_(tiny|second)$/, "", name) }
        eng = v["engine"]; gsub(/bw/, "bitwuzla", eng); gsub(/yi/, "Yices", eng)
        if (st == "PASS" && v["harness"] == "ic") out = (v["step"] == 1 ? "proved, unbounded (induction, " eng ")" : "bounded check to depth 260 (" eng ")")
        else if (st == "PASS") out = "proved to depth " v["depth"] " (step " v["step"] ", " eng (v["harness"] == "full" ? "" : ", " v["harness"] " harness") ")"
        else if (st == "SIM") out = "checked by simulation only"
        else out = st
        printf "| `%s` | %s | %s |\n", name, cfg, out }'
    awk '$3 == "REQ" && $1 ~ /cover/ {d = $0; sub(/.*wall= *[0-9.]*s /, "", d); printf "| covers `%s` | | %s: %s |\n", $1, $2, d}' "$W/runs/checks.txt"
    n_c=$(awk '$3 == "CTL"' "$W/runs/checks.txt" | wc -l); f_c=$(awk '$3 == "CTL" && $2 == "FAIL"' "$W/runs/checks.txt" | wc -l)
    echo "| negative controls | tiny | $f_c of $n_c fail as required |"
    awk '$1 ~ /^induction_/ {c = $1; sub(/^induction_induction_/, "", c); printf "| k-induction | %s | %s |\n", c, ($2 == "PASS" ? "proved, unbounded" : $2)}' "$W/runs/checks.txt"
    echo
    printf "%-30s %-13s %-4s %10s  %s\n" CHECK STATUS CLASS WALL DETAIL
    cat "$W/runs/checks.txt"
    echo
    bad_req=$(awk '$3 == "REQ" && $2 != "PASS" {print $1":"$2}' "$W/runs/checks.txt" | tr '\n' ' ')
    bad_ctl=$(awk '$3 == "CTL" && $2 != "FAIL" {print $1":"$2}' "$W/runs/checks.txt" | tr '\n' ' ')
    n_req=$(awk '$3 == "REQ"' "$W/runs/checks.txt" | wc -l)
    n_ctl=$(awk '$3 == "CTL"' "$W/runs/checks.txt" | wc -l)
    echo "required checks: $n_req, not PASS: ${bad_req:-none}"
    echo "negative controls: $n_ctl, not FAIL (as required): ${bad_ctl:-none}"
    [ "$CONTROLS" = 0 ] && echo "negative controls skipped (--no-controls)"
    if [ -z "$bad_req" ] && [ -z "$bad_ctl" ] && [ "$CONTROLS" = 1 ] && [ "$n_req" -gt 0 ]; then
        echo "FORMAL CACHE RESULT: PASS"
    else
        why=""
        [ -n "$bad_req" ] && why="required checks not PASS: ${bad_req% }"
        [ -n "$bad_ctl" ] && why="${why:+$why; }controls not FAIL: ${bad_ctl% }"
        [ "$CONTROLS" = 0 ] && why="${why:+$why; }negative controls not run"
        echo "FORMAL CACHE RESULT: FAIL ($why)"
    fi
} | tee "$OUT/SUMMARY.txt"
grep -q "^FORMAL CACHE RESULT: PASS" "$OUT/SUMMARY.txt"
