#!/bin/bash
# SPDX-License-Identifier: MIT
# =============================================================================================
# formal/hpm/run.sh -- formal proofs of the hardware performance counters: the counter unit
# (rtl/hpm_events.sv with rtl/hpm.sv), the instruction decoder against the base commit's, and
# the Writeback stage against the base commit's, with covers and negative controls.
# Guide: formal/hpm/README.md.
#
#   bash formal/hpm/run.sh [options]
#   make formal-hpm          (output in $(BUILD_DIR)/formal-hpm, FORMAL_PAR solver processes)
#
#   --out DIR            output directory (default: build/formal-hpm of this checkout)
#   --par N              parallel solver processes (default: FORMAL_PAR, else 4)
#   --src DIR            the tree whose RTL is proved (default: this checkout)
#   --only LIST          only these checks, comma-separated: property names, covers
#   --configs LIST       counter-unit configurations n<N>w<W> (default n7w48,n7w32,n7w64,n1w48,n0w48;
#                        the first one is the one of the negative controls)
#   --step-limit S       seconds for one step of the ladder of one check (default 3600; each of
#                        the three engines gets a third)
#   --bmc-depth N        depth of the ladder's bounded step (default 20)
#   --accept-bounded L   checks whose bounded result the maintainer has accepted
#   --assume-x0-source   the Writeback miter also assumes that a CSRRS, CSRRC, CSRRSI or CSRRCI
#                        with rs1 field 0 has source operand 0
#   --no-controls        skip the negative controls
#   --mutants FILE       the table of the negative controls (default formal/hpm/mutants.txt); a
#                        mutant whose row gives no text is taken from the repository's counter
#                        mutation campaign (test/hpm/mutants.py apply), or from --mutant-cmd
#   --mutant-cmd CMD     "CMD <mutant> <dir>" writes a copy of the source tree with that mutant
#                        applied into <dir> (for the rows without text)
#   --base COMMIT        the commit whose writeback_stage.sv and instruction_decoder.sv the base
#                        copies must equal, with only the module name changed (default c5fe2e4;
#                        not checked when the repository does not have it)
#
# The repository is only read: the sources are copied to <out>/work, and every generated file,
# SBY run directory and log goes below <out>. Result: <out>/SUMMARY.txt and the last line
# "FORMAL HPM RESULT: PASS" or "FORMAL HPM RESULT: FAIL (...)"; exit status 0 only for PASS
# (2: a tool is missing).
# =============================================================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="$REPO/build/formal-hpm"; PAR="${FORMAL_PAR:-4}"; SRC="$REPO"; ONLY=""
CONFIGS="n7w48,n7w32,n7w64,n1w48,n0w48"; LIMIT=3600; BMCD=20; ACCEPT=""; X0=0; CONTROLS=1
MUTANTS="$HERE/mutants.txt"; MUTCMD=""; BASE=c5fe2e4
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift 2;;
        --par) PAR="$2"; shift 2;;
        --src) SRC="$2"; shift 2;;
        --only) ONLY="$2"; shift 2;;
        --configs) CONFIGS="$2"; shift 2;;
        --step-limit) LIMIT="$2"; shift 2;;
        --bmc-depth) BMCD="$2"; shift 2;;
        --accept-bounded) ACCEPT="$2"; shift 2;;
        --assume-x0-source) X0=1; shift;;
        --no-controls) CONTROLS=0; shift;;
        --mutants) MUTANTS="$2"; shift 2;;
        --mutant-cmd) MUTCMD="$2"; shift 2;;
        --base) BASE="$2"; shift 2;;
        -h|--help) sed -n '2,40p' "$0"; exit 0;;
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
echo "formal/hpm/run.sh par=$PAR configs=$CONFIGS out=$OUT  ($(date '+%F %T'))"
echo "sources: $SRC"
step() { echo; echo "=== $* ==="; }
check() {   # check <name> <status> <class> <wall_s> [detail]: one line of the summary
    printf "%-34s %-13s %-4s wall=%7ss %s\n" "$1" "$2" "$3" "$4" "${5:-}" >> "$W/runs/checks.txt"
}
now() { date +%s; }
wanted() { [ -z "$ONLY" ] && return 0; case ",$ONLY," in *",$1,"*) return 0;; esac; return 1; }

UNIT_PROPS="increment write_rule event_timing selector_warl inhibit isolation read_value reset_state"
DEC_PROPS="decoder_miter decoder_legal"
WB_PROPS="writeback_miter writeback_events"
CFG_LIST=$(echo "$CONFIGS" | tr ',' ' ')
CTL_CFG=$(echo "$CFG_LIST" | awk '{print $1}')
WBSUF=""; [ "$X0" = 1 ] && WBSUF=_x0

