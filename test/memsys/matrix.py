#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""matrix.py -- the verification matrix of the simulators with an instruction cache and with both caches.

Runs the legs below, each a set of jobs (one configuration, one program set or one FreeRTOS
program, one or both CPUs), judges every job, checks the CACHE_STATS identities on every log of a
cached run, and keeps the verdicts, so that the whole matrix can be run over several sessions:

    python3 test/memsys/matrix.py list [<leg>...]            the legs, their jobs and estimates
    python3 test/memsys/matrix.py run  [<leg>...|all] [--jobs N] [--out DIR] [--only REGEX]
                                       [--rerun] [--dry-run]
    python3 test/memsys/matrix.py summary [--out DIR]       the table of the recorded verdicts

Configurations: the small cache (ICACHE=512) and the large one (ICACHE=8192), 16-byte lines unless
a leg says otherwise; 'standard' is the build without a slow memory. The legs whose names begin with 'd-'
run the same suites with a data cache as well: the small pair (ICACHE=512 DCACHE=512, 'i512-d512') in place
of the small cache and the large pair (ICACHE=8192 DCACHE=4096, 'i8k-d4k') in place of the large one;
'i-only-regression' runs the instruction-cache-only configurations on this tree and on an earlier revision
(REGRESSION_BASE=<revision>) and compares them. Latency profiles:

    lat0     no MEM_* option: the cache alone, latency 0 (refills at one cycle per beat)
    lat2     MEM_LAT=2: every transfer waits 2 cycles, bursts off
    rand1-3  MEM_LAT=1:8 with MEM_SEED=1, 2, 3: random 1..8 cycles per transfer
    burst    MEM_LAT=1:8 MEM_BEAT_LAT=0: random first beat, one cycle per further refill beat
    stress   MEM_LAT=1:64: beyond the interconnect timeout without the RAM's exemption
    dram     MEM_LAT=8:24 MEM_WR_LAT=1:4 MEM_BEAT_LAT=0: DRAM-like (measurements only)
    dram-nobursts  MEM_LAT=8:24 MEM_WR_LAT=1:4 without a cache: the baseline of the CPI rows
    dram-wr48, dram-wr824  as dram with MEM_WR_LAT=4:8 and 8:24 (reads stay 8:24): the write-latency rows

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
and, with a data cache (the dc_ fields; d_loads is then the words that D-refills read, d_stores the stores):
    dc_load_misses = dc_done + dc_inflight      dc_beats = <words per line> * dc_done + dc_inflight_beats
    d_loads = dc_beats                          dc_lookup_hits = the loads of the SCOREBOARD line
    dc_store_hits + dc_store_misses = d_stores = the stores of the SCOREBOARD line
    at a fixed latency: port_irefill = <refill> * i_done + i_inflight_port and
    port_data = <refill> * dc_done + (write latency + 1) * d_stores + dc_inflight_port + d_inflight_port
and on a log with RESET lines: cycles = the cycles after the last reset (RETIRED counts every
cycle without reset since time 0; see cycles_after_last_reset).

Resuming: the verdicts are kept in <out>/matrix.json, keyed by job, with an identity of the tree
(the commit, the hash of 'git diff HEAD' and of the untracked files' names). A job whose verdict is
recorded for the same tree is not run again (--rerun runs it anyway). Jobs run longest first
(their estimated simulated cycles). Two FreeRTOS builds of the same program in one configuration
directory never run at the same time: their build directory is shared.

A leg that needs an instruction cache refuses to run in a tree whose Makefile does not know the
ICACHE option (make sim-config shows no HADES_ICACHE_BYTES define): such a tree would silently
build the uncached configuration. The same for a data cache and the DCACHE option.
"""
import argparse
import concurrent.futures as cf
import fcntl
import hashlib
import json
import os
import re
import shlex
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
    # the write latency of the store-stall measurement: reads stay 8:24
    "dram-wr48":  ["MEM_LAT=8:24", "MEM_WR_LAT=4:8", "MEM_BEAT_LAT=0"],
    "dram-wr824": ["MEM_LAT=8:24", "MEM_WR_LAT=8:24", "MEM_BEAT_LAT=0"],
    # fixed latencies of the interrupt-latency validation (irqlat.s)
    "lat1":   ["MEM_LAT=1"],
    "lat5":   ["MEM_LAT=5"],
}
CACHES = {"i512": ["ICACHE=512"], "i8k": ["ICACHE=8192"], "i16k": ["ICACHE=16384"], "standard": [],
          "i512-line8": ["ICACHE=512", "LINE=8"], "i512-line32": ["ICACHE=512", "LINE=32"],
          "i512-line64": ["ICACHE=512", "LINE=64"],
          # with a data cache as well: the small pair (512-byte caches) and the large pair (8 KiB and 4 KiB)
          "i512-d512": ["ICACHE=512", "DCACHE=512"], "i8k-d4k": ["ICACHE=8192", "DCACHE=4096"],
          "i512-d512-line8": ["ICACHE=512", "DCACHE=512", "LINE=8"], "i512-d512-line32": ["ICACHE=512", "DCACHE=512", "LINE=32"],
          "i512-d512-line64": ["ICACHE=512", "DCACHE=512", "LINE=64"]}
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
DCACHE_LINE = re.compile(r"^CACHE D-cache (\d+) bytes, (\d+)-byte lines", re.M)
SCOREBOARD_PASS = re.compile(r"^SCOREBOARD: PASS\s+(\d+) fetches, (\d+) loads, (\d+) stores", re.M)
RETIRED = re.compile(r"^RETIRED cycles=(\d+)", re.M)
# (a program's UART text without a newline can stand in front of the RESET line, as in front of
# RETIRED_AT, so it is searched in the line, not at its start)
RESET = re.compile(r"RESET at cycle (\d+) \(\+reset_at=(\d+)\): (.*)$", re.M)
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


def sim_latencies(text):
    """The latencies of the one memory port from the 'SLOW MEMORY memory port:' line of a log ->
    (read range, write range, burst beat latency or -1 when off) or None."""
    m = re.search(r"^SLOW MEMORY memory port: read latency (\S+), write latency (\S+), burst beats (\S+)", text, re.M)
    if not m:
        return None

    def rng(t):
        a = re.fullmatch(r"(\d+)(?:(?:\.\.|:|-)(\d+))?", t.strip())
        return (int(a.group(1)), int(a.group(2) or a.group(1))) if a else None
    rd, wr = rng(m.group(1)), rng(m.group(2))
    beat = -1 if m.group(3).startswith("off") else int(re.match(r"\d+", m.group(3)).group(0))
    return (rd, wr, beat) if rd and wr else None


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
    dcache = "dc_lookup_hits" in st

    def need(name, got, want):
        if got != want:
            bad.append(f"{name}: {got} != {want}")
    try:
        need("i_refills = i_done + i_inflight", st["i_refills"], st["i_done"] + st["i_inflight"])
        need("i_refill_cycles = wait_i_for_port + port_irefill", st["i_refill_cycles"],
             st["wait_i_for_port"] + st["port_irefill"])
        need(f"i_beats = {lw} * i_done + i_inflight_beats", st["i_beats"], lw * st["i_done"] + st["i_inflight_beats"])
        if dcache:
            need("dc_load_misses = dc_done + dc_inflight", st["dc_load_misses"], st["dc_done"] + st["dc_inflight"])
            need(f"dc_beats = {lw} * dc_done + dc_inflight_beats", st["dc_beats"], lw * st["dc_done"] + st["dc_inflight_beats"])
            need("d_loads = dc_beats", st["d_loads"], st["dc_beats"])
            need("dc_store_hits + dc_store_misses = d_stores", st["dc_store_hits"] + st["dc_store_misses"], st["d_stores"])
        sb = SCOREBOARD_PASS.search(text)
        if sb:
            need("i_hits = scoreboard fetches", st["i_hits"], int(sb.group(1)))
            if dcache:
                need("dc_lookup_hits = scoreboard loads", st["dc_lookup_hits"], int(sb.group(2)))
            else:
                need("d_loads = scoreboard loads", st["d_loads"], int(sb.group(2)))
            need("d_stores = scoreboard stores", st["d_stores"], int(sb.group(3)))
        r = RETIRED.search(text)
        if r:
            need("cycles = RETIRED cycles", st["cycles"], int(r.group(1)))
        lat = sim_latencies(text) if dcache else None
        if lat and lat[0][0] == lat[0][1] and lat[1][0] == lat[1][1]:
            # a fixed latency: the port cycles of D-refills and stores (the burst rule discounts the beats of a refill block)
            rd, wr, beat = lat[0][0], lat[1][0], lat[2]
            refill = (rd + 1) + (lw - 1) * ((beat if beat >= 0 else rd) + 1)
            need(f"port_irefill = {refill} * i_done + i_inflight_port", st["port_irefill"],
                 refill * st["i_done"] + st["i_inflight_port"])
            need(f"port_data = {refill} * dc_done + {wr + 1} * d_stores + dc_inflight_port + d_inflight_port",
                 st["port_data"], refill * st["dc_done"] + (wr + 1) * st["d_stores"] + st["dc_inflight_port"] +
                 st["d_inflight_port"])
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
    """Whether make sim-config shows the caches that the options ask for (a tree whose Makefile does not know
    ICACHE or DCACHE would silently build the configuration without them)."""
    _, text = build_dir(vars_)
    if "+define+HADES_ICACHE_BYTES=" not in text:
        return False
    return "+define+HADES_DCACHE_BYTES=" in text or not any(v.startswith("DCACHE=") for v in vars_)


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


def cpi_judge(job, rc, out, d):
    """A CPI row: the helper's exit status and the logs as for any job (a column ended early by the program's own
    check is not a failure of the tool: the row is marked and run again with the automatic tick), and the
    lines of the row's table recorded."""
    verdict, notes = exit_judge(job, rc, out, d)
    notes = [n for n in notes if not n.startswith("last line")]
    for l in out.splitlines():
        if l.startswith("CPI "):
            notes.append(f"{l[:240]} (recorded)")
    if not any(n.startswith("CPI ROW") for n in notes):
        notes.append("no CPI ROW line")
    return ("PASS" if verdict == "PASS" and not [n for n in notes if "recorded" not in n] else "FAIL"), notes


