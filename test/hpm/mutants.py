#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""mutants.py -- the mutation campaign of the hardware performance counters.

Every mutant is a source patch, applied to a temporary copy of the tree (never to this checkout),
with its own build directory. The checks that must catch it run in that copy and the mutant is
reported as CAUGHT (with the first check that caught it) or MISSED:

    python3 test/hpm/mutants.py list [-v]                  every mutant: file, checks that must catch it
    python3 test/hpm/mutants.py anchors [<name>...]        do the patches find their text in this tree?
    python3 test/hpm/mutants.py show <name>                the diff that a mutant applies
    python3 test/hpm/mutants.py baseline [--layers a,b]    run the checks on the unchanged tree
    python3 test/hpm/mutants.py run [<name>...|all] [--jobs N] [--out DIR] [--keep] [--layers a,b]
    python3 test/hpm/mutants.py dryrun [<name>...]         apply each patch in a temporary copy, check
                                                           that the copy still builds, discard it
    python3 test/hpm/mutants.py apply [--src TREE] [--subset DIR,...] <name> <dir>
                                                           write a copy of the tree with one mutant applied

The campaign has a runner of its own: formal/scripts/mutate.py and run_mutants.sh are wired to the
Execute stage's formal model and are fingerprinted by the record of make formal, so they are not used
here, and nothing in formal/scripts/ is edited.

ANCHORS. A patch is a list of (file, regular expression, replacement, expected number of matches), as in
test/memsys/mutants.py; a patch whose expression does not match exactly that often is not applied, and
the mutant is reported as 'ANCHOR MISSING' (never as CAUGHT or MISSED). The patches of this file are
written against the code as it is: the counter unit rtl/hpm.sv (cnt_next, sel, inhibit, ev, pipe_s2,
trap_s2), the events built in rtl/hpm_events.sv, the Writeback stage's retire, trap and predictor
signals (hpm_ev_a, hpm_trap, bp_rec1, bp_rec2), the counter block of rtl/mcu.sv (hpm_ext,
hpm_ext_present) and the monitors of sim/top.sv (hm_*). 'anchors' shows which of them match the tree;
a patch whose text does not find its anchor is fixed here to the code as it is, never by changing the
design. 'dryrun' applies each patch to a copy of the tree and lints the standard simulator and a
simulator with an instruction cache.

