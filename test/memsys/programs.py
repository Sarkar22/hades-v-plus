#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""programs.py -- run the assembly and C test programs on both CPUs in one simulator
configuration, and compare the runs of two configurations.

The make targets test/asm/<name>, test/c/<name> and test/memsys/<name> (the assembly
programs of this directory) run one program on HaDes-V+ only. This script runs all of them, on HaDes-V+ (dut) and on the golden CPU, with the
full-system simulators of a simulator configuration (the Makefile's MEM_LAT=...,
SCOREBOARD=1, BUSHASH=1, ...; see `make help`), e.g.

    python3 test/memsys/programs.py run MEM_LAT=2
    python3 test/memsys/programs.py run MEM_LAT=1:8 MEM_SEED=2
    python3 test/memsys/programs.py run MEM_LAT=0 BUSHASH=1
    python3 test/memsys/programs.py compare <run dir A> <run dir B>

run: builds the simulators (make frtos-model FRTOS_CPU=dut|ref FRTOS_RAM_KB=32 with the
     given options) and the programs, runs every program on every CPU (--jobs at a time,
     each in its own directory under --out, default <configuration's build dir>/programs),
     and prints one line per run: the number of "Test pass!" and "Test fail!" lines, the
     cycles after reset (when the simulator prints a RETIRED or BUSHASH line), the
     scoreboard's verdict, the judgement (below) and the testbench's verdict line (or
     "Simulation timeout!").
     With a slow memory, every program also runs at latency 0 in the same simulator
     (+mem_lat=0, in <out>/latency0), and each run is judged against that run of the same
     program on the same CPU: it must give the same reports ("Test pass!" and "Test fail!",
     in order), reach the verdict as that run did, and print the same output, apart from
     the differences that WAIT_STATES below lists, each with its reason: checks that
     measure the timing of a single-cycle memory. Some of them apply only to some latency
     profiles (see TIMING below); the run prints the profile it judged by. A run is "same",
     "expected" (it differs only as listed) or "DIFFERS". The golden CPU's runs are judged
     the same way but only recorded: it is a frozen model with known deviations
     (docs/VERIFICATION.md).
     A run is also counted as bad when its scoreboard reports a mismatch, its simulator
     stops with an error, or its simulator returns a non-zero status without a verdict line
     (that run or its latency-0 run), and when a HaDes-V+ run at latency 0 (the latency-0
     runs above, and every run of a configuration without wait states) does not end with
     the verdict its program gives on the standard memory (VERDICT_AT_LATENCY0): judging
     against latency 0 compares with that run, so it must be right.
     With a slow memory the scoreboard must be on (the default): a fault of the memory path
     that is present at every latency gives the same wrong result at latency 0, and only
     the scoreboard sees it. The run refuses to start when SCOREBOARD=0 or +noscoreboard
     turns it off, unless --allow-no-scoreboard is given (then it warns).
     Exit status 1 when a HaDes-V+ run DIFFERS or any run is bad, else 0. Without a slow
     memory (or with --no-judge) the verdicts are printed, not judged: some programs end
     without the "initial test" marker (docs/VERIFICATION.md, "The Testbench's Verdict
     Line"), and the golden CPU cannot run the M, Zba, Zicntr and branch-predictor programs.
compare: for every program and CPU in both run directories, the simulator output must be
     the same apart from the lines of the configuration (SLOW MEMORY ...), the checkers
     (SCOREBOARD ..., BUSHASH ..., RETIRED ...) and the simulator's own run-time report,
     and where both runs printed a bus hash, the hashes must be equal (a bus hash that only
     one of the runs printed is not compared; such runs are counted separately). Comparing
     the standard configuration with a slow memory at latency 0 (MEM_LAT=0 BUSHASH=1, and
     the standard runs with --sim-args +bushash) shows that the slow-memory simulator
     behaves exactly as the standard one, cycle for cycle. Exit status 1 on any difference.
"""
import argparse
import concurrent.futures as cf
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
TIMEOUT = 100000            # sim/top.sv's default cycle limit, as for make test/...

# Lines that describe the configuration, the checkers or the simulator's run rather than the
# program's behaviour (Verilator's report: "- sim/top.sv:<line>: Verilog $finish",
# "- S i m u l a t i o n   R e p o r t ...", "- Verilator: ..."); compare checks the bus
# hashes separately
CONFIG_LINE = re.compile(r"^(SLOW MEMORY |SCOREBOARD|BUSHASH |RETIRED |- \S+:\d+: Verilog |- S i m u l a t i o n |- Verilator: )")
ANSI = re.compile(r"\x1b\[[0-9;]*m")
REPORT = re.compile(r"Test (pass|fail)!")
VERDICT = re.compile(r"\s*(All tests passed|Some test\(s\) failed|Inital test failed)")

# The verdict line with which a HaDes-V+ run ends on the standard memory, and so at latency 0
# (docs/VERIFICATION.md, "The Testbench's Verdict Line"): the self-checking assembly programs
# write the "initial test" marker and pass; bpred.s and the C programs write no marker, so a
# passing run reads "Inital test failed! (# Errors: 0)" and has no "Test fail!" line;
# basys3_demo and the bootloader never end. A further pattern, where given, must match a line
# of the output (the program's own verdict).
ALL_PASSED = "All tests passed! (# Errors: 1 = initial test)"
NO_MARKER = "Inital test failed! (# Errors: 0)"
TIMED_OUT = "Simulation timeout!"
VERDICT_AT_LATENCY0 = {
    "asm/bpred": (NO_MARKER, None),
    "c/m_extension": (NO_MARKER, r"^M-EXT PASS$"),
    "c/basys3_demo": (TIMED_OUT, None),
    "c/bootloader": (TIMED_OUT, None),
}


def verdict_at_latency0(prog):
    return VERDICT_AT_LATENCY0.get(prog, (NO_MARKER if prog.startswith("c/") else ALL_PASSED, None))


# TIMING: when a rule of WAIT_STATES applies, by the latency profile of the configuration and
# the run options (+mem_lat=... in --sim-args); `when` of a rule, default ALWAYS:
#   ALWAYS       every profile with wait states
#   FETCH_WAITS  instruction fetch waits: a read latency (or a burst beat) above 0 on the
#                fetch port
#   VARIABLE     the latency of an access is not always the same: random per-access
#                latencies (MIN < MAX) on a port that waits, or burst mode (MEM_BEAT_LAT)
#   FIXED        wait states, all at one fixed latency, no burst mode
# The checks of a program that time its own instructions against mcycle are of two kinds.
# Some compare two blocks of instructions with each other: at a fixed latency every fetch
# waits the same, the comparison still holds and still means something (an operand-dependent
# stall, of a cache for instance, would show there), so they are excused only when the
# latency varies. Others compare a block with the absolute cycle count of single-cycle fetch,
# and fail whenever instruction fetch waits.
ALWAYS, FETCH_WAITS, VARIABLE, FIXED = "always", "fetch waits", "variable", "fixed"


def cycle_exact(name, line, report):
    """The two timed checks of test_cycle_exact in the Zb*/Zk*/Zicond programs, at <name>.s:<line>
    (the equality check, report <report>) and <line> + 3 (the 17-cycle check, report
    <report> + 2)."""
    return [
        dict(may_fail=[report], when=VARIABLE,
             why=f"test_cycle_exact, {name}.s:{line} (report {report}): the chain of 16 dependent "
                 f"instructions of the extension must take as many mcycle cycles as the chain of 16 "
                 f"adds; this holds at a fixed latency, not with random per-access latencies or "
                 f"in burst mode"),
        dict(may_fail=[report + 2], when=FETCH_WAITS,
             why=f"test_cycle_exact, {name}.s:{line + 3} (report {report + 2}): the chain and one "
                 f"csrr must take exactly 17 cycles, which holds for single-cycle fetch only "
                 f"(17*(1+L) cycles with L wait states on fetch)"),
    ]


# Checks that measure the timing of a single-cycle memory. With wait states they may give
# another result although the CPU is right; the tests are right for the standard memory and
# stay as they are. A program's reports are its "Test pass!" and "Test fail!" lines,
# numbered from 1 in the order of its run at latency 0 (report 1 is the deliberate initial
# fail of the self-checking programs). Each program has a list of rules; every rule whose
# `when` (TIMING above) holds for the profile, and whose `cpu`, if given, is the run's CPU,
# applies. Keys of a rule:
#   insert_fail  one more "Test fail!" may come before this report
#   may_fail     these reports may be "Test fail!"
#   may_pass     these reports may be "Test pass!" (where the run at latency 0 failed them)
#   tail_may_fail  from this report on, each report may independently be "Test pass!" or
#                "Test fail!" (checked directly: a program whose whole point is to time its own
#                instructions has too many reports that may flip to list)
#   lines        output lines that match this pattern may differ (the diagnostics of a sweep)
#   numbers      in the output lines that match this pattern, the 8-digit hexadecimal
#                numbers may differ (cycle counts)
#   when         TIMING above (default ALWAYS)
#   cpu          only for the runs of this CPU ("dut" or "golden")
#   why          the reason
# zbb.s, zbkb.s, zbkx.s, zbs.s, zicond.s and zknh.s each end their timing tests with the same
# test_cycle_exact block (cycle_exact above): a chain of 16 dependent instructions of the
# extension and a chain of 16 adds are timed with mcycle. Report n-2 (assert_equal s8, s9)
# requires both chains to take the same number of cycles, report n (addi s9, s8, -17;
# assert_value s9, 0) requires the extension chain and one csrr to take exactly 17. With L
# wait states, Fetch delivers one instruction every 1+L cycles, so the chain takes 17*(1+L)
# cycles: report n fails at every fetch latency above 0, and report n-2 fails only when the
# per-access latencies of the two chains differ. Report n-1 (assert_value s4, the chain's
# result) and every check of the following test_interrupt_in_chain block stay strict.
WAIT_STATES = {
    "asm/ops": [dict(
        insert_fail=56,
        why="the interrupt handler requires t6 = 5 (ops.s:532), i.e. that three 'addi t6,t6,1' "
            "retire in the 2 cycles between 'interrupt 2' (ops.s:518), which makes the test "
            "device raise its interrupt 2 cycles later, and the interrupt; with wait states "
            "fewer instructions retire in those cycles (t6 = 3) and the 'fail' after the check "
            "runs; the other checks of the interrupt (mcause, t6 = 9, the handler ran) still "
            "apply")],
    "asm/zicntr": [dict(
        may_fail=[4, 5], when=VARIABLE,
        why="zicntr.s:205-206 require the cycle deltas of three pairs of adjacent counter reads "
            "to be equal, which holds when every fetch takes the same time (latency 0, or a "
            "fixed latency) but not with random per-access latencies or in burst mode")],
    "asm/uartirq": [dict(
        may_fail=[14], lines=r"^\[[ .rSD]*\]$",
        why="check 5 needs its sweep of the store's position (DFIRST..DLAST, uartirq.s:76-77: "
            "142..166 nops, the boundary at 154 on single-cycle memory) to cross the cycle in "
            "which the transmit buffer empties; with wait states the nops take longer, the "
            "boundary moves before the window, every position prints 'r', and report 14 (some "
            "position took no interrupt, uartirq.s:281) fails as the test's header says it will; "
            "report 13 (no spurious 'S' or doubled 'D' interrupt, uartirq.s:279) and report 15 "
            "(some position took one real interrupt, uartirq.s:283) still apply")],
    "asm/memirq": [dict(
        lines=r"^[<>0-9]+$",
        why="its UART lines show where each interrupt landed ('<' before the block of accesses, "
            "'0'..'8' in it, '>' after it); the arming delay (ARM_DELAY, memirq.s:48) is set "
            "for single-cycle fetch, so with wait states the interrupts land before the block: "
            "the verdict is the same, the sweep covers less")],
    "asm/mtvecirq": [dict(
        cpu="golden", may_pass=[2], lines=r"^[.V]+$",
        why="the golden CPU's stale-mtvec defect (mtvecirq.s's header: 'V' at one delay step) "
            "fails report 2 when the sweep hits its timing window, as it does at latency 0, "
            "and with wait states it may hit it at other positions or not at all")],
    "c/test_csr": [dict(numbers=r"^(?!00001234$|0000abcd$|00000000$)[0-9a-f]{8}$",
                        why="its third line is an mcycle reading (the first two, mscratch, stay, "
                            "and a reading of 0 is still wrong)")],
    "c/test_mcycle": [dict(numbers=r"^X[0-9a-f]{8} ", why="it prints mcycle readings")],
    "c/bp_benchmark": [dict(
        numbers=r"^M[03]: cyc=",
        why="it prints the cycles of a loop and the branch predictor's counters, which also "
            "count the branches of the UART polling loops between the counter reads")],
    "asm/zbb": cycle_exact("zbb", 1729, 403),
    "asm/zbkb": cycle_exact("zbkb", 992, 182),
    "asm/zbkx": cycle_exact("zbkx", 951, 150),
    "asm/zbs": cycle_exact("zbs", 1411, 353),
    "asm/zicond": cycle_exact("zicond", 1027, 174),
    "asm/zknh": cycle_exact("zknh", 1391, 312),
    # zkt.s times blocks of 8 instructions against mcycle: report 2 (zkt.s:192) requires the
    # block of adds to take exactly 9 cycles, reports 3-304 that every other block takes the
    # cycles of the add block (the mul/mulh/mulhsu/mulhu blocks, reports 67-94 in test_mul,
    # zkt.s:1172-1622: exactly 8 more). At a fixed latency the same 29 reports fail at
    # latencies 1, 2, 3, 4 and 8 (with every fetch waiting, the multiplier's second cycle no
    # longer shows), and the 274 other comparisons still hold.
    "asm/zkt": [
        dict(may_fail=[2] + list(range(67, 95)), when=FIXED,
             why="zkt.s:192 (report 2) requires the block of 8 adds to take exactly 9 cycles, "
                 "which holds for single-cycle fetch only; test_mul (zkt.s:1172-1622, reports "
                 "67-94) requires the mul, mulh, mulhsu and mulhu blocks to take exactly 8 cycles "
                 "more than the add block, which with every fetch waiting they do not (the "
                 "multiplier's second cycle is hidden behind the fetch); every other block must "
                 "still take the cycles of the add block"),
        dict(tail_may_fail=2, when=VARIABLE,
             why="zkt.s times blocks of the core's own instructions against mcycle and requires each "
                 "block to take exactly the cycles of a same-size block of 'add' (zkt.s's own header: "
                 "a fixed number of cycles whatever the operands); with random per-access latencies "
                 "or in burst mode the fetches of two blocks no longer take the same time, so almost "
                 "any timed block may measure other cycles than expected and fail. Report 1, the "
                 "deliberate initial-test fail, still applies exactly as at latency 0, and every "
                 "report from 2 on may independently pass or fail"),
    ],
}


def latency_profile(defs, sim_args):
    """The wait states of both RAM ports: the defaults compiled in (the Verilator defines of the
    configuration), overridden as sim/slow_memory.sv does by the run options in sim_args."""
    def define(name, default):
        m = re.search(rf"\+define\+HADES_MEM_{name}=(-?\d+)", defs)
        return int(m.group(1)) if m else default

    def option(name):              # $value$plusargs takes the first match
        return next((a.split("=", 1)[1] for a in sim_args if a.startswith(f"+{name}=")), None)

    def rng(text):
        lo, _, hi = text.partition(":")
        return int(lo), int(hi or lo)

    rd = (define("RD_LAT_MIN", 0), define("RD_LAT_MAX", 0))
    wr = (define("WR_LAT_MIN", 0), define("WR_LAT_MAX", 0))
    beat = define("BEAT_LAT", -1)
    only = "fetch" if "+define+HADES_MEM_ONLY_FETCH" in defs else \
        "data" if "+define+HADES_MEM_ONLY_DATA" in defs else ""
    if option("mem_lat") is not None:
        rd = wr = rng(option("mem_lat"))
    if option("mem_rd_lat") is not None:
        rd = rng(option("mem_rd_lat"))
    if option("mem_wr_lat") is not None:
        wr = rng(option("mem_wr_lat"))
    if option("mem_beat_lat") is not None:
        beat = int(option("mem_beat_lat"))
    if option("mem_only") is not None:
        only = option("mem_only")
    zero, off = (0, 0), -1
    fetch = dict(rd=rd if only != "data" else zero, beat=beat if only != "data" else off)
    data = dict(rd=rd if only != "fetch" else zero, wr=wr if only != "fetch" else zero,
                beat=beat if only != "fetch" else off)
    ranges = [fetch["rd"], data["rd"], data["wr"]]
    beats = [fetch["beat"], data["beat"]]
    fetch_waits = fetch["rd"][1] > 0 or fetch["beat"] > 0
    waits = any(hi > 0 for _, hi in ranges) or any(b > 0 for b in beats)
    variable = any(lo < hi for lo, hi in ranges) or any(b >= 0 for b in beats)
    mode = (VARIABLE if variable else FIXED) if waits else "latency 0"

    def text(r):
        return f"{r[0]}" if r[0] == r[1] else f"{r[0]}..{r[1]}"
    desc = (f"fetch port reads {text(fetch['rd'])}, data port reads {text(data['rd'])} and writes "
            f"{text(data['wr'])} cycles, bursts {'off' if max(beats) < 0 else 'beat ' + str(max(beats))}")
    longest = max([hi for _, hi in ranges] + beats + [0])
    return dict(fetch_waits=fetch_waits, waits=waits, mode=mode, text=desc, longest=longest)


def rules_for(program, cpu, profile):
    """The rules of WAIT_STATES that apply to a run of <program> on <cpu> with this profile."""
    def holds(when):
        return {ALWAYS: profile["waits"], FETCH_WAITS: profile["fetch_waits"],
                VARIABLE: profile["mode"] == VARIABLE, FIXED: profile["mode"] == FIXED}[when]
    return [r for r in WAIT_STATES.get(program, [])
            if holds(r.get("when", ALWAYS)) and r.get("cpu", cpu) == cpu]


def make(args, capture=False):
    cmd = ["make", "-s", "--no-print-directory", "-C", REPO] + args
    r = subprocess.run(cmd, stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
                       stderr=subprocess.STDOUT, text=True)
    if r.returncode:
        out = r.stdout or ""
        sys.exit(f"programs.py: '{' '.join(cmd)}' failed{':' + chr(10) + out[-3000:] if out else ''}")
    return r.stdout


def programs():
    names = []
    for kind, ext in (("asm", ".s"), ("c", ".c"), ("memsys", ".s")):
        d = os.path.join(REPO, "test", kind)
        names += [f"{kind}/{f[:-len(ext)]}" for f in sorted(os.listdir(d)) if f.endswith(ext)]
    return names


def parse(log, rc):
    """The facts of one run, from its output."""
    clean = ANSI.sub("", log)
    lines = clean.splitlines()
    verdict = next((l.strip() for l in lines if re.match(r"\s*(All tests passed|Some test\(s\) failed|"
                                                          r"Inital test failed|Simulation timeout!)", l)), "")
    # (Verilator prints $fatal as "[<time>] %Fatal: <file>:<line>: Assertion failed in ...: <message>")
    sb = next((l for l in lines if "SCOREBOARD: FAIL" in l), "") or \
        next((l for l in lines if l.startswith("SCOREBOARD: ")), "")
    errors = [l for l in lines if re.search(r"%(Fatal|Error)", l)]
    bushash = next((l for l in lines if l.startswith("BUSHASH ")), "")
    retired = next((l for l in lines if l.startswith("RETIRED ")), "")
    m = re.search(r"cycles=(\d+)", retired or bushash)
    cycles = int(m.group(1)) if m else None
    # the program's reports, whether it reached the testbench's verdict, and its other output
    reports, finished, output = "", False, []
    for l in lines:
        m = REPORT.search(l)
        if m:
            reports += "P" if m.group(1) == "pass" else "F"
        elif VERDICT.match(l):
            finished = True
        elif not CONFIG_LINE.match(l):
            output.append(l)
    return dict(verdict=verdict or "(no verdict)", passes=reports.count("P"), fails=reports.count("F"),
                cycles=cycles, scoreboard=("FAIL" if "FAIL" in sb else "PASS" if "PASS" in sb else "-"),
                scoreboard_line=sb, bushash=bushash, retired=retired, errors=errors[:3], rc=rc,
                reports=reports, finished=finished, output=output)


def reports_match(res, ref, rule):
    """Whether the reports <res> of a run are among those that the merged rules allow, from the
    reports <ref> of its run at latency 0. Every report may keep its value at latency 0;
    may_fail and may_pass let the listed ones (numbered as at latency 0) be "F" or "P";
    insert_fail <n> lets one more "F" come before report <n>; tail_may_fail <n> lets every
    report from <n> on be either (the reports before it must be equal)."""
    n = rule.get("tail_may_fail")
    if n:
        return len(res) == len(ref) and res[:n - 1] == ref[:n - 1]
    allowed = [{c} | ({"F"} if i + 1 in rule["may_fail"] else set()) | ({"P"} if i + 1 in rule["may_pass"] else set())
               for i, c in enumerate(ref)]
    candidates = [allowed]
    n = rule.get("insert_fail")
    if n and len(ref) >= n - 1:
        candidates.append(allowed[:n - 1] + [{"F"}] + allowed[n - 1:])
    return any(len(c) == len(res) and all(r in a for r, a in zip(res, c)) for c in candidates)


def merge(rules):
    """The rules that apply to one run, as one."""
    m = dict(may_fail=set(), may_pass=set(), lines=[], numbers=[])
    for r in rules:
        m["may_fail"] |= set(r.get("may_fail", []))
        m["may_pass"] |= set(r.get("may_pass", []))
        for k in ("lines", "numbers"):
            if r.get(k):
                m[k].append(r[k])
        for k in ("insert_fail", "tail_may_fail"):
            if r.get(k):
                m[k] = min(m.get(k, r[k]), r[k])
    return m


def judge(res, ref, rules):
    """A run against the run of the same program on the same CPU at latency 0:
    -> ("same" | "expected" | "DIFFERS", [what differs])."""
    rule = merge(rules)
    what, expected = [], False
    if res["finished"] != ref["finished"]:
        what.append("no verdict within the cycle limit, unlike at latency 0" if ref["finished"]
                    else "a verdict, unlike at latency 0")
    if res["reports"] != ref["reports"]:
        if reports_match(res["reports"], ref["reports"], rule):
            expected = True
        else:
            what.append(f"reports {res['reports'] or '(none)'}, at latency 0 {ref['reports'] or '(none)'}")
    a, b = ref["output"], res["output"]
    if a != b:
        def number(l):              # the cycle counts of a line that may differ, hidden
            if any(re.match(p, l) for p in rule["numbers"]):
                return re.sub(r"[0-9a-f]{8}", "########", l)
            return l
        a = [l for l in a if not any(re.match(p, l) for p in rule["lines"])]
        b = [l for l in b if not any(re.match(p, l) for p in rule["lines"])]
        if list(map(number, a)) == list(map(number, b)):
            expected = True
        else:
            i = next(i for i in range(max(len(a), len(b)))
                     if i >= len(a) or i >= len(b) or number(a[i]) != number(b[i]))
            what.append(f"output line {i + 1}: {(b[i] if i < len(b) else '(end)')!r}, "
                        f"at latency 0 {(a[i] if i < len(a) else '(end)')!r}")
    return ("DIFFERS" if what else "expected" if expected else "same"), what


def problems(r, latency0, scoreboard_needed):
    """What makes a run bad, whatever the judgement: its own checks and its simulator."""
    p = []
    if r["scoreboard"] == "FAIL":
        p.append(f"scoreboard: {r['scoreboard_line']}")
    if r["rc"] != 0 and r["verdict"] == "(no verdict)":
        p.append(f"the simulator returned {r['rc']} without a verdict line")
    if scoreboard_needed and r["scoreboard"] == "-" and not r["errors"]:
        p.append("no SCOREBOARD line, although the scoreboard should be on")
    if latency0 and r["cpu"] == "dut":
        verdict, own = verdict_at_latency0(r["program"])
        if not r["verdict"].startswith(verdict):
            p.append(f"verdict '{r['verdict']}', on the standard memory '{verdict}'")
        elif verdict == NO_MARKER and r["fails"]:
            p.append(f"{r['fails']} 'Test fail!' line(s), on the standard memory none")
        if own and not any(re.match(own, l) for l in r["output"]):
            p.append(f"no output line matching {own!r}")
    return p


def run(a, variables):
    cfg = make(["sim-config"] + variables, capture=True)
    bmake = re.search(r"build directory:\s+(\S+)", cfg).group(1)       # as make spells it
    bdir = os.path.join(REPO, bmake)
    name = re.search(r"simulator configuration: (\S+)", cfg).group(1)
    defs = re.search(r"Verilator defines:\s+(.*)", cfg).group(1)
    slow = "+define+HADES_SLOW_MEM" in defs
    sim_args = a.sim_args.split()
    profile = latency_profile(defs, sim_args) if slow else None
    timeout = a.timeout or TIMEOUT * (1 + (profile["longest"] if slow else 0))
    judged = slow and not a.no_judge
    # the scoreboard: the configuration's default (make sim-config: "scoreboard on|off"), then
    # the run options (+scoreboard wins over +noscoreboard, as in sim/top.sv)
    scoreboard = ("+scoreboard" in sim_args or
                  ("scoreboard on" in cfg.splitlines()[0] and "+noscoreboard" not in sim_args))
    if judged and not scoreboard and not a.allow_no_scoreboard:
        sys.exit("programs.py: the scoreboard is off (SCOREBOARD=0 or +noscoreboard). Judging against "
                 "latency 0 compares with a run in the same simulator, so a fault of the memory path "
                 "that is present at every latency gives the same wrong result in both runs and only "
                 "the scoreboard sees it. Turn it on, or give --allow-no-scoreboard to judge without it.")
    out = os.path.abspath(a.out or os.path.join(bdir, "programs"))
    cpus = a.cpu.split(",")
    print(f"configuration {name}; simulators and programs in {bdir}; runs in {out}; cycle limit {timeout}",
          flush=True)
    if slow:
        print(f"latency profile: {profile['text']}; timing checks judged as: "
              f"{ {VARIABLE: 'random latency or burst mode', FIXED: 'fixed latency'}.get(profile['mode'], profile['mode']) }"
              f", instruction fetch {'waits' if profile['fetch_waits'] else 'does not wait'}", flush=True)
    if judged and not scoreboard:
        print("WARNING: the scoreboard is off (--allow-no-scoreboard): a fault of the memory path that is "
              "present at every latency is judged the same", flush=True)
    sims = {}
    for cpu in cpus:
        model = {"dut": "dut", "golden": "ref"}[cpu]
        print(f"building the {cpu} simulator ...", flush=True)
        make(["frtos-model", f"FRTOS_CPU={model}", "FRTOS_RAM_KB=32"] + variables)
        sims[cpu] = os.path.join(bdir, "frtos-model", f"{model}-32k", "top")
    progs = [p for p in programs() if re.search(a.only or "", p)]
    print(f"building {len(progs)} programs ...", flush=True)
    make([os.path.join(bmake, "test", p, "init.mem") for p in progs] + variables)

    # the runs at latency 0 against which the others are judged (first on the command line:
    # a run option is taken from its first occurrence)
    ref_args = ["+mem_lat=0", "+mem_rd_lat=0", "+mem_wr_lat=0", "+mem_beat_lat=0"]

    def one(cpu, prog, latency0):
        d = os.path.join(out, *(["latency0"] if latency0 else []), cpu, prog.replace("/", "-"))
        os.makedirs(d, exist_ok=True)
        shutil.copy(os.path.join(bdir, "test", prog, "init.mem"), d)
        cmd = [sims[cpu], "+nodump", f"+timeout={timeout}"] + (ref_args if latency0 else []) + sim_args
        r = subprocess.run(cmd, cwd=d, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                           errors="replace")
        with open(os.path.join(d, "sim.log"), "w") as f:
            f.write(r.stdout)
        res = parse(r.stdout, r.returncode)
        res.update(cpu=cpu, program=prog, dir=os.path.relpath(d, out))
        return res

    results, refs = [], {}
    with cf.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        futs = {ex.submit(one, cpu, p, l0): l0 for cpu in cpus for p in progs for l0 in ([False, True] if judged else [False])}
        for f in cf.as_completed(futs):
            r = f.result()
            if futs[f]:
                refs[(r["cpu"], r["program"])] = r
            else:
                results.append(r)
    results.sort(key=lambda r: (r["cpu"], r["program"]))
    at_latency0 = not slow or profile["mode"] == "latency 0"      # the runs themselves
    for r in results:
        r["problems"] = problems(r, at_latency0, judged and scoreboard)
        if judged:
            ref = refs[(r["cpu"], r["program"])]
            rules = rules_for(r["program"], r["cpu"], profile)
            r["judged"], r["differences"] = judge(r, ref, rules)
            r["rules"] = [x["why"] for x in rules]
            r["latency0"] = {k: ref[k] for k in ("dir", "verdict", "reports", "cycles", "scoreboard", "errors", "rc")}
            r["problems"] += [f"latency 0: {x}" for x in problems(ref, True, judged and scoreboard)]
        else:
            r["judged"], r["differences"] = "-", []
    with open(os.path.join(out, "results.json"), "w") as f:
        json.dump(dict(configuration=name, sim_args=a.sim_args, timeout=timeout, judged=judged,
                       profile=profile, scoreboard=scoreboard, results=results), f, indent=1)

    bad, differs = 0, 0
    print(f"{'cpu':6} {'program':18} {'pass':>4} {'fail':>4} {'cycles':>9}  {'scoreboard':10} {'judged':8} verdict")
    for r in results:
        print(f"{r['cpu']:6} {r['program']:18} {r['passes']:4} {r['fails']:4} {str(r['cycles']):>9}  "
              f"{r['scoreboard']:10} {r['judged']:8} {r['verdict']}")
        for e in r["errors"] + (r["latency0"]["errors"] if judged else []):
            print(f"{'':12}{e}")
        for w in r["differences"] + [p for p in r["problems"] if "scoreboard: " not in p]:
            print(f"{'':12}{w}")
        if r["errors"] or r["problems"] or (judged and r["latency0"]["errors"]):
            bad += 1
        if r["cpu"] == "dut" and r["judged"] == "DIFFERS":
            differs += 1
    n_sb = sum(r["scoreboard"] == "PASS" for r in results)
    print(f"PROGRAMS: {len(results)} runs in configuration {name}: scoreboard PASS in {n_sb}, "
          f"{bad} run(s) with a scoreboard mismatch, a simulator error or a wrong verdict at latency 0; "
          f"results: {out}/results.json")
    if judged:
        for cpu in cpus:
            rs = [r for r in results if r["cpu"] == cpu]
            cnt = {j: [r["program"] for r in rs if r["judged"] == j] for j in ("same", "expected", "DIFFERS")}
            print(f"JUDGED against latency 0: {cpu}{' (recorded, not judged)' if cpu != 'dut' else ''}: "
                  f"{len(rs)} runs, {len(cnt['same'])} the same, {len(cnt['expected'])} with the differences "
                  f"listed for wait states{' (' + ', '.join(cnt['expected']) + ')' if cnt['expected'] else ''}, "
                  f"{len(cnt['DIFFERS'])} differ otherwise{' (' + ', '.join(cnt['DIFFERS']) + ')' if cnt['DIFFERS'] else ''}")
        shown = set()
        for r in results:
            if r["judged"] == "expected":
                for x in rules_for(r["program"], r["cpu"], profile):
                    if (r["program"], x["why"]) not in shown:
                        shown.add((r["program"], x["why"]))
                        only = f" ({x['cpu']} only)" if x.get("cpu") else ""
                        print(f"  {r['program']}{only}: {x['why']}")
    if judged and not scoreboard:
        print("WARNING: judged with the scoreboard off")
    return 1 if bad or differs else 0


def outputs(d):
    res = json.load(open(os.path.join(d, "results.json")))
    return res, {(r["cpu"], r["program"]): r for r in res["results"]}


def program_output(d, r):
    with open(os.path.join(d, r["dir"], "sim.log"), errors="replace") as f:
        return [l for l in f.read().splitlines() if not CONFIG_LINE.match(l)]


def compare(a):
    ra, A = outputs(a.dirs[0])
    rb, B = outputs(a.dirs[1])
    keys = sorted(set(A) | set(B))
    diffs, hashes, one_sided = [], 0, 0
    for k in keys:
        if k not in A or k not in B:
            diffs.append(f"{k[0]} {k[1]}: only in {'B' if k not in A else 'A'}")
            continue
        oa, ob = program_output(a.dirs[0], A[k]), program_output(a.dirs[1], B[k])
        if oa != ob:
            first = next(i for i in range(max(len(oa), len(ob)))
                         if i >= len(oa) or i >= len(ob) or oa[i] != ob[i])
            diffs.append(f"{k[0]} {k[1]}: output differs from line {first + 1}: "
                         f"{(oa[first] if first < len(oa) else '(end)')!r} / "
                         f"{(ob[first] if first < len(ob) else '(end)')!r}")
        ha, hb = A[k]["bushash"], B[k]["bushash"]
        if ha and hb:
            if ha == hb:
                hashes += 1
            else:
                diffs.append(f"{k[0]} {k[1]}: bus hashes differ: {ha} / {hb}")
        elif ha or hb:
            one_sided += 1
    print(f"COMPARE {ra['configuration']} ({a.dirs[0]})")
    print(f"   with {rb['configuration']} ({a.dirs[1]})")
    for d in diffs:
        print(f"  {d}")
    print(f"PROGRAMS COMPARE: {'SAME' if not diffs else 'DIFFERENT'}  {len(keys)} runs, {len(diffs)} differ; "
          f"equal bus hashes: {hashes}" + (f"; a bus hash in one run only (not compared): {one_sided}" if one_sided else ""))
    return 1 if diffs else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run", help="run the programs in one configuration")
    r.add_argument("variables", nargs="*", help="the configuration's options, e.g. MEM_LAT=2 BUSHASH=1")
    r.add_argument("--cpu", default="dut,golden", help="dut and/or golden (default: both)")
    r.add_argument("--jobs", type=int, default=4)
    r.add_argument("--only", default="", help="only the programs matching this regular expression")
    r.add_argument("--timeout", type=int, default=None,
                   help=f"cycle limit of a run (default {TIMEOUT}, as for make test/..., times 1 + the "
                        f"longest wait of the configuration's slow memory)")
    r.add_argument("--sim-args", default="", help="further run-time options for the simulator")
    r.add_argument("--no-judge", action="store_true", help="with a slow memory: do not run the programs at "
                                                          "latency 0 and do not judge the runs")
    r.add_argument("--allow-no-scoreboard", action="store_true",
                   help="judge the runs of a slow memory although the scoreboard is off (it warns)")
    r.add_argument("--out", default=None, help="run directory (default: <build dir>/programs)")
    c = sub.add_parser("compare", help="compare the runs of two configurations")
    c.add_argument("dirs", nargs=2)
    a = ap.parse_args()
    if a.cmd == "run":
        bad = [v for v in a.variables if not re.match(r"^[A-Z_]+=", v)]
        if bad:
            ap.error(f"not an option of the form NAME=value: {bad}")
        return run(a, a.variables)
    return compare(a)


if __name__ == "__main__":
    sys.exit(main())
