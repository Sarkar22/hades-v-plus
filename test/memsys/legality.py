#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""legality.py -- the refusals, negative builds and option checks of the cached configurations.

    python3 test/memsys/legality.py list               every case, by group
    python3 test/memsys/legality.py run [<group>...] [--only REGEX] [--out DIR] [--jobs N]

Groups (each case passes or fails on its own; the last line is 'LEGALITY: PASS (<n> cases)' or
'LEGALITY: FAIL (<k> of <n> cases failed)'):

  make-options   the Makefile options ICACHE and LINE: legal values and their configuration names,
                 defines and descriptions (make sim-config), the environment for scripts
                 (HADES_ICACHE, HADES_LINE), and every refusal: LINE without a non-zero ICACHE,
                 illegal ICACHE or LINE values (also 00512, +512, 512.0), MEM_ONLY with ICACHE,
                 DCACHE with any value; the 254-cycle data limit only without a cache; synthesis
                 refused with any configuration (make -n: nothing is run)
  build-checks   negative builds that call Verilator directly with explicit parameters, where make
                 refuses first: the elaboration checks of icache (BYTES, LINE_BYTES, the window) and
                 cache_ram (WIDTH, DEPTH), and of the cached branch of rtl/mcu.sv (HADES_SLOW_MEM)
  run-options    the time-0 checks of a cached simulator: +mem_only refused on the one memory port,
                 +reset_at (syntax, strictly ascending, neighbours at least 2 cycles apart),
                 +retired_every > 0, +ram_words inside the RAM; no 254-cycle limit with a cache; the
                 configuration lines (CACHE, SLOW MEMORY memory port)
  resets         +reset_at gives one RESET line per entry, in a cached and in an uncached
                 slow-memory simulator, on both CPUs; the delay from the requested cycle to the
                 reset cycle (the number printed in the RESET line) is reported
  cycle-limit    for every latency profile the printed default cycle limit of a cached run equals
                 100000 * (1 + max(R, D)) and programs.py's limit for the same run; +timeout sets it
  simulators     the small and the large cache build for both CPUs as plain, console and FreeRTOS
                 model simulators, with SCOREBOARD=0, SCOREBOARD=1 and BUSHASH=1; in sim/top.sv every
                 reference to a memory wrapper lies in the branch of its configuration
  bench          the I-cache bench's negative cases (+negative=<case>) each stop with their message
                 and a non-zero exit; +compare=0 ends with 'ICACHE BENCH: COMPARE OFF' and a non-zero
                 exit