step "0. tools"
echo "$FORMAL_TOOL_REPORT"
if [ -n "$FORMAL_TOOLS_MISSING" ]; then
    echo "MISSING:$FORMAL_TOOLS_MISSING  -- see formal/README.md (Tools); nothing was run"
    echo "FORMAL HPM RESULT: FAIL (missing tools)"
    exit 2
fi
printf "    versions: %s | %s | bitwuzla %s | %s | %s | sv2v %s\n" \
    "$($SBY --help >/dev/null 2>&1 && echo sby ok)" "$(yosys -V 2>/dev/null | cut -d' ' -f1-2)" \
    "$(bitwuzla --version 2>/dev/null)" "$(yices-smt2 --version 2>/dev/null | head -1)" \
    "$(z3 --version 2>/dev/null)" "$(sv2v --version 2>/dev/null)"

rm -rf "$W"; mkdir -p "$W/runs" "$W/mut"
cp -r "$HERE/sby" "$HERE/props" "$W/"
: > "$W/runs/checks.txt"; : > "$W/runs/proofs.txt"; : > "$W/runs/controls.txt"; : > "$W/runs/times.txt"

step "1. the base copies, the ISS's legal CSR set"
for pair in "writeback_stage_base.sv rtl/writeback_stage.sv writeback_stage" \
            "instruction_decoder_base.sv rtl/instruction_decoder.sv instruction_decoder"; do
    set -- $pair
    r=$(python3 "$HERE/scripts/model.py" base "$REPO" "$BASE" "$HERE/base/$1" "$2" "$3")
    case "$r" in
        SAME)      echo "    base/$1 equals $BASE:$2 (module name apart)"; check "base_copy:$3" PASS REQ 0;;
        DIFFERENT) echo "    base/$1 DIFFERS from $BASE:$2"; check "base_copy:$3" FAIL REQ 0;;
        *)         echo "    base commit $BASE not available: base/$1 is not checked"
                   check "base_copy:$3" NOT-RUN AUX 0 "base commit not available";;
    esac
done
if [ -f "$SRC/test/trapsweep/iss.py" ]; then
    legal=$(python3 "$HERE/scripts/model.py" legal "$SRC/test/trapsweep/iss.py" | tr '\n' ' ')
    echo "    ISS legal CSR set: $(echo $legal | wc -w) addresses; 0x320 $(case " $legal " in *" 0x320 "*) echo present;; *) echo ABSENT;; esac)"
fi

step "2. formal models (sv2v with SYNTHESIS defined; observer and property include lines)"
mkdir -p "$W/gen"
GEN_OK=""
gen() {   # gen <model>: builds <model>.v, records the check
    local s; s=$(now)
    if python3 "$HERE/scripts/model.py" gen "$SRC" "$HERE" "$W/gen" "$1" > "$W/gen_$1.log" 2>&1; then
        check "gen:$1" PASS REQ "$(( $(now) - s ))"; GEN_OK="$GEN_OK $1"
    else
        check "gen:$1" FAIL REQ "$(( $(now) - s ))" "$(tail -1 "$W/gen_$1.log")"
    fi
    sed 's/^/    /' "$W/gen_$1.log"
}
wanted_any() { local p; for p in "$@"; do wanted "$p" && return 0; done; return 1; }
if wanted_any $UNIT_PROPS covers; then for c in $CFG_LIST; do gen "unit_$c"; done; fi
wanted_any $DEC_PROPS covers && gen decoder
wanted_any $WB_PROPS covers && gen writeback
HAS_HPM=0; grep -q '^`define F_HAS_HPM' "$W/gen/writeback.v" 2>/dev/null && HAS_HPM=1
( cd "$W/gen" && sha256sum *.v > SHA256SUMS 2>/dev/null )
sed 's/^/    sha256 /' "$W/gen/SHA256SUMS"

# ---- 3. the proofs, each with its ladder ----------------------------------------------------
step "3. proofs (k-induction; ladder: bitwuzla, Yices, z3, then bounded to $BMCD; ${PAR} at a time)"
: > "$W/runs/proof.jobs"
for c in $CFG_LIST; do
    for p in $UNIT_PROPS; do
        wanted "$p" && echo "${p}_$c unit unit_$c $p" >> "$W/runs/proof.jobs"
    done
done
for p in $DEC_PROPS; do wanted "$p" && echo "$p decoder decoder $p" >> "$W/runs/proof.jobs"; done
for p in $WB_PROPS; do
    wanted "$p" || continue
    if [ "$p" = writeback_events ] && [ "$HAS_HPM" = 0 ]; then
        check "$p" NOT-RUN AUX 0 "rtl/writeback_stage.sv has no counter unit i_hpm"
        continue
    fi
    echo "$p writeback writeback $p$WBSUF" >> "$W/runs/proof.jobs"
