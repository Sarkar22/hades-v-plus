#!/bin/sh
# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------------------------------
# results/check.sh -- re-runs the repeatable records of results/ and compares what the commands
# print with the values stored in the records. Guide: results/README.md.
#
#   sh results/check.sh [--jobs N] [--campaign] [--formal] [--list] [CHECK ...]
#   make check-results [CHECK_ARGS='...']
#
# The checks, each against the newest repeatable record of its topic:
#   zba                make bench-zba, at -O2, -Os and -O0           results/zba/
#   m-unit-cycles      make bench-mcost                              results/m-unit-cycles/
#   fencei-window      make bench-fencei-window                      results/fencei-window/
#   tests              every suite of docs/VERIFICATION.md            results/tests/
#   trapsweep          sweep.py list and run, the four fuzz sets     results/trapsweep/
#   freertos-validate  the campaign of make freertos-stress          results/freertos-validate/
#   freertos-campaign  only with --campaign: the 794-run suite       results/freertos-campaign/
#   formal             only with --formal: make formal (formal tools) results/formal/
# Without CHECK names it runs the first six (4 to 10 minutes once the simulators are built,
# depending on the load of the machine).
# Each check compares the stored values exactly: program output, cycle counts, verdict lines,
# per-run tables and the sha256 of the program images. Wall times are never compared.
#
# It prints one block per check and ends with one line, CHECK RESULTS: PASS or
# CHECK RESULTS: FAIL; the exit status is 0 only for PASS. The commands run in the repository
# root and build into the build directory ($HADES_BUILD_DIR, else build/); their logs go to
# <build directory>/check-results/. The tests check creates test/freertos/myapp/ for one row,
# as docs/FREERTOS.md section 8 does, and removes it again; before a FreeRTOS command whose
# recorded output includes the program's size line, it removes that program's ELF from the build
# directory, so that the command links the program again and prints the line.
# ---------------------------------------------------------------------------------------------
command -v python3 >/dev/null 2>&1 || { echo "results/check.sh: python3 is needed" >&2; exit 2; }
exec python3 - "$0" "$@" <<'PYTHON'
import argparse
import csv
import difflib
import glob
import hashlib
import io
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(sys.argv[1])))
sys.argv = ["results/check.sh"] + sys.argv[2:]
os.chdir(ROOT)

BUILD = os.path.abspath(os.environ.get("HADES_BUILD_DIR") or os.path.join(ROOT, "build"))
BUILD_NAME = "build" if BUILD == os.path.join(ROOT, "build") else "$HADES_BUILD_DIR"
LOGS = os.path.join(BUILD, "check-results")
ANSI = re.compile(r"\x1b\[[0-9;]*m")
# Verilator's run statistics: wall-clock time, speed, CPU time and memory vary from run to run
STATS = re.compile(r"\b(walltime|speed|cpu|alloced) [0-9.]+( ?[A-Za-z]+(/s)?)?")

# The commands get the caller's environment without make's flags (a parent make's jobserver or
# variables) and without the FreeRTOS source overrides: the records use the vendored sources.
ENV = dict(os.environ)
IGNORED = [k for k in ("FREERTOS_HOME", "FREERTOS_KERNEL", "FREERTOS_DEMO", "FREERTOS_PLUS_CLI")
           if ENV.get(k)]
for k in ("MAKEFLAGS", "MFLAGS", "MAKELEVEL", "MAKEOVERRIDES", "GNUMAKEFLAGS") + tuple(IGNORED):
    ENV.pop(k, None)
ENV["GIT_OPTIONAL_LOCKS"] = "0"


def say(text=""):
    print(text, flush=True)


def rel(path):
    """path relative to the repository, or with the build directory written as such"""
    path = os.path.abspath(path)
    if path == BUILD or path.startswith(BUILD + os.sep):
        return BUILD_NAME + path[len(BUILD):]
    return os.path.relpath(path, ROOT)


def built(path):
    """A record's 'build/...' path in the build directory in use"""
    if not path.startswith("build/"):
        raise ValueError("not a build path: " + path)
    return os.path.join(BUILD, path[len("build/"):])


