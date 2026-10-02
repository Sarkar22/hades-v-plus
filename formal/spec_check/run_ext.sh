#!/bin/bash
# run_ext.sh [n_random]: simulate props/ext_spec.vh with Verilator and compare it
# against the independent Python model in check_ext_spec.py (corner vectors, every
# shift amount, + n_random random vectors, default 1e6). Run from a work copy
# (run.sh does this): the Verilator model is built in ./obj_ext next to this script.
set -e; cd "$(dirname "$0")"
verilator --cc --exe --build -j 4 -Wno-fatal -Wno-WIDTH -I../props ext_spec_top.v ext_tb.cpp --Mdir obj_ext -o Vext_spec_top >/dev/null
python3 check_ext_spec.py ${1:-1000000}
