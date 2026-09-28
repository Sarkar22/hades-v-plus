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

Examples
  test/freertos/campaign.py --set quick
  test/freertos/campaign.py --set validate --dut buggy=. --dut patched=../wt-fixed
  test/freertos/campaign.py --set standard --seeds 3 --jobs 6 --out build/campaign
  test/freertos/campaign.py --set bpred --seeds 4     # branch predictor on (FRTOS_BPRED=1..3)

The branch predictor (MHPMEVENT10) is off at reset; only the variants with a
.bp<N> suffix (sets breaker, breaker2, breaker-long, bpred) switch it on. The
golden CPU reads that CSR as 0 and ignores writes, so those rv32i variants keep
their golden twin.
"""
import argparse
import concurrent.futures as cf
import csv
import itertools
import json
import os
import random
import re
import resource
import shutil
import subprocess
import sys
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
    return bd, {"BUILD_DIR": bd}

CYCLE_PS = 20                   # sim/top.sv: 20 time units (ps) per system clock
DEFAULT_TICK = 10000            # cycles per RTOS tick (5x faster than 1 kHz at 50 MHz)
NORMAL_TICK = 50000             # 1 kHz at 50 MHz, the "real" setting
# Shortest tick periods at which the golden CPU still passes (measured, see
# README.md); below these the tick handler alone saturates the CPU.
PATHOLOGICAL_TICK = {"-O2": 500, "-Os": 500, "-O0": 1500}


# --------------------------------------------------------------------------- variants
class Variant:
    def __init__(self, app, march="rv32i", opt="-O2", preempt=1, slice_=1, tick=DEFAULT_TICK,
                 heap=4, defs=(), tag="", ram_kb=None, run_cycles=5_000_000, bpred=0):
        self.app, self.march, self.opt, self.bpred = app, march, opt, bpred
        self.preempt, self.slice, self.tick, self.heap = preempt, slice_, tick, heap
        self.defs, self.tag = tuple(defs), tag
        self.ram_kb = ram_kb or default_ram_kb(app, opt)
        self.nchecks, self.check_ticks = run_shape(app, tick, run_cycles, opt, march)
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
MAX_CHECKS = 40                 # --max-checks: longer --run-cycles runs need more periods
MIN_CHECK_CYCLES = {"stress": 400_000, "mzba-m": 400_000, "mzba-i": 1_000_000, "brk": 1_000_000}


def run_shape(app, tick, run_cycles, opt="-O2", march="rv32i"):
    """(checks, ticks per check) so that a run lasts about run_cycles."""
    if app == "full":
        return 3, 5000              # the official demo's 5 s check period
    if app == "minimal":
        return 1, max(60, min(4000, run_cycles // tick))
    key = app if app != "mzba" else ("mzba-i" if march == "rv32i" else "mzba-m")
    knee = 7500 if opt == "-O0" else (6000 if app in ("stress", "brk") else 3000)
    scale = 1 if tick >= knee else -(-knee // tick)          # same back-off as the programs
    min_cycles = MIN_CHECK_CYCLES[key] * scale * (5 if opt == "-O0" else 2) // 2
    check_ticks = max(10, -(-min_cycles // tick))
    nchecks = max(4, min(MAX_CHECKS, run_cycles // (check_ticks * tick)))
    return nchecks, check_ticks


def variant_sets(args):
    V = Variant
    rc = args.run_cycles
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


# --------------------------------------------------------------------------- helpers
def log(msg):
    print(msg, flush=True)


def make(root, target, variables, logfile, extra_env=None):
    cmd = ["make", "-s", "-C", root, target] + [f"{k}={v}" for k, v in variables.items()]
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


# --------------------------------------------------------------------------- campaign
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--set", default="quick", help="variant set: quick, validate, standard, full, realtick, ticksweep; "
                    "breaker, breaker2, breaker-long (brk program); bpred (branch predictor on)")
    ap.add_argument("--apps", help="comma-separated subset of programs")
    ap.add_argument("--only", metavar="REGEX", help="run only the variants whose name matches REGEX")
    ap.add_argument("--dut", action="append", default=[], metavar="NAME=ROOT",
                    help="DUT tree to test (repeatable); default dut=<this repo>")
    ap.add_argument("--no-golden", action="store_true", help="skip the golden reference CPU")
    ap.add_argument("--golden-only", action="store_true", help="run only the golden reference CPU")
    ap.add_argument("--golden-root", help="tree whose ref/*.so + peripherals build the golden model "
                                          "(default: the first --dut)")
    ap.add_argument("--seeds", type=int, default=4, help="interrupt-timing seeds per variant")
    ap.add_argument("--seed-base", type=lambda s: int(s, 0), default=0x0001,
                    help="first seed (16-bit, consecutive seeds follow)")
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--run-cycles", type=int, default=5_000_000,
                    help="target length of a stress/minimal/mzba/brk run in cycles")
    ap.add_argument("--max-checks", type=int, default=40,
                    help="upper bound on check periods per run (raise it for very long --run-cycles)")
    ap.add_argument("--out", default=os.path.join(tree_build(REPO, "dut")[0], "freertos-campaign"))
    ap.add_argument("--kernel", default=os.environ.get("FREERTOS_KERNEL"))
    ap.add_argument("--demo", default=os.environ.get("FREERTOS_DEMO"))
    ap.add_argument("--list", action="store_true", help="list the variants and exit")
    ap.add_argument("--no-uart-check", action="store_true",
                    help="do not fail runs whose UART pattern lines arrive corrupted (still counted)")
    ap.add_argument("--strict", action="store_true",
                    help="exit status 1 if any DUT run did not pass (default: only golden or build "
                         "failures make the exit status non-zero)")
    args = ap.parse_args()
    global MAX_CHECKS
    MAX_CHECKS = args.max_checks

    variants = variant_sets(args).get(args.set)
    if variants is None:
        ap.error(f"unknown --set {args.set}")
    if args.apps:
        keep = set(args.apps.split(","))
        variants = [v for v in variants if v.app in keep]
    if args.only:
        variants = [v for v in variants if re.search(args.only, v.name)]
    if args.list:
        for v in variants:
            log(f"{v.name:55s} ram={v.ram_kb}K run={v.run_ticks} ticks ({v.nchecks}x{v.check_ticks})"
                f" timeout={v.timeout_cycles()} golden={'yes' if v.golden_ok else 'no'}")
        return 0
    if not args.kernel or not args.demo:
        ap.error("set --kernel/--demo (or FREERTOS_KERNEL/FREERTOS_DEMO); see test/freertos/README.md")

    duts = []
    for d in args.dut or [f"dut={REPO}"]:
        name, _, root = d.partition("=")
        duts.append((name, os.path.abspath(root)))
    golden_root = os.path.abspath(args.golden_root) if args.golden_root else duts[0][1]
    targets = [] if args.golden_only else [(n, r, "dut") for n, r in duts]
    if not args.no_golden:
        targets.append(("golden", golden_root, "ref"))

    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    fenv = {"FREERTOS_KERNEL": os.path.abspath(args.kernel), "FREERTOS_DEMO": os.path.abspath(args.demo)}
    t_start = time.time()

    # ---- 1. simulator models (per target and RAM size)
    rams = sorted({v.ram_kb for v in variants})
    log(f"== building simulator models: {[t[0] for t in targets]} x RAM {rams} KiB")
    models, jobs = {}, []
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
    log(f"== building {len(variants)} program variants")
    built = {}
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        futs = {}
        for v in variants:
            vdir = os.path.join(out, "elf", v.name)
            mv = dict(v.make_vars(), FRTOS_OUT=vdir)
            futs[ex.submit(make, REPO, "frtos-elf", mv, os.path.join(out, "logs", f"build-{v.name}.log"), fenv)] = v
        for fut in cf.as_completed(futs):
            v = futs[fut]
            built[v.name] = fut.result()
            if not built[v.name]:
                log(f"   BUILD FAILED: {v.name} (logs/build-{v.name}.log)")

    # ---- 3. runs
    seeds = [(args.seed_base + i) & 0xFFFF for i in range(args.seeds)]
    runs = []
    for v in variants:
        if not built[v.name]:
            continue
        for s in seeds:
            for tname, root, cpu in targets:
                if cpu == "ref" and not v.golden_ok:
                    continue
                runs.append((v, s, tname))
    log(f"== {len(runs)} simulation runs on {args.jobs} workers "
        f"({len(variants)} variants x {len(seeds)} seeds x targets)")

    def do_run(v, seed, tname):
        rdir = os.path.join(out, "runs", tname, v.name, f"s{seed:04x}")
        os.makedirs(rdir, exist_ok=True)
        mem = os.path.join(rdir, "init.mem")
        if os.path.lexists(mem):
            os.unlink(mem)
        os.symlink(os.path.join(out, "elf", v.name, "init.mem"), mem)
        tmo = v.timeout_cycles()
        cmd = [models[(tname, v.ram_kb)], "+nodump", f"+timeout={tmo}", f"+switches={seed:x}"]
        with open(os.path.join(rdir, "cmd.txt"), "w") as f:   # enough to reproduce this run
            f.write("# ELF: make frtos-elf " + " ".join(f"{k}='{x}'" for k, x in v.make_vars().items())
                    + "\n# run (in this directory):\n" + " ".join(cmd) + "\n")
        t0 = time.time()
        with open(os.path.join(rdir, "sim.log"), "w") as f:
            try:
                subprocess.run(cmd, cwd=rdir, stdout=f, stderr=subprocess.STDOUT,
                               preexec_fn=limit_resources, timeout=max(600, tmo / 150_000))
            except subprocess.TimeoutExpired:
                f.write("\nWALL-CLOCK TIMEOUT\n")
        with open(os.path.join(rdir, "sim.log"), errors="replace") as f:
            r = parse_log(f.read(), tmo, uart_check=not args.no_uart_check)
        r.update(variant=v.name, app=v.app, march=v.march, opt=v.opt, preempt=v.preempt, bpred=v.bpred,
                 slice=v.slice, tick=v.tick, heap=v.heap, tag=v.tag, ram_kb=v.ram_kb, seed=f"{seed:04x}",
                 target=tname, wall_s=round(time.time() - t0, 1), log=os.path.relpath(rdir, out))
        return r

    results, done = [], 0
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        futs = [ex.submit(do_run, *r) for r in runs]
        for fut in cf.as_completed(futs):
            r = fut.result()
            results.append(r)
            done += 1
            if r["status"] != "PASS" or done % 10 == 0 or done == len(runs):
                log(f"   [{done}/{len(runs)}] {r['target']:8s} {r['variant']} s{r['seed']}: {r['status']}"
                    f" {fmt_cycles(r['cycles'])} {r['reason'][:100]}")

    # ---- 4. report
    tnames = [t[0] for t in targets]
    by = {(r["variant"], r["seed"], r["target"]): r for r in results}
    keys = sorted({(r["variant"], r["seed"]) for r in results})
    with open(os.path.join(out, "results.json"), "w") as f:
        json.dump(results, f, indent=1)
    with open(os.path.join(out, "results.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(results[0].keys()) if results else ["variant"])
        w.writeheader()
        for r in sorted(results, key=lambda r: (r["variant"], r["seed"], r["target"])):
            w.writerow(r)

    lines = []
    hdr = "| variant | seed | " + " | ".join(tnames) + " |"
    lines += [hdr, "|" + "---|" * (2 + len(tnames))]
    for vname, seed in keys:
        cells = []
        for t in tnames:
            r = by.get((vname, seed, t))
            if r is None:
                cells.append("n/a")
            elif r["status"] == "PASS":
                cells.append(f"PASS {fmt_cycles(r['cycles'])}")
            else:
                cells.append(f"**{r['status']}** {fmt_cycles(r['cycles'])}: {r['reason'][:70]}")
        lines.append(f"| {vname} | {seed} | " + " | ".join(cells) + " |")

    summ = ["", "## Summary", "",
            "| target | runs | PASS | FAIL | of which UART transcript only | HANG | CRASH "
            "| vs golden: runs with a golden twin | diverged |",
            "|---|---|---|---|---|---|---|---|---|"]
    golden_bad = [r for r in results if r["target"] == "golden" and r["status"] != "PASS"]
    build_bad = sorted(n for n, ok in built.items() if not ok)
    if build_bad:
        summ += ["", f"**{len(build_bad)} variant(s) failed to build and were not run:** "
                 + ", ".join(build_bad) + " (see logs/build-*.log)"]
    for t in tnames:
        rs = [r for r in results if r["target"] == t]
        cnt = {s: sum(r["status"] == s for r in rs) for s in ("PASS", "FAIL", "HANG", "CRASH")}
        twins = [r for r in rs if (r["variant"], r["seed"], "golden") in by and t != "golden"]
        div = [r for r in twins if by[(r["variant"], r["seed"], "golden")]["status"] == "PASS"
               and r["status"] != "PASS"]
        uo = sum(r["status"] == "FAIL" and r.get("uart_only", False) for r in rs)
        summ.append(f"| {t} | {len(rs)} | {cnt['PASS']} | {cnt['FAIL']} | {uo} | {cnt['HANG']} | {cnt['CRASH']} | "
                    f"{len(twins) if t != 'golden' else '-'} | {len(div) if t != 'golden' else '-'} |")
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
    dut_bad = [r for r in results if r["target"] != "golden" and r["status"] != "PASS"]
    summ += ["### Verdict", ""] + [f"- {v}" for v in verdict]
    summ.append(f"\n(wall time {time.time() - t_start:.0f} s; logs under {out})")
    ok = not (golden_bad or build_bad or dut_bad)
    summ.append(f"\nCAMPAIGN RESULT: {'PASS' if ok else 'FAIL'} ({len(results)} runs: "
                f"{len(dut_bad)} DUT run(s) not passed, {len(golden_bad)} golden run(s) not passed, "
                f"{len(build_bad)} build failure(s))")

    with open(os.path.join(out, "summary.md"), "w") as f:
        f.write("# FreeRTOS differential campaign: " + args.set + "\n\n")
        f.write("\n".join(lines + summ) + "\n")
    log("\n".join([""] + lines + summ))
    if golden_bad or build_bad:
        return 2
    return 1 if (args.strict and dut_bad) else 0


if __name__ == "__main__":
    sys.exit(main())
