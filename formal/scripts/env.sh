# formal/scripts/env.sh -- sourced by formal/run.sh with OUT set (the output directory).
#
# Finds the tools and makes them available under the names SBY and yosys-smtbmc
# expect, WITHOUT relying on any path in this repository being executable (the
# repository may live on a noexec disk; everything executable is created in $OUT).
#
#   HADES_FORMAL_ENV   optional file sourced first (e.g. a script that puts a tool
#                      installation on PATH); sourced before anything else
#   SBY                SymbiYosys command: default `sby` (OSS CAD Suite), else `yowasp-sby`
#   yosys, yosys-smtbmc: taken from PATH; if missing, `yowasp-yosys` /
#                      `yowasp-yosys-smtbmc` are wrapped under those names
#   BITWUZLA, YICES_SMT2, Z3: solver binaries (default: `bitwuzla`, `yices-smt2`,
#                      `z3` on PATH). They are wrapped in $OUT/bin with a memory cap
#                      (ulimit -v $SOLVER_VMEM_KB, default 4000000 KiB) and nice.
#   SV2V, VERILATOR    default `sv2v`, `verilator` on PATH
if [ -n "${HADES_FORMAL_ENV:-}" ]; then
    # shellcheck disable=SC1090
    source "$HADES_FORMAL_ENV" || { echo "cannot source HADES_FORMAL_ENV=$HADES_FORMAL_ENV"; return 1; }
fi
mkdir -p "$OUT/bin"

_fe_missing=""
_fe_resolve() {   # _fe_resolve <explicit-value> <name>...  -> absolute path of the first found
    local v="$1"; shift
    if [ -n "$v" ]; then command -v "$v" 2>/dev/null && return 0; echo ""; return 1; fi
    local n; for n in "$@"; do
        local p; p=$(command -v "$n" 2>/dev/null) && { echo "$p"; return 0; }
    done
    echo ""; return 1
}
_fe_wrap() {      # _fe_wrap <name> <target> [memcap]
    local name="$1" target="$2" cap="${3:-}"
    {
        echo '#!/bin/bash'
        [ -n "$cap" ] && echo 'ulimit -v ${SOLVER_VMEM_KB:-4000000}'
        [ -n "$cap" ] && echo "exec nice -n 10 \"$target\" \"\$@\"" || echo "exec \"$target\" \"\$@\""
    } > "$OUT/bin/$name"
    chmod +x "$OUT/bin/$name"
}

# --- SymbiYosys / Yosys ------------------------------------------------------------------
_sby=$(_fe_resolve "${SBY:-}" sby yowasp-sby)            || _fe_missing="$_fe_missing sby/yowasp-sby"
_yosys=$(_fe_resolve "" yosys yowasp-yosys)              || _fe_missing="$_fe_missing yosys/yowasp-yosys"
_smtbmc=$(_fe_resolve "" yosys-smtbmc yowasp-yosys-smtbmc) || _fe_missing="$_fe_missing yosys-smtbmc"
[ -n "$_yosys" ]  && [ "$(basename "$_yosys")" != yosys ]         && _fe_wrap yosys "$_yosys"
[ -n "$_smtbmc" ] && [ "$(basename "$_smtbmc")" != yosys-smtbmc ] && _fe_wrap yosys-smtbmc "$_smtbmc"
_w=$(_fe_resolve "" yosys-witness yowasp-yosys-witness) && [ "$(basename "$_w")" != yosys-witness ] && _fe_wrap yosys-witness "$_w"

# --- solvers (always wrapped: memory cap + nice) -----------------------------------------
_bw=$(_fe_resolve "${BITWUZLA:-}" bitwuzla)     || _fe_missing="$_fe_missing bitwuzla"
_yi=$(_fe_resolve "${YICES_SMT2:-}" yices-smt2) || _fe_missing="$_fe_missing yices-smt2"
_z3=$(_fe_resolve "${Z3:-}" z3)                 || _fe_missing="$_fe_missing z3"
# never wrap our own wrapper (a second run with $OUT/bin already on PATH)
case "$_bw" in "$OUT/bin/"*) _bw=$(sed -n 's/^exec nice -n 10 "\(.*\)" "\$@"$/\1/p' "$_bw");; esac
case "$_yi" in "$OUT/bin/"*) _yi=$(sed -n 's/^exec nice -n 10 "\(.*\)" "\$@"$/\1/p' "$_yi");; esac
case "$_z3" in "$OUT/bin/"*) _z3=$(sed -n 's/^exec nice -n 10 "\(.*\)" "\$@"$/\1/p' "$_z3");; esac
[ -n "$_bw" ] && _fe_wrap bitwuzla   "$_bw" cap
[ -n "$_yi" ] && _fe_wrap yices-smt2 "$_yi" cap
[ -n "$_z3" ] && _fe_wrap z3         "$_z3" cap

# --- sv2v, Verilator, python3 ------------------------------------------------------------
_sv2v=$(_fe_resolve "${SV2V:-}" sv2v)             || _fe_missing="$_fe_missing sv2v"
[ -n "$_sv2v" ] && [ "$(basename "$_sv2v")" != sv2v ] && _fe_wrap sv2v "$_sv2v"
_vl=$(_fe_resolve "${VERILATOR:-}" verilator)     || _fe_missing="$_fe_missing verilator"
[ -n "$_vl" ] && [ "$(basename "$_vl")" != verilator ] && _fe_wrap verilator "$_vl"
command -v python3 >/dev/null || _fe_missing="$_fe_missing python3"

export PATH="$OUT/bin:$PATH"
export SBY="$_sby"
FORMAL_TOOLS_MISSING="$_fe_missing"
FORMAL_TOOL_REPORT=$(
    printf "    %-14s %s\n" sby "${_sby:-MISSING}"
    printf "    %-14s %s\n" yosys "${_yosys:-MISSING}"
    printf "    %-14s %s\n" yosys-smtbmc "${_smtbmc:-MISSING}"
    printf "    %-14s %s\n" bitwuzla "${_bw:-MISSING}"
    printf "    %-14s %s\n" yices-smt2 "${_yi:-MISSING}"
    printf "    %-14s %s\n" z3 "${_z3:-MISSING}"
    printf "    %-14s %s\n" sv2v "${_sv2v:-MISSING}"
    printf "    %-14s %s\n" verilator "${_vl:-MISSING}"
)
unset -f _fe_resolve _fe_wrap