done
while read -r name sby model task; do
    case " $GEN_OK " in *" $model "*) ;; *) check "$name" ERROR REQ 0 "no model $model"; continue;; esac
    echo "$name $sby $model $task"
done < "$W/runs/proof.jobs" | xargs -P "$PAR" -L1 bash "$HERE/scripts/check.sh" "$W" "$LIMIT" "$BMCD"
sort "$W/runs/proofs.txt" -o "$W/runs/proofs.txt"
sed 's/^/    /' "$W/runs/proofs.txt"
while read -r name st rest; do
    wall=$(echo "$rest" | sed -n 's/.*wall=\([0-9]*\)s.*/\1/p')
    case "$st" in
        PASS) check "$name" PASS REQ "$wall" "$rest";;
        BOUNDED) case ",$ACCEPT," in
                     *",$name,"*) check "$name" PASS REQ "$wall" "bounded only, accepted: $rest";;
                     *)           check "$name" BOUNDED REQ "$wall" "bounded only, not accepted: $rest";;
                 esac;;
        *) check "$name" "$st" REQ "$wall" "$rest";;
    esac
done < "$W/runs/proofs.txt"

# ---- 4. covers --------------------------------------------------------------------------------
step "4. covers (every cover statement must be reached)"
if wanted covers; then
    : > "$W/runs/cover.jobs"
    case " $GEN_OK " in *" unit_$CTL_CFG "*) echo "unit unit_$CTL_CFG" >> "$W/runs/cover.jobs";; esac
    case " $GEN_OK " in *" decoder "*) echo "decoder decoder" >> "$W/runs/cover.jobs";; esac
    case " $GEN_OK " in *" writeback "*) echo "writeback writeback" >> "$W/runs/cover.jobs";; esac
    while read -r sby model; do
        s=$(now)
        sed -e "s#^\.\./gen/[a-z_]*_model\.v\$#../gen/$model.v#" \
            -e "s#^read_verilog -sv -formal [a-z_]*_model\.v\$#read_verilog -sv -formal $model.v#" \
            "$W/sby/$sby.sby" > "$W/sby/cover_$model.sby"
        bash "$REPO/formal/scripts/run_task.sh" "$W" "cover_$model.sby" covers "$LIMIT" COV > /dev/null
        lg="$W/runs/cover_${model}_covers.log"
        st=$(grep "^cover_${model}_covers " "$W/runs/times.txt" | tail -1 | awk '{print $2}')
        r=$(grep -a -c "Reached cover statement" "$lg" 2>/dev/null); u=$(grep -a -c "Unreached cover statement" "$lg" 2>/dev/null)
        echo "    covers $model: $st, $r reached, $u unreached"
        check "covers:$model" "$st" REQ "$(( $(now) - s ))" "$r reached, $u unreached"
    done < "$W/runs/cover.jobs"
fi