# ---- the coverage of the directed tests (headers of the programs)
def header_minimum(prog, pattern):
    """A number from a test's header box, read as running text (the box's line breaks removed)."""
    text = re.sub(r"\s*\|[ \t]*\n#[ \t]*\|\s*", " ", read(os.path.join(REPO, "test", "memsys", prog + ".s")))
    m = re.search(pattern, text, re.S)
    return int(m.group(1)) if m else None


def irqchain_positions(job, d):
    """The interrupt positions that irqchain.s recorded (+ram_words=0x46000,0x46004: the masks of mode 0 and
    mode 3; bit b is an interrupt whose mepc is the word b after the first nop, 'pad', so bits 0-2 the nops,
    3 + k the chain instruction k, 19-21 the wait loop). Every position must be reached in at least one mode,
    except those that cannot be reached; each of those is listed with its reason, and a missing position
    without a reason fails the job.

    The reasons, derived from the assembled program and rtl/writeback_stage.sv (the program's header has them
    in words): an interrupt is recognised in the cycle in which an instruction I is in Writeback, I retires,
    and mepc is the address after the next instruction J if J is in Writeback in the next cycle (it retires
    too), else the address after I.
      - bit 0 (mepc = pad): J would be the arming store, so I would have to be in Writeback when the interrupt
        is pending, which is at least two cycles after the store's bus access, by when I, ahead of the store,
        has retired: unreachable at any latency.
      - mepc = word 1 of a cache line: J would be word 0 of that line and I the last word of the line before,
        retiring in consecutive cycles. The eviction step makes every tested line miss in every iteration, so
        word 0 of a line reaches Writeback only after the line's refill, many cycles after the last word of the
        line before: J is a bubble and mepc is word 0 instead. (Without a cache, with a slow memory,
        these positions are reached: masks 0x3ffffe at MEM_LAT=2.)"""
    words = re.search(r"^RAM_WORDS (.*)$", read(os.path.join(d, "dut", "memsys-irqchain", "sim.log")), re.M)
    if not words:
        return ["irqchain: no RAM_WORDS line"]
    vals = [int(v, 16) for v in re.findall(r"=(?:0x)?([0-9a-fA-F]+)", words.group(1))]
    union = 0
    for v in vals:
        union |= v
    log = read(os.path.join(d, "dut", "memsys-irqchain", "sim.log"))
    lm = LINE_BYTES.search(log)
    line = int(lm.group(1)) if lm else 16
    bdir, _ = build_dir(job.vars)
    dis = read(os.path.join(bdir, "test", "memsys", "irqchain", "init.dis"))
    pm = re.search(r"^([0-9a-f]+) <pad>:", dis, re.M)
    if not pm:
        return ["irqchain: cannot find 'pad' in the disassembly"]
    pad = int(pm.group(1), 16)
    why = {0: "bit 0: mepc = pad; J would be the arming store, I retires before the interrupt can be pending"}
    for b in range(1, 22):
        if (pad + 4 * b) % line == 4:
            why[b] = (f"bit {b}: mepc = word 1 of the line at 0x{pad + 4 * b - 4:x}; every tested line misses after the "
                      f"eviction step, so J (word 0) is a bubble behind the last word of the line before")
    missing = [b for b in range(22) if not union >> b & 1]
    unexplained = [b for b in missing if b not in why]
    reached_anyway = [b for b in why if union >> b & 1]
    notes = [f"irqchain positions: masks {[hex(v) for v in vals]}, union 0x{union:x}; {22 - len(missing)} of 22 "
             f"reached; wait loop {'reached' if any(union >> b & 1 for b in (19, 20, 21)) else 'NOT reached'}"
             + (f"; not reached and explained: {'; '.join(why[b] for b in missing if b in why)}" if missing else "")
             + (f"; reached although the reason applies: {reached_anyway}" if reached_anyway else "")
             + " (recorded)"]
    if unexplained:
        notes.append(f"irqchain positions without a reason: bits {unexplained}")
    return notes


def fetchredirect_cases(d, minimum):
    """Abandoned refills of fetchredirect.s per case, from the CACHE_STATS_MARK lines (+cache_stats_marks): the
    program reports twice at the end of each case (the checksum, the wrong-path counter): report 0 is the
    initial fail, then cases 2, 3 and 4 in mode 0 (reports 1-6), then in mode 3 (7-12), then the end (13, 14).
    A case's counts are those between the last report before it and its second report (its eviction step
    comes first, so it belongs to the case)."""
    log = read(os.path.join(d, "dut", "memsys-fetchredirect", "sim.log"))
    marks = {int(m.group(1)): int(m.group(2)) for m in
             re.finditer(r"CACHE_STATS_MARK report=(\d+) cycles=\d+ i_done=\d+ i_abandoned=(\d+)", log)}
    if sorted(marks) != list(range(15)):
        return [f"fetchredirect: {len(marks)} CACHE_STATS_MARK lines, expected 15 (run with +cache_stats_marks)"]
    notes, rows = [], []
    for mode, base in ((0, 0), (3, 6)):
        for case, first in ((2, 0), (3, 2), (4, 4)):
            lo, hi = base + first, base + first + 2
            rows.append((mode, case, marks[hi] - marks[lo]))
    notes.append("fetchredirect i_abandoned per case: " +
                 ", ".join(f"mode {m} case {c}: {n}" for m, c, n in rows) + " (recorded)")
    low = [(m, c, n) for m, c, n in rows if n < (minimum or 1)]
    if minimum is None:
        notes.append("fetchredirect: no per-case minimum in its header")
    if low:
        notes.append(f"fetchredirect: i_abandoned below the header's {minimum} per case: {low}")
    return notes


def positions_confirm_judge(job, rc, out, d):
    """irqchain.s in a 16 KiB cache: the eviction block, 8 KiB after the tested code, has another index there
    and evicts nothing, so the tested lines stay cached and the positions that the eviction step makes
    unreachable (word 1 of a line, see irqchain_positions) are reached. Every position but bit 0 must be."""
    verdict, notes = programs_judge(job, rc, out, d)
    words = re.search(r"^RAM_WORDS (.*)$", read(os.path.join(d, "dut", "memsys-irqchain", "sim.log")), re.M)
    if not words:
        return "FAIL", notes + ["irqchain: no RAM_WORDS line"]
    union = 0
    for v in re.findall(r"=(?:0x)?([0-9a-fA-F]+)", words.group(1)):
        union |= int(v, 16)
    missing = [b for b in range(1, 22) if not union >> b & 1]
    notes.append(f"irqchain positions in the 16 KiB cache: union 0x{union:x}; positions 1 to 21 not reached: {missing or 'none'}"
                 + (" (recorded)" if not missing else ""))
    return ("PASS" if verdict == "PASS" and not missing else "FAIL"), notes


DSIDE_MINIMA = {
    prog: dict(dc_load_misses=(prog, r"dc_load_misses is at least (\d+)"),
               dc_store_hits=(prog, r"dc_store_hits at least (\d+)"),
               dc_store_misses=(prog, r"dc_store_misses at least (\d+)"))
    for prog in ("dcache", "dcoherence")}


def dside_notes(d):
    """The coverage stated in the headers of dcache.s and dcoherence.s: CACHE_STATS dc_load_misses, dc_store_hits and
    dc_store_misses at least the minimum of the header (they do not depend on the timing, and are the same for the
    512-byte and the 4 KiB data cache, 16-byte lines) -> notes ('(recorded)' for a figure that holds)."""
    notes = []
    for prog, want in DSIDE_MINIMA.items():
        log = read(os.path.join(d, "dut", f"memsys-{prog}", "sim.log"))
        if not log:
            continue
        st = stats_of(log)
        if not st or "dc_load_misses" not in st:
            notes.append(f"{prog}: no CACHE_STATS line with the dc_ fields")
            continue
        for k, (hp, pat) in want.items():
            v = header_minimum(hp, pat)
            if v is None:
                notes.append(f"{prog}: no minimum of {k} in its header")
            elif st.get(k, -1) < v:
                notes.append(f"{prog}: {k}={st.get(k)} below the header's {v}")
            else:
                notes.append(f"{prog}: {k}={st.get(k)} (at least {v}; recorded)")
    return notes


def dcache_coverage_judge(job, rc, out, d):
    """dcache.s and dcoherence.s (and the other programs of the job) as programs.py judges them, and the coverage of
    their headers."""
    verdict, notes = programs_judge(job, rc, out, d)
    notes += dside_notes(d)
    fails = [n for n in notes if "recorded" not in n and not n.startswith("golden (recorded)")]
    return ("PASS" if verdict == "PASS" and not fails else "FAIL"), notes


def coverage_judge(job, rc, out, d):
    """Directed tests with a cache: the reports as on the standard build (programs.py), and the
    coverage stated in each test's header: i_done and i_abandoned of irqchain and fetchredirect,
    snoop_inval of icoherence, the interrupt positions of irqchain (+ram_words), and every test
    below 80% of its cycle limit; with a data cache also the data-cache figures of dcache.s and
    dcoherence.s."""
    verdict, notes = programs_judge(job, rc, out, d)
    large = job.cache.startswith("i8k")
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
    if "-d" in job.cache:
        notes += dside_notes(d)
    notes += irqchain_positions(job, d)
    notes += fetchredirect_cases(d, header_minimum("fetchredirect", r"\(at least (\d+) per case\)"))
    fails = [n for n in notes if "recorded" not in n]
    return ("PASS" if verdict == "PASS" and not fails else "FAIL"), notes


