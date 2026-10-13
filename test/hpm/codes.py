#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""codes.py -- the event codes of the performance counters, in the places that must agree.

    python3 test/hpm/codes.py [--tree DIR]

The codes are never renumbered or reused. This script compares
  * std/include/hpm.h        the #define HPM_EV_<NAME> <code> lines (software),
  * sim/top.sv               the names the +hpm_stats monitor prints (function hm_name), and
  * defines/hpm.sv           the package of the RTL, if the tree has it: every constant whose name,
                             without a prefix EV_ or HPM_EV_ and in any case, is a name of the header
and prints the differences. Exit status 0 when they agree.
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))


def header(tree):
    text = open(os.path.join(tree, "std", "include", "hpm.h")).read()
    return {m.group(1): int(m.group(2)) for m in re.finditer(r"^#define\s+HPM_EV_(\w+)\s+(\d+)u?\b", text, re.M)}


def monitor(tree):
    text = open(os.path.join(tree, "sim", "top.sv")).read()
    start = text.find("function automatic string hm_name")
    if start < 0:
        return None
    end = text.find("endfunction", start)
    return {m.group(2): int(m.group(1)) for m in re.finditer(r"(\d+):\s*return\s*\"(\w+)\"", text[start:end])}


def package(tree):
    path = os.path.join(tree, "defines", "hpm.sv")
    if not os.path.exists(path):
        return None
    text = open(path).read()
    out = {}
    for m in re.finditer(r"\b(?:EV_|HPM_EV_)?([A-Za-z][A-Za-z0-9_]*)\s*=\s*(?:\d+'[dD])?(\d+)\b", text):
        out[m.group(1).upper()] = int(m.group(2))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tree", default=REPO)
    a = ap.parse_args()
    h = header(a.tree)
    bad = []
    if len(set(h.values())) != len(h):
        bad.append("the header gives one code to two names")
    for name, code in sorted(h.items(), key=lambda x: x[1]):
        if not 0 <= code <= 255:
            bad.append(f"hpm.h: {name} = {code} is not an 8-bit code")
    mon = monitor(a.tree)
    if mon is None:
        print("sim/top.sv: no monitor (hm_name) in this tree: not compared")
    else:
        for name, code in mon.items():
            if name.startswith("CODE"):
                continue
            if h.get(name) != code:
                bad.append(f"sim/top.sv prints {name} for code {code}; hpm.h says {h.get(name)}")
        for name, code in h.items():
            if (1 <= code <= 26 or 32 <= code <= 49 or code in (160, 161)) and name != "NONE" and mon.get(name) != code:
                bad.append(f"hpm.h: {name} = {code} is not in the monitor's table")
    pkg = package(a.tree)
    if pkg is None:
        print("defines/hpm.sv: not in this tree: not compared")
    else:
        n = 0
        for name, code in pkg.items():
            if name in h:
                n += 1
                if h[name] != code:
                    bad.append(f"defines/hpm.sv: {name} = {code}; hpm.h says {h[name]}")
        if n == 0:
            bad.append("defines/hpm.sv: no constant with the name of an event of hpm.h")
        for name in h:
            if name != "NONE" and name not in pkg:
                bad.append(f"hpm.h: {name} is not in defines/hpm.sv")
    for b in bad:
        print("DIFFERS: " + b)
    print(f"CODES: {len(h)} codes in hpm.h; " + ("they agree" if not bad else f"{len(bad)} difference(s)"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