# ---- 5. negative controls --------------------------------------------------------------------
step "5. negative controls: each mutant must make its properties FAIL (same model and engine, bounded to $BMCD)"
if [ "$CONTROLS" = 1 ]; then
    python3 "$HERE/scripts/model.py" mutants "$MUTANTS" > "$W/runs/mutants.list" || exit 1
    : > "$W/runs/control.jobs"
    while read -r m props kind; do
        for p in ${props//,/ }; do
            wanted "$p" || continue
            case " $UNIT_PROPS " in
                *" $p "*) key="${p}_$CTL_CFG"; sby=unit; model="unit_$CTL_CFG"; task="$p";;
                *) case " $DEC_PROPS " in
                       *" $p "*) key="$p"; sby=decoder; model=decoder; task="$p";;
                       *) key="$p"; sby=writeback; model=writeback; task="$p$WBSUF";;
                   esac;;
            esac
            line=$(grep -E "^$key +(PASS|BOUNDED) " "$W/runs/proofs.txt" | head -1)
            if [ -z "$line" ]; then
                echo "    $m: $key was not proved, no control run"
                check "ctl:$m:$key" NOT-RUN CTL 0 "$key was not proved"
                continue
            fi
            # the engine that proved it, as a bounded check from reset to the ladder's bounded
            # depth: a control must give a concrete counterexample (FAIL), not only an induction
            # step that no longer closes
            eng=$(echo "$line" | sed -n 's/.*engine=\([a-z0-9]*\).*/\1/p')
            echo "$m $kind ctl:$m:$key $sby $model $task mut/$m/gen $eng bmc $BMCD" >> "$W/runs/control.jobs"
        done
    done < "$W/runs/mutants.list"
    # the mutated models, one directory per mutant
    for m in $(awk '{print $1}' "$W/runs/control.jobs" | sort -u); do
        kind=$(awk -v m="$m" '$1 == m {print $2; exit}' "$W/runs/control.jobs")
        models=$(awk -v m="$m" '$1 == m {print $5}' "$W/runs/control.jobs" | sort -u | tr '\n' ' ')
        md="$W/mut/$m"; mkdir -p "$md/gen"
        if [ "$kind" = defined ]; then
            python3 "$HERE/scripts/model.py" gen "$SRC" "$HERE" "$md/gen" --mutant "$m" --mutants "$MUTANTS" \
                $models > "$md/gen.log" 2>&1
        elif [ -n "$MUTCMD" ]; then
            rm -rf "$md/tree"
            $MUTCMD "$m" "$md/tree" > "$md/gen.log" 2>&1 &&
                python3 "$HERE/scripts/model.py" gen "$md/tree" "$HERE" "$md/gen" $models >> "$md/gen.log" 2>&1
        elif [ -f "$SRC/test/hpm/mutants.py" ]; then
            rm -rf "$md/tree"
            python3 "$SRC/test/hpm/mutants.py" apply --src "$SRC" "$m" "$md/tree" > "$md/gen.log" 2>&1 &&
                python3 "$HERE/scripts/model.py" gen "$md/tree" "$HERE" "$md/gen" $models >> "$md/gen.log" 2>&1
        else
            echo "mutant $m has no text in $(basename "$MUTANTS"), and there is no test/hpm/mutants.py or --mutant-cmd" \
                > "$md/gen.log"
        fi
    done
    awk '{print $3, $4, $5, $6, $7, $8, $9, $10}' "$W/runs/control.jobs" |
        xargs -P "$PAR" -L1 bash "$HERE/scripts/check.sh" "$W" "$LIMIT" "$BMCD"
    while read -r name st rest; do
        m=$(echo "$name" | cut -d: -f2)
        detail="$rest"
        [ "$st" = ERROR ] && [ -f "$W/mut/$m/gen.log" ] && detail="$rest $(tail -1 "$W/mut/$m/gen.log")"
        check "$name" "$st" CTL "$(echo "$rest" | sed -n 's/.*wall=\([0-9]*\)s.*/\1/p')" "$detail"
    done < "$W/runs/controls.txt"
    sort "$W/runs/controls.txt" -o "$W/runs/controls.txt"
    sed 's/^/    /' "$W/runs/controls.txt"
fi

# ---- summary ---------------------------------------------------------------------------------
step "SUMMARY ($(( $(now) - START )) s)"
{
    echo "formal/hpm/run.sh  $(date '+%F %T')  sources: $SRC"
    [ -f "$W/gen/SHA256SUMS" ] && sed 's/^/  sha256 /' "$W/gen/SHA256SUMS"
    echo
    echo "Proofs (check status engine mode depth):"
    sed 's/^/  /' "$W/runs/proofs.txt"
    echo
    printf "%-34s %-13s %-4s %10s  %s\n" CHECK STATUS CLASS WALL DETAIL
    cat "$W/runs/checks.txt"
    echo
    bad_req=$(awk '$3 == "REQ" && $2 != "PASS" {print $1":"$2}' "$W/runs/checks.txt" | tr '\n' ' ')
    bad_ctl=$(awk '$3 == "CTL" && $2 != "FAIL" {print $1":"$2}' "$W/runs/checks.txt" | tr '\n' ' ')
    n_req=$(awk '$3 == "REQ"' "$W/runs/checks.txt" | wc -l)
    n_ctl=$(awk '$3 == "CTL"' "$W/runs/checks.txt" | wc -l)
    echo "required checks: $n_req, not PASS: ${bad_req:-none}"
    echo "negative controls: $n_ctl, not FAIL (as required): ${bad_ctl:-none}"
    [ "$CONTROLS" = 0 ] && echo "negative controls skipped (--no-controls)"
    if [ -z "$bad_req" ] && [ -z "$bad_ctl" ] && [ "$CONTROLS" = 1 ] && [ "$n_req" -gt 0 ] && [ "$n_ctl" -gt 0 ]; then
        echo "FORMAL HPM RESULT: PASS"
    else
        why=""
        [ -n "$bad_req" ] && why="required checks not PASS: ${bad_req% }"
        [ -n "$bad_ctl" ] && why="${why:+$why; }controls not FAIL: ${bad_ctl% }"
        [ "$CONTROLS" = 0 ] && why="${why:+$why; }negative controls not run"
        [ "$CONTROLS" = 1 ] && [ "$n_ctl" = 0 ] && why="${why:+$why; }no negative control ran"
        echo "FORMAL HPM RESULT: FAIL ($why)"
    fi
} | tee "$OUT/SUMMARY.txt"
grep -q "^FORMAL HPM RESULT: PASS" "$OUT/SUMMARY.txt"