Messages are matched by regular expressions: a check passes when its run stops with a matching
line. The expressions follow the rules of the cache documentation (each message names the option or
parameter, its value and the rule); those of the bench's negative cases name the assertion of the
RTL that must stop the run, in its own wording.
"""
import argparse
import concurrent.futures as cf
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.dont_write_bytecode = True

DEFINES = ["defines/csr.sv", "defines/op.sv", "defines/instruction.sv", "defines/pipeline_status.sv",
           "defines/constants.sv", "defines/forwarding.sv", "defines/clk_params.sv", "defines/bpredict.sv"]


def env():
    return {k: v for k, v in os.environ.items() if not k.startswith("HADES_")}


def make(args, cwd=REPO):
    r = subprocess.run(["make", "-s", "--no-print-directory", "-C", REPO] + args, cwd=cwd, env=env(),
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
    return r.returncode, r.stdout


# ------------------------------------------------------------------------------ the cases
CASES = []


def case(group, name, fn, **kw):
    CASES.append(dict(group=group, name=name, fn=fn, kw=kw))


def refused(vars_, message, goal="sim-config"):
    def fn(tmp):
        args = (["-n", goal] if goal != "sim-config" else [goal]) + vars_
        rc, out = make(args)
        ok = rc != 0 and re.search(message, out, re.I | re.S) is not None
        return ok, (f"exit {rc}: " + (out.strip().splitlines() or ["(no output)"])[-1])[:240]
    return fn


def accepted(vars_, name=None, defines=(), text=(), environment=()):
    def fn(tmp):
        rc, out = make(["sim-config"] + vars_)
        problems = []
        if rc:
            problems.append(f"refused (exit {rc}): {out.strip()[-200:]}")
        else:
            m = re.search(r"simulator configuration: (\S+)", out)
            if name and (not m or m.group(1) != name):
                problems.append(f"name {m.group(1) if m else '?'}, expected {name}")
            problems += [f"no define {d}" for d in defines if d not in out]
            problems += [f"no '{t}' in the description" for t in text if t not in out]
            problems += [f"no {e} in the environment line" for e in environment if e not in out]
        return not problems, "; ".join(problems) or (out.splitlines()[0][:200] if out else "")
    return fn


ICACHE_TEXT = "one memory port shared with the data side; RAM exempt from the interconnect timeout;"
for vars_, name, size, line in (
        (["ICACHE=512"], "mem0-i512-l16", 512, 16),
        (["ICACHE=512", "MEM_LAT=2"], "mem2-i512-l16", 512, 16),
        (["ICACHE=512", "MEM_LAT=1:8", "MEM_SEED=2"], "mem1_8-seed2-i512-l16", 512, 16),
        (["ICACHE=512", "MEM_LAT=1:8", "MEM_BEAT_LAT=0"], "mem1_8-beat0-i512-l16", 512, 16),
        (["ICACHE=8192", "MEM_LAT=8:24", "MEM_WR_LAT=1:4", "MEM_BEAT_LAT=0"], "mem8_24-wr1_4-beat0-i8k-l16", 8192, 16),
        (["ICACHE=512", "LINE=8"], "mem0-i512-l8", 512, 8),
        (["ICACHE=512", "LINE=32"], "mem0-i512-l32", 512, 32),
        (["ICACHE=512", "LINE=64"], "mem0-i512-l64", 512, 64),
        (["ICACHE=128", "LINE=64"], "mem0-i128-l64", 128, 64),
        (["ICACHE=512", "MEM_LAT=300"], "mem300-i512-l16", 512, 16)):
    case("make-options", f"accepted: {' '.join(vars_)}",
         accepted(vars_, name, defines=("+define+HADES_SLOW_MEM", f"+define+HADES_ICACHE_BYTES={size}",
                                        f"+define+HADES_CACHE_LINE_BYTES={line}", "-y rtl/cache"),
                  text=(f"I-cache {size} bytes, {line}-byte lines;", ICACHE_TEXT),
                  environment=(f"HADES_ICACHE={size}",)))
case("make-options", "ICACHE=0 is no cache", accepted(["ICACHE=0"], "standard"))
for vars_, msg in (
        (["LINE=16"], r"LINE"), (["ICACHE=0", "LINE=16"], r"LINE"),
        (["ICACHE=00512"], r"ICACHE"), (["ICACHE=+512"], r"ICACHE"), (["ICACHE=512.0"], r"ICACHE"),
        (["ICACHE=500"], r"ICACHE.*power of two"), (["ICACHE=16"], r"ICACHE.*(two lines|at least)"),
        (["ICACHE=abc"], r"ICACHE"), (["ICACHE=-512"], r"ICACHE"),
        (["ICACHE=512", "LINE=24"], r"LINE"), (["ICACHE=512", "LINE=4"], r"LINE"),
        (["ICACHE=512", "LINE=128"], r"LINE"), (["ICACHE=64", "LINE=64"], r"ICACHE.*(two lines|at least)"),
        (["ICACHE=512", "MEM_ONLY=fetch"], r"MEM_ONLY"), (["ICACHE=512", "MEM_ONLY=data"], r"MEM_ONLY"),
        (["DCACHE=512"], r"DCACHE.*docs/CACHES\.md"), (["DCACHE=0"], r"DCACHE"),
        (["ICACHE=512", "DCACHE=512"], r"DCACHE"),
        (["MEM_LAT=300"], r"254")):
    case("make-options", f"refused: {' '.join(vars_)}", refused(vars_, msg))
for vars_ in (["ICACHE=512"], ["ICACHE=8192", "MEM_LAT=2"], ["MEM_LAT=2"]):
    case("make-options", f"synthesis refused: {' '.join(vars_)}",
         refused(vars_, r"simulation only|synthesis", goal="synthesis"))
case("make-options", "make help lists ICACHE, LINE, formal-cache and the cached cycle limit",
     lambda tmp: (lambda rc_out: (all(w in rc_out[1] for w in ("ICACHE", "LINE", "formal-cache", "100000")),
                                  "make help"))(make(["help"])))


# ---- negative builds with Verilator, where make refuses first
WRAP_ICACHE = """
module legality_top;
    logic clk = 0, rst = 1;
    wishbone_interface cpu_bus();
    wishbone_interface mem_bus();
    logic mem_cont, ev_hit, ev_miss, ev_beat, ev_fill, ev_abandoned, ev_snoop_inval, ev_refill;
    icache #(.BYTES({bytes}), .LINE_BYTES({line}), .WINDOW_START({start}), .WINDOW_WORDS({words})) dut (
        .clk(clk), .rst(rst), .cpu(cpu_bus.slave), .mem(mem_bus.master), .mem_cont(mem_cont),
        .snoop_store(1'b0), .snoop_adr(32'b0), .ev_hit(ev_hit), .ev_miss(ev_miss), .ev_beat(ev_beat),
        .ev_fill(ev_fill), .ev_abandoned(ev_abandoned), .ev_snoop_inval(ev_snoop_inval), .ev_refill(ev_refill));
    initial begin
        #10;
        $display("LEGALITY: ELABORATED");
        $finish;
    end
    always #1 clk = ~clk;
