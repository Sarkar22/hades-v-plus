#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""matrix.py -- the verification matrix of the simulators with an instruction cache.

Runs the legs below, each a set of jobs (one configuration, one program set or one FreeRTOS
program, one or both CPUs), judges every job, checks the CACHE_STATS identities on every log of a
cached run, and keeps the verdicts, so that the whole matrix can be run over several sessions:

    python3 test/memsys/matrix.py list [<leg>...]            the legs, their jobs and estimates
    python3 test/memsys/matrix.py run  [<leg>...|all] [--jobs N] [--out DIR] [--only REGEX]
                                       [--rerun] [--dry-run]
    python3 test/memsys/matrix.py summary [--out DIR]       the table of the recorded verdicts

Configurations: the small cache (ICACHE=512) and the large one (ICACHE=8192), 16-byte lines unless
a leg says otherwise; 'standard' is the build without a slow memory. Latency profiles:

    lat0     no MEM_* option: the cache alone, latency 0 (refills at one cycle per beat)
    lat2     MEM_LAT=2: every transfer waits 2 cycles, bursts off
    rand1-3  MEM_LAT=1:8 with MEM_SEED=1, 2, 3: random 1..8 cycles per transfer
    burst    MEM_LAT=1:8 MEM_BEAT_LAT=0: random first beat, one cycle per further refill beat
    stress   MEM_LAT=1:64: beyond the interconnect timeout without the RAM's exemption
    dram     MEM_LAT=8:24 MEM_WR_LAT=1:4 MEM_BEAT_LAT=0: DRAM-like (measurements only)
    dram-nobursts  MEM_LAT=8:24 MEM_WR_LAT=1:4 without a cache: the baseline of the CPI rows

Every job runs with the scoreboard on (the default with a slow memory) and its fetch compare on.
Hard conditions for every run of both CPUs: no scoreboard mismatch, no %Fatal or %Error (every
assertion stops the simulation with one), no cycle limit reached where the program should finish,
and on every log of a cached run the CACHE_STATS identities (below). The golden CPU's verdicts are
judged as its leg says; a failure seen only on the golden CPU is marked 'golden only', to be
traced to its mechanism (a wrong answer of the memory system is a cache defect; the golden CPU's
own behaviour is recorded as a finding of the golden CPU).

CACHE_STATS identities, on every log of a cached run without a RESET line:
    i_refills = i_done + i_inflight             i_refill_cycles = wait_i_for_port + port_irefill
    i_beats = <words per line> * i_done + i_inflight_beats
    i_hits, d_loads, d_stores = the fetches, loads and stores of the SCOREBOARD line
    cycles = the cycles of the RETIRED line
and on a log with RESET lines: cycles = the cycles after the last reset (RETIRED counts every
cycle without reset since time 0; see cycles_after_last_reset).

