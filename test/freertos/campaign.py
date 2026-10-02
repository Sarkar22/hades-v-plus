#!/usr/bin/env python3
"""FreeRTOS differential stress campaign for HaDes-V+.

Builds every FreeRTOS program configuration ("variant") once, then runs each
ELF with several interrupt-timing seeds on
  * one or more DUT trees       (--dut NAME=ROOT, default: dut=<this repo>)
  * the golden reference CPU    (ref/*.so via +define+USE_REF_CPU; rv32i only)
in parallel, and prints a per-run table plus a summary.

Oracles
  * rv32i variants: the golden CPU must PASS; every DUT run must match it.
    A golden failure means the variant (or the harness) is invalid, not the
    DUT -- it is reported as such and makes the campaign exit non-zero.
  * rv32im / rv32im_zba variants: the golden CPU predates M and Zba, so the
    oracle is the program's own self-checks (FRTOS-RESULT: PASS).
Nothing depends on the Zicntr TIME CSR (it reads 0 on the golden CPU).

Seeds drive +switches=<hex>, which the programs read as their run seed; the
seed decides the external-interrupt delays and all task-side random timing.

Suites
  --suite NAME runs several sets in one pool of --jobs workers, each set with its
  own --seeds, --seed-base, --run-cycles and --max-checks, as the separate --set
  commands would (each entry builds and logs into <out>/<entry>/). The report adds
  a table per entry and the runs that two entries share. The suites are listed
  below; --list shows a suite's runs.

Records
  --record DIR writes a record of the campaign into DIR (by convention
  results/<topic>/<date>_<commit>/): RECORD.md, meta.json, results.csv (one row
  per run), summary.md and inputs.sha256 (program images, source fingerprints).
  --compare FILE checks the campaign run for run against a stored results.csv:
  status, reason, cycles, UART line counts, run shape and program image, never
  wall time. It prints COMPARE RESULT and exits with status 4 on a difference.
  With --results OTHER.csv nothing is run: OTHER.csv is compared with FILE.

Examples
  test/freertos/campaign.py --set quick
  test/freertos/campaign.py --set validate --dut buggy=. --dut patched=../wt-fixed
  test/freertos/campaign.py --set standard --seeds 3 --jobs 6 --out build/campaign
  test/freertos/campaign.py --set bpred --seeds 4     # branch predictor on (FRTOS_BPRED=1..3)
  test/freertos/campaign.py --suite sep2026 --list   # the runs of a suite
  test/freertos/campaign.py --suite sep2026 --jobs 12 --wall-limit 0 \\
      --compare results/freertos-campaign/2026-10-01_03386fd/results.csv

The branch predictor (MHPMEVENT10) is off at reset; only the variants with a
.bp<N> suffix (sets breaker, breaker2, breaker-long, bpred) switch it on. The
golden CPU reads that CSR as 0 and ignores writes, so those rv32i variants keep
their golden twin.
"""
import argparse
import concurrent.futures as cf
import csv
import datetime
import glob
import hashlib
import itertools
import json
import os
import platform
import random
import re
import resource
import shlex
import shutil
import subprocess
import sys
import textwrap
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))


def tree_build(root, name):
    """(build directory of tree `root`, extra make variables) -- follows the Makefile.

    By default every tree builds into <root>/build (no BUILD_DIR is passed, so the
    Makefile's own default applies). With HADES_BUILD_DIR set (a relocated build, see
    docs/FREERTOS.md) this repository builds there and any other tree into
    $HADES_BUILD_DIR/other-trees/<name>, so that two trees never share simulator models."""
    bd = os.environ.get("HADES_BUILD_DIR")
    if not bd:
        return os.path.join(root, "build"), {}
    bd = os.path.abspath(bd)
    if os.path.realpath(root) != os.path.realpath(REPO):
        bd = os.path.join(bd, "other-trees", name)
    elif os.path.realpath(bd) == os.path.realpath(os.path.join(root, "build")):
        # The Makefile spells this directory build/ (not relocated): no BUILD_DIR and no
        # copies of ref/*.so, which only a relocated build directory has a rule for.
        return os.path.join(root, "build"), {}
    return bd, {"BUILD_DIR": bd}

CYCLE_PS = 20                   # sim/top.sv: 20 time units (ps) per system clock
DEFAULT_TICK = 10000            # cycles per RTOS tick (5x faster than 1 kHz at 50 MHz)
NORMAL_TICK = 50000             # 1 kHz at 50 MHz, the "real" setting
# Shortest tick periods at which the golden CPU still passes (measured, see
# README.md); below these the tick handler alone saturates the CPU.
PATHOLOGICAL_TICK = {"-O2": 500, "-Os": 500, "-O0": 1500}
# Defaults of --seeds, --seed-base, --run-cycles and --max-checks (also those of a suite entry)
DEFAULT_SEEDS, DEFAULT_SEED_BASE, DEFAULT_RUN_CYCLES, DEFAULT_MAX_CHECKS = 4, 0x0001, 5_000_000, 40


# --------------------------------------------------------------------------- variants
class Variant:
    def __init__(self, app, march="rv32i", opt="-O2", preempt=1, slice_=1, tick=DEFAULT_TICK,
                 heap=4, defs=(), tag="", ram_kb=None, run_cycles=5_000_000, bpred=0, max_checks=None):
        self.app, self.march, self.opt, self.bpred = app, march, opt, bpred
        self.preempt, self.slice, self.tick, self.heap = preempt, slice_, tick, heap
        self.defs, self.tag = tuple(defs), tag
        self.ram_kb = ram_kb or default_ram_kb(app, opt)
        self.nchecks, self.check_ticks = run_shape(app, tick, run_cycles, opt, march, max_checks)
        self.run_ticks = self.nchecks * self.check_ticks

    @property
    def name(self):
        t = f".{self.tag}" if self.tag else ""
        bp = f".bp{self.bpred}" if self.bpred else ""
        return (f"{self.app}{t}.{self.march}.{self.opt.lstrip('-')}.p{self.preempt}s{self.slice}"
                f".t{self.tick}.h{self.heap}{bp}")

    @property
    def golden_ok(self):
        return self.march == "rv32i"

    def make_vars(self):
        defs = list(self.defs) + [f"-DFRTOS_NCHECKS={self.nchecks}",
                                  f"-DFRTOS_CHECK_TICKS={self.check_ticks}"]
        return {"FRTOS_APP": self.app, "FRTOS_MARCH": self.march, "FRTOS_OPT": self.opt,
                "FRTOS_PREEMPT": self.preempt, "FRTOS_SLICE": self.slice, "FRTOS_TICK": self.tick,
                "FRTOS_HEAP": self.heap, "FRTOS_RAM_KB": self.ram_kb, "FRTOS_BPRED": self.bpred,
                "FRTOS_DEFS": " ".join(defs)}

    def timeout_cycles(self):
        startup = 3_000_000 if self.opt == "-O0" else 1_500_000
        if self.app == "full":
            startup *= 4
        if self.app == "brk":
            startup *= 2
        return int(1.5 * self.run_ticks * self.tick) + 2 * startup


def default_ram_kb(app, opt):
    if app == "full":
        return 512 if opt == "-O0" else 256
    if app == "stress" and opt == "-O0":
        return 64       # -O0 code alone is ~29 KB; -O2/-Os fit the real 32 KiB
    if app == "mzba" and opt == "-O0":
        return 64
    if app == "brk":
        return 256 if opt == "-O0" else 64
    return 32


# Shortest check period (cycles) per program: several times the longest sleep
# of any of its tasks (stress/main.c STRESS_PERIOD, mzba/main.c MZBA_PERIOD),
# so that "no progress in a check period" can only mean a stuck task.
# (150k-cycle periods let the golden CPU fail 1 run in 56 when a dense
# interrupt profile starved the priority-0 RegTest tasks for one period.)
MAX_CHECKS = DEFAULT_MAX_CHECKS # --max-checks: longer --run-cycles runs need more periods
MIN_CHECK_CYCLES = {"stress": 400_000, "mzba-m": 400_000, "mzba-i": 1_000_000, "brk": 1_000_000}