CHECKS ('layers'). Each is a command in the copy; it must pass on the unchanged tree ('baseline'), and
it catches a mutant when it then fails:
    unit         make test/sv/test_hpm: the bench of the counter unit against its model
    formal       make formal-hpm: the proofs of the unit, of the decoder and of the Writeback stage
    legal        make csr-legal-check: the decoder's legality map against the ISS's
    hpm          test/asm/hpm.s on HaDes-V+ (every event provoked a known number of times)
    hpmirq       test/asm/hpmirq.s (the counters at every position of an interrupt)
    bpsquash     test/asm/bpsquash.s (the predictor's counters count retired branches)
    hpmwait      test/memsys/hpmwait.s with a slow memory (MEM_LAT=2)
    hpmcache     test/memsys/hpmcache.s with an instruction cache (ICACHE=512 MEM_LAT=2)
    check-<A..I> test programs in a simulator whose selectors reset to the preset <A..I> (make
                 HPM_PRESET=<letter>), with +hpm_check: caught when the model of sim/top.sv stops the run
    gate         test/hpm/identities.py on the HPM lines (+hpm_stats) of a few programs (the line holds the totals of
                 the monitor's model, so it checks the testbench and the programs, not the events of rtl/hpm_events.sv)
    cache        the counters of the cache events against CACHE_STATS (HPM_PRESET=H and I with ICACHE=512)
    sweep        sweep.py run --fam hpm --targets dut: caught when a program is not ISS-consistent
A program passes a check when its output has the line 'All tests passed! (# Errors: 1 = initial test)'.
"""
import argparse
import concurrent.futures as cf
import difflib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.dont_write_bytecode = True

# the helpers of the campaign of the memory system (patches, copies of the tree, the clean environment)
_spec = importlib.util.spec_from_file_location("memsys_mutants", os.path.join(REPO, "test", "memsys", "mutants.py"))
mm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mm)
apply, copy_tree, clean_env, sh = mm.apply, mm.copy_tree, mm.clean_env, mm.sh

HPM, EVENTS, WB, DEC, DECODER, MCU, TOP = ("rtl/hpm.sv", "rtl/hpm_events.sv", "rtl/writeback_stage.sv", "rtl/decode_stage.sv",
                                           "rtl/instruction_decoder.sv", "rtl/mcu.sv", "sim/top.sv")
PKG = "defines/hpm.sv"
PASSED = "All tests passed! (# Errors: 1 = initial test)"

PROGRAMS_FOR_PRESETS = ["test/asm/ops", "test/asm/csrirq", "test/asm/trapirq", "test/asm/mul", "test/asm/div", "test/asm/memirq"]
IDENTITY_PROGRAMS = ["test/asm/ops", "test/asm/csrirq", "test/asm/trapirq", "test/asm/memirq", "test/asm/bpirq"]


def added_logic(f, decl, body=""):
    """Patches that add a mutant's own signals to a module: their declarations right after the port
    list and their logic before endmodule."""
    return mm.added_logic(f, decl, body)


def m(name, what, patches, layers, also="", left_out=False):
    return dict(name=name, what=what, patches=patches, layers=layers, also=also, left_out=left_out)


# ------------------------------------------------------------------------------ the mutants
MUTANTS = [
    m("event-tied-to-zero", "One raw retirement event (LOAD) is tied to 0.",
      [(WB, r"(hpm_ev_a\[hpm_pkg::EV_LOAD\]\s*=\s*)[^;]+;", r"\g<1>1'b0;", 1)],
      ["hpm", "check-B"], "the unit bench drives the unit's inputs, not Writeback's wiring"),
    m("increment-adds-two", "A counter that sees an event adds 2.",
      [(HPM, r"(cnt_next\[n\]\s*=\s*cnt_64\[n\]\s*\+\s*)64'\((ev\[sel\[n\]\]\s*&&\s*!inhibit\[n\])\);", r"\g<1>{62'b0, \g<2>, 1'b0};", 1)],
      ["unit", "formal", "hpm"]),
    m("inhibit-ignored-for-counter-5", "The inhibit bit of the third programmable counter (HPM5) is ignored.",
      [(HPM, r"(64'\(ev\[sel\[n\]\]\s*&&\s*)!inhibit\[n\]\)", r"\g<1>(!inhibit[n] || n == 5))", 1)],
      ["unit", "formal", "hpm"]),
    m("increment-beats-write", "A write to a counter loses when an event arrives in the same cycle (the increment is kept).",
      [(HPM, r"if \(csr_we && is_lo && idx == 4'\(n\)\)", "if (csr_we && is_lo && idx == 4'(n) && !(ev[sel[n]] && !inhibit[n]))", 1),
       (HPM, r"else if \(csr_we && is_hi && idx == 4'\(n\) && W > 32\)", "else if (csr_we && is_hi && idx == 4'(n) && W > 32 && !(ev[sel[n]] && !inhibit[n]))", 1)],
      ["unit", "formal", "hpm"], "'write wins' in hpm.s"),
    m("selector-not-legalised", "A selector keeps any 8-bit value that is written (no check against the codes of the build).",
      [(HPM, r"hpm_pkg::legal\(csr_wdata, hpm_ext_present\)\s*\?\s*csr_wdata\[7:0\]\s*:\s*8'd0", "csr_wdata[7:0]", 1)],
      ["unit", "formal", "hpm"]),
    m("b2-event-one-cycle-late", "A class B2 event reaches its counter one cycle later than it should (a third stage).",
      [*added_logic(HPM, "    // (mutation) a third stage for the class B2 pipeline events\n    logic [46:32] mut_pipe_s3;",
                    "    always_ff @(posedge clk) mut_pipe_s3 <= rst ? '0 : pipe_s2;"),
       (HPM, r"(ev\[46:32\]\s*=\s*)pipe_s2;", r"\g<1>mut_pipe_s3;", 1)],
      ["unit", "formal", "check-A", "gate"], "the partition over a counter window; hpm.s ('IO_ACCESS visible' for the B1 case)"),
    m("b1-event-two-cycles-late", "A class B1 event reaches its counter two cycles later than it should.",
      [*added_logic(HPM, "    // (mutation) a second stage for the class B1 events\n    logic [49:47] mut_b1_late;",
                    "    always_ff @(posedge clk) mut_b1_late <= rst ? '0 : late.b1;"),
       (HPM, r"(ev\[49:47\]\s*=\s*)late\.b1;", r"\g<1>mut_b1_late;", 1)],
      ["unit", "formal", "hpm", "check-F"], "hpm.s: an access to a register that answers at once is already counted for the next instruction"),
    m("select-index-off-by-one", "Counter n selects its event with the selector of counter n + 1.",
      [(HPM, r"ev\[\s*sel\[\s*n\s*\]\s*\]", "ev[sel[(n == 9) ? 3 : n + 1]]", 1)],
      ["unit", "formal", "hpm"], "hpm.s gives each counter a different count"),
    m("hpm-ext-bits-swapped", "Two bits of the memory-system vector in rtl/mcu.sv are swapped (IC_LOOKUP_HIT and IC_MISS).",
      [(MCU, r"cache_ev_i_beat,\s*cache_ev_i_miss,\s*cache_ev_i_hit\s*\}", "cache_ev_i_beat, cache_ev_i_hit, cache_ev_i_miss}", 1)],
      ["cache", "hpmcache"]),
    m("retire-without-replay-gate", "The unit's retirement event counts a replayed instruction too.",
      [(WB, r"(hpm_ev_a\[hpm_pkg::EV_INSTRET\]\s*=\s*)retire;", r"\g<1>is_valid;", 1)],
      ["hpmirq", "gate", "check-B"]),
    m("predictor-events-not-gated-by-retirement", "The predictor events count a branch that is squashed after Execute.",
      [(WB, r"bp_retire_branch\s*&&\s*bp_rec2\.valid", "bp_rec2.valid", 4)],
      ["bpsquash", "gate", "check-E"]),
    m("predictor-record-one-stage", "The predictor's record is delayed by one stage instead of two.",
      [(WB, r"bp_rec2 <= bp_rec1;", "bp_rec2 <= '{valid: bp_feedback_in.valid, predicted_taken: bp_feedback_in.predicted_taken, was_taken: bp_feedback_in.was_taken};", 1)],
      ["bpsquash", "gate", "check-E"]),
    m("csrrs-x0-writes", "csrrs and csrrc with rs1 = x0 write the counters (the rs1 field is not looked at).",
      [(WB, r"\s*&&\s*instruction_in\.rs1_address\s*!=\s*5'b0+", "", 1)],
      ["hpm", "check-A"]),
    m("high-half-not-masked", "The high half of a counter reads one bit more than W - 32 bits (bit 16 of the high half reads 1).",
      [(HPM, r"(rdata\s*=\s*cnt_64\[n\]\[63:32\])\s*;", r"\g<1> | 32'h0001_0000;", 1)],
      ["unit", "formal", "hpm"]),
    m("inhibit-register-too-wide", "mcountinhibit keeps TM (bit 1) and bits above 13.",
      [(HPM, r"(localparam bit \[31:0\] IMPL_MASK = )32'h0000_3C05", r"\g<1>32'hFFFF_3C07", 1)],
      ["unit", "formal", "hpm"]),
    m("decoder-wrong-address", "The decoder accepts 0x321 and rejects 0x320.",
      [(DECODER, r"12'h320", "12'h321", 1)],
      ["formal", "hpm", "legal", "sweep"]),
    m("minstret-ignores-ir", "minstret ignores the IR bit of mcountinhibit.",
      [(WB, r"\s*&&\s*!\s*inh_ir\b", "", 1)],
      ["hpm", "sweep", "check-B"]),
    m("hazard-load-uses-csr-hazard", "HAZARD_LOAD is Decode's CSR-use hazard instead of its load-use hazard.",
      [(DEC, r"(assign\s+load_use_hazard_out\s*=\s*)load_use_hazard;", r"\g<1>csr_use_hazard;", 1)],
      ["hpm", "check-F"]),
    m("memwait-load-store-swapped", "MEMWAIT_LOAD and MEMWAIT_STORE swap their conditions.",
      [(EVENTS, r"(EV_MEMWAIT_LOAD\]\s*=\s*memwait_any\s*&&\s*)r_e_load", r"\g<1>r_e_store", 1),
       (EVENTS, r"(EV_MEMWAIT_STORE\]\s*=\s*memwait_any\s*&&\s*)r_e_store", r"\g<1>r_e_load", 1)],
      ["hpm", "check-F", "gate"]),
    m("io-access-counts-ram", "IO_ACCESS also counts accesses to the RAM.",
      [(EVENTS, r"(EV_IO_ACCESS\]\s*=\s*r_valid\s*&&\s*r_start)\s*&&\s*!r_in_ram", r"\g<1>", 1)],
      ["hpm", "check-F"]),
    m("exception-from-redirect", "EXCEPTION is counted from Writeback's JUMP instead of the trap entry.",
      [(WB, r"(hpm_trap\[hpm_pkg::EV_EXCEPTION\]\s*=\s*)exception_taken;", r"\g<1>(status_backwards_out == pipeline_status::JUMP);", 1)],
      ["gate", "hpm", "check-D"]),
    # Only hpmwait can catch this one: it needs a fetch port that waits in a cycle in which the M unit holds
    # Execute (Decode holds a bubble and tells Fetch READY), so the standard build cannot show it (check-A
    # runs there), and the gate reads the totals of the monitor's own model, which the patch does not touch.
    m("fetch-wait-without-ready", "FETCH_WAIT without the condition that Execute is ready (the overlapping definition).",
      [(EVENTS, r"(fetch_wait\s*=\s*r_valid\s*&&\s*)r_e == READY\s*&&\s*", r"\g<1>", 1)],
      ["hpmwait", "check-A", "gate"]),
    m("timer-external-swapped", "INT_TIMER and INT_EXT swap.",
      [(WB, r"(hpm_trap\[hpm_pkg::EV_INT_TIMER\]\s*=\s*interrupt_taken\s*&&\s*)!ext_int_pending", r"\g<1>ext_int_pending", 1),
       (WB, r"(hpm_trap\[hpm_pkg::EV_INT_EXT\]\s*=\s*interrupt_taken\s*&&\s*)ext_int_pending", r"\g<1>!ext_int_pending", 1)],
      ["hpm", "check-D"]),
    m("fixed-selectors-read-zero", "mhpmevent11..13 read 0 again.",
      [(HPM, r"rdata = \{24'b0, hpm_pkg::EV_BP_NN \+ 8'\(idx - 4'd10\)\};", "rdata = 32'd0;", 1)],
      ["hpm", "unit", "sweep"]),
    m("interrupt-enable-value-or-for-clear", "The restructured mstatus write value that Writeback uses for the interrupt enables ORs for CSRRC.",
      [(WB, r"(CSRRC, CSRRCI:\s*return\s*)old_bit\s*&\s*~src_bit;", r"\g<1>old_bit | src_bit;", 1)],
      ["formal", "sweep"]),
    m("present-mask-all-ones", "The standard build says that all memory-system codes exist.",
      [(MCU, r"(hpm_ext_present\s*=\s*)32'b0;", r"\g<1>32'hFFFF_FFFF;", 1)],
      ["hpm", "unit"]),
    m("cache-compare-without-pending-event", "The comparison of the counters with CACHE_STATS forgets the event in the delay register (a mutant of the monitor).",
      [(TOP, r"have = hm_cnt\[k\] \+ \(\(!hm_inh\[3 \+ k\] && hm_last_ext\[code - 128\]\) \? 1 : 0\);", "have = hm_cnt[k];", 1)],
      ["cache"]),
    # A mutant that cannot change behaviour, left out on purpose: the bits 12 to 31 of the memory-system vector
    # are tied to 0 in rtl/mcu.sv and are masked by the present mask, so tying them to 1 changes nothing.
    m("unused-memory-system-bits", "Bits 12 to 31 of the memory-system vector tied to 1.",
      [(MCU, r"(hpm_ext\s*=\s*)32'b0;", r"\g<1>32'hFFFF_FFFF;", 1)],
      [], "the present mask is 0 for those bits, so the unit never looks at them", left_out=True),
]


# ------------------------------------------------------------------------------ the checks
def make(root, args, timeout=None):
    return sh(["make", "-s", "--no-print-directory"] + args, root, timeout)


def program_check(root, prog, extra=()):
    rc, text = make(root, [prog] + list(extra) + ["SIM_ARGS=+nodump"])
    ok = rc == 0 and PASSED in text
    # (the first 'Test fail!' of every run is the deliberate initial one)
    fails = [l for l in text.splitlines() if "Test fail!" in l][1:]
    summary = next((l for l in text.splitlines() if "test(s) failed" in l or "Simulation timeout" in l), None)
    line = (fails[0].strip() + (f" ({summary.strip()})" if summary else "")) if fails else summary
    why = "passed" if ok else (f"{line}" if line else text.strip().splitlines()[-1][:120] if text.strip() else "no output")
    return ok, why


def check_preset(root, preset):
    """test programs in the simulator with the selectors reset to the preset, with +hpm_check"""
    cfg = ["HPM_PRESET=" + preset] + (["ICACHE=512", "MEM_LAT=2"] if preset in "HI" else [])
    for prog in PROGRAMS_FOR_PRESETS:
        rc, text = make(root, [prog] + cfg + ["SIM_ARGS=+nodump +hpm_check +hpm_stats"])
        bad = next((l for l in text.splitlines() if "HPM CHECK" in l or "HPM_PRESET" in l or "%Error" in l or "%Fatal" in l), None)
        if rc or bad or "HPM_CHECK ok" not in text:
            return False, f"{prog} preset {preset}: {(bad or text.strip().splitlines()[-1] if text.strip() else 'no output')[:150]}"
    return True, "passed"


def check_gate(root):
    for prog in IDENTITY_PROGRAMS:
        rc, text = make(root, [prog, "SIM_ARGS=+nodump +hpm_stats +retired"])
        log = os.path.join(root, "build", "gate-" + os.path.basename(prog) + ".log")
        os.makedirs(os.path.dirname(log), exist_ok=True)
        with open(log, "w") as f:
            f.write(text)
        rc2, out = sh([sys.executable, os.path.join(root, "test", "hpm", "identities.py"), log], root)
        if rc or rc2:
            return False, f"{prog}: {out.strip().splitlines()[-1][:150] if out.strip() else text.strip()[-120:]}"
    return True, "passed"


def check_cache(root):
    for preset, prog in (("H", "test/memsys/fetchredirect"), ("I", "test/memsys/icoherence")):
        rc, text = make(root, [prog, "HPM_PRESET=" + preset, "ICACHE=512", "MEM_LAT=2", "SIM_ARGS=+nodump +hpm_check"])
        bad = next((l for l in text.splitlines() if "HPM CACHE COMPARE" in l or "HPM CHECK" in l or "%Fatal" in l), None)
        if rc or bad or "HPM_CACHE_COMPARE ok" not in text:
            return False, f"{prog} preset {preset}: {(bad or 'no HPM_CACHE_COMPARE ok line')[:150]}"
    return True, "passed"


def run_layer(root, layer):
    """-> (passes, evidence): does the check pass in the tree at root?"""
    if layer == "unit":
        rc, text = make(root, ["test/sv/test_hpm"])
        bad = re.search(r"(?i)errors:\s*[1-9]|\bFAIL(?:ED)?\b|%Fatal|%Error", text)
        return (rc == 0 and not bad), (bad.group(0) if bad else "passed" if rc == 0 else text.strip()[-120:])
    if layer == "formal":
        rc, text = make(root, ["formal-hpm"])
        return rc == 0, "passed" if rc == 0 else (text.strip().splitlines() or ["failed"])[-1][:150]
    if layer == "legal":
        rc, text = make(root, ["csr-legal-check"])
        return rc == 0, "passed" if rc == 0 else (text.strip().splitlines() or ["differs"])[-1][:150]
    if layer == "hpm":
        return program_check(root, "test/asm/hpm")
    if layer == "hpmirq":
        return program_check(root, "test/asm/hpmirq")
    if layer == "bpsquash":
        return program_check(root, "test/asm/bpsquash")
    if layer == "hpmwait":
        return program_check(root, "test/memsys/hpmwait", ["MEM_LAT=2"])
    if layer == "hpmcache":
        return program_check(root, "test/memsys/hpmcache", ["ICACHE=512", "MEM_LAT=2"])
    if layer.startswith("check-"):
        return check_preset(root, layer[6:])
    if layer == "gate":
        return check_gate(root)
    if layer == "cache":
        return check_cache(root)
    if layer == "sweep":
        env_free = [sys.executable, os.path.join(root, "test", "trapsweep", "sweep.py"), "run", "--fam", "hpm", "--targets", "dut",
                    "--jobs", "4", "--out", os.path.join(root, "build", "mutant-sweep")]
        rc, text = sh(env_free, root)
        ok = rc == 0 and re.search(r"DUT: (\d+)/\1 programs ISS-consistent", text) is not None
        return ok, "passed" if ok else (re.search(r"DUT: .*", text).group(0) if re.search(r"DUT: .*", text) else text.strip()[-120:])
    return None, f"unknown check {layer}"


ALL_LAYERS = ["unit", "formal", "legal", "hpm", "hpmirq", "bpsquash", "hpmwait", "hpmcache", "gate", "cache", "sweep"] + \
    ["check-" + c for c in "ABCDEFGHI"]


def find(name):
    for mu in MUTANTS:
        if mu["name"] == name:
            return mu
    sys.exit(f"mutants.py: no mutant {name}; see: mutants.py list")


# ------------------------------------------------------------------------------ one mutant
def run_one(mu, keep, only_layers, base):
    d = tempfile.mkdtemp(prefix=f"mutant-{mu['name']}-")
    root = os.path.join(d, "tree")
    res = dict(name=mu["name"])
    try:
        if mu["left_out"]:
            res.update(verdict="LEFT OUT", evidence=mu["also"])
            return res
        copy_tree(root)
        probs = apply(root, mu["patches"])
        if probs:
            res.update(verdict="ANCHOR MISSING", evidence="; ".join(probs))
            return res
        tried = []
        for layer in mu["layers"]:
            if only_layers and layer not in only_layers:
                continue
            if base.get(layer) is False:
                tried.append(f"{layer}: the check fails on the unchanged tree")
                continue
            ok, ev = run_layer(root, layer)
            if ok is None:
                tried.append(f"{layer}: {ev}")
            elif not ok:
                res.update(verdict="CAUGHT", evidence=f"{layer}: {ev}", layer=layer, expected=mu["layers"])
                return res
            else:
                tried.append(f"{layer}: not caught")
        res.update(verdict="MISSED", evidence="; ".join(tried) or "no check ran", expected=mu["layers"])
        return res
    finally:
        if keep:
            res["tree"] = root
        else:
            shutil.rmtree(d, ignore_errors=True)


def build_check(root, mu):
    """Does the tree with the mutant still elaborate? Verilator lints the standard simulator when a
    SystemVerilog file is patched, and a simulator with an instruction cache too (the cached branch
    of rtl/mcu.sv and the cache monitors of sim/top.sv are not part of the standard one)."""
    files = sorted({f for f, *_ in mu["patches"]})
    if not any(f.endswith(".sv") for f in files):
        return True, "nothing to build"
    rc, text = make(root, ["sim-config", "ICACHE=512", "MEM_LAT=2"])
    defs = re.search(r"Verilator defines:\s*(.*)", text)
    cached = defs.group(1).split() if defs and rc == 0 else []
    for name, extra in (("standard", []), ("with an instruction cache", cached)):
        if name != "standard" and not cached:
            return False, "no configuration with an instruction cache"
        rc, text = sh(["verilator", "--lint-only", "-Wno-fatal", "--timing", "--assert", "-Mdir", os.path.join(root, "build", "lint-only"),
                       "-f", "sim/files.txt"] + extra + ["--top-module", "top", "sim/top.sv"], root)
        err = next((l for l in text.splitlines() if l.startswith("%Error")), None)
        if rc or err:
            return False, f"{name}: " + (err or text.strip()[-160:])[:200]
    return True, "the simulators (standard, with an instruction cache) elaborate"


def dry_one(mu):
    d = tempfile.mkdtemp(prefix=f"mutant-dry-{mu['name']}-")
    root = os.path.join(d, "tree")
    try:
        if mu["left_out"]:
            return mu["name"], "LEFT OUT", mu["also"]
        copy_tree(root)
        probs = apply(root, mu["patches"])
        if probs:
            return mu["name"], "ANCHOR MISSING", "; ".join(probs)
        ok, what = build_check(root, mu)
        return mu["name"], "BUILT" if ok else "BUILD FAILED", what
    finally:
        shutil.rmtree(d, ignore_errors=True)


# ------------------------------------------------------------------------------ commands
def cmd_list(a):
    for mu in MUTANTS:
        files = sorted({f for f, *_ in mu["patches"]})
        print(f"{mu['name']:42s} {', '.join(files):38s} {' '.join(mu['layers']) or '(left out)'}")
        if a.verbose:
            print(f"    {mu['what']}")
            if mu["also"]:
                print(f"    {mu['also']}")
    print(f"{len(MUTANTS)} mutants, {sum(mu['left_out'] for mu in MUTANTS)} left out on purpose")
    return 0


def cmd_anchors(a):
    names = a.names or [mu["name"] for mu in MUTANTS]
    bad = 0
    for n in names:
        mu = find(n)
        if mu["left_out"]:
            print(f"left out {n}: {mu['also']}")
            continue
        d = tempfile.mkdtemp(prefix="mutant-anchor-")
        try:
            for f in {f for f, *_ in mu["patches"]}:
                src = os.path.join(REPO, f)
                if os.path.exists(src):
                    os.makedirs(os.path.dirname(os.path.join(d, f)), exist_ok=True)
                    shutil.copy(src, os.path.join(d, f))
            probs = apply(d, mu["patches"])
        finally:
            shutil.rmtree(d, ignore_errors=True)
        bad += bool(probs)
        print(f"{'ok     ' if not probs else 'MISSING'} {n}" + "".join(f"\n        {p}" for p in probs))
    print(f"ANCHORS: {len(names) - bad} of {len(names)} mutants apply to this tree")
    return 0 if not bad else 1


def cmd_show(a):
    mu = find(a.name)
    d = tempfile.mkdtemp(prefix="mutant-show-")
    try:
        for f in {f for f, *_ in mu["patches"]}:
            if os.path.exists(os.path.join(REPO, f)):
                os.makedirs(os.path.dirname(os.path.join(d, f)), exist_ok=True)
                shutil.copy(os.path.join(REPO, f), os.path.join(d, f))
        probs = apply(d, mu["patches"])
        for f in sorted({f for f, *_ in mu["patches"]}):
            if os.path.exists(os.path.join(d, f)):
                old = open(os.path.join(REPO, f)).read().splitlines(True)
                new = open(os.path.join(d, f)).read().splitlines(True)
                sys.stdout.writelines(difflib.unified_diff(old, new, f"a/{f}", f"b/{f}"))
        for p in probs:
            print(f"ANCHOR MISSING: {p}")
    finally:
        shutil.rmtree(d, ignore_errors=True)
    print(f"{mu['name']}: {mu['what']}")
    return 0


def cmd_apply(a):
    mu = find(a.name)
    dst = os.path.abspath(a.dir)
    if os.path.exists(dst):
        sys.exit(f"mutants.py: {dst} exists")
    copy_tree(dst, os.path.abspath(a.src), a.subset.split(",") if a.subset else None)
    probs = apply(dst, mu["patches"])
    if probs:
        print(f"mutants.py: {mu['name']}: ANCHOR MISSING: " + "; ".join(probs))
        return 1
    print(f"mutants.py: {mu['name']} applied in {dst}")
    return 0


def cmd_dryrun(a):
    names = a.names or [mu["name"] for mu in MUTANTS]
    count = {}
    with cf.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        for name, verdict, why in ex.map(dry_one, [find(n) for n in names]):
            count[verdict] = count.get(verdict, 0) + 1
            print(f"{verdict:14s} {name}: {why}", flush=True)
    print(f"DRY RUN: {count.get('BUILT', 0)} of {len(names)} mutants applied and built, then discarded; "
          f"{count.get('LEFT OUT', 0)} left out, {count.get('ANCHOR MISSING', 0)} without an anchor, "
          f"{count.get('BUILD FAILED', 0)} that do not build")
    return 0 if count.get("ANCHOR MISSING", 0) == 0 and count.get("BUILD FAILED", 0) == 0 else 1


def baseline(layers):
    """The checks on the unchanged checkout -> {layer: True/False/None}"""
    out = {}
    for layer in layers:
        ok, ev = run_layer(REPO, layer)
        out[layer] = ok
        print(f"{'passes' if ok else 'FAILS ' if ok is False else 'n/a   '} {layer}: {ev}", flush=True)
    return out


def cmd_baseline(a):
    layers = a.layers.split(",") if a.layers else ALL_LAYERS
    res = baseline(layers)
    return 0 if all(v for v in res.values()) else 1


def cmd_run(a):
    names = [mu["name"] for mu in MUTANTS] if not a.names or a.names == ["all"] else a.names
    mus = [find(n) for n in names]
    only = set(a.layers.split(",")) if a.layers else None
    needed = sorted({layer for mu in mus for layer in mu["layers"] if not only or layer in only})
    print("baseline: the checks on the unchanged tree")
    base = baseline(needed)
    os.makedirs(a.out, exist_ok=True)
    results = []
    with cf.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        for res in ex.map(lambda mu: run_one(mu, a.keep, only, base), mus):
            results.append(res)
            print(f"{res['verdict']:14s} {res['name']}: {res['evidence']}", flush=True)
    with open(os.path.join(a.out, "mutants.json"), "w") as f:
        json.dump(dict(baseline={k: v for k, v in base.items()}, results=results), f, indent=1)
    caught = sum(r["verdict"] == "CAUGHT" for r in results)
    left = sum(r["verdict"] == "LEFT OUT" for r in results)
    others = ", ".join(f"{v} {sum(r['verdict'] == v for r in results)}"
                       for v in ("MISSED", "ANCHOR MISSING") if any(r["verdict"] == v for r in results))
    print(f"MUTANTS: {caught} of {len(results) - left} CAUGHT" + (f", {left} left out on purpose" if left else "") +
          (f"; {others}" if others else "") + f"; {a.out}/mutants.json")
    return 0 if caught == len(results) - left else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("list")
    p.add_argument("-v", "--verbose", action="store_true")
    p = sub.add_parser("anchors")
    p.add_argument("names", nargs="*")
    p = sub.add_parser("show")
    p.add_argument("name")
    p = sub.add_parser("dryrun")
    p.add_argument("names", nargs="*")
    p.add_argument("--jobs", type=int, default=4)
    p = sub.add_parser("apply")
    p.add_argument("--src", default=REPO)
    p.add_argument("--subset", default="")
    p.add_argument("name")
    p.add_argument("dir")
    p = sub.add_parser("baseline")
    p.add_argument("--layers", default="")
    p = sub.add_parser("run")
    p.add_argument("names", nargs="*")
    p.add_argument("--jobs", type=int, default=2)
    p.add_argument("--out", default=os.path.join(REPO, "build", "hpm-mutants"))
    p.add_argument("--keep", action="store_true")
    p.add_argument("--layers", default="", help="only these checks, comma-separated")
    a = ap.parse_args()
    return {"list": cmd_list, "anchors": cmd_anchors, "show": cmd_show, "run": cmd_run, "dryrun": cmd_dryrun,
            "apply": cmd_apply, "baseline": cmd_baseline}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
