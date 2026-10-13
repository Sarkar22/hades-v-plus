# SPDX-License-Identifier: MIT
# props.sh -- sourced by formal/cache/run.sh, scripts/ladder.sh, scripts/control.sh and
# scripts/sim.sh: the bounded properties, their configurations, depths, .sby files and models
# (formal/cache/README.md, sections 4 and 10).

# The I-cache and the arbiter (harness/cache_top.sv, cache_pair_top.sv): configurations tiny and
# second
PROPS_TINY="fetch_data line_data window ack_err answer_req grant_route refill_no_write grant_kept bound bound_cpu reset_state store_fetch refill_window refill_stable store_once data_indep"
PROPS_SECOND="fetch_data line_data window reset_state store_fetch refill_window refill_stable"
# Both caches, the arbiter and the memory (harness/memsys_top.sv, memsys_pair_top.sv):
# configurations tiny, nowait (tiny with writes answered without waits) and second
ID_PROPS_TINY="load_data dline_data store_mem id_refill_no_write dfill_kept dbound dbound_cpu dack_req dwindow drefill_stable dreset_state ddata_indep id_fetch_data id_store_fetch"
ID_PROPS_NOWAIT="dbound dbound_cpu store_mem dreset_state"
ID_PROPS_SECOND="load_data dline_data store_mem dreset_state dbound_cpu"
# Unbounded proofs by induction (fallback: a bounded check): the interconnect's mask and the
# arbiter's equivalence with the base commit's
IC_CHECKS="ic_default ic_ram_exempt ic_io_timeout"
EQ_CHECKS="arb_equiv"

is_id_prop() { case " $ID_PROPS_TINY " in *" $1 "*) return 0;; esac; return 1; }

# prop_sby <property>: the .sby file (without .sby) of its proof on the full harness
prop_sby() {
    case "$1" in
        data_indep)  echo pair;;
        ddata_indep) echo memsys_pair;;
        *)           if is_id_prop "$1"; then echo memsys; else echo cache; fi;;
    esac
}
# prop_split <property>: the .sby file of its decomposed harness
prop_split() { if is_id_prop "$1"; then echo dsplit; else echo split; fi; }
# stated_depth <property> <configuration>
stated_depth() {
    if is_id_prop "$1"; then
        case "$2" in second) echo 30;; *) echo 50;; esac
    else
        case "$2" in second) echo 30;; *) echo 40;; esac
    fi
}
# min_depth <property>: the minimum depth of the ladder's step 2 (the caller caps it at the
# stated depth of the configuration)
min_depth() {
    if is_id_prop "$1"; then
        case "$1" in
            load_data|dline_data|id_fetch_data|id_store_fetch) echo 40;;
            dreset_state) echo 20;;
            *) echo 25;;
        esac
    else
        case "$1" in
            fetch_data|line_data|store_fetch) echo 35;;
            reset_state) echo 18;;
            *) echo 20;;
        esac
    fi
}
# model_of <property> <configuration> <narrow 0|1>: the model its full-harness proof reads
model_of() {
    local p="$1" c="$2" n="" size=tiny nw="" fl="" h
    [ "$c" = second ] && size=second
    [ "$c" = nowait ] && nw=_nowait
    [ "$3" = 1 ] && n=_narrow
    case "$p" in
        data_indep)  h=pair;;
        ddata_indep) h=mpair;;
        *)           if is_id_prop "$p"; then h=memsys; else h=cache; fi;;
    esac
    case "$p" in
        bound_cpu|dbound_cpu)        fl=_cpu;;
        dack_req|dwindow|drefill_stable) fl=_free;;
    esac
    echo "${h}_${size}${nw}${n}${fl}"
}
# split_models <property> <configuration>: the models of its decomposed harness
split_models() {
    local size=tiny nw=""
    [ "$2" = second ] && size=second
    [ "$2" = nowait ] && nw=_nowait
    if is_id_prop "$1"; then
        echo "dcache_${size}${nw} dcache_${size}${nw}_free icache_${size} arbid_${size}${nw}"
    else
        echo "icache_${size} arbiter_${size} arbiter_${size}_cpu"
    fi
}
# narrow_sed: the sed expression that turns the models of a .sby file into those of the
# narrower memory (_narrow after the size and the write mode)
NARROW_SED='s/\b\(cache\|pair\|memsys\|mpair\)_\(tiny\|second\)\(_nowait\)\{0,1\}\(_cpu\|_free\)\{0,1\}\.v/\1_\2\3_narrow\4.v/g'
