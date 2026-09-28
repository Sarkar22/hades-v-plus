#!/bin/bash
# run.sh [n_random]: simulate props/spec.vh (both formulations) with Verilator and
# compare against the independent Python model in check_spec.py (corner vectors +
# n_random random vectors, default 1e6). Run from a work copy (run.sh does this):
# the Verilator model is built in ./obj next to this script.
set -e; cd "$(dirname "$0")"
verilator --cc --exe --build -j 4 -Wno-fatal -I../props spec_top.v tb.cpp --Mdir obj -o Vspec_top >/dev/null
python3 check_spec.py ${1:-1000000}
