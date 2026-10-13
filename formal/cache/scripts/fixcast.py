#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""fixcast.py <model.v> <out.v>

sv2v writes a size cast of a constant as a function ("function automatic [W-1:0] sv2v_cast_<hash>;
input reg [W-1:0] inp; sv2v_cast_<hash> = inp;"), and calls it in a localparam. The proofs'
tools accept that; Verilator 5.042 refuses a constant function declared under a generate block.
This copies the model with every such identity cast replaced by the size cast it stands for
(W'(expr)) and its function removed, which Verilator accepts and which means the same. Casts
of other shapes (sv2v_cast_32, sv2v_cast_32_signed, ...) stay as they are.
"""
import re
import sys

FUNC = re.compile(
    r"[ \t]*function automatic \[(\d+):0\] (sv2v_cast_[0-9A-F]+);\s*"
    r"input reg \[\1:0\] inp;\s*"
    r"\2 = inp;\s*"
    r"endfunction[ \t]*\n")


def main():
    text = open(sys.argv[1]).read()
    names = {}

    def drop(m):
        names[m.group(2)] = int(m.group(1)) + 1
        return ""
    text = FUNC.sub(drop, text)
    for name, width in names.items():
        text = re.sub(r"\b%s\s*\(" % name, "%d'(" % width, text)
    open(sys.argv[2], "w").write(text)
    print("fixcast: %d identity casts replaced" % len(names))


main()