endmodule
"""
WRAP_RAM = """
module legality_top;
    logic clk = 0;
    logic [{width} - 1:0] rd_a, rd_b;
    cache_ram #(.WIDTH({width}), .DEPTH({depth}), .SNOOP_PORT(1)) dut (
        .clk(clk), .a_adr('0), .a_rdata(rd_a), .a_we(1'b0), .a_wdata('0), .b_adr('0), .b_rdata(rd_b));
    initial begin
        #10;
        $display("LEGALITY: ELABORATED");
        $finish;
    end
endmodule
"""


def verilated(wrapper, message, files, defines=()):
    def fn(tmp):
        d = tempfile.mkdtemp(dir=tmp)
        w = os.path.join(d, "legality_top.sv")
        with open(w, "w") as f:
            f.write(wrapper)
        cmd = ["verilator", "--binary", "--timing", "-Wno-fatal", "-Wno-lint", "-Wno-style", "-j", "2",
               "--top-module", "legality_top", "-Mdir", os.path.join(d, "obj")] + list(defines) + \
            [os.path.join(REPO, f) for f in DEFINES + ["lib/wishbone/wishbone_interface.sv"] + list(files)] + [w]
        r = subprocess.run(cmd, cwd=d, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
        out = r.stdout
        if r.returncode == 0:
            s = subprocess.run([os.path.join(d, "obj", "Vlegality_top")], cwd=d, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, errors="replace")
            out += s.stdout
        hit = next((l for l in out.splitlines() if re.search(message, l) and ("%" in l or "Fatal" in l or "Error" in l)),
                   None)
        stopped = "LEGALITY: ELABORATED" not in out
        return bool(hit) and stopped, (hit or ("elaborated and ran" if not stopped else out.strip()[-200:]))[:240]
    return fn


ICACHE_FILES = ("rtl/cache/cache_ram.sv", "rtl/cache/icache.sv")
for desc, p, msg in (
        ("BYTES not a power of two", dict(bytes=500, line=16, start="32'h10000", words="32'h2000"), r"BYTES"),
        ("BYTES one line", dict(bytes=16, line=16, start="32'h10000", words="32'h2000"), r"BYTES"),
        ("LINE_BYTES 12", dict(bytes=512, line=12, start="32'h10000", words="32'h2000"), r"LINE_BYTES"),
        ("LINE_BYTES 128", dict(bytes=512, line=128, start="32'h10000", words="32'h2000"), r"LINE_BYTES"),
        ("LINE_BYTES 4", dict(bytes=512, line=4, start="32'h10000", words="32'h2000"), r"LINE_BYTES"),
        ("WINDOW_START not line-aligned", dict(bytes=512, line=16, start="32'h10001", words="32'h2000"),
         r"WINDOW_START"),
        ("WINDOW_WORDS not line-aligned", dict(bytes=512, line=16, start="32'h10000", words="32'h2002"),
         r"WINDOW_WORDS"),
        ("WINDOW_WORDS 0", dict(bytes=512, line=16, start="32'h10000", words="32'h0"), r"WINDOW_WORDS"),
        ("window beyond 2**30 words", dict(bytes=512, line=16, start="32'h3FFF_FF00", words="32'h200"),
         r"WINDOW")):
    # (The check that the tag has at least one bit has no negative case: BYTES is an int unsigned,
    # so its largest power of two is 2**31, which leaves 32 - 31 = 1 tag bit.)
    case("build-checks", f"icache: {desc}", verilated(WRAP_ICACHE.format(**p), msg, ICACHE_FILES))
case("build-checks", "icache: legal parameters elaborate",
     lambda tmp: (lambda r: (not r[0] and "elaborated" in r[1], r[1]))(
         verilated(WRAP_ICACHE.format(bytes=512, line=16, start="32'h10000", words="32'h2000"), r"$^",
                   ICACHE_FILES)(tmp)))
for desc, p, msg in (("WIDTH 0", dict(width=0, depth=4), r"WIDTH"), ("DEPTH 3", dict(depth=3, width=8), r"DEPTH"),
                     ("DEPTH 1", dict(depth=1, width=8), r"DEPTH")):
    case("build-checks", f"cache_ram: {desc}", verilated(WRAP_RAM.format(**p), msg, ("rtl/cache/cache_ram.sv",)))


def mcu_without_slow_mem(tmp):
    """The cached branch of rtl/mcu.sv stops at time 0 if HADES_SLOW_MEM is not defined (make always
    defines both): the simulator built with HADES_ICACHE_BYTES alone."""
    d = tempfile.mkdtemp(dir=tmp)
    r = subprocess.run(["verilator", "--binary", "--timing", "--assert", "-Wno-fatal", "-j", "2", "-f",
                        os.path.join(REPO, "sim", "files.txt"), "-y", os.path.join(REPO, "rtl", "cache"),
                        "+define+HADES_ICACHE_BYTES=512", "+define+HADES_CACHE_LINE_BYTES=16",
                        "--top-module", "top", "-Mdir", os.path.join(d, "obj"), os.path.join(REPO, "sim", "top.sv")],
                       cwd=REPO, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
    out = r.stdout
    if r.returncode == 0:
        s = subprocess.run([os.path.join(d, "obj", "Vtop"), "+nodump", "+timeout=10"], cwd=d, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True, errors="replace")
        out += s.stdout
    hit = next((l for l in out.splitlines() if "HADES_SLOW_MEM" in l and ("%" in l or "Fatal" in l)), None)
    return hit is not None, (hit or out.strip()[-200:])[:240]


case("build-checks", "rtl/mcu.sv: a cache without HADES_SLOW_MEM", mcu_without_slow_mem)


# ---- a cached simulator's run-time options
def sim_of(vars_, cpu="dut"):
    model = {"dut": "dut", "golden": "ref"}[cpu]
    rc, out = make(["frtos-model", f"FRTOS_CPU={model}", "FRTOS_RAM_KB=32"] + vars_)
    if rc:
        return None, out
    rc, cfg = make(["sim-config"] + vars_)
    bdir = re.search(r"build directory:\s+(\S+)", cfg).group(1)
    return os.path.join(REPO, bdir, "frtos-model", f"{model}-32k", "top"), os.path.join(REPO, bdir)


def program(vars_, prog):
    rc, cfg = make(["sim-config"] + vars_)
    bdir = re.search(r"build directory:\s+(\S+)", cfg).group(1)
    make([os.path.join(bdir, "test", prog, "init.mem")] + vars_)
    return os.path.join(REPO, bdir, "test", prog, "init.mem")


def sim_run(vars_, plusargs, prog="asm/fencei", cpu="dut", tmp=None):
    sim, info = sim_of(vars_, cpu)
    if sim is None:
        return None, f"the simulator does not build: {info.strip()[-200:]}"
    d = tempfile.mkdtemp(dir=tmp)
    shutil.copy(program(vars_, prog), d)
    r = subprocess.run([sim, "+nodump"] + list(plusargs), cwd=d, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       text=True, errors="replace")
    return r.returncode, r.stdout


def run_refused(vars_, plusargs, message):
    def fn(tmp):
        rc, out = sim_run(vars_, plusargs, tmp=tmp)
        if rc is None:
            return False, out
        hit = next((l for l in out.splitlines() if re.search(message, l) and "%" in l), None)
        return hit is not None, (hit or f"not refused (exit {rc})")[:240]
    return fn


SMALL_LAT2 = ["ICACHE=512", "MEM_LAT=2"]
for plusargs, msg in (
        (["+mem_only=fetch"], r"mem_only"), (["+mem_only=data"], r"mem_only"),
        (["+reset_at=100,50"], r"reset_at"), (["+reset_at=100,101"], r"reset_at"), (["+reset_at=abc"], r"reset_at"),
        (["+reset_at=100,100"], r"reset_at"), (["+retired_every=0"], r"retired_every"),
        (["+ram_words=0x100"], r"ram_words"), (["+ram_words=0x48000"], r"ram_words")):
    case("run-options", f"refused: {' '.join(plusargs)}", run_refused(SMALL_LAT2, plusargs, msg))


def lines_present(tmp):
    rc, out = sim_run(SMALL_LAT2, [], tmp=tmp)
    if rc is None:
        return False, out
    need = [r"^CACHE I-cache 512 bytes, 16-byte lines, 32 sets", r"^SLOW MEMORY memory port: read latency 2, write "
            r"latency 2, burst beats off \(cache refill blocks only\)", r"^SLOW MEMORY cycle limit 1300000",
            r"^CACHE_STATS cycles=\d+"]
    missing = [n for n in need if not re.search(n, out, re.M)]
    once = len(re.findall(r"^SLOW MEMORY memory port:", out, re.M)) == 1
    return rc == 0 and not missing and once, "; ".join(missing) or ("ok" if once else "not exactly one memory port line")


case("run-options", "the configuration lines of a cached run", lines_present)


def no_254_limit(tmp):
    rc, out = sim_run(["ICACHE=512", "MEM_LAT=300"], [], tmp=tmp)
    if rc is None:
        return False, out
    ok = rc == 0 and "SCOREBOARD: PASS" in out and not re.search(r"%(Fatal|Error)", out)
    return ok, f"exit {rc}; " + ("SCOREBOARD: PASS" if "SCOREBOARD: PASS" in out else out.strip()[-160:])


case("run-options", "no 254-cycle limit with a cache (MEM_LAT=300 runs)", no_254_limit)


# ---- +reset_at
def reset_lines(vars_, cpu):
    def fn(tmp):
        rc, out = sim_run(vars_, ["+reset_at=400,800"], prog="memsys/stores", cpu=cpu, tmp=tmp)
        if rc is None:
            return False, out
        got = [(int(a), int(b)) for a, b in re.findall(r"^RESET at cycle (\d+) \(\+reset_at=(\d+)\)", out, re.M)]
        ok = [b for _, b in got] == [400, 800] and len({a - b for a, b in got}) == 1 and \
            "SCOREBOARD: PASS" in out and not re.search(r"%(Fatal|Error)", out)
        delay = got[0][0] - got[0][1] if got else None
        return ok, f"RESET lines {got}; delay {delay} cycles; " + ("SCOREBOARD: PASS" if "SCOREBOARD: PASS" in out
                                                                    else "no SCOREBOARD: PASS")
    return fn


for vars_ in (SMALL_LAT2, ["MEM_LAT=2"]):
    for cpu in ("dut", "golden"):
        case("resets", f"+reset_at=400,800: {' '.join(vars_)}, {cpu}", reset_lines(vars_, cpu))

# ---- the default cycle limit of cached runs
LIMITS = [(["ICACHE=512"], 500000), (["ICACHE=512", "MEM_LAT=2"], 1300000),
          (["ICACHE=512", "MEM_LAT=1:8", "MEM_SEED=1"], 3700000), (["ICACHE=512", "MEM_LAT=1:8", "MEM_SEED=2"], 3700000),
          (["ICACHE=512", "MEM_LAT=1:8", "MEM_SEED=3"], 3700000), (["ICACHE=512", "MEM_LAT=1:8", "MEM_BEAT_LAT=0"], 1300000),
          (["ICACHE=512", "MEM_LAT=1:64"], 26100000),
          (["ICACHE=8192", "MEM_LAT=8:24", "MEM_WR_LAT=1:4", "MEM_BEAT_LAT=0"], 2900000)]


def limit_case(vars_, want):
    def fn(tmp):
        rc, out = sim_run(vars_, [], tmp=tmp)
        if rc is None:
            return False, out
        m = re.search(r"^SLOW MEMORY cycle limit (\d+): 100000 times 1 \+ the longest refill or data transfer", out, re.M)
        sys.path.insert(0, HERE)
        import programs
        sys.path.pop(0)
        rcfg, cfg = make(["sim-config"] + vars_)
        defs = re.search(r"Verilator defines:\s+(.*)", cfg).group(1)
        pl = programs.cache_profile(defs, [])
        got = int(m.group(1)) if m else None
        ok = got == want and pl and pl["limit"] == want
        return ok, f"printed {got}, programs.py {pl['limit'] if pl else None}, expected {want}"
    return fn


for vars_, want in LIMITS:
    case("cycle-limit", f"{' '.join(vars_)}: {want}", limit_case(vars_, want))


def timeout_overrides(tmp):
    rc, out = sim_run(SMALL_LAT2, ["+timeout=50"], prog="memsys/stores", tmp=tmp)
    if rc is None:
        return False, out
    return "Simulation timeout!" in out, "+timeout=50: " + ("timed out" if "Simulation timeout!" in out else "ran on")


case("cycle-limit", "+timeout sets the limit", timeout_overrides)


# ---- the simulators of the cached configurations
def builds(vars_, cpu, kind):
    def fn(tmp):
        model = {"dut": "dut", "golden": "ref"}[cpu]
        rc, cfg = make(["sim-config"] + vars_)
        m = re.search(r"build directory:\s+(\S+)", cfg)
        if rc or not m:
            return False, f"sim-config: {cfg.strip()[-200:]}"
        bdir = os.path.join(REPO, m.group(1))
        target = {"plain": os.path.join(bdir, "sim", "top") if cpu == "dut" else None,
                  "freertos": os.path.join(bdir, "frtos-model", f"{model}-32k", "top"),
                  "console": os.path.join(bdir, "frtos-model", f"{model}-32k-console", "top")}[kind]
        if target is None:
            return True, "(the plain simulator is HaDes-V+ only)"
        rc, out = make([os.path.relpath(target, REPO) if target.startswith(REPO) else target] + vars_ +
                       (["FRTOS_RAM_KB=32"] if kind != "plain" else []))
        return rc == 0 and os.path.exists(target), f"exit {rc}" + ("" if rc == 0 else f": {out.strip()[-200:]}")
    return fn


for size in ("512", "8192"):
    for opt in (["SCOREBOARD=0"], ["SCOREBOARD=1"], ["BUSHASH=1"]):
        for cpu in ("dut", "golden"):
            for kind in ("plain", "freertos", "console"):
                if kind == "plain" and cpu == "golden":
                    continue
                case("simulators", f"ICACHE={size} {opt[0]}: {kind} {cpu}", builds([f"ICACHE={size}"] + opt, cpu, kind))


def wrapper_references(tmp):
    """Every line of sim/top.sv that names a memory wrapper instance lies in the branch of its
    configuration: mcu.memory_delay under `ifdef HADES_ICACHE_BYTES, the two uncached instances (fetch and data) under the
    `elsif HADES_SLOW_MEM that follows it."""
    stack, bad, seen = [], [], 0
    for n, l in enumerate(open(os.path.join(REPO, "sim", "top.sv")), start=1):
        t = l.strip()
        m = re.match(r"`(ifdef|ifndef|elsif|else|endif)\b\s*(\w*)", t)
        if m:
            k, name = m.groups()
            if k in ("ifdef", "ifndef"):
                stack.append((k, name))
            elif k == "elsif":
                stack[-1] = ("ifdef", name)
            elif k == "else":
                stack[-1] = ("else", stack[-1][1])
            else:
                stack.pop()
            continue
        branch = stack[-1] if stack else None
        if re.search(r"\bmcu\.memory_delay\b", l):
            seen += 1
            if branch != ("ifdef", "HADES_ICACHE_BYTES"):
                bad.append(f"line {n}: mcu.memory_delay in {branch}")
        if re.search(r"\bmcu\.(fetch|data)_memory_delay\b", l):
            seen += 1
            if branch != ("ifdef", "HADES_SLOW_MEM") or not any(b == ("ifdef", "HADES_ICACHE_BYTES") for b in stack[:-1]) \
                    and not wrapper_elsif(n):
                bad.append(f"line {n}: an uncached wrapper outside an `elsif HADES_SLOW_MEM after `ifdef HADES_ICACHE_BYTES")
    return not bad and seen > 0, "; ".join(bad[:4]) or f"{seen} references, each in its branch"


def wrapper_elsif(line_no):
    """Whether the innermost branch around <line_no> of sim/top.sv is an `elsif HADES_SLOW_MEM."""
    lines = open(os.path.join(REPO, "sim", "top.sv")).read().splitlines()[:line_no]
    depth = 0
    for l in reversed(lines):
        t = l.strip()
        if t.startswith("`endif"):
            depth += 1
        elif t.startswith(("`ifdef", "`ifndef")):
            if depth == 0:
                return False
            depth -= 1
        elif t.startswith("`elsif") and depth == 0:
            return "HADES_SLOW_MEM" in t
    return False