def run_shape(app, tick, run_cycles, opt="-O2", march="rv32i", max_checks=None):
    """(checks, ticks per check) so that a run lasts about run_cycles, with at most
    max_checks checks (default: MAX_CHECKS, i.e. --max-checks)."""
    if app == "full":
        return 3, 5000              # the official demo's 5 s check period
    if app == "minimal":
        return 1, max(60, min(4000, run_cycles // tick))
    key = app if app != "mzba" else ("mzba-i" if march == "rv32i" else "mzba-m")
    knee = 7500 if opt == "-O0" else (6000 if app in ("stress", "brk") else 3000)
    scale = 1 if tick >= knee else -(-knee // tick)          # same back-off as the programs
    min_cycles = MIN_CHECK_CYCLES[key] * scale * (5 if opt == "-O0" else 2) // 2
    check_ticks = max(10, -(-min_cycles // tick))
    max_checks = MAX_CHECKS if max_checks is None else max_checks
    nchecks = max(4, min(max_checks, run_cycles // (check_ticks * tick)))
    return nchecks, check_ticks


def variant_sets(args, run_cycles=None, max_checks=None):
    """Every variant set, built for run_cycles (default: --run-cycles) and max_checks
    (default: MAX_CHECKS, i.e. --max-checks)."""
    def V(*a, **k):
        k.setdefault("max_checks", max_checks)
        return Variant(*a, **k)
    rc = args.run_cycles if run_cycles is None else run_cycles
    sets = {}
    sets["quick"] = [
        V("minimal", run_cycles=rc), V("stress", run_cycles=rc),
        V("stress", defs=["-DSTRESS_CRIT_YIELD=0"], tag="noyield", run_cycles=rc),
        V("mzba", run_cycles=rc), V("mzba", march="rv32im_zba", run_cycles=rc),
    ]
    # Bug-detection focus: the stress program, rv32i so every run has a golden twin.
    sets["validate"] = [
        V("stress", run_cycles=rc),
        V("stress", defs=["-DSTRESS_CRIT_YIELD=0"], tag="noyield", run_cycles=rc),
        V("stress", opt="-Os", tick=5000, defs=["-DSTRESS_CRIT_YIELD=0"], tag="noyield", run_cycles=rc),
        V("stress", opt="-O0", defs=["-DSTRESS_CRIT_YIELD=0"], tag="noyield", run_cycles=rc),
        V("stress", preempt=0, defs=["-DSTRESS_CRIT_YIELD=0"], tag="noyield", run_cycles=rc),
        V("minimal", run_cycles=rc),
        V("mzba", run_cycles=rc),
    ]
    # Broad coverage of every knob (not a full cross product: each value of each
    # dimension appears several times, in varied combinations).
    std = []
    for app in ("minimal", "stress", "mzba"):
        for march, opt, pre, sl, heap, tick in [
            ("rv32i", "-O2", 1, 1, 4, DEFAULT_TICK),
            ("rv32i", "-Os", 1, 0, 1, 5000),
            ("rv32i", "-O0", 1, 1, 4, DEFAULT_TICK),
            ("rv32i", "-O2", 0, 1, 1, DEFAULT_TICK),
            ("rv32i", "-Os", 0, 0, 4, NORMAL_TICK),
            ("rv32i", "-O2", 1, 1, 4, PATHOLOGICAL_TICK["-O2"]),
            ("rv32i", "-O0", 1, 0, 1, PATHOLOGICAL_TICK["-O0"]),
            ("rv32im", "-O2", 1, 1, 4, DEFAULT_TICK),
            ("rv32im", "-O0", 0, 1, 1, 5000),
            ("rv32im", "-Os", 1, 0, 4, PATHOLOGICAL_TICK["-Os"]),
            ("rv32im_zba", "-O2", 1, 1, 1, 5000),
            ("rv32im_zba", "-Os", 0, 1, 4, DEFAULT_TICK),
            ("rv32im_zba", "-O0", 1, 1, 4, NORMAL_TICK),
        ]:
            std.append(V(app, march, opt, pre, sl, tick, heap, run_cycles=rc))
            if app == "stress":
                std.append(V(app, march, opt, pre, sl, tick, heap, defs=["-DSTRESS_CRIT_YIELD=0"],
                             tag="noyield", run_cycles=rc))
    # The standard demo set is only run with time slicing on, as in the official
    # demo: with configUSE_TIME_SLICING=0 its priority-0 tasks (semtest polling
    # pair, MessageBuffer non-blocking/coherence tasks) can starve for a whole
    # check period or hit MessageBufferDemo's own coherence assert, and the golden
    # CPU failed 3 of 12 seeds of full.rv32i.Os.p1s0. Slicing off is covered by
    # minimal/stress/mzba, whose checks are built for it.
    std += [V("full"), V("full", march="rv32im_zba"), V("full", opt="-Os")]
    sets["standard"] = std
    # Where does the tick period become too short even for the golden CPU?
    # (run with --golden-only; used to choose PATHOLOGICAL_TICK)
    sets["ticksweep"] = [V(app, "rv32i", opt, tick=t, defs=d, tag=tag, run_cycles=3_000_000)
                         for app, d, tag in (("minimal", (), ""), ("stress", ["-DSTRESS_CRIT_YIELD=0"], "noyield"),
                                             ("mzba", (), ""))
                         for opt, ticks in (("-O2", (500, 700, 1000, 1500, 2000, 3000, 5000)),
                                            ("-O0", (1500, 2000, 2500, 3500, 5000)))
                         for t in ticks]
    sets["full"] = [V("full"), V("full", opt="-Os"), V("full", opt="-O0"),
                    V("full", march="rv32im"), V("full", march="rv32im_zba", opt="-Os")]
    # The standard demo at the real 1 kHz tick (50 MHz clock): 3 x 5000 ticks,
    # about 750M cycles per run.
    sets["realtick"] = [V("full", tick=NORMAL_TICK), V("full", march="rv32im", tick=NORMAL_TICK)]
    # RTOS-level breaker (brk): storms, mtimecmp in the past, nesting, yield with
    # MIE=0, vTaskDelete churn, PI chains, ISR stream/message buffers, fence.i;
    # branch predictor off (bp0) and on (bp1..3, and random run-time mode changes).
    dyn = ["-DBRK_BPDYN=1"]
    brk = []
    for march, opt, pre, sl, tick, bp, d, tag in [
        ("rv32i", "-O2", 1, 1, DEFAULT_TICK, 0, (), ""),
        ("rv32i", "-Os", 1, 0, 5000, 0, (), ""),
        ("rv32i", "-O0", 1, 1, DEFAULT_TICK, 0, (), ""),
        ("rv32i", "-O2", 0, 1, DEFAULT_TICK, 0, (), ""),
        ("rv32i", "-O2", 1, 1, 3000, 0, (), ""),
        ("rv32i", "-Os", 1, 1, NORMAL_TICK, 0, (), ""),
        ("rv32i", "-O2", 1, 1, DEFAULT_TICK, 3, (), ""),
        ("rv32i", "-O2", 1, 1, DEFAULT_TICK, 1, (), ""),
        ("rv32i", "-Os", 1, 0, 5000, 2, (), ""),
        ("rv32i", "-O2", 1, 1, DEFAULT_TICK, 3, dyn, "bpdyn"),
        ("rv32im", "-O2", 1, 1, DEFAULT_TICK, 0, (), ""),
        ("rv32im", "-O2", 1, 1, 1500, 0, (), ""),
        ("rv32im_zba", "-Os", 1, 0, 5000, 0, (), ""),
        ("rv32im", "-O0", 1, 1, DEFAULT_TICK, 0, (), ""),
        ("rv32im", "-O2", 1, 1, DEFAULT_TICK, 3, dyn, "bpdyn"),
    ]:
        brk.append(V("brk", march, opt, pre, sl, tick, 4, defs=d, tag=tag, run_cycles=rc, bpred=bp))
    sets["breaker"] = brk
    # The pre-existing programs with the branch predictor switched on at start-up
    # (MHPMEVENT10 = 1/2/3; the golden CPU ignores the CSR, so rv32i runs keep
    # their golden twin).
    sets["bpred"] = ([V("stress", bpred=b, run_cycles=rc) for b in (1, 2, 3)]
                     + [V("stress", opt="-Os", tick=5000, bpred=3, defs=["-DSTRESS_CRIT_YIELD=0"], tag="noyield",
                          run_cycles=rc),
                        V("stress", opt="-O0", bpred=2, run_cycles=rc),
                        V("minimal", bpred=3, run_cycles=rc), V("mzba", bpred=3, run_cycles=rc),
                        V("mzba", march="rv32im_zba", bpred=3, run_cycles=rc),
                        V("full", bpred=3), V("full", opt="-Os", bpred=1)])
    # storm-heavy (a storm after 1 in 4 calm interrupts instead of 1 in 32)
    st, dyn = ["-DBRK_STORM_MASK=3"], ["-DBRK_STORM_MASK=3", "-DBRK_BPDYN=1"]
    sets["breaker2"] = [V("brk", tag="storm", defs=st, run_cycles=rc),
                        V("brk", opt="-Os", tick=3000, slice_=0, tag="storm", defs=st, run_cycles=rc),
                        V("brk", opt="-O0", tag="storm", defs=st, run_cycles=rc),
                        V("brk", preempt=0, tag="storm", defs=st, run_cycles=rc),
                        V("brk", march="rv32im", tick=1500, tag="storm", defs=st, run_cycles=rc),
                        V("brk", march="rv32im_zba", opt="-Os", tag="storm", defs=st, run_cycles=rc),
                        V("brk", bpred=3, tag="storm", defs=st, run_cycles=rc),
                        V("brk", march="rv32im", bpred=3, tag="stormbpdyn", defs=dyn, run_cycles=rc)]
    # the same programs, each run for --run-cycles (use e.g. 100M) on fewer variants
    sets["breaker-long"] = [V("brk", run_cycles=rc), V("brk", opt="-Os", tick=5000, slice_=0, run_cycles=rc),
                            V("brk", tick=DEFAULT_TICK, bpred=3, defs=dyn, tag="bpdyn", run_cycles=rc),
                            V("brk", march="rv32im", run_cycles=rc),
                            V("stress", run_cycles=rc), V("stress", bpred=3, run_cycles=rc)]
    return sets


# --------------------------------------------------------------------------- suites
# A suite is a list of entries. Each entry is the equivalent of the command
#   campaign.py --set SET --seeds N [--seed-base B] [--run-cycles C] [--max-checks M]
# (a field left out takes that option's default); "name" (default: the set) names the
# entry's output directory <out>/<name>/ and its rows in the report.
SUITES = {
    "sep2026": {
        "about": "the final campaign on the fixed core, run on 2026-09-27, whose totals "
                 "docs/VERIFICATION.md quotes",
        "note": "validate and standard share 5 variants and seeds 0001-0008, so 40 DUT and 40 golden runs "
                "are run twice, which also checks that the simulations are deterministic",
        "entries": [
            {"set": "breaker", "seeds": 8, "seed_base": 0x101, "run_cycles": 20_000_000},
            {"set": "breaker2", "seeds": 8, "seed_base": 0x401, "run_cycles": 20_000_000},
            {"set": "breaker-long", "seeds": 3, "seed_base": 0x301, "run_cycles": 100_000_000,
             "max_checks": 100_000},
            {"set": "validate", "seeds": 16},
            {"set": "bpred", "seeds": 4, "seed_base": 0x201, "run_cycles": 10_000_000},
            {"set": "standard", "seeds": 8},
        ],
    },
}


class Entry:
    """One set with its seeds and run shape. A --set campaign is a single entry whose
    output directory is --out itself (sub ""); a suite's entries use <out>/<name>/."""
    def __init__(self, name, set_, seeds, seed_base, run_cycles, max_checks, variants, sub):
        self.name, self.set, self.variants, self.sub = name, set_, variants, sub
        self.nseeds, self.seed_base, self.run_cycles, self.max_checks = seeds, seed_base, run_cycles, max_checks
        self.seeds = [(seed_base + i) & 0xFFFF for i in range(seeds)]

    def options(self):
        """The --set options this entry is equivalent to."""
        o = f"--set {self.set} --seeds {self.nseeds}"
        if self.seed_base != DEFAULT_SEED_BASE:
            o += f" --seed-base {self.seed_base:#x}"
        if self.run_cycles != DEFAULT_RUN_CYCLES:
            o += f" --run-cycles {self.run_cycles}"
        if self.max_checks != DEFAULT_MAX_CHECKS:
            o += f" --max-checks {self.max_checks}"
        return o


def suite_entries(name, args, keep):
    """The entries of suite `name`, their variants filtered by keep()."""
    entries = []
    for e in SUITES[name]["entries"]:
        p = dict({"seed_base": DEFAULT_SEED_BASE, "run_cycles": DEFAULT_RUN_CYCLES,
                  "max_checks": DEFAULT_MAX_CHECKS}, **e)
        ename = p.get("name", p["set"])
        variants = keep(variant_sets(args, p["run_cycles"], p["max_checks"])[p["set"]])
        entries.append(Entry(ename, p["set"], p["seeds"], p["seed_base"], p["run_cycles"], p["max_checks"],
                             variants, ename))
    return entries


def suites_help():
    lines = ["suites (--suite NAME; --list shows the runs):"]
    for name, s in SUITES.items():
        es = suite_entries(name, argparse.Namespace(run_cycles=DEFAULT_RUN_CYCLES), lambda v: v)
        nd = sum(len(e.variants) * len(e.seeds) for e in es)
        nb = sum(sum(v.bpred != 0 for v in e.variants) * len(e.seeds) for e in es)
        ng = sum(sum(v.golden_ok for v in e.variants) * len(e.seeds) for e in es)
        text = (f"{s['about']}: {nd} DUT runs ({nb} with the branch predictor on) and {ng} golden runs, "
                f"from these {len(es)} entries:")
        lines += [(f"  {name:9s} " if i == 0 else " " * 12) + l for i, l in enumerate(textwrap.wrap(text, 72))]
        lines += [" " * 14 + e.options() for e in es]
        if s.get("note"):
            lines += [" " * 12 + l for l in textwrap.wrap(f"({s['note']})", 72)]
    return "\n".join(lines)


# --------------------------------------------------------------------------- helpers
def log(msg):
    print(msg, flush=True)


def make(root, target, variables, logfile, extra_env=None):
    cmd = (["make", "-s", "-C", root] + (target if isinstance(target, list) else [target])
           + [f"{k}={v}" for k, v in variables.items()])
    env = dict(os.environ, **(extra_env or {}))
    with open(logfile, "w") as f:
        f.write(" ".join(repr(c) if " " in str(c) else str(c) for c in cmd) + "\n")
        f.flush()
        r = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, env=env,
                           preexec_fn=lambda: os.nice(5))
    return r.returncode == 0


def limit_resources():
    os.nice(10)
    resource.setrlimit(resource.RLIMIT_AS, (4 << 30, 4 << 30))


ANSI = re.compile(r"\x1b\[[0-9;]*m")
# Printed by hal_pattern_line() with interrupts enabled; must arrive intact.
PATTERN_LINE = "~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz~"


def parse_log(text, timeout_cycles, uart_check=True):
    text = ANSI.sub("", text)
    res = {"status": "CRASH", "reason": "", "cycles": None}
    m = re.search(r"FRTOS-RESULT: (PASS|FAIL)(.*?)(?: mtime=([0-9a-f]{16}))?\s*$", text, re.M)
    times = re.findall(r"\(\s*(\d+) ps\) Test (?:pass|fail)!", text)
    if times:
        res["cycles"] = int(times[-1]) // CYCLE_PS
    if m and m.group(3):
        res["cycles"] = int(m.group(3), 16)
    if "Simulation timeout!" in text:
        res["status"], res["cycles"] = "HANG", timeout_cycles
        uart = [l for l in text.splitlines() if l.strip() and not l.startswith(("-", "%", "("))
                and "REFERENCE IMPLEMENTATION" not in l and "Simulation timeout" not in l]
        res["reason"] = "no result before timeout; last output: " + (uart[-1].strip()[:90] if uart else "(none)")
    elif m and m.group(1) == "PASS":
        if "All tests passed! (# Errors: 1 = initial test)" in text:
            res["status"] = "PASS"
        else:
            res["status"], res["reason"] = "FAIL", "PASS printed but test-register protocol broken"
    elif m:
        res["status"], res["reason"] = "FAIL", m.group(2).strip()
    else:
        tail = [l for l in text.splitlines() if l.strip()][-3:]
        res["reason"] = " | ".join(t.strip() for t in tail)[:160]
    # UART transcript integrity: a program cannot observe its own UART output,
    # so a store the core performed twice (or dropped) is only visible here.
    pat = [l for l in text.splitlines() if l.startswith("~")]
    bad = [l for l in pat if l != PATTERN_LINE]
    res["uart_lines"], res["uart_bad"] = len(pat), len(bad)
    res["uart_only"] = bool(bad) and res["status"] == "PASS"   # passed except for the UART check
    if res["uart_only"] and uart_check:
        res["status"] = "FAIL"
        res["reason"] = (f"UART transcript corrupted in {len(bad)}/{len(pat)} pattern lines "
                         f"(UART store performed twice or lost): {bad[0][:70]}")
    return res


def short_reason(reason):
    """Failure signature without run-specific numbers (for histograms)."""
    r = re.sub(r"\b(a|b)=[0-9a-f]{8}", "", reason)
    r = re.sub(r"last output: .*", "last output: ...", r)
    r = re.sub(r"UART transcript corrupted in \d+/\d+ pattern lines (\([^)]*\)).*", r"UART transcript corrupted \1", r)
    return re.sub(r"\s+", " ", r).strip()


def fmt_cycles(c):
    if c is None:
        return "-"
    return f"{c / 1e6:.2f}M"


# --------------------------------------------------------------------------- records
# What a campaign's results depend on: the simulator models (rtl, lib, defines, sim, ref)
# and the programs (test/freertos, third_party/freertos), both built by the makefiles
# (input_files()).
INPUT_TREES = ("rtl", "lib", "defines", "sim", "ref", "test/freertos", "third_party/freertos")
VENDORED = {"kernel": os.path.join(REPO, "third_party", "freertos", "FreeRTOS-Kernel"),
            "demo": os.path.join(REPO, "third_party", "freertos", "FreeRTOS", "FreeRTOS", "Demo")}
# A record's results.csv: one row per run, keyed by RECORD_KEY. --compare checks every
# column that both files have except NOT_COMPARED.
RECORD_KEY = ("set", "variant", "seed", "target")
RECORD_COLUMNS = RECORD_KEY + ("status", "reason", "cycles", "uart_lines", "uart_bad", "uart_only",
                               "app", "march", "opt", "preempt", "slice", "tick", "heap", "tag", "bpred",
                               "ram_kb", "nchecks", "check_ticks", "timeout", "image", "wall_s")
NOT_COMPARED = ("wall_s", "log")        # timing and local paths
IMAGE_DIGITS = 16                       # the image column: the first digits of sha256(init.mem)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def git(*a):
    """Output of a read-only git command in this repository (no optional locks), or None."""
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0", LC_ALL="C")
    try:
        r = subprocess.run(["git", "-C", REPO] + list(a), capture_output=True, text=True, env=env, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return r.stdout if r.returncode == 0 else None


def manifest_digest(rel):
    """sha256 of the lines '<sha256>  <path>' of every file under rel, sorted by path:
    (cd <repo> && find <rel> -type f ! -path '*/__pycache__/*' | LC_ALL=C sort | xargs sha256sum | sha256sum)"""
    top = os.path.join(REPO, rel)
    files = [rel] if os.path.isfile(top) else []
    for d, dirs, fs in os.walk(top):
        dirs[:] = [x for x in dirs if x != "__pycache__"]
        files += [os.path.relpath(os.path.join(d, f), REPO) for f in fs]
    text = "".join(f"{sha256_file(os.path.join(REPO, f))}  {f}\n" for f in sorted(files, key=lambda s: s.encode()))
    return hashlib.sha256(text.encode()).hexdigest()


def source_fingerprints():
    """The base commit and, for every input, its git object at that commit and the working-tree
    changes (path, git status, sha256); without git, a sha256 manifest digest of every input."""
    head = (git("rev-parse", "HEAD") or "").strip()
    fp = {"commit": head or None}
    if head:
        fp["commit_short"] = (git("rev-parse", "--short=7", "HEAD") or "").strip()
        fp["commit_date"] = (git("show", "-s", "--format=%cI", "HEAD") or "").strip()
    fp["inputs"] = {}
    for rel in INPUT_TREES + input_files():
        e = {"kind": "tree" if rel in INPUT_TREES else "file"}
        path = os.path.join(REPO, rel)
        if os.path.isfile(path):
            e["sha256"] = sha256_file(path)
        if head:
            e["object"] = (git("rev-parse", f"HEAD:{rel}") or "").strip() or None
            items = [x for x in (git("status", "--porcelain=v1", "-z", "--untracked-files=all", "--", rel)
                                 or "").split("\0") if x]
            changes, i = [], 0
            while i < len(items):
                code, p = items[i][:2], items[i][3:]
                i += 2 if code[0] in "RC" else 1          # a rename is followed by its origin
                full = os.path.join(REPO, p)
                changes.append({"path": p, "status": code.strip(),
                                "sha256": sha256_file(full) if os.path.isfile(full) else None})
            e["changes"] = changes
        else:
            e["sha256_manifest"] = manifest_digest(rel) if os.path.exists(path) else None
        fp["inputs"][rel] = e
    return fp


def input_files():
    """The makefiles that make reads in this repository (MAKEFILE_LIST) outside INPUT_TREES and
    the build directory; at least the Makefile."""
    found = (make_var("MAKEFILE_LIST") or "").split()
    build = os.path.realpath(tree_build(REPO, "dut")[0])
    rel = []
    for f in found:
        full = os.path.realpath(os.path.join(REPO, f))
        if full.startswith(os.path.realpath(REPO) + os.sep) and not full.startswith(build + os.sep):
            r = os.path.relpath(full, os.path.realpath(REPO))
            if not any(r.startswith(t + "/") for t in INPUT_TREES) and r not in rel:
                rel.append(r)
    return tuple(["Makefile"] + [r for r in rel if r != "Makefile"])


def make_var(name):
    """The value of a variable of the top-level Makefile (e.g. CC), or None."""
    try:
        r = subprocess.run(["make", "-s", "--no-print-directory", "-C", REPO, "--eval",
                            "hades-print-var-%: ; @echo '$($*)'", f"hades-print-var-{name}"],
                           capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return None
    out = r.stdout.strip().splitlines()
    return out[-1].strip() if r.returncode == 0 and out and out[-1].strip() else None


def first_line(cmd):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return None
    out = (r.stdout or r.stderr).strip().splitlines()
    return out[0].strip() if out else None


def tool_versions():
    cc = make_var("CC") or "riscv32-unknown-elf-gcc"
    vl = make_var("VERILATOR") or "verilator"
    return {"verilator": first_line([vl, "--version"]), "gcc": first_line([cc, "--version"]),
            "binutils": first_line([re.sub(r"gcc$", "ld", cc), "--version"]),
            "python": f"Python {platform.python_version()}"}


def host_summary():
    """CPU model, hardware threads and OS family (nothing that identifies the machine)."""
    cpu = None
    try:
        with open("/proc/cpuinfo") as f:
            cpu = next((l.split(":", 1)[1].strip() for l in f if l.lower().startswith("model name")), None)
    except OSError:
        pass
    if cpu:  # "Intel(R) Core(TM) Ultra 7 165H" -> "Intel Core Ultra 7 165H", as in the other records
        cpu = " ".join(re.sub(r"\((?:R|TM)\)", " ", cpu).split())
    return {"cpu": cpu or platform.processor() or platform.machine(), "threads": os.cpu_count(),
            "os": platform.system()}


def public_path(p):
    """p as a record may show it: relative to the repository, under $HADES_BUILD_DIR, or only its
    last component (a record holds no machine-specific paths)."""
    p = os.path.abspath(p)
    for base, label in ((REPO, ""), (os.environ.get("HADES_BUILD_DIR"), "$HADES_BUILD_DIR")):
        if not base:
            continue
        for b, q in ((os.path.abspath(base), p), (os.path.realpath(base), os.path.realpath(p))):
            if q == b or q.startswith(b + os.sep):
                rel = os.path.relpath(q, b)
                return (label or ".") if rel == "." else (f"{label}/{rel}" if label else rel)
    return f"<elsewhere>/{os.path.basename(p)}"


def same_dir(a, b):
    return bool(a) and os.path.realpath(a) == os.path.realpath(b)


def freertos_sources(args):
    """Where the FreeRTOS sources come from: None if the vendored copies, else a description."""
    ext = [f"--{k} {public_path(getattr(args, k))}" for k in ("kernel", "demo")
           if getattr(args, k) and not same_dir(getattr(args, k), VENDORED[k])]
    home = os.environ.get("FREERTOS_HOME")
    if home and not same_dir(home, os.path.join(REPO, "third_party", "freertos")):
        ext.append(f"FREERTOS_HOME={public_path(home)}")
    return ", ".join(ext) or None


def campaign_command(args):
    """The command line of this campaign as a record shows it: the options that select the runs,
    --jobs and --wall-limit, run from the repository root (no output or record options)."""
    c = ["python3", "test/freertos/campaign.py"]
    if args.suite:
        c += ["--suite", args.suite]
    else:
        c += ["--set", args.set, "--seeds", str(args.seeds)]
        if args.seed_base != DEFAULT_SEED_BASE:
            c += ["--seed-base", f"{args.seed_base:#x}"]
        if args.run_cycles != DEFAULT_RUN_CYCLES:
            c += ["--run-cycles", str(args.run_cycles)]
        if args.max_checks != DEFAULT_MAX_CHECKS:
            c += ["--max-checks", str(args.max_checks)]
    if args.apps:
        c += ["--apps", args.apps]
    if args.only:
        c += ["--only", args.only]
    for d in args.dut:
        name, _, root = d.partition("=")
        c += ["--dut", f"{name}={public_path(root)}"]
    if args.golden_root:
        c += ["--golden-root", public_path(args.golden_root)]
    c += [f"--{o.replace('_', '-')}" for o in ("no_golden", "golden_only", "no_uart_check", "strict")
          if getattr(args, o)]
    c += ["--jobs", str(args.jobs)]
    if args.wall_limit is not None:
        c += ["--wall-limit", f"{args.wall_limit:g}"]
    return " ".join(shlex.quote(x) for x in c)


def record_rows(results, vobj, images):
    """results (each with its entry as "set") as rows of a record's results.csv, all values as
    csv.DictWriter writes them. vobj: (entry, variant name) -> Variant."""
    rows = []
    for r in results:
        v = vobj[(r["set"], r["variant"])]
        row = dict({k: r.get(k) for k in RECORD_COLUMNS}, nchecks=v.nchecks, check_ticks=v.check_ticks,
                   timeout=v.timeout_cycles(), image=images.get((r["set"], r["variant"]), "")[:IMAGE_DIGITS])
        rows.append({k: "" if x is None else str(x) for k, x in row.items()})
    return sorted(rows, key=lambda w: (w["set"], w["variant"], w["seed"], w["target"]))


def compare_runs(rows, path):
    """Compare record rows with the stored results.csv at path. Returns (report lines, verdict
    line, ok); ok is False if a run differs or no run is in common."""
    with open(path, newline="") as f:
        rd = csv.DictReader(f)
        cols, stored = list(rd.fieldnames or []), list(rd)
    key = [k for k in RECORD_KEY if k in cols and (k != "set" or rows and "set" in rows[0])]
    if "variant" not in key or "seed" not in key or "target" not in key:
        return ([], f"COMPARE RESULT: UNUSABLE ({public_path(path)} has no variant, seed and target columns)",
                False)
    comp = [c for c in cols if rows and c in rows[0] and c not in key and c not in NOT_COMPARED]
    old = {}
    for s in stored:
        old.setdefault(tuple(s[k] for k in key), []).append(s)
    lines = [f"== comparison with {public_path(path)} (key: {', '.join(key)}; compared: {', '.join(comp)}; "
             f"never wall time)"]
    common, diffs, per_col, seen = 0, [], {}, set()
    for w in rows:
        k = tuple(w[c] for c in key)
        if k not in old:
            continue
        seen.add(k)
        common += 1
        bad = [(c, s[c], w[c]) for s in old[k][:1] for c in comp if s[c] != w[c]]
        if bad:
            diffs.append((k, bad))
            for c, _, _ in bad:
                per_col[c] = per_col.get(c, 0) + 1
    only_here = len(rows) - common
    only_stored = sum(len(v) for k, v in old.items() if k not in seen)
    lines.append(f"   runs here: {len(rows)}; stored: {len(stored)}; in common: {common}; only here: {only_here}; "
                 f"stored but not run here: {only_stored}")
    for k, bad in diffs[:25]:
        lines.append(f"   differs: {' '.join(k)}: " + "; ".join(f"{c} {a!r} -> {b!r}" for c, a, b in bad)
                     + " (stored -> here)")
    if len(diffs) > 25:
        lines.append(f"   ... and {len(diffs) - 25} more")
    if not common:
        return lines, "COMPARE RESULT: NOTHING IN COMMON (no run here has a stored counterpart)", False
    if diffs:
        cs = ", ".join(f"{c} in {n}" for c, n in sorted(per_col.items(), key=lambda kv: -kv[1]))
        return lines, f"COMPARE RESULT: DIFFERENT ({len(diffs)} of the {common} runs in common differ: {cs})", False
    extra = []
    if only_stored:
        extra.append(f"{only_stored} stored runs were not run here")
    if only_here:
        extra.append(f"{only_here} runs here have no stored counterpart")
    scope = (f"all {common} runs" if not extra else f"the {common} runs in common; " + "; ".join(extra))
    return lines, f"COMPARE RESULT: IDENTICAL ({scope}; every compared column equal)", True


def fmt_big(c):
    return f"{c:,} ({c / 1e9:.2f} billion)" if c >= 1e9 else f"{c:,} ({c / 1e6:.1f} million)"


def change_word(code):
    """A git status code (porcelain v1, e.g. 'M', '??', 'AM') in words."""
    return ("untracked" if "?" in code else "deleted" if "D" in code else "renamed" if "R" in code
            else "added" if "A" in code else "modified")


def write_record(rdir, m, summary_text, table_lines, rows, inputs_lines):
    """Write the record files into rdir. m: the metadata (meta.json)."""
    os.makedirs(rdir, exist_ok=True)
    with open(os.path.join(rdir, "meta.json"), "w") as f:
        json.dump(m, f, indent=1)
        f.write("\n")
    with open(os.path.join(rdir, "results.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(RECORD_COLUMNS), lineterminator="\n")
        w.writeheader()
        w.writerows(rows)
    with open(os.path.join(rdir, "summary.md"), "w") as f:
        f.write(summary_text)
    with open(os.path.join(rdir, "inputs.sha256"), "w") as f:
        f.write("\n".join(inputs_lines) + "\n")
    fg, run, src = m["figures"], m["run"], m["inputs"]
    what = f"suite `{m['suite']['name']}`" if m.get("suite") else f"set `{m['set']['name']}`"
    L = [f"# FreeRTOS differential campaign: {what}", "",
         f"Recorded on {run['date']} at commit {src.get('commit_short') or '(no git metadata)'}.", "",
         f"**STATUS: {m['status']}**. {m['status_note']}", "", "## Figures", ""]
    if m["quoted_in"]:
        L += ["Where they are quoted:", ""] + [f"- {q}" for q in m["quoted_in"]] + [""]
    else:
        L += ["Not quoted in the documentation when this record was made.", ""]
    L += ["Measured by this run:", "",
          "| target | runs | passed | with the branch predictor on | simulated cycles |", "|---|---|---|---|---|"]
    L += [f"| {t['target']} | {t['runs']} | {t['passed']} | {t['bpred_on'] if t['target'] != 'golden' else '-'} "
          f"| {fmt_big(t['cycles'])} |" for t in fg["targets"]]
    L += [""] + [f"- {t['target']}: {t['twins']} runs with a golden twin, {t['diverged']} diverged from it"
                 for t in fg["targets"] if t["twins"] is not None]
    if fg.get("duplicates"):
        L.append(f"- {fg['duplicates']}")
    L += ["", "```text", fg["campaign_result"], "```", "", "## Command", "",
          "From the root of a clean clone (tools as in docs/BUILDING.md):", "", "```bash", m["command"], "```", "",
          "To check a re-run against this record:", "", "```bash",
          m["reproduce"].replace(" --compare ", " \\\n    --compare "), "```", "",
          "`--jobs` sets only the number of simulations run in parallel"
          + (" and `--wall-limit 0` lifts the per-run wall-clock limit; neither changes a result."
             if m["run"]["wall_limit"] == "none" else "; it changes no result.")
          + " The per-run logs (`sim.log`, and `cmd.txt` with the exact simulator command of the run) and the "
          "ELF files are not kept in the record; the command writes them under its output directory (`--out`, "
          "by default under `build/freertos-campaign/`).", ""]
    if m.get("suite"):
        L += [f"Suite `{m['suite']['name']}`: {m['suite']['about']}. It runs the entries below in one pool; each "
              f"is equivalent to `python3 test/freertos/campaign.py <options>`:", "",
              "| entry | options |", "|---|---|"]
        L += [f"| {e['name']} | `{e['options']}` |" for e in m["suite"]["entries"]]
        L.append("")
    L += ["## Inputs", "", f"- Base commit: `{src.get('commit') or 'unknown (no git metadata)'}`"
          + (f" (committed {src['commit_date']})" if src.get("commit_date") else ""), ""]
    if src.get("commit"):
        L += ["| input | git object at the base commit | working tree |", "|---|---|---|"]
        for rel, e in src["inputs"].items():
            ch = e.get("changes") or []
            wt = ("as committed" if not ch else
                  "<br>".join(f"{change_word(c['status'])}: `{c['path']}`"
                              + (f" sha256 `{c['sha256']}`" if c["sha256"] else "") for c in ch))
            obj = f"`{e['object']}`" if e.get("object") else "(not in the commit)"
            L.append(f"| `{rel}` | {obj} | {wt} |")
    else:
        L += ["| input | sha256 manifest digest |", "|---|---|"]
        L += [f"| `{rel}` | `{e.get('sha256') or e.get('sha256_manifest')}` |" for rel, e in src["inputs"].items()]
    L += ["", f"- Program images: [inputs.sha256](inputs.sha256) lists the sha256 of the {m['programs']} ELF files and "
          f"their `init.mem` images (the image a simulator loads; the `image` column of results.csv holds its first "
          f"{IMAGE_DIGITS} hex digits)."]
    L += [f"- {k}: {v}" for k, v in (("Verilator", m["tools"]["verilator"]), ("GCC", m["tools"]["gcc"]),
                                     ("Binutils", m["tools"]["binutils"]), ("Python", m["tools"]["python"]))]
    L += ["", "## Run", "",
          f"- Date: {run['date']}; from {run['started_utc']} to {run['finished_utc']} (UTC); wall time "
          f"{run['wall_s']:.0f} s",
          f"- Workers: {run['workers']} parallel simulations",
          f"- Host: {m['host']['cpu']}, {m['host']['threads']} hardware threads, {m['host']['os']}", "",
          "## Result", "",
          "The summary as printed (the per-run table is in [summary.md](summary.md), one row per run in "
          "[results.csv](results.csv)):", "", "```text"]
    L += (table_lines + [""] if len(table_lines) <= 40 else []) + summary_text_body(summary_text) + ["```", ""]
    if m.get("comparison"):
        c = m["comparison"]
        L += ["## Comparison", "", f"With `{c['stored']}`:", "", "```text"] + c["lines"] + [c["verdict"], "```", ""]
    L += ["## Caveats", ""] + [f"- {c}" for c in m["caveats"]] + [""]
    with open(os.path.join(rdir, "RECORD.md"), "w") as f:
        f.write("\n".join(L))


def summary_text_body(text):
    """The summary part of summary.md (from '## Summary' on)."""
    lines = text.rstrip("\n").splitlines()
    i = next((n for n, l in enumerate(lines) if l.startswith("## Summary")), 0)
    return lines[i:]


# --------------------------------------------------------------------------- campaign
def main():
    ap = argparse.ArgumentParser(description=__doc__, epilog=suites_help(),
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--set", help="variant set: quick, validate, standard, full, realtick, ticksweep; "
                    "breaker, breaker2, breaker-long (brk program); bpred (branch predictor on)")
    ap.add_argument("--suite", metavar="NAME",
                    help="run a suite instead of a set: several sets, each with its own seeds and run shape, "
                         "in one pool (see 'suites' below)")
    ap.add_argument("--apps", help="comma-separated subset of programs")
    ap.add_argument("--only", metavar="REGEX", help="run only the variants whose name matches REGEX")
    ap.add_argument("--dut", action="append", default=[], metavar="NAME=ROOT",
                    help="DUT tree to test (repeatable); default dut=<this repo>")
    ap.add_argument("--no-golden", action="store_true", help="skip the golden reference CPU")
    ap.add_argument("--golden-only", action="store_true", help="run only the golden reference CPU")
    ap.add_argument("--golden-root", help="tree whose ref/*.so + peripherals build the golden model "
                                          "(default: the first --dut)")
    ap.add_argument("--seeds", type=int, help="interrupt-timing seeds per variant")
    ap.add_argument("--seed-base", type=lambda s: int(s, 0),
                    help="first seed (16-bit, consecutive seeds follow)")
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--run-cycles", type=int,
                    help="target length of a stress/minimal/mzba/brk run in cycles")
    ap.add_argument("--max-checks", type=int,
                    help="upper bound on check periods per run (raise it for very long --run-cycles)")
    ap.add_argument("--out")
    ap.add_argument("--kernel", default=os.environ.get("FREERTOS_KERNEL"),
                    help="FreeRTOS-Kernel tree (default: $FREERTOS_KERNEL, else the Makefile's default, "
                         "the copy vendored in third_party/freertos or $FREERTOS_HOME)")
    ap.add_argument("--demo", default=os.environ.get("FREERTOS_DEMO"),
                    help="FreeRTOS/FreeRTOS/Demo tree (default: $FREERTOS_DEMO, else the Makefile's default)")
    ap.add_argument("--list", action="store_true", help="list the variants and exit")
    ap.add_argument("--no-uart-check", action="store_true",
                    help="do not fail runs whose UART pattern lines arrive corrupted (still counted)")
    ap.add_argument("--strict", action="store_true",
                    help="exit status 1 if any DUT run did not pass (default: only golden or build "
                         "failures make the exit status non-zero)")
    ap.add_argument("--wall-limit", type=float, metavar="SECONDS",
                    help="wall-clock limit per run, a safety net against a simulator that stops making "
                         "progress (default: max(600, cycle limit / 150000)); 0: none. A run it stops "
                         "becomes a CRASH that a re-run need not repeat")
    ap.add_argument("--record", metavar="DIR",
                    help="write a record of this campaign into DIR (by convention "
                         "results/<topic>/<date>_<commit>): RECORD.md, meta.json, results.csv, summary.md, "
                         "inputs.sha256; an existing record is never overwritten")
    ap.add_argument("--quoted-in", action="append", default=[], metavar="QUOTE",
                    help="with --record: where a figure of this campaign is quoted and how, as "
                         "'FILE:LINE: TEXT' (repeatable)")
    ap.add_argument("--note", action="append", default=[], metavar="TEXT",
                    help="with --record: a caveat to keep with the record (repeatable)")
    ap.add_argument("--compare", metavar="FILE",
                    help="compare the runs with a stored results.csv (of a record or a campaign) by set, "
                         "variant, seed and target: every deterministic column, never wall time; prints "
                         "COMPARE RESULT and exits with status 4 if anything differs")
    ap.add_argument("--results", metavar="FILE",
                    help="with --compare: run nothing, compare the runs of the results.csv FILE instead "
                         "(e.g. two records)")
    args = ap.parse_args()
    if args.results:
        if not args.compare:
            ap.error("--results goes with --compare")
        with open(args.results, newline="") as f:
            rows = list(csv.DictReader(f))
        clines, cverdict, cok = compare_runs(rows, os.path.abspath(args.compare))
        log("\n".join([f"(runs of {public_path(args.results)})"] + clines + [cverdict]))
        return 0 if cok else 4
    if args.suite is not None:
        if args.suite not in SUITES:
            ap.error(f"unknown --suite {args.suite} (suites: {', '.join(SUITES)})")
        fixed = [o for o, v in (("--set", args.set), ("--seeds", args.seeds), ("--seed-base", args.seed_base),
                                ("--run-cycles", args.run_cycles), ("--max-checks", args.max_checks))
                 if v is not None]
        if fixed:
            ap.error(f"{', '.join(fixed)} cannot be combined with --suite: the suite sets the set, the seeds "
                     f"and the run shape of each of its entries")
    for o, d in (("set", "quick"), ("seeds", DEFAULT_SEEDS), ("seed_base", DEFAULT_SEED_BASE),
                 ("run_cycles", DEFAULT_RUN_CYCLES), ("max_checks", DEFAULT_MAX_CHECKS)):
        if getattr(args, o) is None:
            setattr(args, o, d)
    if (args.quoted_in or args.note) and not args.record:
        ap.error("--quoted-in and --note belong to --record")
    if args.record and not args.list:
        args.record = os.path.abspath(args.record)
        if any(os.path.exists(os.path.join(args.record, f)) for f in ("RECORD.md", "meta.json")):
            ap.error(f"--record {args.record}: a record exists there already (records are not overwritten)")
    if args.compare and not args.list:
        args.compare = os.path.abspath(args.compare)
        if not os.path.isfile(args.compare):
            ap.error(f"--compare {args.compare}: no such file")
    if args.wall_limit is not None and args.wall_limit < 0:
        ap.error("--wall-limit must be 0 (none) or positive")
    global MAX_CHECKS
    MAX_CHECKS = args.max_checks
    suite = args.suite

    def keep(variants):
        if args.apps:
            ks = set(args.apps.split(","))
            variants = [v for v in variants if v.app in ks]
        if args.only:
            variants = [v for v in variants if re.search(args.only, v.name)]
        return variants

    if suite is None:
        variants = variant_sets(args, args.run_cycles, args.max_checks).get(args.set)
        if variants is None:
            ap.error(f"unknown --set {args.set}")
        variants = keep(variants)
        entries = [Entry(args.set, args.set, args.seeds, args.seed_base, args.run_cycles, args.max_checks,
                         variants, "")]
        seeds = entries[0].seeds
    else:
        entries = suite_entries(suite, args, keep)
    label = (lambda e, v: v.name) if suite is None else (lambda e, v: f"{e.name}/{v.name}")
    if args.list and suite is None:
        for v in variants:
            log(f"{v.name:55s} ram={v.ram_kb}K run={v.run_ticks} ticks ({v.nchecks}x{v.check_ticks})"
                f" timeout={v.timeout_cycles()} golden={'yes' if v.golden_ok else 'no'}")
        return 0
    duts = []
    for d in args.dut or [f"dut={REPO}"]:
        name, _, root = d.partition("=")
        duts.append((name, os.path.abspath(root)))
    golden_root = os.path.abspath(args.golden_root) if args.golden_root else duts[0][1]
    targets = [] if args.golden_only else [(n, r, "dut") for n, r in duts]
    if not args.no_golden:
        targets.append(("golden", golden_root, "ref"))

    def count(e):
        """(DUT runs, of them with the branch predictor on, golden runs) of entry e"""
        nd = sum(t[2] == "dut" for t in targets) * len(e.seeds)
        ng = len(e.seeds) if any(t[2] == "ref" for t in targets) else 0
        return (nd * len(e.variants), nd * sum(v.bpred != 0 for v in e.variants),
                ng * sum(v.golden_ok for v in e.variants))

    if args.list:
        tot = [0, 0, 0, 0]
        log(f"suite {suite}: {SUITES[suite]['about']}")
        for e in entries:
            nd, nb, ng = count(e)
            tot = [tot[0] + len(e.variants), tot[1] + nd, tot[2] + nb, tot[3] + ng]
            log(f"== {e.name}: {e.options()} ({len(e.variants)} variants, seeds "
                f"{e.seeds[0]:04x}-{e.seeds[-1]:04x}; {nd} DUT runs, {nb} with the branch predictor on; "
                f"{ng} golden runs)")
            for v in e.variants:
                log(f"   {v.name:55s} ram={v.ram_kb}K run={v.run_ticks} ticks ({v.nchecks}x{v.check_ticks})"
                    f" timeout={v.timeout_cycles()} golden={'yes' if v.golden_ok else 'no'}")
        log(f"total: {tot[0]} variants; {tot[1]} DUT runs ({tot[2]} with the branch predictor on), "
            f"{tot[3]} golden runs: {tot[1] + tot[3]} simulation runs")
        return 0

    if args.out is None:
        args.out = os.path.join(tree_build(REPO, "dut")[0], "freertos-campaign")
        if suite is not None:
            args.out = os.path.join(args.out, suite)
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    # FreeRTOS sources: only what was given; otherwise the Makefile's defaults apply
    fenv = {k: os.path.abspath(v) for k, v in (("FREERTOS_KERNEL", args.kernel),
                                               ("FREERTOS_DEMO", args.demo)) if v}
    t_start = time.time()
    if args.record:
        fp_start = source_fingerprints()

    # ---- 1. simulator models (per target and RAM size)
    rams = sorted({v.ram_kb for e in entries for v in e.variants})
    log(f"== building simulator models: {[t[0] for t in targets]} x RAM {rams} KiB")
    models, jobs = {}, []
    # A relocated build directory gets copies of ref/*.so (the Makefile's $(BUILD_DIR)/ref/%.so
    # rule). Make them once, one tree at a time, before the parallel model builds: two makes
    # copying the same file at once can fail with "File exists".
    for tname, root, cpu in targets:
        bdir, bvars = tree_build(root, tname)
        sos = [os.path.join(bdir, "ref", os.path.basename(p))
               for p in sorted(glob.glob(os.path.join(root, "ref", "*.so")))]
        if bvars and sos:
            lf = os.path.join(out, "logs", f"model-{tname}-ref.log")
            os.makedirs(os.path.dirname(lf), exist_ok=True)
            if not make(root, sos, bvars, lf, fenv):
                log(f"   copying ref/*.so for {tname} FAILED, see logs/model-{tname}-ref.log")
                return 3
    with cf.ThreadPoolExecutor(max_workers=max(1, min(args.jobs, 4))) as ex:
        for (tname, root, cpu), ram in itertools.product(targets, rams):
            lf = os.path.join(out, "logs", f"model-{tname}-{ram}k.log")
            os.makedirs(os.path.dirname(lf), exist_ok=True)
            bdir, bvars = tree_build(root, tname)
            models[(tname, ram)] = os.path.join(bdir, "frtos-model", f"{cpu}-{ram}k", "top")
            jobs.append((tname, ram, ex.submit(make, root, "frtos-model",
                                               dict(bvars, FRTOS_CPU=cpu, FRTOS_RAM_KB=ram), lf, fenv)))
        for tname, ram, fut in jobs:
            if not fut.result():
                log(f"   model {tname}/{ram}k FAILED to build, see logs/model-{tname}-{ram}k.log")
                return 3

    # ---- 2. ELFs (each variant once, from this repo)
    nvar = sum(len(e.variants) for e in entries)
    log(f"== building {nvar} program variants" + ("" if suite is None else f" ({len(entries)} entries)"))
    built = {}
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        futs = {}
        for e in entries:
            for v in e.variants:
                vdir = os.path.join(out, e.sub, "elf", v.name)
                mv = dict(v.make_vars(), FRTOS_OUT=vdir)
                lf = os.path.join(out, e.sub, "logs", f"build-{v.name}.log")
                os.makedirs(os.path.dirname(lf), exist_ok=True)
                futs[ex.submit(make, REPO, "frtos-elf", mv, lf, fenv)] = (e, v)
        for fut in cf.as_completed(futs):
            e, v = futs[fut]
            built[label(e, v)] = fut.result()
            if not built[label(e, v)]:
                log(f"   BUILD FAILED: {label(e, v)} ({os.path.join(e.sub, 'logs', f'build-{v.name}.log')})")
    # program images: (entry, variant) -> sha256 of init.mem, and of out.elf
    images, elves = {}, {}
    for e in entries:
        for v in e.variants:
            if built[label(e, v)]:
                vdir = os.path.join(out, e.sub, "elf", v.name)
                images[(e.name, v.name)] = sha256_file(os.path.join(vdir, "init.mem"))
                elves[(e.name, v.name)] = sha256_file(os.path.join(vdir, "out.elf"))

    # ---- 3. runs
    runs = []
    for e in entries:
        for v in e.variants:
            if not built[label(e, v)]:
                continue
            for s in e.seeds:
                for tname, root, cpu in targets:
                    if cpu == "ref" and not v.golden_ok:
                        continue
                    runs.append((e, v, s, tname))
    if suite is None:
        log(f"== {len(runs)} simulation runs on {args.jobs} workers "
            f"({len(variants)} variants x {len(seeds)} seeds x targets)")
    else:
        per = ", ".join(f"{e.name} {sum(r[0] is e for r in runs)}" for e in entries)
        log(f"== {len(runs)} simulation runs on {args.jobs} workers ({len(entries)} entries: {per})")
        # longest first (the golden CPU simulates more slowly), for a short tail
        runs.sort(key=lambda r: -r[1].timeout_cycles() * (3 if r[3] == "golden" else 2))
    killed = set()

    def do_run(e, v, seed, tname):
        rdir = os.path.join(out, e.sub, "runs", tname, v.name, f"s{seed:04x}")
        os.makedirs(rdir, exist_ok=True)
        mem = os.path.join(rdir, "init.mem")
        if os.path.lexists(mem):
            os.unlink(mem)
        os.symlink(os.path.join(out, e.sub, "elf", v.name, "init.mem"), mem)
        tmo = v.timeout_cycles()
        cmd = [models[(tname, v.ram_kb)], "+nodump", f"+timeout={tmo}", f"+switches={seed:x}"]
        with open(os.path.join(rdir, "cmd.txt"), "w") as f:   # enough to reproduce this run
            f.write("# ELF: make frtos-elf " + " ".join(f"{k}='{x}'" for k, x in v.make_vars().items())
                    + "\n# run (in this directory):\n" + " ".join(cmd) + "\n")
        t0 = time.time()
        wall = max(600, tmo / 150_000) if args.wall_limit is None else (args.wall_limit or None)
        with open(os.path.join(rdir, "sim.log"), "w") as f:
            try:
                subprocess.run(cmd, cwd=rdir, stdout=f, stderr=subprocess.STDOUT,
                               preexec_fn=limit_resources, timeout=wall)
            except subprocess.TimeoutExpired:
                f.write("\nWALL-CLOCK TIMEOUT\n")
                killed.add((e.name, v.name, f"{seed:04x}", tname))
        with open(os.path.join(rdir, "sim.log"), errors="replace") as f:
            r = parse_log(f.read(), tmo, uart_check=not args.no_uart_check)
        r.update(variant=v.name, app=v.app, march=v.march, opt=v.opt, preempt=v.preempt, bpred=v.bpred,
                 slice=v.slice, tick=v.tick, heap=v.heap, tag=v.tag, ram_kb=v.ram_kb, seed=f"{seed:04x}",
                 target=tname, wall_s=round(time.time() - t0, 1), log=os.path.relpath(rdir, out))
        if suite is not None:
            r = dict({"set": e.name}, **r)
        return r

    results, done = [], 0
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        futs = [ex.submit(do_run, *r) for r in runs]
        for fut in cf.as_completed(futs):
            r = fut.result()
            results.append(r)
            done += 1
            if r["status"] != "PASS" or done % 10 == 0 or done == len(runs):
                name = r["variant"] if suite is None else f"{r['set']}/{r['variant']}"
                log(f"   [{done}/{len(runs)}] {r['target']:8s} {name} s{r['seed']}: {r['status']}"
                    f" {fmt_cycles(r['cycles'])} {r['reason'][:100]}")

    # ---- 4. report
    tnames = [t[0] for t in targets]
    vobj = {(e.name, v.name): v for e in entries for v in e.variants}
    rkey = (lambda r: (r["variant"], r["seed"])) if suite is None else (lambda r: (r["set"], r["variant"], r["seed"]))
    by = {rkey(r) + (r["target"],): r for r in results}
    keys = sorted({rkey(r) for r in results})
    with open(os.path.join(out, "results.json"), "w") as f:
        json.dump(results, f, indent=1)
    with open(os.path.join(out, "results.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(results[0].keys()) if results else ["variant"],
                           lineterminator="\n")
        w.writeheader()
        for r in sorted(results, key=lambda r: rkey(r) + (r["target"],)):
            w.writerow(r)

    lines = []
    hdr = ("| variant | seed | " if suite is None else "| set | variant | seed | ") + " | ".join(tnames) + " |"
    lines += [hdr, "|" + "---|" * ((2 if suite is None else 3) + len(tnames))]
    for k in keys:
        cells = []
        for t in tnames:
            r = by.get(k + (t,))
            if r is None:
                cells.append("n/a")
            elif r["status"] == "PASS":
                cells.append(f"PASS {fmt_cycles(r['cycles'])}")
            else:
                cells.append(f"**{r['status']}** {fmt_cycles(r['cycles'])}: {r['reason'][:70]}")
        lines.append("| " + " | ".join(k) + " | " + " | ".join(cells) + " |")

    summ = ["", "## Summary", "",
            "| target | runs | PASS | FAIL | of which UART transcript only | HANG | CRASH "
            "| vs golden: runs with a golden twin | diverged |",
            "|---|---|---|---|---|---|---|---|---|"]
    golden_bad = [r for r in results if r["target"] == "golden" and r["status"] != "PASS"]
    build_bad = sorted(n for n, ok in built.items() if not ok)
    if build_bad:
        summ += ["", f"**{len(build_bad)} variant(s) failed to build and were not run:** "
                 + ", ".join(build_bad) + " (see logs/build-*.log)"]
    tstats = []
    for t in tnames:
        rs = [r for r in results if r["target"] == t]
        cnt = {s: sum(r["status"] == s for r in rs) for s in ("PASS", "FAIL", "HANG", "CRASH")}
        twins = [r for r in rs if rkey(r) + ("golden",) in by and t != "golden"]
        div = [r for r in twins if by[rkey(r) + ("golden",)]["status"] == "PASS"
               and r["status"] != "PASS"]
        uo = sum(r["status"] == "FAIL" and r.get("uart_only", False) for r in rs)
        summ.append(f"| {t} | {len(rs)} | {cnt['PASS']} | {cnt['FAIL']} | {uo} | {cnt['HANG']} | {cnt['CRASH']} | "
                    f"{len(twins) if t != 'golden' else '-'} | {len(div) if t != 'golden' else '-'} |")
        tstats.append({"target": t, "runs": len(rs), "passed": cnt["PASS"], "fail": cnt["FAIL"],
                       "hang": cnt["HANG"], "crash": cnt["CRASH"], "uart_only": uo,
                       "bpred_on": sum(r["bpred"] != 0 for r in rs),
                       "cycles": sum(r["cycles"] or 0 for r in rs),
                       "twins": len(twins) if t != "golden" else None,
                       "diverged": len(div) if t != "golden" else None})
    dup_text, per_entry = None, []
    if suite is not None:
        # Per entry, and the runs that repeat a run of an earlier entry exactly: the same
        # program image, seed, simulator and cycle limit.
        summ += ["", "### Per entry", "",
                 "| entry | equivalent options | variants | DUT runs (predictor on) | DUT passed | golden runs "
                 "| golden passed | DUT Gcycles | golden Gcycles | simulation time (s) |",
                 "|---|---|---|---|---|---|---|---|---|---|"]
        for e in entries + [None]:
            rs = [r for r in results if e is None or r["set"] == e.name]
            d = [r for r in rs if r["target"] != "golden"]
            g = [r for r in rs if r["target"] == "golden"]
            row = {"entry": e.name if e else "total", "options": e.options() if e else "",
                   "variants": len(e.variants) if e else nvar, "dut_runs": len(d),
                   "dut_bpred_on": sum(r["bpred"] != 0 for r in d), "dut_passed": sum(r["status"] == "PASS" for r in d),
                   "golden_runs": len(g), "golden_passed": sum(r["status"] == "PASS" for r in g),
                   "dut_cycles": sum(r["cycles"] or 0 for r in d), "golden_cycles": sum(r["cycles"] or 0 for r in g),
                   "sim_s": round(sum(r["wall_s"] for r in rs))}
            per_entry.append(row)
            opts = f"`{row['options']}`" if row["options"] else ""
            summ.append(f"| {row['entry']} | {opts} | {row['variants']} | {row['dut_runs']} ({row['dut_bpred_on']}) | "
                        f"{row['dut_passed']} | {row['golden_runs']} | {row['golden_passed']} | "
                        f"{row['dut_cycles'] / 1e9:.2f} | {row['golden_cycles'] / 1e9:.2f} | {row['sim_s']} |")
        first, dups = {}, {}
        order = {e.name: i for i, e in enumerate(entries)}
        for r in sorted(results, key=lambda r: (order[r["set"]], r["variant"], r["seed"], r["target"])):
            v = vobj[(r["set"], r["variant"])]
            k = (r["target"], v.ram_kb, images[(r["set"], r["variant"])], r["seed"], v.timeout_cycles())
            if k in first:
                dups.setdefault(r["target"], []).append((first[k], r))
            else:
                first[k] = r
        same = lambda a, b: all(a[c] == b[c] for c in ("status", "reason", "cycles", "uart_lines", "uart_bad"))
        ndup = {t: len(dups.get(t, [])) for t in tnames}
        nagree = sum(same(a, b) for t in dups for a, b in dups[t])
        ndut = sum(1 for r in results if r["target"] != "golden")
        if any(ndup.values()):
            dup_text = (f"exact duplicates (the same program image, seed, simulator and cycle limit as a run of an "
                        f"earlier entry): " + ", ".join(f"{n} {t}" for t, n in ndup.items() if n)
                        + f" runs; {nagree} of {sum(ndup.values())} gave the same result as the run they repeat; "
                        f"distinct DUT runs: {ndut - sum(n for t, n in ndup.items() if t != 'golden')}")
        else:
            dup_text = "exact duplicates: none"
        summ += ["", "Simulation time: the sum of the runs' wall-clock times (the entries share one pool of "
                 f"{args.jobs} workers).", "", f"Runs: {dup_text}."]
    summ += ["", "### Failure signatures", ""]
    for t in tnames:
        hist = {}
        for r in results:
            if r["target"] == t and r["status"] != "PASS":
                k = f"{r['status']}: {short_reason(r['reason'])}"
                hist[k] = hist.get(k, 0) + 1
        if hist:
            summ.append(f"**{t}**")
            summ += [f"- {n} x {k}" for k, n in sorted(hist.items(), key=lambda kv: -kv[1])]
            summ.append("")
    verdict = []
    if not args.no_golden:
        ng = sum(r["target"] == "golden" for r in results)
        if golden_bad:
            verdict.append(f"HARNESS CHECK FAILED: golden did not pass {len(golden_bad)}/{ng} runs "
                           f"(those variants are invalid as differential tests)")
        else:
            verdict.append(f"harness check: golden passed all {ng} runs")
    for t in tnames:
        if t == "golden":
            continue
        rs = [r for r in results if r["target"] == t]
        bad = [r for r in rs if r["status"] != "PASS"]
        uo = [r for r in bad if r["status"] == "FAIL" and r.get("uart_only", False)]
        verdict.append(f"{t}: {len(rs) - len(bad)}/{len(rs)} runs passed"
                       + (f" ({len(uo)} of the {len(bad)} failures only in the UART transcript check;"
                          f" {len(bad) - len(uo)} failed otherwise)" if uo else ""))
    if build_bad:
        verdict.append(f"BUILD FAILURES: {len(build_bad)} variant(s) not run")
    if killed and (suite or args.record or args.compare):
        verdict.append(f"WALL-CLOCK LIMIT: {len(killed)} run(s) stopped by the wall-clock limit (not repeatable)")
    dut_bad = [r for r in results if r["target"] != "golden" and r["status"] != "PASS"]
    summ += ["### Verdict", ""] + [f"- {v}" for v in verdict]
    t_end = time.time()
    summ.append(f"\n(wall time {t_end - t_start:.0f} s; logs under {out})")
    ok = not (golden_bad or build_bad or dut_bad)
    result_line = (f"CAMPAIGN RESULT: {'PASS' if ok else 'FAIL'} ({len(results)} runs: "
                   f"{len(dut_bad)} DUT run(s) not passed, {len(golden_bad)} golden run(s) not passed, "
                   f"{len(build_bad)} build failure(s))")
    summ.append("\n" + result_line)

    title = ("# FreeRTOS differential campaign: " + args.set if suite is None
             else "# FreeRTOS differential campaign: suite " + suite)
    summary_text = title + "\n\n" + "\n".join(lines + summ) + "\n"
    with open(os.path.join(out, "summary.md"), "w") as f:
        f.write(summary_text)
    log("\n".join([""] + lines + summ))

    # ---- 5. comparison with stored results, record
    rows = record_rows([r if "set" in r else dict(r, set=args.set) for r in results], vobj,
                       images) if (args.compare or args.record) else []
    comparison = None
    if args.compare:
        clines, cverdict, cok = compare_runs(rows, args.compare)
        log("\n".join([""] + clines + [cverdict]))
        comparison = {"stored": public_path(args.compare), "lines": clines, "verdict": cverdict, "identical": cok}
    if args.record:
        write_campaign_record(args, suite, entries, targets, results, rows, images, elves, killed, tstats,
                              per_entry, dup_text, result_line, summary_text.replace(out, public_path(out)),
                              lines, comparison, fp_start, t_start, t_end)
        log(f"\n== record written to {args.record}")
    if golden_bad or build_bad:
        return 2
    if comparison and not comparison["identical"]:
        return 4
    return 1 if (args.strict and dut_bad) else 0


def write_campaign_record(args, suite, entries, targets, results, rows, images, elves, killed, tstats,
                          per_entry, dup_text, result_line, summary_text, table_lines, comparison, fp_start,
                          t_start, t_end):
    """Write the record of a finished campaign into args.record (see write_record)."""
    fp = source_fingerprints()
    caveats = []
    changed = [c for e in fp["inputs"].values() for c in e.get("changes") or []]
    if fp.get("commit") and changed:
        caveats.append("The working tree differed from the base commit in these inputs: "
                       + ", ".join(f"`{c['path']}` ({change_word(c['status'])})" for c in changed)
                       + "; their sha256 are under Inputs.")
    moved = [rel for rel in sorted(set(fp["inputs"]) | set(fp_start["inputs"]))
             if fp["inputs"].get(rel) != fp_start["inputs"].get(rel)]
    if moved or fp.get("commit") != fp_start.get("commit"):
        caveats.append("Inputs changed while the campaign ran: " + ", ".join(f"`{r}`" for r in moved or ["HEAD"])
                       + " (fingerprints at its start and end differ); the end state is recorded.")
    if not fp.get("commit"):
        caveats.append("No git metadata: the inputs are identified by sha256 manifest digests only.")
    ext = freertos_sources(args)
    if ext:
        caveats.append(f"FreeRTOS sources other than the vendored third_party/freertos were used ({ext}); "
                       "their content is not fingerprinted.")
    others = [(n, r) for n, r, c in targets if not same_dir(r, REPO)]
    if others:
        caveats.append("Trees other than this repository were simulated ("
                       + ", ".join(f"{n}={public_path(r)}" for n, r in others) + "); only this repository is "
                       "fingerprinted.")
    if killed:
        caveats.append(f"{len(killed)} run(s) were stopped by the wall-clock limit; they are not repeatable: "
                       + ", ".join(" ".join(k) for k in sorted(killed)[:10]))
    caveats.append("Wall times depend on the host and its load; every other column of results.csv is "
                   "deterministic.")
    caveats += args.note
    status, note = "repeatable", ("The simulations are deterministic: the command below reproduces every status "
                                  "and cycle count of results.csv, which `--compare` checks run for run.")
    if killed:
        status, note = "repeatable except the runs stopped by the wall-clock limit", (
            "Re-run with `--wall-limit 0`.")
    reproduce = campaign_command(args) + " --compare " + shlex.quote(
        os.path.join(public_path(args.record), "results.csv"))
    started = datetime.datetime.fromtimestamp(t_start, datetime.timezone.utc)
    finished = datetime.datetime.fromtimestamp(t_end, datetime.timezone.utc)
    inputs_lines = [
        "# FreeRTOS campaign record: program images and source fingerprints.",
        "# The sha256sum lines name the files the campaign built, relative to its output directory (--out).",
        "# After re-running the command of RECORD.md: cd <out> && grep -v '^#' <this file> | sha256sum -c",
        "# init.mem is the program image the simulators load. The ELF files also carry debug information",
        "# that holds the absolute path of the checkout, so their hashes match only at the same path:",
        "# they are kept as '# elf' comments, which sha256sum -c does not check.",
        "#",
        f"# base commit {fp.get('commit') or 'unknown (no git metadata)'}"]
    for rel, e in fp["inputs"].items():
        if fp.get("commit"):
            inputs_lines.append(f"# {e['kind']} {e.get('object') or '(not in the commit)'}  {rel}"
                                + ("" if not e.get("changes") else "  (working tree: "
                                   + "; ".join(f"{change_word(c['status'])} {c['path']} sha256 {c['sha256']}"
                                               for c in e["changes"]) + ")"))
        else:
            inputs_lines.append(f"# sha256 manifest {e.get('sha256') or e.get('sha256_manifest')}  {rel}")
    for e in entries:
        for v in e.variants:
            if (e.name, v.name) in images:
                d = os.path.join(e.sub, "elf", v.name)
                inputs_lines += [f"{images[(e.name, v.name)]}  {os.path.join(d, 'init.mem')}",
                                 f"# elf {elves[(e.name, v.name)]}  {os.path.join(d, 'out.elf')}"]
    figures = {"targets": tstats, "campaign_result": result_line, "duplicates": dup_text,
               "dut_runs": sum(t["runs"] for t in tstats if t["target"] != "golden"),
               "dut_passed": sum(t["passed"] for t in tstats if t["target"] != "golden"),
               "dut_bpred_on": sum(t["bpred_on"] for t in tstats if t["target"] != "golden"),
               "dut_cycles": sum(t["cycles"] for t in tstats if t["target"] != "golden"),
               "golden_runs": sum(t["runs"] for t in tstats if t["target"] == "golden"),
               "golden_passed": sum(t["passed"] for t in tstats if t["target"] == "golden"),
               "golden_cycles": sum(t["cycles"] for t in tstats if t["target"] == "golden")}
    if per_entry:
        figures["per_entry"] = per_entry
    m = {"record": "freertos-campaign",
         "suite": ({"name": suite, "about": SUITES[suite]["about"],
                    "entries": [{"name": e.name, "options": e.options(), "variants": len(e.variants)}
                                for e in entries]} if suite else None),
         "set": (None if suite else {"name": args.set, "options": entries[0].options(),
                                     "variants": len(entries[0].variants)}),
         "status": status, "status_note": note, "quoted_in": args.quoted_in, "figures": figures,
         "command": campaign_command(args), "reproduce": reproduce,
         "targets": [t[0] for t in targets], "programs": len(images),
         "inputs": fp, "tools": tool_versions(), "host": host_summary(),
         "run": {"date": time.strftime("%Y-%m-%d", time.localtime(t_start)),
                 "started_utc": started.strftime("%Y-%m-%dT%H:%M:%SZ"),
                 "finished_utc": finished.strftime("%Y-%m-%dT%H:%M:%SZ"),
                 "wall_s": round(t_end - t_start, 1), "workers": args.jobs,
                 "wall_limit": "none" if args.wall_limit == 0 else (args.wall_limit or
                                                                    "max(600 s, cycle limit / 150000)"),
                 "relocated_build": bool(os.environ.get("HADES_BUILD_DIR"))},
         "comparison": comparison, "caveats": caveats}
    write_record(args.record, m, summary_text, table_lines, rows, inputs_lines)


if __name__ == "__main__":
    sys.exit(main())