# ---- the validation of +irq_latency: irqlat.s, whose latencies are derived by hand in its header
# (interrupts, max, mean) at the standard memory and at fixed latencies without a cache
IRQLAT_EXPECTED = {"std": (6, 2, "2.00"), "lat1": (6, 4, "3.50"), "lat2": (6, 6, "5.00"), "lat5": (6, 12, "9.50")}


def irqlat_judge(job, rc, out, d):
    """The IRQLAT line of irqlat.s against the figures derived by hand in its header, and the program's
    own reports (programs.py)."""
    verdict, notes = programs_judge(job, rc, out, d)
    if job.profile == "std":
        # the standard simulator has no scoreboard (it is on with a slow memory)
        notes = [n for n in notes if not n.startswith("scoreboard PASS in")]
        verdict = "PASS" if rc == 0 and not [n for n in notes if not n.startswith("golden")] else "FAIL"
    want = IRQLAT_EXPECTED[job.profile]
    log = read(os.path.join(d, "dut", "memsys-irqlat", "sim.log"))
    m = re.search(r"^IRQLAT interrupts=(\d+) max=(\d+) mean=([0-9.]+)", log, re.M)
    if not m:
        notes.append("no IRQLAT line")
    else:
        got = (int(m.group(1)), int(m.group(2)), m.group(3))
        if got != want:
            notes.append(f"IRQLAT interrupts={got[0]} max={got[1]} mean={got[2]}, derived by hand: "
                         f"interrupts={want[0]} max={want[1]} mean={want[2]}")
        else:
            notes.append(f"IRQLAT {m.group(0)[7:]} equals the figures derived by hand (recorded)")
    return ("PASS" if verdict == "PASS" and not [n for n in notes if "recorded" not in n and not n.startswith("golden")]
            else "FAIL"), notes


def irqlat_job(profile):
    job = programs_job("irq-latency-validation", "standard", profile, only="memsys/irqlat$", cpus="dut",
                       sim_args="+irq_latency", judge=irqlat_judge, est=2e6,
                       name="standard-memory" if profile == "std" else f"mem-{profile}")
    job.needs_cache = False
    return job


# ---- mid-run resets (the reset leg): placed from a +cache_phase_log run
RESET_DELAY = 3          # cycles from buttons_async[0] to rst (two synchronizer stages, the rst flip-flop)
PHASES = {
    "refill beat":      lambda b: b & 1,
    "refill waiting":   lambda b: b & 2,
    "RAM store wait":   lambda b: (b & 0x1C) == 0x1C,
    "RAM load wait":    lambda b: (b & 0x1C) == 0x0C,
    "I/O wait":         lambda b: (b & 0x0C) == 0x04,
    # with a data cache: bit 7 of the phase log is 'the D-cache is in REFILL', bit 5 'the data side is granted the port'
    "D refill beat":    lambda b: (b & 0x80) and (b & 0x20),
    "D refill waiting": lambda b: (b & 0x80) and not (b & 0x20),
}
# The phase of a RESET line. With a cache a RAM access that waits for its answer is either still
# waiting for the memory port ("RAM load waiting") or granted it ("granted (RAM load)"); both count.
RESET_TEXT = {"refill beat": r"I-cache refill beat", "refill waiting": r"I-cache refill waiting for the port",
              "RAM store wait": r"data side (RAM store waiting|granted \(RAM store\))",
              "RAM load wait": r"data side (RAM load waiting|granted \(RAM load\)|RAM load: refill)",
              "I/O wait": r"data side I/O access waiting",
              "D refill beat": r"data side RAM load: refill beat \d+ of \d+",
              "D refill waiting": r"data side RAM load: refill waiting for the port"}