def sha256(path):
    try:
        with open(path, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except OSError:
        return None


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def norm(line):
    return STATS.sub(r"\1 #", ANSI.sub("", line)).rstrip()


def log_lines(text):
    """The lines of a run log that are compared: without the simulator's report header"""
    return [norm(l) for l in text.splitlines() if not l.startswith("- S i m u l a t i o n")]


def stop_group(p):
    """Stops the process group of p and everything in it (make, its simulators, campaign workers)"""
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(p.pid, sig)
        except OSError:
            return
        try:
            p.wait(timeout=10)
            return
        except subprocess.TimeoutExpired:
            pass


def run(cmd, log):
    """Runs cmd (a list, or a string for sh -c) in the repository root, stdin /dev/null, stdout and
    stderr into log. Returns (exit status, output without colour codes, seconds). The command runs
    in a process group of its own, which an interruption of this script stops as a whole."""
    os.makedirs(os.path.dirname(log), exist_ok=True)
    t0 = time.time()
    with open(log, "wb") as f:
        p = subprocess.Popen(cmd, cwd=ROOT, env=ENV, stdin=subprocess.DEVNULL, stdout=f,
                             stderr=subprocess.STDOUT, shell=isinstance(cmd, str), start_new_session=True)
        try:
            rc = p.wait()
        except BaseException:
            stop_group(p)
            raise
    return rc, ANSI.sub("", read(log)), time.time() - t0


def show(cmd):
    """cmd as printed: the build directory written as build/ or $HADES_BUILD_DIR"""
    text = cmd if isinstance(cmd, str) else " ".join(cmd)
    return text.replace(BUILD + os.sep, BUILD_NAME + "/")


def newest_record(topic, statuses=("repeatable",)):
    """The newest record of a topic with one of the statuses (by the date in its directory name)"""
    found = []
    for m in sorted(glob.glob(os.path.join("results", topic, "*", "meta.json"))):
        try:
            status = str(json.load(open(m)).get("status", ""))
        except (OSError, ValueError):
            continue
        if status.startswith(statuses):
            found.append(os.path.dirname(m))
    return found[-1] if found else None


def diff_lines(want, got, limit=12):
    """The first differences of two line lists, for the report: the lines that only the record
    has ('recorded:') and the lines that only the new output has ('now:')"""
    out = []
    matcher = difflib.SequenceMatcher(None, want, got, autojunk=False)
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            continue
        out += ["        recorded: " + l for l in want[i1:i2]]
        out += ["        now:      " + l for l in got[j1:j2]]
        if len(out) >= limit:
            return out[:limit] + ["        ..."]
    return out


class Check:
    def __init__(self, name, topic, title):
        self.name, self.topic, self.title = name, topic, title
        self.record = newest_record(topic, STATUSES.get(name, ("repeatable",)))
        self.problems = []
        self.compared = []
        self.not_run = None     # the reason, when the check could not be run at all

    def meta(self):
        return json.load(open(os.path.join(self.record, "meta.json")))

    def log(self, name):
        return os.path.join(LOGS, self.name, name + ".log")

    def problem(self, text, details=()):
        self.problems.append(text)
        say("     DIFFERS: " + text)
        for d in details:
            say(d)

    def run(self, cmd, logname, expect_rc=0):
        say("   $ " + show(cmd))
        rc, out, dt = run(cmd, self.log(logname))
        if rc != expect_rc:
            self.problem("'%s' exited with status %d, recorded %d (log: %s)"
                         % (show(cmd), rc, expect_rc, rel(self.log(logname))))
        return rc, out, dt

    def compare_images(self, expected):
        """expected: {record path 'build/...': sha256}"""
        bad = [p for p, h in sorted(expected.items()) if sha256(built(p)) != h]
        for p in bad:
            self.problem("%s: sha256 %s, recorded %s" % (p, sha256(built(p)) or "(missing)", expected[p]))
        self.compared.append("%d of %d program files (sha256)" % (len(expected) - len(bad), len(expected)))


# ---- benchmarks: zba, m-unit-cycles, fencei-window ------------------------------------------

def bench_summary(out, want):
    """The summary block that test/bench/bench.py printed: from the recorded first line to the
    line 'BENCH <NAME>: ...'"""
    lines = [l.rstrip() for l in out.splitlines()]
    first = want[0]
    starts = [i for i, l in enumerate(lines) if l == first] or \
             [i for i, l in enumerate(lines) if l[:15] == first[:15]]
    if not starts:
        return []
    block = []
    for l in lines[starts[-1]:]:
        block.append(l)
        if l.startswith("BENCH "):
            break
    return block


def check_bench(c, runs, subdir):
    """runs: [(make target and settings, key of summary_output or None)]"""
    meta = c.meta()
    for cmd, key in runs:
        rc, out, dt = c.run(cmd, "_".join(cmd[1:]).replace("=", "-"))
        want = (meta["summary_output"][key] if key else meta["summary_output"]).strip("\n").splitlines()
        got = bench_summary(out, want)
        if got != [l.rstrip() for l in want]:
            c.problem("the summary of '%s' differs from the record" % show(cmd), diff_lines(want, got))
    c.compared.append("%d summar%s" % (len(runs), "y" if len(runs) == 1 else "ies"))
    # the run log of every program, without Verilator's run statistics
    logs = sorted(glob.glob(os.path.join(c.record, "logs", "*.run.log")))
    same = 0
    for stored in logs:
        parts = os.path.basename(stored)[:-len(".run.log")].split(".")
        fresh = os.path.join(BUILD, "test", "bench", subdir, *parts, "run.log")
        want = log_lines(read(stored))
        got = log_lines(read(fresh)) if os.path.exists(fresh) else ["(no run log)"]
        if want == got:
            same += 1
        else:
            c.problem("run log %s differs from %s" % (rel(fresh), rel(stored)), diff_lines(want, got))
    c.compared.append("%d of %d run logs" % (same, len(logs)))
    c.compare_images(meta.get("outputs_sha256", {}))


def check_zba(c):
    check_bench(c, [(["make", "bench-zba"], "-O2"), (["make", "bench-zba", "OPT=-Os"], "-Os"),
                    (["make", "bench-zba", "OPT=-O0"], "-O0")], "zba")


def check_mcost(c):
    check_bench(c, [(["make", "bench-mcost"], None)], "mcost")


def check_fencei(c):
    check_bench(c, [(["make", "bench-fencei-window"], None)], "fencei-window")


# ---- tests: every suite of docs/VERIFICATION.md ----------------------------------------------

SUMMARY = r"All tests passed!|Some test\(s\) failed!|Inital test failed!|Simulation timeout!"
SV_PATTERNS = {
    "test_decode_exhaustive": [r"checks PASSED|checks passed"],
    "test_decode_compare": [r"checks passed"],
    "test_decode_hazard": [r"^All tests passed"],
    "test_zba_encoding_sweep": [r"^WIDTH:|^ENUM:|^=== SWEEP|after [ABCD]:|encoding checks passed"],
    "test_m_execute": [r"MEASURED:|Checks: |M-extension checks passed"],
    "test_execute_bpred_nextpc": [r"mismatches vs golden|next-PC checks passed"],
    "test_execute_compare": [r"Tests: +\d+ +Errors", r"^SOME TESTS"],
    "test_memory_compare": [r"Tests: +\d+ +Errors", r"^SOME TESTS"],
    "test_writeback_compare": [r"Tests: +\d+ +Errors", r"^SOME TESTS"],
    "test_writeback_special_irq": [r"Tests: +\d+ +Errors", r"^SOME TESTS"],
    "test_writeback_persephone_case1": [r"Verilog \$finish"],
    "test_writeback_persephone_case2": [r"Verilog \$finish"],
    "test_writeback_persephone_case13": [r"Verilog \$finish"],
    "test_example": [r"^%Error"],
}
FREERTOS_PATTERNS = {
    "freertos minimal": [r"image\+bss|config:|seed: switches|ticks=|FRTOS-RESULT|ps\) Test (pass|fail)!"
                         r"|FREERTOS RESULT|UART pattern"],
    "freertos stress": [r"image\+bss|ticks=|FRTOS-RESULT|FREERTOS RESULT|UART pattern"],
    "freertos mzba (rv32im_zba)": [r"image\+bss|ticks=|FRTOS-RESULT|FREERTOS RESULT|UART pattern"],
    "freertos full": [r"image\+bss|FRTOS-RESULT|FREERTOS RESULT|UART pattern|walltime"],
    "freertos-compare stress seed 7": [r"FREERTOS RESULT|^COMPARE|^AGREE"],
    "freertos-compare minimal": [r"FREERTOS RESULT|^COMPARE|^AGREE"],
    "freertos-check-rebuild": [r"^step \d|REBUILD CHECK"],
    "freertos-shell-test": [r"image\+bss|FREERTOS SHELL RESULT|typed lines"],
    "freertos-shell-compare": [r"FREERTOS SHELL RESULT|typed lines|SHELL COMPARE|lines labelled"],
    "freertos-shell-tty-test": [r"TTY TEST|^\s+PASS\s+paste"],
    "freertos template with IRQ (myapp)": [r"received \d+ items|FREERTOS RESULT|^COMPARE|^AGREE"],
    "freertos-list": [r"KiB|template"],
}
MYAPP = os.path.join("test", "freertos", "myapp")
# The size line that a FreeRTOS program prints when it is linked: '  <app>: RAM 32 KiB, image+bss ...'
SIZE_LINE = re.compile(r"^  (\S+): RAM \d+ KiB, image\+bss ")


def test_patterns(suite):
    """The lines of a command's output that the tests record keeps, as patterns (the same rules
    that made the record)"""
    if suite.startswith("asm/"):
        name = suite[4:]
        if name == "bpred":
            return [r"Test pass!|Test fail!", SUMMARY]
        if name in ("bpirq", "bpirq2", "bpirq3"):
            return [r"^[MDI][0-9a-f]{8} ", SUMMARY]
        return [SUMMARY]
    if suite == "c/m_extension":
        return [r"^M-EXT", SUMMARY]
    if suite == "c/bootloader":
        return [r"^INFO:", SUMMARY]
    if suite == "c/bp_benchmark":
        return [SUMMARY, r"^BP benchmark|^M[03]: cyc="]
    if suite.startswith("c/"):
        return [SUMMARY]
    if suite.startswith("sv/"):
        return SV_PATTERNS.get(suite[3:])
    return FREERTOS_PATTERNS.get(suite)


def test_output(suite, out):
    """The output lines of one command as the tests record stores them"""
    if suite == "campaign.py --set standard --list":
        n = sum(1 for l in out.splitlines() if re.match(r"^(minimal|stress|mzba|full|brk)\.", l))
        return ["%d variants listed" % n]
    if suite == "vendored FreeRTOS checksums":
        lines = out.splitlines()
        ok = sum(1 for l in lines if l.endswith(": OK"))
        other = sum(1 for l in lines if l.strip() and not l.endswith(": OK"))
        return ["%d files ': OK', %d other lines" % (ok, other)]
    pats = test_patterns(suite)
    return [l.rstrip() for l in out.splitlines() if any(re.search(p, l) for p in pats)]


def baseline_text(outputs):
    """baseline-diffs.txt from the output of the four golden-comparison benches"""
    text = ("# Every check on which a HaDes-V+ pipeline stage differs from its frozen golden stage\n"
            "# (lines '[n] <check> FAIL|COMB <signal>: dut=... ref=...' of each bench, verbatim),\n"
            "# base commit 03386fd, Verilator 5.042. A change in these lines is a change of behaviour.\n")
    for b in ("test_execute_compare", "test_memory_compare", "test_writeback_compare",
              "test_writeback_special_irq"):
        out = outputs.get("sv/" + b, "")
        diffs = [l for l in out.splitlines() if re.match(r"^\[\d+\] \S+ (FAIL|COMB) ", l)]
        m = re.search(r"Tests: +\d+ +Errors: +\d+", out)
        text += "\n## make test/sv/%s   (%s; %d difference lines)\n" % (b, m.group(0) if m else "?", len(diffs))
        text += "\n".join(diffs) + "\n"
    return text


def check_tests(c):
    meta = c.meta()
    outputs, same, created = {}, 0, False
    if os.path.exists(MYAPP):
        c.problem("%s exists (a program of your own?): the record's rows for make freertos-list and "
                  "for the template need the name; rename it and run the check again" % MYAPP)
    try:
        for i, f in enumerate(meta["figures"]):
            suite, cmd = f["suite"], f["command"]
            if test_patterns(suite) is None and suite not in ("campaign.py --set standard --list",
                                                                "vendored FreeRTOS checksums"):
                c.problem("no rule for the row '%s' of the record: update results/check.sh" % suite)
                continue
            if suite == "freertos template with IRQ (myapp)":
                if os.path.exists(MYAPP) and not created:
                    continue
                rc, out, dt = c.run(["make", "freertos-new", "NAME=myapp"], "%02d-freertos-new" % i)
                created = rc == 0
            name = "%02d-%s" % (i, re.sub(r"[^A-Za-z0-9_.-]+", "-", suite).strip("-"))
            # A FreeRTOS program prints its size line only when the command links it, and the
            # record was made in a new build directory: remove the program's ELF, so that the
            # command links it again (from the objects it already has) and prints the line
            for line in f["output"]:
                m = SIZE_LINE.match(line)
                elf = os.path.join(BUILD, "test", "freertos", m.group(1), "out.elf") if m else None
                if elf and os.path.exists(elf):
                    os.remove(elf)
            rc, out, dt = c.run(cmd, name, expect_rc=int(f["exit_status"]))
            if suite == "freertos template with IRQ (myapp)" and created:
                shutil.rmtree(MYAPP, ignore_errors=True)
                created = False
            outputs[suite] = out
            want, got = [norm(l) for l in f["output"]], [norm(l) for l in test_output(suite, out)]
            if want == got:
                same += 1
            else:
                c.problem("%s: the output differs from the record (log: %s)" % (suite, rel(c.log(name))),
                          diff_lines(want, got))
    finally:
        if created:
            shutil.rmtree(MYAPP, ignore_errors=True)
    c.compared.append("%d of %d outputs" % (same, len(meta["figures"])))
    # baseline-diffs.txt without its header comment (which names the record's base commit)
    stored = [l for l in read(os.path.join(c.record, "baseline-diffs.txt")).splitlines()
              if not re.match(r"#( |$)", l)]
    now = [l for l in baseline_text(outputs).splitlines() if not re.match(r"#( |$)", l)]
    n = sum(1 for l in stored if l.startswith("["))
    if now == stored:
        c.compared.append("%d baseline differences" % n)
    else:
        c.problem("the difference lines of the four golden-comparison benches differ from "
                  "baseline-diffs.txt", diff_lines(stored, now))
    images = {}
    for line in read(os.path.join(c.record, "images.sha256")).splitlines():
        if line.strip() and not line.startswith("#"):
            h, p = line.split()
            images[p] = h
    c.compare_images(images)


# ---- trapsweep ------------------------------------------------------------------------------

PROGRAM = re.compile(r"^(\S+) \| (dut:.*)$")
ISS = re.compile(r"ISS\[(dut|ref)\] groups_bad=(\d+) violations=(\d+) notes=(\d+)")
DVG = re.compile(r"DUT-vs-golden: (\d+) iterations, (\d+) differ")
SWEEP_COLUMNS = ["program", "family", "dut_iss_consistent", "golden_iss_consistent", "dut_groups_bad",
                 "dut_violations", "dut_notes", "golden_groups_bad", "golden_violations", "golden_notes",
                 "dut_iterations", "dut_trap_entries", "dut_cycles", "golden_iterations",
                 "golden_trap_entries", "golden_cycles", "dut_vs_golden_iterations", "dut_vs_golden_differ"]
FUZZ = [("i", "101-160"), ("m", "201-240"), ("bp", "301-360"), ("mt", "401-430")]


def csv_text(header, rows):
    s = io.StringIO()
    w = csv.writer(s, lineterminator="\n")
    w.writerow(header)
    w.writerows(rows)
    return s.getvalue()


def trace_counts(sim_log):
    """Iteration headers (offset 0x00) and trap entries (offset 0x1C) of a run's trace"""
    it = tr = 0
    with open(sim_log, errors="replace") as f:
        for line in f:
            if line.startswith("TRACE "):
                p = line.split()
                if len(p) >= 4:
                    it += p[2] == "000"
                    tr += p[2] == "01c"
    return it, tr


def sweep_tables(out_dir):
    """results.csv and flags.txt of the trapsweep record, from the output directory of sweep.py run"""
    summary = read(os.path.join(out_dir, "summary.txt")).splitlines()
    first = {}
    for l in summary:
        m = PROGRAM.match(l)
        if m and m.group(1) not in first:
            first[m.group(1)] = l
    rows = []
    for r in json.load(open(os.path.join(out_dir, "results.json"))):
        line = first[r["program"]]
        iss = {m.group(1): m.groups()[1:] for m in ISS.finditer(line)}
        dvg = DVG.search(line)
        runs = {x["target"]: x for x in r["runs"]}
        d_it, d_tr = trace_counts(os.path.join(out_dir, r["program"], "dut", "sim.log"))
        g = ("", "", "")
        if "ref" in runs:
            g = trace_counts(os.path.join(out_dir, r["program"], "ref", "sim.log")) + (runs["ref"]["cycles"],)

        def v(t, i):
            return iss[t][i] if t in iss else ""
        rows.append([r["program"], r["family"], r.get("dut_ok"), r.get("ref_ok", "") if "ref" in runs else "",
                     v("dut", 0), v("dut", 1), v("dut", 2), v("ref", 0), v("ref", 1), v("ref", 2),
                     d_it, d_tr, runs["dut"]["cycles"], g[0], g[1], g[2],
                     dvg.group(1) if dvg else "", dvg.group(2) if dvg else ""])
    flags = []
    for l in first.values():
        if any(int(x[1]) or int(x[2]) for x in ISS.findall(l)):
            flags.append(l)
    flags.append("")
    flags += [l for l in summary if re.match(r"^   (dut|ref) (probe|VIOLATION)", l)]
    return csv_text(SWEEP_COLUMNS, rows), flags


def check_trapsweep(c, jobs):
    meta = c.meta()
    sweep = ["python3", "test/trapsweep/sweep.py"]
    outs = {}
    rc, out, dt = c.run(sweep + ["list"], "list")
    fams = re.findall(r"^(\S+)\s+(\d+) probes", out, re.M)
    got = "sweep.py list: %d families, %d probes, pre_i %s" % (
        len(fams), sum(int(n) for _, n in fams), dict(fams).get("pre_i", "-"))
    want = [f["output"] for f in meta["figures"]
            if isinstance(f.get("output"), str) and f["output"].startswith("sweep.py list:")]
    if want and want[0] != got:
        c.problem("probe list: '%s', recorded '%s'" % (got, want[0]))
    run_dir = os.path.join(LOGS, c.name, "run")
    rc, outs["run"], dt = c.run(sweep + ["run", "--jobs", str(jobs), "--out", run_dir], "run")
    for v, seeds in FUZZ:
        d = os.path.join(LOGS, c.name, "fuzz-" + v)
        rc, outs[v], dt = c.run(sweep + ["fuzz", "--seeds", seeds, "--variant", v, "--jobs", str(jobs),
                                         "--out", d], "fuzz-" + v)
    # the verdict lines quoted in the record
    n = 0
    for f in meta["figures"]:
        if not isinstance(f.get("output"), str):
            continue
        target = f["figure"].split()[1] if f["figure"].startswith("fuzz ") else "run"
        for part in f["output"].split(" / "):
            if part.startswith(("DUT: ", "golden: ")):
                n += 1
                if part not in outs.get(target, "").splitlines():
                    c.problem("'%s' is not in the output of the %s" % (part, "sweep" if target == "run"
                                                                       else "fuzz set " + target))
    c.compared.append("%d verdict lines" % n)
    # per-program table and flagged probes of the sweep, per-program table of the fuzz sets
    try:
        table, flags = sweep_tables(run_dir)
    except (OSError, KeyError, ValueError) as e:
        c.problem("no complete sweep output in %s (%s)" % (rel(run_dir), e))
        return
    stored = read(os.path.join(c.record, "results.csv"))
    if table == stored:
        c.compared.append("%d programs of the sweep" % (len(stored.splitlines()) - 1))
    else:
        c.problem("the per-program results of the sweep differ from results.csv",
                  diff_lines(stored.splitlines(), table.splitlines()))
    body = [l for l in read(os.path.join(c.record, "flags.txt")).splitlines() if not l.startswith("#")]
    while body and body[0] == "":
        body.pop(0)
    if flags == body:
        c.compared.append("%d flagged programs and %d flagged probe lines"
                          % (body.index(""), len(body) - body.index("") - 1))
    else:
        c.problem("the flagged programs and probes differ from flags.txt", diff_lines(body, flags))
    rows = []
    for v, seeds in FUZZ:
        try:
            for r in json.load(open(os.path.join(LOGS, c.name, "fuzz-" + v, "results.json"))):
                runs = {x["target"]: x for x in r["runs"]}
                rows.append([v, seeds, r["program"], r.get("dut_ok"),
                             r.get("ref_ok", "") if "ref" in runs else "", runs["dut"]["cycles"],
                             runs["ref"]["cycles"] if "ref" in runs else ""])
        except (OSError, ValueError) as e:
            c.problem("no results of the fuzz set %s (%s)" % (v, e))
    fuzz = csv_text(["variant", "seeds", "program", "dut_iss_consistent", "golden_iss_consistent",
                     "dut_cycles", "golden_cycles"], rows)
    stored = read(os.path.join(c.record, "fuzz.csv"))
    if fuzz == stored:
        c.compared.append("%d fuzz programs" % (len(stored.splitlines()) - 1))
    else:
        c.problem("the fuzz results differ from fuzz.csv", diff_lines(stored.splitlines(), fuzz.splitlines()))


# ---- FreeRTOS campaigns ---------------------------------------------------------------------

def check_campaign(c, args):
    meta = c.meta()
    out_dir = os.path.join(LOGS, c.name, "out")
    rc, out, dt = c.run(["python3", "test/freertos/campaign.py"] + args +
                        ["--out", out_dir, "--compare", os.path.join(c.record, "results.csv")], "campaign")
    verdict = [l for l in out.splitlines() if l.startswith("COMPARE RESULT:")]
    if not verdict or not verdict[-1].startswith("COMPARE RESULT: IDENTICAL"):
        c.problem(verdict[-1] if verdict else "no COMPARE RESULT line (log: %s)" % rel(c.log("campaign")))
    figures = meta.get("figures")
    want = figures.get("campaign_result") if isinstance(figures, dict) else None
    if want and want not in out.splitlines():
        c.problem("'%s' is not in the output" % want)
    m = re.search(r"in common: (\d+)", out)
    c.compared.append("%s runs, every deterministic column" % (m.group(1) if m else "?"))


def check_validate(c, jobs):
    check_campaign(c, ["--set", "validate", "--seeds", "2", "--strict", "--jobs", str(jobs)])


def check_suite(c, jobs):
    check_campaign(c, ["--suite", "sep2026", "--jobs", str(jobs), "--wall-limit", "0"])


# ---- formal ---------------------------------------------------------------------------------

def check_formal(c):
    meta = c.meta()
    say("   $ make formal")
    rc, out, dt = run(["make", "formal"], c.log("formal"))
    if "FORMAL RESULT: FAIL (missing tools)" in out:
        c.not_run = "the formal tools are not installed: formal/README.md, Tools"
        say("     NOT RUN: " + c.not_run)
        return
    if rc != 0:
        c.problem("'make formal' exited with status %d, recorded 0 (log: %s)" % (rc, rel(c.log("formal"))))
    want = [l for l in meta["verbatim"]["default"] if not l.startswith("real")]
    lines = [l.rstrip() for l in out.splitlines()]
    missing = [l for l in want if l not in lines]
    for l in missing:
        c.problem("'%s' is not in the output" % l)
    c.compared.append("%d of %d summary lines" % (len(want) - len(missing), len(want)))


# ---- main -----------------------------------------------------------------------------------

CHECKS = [
    ("zba", "zba", "make bench-zba at -O2, -Os and -O0", "seconds"),
    ("m-unit-cycles", "m-unit-cycles", "make bench-mcost", "seconds"),
    ("fencei-window", "fencei-window", "make bench-fencei-window", "seconds"),
    ("tests", "tests", "every suite of docs/VERIFICATION.md (55 commands)", "3 to 6 minutes"),
    ("trapsweep", "trapsweep", "sweep.py list, run and the fuzz sets i, m, bp, mt", "under 2 minutes"),
    ("freertos-validate", "freertos-validate", "campaign.py --set validate --seeds 2 --strict --compare",
     "under 2 minutes"),
    ("freertos-campaign", "freertos-campaign", "campaign.py --suite sep2026 --wall-limit 0 --compare",
     "about 80 minutes with --jobs 12"),
    ("formal", "formal", "make formal (needs the formal tools)", "about a minute"),
]
DEFAULT = ["zba", "m-unit-cycles", "fencei-window", "tests", "trapsweep", "freertos-validate"]
# the formal record is repeatable only where the formal tools are installed
STATUSES = {"formal": ("needs formal tools", "repeatable")}


def tool(cmd):
    try:
        p = subprocess.run(cmd, env=ENV, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, universal_newlines=True)
        return p.stdout.strip().splitlines()[0] if p.stdout.strip() else "(no output)"
    except OSError:
        return "(not found)"


def inputs_note(base):
    """Whether the simulated hardware, the C runtime and the FreeRTOS sources differ from the
    records' base commit (a changed program shows in the sha256 of its image)"""
    paths = ["rtl", "lib", "defines", "sim", "ref", "std", "third_party/freertos"]
    try:
        subprocess.run(["git", "cat-file", "-e", base + "^{commit}"], env=ENV, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.CalledProcessError):
        return "not a git checkout with commit %s: inputs not compared" % base[:7]
    changed = []
    for p in paths:
        d = subprocess.run(["git", "diff", "--quiet", base, "--", p], env=ENV, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL).returncode
        if d:
            changed.append(p)
    if not changed:
        return "%s as at %s, the records' base commit" % (", ".join(paths), base[:7])
    return ("differ from %s, the records' base commit, in: %s (the records name the files they used)"
            % (base[:7], ", ".join(changed)))


def main():
    ap = argparse.ArgumentParser(
        prog="results/check.sh",
        description="Re-runs the repeatable records of results/ and compares the output with the "
                    "stored values. Ends with CHECK RESULTS: PASS or FAIL. Guide: results/README.md.")
    ap.add_argument("checks", nargs="*", metavar="CHECK", help="checks to run (default: %s)" % " ".join(DEFAULT))
    ap.add_argument("--jobs", type=int, default=4,
                    help="parallel simulations of the trap sweep and the campaigns (default 4)")
    ap.add_argument("--campaign", action="store_true",
                    help="also re-run the 794-run campaign (about 80 minutes with --jobs 12)")
    ap.add_argument("--formal", action="store_true", help="also run make formal (needs the formal tools)")
    ap.add_argument("--list", action="store_true", help="list the checks and their records, run nothing")
    a = ap.parse_args()
    names = [n for n, _, _, _ in CHECKS]
    unknown = [n for n in a.checks if n not in names]
    if unknown:
        ap.error("unknown check %s (checks: %s)" % (", ".join(unknown), ", ".join(names)))
    if a.jobs < 1:
        ap.error("--jobs must be at least 1")
    selected = (list(a.checks) or list(DEFAULT)) + (["freertos-campaign"] if a.campaign else []) + \
        (["formal"] if a.formal else [])

    checks = [Check(n, t, d) for n, t, d, _ in CHECKS if n in selected]
    if a.list:
        for c in [Check(n, t, d) for n, t, d, _ in CHECKS]:
            dur = [x[3] for x in CHECKS if x[0] == c.name][0]
            say("%-18s %s" % (c.name, c.title))
            say("%-18s %s%s" % ("", dur, "" if c.name in DEFAULT else
                                "; only when named, or with --%s"
                                % ("campaign" if c.name == "freertos-campaign" else "formal")))
            say("%-18s record: %s" % ("", c.record or "(none)"))
        return 0

    tests_meta = json.load(open(os.path.join(newest_record("tests"), "meta.json"))) if newest_record("tests") else {}
    say("results/check.sh: the repeatable records of results/, re-run and compared with the stored values")
    say("  build directory: " + BUILD_NAME + "/")
    say("  logs:            " + BUILD_NAME + "/check-results/")
    tools = [("verilator", ["verilator", "--version"]),
             ("gcc", ["/opt/riscv32i/bin/riscv32-unknown-elf-gcc", "--version"]),
             ("python", [sys.executable, "--version"])]
    rec_tools = tests_meta.get("tools", {})
    for key, cmd in tools:
        now = tool(cmd)
        note = "" if not rec_tools.get(key) or rec_tools[key] == now else "  (records: %s)" % rec_tools[key]
        say("  %-16s %s%s" % (key + ":", now, note))
    if tests_meta.get("base_commit"):
        say("  inputs:          " + inputs_note(tests_meta["base_commit"]))
    if IGNORED:
        say("  ignored:         %s (the records use the vendored sources in third_party/freertos)"
            % ", ".join(IGNORED))

    interrupted = False

    def stop(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGHUP, stop)
    t_all = time.time()
    try:
        for c in checks:
            say("")
            if not c.record:
                say("== %s: no repeatable record under results/%s/" % (c.name, c.topic))
                c.problems.append("no repeatable record")
                continue
            say("== %s: %s, compared with %s" % (c.name, c.title, c.record))
            t0 = time.time()
            if c.name == "zba":
                check_zba(c)
            elif c.name == "m-unit-cycles":
                check_mcost(c)
            elif c.name == "fencei-window":
                check_fencei(c)
            elif c.name == "tests":
                check_tests(c)
            elif c.name == "trapsweep":
                check_trapsweep(c, a.jobs)
            elif c.name == "freertos-validate":
                check_validate(c, a.jobs)
            elif c.name == "freertos-campaign":
                check_suite(c, a.jobs)
            elif c.name == "formal":
                check_formal(c)
            if c.not_run:
                say("   %s: NOT RUN (%.0f s)" % (c.name, time.time() - t0))
                continue
            say("   compared: %s" % (", ".join(c.compared) or "nothing"))
            say("   %s: %s (%.0f s)" % (c.name, "FAIL" if c.problems or not c.compared else "PASS",
                                     time.time() - t0))
    except KeyboardInterrupt:
        interrupted = True
        say("\n(interrupted)")
    if os.path.isdir(MYAPP) and not os.listdir(MYAPP):
        os.rmdir(MYAPP)

    say("")
    say("Summary (%.0f s):" % (time.time() - t_all))
    for c in checks:
        if c.not_run:
            state = "NOT RUN (%s)" % c.not_run
        elif c.problems:
            state = "FAIL (%d difference%s)" % (len(c.problems), "" if len(c.problems) == 1 else "s")
        else:
            state = "PASS" if c.compared else "not run"
        say("  %-18s %-46s %s" % (c.name, c.record or "-", state))
    skipped = [n for n, _, _, _ in CHECKS if n not in selected]
    if skipped:
        say("  not selected: %s; the records that need Vivado or are historical are listed in "
            "results/README.md" % ", ".join(skipped))
    failed = [c.name for c in checks if c.problems or not (c.compared or c.not_run)]
    not_run = [c.name for c in checks if c.not_run and not c.problems]
    if interrupted:
        say("CHECK RESULTS: FAIL (interrupted)")
        return 130
    if failed:
        say("CHECK RESULTS: FAIL (%d of %d checks differ from their records: %s)"
            % (len(failed), len(checks), ", ".join(failed)))
        return 1
    if not_run:
        say("CHECK RESULTS: FAIL (%d of %d checks could not be run: %s)"
            % (len(not_run), len(checks), ", ".join(not_run)))
        return 1
    say("CHECK RESULTS: PASS (%d of %d checks reproduce their records: %s)"
        % (len(checks), len(checks), ", ".join(c.name for c in checks)))
    return 0


sys.exit(main())
PYTHON