case("simulators", "sim/top.sv: every memory-wrapper reference in its branch", wrapper_references)


# ---- the I-cache bench's negative cases
BENCH_CASES = {"fetch-write": r"icache: the fetch port presents we=1",
               "request-change": r"mem_arbiter: the granted data request .* changed before its answer",
               "ack-err": r"(mem_arbiter|icache): ack and err together",
               "refill-err": r"icache: the memory answered err to the refill",
               "spontaneous-answer": r"mem_arbiter: the memory answered at cycle \d+ .*no side is granted"}


def bench_case(name, message):
    def fn(tmp):
        top = os.path.join(REPO, "build", "test", "sv", "test_icache", "top")
        rc, out = make([os.path.relpath(top, REPO)])
        if rc:
            return False, f"the bench does not build: {out.strip()[-200:]}"
        r = subprocess.run([top, f"+negative={name}"] if name else [top, "+compare=0"], cwd=os.path.dirname(top),
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
        if not name:
            ok = r.returncode != 0 and "ICACHE BENCH: COMPARE OFF" in r.stdout and "ICACHE BENCH: PASS" not in r.stdout
            return ok, f"exit {r.returncode}; " + ("COMPARE OFF" if "COMPARE OFF" in r.stdout else r.stdout.strip()[-160:])
        hit = next((l for l in r.stdout.splitlines() if re.search(message, l, re.I) and "%" in l), None)
        return r.returncode != 0 and hit is not None, (hit or f"exit {r.returncode}: {r.stdout.strip()[-160:]}")[:240]
    return fn


for n, msg in BENCH_CASES.items():
    case("bench", f"+negative={n}", bench_case(n, msg))
case("bench", "+compare=0 ends with COMPARE OFF", bench_case(None, None))


# ------------------------------------------------------------------------------ main
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list")
    p = sub.add_parser("run")
    p.add_argument("groups", nargs="*")
    p.add_argument("--only", default="")
    p.add_argument("--jobs", type=int, default=1, help="cases at a time (builds share make's directories: 1)")
    p.add_argument("--out", default=None, help="keep the temporary files here")
    a = ap.parse_args()
    if a.cmd == "list":
        group = None
        for c in CASES:
            if c["group"] != group:
                group = c["group"]
                print(f"{group}:")
            print(f"    {c['name']}")
        print(f"{len(CASES)} cases")
        return 0
    groups = a.groups or sorted({c["group"] for c in CASES}, key=[c["group"] for c in CASES].index)
    todo = [c for c in CASES if c["group"] in groups and re.search(a.only, f"{c['group']}: {c['name']}")]
    tmp = a.out or tempfile.mkdtemp(prefix="legality-")
    os.makedirs(tmp, exist_ok=True)
    rc, cfg = make(["sim-config", "ICACHE=512"])
    if "+define+HADES_ICACHE_BYTES=" not in cfg:
        print("NOTE: this tree's Makefile does not know ICACHE (make sim-config ICACHE=512 shows no cache): the "
              "cases of the cached configurations will fail")
    failed = 0

    def one(c):
        try:
            return c, c["fn"](tmp)
        except Exception as e:
            return c, (False, f"error: {e!r}")
    with cf.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        for c, (ok, why) in ex.map(one, todo):
            failed += not ok
            print(f"{'pass' if ok else 'FAIL'}  {c['group']}: {c['name']}: {why}", flush=True)
    if not a.out:
        shutil.rmtree(tmp, ignore_errors=True)
    print(f"LEGALITY: {'PASS' if not failed else 'FAIL'} ({failed} of {len(todo)} cases failed)" if failed else
          f"LEGALITY: PASS ({len(todo)} cases)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