def place_resets(phase_log, cached, dcached=False):
    """Cycles to reset in, from a phase log (one byte per cycle): three refill beats and three waiting
    refills (cached only), the same of the D-cache's refills (with a data cache only), and for each kind of
    data wait its first, a middle and its last cycle."""
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
        if not dcached and name.startswith("D refill"):
            continue
        rs = runs(test)
        if name.startswith(("refill", "D refill")):
            for s, e in rs[len(rs) // 4::max(1, len(rs) // 3)][:3]:
                picks.append((name, s + (e - s) // 2))
        else:
            long = [r for r in rs if r[1] - r[0] >= 2] or rs
            if long:
                s, e = long[len(long) // 2]
                picks += [(name + " (first)", s), (name + " (middle)", (s + e) // 2), (name + " (last)", e)]
    return [(n, c) for n, c in picks if c > RESET_DELAY + 2]


def reset_runs(job, d, sim, prog_dir, prog, cached, timeout, dcached=False):
    """One phase-log run and one run per placed reset -> (notes, results)."""
    os.makedirs(d, exist_ok=True)
    shutil.copy(os.path.join(prog_dir, "init.mem"), d)
    base = subprocess.run([sim, "+nodump", f"+timeout={timeout}", "+cache_phase_log=phase.bin"], cwd=d,
                          capture_output=True, text=True, errors="replace")
    notes, results = [], []
    if not os.path.exists(os.path.join(d, "phase.bin")):
        return [f"{prog}: no phase log ({base.stdout[-200:]})"], results
    for name, cyc in place_resets(os.path.join(d, "phase.bin"), cached, dcached):
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


def resets_judge_factory(cached, minimum=3, dcached=False):
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
        need = {k: minimum for k in RESET_TEXT if (cached or not k.startswith("refill"))
                and (dcached or not k.startswith("D refill"))}
        for k, n in need.items():
            if count[k] < n:
                notes.append(f"only {count[k]} reset(s) in phase '{k}' by the RESET lines (need {n})")
        notes.append(f"resets by phase (recorded): {count}")
        return ("PASS" if not [n for n in notes if "recorded" not in n] else "FAIL"), notes
    return judge


def resets_job(leg, cache, profile, progs=("memsys/stores", "memsys/fetchredirect", "memsys/icoherence",
                                           "memsys/irqchain", "asm/ops", "asm/memirq")):
    dcached = "-d" in cache
    if dcached and "memsys/dcache" not in progs and progs:
        progs = tuple(progs) + ("memsys/dcache",)
    # asm/memirq is the program of the set that accesses the test stall register (a 4-cycle wait for
    # the answer): none of the others waits for an I/O answer, so without it no reset lands in an I/O wait
    cached = cache != "standard"

    def cmd(d):
        return [sys.executable, os.path.abspath(__file__), "_resets", "--dir", d, "--cached", str(int(cached)),
                "--dcached", str(int(dcached)), "--programs", ",".join(progs), "--"] + config(cache, profile)
    return Job(leg, cname(cache, profile), cache, profile, cmd, resets_judge_factory(cached, dcached=dcached), 5e7,
               cpus="dut", needs_cache=cached)


# ---- model agreement (cachemodel.py rtlcheck; docs/CACHES.md)
# icoherence is left out: it stores to a line in the cycle that the line misses, and the cache model
# orders that store after the refill, while the arbiter serves the data side first (its refill then
# loads the stored words). The model approximates the core as waiting during a miss, so it cannot
# follow this order; the I-cache bench checks it cycle by cycle instead.
MODEL_PROGRAMS = ("memsys/fetchredirect", "asm/zkt", "memsys/stores")


def model_job(leg, cache, profile, burst=False, step4=False):
    """One model-agreement job: step 0 (timing independence), steps 1 to 3 (or 5 with burst: the run with
    MEM_BEAT_LAT=0) for the programs of MODEL_PROGRAMS (and dcache.s with a data cache), and with step4 the
    informative step 4."""
    extra = ["MEM_BEAT_LAT=0"] if burst else []
    programs = MODEL_PROGRAMS + (("memsys/dcache",) if "-d" in cache else ())

    def cmd(d):
        return [sys.executable, os.path.abspath(__file__), "_model", "--dir", d, "--programs",
                ",".join(programs)] + (["--app", "minimal"] if step4 else []) + \
            ["--"] + config(cache, profile) + extra

    def judge(job, rc, out, d):
        notes = []
        for prog in programs:
            m = re.search(rf"^MODEL {re.escape(prog)}: RTLCHECK: (\S+)", out, re.M)
            if not m or m.group(1) != "AGREE":
                notes.append(f"{prog}: {m.group(1) if m else 'no rtlcheck verdict'}")
            t = re.search(rf"^TIMING {re.escape(prog)}: (\S+)", out, re.M)
            if not t or t.group(1) != "SAME":
                notes.append(f"{prog}: step 0, {t.group(1) if t else 'no timing comparison'}: the retired instructions "
                             f"depend on the timing, replace the program")
        if step4:
            s4 = re.search(r"^STEP4 .*$", out, re.M)
            notes.append((s4.group(0)[:320] + " (recorded)") if s4 else "no STEP4 line")
        notes += logs_problems(d)
        return ("PASS" if not [n for n in notes if "recorded" not in n] else "FAIL"), notes
    name = cname(cache, profile) + ("-burst0" if burst else "")
    return Job(leg, name, cache, profile, cmd, judge, 2e7 + (6e7 if step4 else 0), cpus="dut", extra_vars=extra,
               lock=("trace", "minimal") if step4 else None)


# ---- the counter presets with both caches (HPM_PRESET=H and I): the monitor's own checks
def hpm_preset_judge(job, rc, out, d):
    """freertos-compare with a counter preset: as for any FreeRTOS compare, and the dut's log has 'HPM_CHECK ok' and
    'HPM_CACHE_COMPARE ok' (the counters of the cache events, those of the data cache included, equal CACHE_STATS)."""
    verdict, notes = freertos_judge(job, rc, out, d)
    dut_logs = [f for f in job_logs(d) if "dut" in os.path.basename(f)] or job_logs(d)
    text = "".join(read(f) for f in dut_logs)
    for want in ("HPM_CHECK ok", "HPM_CACHE_COMPARE ok"):
        if want not in text:
            notes.append(f"no '{want}' line in the dut log")
    return ("PASS" if not notes else "FAIL"), notes


# ---- regression: the instruction-cache-only configurations on this tree and on an earlier revision
def regression_judge(job, rc, out, d):
    notes = []
    m = re.search(r"^PROGRAMS COMPARE: (\S+)\s+(\d+) runs, (\d+) differ; equal bus hashes: (\d+)(.*)$", out, re.M)
    if not m:
        return "FAIL", ["no PROGRAMS COMPARE line" + (f": {out.strip().splitlines()[-1][:160]}" if out.strip() else "")]
    if m.group(1) != "SAME" or int(m.group(3)):
        notes.append(f"PROGRAMS COMPARE: {m.group(1)}, {m.group(3)} of {m.group(2)} runs differ")
    st = re.search(r"equal CACHE_STATS lines: (\d+)", m.group(5))
    notes.append(f"{m.group(2)} runs compared, equal bus hashes {m.group(4)}"
                 + (f", equal CACHE_STATS lines {st.group(1)}" if st else "") + " (recorded)")
    if not int(m.group(4)):
        notes.append("no bus hash was compared")
    if not st or not int(st.group(1)):
        notes.append("no CACHE_STATS line was compared")
    return ("PASS" if not [n for n in notes if "recorded" not in n] and rc == 0 else "FAIL"), notes


def regression_job(cache, profile):
    base = os.environ.get("REGRESSION_BASE", "")

    def cmd(d):
        return [sys.executable, os.path.abspath(__file__), "_regression", "--dir", d, "--base", base, "--"] + config(cache, profile)
    return Job("i-only-regression", cname(cache, profile), cache, profile, cmd, regression_judge, 6e7, cpus="both",
               needs_cache=True)


def helper_regression(a, vars_):
    """The same programs in the same configuration on this tree and on the revision a.base (a shared clone in
    <dir>/base): programs.py run with +bushash on both, then programs.py compare restricted to the programs whose
    sources are the same in the two revisions (the same sources give the same images), with asm/hpm and memsys/hpmcache,
    whose fetched words were changed on purpose, compared by their reports, and with the CACHE_STATS lines compared too."""
    if not a.base:
        print("REGRESSION: give the earlier revision in the environment: REGRESSION_BASE=<revision> matrix.py run ...")
        return 2
    base_dir = os.path.join(a.dir, "base")
    if not os.path.isdir(base_dir):
        subprocess.run(["git", "clone", "-q", "--shared", REPO, base_dir], check=True)
    subprocess.run(["git", "-C", base_dir, "checkout", "-q", a.base], check=True)
    tip = subprocess.run(["git", "-C", REPO, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    runs = {}
    for name, root in (("A", base_dir), ("B", REPO)):
        out = os.path.join(a.dir, f"runs-{name}")
        r = subprocess.run([sys.executable, os.path.join(root, "test", "memsys", "programs.py"), "run"] + vars_ +
                           ["--sim-args", "+bushash", "--jobs", "4", "--out", out], cwd=root, env=clean_env(),
                           capture_output=True, text=True, errors="replace")
        print(f"PROGRAMS RUN {name} ({root}): exit {r.returncode}; " + (r.stdout.strip().splitlines() or ["(no output)"])[-1][:200])
        runs[name] = out
    c = subprocess.run([sys.executable, os.path.join(HERE, "programs.py"), "compare", "--same-sources", a.base, tip,
                        "--reports-only", "asm/hpm", "--reports-only", "memsys/hpmcache", "--stats", runs["A"], runs["B"]],
                       cwd=REPO, capture_output=True, text=True, errors="replace")
    print(c.stdout)
    return c.returncode


# ---- 6.8: the data cache's CPI and store stall, with the model's write buffers
def model_trace(app, bpred, d, vars_extra, ram_kb, window, mark):
    """The bus trace of the program at the standard memory (TICK=10000, the row's BPRED), prepared, and the cycle at which it has retired `mark`
    instructions -> (prepared directory, window end) or (None, None)."""
    import numpy as np
    tdir = os.path.join(d, "trace")
    os.makedirs(tdir, exist_ok=True)
    binfile = os.path.join(tdir, "bustrace.bin")
    vars_extra = [v for v in vars_extra if not v.startswith("MEM_")]       # the trace is at the standard memory
    if app == "shell":
        subprocess.run(make_cmd(["freertos-shell-test", "APP=shell", f"APP_CONSOLE_ARGS=+bustrace={binfile}"],
                                ["BUSTRACE=1", "TICK=10000", f"BPRED={bpred}"] + vars_extra), capture_output=True,
                       text=True, env=clean_env())
    else:
        frtos_direct(app, ["BUSTRACE=1", "TICK=10000", f"BPRED={bpred}"] + vars_extra + window, ["+bustrace=" + binfile], tdir)
    if not os.path.exists(binfile):
        return None, None
    prepared = os.path.join(tdir, "prepared")
    model_prep(binfile, prepared, ram_kb, app)
    os.remove(binfile)
    code = np.load(os.path.join(prepared, "code.npy"), mmap_mode="r")
    retired = np.cumsum((np.asarray(code) >> 5) & 1)
    if mark is None or retired[-1] < mark:
        return None, None
    return prepared, int(np.searchsorted(retired, mark)) + 1


def model_d_columns(prepared, w1, seed, wr, d):
    """The model of PD x GD on a prepared trace over w1 cycles, with write latency wr: --wbuf none, line and ideal ->
    {wbuf: figures}."""
    out = {}
    for wbuf in ("none", "line", "ideal"):
        res = model_run(prepared, ["--isize", "8192", "--dsize", "4096", "--line", "16", "--mem", "burst", "--beat-cycles", "1",
                                   "--rd-lat", "8:24", "--wr-lat", wr, "--wbuf", wbuf], os.path.join(d, f"model-{wbuf}.jsonl"),
                        seed=seed, w1=w1)
        raw = res["raw"]
        out[wbuf] = dict(cycles=res["cycles"], instructions=res["instructions"], cpi=res["cpi"], cpi_base=res["cpi_base"],
                         i_mpki=res["i_mpki"], d_mpki=res["d_mpki"], store_stall_share=res["store_stall_share"],
                         st_store=raw["st_store"], wait_i_for_port=raw["wait_i_for_port"],
                         wait_d_for_port=raw["wait_d_for_port"])
    return out


WR_LAT = {"dram": "1:4", "dram-wr48": "4:8", "dram-wr824": "8:24"}      # the write latency of each profile


def cpi_d_lines(prefix, name, wrname, cols, mark, model):
    """The table of one line of a row with a data cache -> list of text lines. cols: 'baseline' (uncached), 'ionly'
    (the instruction cache alone, P x GD) and 'pd' (PD x GD) columns; the first two only in the row at the base
    write latency."""
    out = []
    head = f"{prefix}ROW {name} (write latency {WR_LAT[wrname]})"
    pd = cols["pd"]
    if mark is None:
        out.append(f"{head}: no RETIRED_AT mark reached by all columns; whole runs: PD CPI "
                   f"{pd['cycles'] / pd['instructions']:.3f}")
        return out
    out.append(f"{head}: compared over the first {mark} retired instructions (the largest RETIRED_AT mark of all columns)")
    for col, label in (("baseline", "baseline (no cache)"), ("ionly", "P x GD (I-cache)"), ("pd", "PD x GD (I and D)")):
        f = cols.get(col)
        if not f:
            continue
        tick = f" tick {f['tick']}" if f.get("tick") else ""
        out.append(f"{prefix}  {label:20s} cycles {f['marks'][mark]:>10}  instructions {mark:>8}  CPI {cpi_at(f, mark):.3f}"
                   f"   (whole run: {f['cycles']} cycles, {f['instructions']} instructions{tick})")
    st, n, cyc = pd["stats"], pd["instructions"], pd["cycles"]
    if st and "dc_store_wait" in st:
        out.append(f"{prefix}  PD x GD CACHE_STATS: I-MPKI {1000.0 * st['i_done'] / n:.2f}  D-MPKI "
                   f"{1000.0 * st['dc_load_misses'] / n:.2f}  (dc_load_misses {st['dc_load_misses']}, dc_lookup_hits "
                   f"{st['dc_lookup_hits']}, dc_store_hits {st['dc_store_hits']}, dc_store_misses {st['dc_store_misses']})")
        out.append(f"{prefix}  store stall (no write buffer): dc_store_wait {st['dc_store_wait']} cycles = "
                   f"{100.0 * st['dc_store_wait'] / cyc:.2f}% of all cycles = {st['dc_store_wait'] / n:.4f} per instruction")
        out.append(f"{prefix}  port sharing: wait_d_for_port {st['wait_d_for_port']} cycles = {st['wait_d_for_port'] / n:.4f} per "
                   f"instruction; wait_i_for_port {st['wait_i_for_port']} = {st['wait_i_for_port'] / n:.4f}; dc_refill_cycles "
                   f"{st['dc_refill_cycles']}")
    if model:
        for wbuf in ("none", "line", "ideal"):
            m = model[wbuf]
            extra = ""
            if wbuf == "none":
                extra = (f"; store stall share {100.0 * m['store_stall_share']:.2f}% of cycles = {m['st_store'] / m['instructions']:.4f} "
                         f"per instruction; I-MPKI {m['i_mpki']:.2f}, D-MPKI {m['d_mpki']:.2f}; wait_i_for_port "
                         f"{m['wait_i_for_port']}, wait_d_for_port {m['wait_d_for_port']}")
            out.append(f"{prefix}  model --wbuf {wbuf:5s} cycles {m['cycles']:>10}  instructions {m['instructions']:>8}  "
                       f"CPI {m['cpi']:.3f}{extra}")
        base = model["none"]["cpi"]
        out.append(f"{prefix}  a write buffer would take the CPI from {base:.3f} to {model['line']['cpi']:.3f} (one line) or "
                   f"{model['ideal']['cpi']:.3f} (ideal): {base - model['line']['cpi']:.3f} and {base - model['ideal']['cpi']:.3f} "
                   f"cycles per instruction")
    else:
        out.append(f"{prefix}  model    not applicable (its traces are the runs at TICK=10000)")
    return out


def helper_cpirow_d(a, vars_):
    """One row of the CPI measurement with a data cache (6.8): the program in PD x GD with the write latency of a.wr
    (dram: 1:4, dram-wr48: 4:8, dram-wr824: 8:24; reads stay 8:24), at TICK=10000 and the row's branch-predictor mode,
    and, at the base write latency (a.columns all), also in the uncached baseline and with the instruction cache alone
    (P x GD, the earlier 'after'). The columns are compared at the largest RETIRED_AT mark that they all reached, the
    model (--wbuf none, line, ideal, the same write latency) on the trace of the same program over the same number of
    retired instructions. A row whose program check ends a column early is run once more with the automatic tick,
    without the model (lines prefixed 'CPI D AUTO')."""
    seed = int(a.seed)
    extra = list(vars_)
    columns = {"pd": config("i8k-d4k", a.wr)}
    if a.columns == "all":
        columns.update(baseline=config("standard", "dram-nobursts"), ionly=config("i8k", "dram"))
    rows = {}
    for line, prefix, tick in ((1, "CPI D ", ["TICK=10000"]), (2, "CPI D AUTO ", [])):
        cols = {name: column_run(a.app, cv, os.path.join(a.dir, f"line{line}-{name}"), extra + tick, a.bpred)
                for name, cv in columns.items()}
        marks = sorted(set.intersection(*(set(c["marks"]) for c in cols.values())))
        mark = marks[-1] if marks else None
        model = None
        if line == 1:
            window = ["TIMEOUT=10000000"] if a.app == "full" else []
            prepared, w1 = model_trace(a.app, a.bpred, a.dir, extra, cols["pd"]["ram_kb"], window, mark)
            if prepared:
                model = model_d_columns(prepared, w1, seed, WR_LAT[a.wr], a.dir)
        for l in cpi_d_lines(prefix, a.name, a.wr, cols, mark, model):
            print(l, flush=True)
        rows[line] = dict(mark=mark, model=model, **{k: {kk: vv for kk, vv in v.items() if kk != "marks"} for k, v in cols.items()})
        for name, c in cols.items():
            print(f"{prefix}  {name}: program check {'FAILED (the run ended early)' if c['early'] else 'ok'}, "
                  f"run {'sound' if c['sound'] else 'NOT SOUND'}", flush=True)
        if line == 1:
            if not any(c["early"] for c in cols.values()):
                break
            print("CPI D ROW MARKED: the program's own check ended a run early at TICK=10000; run once more with the "
                  "automatic tick in every column (second line, lines prefixed 'CPI D AUTO')", flush=True)
        if line == 2 and any(c["early"] for c in cols.values()):
            print("CPI D ROW: a run with the automatic tick ended early as well", flush=True)
            rows["failed"] = True
    with open(os.path.join(a.dir, "row.json"), "w") as f:
        json.dump(rows, f, indent=1)
    sound = all(rows[k][c]["sound"] for k in (1, 2) if k in rows for c in columns)
    return 0 if sound and not rows.get("failed") else 1


def cpi_d_judge(job, rc, out, d):
    """A CPI row with a data cache: as cpi_judge, and the row's lines (the CPI of every column, the store stall share and the
    model's buffered CPI) recorded."""
    verdict, notes = exit_judge(job, rc, out, d)
    notes = [n for n in notes if not n.startswith("last line")]
    for l in out.splitlines():
        if l.startswith("CPI D "):
            notes.append(f"{l[:260]} (recorded)")
    if not any(n.startswith("CPI D ROW") for n in notes):
        notes.append("no CPI D ROW line")
    return ("PASS" if verdict == "PASS" and not [n for n in notes if "recorded" not in n] else "FAIL"), notes


def cpi_d_jobs():
    """The rows of 6.8 with both caches: minimal, stress, mzba (rv32i and rv32im_zba), full and the scripted shell session at
    BPRED 0 and 3 (memory seed 1; seed 2 for minimal and stress), at the write latency 1:4 with all columns (the leg
    d-cpi) and at 4:8 and 8:24 with the PD column and the model (the leg d-cpi-wr)."""
    base, wr = [], []
    rows = [(a_, e_, 1) for a_, e_ in (("minimal", []), ("stress", []), ("mzba", []), ("mzba", ["MARCH=rv32im_zba"]),
                                       ("full", []), ("shell", []))] + [(a_, [], 2) for a_ in ("minimal", "stress")]
    for app, extra, seed in rows:
        for b in (0, 3):
            nm = f"{app}{'-zba' if extra else ''}-bpred{b}" + ("-seed2" if seed == 2 else "")
            vars_ = extra + (["MEM_SEED=2"] if seed == 2 else [])
            for wrname in ("dram", "dram-wr48", "dram-wr824"):
                full = wrname == "dram"
                job = Job("d-cpi" if full else "d-cpi-wr", f"{nm}-{wrname}" if not full else nm, "i8k-d4k", wrname,
                          (lambda nm, app, b, seed, vars_, wrname, full: lambda d: [
                              sys.executable, os.path.abspath(__file__), "_cpirow_d", "--dir", d, "--app", app, "--bpred", str(b),
                              "--seed", str(seed), "--name", nm, "--wr", wrname, "--columns", "all" if full else "pd", "--"] + vars_)(
                              nm, app, b, seed, vars_, wrname, full),
                          cpi_d_judge, (1e8 if app == "full" else 5e7) * (3 if full else 1), cpus="dut", lock=("trace", app),
                          extra_vars=vars_)
                (base if full else wr).append(job)
    return base, wr


# ------------------------------------------------------------------------------ the legs
def base_legs(SMALL, LARGE, d_):
    """The legs of the matrix for the small and the large configuration (d_: both are pairs of an instruction and
    a data cache)."""
    L = {}
    LINES = tuple(f"{SMALL}-line{n}" for n in (8, 32, 64))
    DIRECTED = "memsys/(irqchain|fetchredirect|icoherence|stores" + ("|dcache|dcoherence" if d_ else "") + ")$"
    SMOKE = ("memsys/(stores|dcache|dcoherence|fetchredirect|icoherence|hpmwait|hpmcache)$|asm/(ops|fencei|hpm)$" if d_ else
             "memsys/(stores|fetchredirect|icoherence|irqchain)$|asm/(ops|fencei)$")
    L["smoke"] = [programs_job("smoke", SMALL, p, only=SMOKE,
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
                                           only=DIRECTED, cpus="dut",
                                           sim_args="+ram_words=0x46000,0x46004 +cache_stats_marks", judge=coverage_judge)
                              for c in (SMALL, LARGE)]
    if not d_:
        L["directed-coverage"].append(programs_job("directed-coverage", "i16k", "lat2", only="memsys/irqchain$", cpus="dut",
                                                   sim_args="+ram_words=0x46000,0x46004", judge=positions_confirm_judge,
                                                   name="i16k-lat2-irqchain-positions"))
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
                                    only="memsys/(fetchredirect|icoherence|irqchain|stores" + ("|dcache|dcoherence" if d_ else "") +
                                         ")$|asm/(fencei|ops)$")
                       for c in LINES] + \
                      [freertos_job("line-sizes", "minimal", c, "lat2", compare=False) for c in LINES]
    L["resets"] = [resets_job("resets", SMALL, "lat2"), resets_job("resets", SMALL, "rand1"),
                   resets_job("resets", "standard", "lat2")]
    mini = resets_job("resets", SMALL, "lat2", progs=())
    mini.name, mini.lock = f"freertos-minimal-{cname(SMALL, 'lat2')}", (SMALL, "lat2", "minimal")
    mini.cmd = lambda d: [sys.executable, os.path.abspath(__file__), "_resets", "--dir", d, "--cached", "1",
                          "--dcached", str(int(d_)), "--app", "minimal", "--"] + config(SMALL, "lat2")
    mini.judge = resets_judge_factory(True, minimum=1, dcached=d_)
    L["resets"].append(mini)
    L["model-agreement"] = [model_job("model-agreement", SMALL, "lat2", step4=True),
                            model_job("model-agreement", LARGE, "lat2", step4=True),
                            model_job("model-agreement", SMALL, "lat2", burst=True),
                            model_job("model-agreement", LARGE, "lat2", burst=True)]
    cpi = []
    # the rows of 6.8: minimal, stress, mzba (rv32i and rv32im_zba), full and the scripted shell session, at
    # BPRED 0 and 3, memory seed 1; memory seed 2 as the variance check for minimal and stress
    for app, extra, seed in [(a_, e_, 1) for a_, e_ in (("minimal", []), ("stress", []), ("mzba", []),
                                                         ("mzba", ["MARCH=rv32im_zba"]), ("full", []), ("shell", []))] + \
                            [(a_, [], 2) for a_ in ("minimal", "stress")]:
        for b in (0, 3):
            nm = f"{app}{'-zba' if extra else ''}-bpred{b}" + ("-seed2" if seed == 2 else "")
            vars_ = extra + (["MEM_SEED=2"] if seed == 2 else [])
            cpi.append(Job("cpi", nm, LARGE, "dram",
                           (lambda nm, app, b, seed, vars_: lambda d: [
                               sys.executable, os.path.abspath(__file__), "_cpirow", "--dir", d, "--app", app,
                               "--bpred", str(b), "--seed", str(seed), "--name", nm, "--"] + vars_)(nm, app, b, seed, vars_),
                           cpi_judge, 1e8 if app == "full" else 5e7, cpus="dut", lock=("trace", app),
                           extra_vars=vars_))
    L["cpi"] = cpi
    L["irq-latency-freertos"] = [
        Job("irq-latency-freertos", f"stress-{cname(c, p)}", c, p,
            (lambda c, p: lambda d: [sys.executable, os.path.abspath(__file__), "_irqlat_frtos", "--dir", d, "--app", "stress",
                                     "--"] + config(c, p))(c, p),
            irqlat_frtos_judge, 1e8, cpus="dut", lock=("irqlat", cname(c, p)), needs_cache=c != "standard")
        for c, p in ((SMALL, "lat2"), (LARGE, "dram"), ("standard", "dram-nobursts"))]
    L["irq-latency"] = [programs_job("irq-latency", c, p, only="asm/uartirq$|memsys/irqchain$", cpus="dut",
                                     sim_args="+irq_latency", judge=lambda j, rc, out, d: exit_judge(j, rc, out, d))
                        for c, p in ((SMALL, "stress"), (LARGE, "dram"))]
    L["irq-latency-validation"] = [irqlat_job(p) for p in ("std", "lat1", "lat2", "lat5")]
    if d_:
        # the uncached jobs and the earlier CPI rows (the cache-free configurations do not depend on a data cache;
        # the CPI rows with both caches are the legs 'd-cpi*')
        for name in list(L):
            L[name] = [j for j in L[name] if j.cache != "standard"]
            if not L[name] or name in ("cpi", "irq-latency-validation"):
                del L[name]
    return L


def legs():
    L = base_legs("i512", "i8k", False)
    for name, jobs in base_legs("i512-d512", "i8k-d4k", True).items():
        L["d-" + name] = jobs
    SMALL, LARGE = "i512-d512", "i8k-d4k"
    # the counter programs and the data-cache programs, with the header minima of the latter
    hpm_only = "asm/hpm$|memsys/(hpmcache|hpmwait|hpmdcache)$"
    d_hpm = [programs_job("d-hpm", SMALL, p, only=hpm_only, cpus="dut") for p in ("lat0", "lat2", "rand1", "burst", "stress")] + \
            [programs_job("d-hpm", LARGE, p, only=hpm_only, cpus="dut") for p in ("lat2", "dram")]
    d_hpm += [programs_job("d-hpm", c, p, only="memsys/(dcache|dcoherence)$", cpus="dut,golden", judge=dcache_coverage_judge,
                           name=f"dcache-{cname(c, p)}")
              for c, ps in ((SMALL, ("lat0", "lat2", "rand1", "burst", "stress")), (LARGE, ("lat2", "dram"))) for p in ps]
    L["d-hpm"] = d_hpm
    # the counter presets H and I with both caches (HPM_CHECK ok and HPM_CACHE_COMPARE ok in the logs)
    L["d-hpm-freertos"] = [freertos_job("d-hpm-freertos", "minimal", SMALL, "lat2", extra=[f"HPM_PRESET={x}"],
                                        name=f"minimal-{cname(SMALL, 'lat2')}-preset{x}")
                           for x in ("H", "I")] + \
                          [freertos_job("d-hpm-freertos", "stress", SMALL, "lat2", extra=[f"HPM_PRESET={x}"],
                                        name=f"stress-{cname(SMALL, 'lat2')}-preset{x}") for x in ("H", "I")]
    for j in L["d-hpm-freertos"]:
        j.judge = hpm_preset_judge
    # the coherence tests again with both caches: icoherence (unchanged), dcoherence, fencei, fencerd, the trap sweep's
    # ctl family and the self-modifying FreeRTOS programs (brk with BRK_FENCEI, the loader's selfmod) 
    coh = "memsys/(icoherence|dcoherence)$|asm/(fencei|fencerd)$"
    L["d-coherence"] = [programs_job("d-coherence", c, p, only=coh) for c, ps in ((SMALL, ("lat0", "lat2", "rand1")),
                                                                                 (LARGE, ("lat2",))) for p in ps] + \
                       [sweep_job("d-coherence", c, p, fam="ctl") for c, p in ((SMALL, "lat0"), (SMALL, "lat2"), (SMALL, "rand1"),
                                                                              (LARGE, "lat2"))]
    for j in L["d-coherence"]:
        if j.cmd.__qualname__.startswith("sweep_job"):          # the sweep's jobs share the programs' configuration names
            j.name = f"ctl-{j.name}"
    # regression: the instruction-cache-only configurations against an earlier revision (REGRESSION_BASE=<revision>)
    L["i-only-regression"] = [regression_job("i512", "lat0"), regression_job("i512", "lat2"), regression_job("i8k", "lat2")]
    # 6.8: the store stall of the data cache without a write buffer, and what the model says a buffer would save
    L["d-cpi"], L["d-cpi-wr"] = cpi_d_jobs()
    for name, jobs in L.items():
        for j in jobs:
            j.leg = name
            j.id = f"{name}/{j.name}"
    ids = [j.id for jobs in L.values() for j in jobs]
    dup = sorted({i for i in ids if ids.count(i) > 1})
    assert not dup, f"matrix.py: job names used twice: {', '.join(dup)}"
    return L


# ------------------------------------------------------------------------------ helpers run as jobs
class build_lock:
    """Builds of simulators and programs from several jobs of one matrix run never overlap in time (the
    jobs share build directories: a simulator of one configuration is used by several of them)."""
    path = os.path.join(REPO, "build", ".matrix-build.lock")

    def __enter__(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        self.f = open(self.path, "w")
        fcntl.flock(self.f, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.f, fcntl.LOCK_UN)
        self.f.close()


def run_programs(vars_, progs, sim_args=(), cpu="dut"):
    """Build a configuration's simulator and programs; -> (simulator, {program: directory})."""
    env = clean_env()
    bdir, text = build_dir(vars_)
    model = {"dut": "dut", "golden": "ref"}[cpu]
    # the goals in the spelling of make's own BUILD_DIR: absolute for a configuration's directory
    # (cfg-<name>), 'build' for the standard one; any other spelling names no rule
    raw = re.search(r"build directory:\s+(\S+)", text).group(1)
    with build_lock():
        subprocess.run(make_cmd(["frtos-model", f"FRTOS_CPU={model}", "FRTOS_RAM_KB=32"], vars_), check=True, env=env,
                       stdout=subprocess.DEVNULL)
        subprocess.run(make_cmd([os.path.join(raw, "test", p, "init.mem") for p in progs], vars_),
                       check=True, env=env, stdout=subprocess.DEVNULL)
    return os.path.join(bdir, "frtos-model", f"{model}-32k", "top"), {p: os.path.join(bdir, "test", p) for p in progs}


def frtos_direct(app, vars_, plusargs, d):
    """Build a FreeRTOS program and run its simulator directly with further run options (the make
    targets run it through run.sh, which takes none): the command of 'make -n frtos-run', run in the
    program's directory with the options appended; the output also goes to <d>/sim.log."""
    env = clean_env()
    with build_lock():
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
    dcached = a.dcached == "1"
    allres = []
    if a.app:
        # a FreeRTOS program: the phase log of one run, then one run per placed reset
        d = os.path.join(a.dir, a.app)
        os.makedirs(d, exist_ok=True)          # the phase log is opened in it before frtos_direct writes there
        frtos_direct(a.app, vars_, ["+cache_phase_log=" + os.path.join(d, "phase.bin")], d)
        _, rundir, sim, args = frtos_direct(a.app, vars_, [], os.path.join(d, "base"))
        for name, cyc in place_resets(os.path.join(d, "phase.bin"), cached, dcached):
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
        _, res = reset_runs(None, os.path.join(a.dir, prog.replace("/", "-")), sim, pd, prog, cached, 10_000_000, dcached)
        allres += res
    with open(os.path.join(a.dir, "resets.json"), "w") as f:
        json.dump(allres, f, indent=1)
    for r in allres:
        print(f"RESET RUN {r['program']} at {r['cycle']} ({r['wanted']}): {r['reset_line']}"
              f"{'' if r['placed'] else ' (not where it was placed)'}; {'; '.join(r['problems']) or 'ok'}")
    return 0


def retired_pcs(path):
    """The PCs of the retired instructions of a bus trace (BUSTRACE=1: 16-byte records; word 1 bit 12: an
    instruction retires, word 3: the PC of the instruction in Writeback)."""
    import numpy as np
    rec = np.fromfile(path, dtype="<u4")
    rec = rec[:len(rec) // 4 * 4].reshape(-1, 4)
    return rec[(rec[:, 1] >> 12) & 1 == 1, 3]


def model_prep(binfile, outdir, ram_kb, name):
    subprocess.run([sys.executable, os.path.join(HERE, "cachemodel.py"), "prep", binfile, outdir, "--ram-kb",
                    str(ram_kb), "--name", name], check=True, stdout=subprocess.DEVNULL)


def model_run(prepared, args, out, seed=1, w1=None):
    """cachemodel.py run on a prepared trace -> the model's JSON result (one configuration)."""
    cmd = [sys.executable, os.path.join(HERE, "cachemodel.py"), "run", prepared] + args + ["--seed", str(seed),
                                                                                           "--out", out]
    if w1 is not None:
        cmd += ["--w1", str(w1)]
    if os.path.exists(out):
        os.remove(out)
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)
    with open(out) as f:
        return json.loads(f.readline())


def ram_kb_of(text):
    """The RAM size in KiB from the scoreboard's 'SCOREBOARD on' line of a log."""
    m = re.search(r"SCOREBOARD on: .* addresses 0x([0-9a-f]+)-0x([0-9a-f]+)", text)
    return (int(m.group(2), 16) - int(m.group(1), 16) + 1) // 1024 if m else 32


def model_step4(a, vars_):
    """6.7 step 4, informative: the FreeRTOS program a.app in the cached configuration (the automatic tick),
    its I-MPKI from the RTL's CACHE_STATS and RETIRED lines, and the model's on the trace of the same program
    at the standard memory with the same TICK; the expected agreement is 10% of the model's value or 0.2
    MPKI, whichever is larger. It does not gate."""
    d = os.path.join(a.dir, "step4")
    r, _, _, _ = frtos_direct(a.app, vars_ + ["BPRED=0"], [], os.path.join(d, "cached"))
    text = r.stdout
    st, ret = stats_of(text), re.search(r"^RETIRED cycles=(\d+) instructions=(\d+)", text, re.M)
    tick = re.search(r"config: tick=(\d+)cyc", text)
    cm = re.search(r"^CACHE I-cache (\d+) bytes, (\d+)-byte lines", text, re.M)
    sm = re.search(r"^SLOW MEMORY memory port: read latency ([^,\s]+), write latency ([^,\s]+)", text, re.M)
    if not (st and ret and tick and cm and sm):
        print(f"STEP4 {a.app}: cannot read the cached run (CACHE_STATS, RETIRED, tick, configuration)")
        return 1
    rtl = st["i_done"] * 1000.0 / int(ret.group(2))
    dm = re.search(r"^CACHE D-cache (\d+) bytes", text, re.M)       # with a data cache the model has one as well
    dsize = dm.group(1) if dm else "0"
    tdir = os.path.join(d, "trace")
    os.makedirs(tdir, exist_ok=True)
    binfile = os.path.join(tdir, "bustrace.bin")
    frtos_direct(a.app, ["BUSTRACE=1", f"TICK={tick.group(1)}", "BPRED=0"], ["+bustrace=" + binfile], tdir)
    model_prep(binfile, os.path.join(tdir, "prepared"), ram_kb_of(text), a.app)
    os.remove(binfile)
    lat = lambda t: t.replace("..", ":")
    res = model_run(os.path.join(tdir, "prepared"),
                    ["--isize", cm.group(1), "--dsize", dsize, "--line", cm.group(2), "--mem", "beat",
                     "--rd-lat", lat(sm.group(1)), "--wr-lat", lat(sm.group(2))], os.path.join(tdir, "model.jsonl"))
    mod = res["i_mpki"]
    tol = max(0.1 * mod, 0.2)
    dtext = ""
    if dm:
        rtl_d = st["dc_load_misses"] * 1000.0 / int(ret.group(2))
        mod_d = res["d_mpki"]
        dtext = (f"; RTL D-MPKI {rtl_d:.3f} (dc_load_misses {st['dc_load_misses']}), model D-MPKI {mod_d:.3f}, "
                 f"{'WITHIN' if abs(rtl_d - mod_d) <= max(0.1 * mod_d, 0.2) else 'BEYOND'}")
    print(f"STEP4 {a.app} (tick {tick.group(1)}): RTL I-MPKI {rtl:.3f} (i_done {st['i_done']}, {ret.group(2)} "
          f"retired instructions), model I-MPKI {mod:.3f} ({res['instructions']} instructions of the standard-memory "
          f"trace); expected agreement +-{tol:.3f}: {'WITHIN' if abs(rtl - mod) <= tol else 'BEYOND'} "
          f"(informative; the two runs execute different program phases)" + dtext)
    return 0


def helper_model(a, vars_):
    """Model agreement: 6.7 step 0 (the retired instructions' PCs of each program at the standard memory and
    at MEM_LAT=2, uncached, must be the same sequence), the trace of each program at the standard memory
    (BUSTRACE=1), its cached run, and cachemodel.py rtlcheck (steps 1 to 3 and 5); with --app, step 4."""
    progs = a.programs.split(",")
    tsim, tdirs = run_programs(["BUSTRACE=1"], progs)
    csim, cdirs = run_programs(vars_, progs)
    t2sim, t2dirs = run_programs(["BUSTRACE=1", "MEM_LAT=2"], progs)
    rc = 0
    for p in progs:
        d = os.path.join(a.dir, p.replace("/", "-"))
        for sub in ("trace", "trace-lat2", "cached"):
            os.makedirs(os.path.join(d, sub), exist_ok=True)
        shutil.copy(os.path.join(tdirs[p], "init.mem"), os.path.join(d, "trace"))
        shutil.copy(os.path.join(t2dirs[p], "init.mem"), os.path.join(d, "trace-lat2"))
        shutil.copy(os.path.join(cdirs[p], "init.mem"), os.path.join(d, "cached"))
        subprocess.run([tsim, "+nodump"], cwd=os.path.join(d, "trace"), capture_output=True)
        subprocess.run([t2sim, "+nodump", "+timeout=20000000"], cwd=os.path.join(d, "trace-lat2"), capture_output=True)
        a0, a2 = retired_pcs(os.path.join(d, "trace", "bustrace.bin")), retired_pcs(os.path.join(d, "trace-lat2", "bustrace.bin"))
        same = len(a0) == len(a2) and bool((a0 == a2).all())
        print(f"TIMING {p}: {'SAME' if same else 'DIFFERENT'} sequence of retired PCs at the standard memory "
              f"({len(a0)} instructions) and at MEM_LAT=2 uncached ({len(a2)})")
        os.remove(os.path.join(d, "trace-lat2", "bustrace.bin"))
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
    if a.app:
        rc |= model_step4(a, vars_)
    return rc


def helper_benches(a, vars_):
    # every bench of test/sv, or those named by --programs; test_example.sv is the template of the
    # original repository, which does not build in any configuration (the standard one included)
    names = sorted(f[:-3] for f in os.listdir(os.path.join(REPO, "test", "sv"))
                   if f.endswith(".sv") and f != "test_example.sv")
    if a.programs:
        names = [n for n in names if n in a.programs.split(",")]
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


def unsplit(text):
    """A program's own output with the testbench's RETIRED_AT lines taken out: they are printed without a
    line break and can stand inside a line of the program's text ('FRTOS-R<RETIRED_AT ...>ESULT: FAIL')."""
    return re.sub(r"RETIRED_AT instructions=\d+ cycles=\d+\n?", "", text)


def column_run(app, vars_, d, extra, bpred):
    """One simulated column of a CPI row (the cached or the uncached baseline configuration): the figures of
    its RETIRED_AT marks, its RETIRED and CACHE_STATS lines, whether the program's own check ended the run
    early (FRTOS-RESULT: FAIL), and whether the run itself is sound (scoreboard PASS, no simulator error).
    The shell session is the scripted session (session.txt) of make freertos-shell-test."""
    os.makedirs(d, exist_ok=True)
    if app == "shell":
        r = subprocess.run(make_cmd(["freertos-shell-test", "APP=shell", "APP_CONSOLE_ARGS=+retired_every=100000"],
                                    vars_ + extra + [f"BPRED={bpred}"]), capture_output=True, text=True,
                           env=clean_env(), errors="replace")
        bdir, _ = build_dir(vars_ + extra)
        text = read(os.path.join(bdir, "test", "freertos", "shell", "session-dut.log"))
        shutil.copy(os.path.join(bdir, "test", "freertos", "shell", "session-dut.log"), os.path.join(d, "sim.log")) \
            if text else None
        ok_result = "FREERTOS SHELL RESULT: PASS" in r.stdout
        early = "FREERTOS SHELL RESULT: FAIL" in r.stdout
    else:
        window = ["TIMEOUT=10000000"] if app == "full" else []
        r, _, _, _ = frtos_direct(app, vars_ + extra + window + [f"BPRED={bpred}"], ["+retired_every=100000"], d)
        text = r.stdout
        early = "FRTOS-RESULT: FAIL" in unsplit(text)
        ok_result = "FRTOS-RESULT: PASS" in unsplit(text) or app == "full"
    fig = dict(marks={int(i): int(c) for i, c in re.findall(r"RETIRED_AT instructions=(\d+) cycles=(\d+)", text)})
    m = re.search(r"^RETIRED cycles=(\d+) instructions=(\d+)", text, re.M)
    fig["cycles"], fig["instructions"] = (int(m.group(1)), int(m.group(2))) if m else (None, None)
    fig["stats"] = stats_of(text)
    fig["early"] = early
    fig["result_ok"] = ok_result
    fig["sound"] = "SCOREBOARD: PASS" in text and not re.search(r"%(Fatal|Error)", text)
    fig["tick"] = (re.search(r"config: tick=(\d+)cyc", text) or [None, None])[1]
    fig["ram_kb"] = ram_kb_of(text)
    return fig


def cpi_at(fig, mark):
    return fig["marks"][mark] / mark


def cpi_lines(prefix, name, cached, base, model, mark):
    """The table of one line of a row; -> list of text lines."""
    out = []
    head = f"{prefix}ROW {name}"
    if mark is None:
        out.append(f"{head}: no RETIRED_AT mark reached by both columns; whole runs: cached CPI "
                   f"{cached['cycles'] / cached['instructions']:.3f}, baseline CPI {base['cycles'] / base['instructions']:.3f}")
        return out
    out.append(f"{head}: compared over the first {mark} retired instructions (the largest RETIRED_AT mark of both columns)")
    for col, f in (("cached  ", cached), ("baseline", base)):
        tick = f" tick {f['tick']}" if f.get("tick") else ""
        out.append(f"{prefix}  {col} cycles {f['marks'][mark]:>10}  instructions {mark:>8}  CPI {cpi_at(f, mark):.3f}"
                   f"   (whole run: {f['cycles']} cycles, {f['instructions']} instructions{tick})")
    if model:
        out.append(f"{prefix}  model    cycles {model['cycles']:>10}  instructions {model['instructions']:>8}  "
                   f"CPI {model['cpi']:.3f}   (I-MPKI {model['i_mpki']:.2f}; trace window of {model['window_cycles']} cycles; "
                   f"no cache: CPI {model['cpi_base']:.3f})")
    else:
        out.append(f"{prefix}  model    not applicable (its traces are the runs at TICK=10000)")
    st, n = cached["stats"], cached["instructions"]
    if st:
        out.append(f"{prefix}  CACHE_STATS of the cached run: i_done {st['i_done']}  I-MPKI {1000.0 * st['i_done'] / n:.2f}  "
                   f"wait_i_for_port {st['wait_i_for_port']}  wait_d_for_port {st['wait_d_for_port']}  "
                   f"port_irefill {st['port_irefill']}  port_data {st['port_data']}")
        cyc = cached["cycles"]
        wd, wi = st["wait_d_for_port"], st["wait_i_for_port"]
        delta = cpi_at(cached, mark) - cpi_at(base, mark)
        out.append(f"{prefix}  port sharing: data accesses waiting behind I-refills (wait_d_for_port) {wd} cycles = "
                   f"{100.0 * wd / cyc:.2f}% of all cycles = {wd / n:.4f} per instruction; I-refills waiting behind data "
                   f"transfers (wait_i_for_port) {wi} cycles = {100.0 * wi / cyc:.2f}% = {wi / n:.4f} per instruction")
        out.append(f"{prefix}  CPI change cached - baseline {delta:+.3f}: port sharing costs {(wd + wi) / n:.3f} cycles per "
                   f"instruction (wait_d_for_port + wait_i_for_port, whole run), the rest, {delta - (wd + wi) / n:+.3f}, is "
                   f"attributed to the cache")
    return out


def model_for_row(app, bpred, d, vars_extra, mem_seed, mark, ram_kb, window):
    """The model's CPI on the trace of the same program at the standard memory (TICK=10000, the row's BPRED),
    over the window that ends where the trace has retired `mark` instructions."""
    import numpy as np
    tdir = os.path.join(d, "trace")
    os.makedirs(tdir, exist_ok=True)
    binfile = os.path.join(tdir, "bustrace.bin")
    vars_extra = [v for v in vars_extra if not v.startswith("MEM_")]       # the trace is at the standard memory
    if app == "shell":
        subprocess.run(make_cmd(["freertos-shell-test", "APP=shell", f"APP_CONSOLE_ARGS=+bustrace={binfile}"],
                                ["BUSTRACE=1", "TICK=10000", f"BPRED={bpred}"] + vars_extra), capture_output=True,
                       text=True, env=clean_env())
    else:
        frtos_direct(app, ["BUSTRACE=1", "TICK=10000", f"BPRED={bpred}"] + vars_extra + window, ["+bustrace=" + binfile], tdir)
    if not os.path.exists(binfile):
        return None
    prepared = os.path.join(tdir, "prepared")
    model_prep(binfile, prepared, ram_kb, app)
    os.remove(binfile)
    code = np.load(os.path.join(prepared, "code.npy"), mmap_mode="r")
    retired = np.cumsum((np.asarray(code) >> 5) & 1)
    if mark is None or retired[-1] < mark:
        return None
    w1 = int(np.searchsorted(retired, mark)) + 1
    res = model_run(prepared, ["--isize", "8192", "--dsize", "0", "--line", "16", "--mem", "burst", "--beat-cycles", "1",
                               "--rd-lat", "8:24", "--wr-lat", "1:4"], os.path.join(tdir, "model.jsonl"),
                    seed=mem_seed, w1=w1)
    return dict(cycles=res["cycles"], instructions=res["instructions"], cpi=res["cpi"], cpi_base=res["cpi_base"],
                i_mpki=res["i_mpki"], window_cycles=w1)


def helper_cpirow(a, vars_):
    """One row of the CPI measurement (6.8): the program in the cached configuration (P x GD) and in the
    uncached baseline, at TICK=10000 (as the model's traces), the row's branch-predictor mode, and
    +retired_every=100000; `full` runs a fixed window of 10 M cycles. The columns are compared at the
    largest RETIRED_AT mark that both reached (CPI = cycles at the mark / instructions), the model on the
    trace of the same program over the same number of retired instructions. A program whose own real-time
    check ends a column early (FRTOS-RESULT: FAIL) marks the row, which is run once more with the
    automatic tick in both columns (F = 18 and F = 17): the second line, with the prefix AUTO. The variables
    after '--' are the row's (MARCH=..., MEM_SEED=...); `vars_` here is the row's own extra options."""
    seed = int(a.seed)
    extra = list(vars_)
    cached_vars, base_vars = config("i8k", "dram"), config("standard", "dram-nobursts")
    rows = {}
    for line, prefix, tick in ((1, "CPI ", ["TICK=10000"]), (2, "CPI AUTO ", [])):
        cols = {}
        for name, cv in (("cached", cached_vars), ("baseline", base_vars)):
            cols[name] = column_run(a.app, cv, os.path.join(a.dir, f"line{line}-{name}"), extra + tick, a.bpred)
        marks = sorted(set(cols["cached"]["marks"]) & set(cols["baseline"]["marks"]))
        mark = marks[-1] if marks else None
        model = None
        if line == 1:
            window = ["TIMEOUT=10000000"] if a.app == "full" else []
            model = model_for_row(a.app, a.bpred, a.dir, extra, seed, mark, cols["cached"]["ram_kb"], window)
        for l in cpi_lines(prefix, a.name, cols["cached"], cols["baseline"], model, mark):
            print(l, flush=True)
        rows[line] = dict(mark=mark, model=model, cached={k: v for k, v in cols["cached"].items() if k != "marks"},
                          baseline={k: v for k, v in cols["baseline"].items() if k != "marks"})
        for name in ("cached", "baseline"):
            c = cols[name]
            print(f"{prefix}  {name}: program check {'FAILED (the run ended early)' if c['early'] else 'ok'}, "
                  f"run {'sound' if c['sound'] else 'NOT SOUND'}", flush=True)
        if line == 1:
            if not (cols["cached"]["early"] or cols["baseline"]["early"]):
                break
            print("CPI ROW MARKED: the program's own check ended a run early at TICK=10000; run once more with the "
                  "automatic tick in both columns (second line, lines prefixed 'CPI AUTO')", flush=True)
        if line == 2 and (cols["cached"]["early"] or cols["baseline"]["early"]):
            print("CPI ROW: a run with the automatic tick ended early as well", flush=True)
            rows["failed"] = True
    with open(os.path.join(a.dir, "row.json"), "w") as f:
        json.dump(rows, f, indent=1)
    sound = all(rows[k][c]["sound"] for k in (1, 2) if k in rows for c in ("cached", "baseline"))
    return 0 if sound and not rows.get("failed") else 1


def helper_irqlat_frtos(a, vars_):
    """+irq_latency in a FreeRTOS program (the automatic tick of the configuration): the IRQLAT line, the tick
    and the program's verdict."""
    r, _, _, _ = frtos_direct(a.app, vars_, ["+irq_latency"], a.dir)
    text = r.stdout
    print(f"IRQ-LATENCY {a.app}: " + " ".join(vars_ or ["(standard)"]))
    for pat in (r"config: tick=\d+cyc", r"^IRQLAT .*$", r"^RETIRED .*$"):
        m = re.search(pat, text, re.M)
        print(m.group(0) if m else f"(no line for {pat})")
    print("FRTOS-RESULT: " + ("PASS" if "FRTOS-RESULT: PASS" in unsplit(text) else "NOT PASS"))
    print("SCOREBOARD: " + ("PASS" if "SCOREBOARD: PASS" in text else "NOT PASS"))
    return 0


def irqlat_frtos_judge(job, rc, out, d):
    """+irq_latency in FreeRTOS stress: a sound, passing run with an IRQLAT line whose maximum is below the tick
    (the figures are the observed maximum of this run, not a bound)."""
    notes = logs_problems(d)
    if rc:
        notes.append(f"exit status {rc}")
    tick = re.search(r"config: tick=(\d+)cyc", out)
    lat = re.search(r"^IRQLAT interrupts=(\d+) max=(\d+) mean=([0-9.]+)", out, re.M)
    if not tick or not lat:
        notes.append("no tick or no IRQLAT line")
    else:
        n, mx, mean, t = int(lat.group(1)), int(lat.group(2)), lat.group(3), int(tick.group(1))
        notes.append(f"IRQLAT interrupts={n} max={mx} mean={mean} against the tick {t}: max = {100.0 * mx / t:.2f}% of the tick (recorded)")
        if n == 0:
            notes.append("no interrupt measured")
        if mx >= t:
            notes.append(f"the maximum latency {mx} is not below the tick {t}")
    if "FRTOS-RESULT: PASS" not in out:
        notes.append("the program did not pass")
    if "SCOREBOARD: PASS" not in out:
        notes.append("no SCOREBOARD: PASS")
    return ("PASS" if not [n for n in notes if "recorded" not in n] else "FAIL"), notes


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
           "_timing_benches": helper_timing_benches, "_cached_vs_golden": helper_cached_vs_golden, "_cpirow": helper_cpirow,
           "_cpirow_d": helper_cpirow_d, "_irqlat_frtos": helper_irqlat_frtos, "_lint": helper_lint,
           "_regression": helper_regression}


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
            print(f"  would run {j.id}\n      {shlex.join(j.cmd(os.path.join(out, 'jobs', j.id.replace('/', '--'))))}")
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
        ap.add_argument("--dcached", default="0")
        ap.add_argument("--base", default="")
        ap.add_argument("--wr", default="dram")
        ap.add_argument("--columns", default="all")
        ap.add_argument("--app", default="")
        ap.add_argument("--bpred", default="0")
        ap.add_argument("--seed", default="1")
        ap.add_argument("--name", default="")
        # the make variables follow a '--': split there, since argparse (3.12) does not accept a '--'
        # between an option and a positional list
        argv = sys.argv[1:]
        k = argv.index("--") if "--" in argv else len(argv)
        a = ap.parse_args(argv[:k])
        return HELPERS[a.helper](a, argv[k + 1:])
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