Resuming: the verdicts are kept in <out>/matrix.json, keyed by job, with an identity of the tree
(the commit, the hash of 'git diff HEAD' and of the untracked files' names). A job whose verdict is
recorded for the same tree is not run again (--rerun runs it anyway). Jobs run longest first
(their estimated simulated cycles). Two FreeRTOS builds of the same program in one configuration
directory never run at the same time: their build directory is shared.

A leg that needs an instruction cache refuses to run in a tree whose Makefile does not know the
ICACHE option (make sim-config shows no HADES_ICACHE_BYTES define): such a tree would silently
build the uncached configuration.
"""
import argparse
import concurrent.futures as cf
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.dont_write_bytecode = True

# ------------------------------------------------------------------------------ configurations
PROFILES = {
    "lat0":   [],
    "lat2":   ["MEM_LAT=2"],
    "rand1":  ["MEM_LAT=1:8", "MEM_SEED=1"],
    "rand2":  ["MEM_LAT=1:8", "MEM_SEED=2"],
    "rand3":  ["MEM_LAT=1:8", "MEM_SEED=3"],
    "burst":  ["MEM_LAT=1:8", "MEM_BEAT_LAT=0"],
    "stress": ["MEM_LAT=1:64"],
    "dram":   ["MEM_LAT=8:24", "MEM_WR_LAT=1:4", "MEM_BEAT_LAT=0"],
    # the uncached baseline of the CPI measurement: two ports, bursts off
    "dram-nobursts": ["MEM_LAT=8:24", "MEM_WR_LAT=1:4"],
}
CACHES = {"i512": ["ICACHE=512"], "i8k": ["ICACHE=8192"], "standard": [],
          "i512-line8": ["ICACHE=512", "LINE=8"], "i512-line32": ["ICACHE=512", "LINE=32"],
          "i512-line64": ["ICACHE=512", "LINE=64"]}
# the automatic FreeRTOS tick factor F of each profile with a cache (test/freertos/freertos.mk)
TICK_FACTOR = {"lat0": 2, "lat2": 4, "rand1": 7, "rand2": 7, "rand3": 7, "burst": 7, "stress": 35}

# Simulated cycles of the runs, for the order (longest first); FreeRTOS runs per program and tick
# factor (estimates: the program's ticks times the tick, see the cache documentation)
FRTOS_TICKS = {"minimal": 312, "stress": 508, "mzba": 580, "full": 15050, "brk": 400}


def config(cache, profile):
    return CACHES[cache] + ([] if cache == "standard" and profile == "std" else PROFILES[profile])


def cname(cache, profile):
    return cache if profile == "std" else f"{cache}-{profile}"


# ------------------------------------------------------------------------------ the logs
CACHE_STATS = re.compile(r"^CACHE_STATS (.*)$", re.M)
LINE_BYTES = re.compile(r"^CACHE I-cache \d+ bytes, (\d+)-byte lines", re.M)
SCOREBOARD_PASS = re.compile(r"^SCOREBOARD: PASS\s+(\d+) fetches, (\d+) loads, (\d+) stores", re.M)
RETIRED = re.compile(r"^RETIRED cycles=(\d+)", re.M)
RESET = re.compile(r"^RESET at cycle (\d+) \(\+reset_at=(\d+)\): (.*)$", re.M)
# The cycles with rst = 1 at the start of a run (rtl/mcu.sv: rst is set at time 0 and cleared at
# the first edge). Used only to relate RESET lines to RETIRED; checked on the first reset runs.
INITIAL_RESET_CYCLES = 1


def stats_of(text):
    m = CACHE_STATS.search(text)
    return {k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", m.group(1))} if m else None


def cycles_after_last_reset(text):
    """The cycles with rst = 0 after the last mid-run reset: RETIRED's cycles minus those before it.
    A RESET line names the cycle of the testbench's cycle count in which rst was 1; every earlier
    mid-run reset and the initial reset cycles are not counted by RETIRED."""
    resets = [int(m.group(1)) for m in RESET.finditer(text)]
    r = RETIRED.search(text)
    if not resets or not r:
        return None
    before = resets[-1] - INITIAL_RESET_CYCLES - (len(resets) - 1)
    return int(r.group(1)) - before


def identities(text):
    """The CACHE_STATS identities of one log -> list of violations ([] if it has no CACHE_STATS)."""
    st = stats_of(text)
    if st is None:
        return []
    bad = []
    if RESET.search(text):
        want = cycles_after_last_reset(text)
        if want is not None and st.get("cycles") != want:
            bad.append(f"cycles={st.get('cycles')}, the cycles after the last reset {want}")
        return bad
    lm = LINE_BYTES.search(text)
    lw = int(lm.group(1)) // 4 if lm else 4

    def need(name, got, want):
        if got != want:
            bad.append(f"{name}: {got} != {want}")
    try:
        need("i_refills = i_done + i_inflight", st["i_refills"], st["i_done"] + st["i_inflight"])
        need("i_refill_cycles = wait_i_for_port + port_irefill", st["i_refill_cycles"],
             st["wait_i_for_port"] + st["port_irefill"])
        need(f"i_beats = {lw} * i_done + i_inflight_beats", st["i_beats"], lw * st["i_done"] + st["i_inflight_beats"])
        sb = SCOREBOARD_PASS.search(text)
        if sb:
            need("i_hits = scoreboard fetches", st["i_hits"], int(sb.group(1)))
            need("d_loads = scoreboard loads", st["d_loads"], int(sb.group(2)))
            need("d_stores = scoreboard stores", st["d_stores"], int(sb.group(3)))
        r = RETIRED.search(text)
        if r:
            need("cycles = RETIRED cycles", st["cycles"], int(r.group(1)))
    except KeyError as e:
        bad.append(f"CACHE_STATS lacks {e}")
    return bad


def hard_problems(text):
    """Problems that fail a run whatever its verdict: errors, scoreboard, identities."""
    p = []
    for l in text.splitlines():
        if re.search(r"%(Fatal|Error)", l) or "SCOREBOARD: FAIL" in l:
            p.append(l.strip()[:200])
            break
    p += [f"CACHE_STATS identity: {x}" for x in identities(text)]
    return p


def read(path):
    try:
        with open(path, errors="replace") as f:
            return f.read()
    except OSError:
        return ""


# ------------------------------------------------------------------------------ jobs
class Job:
    def __init__(self, leg, name, cache, profile, cmd, judge, est, cpus="both", lock=None, logs=None,
                 needs_cache=True, extra_vars=(), cwd=None, note=""):
        self.leg, self.name, self.cache, self.profile = leg, name, cache, profile
        self.vars = config(cache, profile) + list(extra_vars)
        self.cmd, self.judge, self.est, self.cpus = cmd, judge, est, cpus
        self.lock, self.logs, self.needs_cache, self.cwd, self.note = lock, logs, needs_cache, cwd, note
        self.id = f"{leg}/{name}"


def make_cmd(goals, vars_):
    return ["make", "-s", "--no-print-directory", "-C", REPO] + goals + vars_


def build_dir(vars_):
    """The build directory of a configuration, as make sim-config prints it."""
    out = subprocess.run(make_cmd(["sim-config"], vars_), capture_output=True, text=True, env=clean_env())
    m = re.search(r"build directory:\s+(\S+)", out.stdout)
    return (os.path.join(REPO, m.group(1)) if m else None), out.stdout


def clean_env():
    return {k: v for k, v in os.environ.items() if not k.startswith("HADES_")}


def has_cache(vars_):
    _, text = build_dir(vars_)
    return "+define+HADES_ICACHE_BYTES=" in text


# ---- judges: (job, returncode, output text, job directory) -> (verdict, [notes])
def programs_judge(job, rc, out, d):
    notes = []
    m = re.search(r"JUDGED against [^:]*: dut: .* (\d+) differ otherwise", out)
    bad = re.search(r"PROGRAMS: (\d+) runs .*scoreboard PASS in (\d+), (\d+) run\(s\)", out)
    if not bad:
        return "FAIL", ["no PROGRAMS line"]
    runs, sbpass, nbad = (int(x) for x in bad.groups())
    if nbad:
        notes.append(f"{nbad} bad run(s)")
    if sbpass != runs:
        notes.append(f"scoreboard PASS in {sbpass} of {runs} runs")
    if m and int(m.group(1)):
        notes.append(f"dut: {m.group(1)} program(s) differ otherwise")
    golden = re.search(r"JUDGED against [^:]*: golden .*?(\d+) differ otherwise", out)
    if golden and int(golden.group(1)):
        notes.append(f"golden (recorded): {golden.group(1)} differ otherwise")
    for f in job_logs(d):
        for p in identities(read(f)):
            notes.append(f"{os.path.relpath(f, d)}: CACHE_STATS identity: {p}")
    fails = [n for n in notes if not n.startswith("golden (recorded)")]
    return ("PASS" if not fails and rc == 0 else "FAIL"), notes


def job_logs(d):
    out = []
    for root, _, files in os.walk(d):
        out += [os.path.join(root, f) for f in files if f.endswith(".log")]
    return sorted(out)


def programs_job(leg, cache, profile, only="", cpus="dut,golden", sim_args="", extra=(), est=None, name=None,
                 judge=None):
    def cmd(d):
        c = [sys.executable, os.path.join(HERE, "programs.py"), "run"] + config(cache, profile) + list(extra) + \
            ["--cpu", cpus, "--jobs", "4", "--out", d]
        if only:
            c += ["--only", only]
        if sim_args:
            c += ["--sim-args", sim_args]
        return c
    return Job(leg, name or cname(cache, profile), cache, profile, cmd, judge or programs_judge,
               est or 3e7, cpus=cpus, extra_vars=extra)


def freertos_judge(job, rc, out, d):
    notes = []
    m = re.search(r"^COMPARE\s+dut: (\S+).*golden: (\S+)", out, re.M)
    if "AGREE:" not in out:
        notes.append("no AGREE line" + (f" (dut {m.group(1)}, golden {m.group(2)})" if m else ""))
        if m and m.group(1) == "PASS" and m.group(2) != "PASS":
            notes.append("golden only: trace it to its mechanism")
    notes += logs_problems(d)
    return ("PASS" if not notes else "FAIL"), notes


def logs_problems(d):
    p = []
    for f in job_logs(d):
        for x in hard_problems(read(f)):
            p.append(f"{os.path.basename(f)}: {x}")
    return p


def freertos_job(leg, app, cache, profile, compare=True, extra=(), name=None):
    goal = "freertos-compare" if compare else "freertos"

    def cmd(d):
        return make_cmd([goal, f"APP={app}"], config(cache, profile) + list(extra))
    f = TICK_FACTOR.get(profile, 1)
    est = FRTOS_TICKS.get(app, 500) * 10000 * f * (2 if compare else 1)
    judge = freertos_judge if compare else single_frtos_judge
    return Job(leg, name or f"{app}-{cname(cache, profile)}", cache, profile, cmd, judge, est,
               cpus="both" if compare else "dut", lock=(cache, profile, app), logs=("freertos", app),
               extra_vars=extra)


def single_frtos_judge(job, rc, out, d):
    notes = []
    if not re.search(r"^FREERTOS RESULT: PASS", out, re.M):
        notes.append("no 'FREERTOS RESULT: PASS'")
    notes += logs_problems(d)
    tick = re.search(r"tick=(\d+)", out)
    if tick:
        notes.append(f"tick {tick.group(1)} (recorded)")
    return ("PASS" if not [n for n in notes if "recorded" not in n] else "FAIL"), notes


def shell_judge(job, rc, out, d):
    notes = []
    if "SHELL COMPARE: SAME" not in out:
        notes.append("no 'SHELL COMPARE: SAME'")
    met = re.findall(r"expectations met: (\d+)/(\d+)", out)
    want = [("120", "120"), ("121", "121")]
    if met[:2] != want:
        notes.append(f"expectations met {met}, expected dut 120/120 and golden 121/121")
    notes += logs_problems(d)
    return ("PASS" if not notes else "FAIL"), notes


def loader_judge(job, rc, out, d):
    notes = [] if re.search(r"^LOADER COMPARE: PASS", out, re.M) else ["no 'LOADER COMPARE: PASS'"]
    notes += logs_problems(d)
    return ("PASS" if not notes else "FAIL"), notes


def sweep_judge(job, rc, out, d):
    notes = []
    m = re.search(r"^DUT: (\d+)/(\d+) programs ISS-consistent", out, re.M)
    if not m or m.group(1) != m.group(2):
        notes.append(f"DUT: {m.group(0) if m else 'no DUT line'}")
    g = re.search(r"^golden: .*$", out, re.M)
    if g:
        notes.append(f"golden (recorded): {g.group(0)}")
    for f in job_logs(d):
        for x in hard_problems(read(f)):
            notes.append(f"{os.path.relpath(f, d)}: {x}")
    fails = [n for n in notes if "recorded" not in n]
    return ("PASS" if not fails else "FAIL"), notes


def sweep_job(leg, cache, profile, fam=None, cpus="dut,ref"):
    def cmd(d):
        c = [sys.executable, os.path.join(REPO, "test", "trapsweep", "sweep.py"), "run", "--jobs", "4",
             "--targets", cpus, "--out", d]
        return c + (["--fam", fam] if fam else [])
    job = Job(leg, cname(cache, profile), cache, profile, cmd, sweep_judge, 2e7 if fam is None else 2e6,
              needs_cache=cache != "standard")
    job.env_from_config = True          # sweep.py takes the configuration from the environment
    return job


def stress_campaign_judge(job, rc, out, d):
    notes = []
    if re.search(r"CAMPAIGN RESULT: (PASS|FAIL)", out) is None:
        notes.append("no CAMPAIGN RESULT line")
    tbl = re.findall(r"^\|[^|]+\|\s*\d+\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|", out, re.M)
    if any(int(h) or int(c) for h, c in tbl):
        notes.append(f"HANG/CRASH in the table: {tbl}")
    bdir, _ = build_dir(job.vars)
    logs = job_logs(os.path.join(bdir, "freertos-campaign", "validate"))
    runs = [f for f in logs if "SCOREBOARD" in read(f) or "FREERTOS RESULT" in read(f)]
    for f in logs:
        text = read(f)
        for x in hard_problems(text):
            notes.append(f"{os.path.basename(f)}: {x}")
        if "FREERTOS RESULT" in text and "SCOREBOARD: PASS" not in text:
            notes.append(f"{os.path.basename(f)}: no SCOREBOARD: PASS")
    notes.append(f"{len(runs)} run log(s) checked (recorded)")
    pv = re.search(r"CAMPAIGN RESULT: .*$", out, re.M)
    if pv:
        notes.append(f"progress verdict (recorded): {pv.group(0)}")
    return ("PASS" if not [n for n in notes if "recorded" not in n] else "FAIL"), notes


def bench_judge(job, rc, out, d):
    """The timing benches with a cache: zba and zbb by their own verdict (equality checks only),
    mcost and fencei-window by the rules below; bench.py's verdict of those two is recorded only."""
    bdir, _ = build_dir(job.vars)
    notes = []
    for b in ("ZBA", "ZBB"):
        if f"BENCH {b}: PASS" not in out:
            notes.append(f"no 'BENCH {b}: PASS'")
    notes += mcost_problems(os.path.join(bdir, "test", "bench", "mcost"))
    notes += fencei_window_problems(os.path.join(bdir, "test", "bench", "fencei-window"))
    for v in re.findall(r"^BENCH (MCOST|FENCEI-WINDOW): (\S+)", out, re.M):
        notes.append(f"bench.py {v[0]}: {v[1]} (recorded)")
    return ("PASS" if not [n for n in notes if "recorded" not in n] else "FAIL"), notes


def mcost_problems(top):
    """bench-mcost with a cache: every run log has its markers (two in each 800-op loop) and its
    table lines (one per instruction of mcost.c), ends without a simulator error, and has
    SCOREBOARD: PASS. The cost figures are recorded, not judged."""
    sys.path.insert(0, os.path.join(REPO, "test", "bench"))
    import bench                                   # LOOPS, MCOST, run_problems, read_log
    sys.path.pop(0)
    p = []
    for name, _ in bench.LOOPS:
        log = bench.read_log(os.path.join(top, name))
        p += [f"mcost {name}: {x}" for x in bench.run_problems(log)]
        if len(re.findall(r"Test pass!", log)) != 2:
            p.append(f"mcost {name}: not two markers")
        if "SCOREBOARD: PASS" not in log:
            p.append(f"mcost {name}: no SCOREBOARD: PASS")
        p += [f"mcost {name}: {x}" for x in hard_problems(log)]
    log = bench.read_log(os.path.join(top, "mcost"))
    p += [f"mcost.c: {x}" for x in bench.run_problems(log) + hard_problems(log)]
    have = {m.group(1) for m in re.finditer(r"^(\S+)\s+[0-9a-f]{8}$", log, re.M)}
    p += [f"mcost.c: no {n} line" for n in bench.MCOST if n not in have]
    if "SCOREBOARD: PASS" not in log:
        p.append("mcost.c: no SCOREBOARD: PASS")
    return p


FENCEI_NEW = ("sw+16 (3 nops in gap)", "sw+20 (4 nops in gap)", "sw+8  (fence.i in gap)")
FENCEI_EITHER = ("sw+4  (0 nops in gap)", "sw+8  (1 nop  in gap)", "sw+12 (2 nops in gap)", "sw+12 (2 stalling lw )")
FENCEI_EXCUSED = ("s0", "s1", "s2", "s7")    # the locked OLD values of sw+4/8/12 and the stall control


def fencei_excused_reports():
    """The reports of fencei_stale.s's own checks of s0, s1, s2 and s7 (the locked values), counted in
    its checks section after the deliberate initial fail (report 1)."""
    src = read(os.path.join(REPO, "test", "bench", "fencei-window", "fencei_stale.s")).splitlines()
    start = next(i for i, l in enumerate(src) if l.startswith("checks:"))
    n, excused = 1, set()
    for l in src[start:]:
        if re.match(r"\s*(assert_value|assert_equal)\b", l):
            n += 1
            m = re.match(r"\s*assert_value\s+(s\d+),\s*RESULT_", l)
            if m and m.group(1) in FENCEI_EXCUSED:
                excused.add(n)
        if l.startswith("done:"):
            break
    return excused


def fencei_window_problems(top):
    """bench-fencei-window with a cache: sw+16, sw+20 and the fence.i row read NEW; sw+4, sw+8,
    sw+12 and the 2-stalling-lw row OLD or NEW; of fencei_stale.s's own checks those of s0, s1, s2
    and s7 are excused and every other one passes; stall_probe.s is recorded, not judged."""
    p = []
    log = read(os.path.join(top, "fencei_stale", "run.log"))
    log = re.sub(r"\x1b\[[0-9;]*m", "", log)
    if not log:
        return ["fencei_stale: no run log"]
    p += [f"fencei_stale: {x}" for x in hard_problems(log)]
    rows = {m.group(1): m.group(2) for m in re.finditer(r"^\s+(sw\+\d+\s+\(.*?\))\s*:\s*(.*?)\s*$", log, re.M)}
    for k in FENCEI_NEW:
        if not rows.get(k, "").startswith("NEW"):
            p.append(f"fencei_stale {k}: {rows.get(k, '(missing)')}, expected NEW")
    for k in FENCEI_EITHER:
        if not rows.get(k, "").startswith(("NEW", "OLD")):
            p.append(f"fencei_stale {k}: {rows.get(k, '(missing)')}, expected OLD or NEW")
    reps = "".join("P" if m.group(1) == "pass" else "F" for m in re.finditer(r"Test (pass|fail)!", log))
    excused = fencei_excused_reports()
    for i, r in enumerate(reps, start=1):
        want = "F" if i == 1 else "P"
        if r != want and i not in excused:
            p.append(f"fencei_stale: report {i} is {'fail' if r == 'F' else 'pass'}")
    if "SCOREBOARD: PASS" not in log:
        p.append("fencei_stale: no SCOREBOARD: PASS")
    return p


def lint_judge(job, rc, out, d):
    """HaDes-V+'s list of signals on combinational loops must equal the standard build's; the golden
    CPU's further signals are listed (each to be explained: the golden library's outputs count as
    depending on all its inputs, and the cache answers and the arbiter grants in the same cycle)."""
    notes = []
    m = re.search(r"^LINT dut: (SAME|DIFFERENT) (.*)$", out, re.M)
    if not m or m.group(1) != "SAME":
        notes.append(f"HaDes-V+'s loop list: {m.group(0) if m else 'no comparison'}")
    g = re.search(r"^LINT golden: (.*)$", out, re.M)
    if g:
        notes.append(f"golden (recorded; explain every further signal): {g.group(1)}")
    return ("PASS" if rc == 0 and not [n for n in notes if "recorded" not in n] else "FAIL"), notes


def exit_judge(job, rc, out, d):
    notes = logs_problems(d)
    if rc:
        notes.append(f"exit status {rc}")
    tail = [l for l in out.strip().splitlines() if l.strip()][-1:] or ["(no output)"]
    notes.append(f"last line (recorded): {tail[0][:160]}")
    return ("PASS" if rc == 0 and not [n for n in notes if "recorded" not in n] else "FAIL"), notes


# ---- the coverage of the directed tests (headers of the programs)
def header_minimum(prog, pattern):
    """A number from a test's header box, read as running text (the box's line breaks removed)."""
    text = re.sub(r"\s*\|[ \t]*\n#[ \t]*\|\s*", " ", read(os.path.join(REPO, "test", "memsys", prog + ".s")))
    m = re.search(pattern, text, re.S)
    return int(m.group(1)) if m else None


def coverage_judge(job, rc, out, d):
    """Directed tests with a cache: the reports as on the standard build (programs.py), and the
    coverage stated in each test's header: i_done and i_abandoned of irqchain and fetchredirect,
    snoop_inval of icoherence, the interrupt positions of irqchain (+ram_words), and every test
    below 80% of its cycle limit."""
    verdict, notes = programs_judge(job, rc, out, d)
    large = job.cache == "i8k"
    try:
        limit = json.load(open(os.path.join(d, "results.json")))["timeout"]
    except (OSError, ValueError, KeyError):
        limit = None
    mins = {
        "irqchain": dict(i_done=header_minimum("irqchain", r"i_done is at least.*?=\s*(\d+)"),
                         i_abandoned=header_minimum("irqchain", r"i_abandoned at least (\d+)")),
        "fetchredirect": dict(i_done=header_minimum("fetchredirect", r"i_done is at least\s+(\d+)"),
                              i_abandoned=header_minimum("fetchredirect", r"i_abandoned is at least\s+(\d+)")),
        "icoherence": dict(snoop_inval=header_minimum(
            "icoherence", r"at least (\d+) with an 8 KiB" if large else r"snoop_inval is at least\s+(\d+)")),
    }
    for prog, want in mins.items():
        log = read(os.path.join(d, "dut", f"memsys-{prog}", "sim.log"))
        st = stats_of(log)
        if not st:
            notes.append(f"{prog}: no CACHE_STATS line")
            continue
        for k, v in want.items():
            if v is None:
                notes.append(f"{prog}: no minimum of {k} in its header")
            elif st.get(k, -1) < v:
                notes.append(f"{prog}: {k}={st.get(k)} below the header's {v}")
            else:
                notes.append(f"{prog}: {k}={st.get(k)} (at least {v}; recorded)")
        # the cycle limit of the run: programs.py passes it as +timeout (results.json), so the
        # simulator prints no limit line of its own
        lim = limit
        if lim is None:
            m = re.search(r"cycle limit (\d+)", log)
            lim = int(m.group(1)) if m else None
        r = RETIRED.search(log)
        if lim is None:
            notes.append(f"{prog}: no cycle limit found")
        elif r and int(r.group(1)) >= 0.8 * lim:
            notes.append(f"{prog}: {r.group(1)} cycles, 80% or more of the limit {lim}")
        elif r:
            notes.append(f"{prog}: {r.group(1)} cycles, {100 * int(r.group(1)) / lim:.1f}% of the limit {lim} (recorded)")
    words = re.search(r"^RAM_WORDS (.*)$", read(os.path.join(d, "dut", "memsys-irqchain", "sim.log")), re.M)
    if words:
        vals = [int(v, 16) for v in re.findall(r"=(?:0x)?([0-9a-fA-F]+)", words.group(1))]
        union = 0
        for v in vals:
            union |= v
        chain = all(union >> b & 1 for b in range(3, 19))
        wait = any(union >> b & 1 for b in range(19, 22))
        missing = [b for b in range(3, 22) if not union >> b & 1]
        notes.append(f"irqchain positions: masks {[hex(v) for v in vals]}; every chain position "
                     f"{'covered' if chain else 'NOT covered'}, the wait loop {'reached' if wait else 'NOT reached'}"
                     + (f"; missing bits {missing} (list them with the reason, or fail)" if missing else "")
                     + " (recorded)")
    else:
        notes.append("irqchain: no RAM_WORDS line")
    fails = [n for n in notes if "recorded" not in n]
    return ("PASS" if verdict == "PASS" and not fails else "FAIL"), notes


# ---- mid-run resets (the reset leg): placed from a +cache_phase_log run
RESET_DELAY = 3          # cycles from buttons_async[0] to rst (two synchronizer stages, the rst flip-flop)
PHASES = {
    "refill beat":      lambda b: b & 1,
    "refill waiting":   lambda b: b & 2,
    "RAM store wait":   lambda b: (b & 0x1C) == 0x1C,
    "RAM load wait":    lambda b: (b & 0x1C) == 0x0C,
    "I/O wait":         lambda b: (b & 0x0C) == 0x04,
}
# The phase of a RESET line. With a cache a RAM access that waits for its answer is either still
# waiting for the memory port ("RAM load waiting") or granted it ("granted (RAM load)"); both count.
RESET_TEXT = {"refill beat": r"I-cache refill beat", "refill waiting": r"refill waiting for the port",
              "RAM store wait": r"data side (RAM store waiting|granted \(RAM store\))",
              "RAM load wait": r"data side (RAM load waiting|granted \(RAM load\))",
              "I/O wait": r"data side I/O access waiting"}


def place_resets(phase_log, cached):
    """Cycles to reset in, from a phase log (one byte per cycle): three refill beats and three waiting
    refills (cached only), and for each kind of data wait its first, a middle and its last cycle."""
    data = open(phase_log, "rb").read()
    picks = []

    def runs(test):
        out, start = [], None
        for i, b in enumerate(data):
            if test(b) and not b & 0x40:
                start = i if start is None else start
            elif start is not None:
                out.append((start, i - 1))
                start = None
        return out
    for name, test in PHASES.items():
        if not cached and name.startswith("refill"):
            continue
        rs = runs(test)
        if name.startswith("refill"):
            for s, e in rs[len(rs) // 4::max(1, len(rs) // 3)][:3]:
                picks.append((name, s + (e - s) // 2))
        else:
            long = [r for r in rs if r[1] - r[0] >= 2] or rs
            if long:
                s, e = long[len(long) // 2]
                picks += [(name + " (first)", s), (name + " (middle)", (s + e) // 2), (name + " (last)", e)]
    return [(n, c) for n, c in picks if c > RESET_DELAY + 2]


def reset_runs(job, d, sim, prog_dir, prog, cached, timeout):
    """One phase-log run and one run per placed reset -> (notes, results)."""
    os.makedirs(d, exist_ok=True)
    shutil.copy(os.path.join(prog_dir, "init.mem"), d)
    base = subprocess.run([sim, "+nodump", f"+timeout={timeout}", "+cache_phase_log=phase.bin"], cwd=d,
                          capture_output=True, text=True, errors="replace")
    notes, results = [], []
    if not os.path.exists(os.path.join(d, "phase.bin")):
        return [f"{prog}: no phase log ({base.stdout[-200:]})"], results
    for name, cyc in place_resets(os.path.join(d, "phase.bin"), cached):
        rd = os.path.join(d, f"reset-{cyc}")
        os.makedirs(rd, exist_ok=True)
        shutil.copy(os.path.join(prog_dir, "init.mem"), rd)
        r = subprocess.run([sim, "+nodump", f"+timeout={timeout}", f"+reset_at={cyc - RESET_DELAY}"], cwd=rd,
                           capture_output=True, text=True, errors="replace")
        with open(os.path.join(rd, "sim.log"), "w") as f:
            f.write(r.stdout)
        got = RESET.search(r.stdout)
        phase = got.group(3) if got else "(no RESET line)"
        ok = got is not None and int(got.group(1)) - int(got.group(2)) == RESET_DELAY
        results.append(dict(program=prog, wanted=name, cycle=cyc, reset_line=phase, placed=ok,
                            problems=hard_problems(r.stdout) + ([] if "SCOREBOARD: PASS" in r.stdout
                                                                 else ["no SCOREBOARD: PASS"])))
    return notes, results


def resets_judge_factory(cached, minimum=3):
    def judge(job, rc, out, d):
        notes = []
        try:
            res = json.load(open(os.path.join(d, "resets.json")))
        except OSError:
            return "FAIL", ["no resets.json"]
        for r in res:
            for p in r["problems"]:
                notes.append(f"{r['program']} reset at {r['cycle']} ({r['wanted']}): {p}")
        count = {k: 0 for k in RESET_TEXT}
        for r in res:
            for k, pat in RESET_TEXT.items():
                if re.search(pat, r["reset_line"]):
                    count[k] += 1
        need = {k: minimum for k in RESET_TEXT if cached or not k.startswith("refill")}
        for k, n in need.items():
            if count[k] < n:
                notes.append(f"only {count[k]} reset(s) in phase '{k}' by the RESET lines (need {n})")
        notes.append(f"resets by phase (recorded): {count}")
        return ("PASS" if not [n for n in notes if "recorded" not in n] else "FAIL"), notes
    return judge


def resets_job(leg, cache, profile, progs=("memsys/stores", "memsys/fetchredirect", "memsys/icoherence",
                                           "memsys/irqchain", "asm/ops")):
    cached = cache != "standard"

    def cmd(d):
        return [sys.executable, os.path.abspath(__file__), "_resets", "--dir", d, "--cached", str(int(cached)),
                "--programs", ",".join(progs), "--"] + config(cache, profile)
    return Job(leg, cname(cache, profile), cache, profile, cmd, resets_judge_factory(cached), 5e7, cpus="dut",
               needs_cache=cached)


# ---- model agreement (6.7 of the cache documentation's verification plan)
MODEL_PROGRAMS = ("memsys/fetchredirect", "memsys/icoherence", "asm/zkt", "memsys/stores")


def model_job(leg, cache, profile, burst=False):
    def cmd(d):
        return [sys.executable, os.path.abspath(__file__), "_model", "--dir", d, "--programs",
                ",".join(MODEL_PROGRAMS), "--"] + config(cache, profile)
    def judge(job, rc, out, d):
        notes = []
        for prog in MODEL_PROGRAMS:
            m = re.search(rf"^MODEL {re.escape(prog)}: RTLCHECK: (\S+)", out, re.M)
            if not m or m.group(1) != "AGREE":
                notes.append(f"{prog}: {m.group(1) if m else 'no rtlcheck verdict'}")
        notes += logs_problems(d)
        return ("PASS" if not notes else "FAIL"), notes
    return Job(leg, cname(cache, profile), cache, profile, cmd, judge, 2e7, cpus="dut")


# ------------------------------------------------------------------------------ the legs
def legs():
    L = {}
    SMALL, LARGE = "i512", "i8k"
    L["smoke"] = [programs_job("smoke", SMALL, p, only="memsys/(stores|fetchredirect|icoherence|irqchain)$|asm/(ops|fencei)$",
                               cpus="dut") for p in ("burst", "stress")] + \
                 [freertos_job("smoke", "minimal", SMALL, p, compare=False) for p in ("burst", "stress")]
    L["programs"] = [programs_job("programs", SMALL, p) for p in ("lat0", "lat2", "rand1", "rand2", "rand3", "burst", "stress")] + \
                    [programs_job("programs", LARGE, p) for p in ("lat2", "rand1")]
    L["module-benches"] = [Job("module-benches", cname(SMALL, "lat2"), SMALL, "lat2",
                               lambda d: [sys.executable, os.path.abspath(__file__), "_benches", "--dir", d, "--"] +
                               config(SMALL, "lat2"), exit_judge, 1e7, cpus="dut")]
    L["timing-benches"] = [Job("timing-benches", cname(SMALL, p), SMALL, p,
                               (lambda p: lambda d: [sys.executable, os.path.abspath(__file__), "_timing_benches",
                                                     "--dir", d, "--"] + config(SMALL, p) + ["BENCH_TIMEOUT=50000000"])(p),
                               bench_judge, 5e7, cpus="dut", extra_vars=["BENCH_TIMEOUT=50000000"])
                           for p in ("lat0", "lat2")]
    L["freertos-compare"] = [freertos_job("freertos-compare", a, SMALL, p) for a in ("minimal", "stress", "mzba")
                             for p in ("lat0", "lat2", "rand1", "burst")] + \
                            [freertos_job("freertos-compare", a, SMALL, p) for a in ("minimal", "stress")
                             for p in ("rand2", "rand3")]
    L["freertos-mzba-zba"] = [freertos_job("freertos-mzba-zba", "mzba", SMALL, p, compare=False, extra=["MARCH=rv32im_zba"],
                                           name=f"mzba-zba-{cname(SMALL, p)}") for p in ("lat2", "rand1")] + \
                             [freertos_job("freertos-mzba-zba", "mzba", SMALL, "lat2", compare=False,
                                           extra=["MARCH=rv32im_zba", "DEFS=-DMZBA_IRQ_MEAN=2500"],
                                           name=f"mzba-zba-interval2500-{cname(SMALL, 'lat2')}")]
    L["freertos-full"] = [freertos_job("freertos-full", "full", SMALL, p) for p in ("lat2", "rand1")]
    L["shell"] = [Job("shell", cname(SMALL, p), SMALL, p,
                      (lambda p: lambda d: make_cmd(["freertos-shell-compare"], config(SMALL, p)))(p), shell_judge,
                      2e7, lock=(SMALL, p, "shell"), logs=("freertos", "shell")) for p in ("lat0", "lat2", "rand1", "burst")]
    L["loader"] = [Job("loader", cname(SMALL, "lat2"), SMALL, "lat2", lambda d: make_cmd(["freertos-loader-compare"],
                                                                                config(SMALL, "lat2")),
                       loader_judge, 3e8, lock=(SMALL, "lat2", "loader"), logs=("freertos", "loader"))]
    L["brk"] = [freertos_job("brk", "brk", SMALL, p) for p in ("lat2", "rand1")]
    L["trapsweep"] = [sweep_job("trapsweep", SMALL, p) for p in ("lat2", "rand1")] + [sweep_job("trapsweep", LARGE, "lat2")]
    L["window-sweep"] = [sweep_job("window-sweep", "standard", "std", fam="window")] + \
                        [sweep_job("window-sweep", SMALL, p, fam="window") for p in ("lat0", "lat2", "rand1")] + \
                        [sweep_job("window-sweep", LARGE, "lat2", fam="window")]
    L["stress-campaign"] = [Job("stress-campaign", cname(SMALL, p), SMALL, p,
                                (lambda p: lambda d: make_cmd(["freertos-stress", "SET=validate"], config(SMALL, p)))(p),
                                stress_campaign_judge, 2e8, lock=(SMALL, p, "campaign")) for p in ("lat2", "rand1")]
    L["directed-coverage"] = [programs_job("directed-coverage", c, "lat2",
                                           only="memsys/(irqchain|fetchredirect|icoherence|stores)$", cpus="dut",
                                           sim_args="+ram_words=0x46000,0x46004", judge=coverage_judge)
                              for c in (SMALL, LARGE)]
    L["freertos-compare-large"] = [freertos_job("freertos-compare-large", a, LARGE, "lat2") for a in ("minimal", "stress")]
    L["cached-vs-golden"] = [Job("cached-vs-golden", f"{a}-{cname(SMALL, 'lat2')}", SMALL, "lat2",
                                 (lambda a: lambda d: [sys.executable, os.path.abspath(__file__), "_cached_vs_golden",
                                                       "--dir", d, "--app", a, "--"] + config(SMALL, "lat2"))(a),
                                 exit_judge, FRTOS_TICKS.get(a, 500) * 40000 * 2, lock=(SMALL, "lat2", a))
                             for a in ("minimal", "stress", "mzba", "full", "shell")]
    L["lint-loops"] = [Job("lint-loops", c, c, "lat0",
                           (lambda c: lambda d: [sys.executable, os.path.abspath(__file__), "_lint", "--dir", d, "--"] +
                            config(c, "lat0"))(c), lint_judge, 1e6) for c in (SMALL, LARGE)]
    L["minimal-stress-profile"] = [freertos_job("minimal-stress-profile", "minimal", SMALL, "stress", compare=False)]
    L["line-sizes"] = [programs_job("line-sizes", c, "lat2", cpus="dut",
                                    only="memsys/(fetchredirect|icoherence|irqchain|stores)$|asm/(fencei|ops)$")
                       for c in ("i512-line8", "i512-line32", "i512-line64")] + \
                      [freertos_job("line-sizes", "minimal", c, "lat2", compare=False)
                       for c in ("i512-line8", "i512-line32", "i512-line64")]
    L["resets"] = [resets_job("resets", SMALL, "lat2"), resets_job("resets", SMALL, "rand1"),
                   resets_job("resets", "standard", "lat2")]
    mini = resets_job("resets", SMALL, "lat2", progs=())
    mini.name, mini.lock = f"freertos-minimal-{cname(SMALL, 'lat2')}", (SMALL, "lat2", "minimal")
    mini.cmd = lambda d: [sys.executable, os.path.abspath(__file__), "_resets", "--dir", d, "--cached", "1",
                          "--app", "minimal", "--"] + config(SMALL, "lat2")
    mini.judge = resets_judge_factory(True, minimum=1)
    L["resets"].append(mini)
    L["model-agreement"] = [model_job("model-agreement", SMALL, "lat2"), model_job("model-agreement", LARGE, "lat2")] + \
                           [Job("model-agreement", "i512-lat2-burst0", SMALL, "lat2",
                                lambda d: [sys.executable, os.path.abspath(__file__), "_model", "--dir", d, "--programs",
                                           ",".join(MODEL_PROGRAMS), "--"] + config(SMALL, "lat2") + ["MEM_BEAT_LAT=0"],
                                model_job("x", SMALL, "lat2").judge, 2e7, cpus="dut", extra_vars=["MEM_BEAT_LAT=0"])]
    cpi = []
    for app, extra in (("minimal", []), ("stress", []), ("mzba", []), ("mzba", ["MARCH=rv32im_zba"]), ("full", [])):
        for b in (0, 3):
            for col, cache, prof in (("cached", LARGE, "dram"), ("baseline", "standard", "dram-nobursts")):
                nm = f"{app}{'-zba' if extra else ''}-bpred{b}-{col}"
                cpi.append(Job("cpi", nm, cache, prof,
                               (lambda app, b, cache, prof, extra: lambda d: [
                                   sys.executable, os.path.abspath(__file__), "_cpi", "--dir", d, "--app", app,
                                   "--bpred", str(b), "--"] + config(cache, prof) + extra)(app, b, cache, prof, extra),
                               exit_judge, 6e7, cpus="dut", lock=(cache, prof, app), needs_cache=cache != "standard",
                               extra_vars=extra))
    L["cpi"] = cpi
    L["irq-latency"] = [programs_job("irq-latency", c, p, only="asm/uartirq$|memsys/irqchain$", cpus="dut",
                                     sim_args="+irq_latency", judge=lambda j, rc, out, d: exit_judge(j, rc, out, d))
                        for c, p in ((SMALL, "stress"), (LARGE, "dram"))]
    for name, jobs in L.items():
        for j in jobs:
            j.leg = name
            j.id = f"{name}/{j.name}"
    return L


# ------------------------------------------------------------------------------ helpers run as jobs
def run_programs(vars_, progs, sim_args=(), cpu="dut"):
    """Build a configuration's simulator and programs; -> (simulator, {program: directory})."""
    env = clean_env()
    bdir, text = build_dir(vars_)
    model = {"dut": "dut", "golden": "ref"}[cpu]
    subprocess.run(make_cmd(["frtos-model", f"FRTOS_CPU={model}", "FRTOS_RAM_KB=32"], vars_), check=True, env=env,
                   stdout=subprocess.DEVNULL)
    subprocess.run(make_cmd([os.path.relpath(os.path.join(bdir, "test", p, "init.mem"), REPO) for p in progs], vars_),
                   check=True, env=env, stdout=subprocess.DEVNULL)
    return os.path.join(bdir, "frtos-model", f"{model}-32k", "top"), {p: os.path.join(bdir, "test", p) for p in progs}


def frtos_direct(app, vars_, plusargs, d):
    """Build a FreeRTOS program and run its simulator directly with further run options (the make
    targets run it through run.sh, which takes none): the command of 'make -n frtos-run', run in the
    program's directory with the options appended; the output also goes to <d>/sim.log."""
    env = clean_env()
    subprocess.run(make_cmd(["frtos-elf", "frtos-model", f"APP={app}"], vars_), check=True, env=env,
                   stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    dry = subprocess.run(make_cmd(["-n", "frtos-run", f"APP={app}"], vars_), capture_output=True, text=True,
                         env=env).stdout.strip().splitlines()[-1]
    m = re.match(r"cd (\S+) && (\S+) (.*)$", dry)
    if not m:
        raise SystemExit(f"matrix.py: cannot read the run command of {app}: {dry}")
    rundir = os.path.join(REPO, m.group(1))
    r = subprocess.run([m.group(2)] + m.group(3).split() + list(plusargs), cwd=rundir, capture_output=True,
                       text=True, errors="replace")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "sim.log"), "w") as f:
        f.write(r.stdout)
    return r, rundir, m.group(2), m.group(3).split()


def helper_resets(a, vars_):
    cached = a.cached == "1"
    allres = []
    if a.app:
        # a FreeRTOS program: the phase log of one run, then one run per placed reset
        d = os.path.join(a.dir, a.app)
        frtos_direct(a.app, vars_, ["+cache_phase_log=" + os.path.join(d, "phase.bin")], d)
        _, rundir, sim, args = frtos_direct(a.app, vars_, [], os.path.join(d, "base"))
        for name, cyc in place_resets(os.path.join(d, "phase.bin"), cached):
            rd = os.path.join(d, f"reset-{cyc}")
            r = subprocess.run([sim] + args + [f"+reset_at={cyc - RESET_DELAY}"], cwd=rundir, capture_output=True,
                               text=True, errors="replace")
            os.makedirs(rd, exist_ok=True)
            with open(os.path.join(rd, "sim.log"), "w") as f:
                f.write(r.stdout)
            got = RESET.search(r.stdout)
            allres.append(dict(program=a.app, wanted=name, cycle=cyc,
                               reset_line=got.group(3) if got else "(no RESET line)",
                               placed=bool(got) and int(got.group(1)) - int(got.group(2)) == RESET_DELAY,
                               problems=hard_problems(r.stdout) + ([] if "SCOREBOARD: PASS" in r.stdout
                                                                    else ["no SCOREBOARD: PASS"])))
    progs = [p for p in a.programs.split(",") if p]
    sim, dirs = run_programs(vars_, progs) if progs else (None, {})
    for prog, pd in dirs.items():
        _, res = reset_runs(None, os.path.join(a.dir, prog.replace("/", "-")), sim, pd, prog, cached, 10_000_000)
        allres += res
    with open(os.path.join(a.dir, "resets.json"), "w") as f:
        json.dump(allres, f, indent=1)
    for r in allres:
        print(f"RESET RUN {r['program']} at {r['cycle']} ({r['wanted']}): {r['reset_line']}"
              f"{'' if r['placed'] else ' (not where it was placed)'}; {'; '.join(r['problems']) or 'ok'}")
    return 0


def helper_model(a, vars_):
    """Model agreement: the trace of each program at the standard memory (BUSTRACE=1), its cached
    run, and cachemodel.py rtlcheck."""
    progs = a.programs.split(",")
    tsim, tdirs = run_programs(["BUSTRACE=1"], progs)
    csim, cdirs = run_programs(vars_, progs)
    rc = 0
    for p in progs:
        d = os.path.join(a.dir, p.replace("/", "-"))
        for sub in ("trace", "cached"):
            os.makedirs(os.path.join(d, sub), exist_ok=True)
        shutil.copy(os.path.join(tdirs[p], "init.mem"), os.path.join(d, "trace"))
        shutil.copy(os.path.join(cdirs[p], "init.mem"), os.path.join(d, "cached"))
        subprocess.run([tsim, "+nodump"], cwd=os.path.join(d, "trace"), capture_output=True)
        r = subprocess.run([csim, "+nodump"], cwd=os.path.join(d, "cached"), capture_output=True, text=True,
                           errors="replace")
        with open(os.path.join(d, "cached", "sim.log"), "w") as f:
            f.write(r.stdout)
        model = os.path.join(HERE, "cachemodel.py")
        subprocess.run([sys.executable, model, "prep", os.path.join(d, "trace", "bustrace.bin"),
                        os.path.join(d, "prepared"), "--ram-kb", "32", "--name", p], check=True,
                       stdout=subprocess.DEVNULL)
        c = subprocess.run([sys.executable, model, "rtlcheck", os.path.join(d, "prepared"),
                            os.path.join(d, "cached", "sim.log")], capture_output=True, text=True)
        print(c.stdout)
        v = re.search(r"^RTLCHECK: (\S+)", c.stdout, re.M)
        print(f"MODEL {p}: RTLCHECK: {v.group(1) if v else 'NONE'}")
        rc |= c.returncode
    return rc


def helper_benches(a, vars_):
    names = sorted(f[:-3] for f in os.listdir(os.path.join(REPO, "test", "sv")) if f.endswith(".sv"))
    rc = 0
    for n in names:
        r = subprocess.run(make_cmd([f"test/sv/{n}"], vars_), capture_output=True, text=True, env=clean_env(),
                           errors="replace")
        last = [l for l in r.stdout.splitlines() if l.strip()][-1:] or ["(no output)"]
        print(f"MODULE BENCH {n}: exit {r.returncode}: {last[0][:160]}")
        rc |= r.returncode
    return rc


def helper_timing_benches(a, vars_):
    out = []
    for goal in ("bench-zba", "bench-zbb", "bench-mcost", "bench-fencei-window"):
        r = subprocess.run(make_cmd([goal], vars_), capture_output=True, text=True, env=clean_env(), errors="replace")
        print(r.stdout)
        print(f"(make {goal}: exit {r.returncode})")
    return 0


def helper_cached_vs_golden(a, vars_):
    """Our CPU cached against the golden CPU uncached: the same image (the explicit tick and scale
    that the automatic setting gives in the cached configuration), run on HaDes-V+ cached and on
    the golden CPU in the standard build, compared by run.sh --compare (session.py for the shell)."""
    bdir, text = build_dir(vars_)
    f = TICK_FACTOR["lat2"]
    tick = [f"TICK={10000 * f}", f"DEFS=-DFRTOS_SLOW_SCALE={f}"]
    app = a.app
    if app == "shell":
        r1 = subprocess.run(make_cmd(["freertos-shell-test", "APP=shell", "FRTOS_CPU=dut"], vars_ + tick),
                            capture_output=True, text=True, env=clean_env())
        r2 = subprocess.run(make_cmd(["freertos-shell-test", "APP=shell", "FRTOS_CPU=ref"], tick),
                            capture_output=True, text=True, env=clean_env())
        print(r1.stdout[-2000:], r2.stdout[-2000:])
        sbdir, _ = build_dir([])
        c = subprocess.run([sys.executable, os.path.join(REPO, "test", "freertos", "shell", "session.py"), "compare",
                            "--script", os.path.join(REPO, "test", "freertos", "shell", "session.txt"),
                            os.path.join(bdir, "test", "freertos", "shell", "session-dut.log"),
                            os.path.join(sbdir, "test", "freertos", "shell", "session-golden.log")],
                           capture_output=True, text=True)
        print(c.stdout)
        return 0 if "SHELL COMPARE: SAME" in c.stdout else 1
    r1 = subprocess.run(make_cmd(["freertos", f"APP={app}", "FRTOS_CPU=dut"], vars_ + tick), capture_output=True,
                        text=True, env=clean_env())
    r2 = subprocess.run(make_cmd(["freertos", f"APP={app}", "FRTOS_CPU=ref"], tick), capture_output=True, text=True,
                        env=clean_env())
    print(r1.stdout[-1500:], r2.stdout[-1500:])
    sbdir, _ = build_dir([])
    c = subprocess.run(["sh", os.path.join(REPO, "test", "freertos", "run.sh"), "--compare",
                        os.path.join(bdir, "test", "freertos", app, "run-dut.log"),
                        os.path.join(sbdir, "test", "freertos", app, "run-golden.log")], capture_output=True, text=True)
    print(c.stdout)
    return c.returncode


def helper_cpi(a, vars_):
    """One row of the CPI measurement: TICK=10000 (as the model's traces), the branch-predictor
    mode, +retired_every=100000; full runs a fixed window of 10 M cycles. The RETIRED_AT, RETIRED and
    CACHE_STATS lines are the row's figures (compared over equal retired instructions)."""
    goal_vars = vars_ + ["TICK=10000", f"BPRED={a.bpred}"] + (["TIMEOUT=10000000"] if a.app == "full" else [])
    r, _, _, _ = frtos_direct(a.app, goal_vars, ["+retired_every=100000"], a.dir)
    for l in r.stdout.splitlines():
        # (a RETIRED_AT line can follow the program's UART output on the same line)
        m = re.search(r"RETIRED_AT instructions=\d+ cycles=\d+", l)
        if m:
            print(m.group(0))
        elif l.startswith(("RETIRED", "CACHE_STATS", "FRTOS-RESULT", "Simulation timeout", "SCOREBOARD")):
            print(l)
    return 0 if "SCOREBOARD: PASS" in r.stdout and not re.search(r"%(Fatal|Error)", r.stdout) else 1


def helper_lint(a, vars_):
    """make lint-loops in the standard build and in this configuration; HaDes-V+'s signals must be
    the same, the golden CPU's further ones are listed."""
    def lists(v):
        r = subprocess.run(make_cmd(["lint-loops"], v), capture_output=True, text=True, env=clean_env())
        print(r.stdout)
        bdir, _ = build_dir(v)
        return {cpu: sorted(l.split(":")[0] for l in read(os.path.join(bdir, "lint", f"loops-{cpu}.txt")).splitlines()
                            if l.strip()) for cpu in ("dut", "golden")}, r.returncode
    std, rc1 = lists([])
    cfg, rc2 = lists(vars_)
    print(f"LINT dut: {'SAME' if std['dut'] == cfg['dut'] else 'DIFFERENT'} "
          f"({len(cfg['dut'])} signals; standard {len(std['dut'])})")
    extra = [s for s in cfg["golden"] if s not in std["golden"]]
    print(f"LINT golden: {len(cfg['golden'])} signals, the standard {len(std['golden'])}; further: {', '.join(extra) or 'none'}")
    return rc1 | rc2


HELPERS = {"_resets": helper_resets, "_model": helper_model, "_benches": helper_benches,
           "_timing_benches": helper_timing_benches, "_cached_vs_golden": helper_cached_vs_golden, "_cpi": helper_cpi,
           "_lint": helper_lint}


# ------------------------------------------------------------------------------ the runner
def tree_id():
    def git(*args):
        return subprocess.run(["git", "-C", REPO] + list(args), capture_output=True, text=True).stdout
    h = hashlib.sha256((git("diff", "HEAD") + git("ls-files", "--others", "--exclude-standard")).encode()).hexdigest()
    return f"{git('rev-parse', 'HEAD').strip()[:12]}+{h[:12]}"


def load(out):
    try:
        return json.load(open(os.path.join(out, "matrix.json")))
    except (OSError, ValueError):
        return {}


def save(out, rec, lock):
    with lock:
        tmp = os.path.join(out, "matrix.json.tmp")
        with open(tmp, "w") as f:
            json.dump(rec, f, indent=1, sort_keys=True)
        os.replace(tmp, os.path.join(out, "matrix.json"))


def collect_logs(job, d):
    """Copy the logs that a FreeRTOS job leaves in its build directory into the job's directory."""
    if not job.logs:
        return
    kind, app = job.logs
    bdir, _ = build_dir(job.vars)
    src = os.path.join(bdir, "test", "freertos", app)
    if os.path.isdir(src):
        for f in os.listdir(src):
            if f.endswith(".log") and f != "build.log":
                shutil.copy(os.path.join(src, f), os.path.join(d, f))


def run_job(job, out, tid):
    d = os.path.join(out, "jobs", job.id.replace("/", "--"))
    if os.path.isdir(d):
        shutil.rmtree(d)
    os.makedirs(d)
    env = clean_env()
    if getattr(job, "env_from_config", False):
        bdir, text = build_dir(job.vars)
        m = re.search(r"\n\s+(HADES_BUILD_DIR=\S+(?: HADES_\w+=\S+)*)\s*$", text)
        for kv in (m.group(1).split() if m else []):
            k, v = kv.split("=", 1)
            env[k] = v
    t0 = time.time()
    r = subprocess.run(job.cmd(d), cwd=job.cwd or REPO, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       text=True, errors="replace", env=env)
    with open(os.path.join(d, "output.txt"), "w") as f:
        f.write(r.stdout)
    collect_logs(job, d)
    try:
        verdict, notes = job.judge(job, r.returncode, r.stdout, d)
    except Exception as e:                       # a judge that cannot read its logs
        verdict, notes = "FAIL", [f"judge error: {e!r}"]
    return dict(leg=job.leg, job=job.name, configuration=" ".join(job.vars) or "standard", cpus=job.cpus,
                verdict=verdict, notes=notes, dir=os.path.relpath(d, out), tree=tid,
                seconds=round(time.time() - t0, 1), exit=r.returncode)


def select(L, names, only):
    if not names or names == ["all"]:
        names = list(L)
    unknown = [n for n in names if n not in L]
    if unknown:
        sys.exit(f"matrix.py: unknown leg(s) {unknown}; see: matrix.py list")
    jobs = [j for n in names for j in L[n]]
    return [j for j in jobs if re.search(only or "", j.id)]


def cmd_list(a):
    L = legs()
    total = 0
    for name in (a.legs or list(L)):
        jobs = L[name]
        print(f"{name}: {len(jobs)} job(s)")
        for j in jobs:
            total += j.est
            print(f"    {j.id:58s} {j.cpus:5s} ~{j.est / 1e6:8.1f} M cycles  {' '.join(j.vars) or '(standard)'}")
    print(f"{sum(len(L[n]) for n in (a.legs or list(L)))} jobs, about {total / 1e9:.1f} G simulated cycles")
    return 0


def cmd_run(a):
    L = legs()
    jobs = sorted(select(L, a.legs, a.only), key=lambda j: -j.est)
    out = os.path.abspath(a.out)
    os.makedirs(out, exist_ok=True)
    tid = tree_id()
    rec = load(out)
    lock = threading.Lock()
    todo = [j for j in jobs if a.rerun or rec.get(j.id, {}).get("tree") != tid]
    print(f"tree {tid}; {len(jobs)} job(s), {len(jobs) - len(todo)} already judged for this tree; "
          f"{len(todo)} to run, {a.jobs} at a time, longest first; results in {out}", flush=True)
    if a.dry_run:
        for j in todo:
            print(f"  would run {j.id}")
        return 0
    cache_ok = {}
    held, held_lock = set(), threading.Condition()

    def worker(job):
        key = " ".join(job.vars)
        if job.needs_cache:
            if key not in cache_ok:
                cache_ok[key] = has_cache(job.vars)
            if not cache_ok[key]:
                res = dict(leg=job.leg, job=job.name, configuration=key, cpus=job.cpus, verdict="REFUSED",
                           notes=["make sim-config shows no instruction cache in this configuration: the tree's "
                                  "Makefile does not know ICACHE"], dir="", tree=tid, seconds=0, exit=None)
                return job, res
        with held_lock:
            while job.lock is not None and job.lock in held:
                held_lock.wait()
            if job.lock is not None:
                held.add(job.lock)
        try:
            return job, run_job(job, out, tid)
        finally:
            with held_lock:
                held.discard(job.lock)
                held_lock.notify_all()

    with cf.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        futs = [ex.submit(worker, j) for j in todo]
        for f in cf.as_completed(futs):
            job, res = f.result()
            rec[job.id] = res
            save(out, rec, lock)
            print(f"  {res['verdict']:8s} {job.id}  ({res['seconds']} s)" +
                  "".join(f"\n           {n}" for n in res["notes"][:6]), flush=True)
    return summary(out, [j.id for j in jobs])


def summary(out, ids=None):
    rec = load(out)
    rows = [r for k, r in sorted(rec.items()) if ids is None or k in ids]
    lines = ["| leg | job | configuration | CPUs | result | log |", "|---|---|---|---|---|---|"]
    for r in rows:
        lines.append(f"| {r['leg']} | {r['job']} | {r['configuration']} | {r['cpus']} | {r['verdict']} | {r['dir']} |")
    with open(os.path.join(out, "summary.md"), "w") as f:
        f.write("\n".join(lines) + "\n")
    count = {}
    for r in rows:
        count[r["verdict"]] = count.get(r["verdict"], 0) + 1
    print("\n".join(lines))
    missing = [i for i in (ids or []) if i not in rec]
    ok = rows and all(r["verdict"] == "PASS" for r in rows) and not missing
    print(f"MATRIX: {'PASS' if ok else 'NOT PASSED'}  {len(rows)} job(s): "
          + ", ".join(f"{v} {n}" for v, n in sorted(count.items()))
          + (f"; {len(missing)} not run" if missing else "") + f"; table {out}/summary.md, verdicts {out}/matrix.json")
    return 0 if ok else 1


def main():
    if len(sys.argv) > 1 and sys.argv[1] in HELPERS:
        ap = argparse.ArgumentParser()
        ap.add_argument("helper")
        ap.add_argument("--dir", required=True)
        ap.add_argument("--programs", default="")
        ap.add_argument("--cached", default="1")
        ap.add_argument("--app", default="")
        ap.add_argument("--bpred", default="0")
        ap.add_argument("vars", nargs="*")
        a = ap.parse_args()
        return HELPERS[a.helper](a, a.vars)
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("list")
    p.add_argument("legs", nargs="*")
    p = sub.add_parser("run")
    p.add_argument("legs", nargs="*")
    p.add_argument("--jobs", type=int, default=2,
                   help="jobs at a time (default 2; a program-set job runs 4 simulations at a time itself)")
    p.add_argument("--out", default=os.path.join(REPO, "build", "matrix"))
    p.add_argument("--only", default="", help="only the jobs whose id matches this regular expression")
    p.add_argument("--rerun", action="store_true", help="run jobs whose verdict is already recorded")
    p.add_argument("--dry-run", action="store_true")
    p = sub.add_parser("summary")
    p.add_argument("--out", default=os.path.join(REPO, "build", "matrix"))
    a = ap.parse_args()
    if a.cmd == "list":
        return cmd_list(a)
    if a.cmd == "run":
        return cmd_run(a)
    return summary(os.path.abspath(a.out))


if __name__ == "__main__":
    sys.exit(main())
