#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""sweep.py -- interrupt-offset sweeps and random programs for HaDes-V+, checked by an
independent instruction-set model (iss.py) and, where it applies, against the golden CPU.

  sweep.py list                                  families, probe counts, DUT-only marks
  sweep.py run  [--fam csr,exc|all] [--src ext,timer,both] [--targets dut,ref] [--no-mtvec]
                ('all' is every listed family; --fam ext, Zbb/Zbs/Zicond on the DUT, only when named)
  sweep.py fuzz --seeds 101-130 [--variant i|m|mt|bp|b] [--nseg 40]
  sweep.py file prog.s [prog2.s ...]              hand-written programs (probes.py trace protocol)
common options: --jobs N (6)  --out DIR (<build dir>/trapsweep/<mode>)  --tree ROOT (simulators from
another checkout; default: this repository)  --timeout CYCLES

Every program is assembled, run on the DUT (and on the golden CPU for the target list) with the
+trace bus snoop of sim/top.sv, and then
  * iss.py replays each run at the interrupt boundaries the RTL chose and checks every trap
    entry (mepc, mcause, mstatus, minstret), every result register and peripheral snapshot:
    'ISS[dut] groups_bad=0 violations=0' means the run is architecturally correct;
  * for DUT+golden, the per-iteration trace streams are compared ('mismatching' iterations are
    legitimate differences in *where* the interrupt was taken whenever both sides are
    ISS-consistent; the golden CPU samples interrupts one cycle later than the DUT).
Exit status: 0 if every DUT run completed and is ISS-consistent (the 'race' family's
bounded-latency flags excepted, see README), 1 otherwise.
"""
import argparse, concurrent.futures as cf, json, os, re, shutil, subprocess, sys, time, collections

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True     # no __pycache__ in the source tree
import iss, probes  # noqa: E402

TC = os.environ.get("RISCV_PREFIX", "/opt/riscv32i/bin/riscv32-unknown-elf-")
MARCH = "rv32im_zba_zicsr_zifencei"
MAX_TEXT = 0x6c00          # program + data must stay below the stack and the trace window (0x47E00)

# Flags that are expected and allowed by the privileged spec (not counted as failures).
EXPECTED = {
    "race": "interrupt taken right after the store that cleared/disarmed its source retired "
            "(one-cycle line-to-trap latency; the spec allows a bounded latency, the handler sees "
            "a spurious interrupt)",
}
# Known deviations of the frozen golden CPU from the RISC-V spec (flagged on target 'ref' only).
GOLDEN_KNOWN = [
    (re.compile(r"csrrwi a1,\w+,(0x)?0\b"), "golden bug: CSRRWI rd,csr,0 returns 0 instead of the old CSR value"),
    (re.compile(r"csrr?[wsc]i? (\w+,)?mtvec"), "golden bug: an interrupt right after a retired csrw mtvec uses the OLD "
                           "vector (see test/asm/mtvecirq.s)"),
]


# ------------------------------------------------------------------------------ helpers
def sh(cmd, **kw):
    return subprocess.run(cmd, shell=True, check=True, **kw)


def tree_build(tree):
    """(build directory of `tree`, extra make arguments) -- follows the Makefile: <tree>/build
    by default; with HADES_BUILD_DIR set (relocated build, docs/FREERTOS.md) this repository
    builds there and another tree into $HADES_BUILD_DIR/other-trees/<tree name>."""
    bd = os.environ.get("HADES_BUILD_DIR")
    if not bd:
        return os.path.join(tree, "build"), []
    bd = os.path.abspath(bd)
    if os.path.realpath(tree) != os.path.realpath(REPO):
        bd = os.path.join(bd, "other-trees", os.path.basename(os.path.normpath(tree)))
    return bd, [f"BUILD_DIR={bd}"]


def build_sims(tree, targets, log):
    """Verilate the full-system simulators (DUT and/or golden CPU, 32 KiB RAM, +trace capable)."""
    sims = {}
    bdir, bargs = tree_build(tree)
    for t in targets:
        cpu = {"dut": "dut", "ref": "ref"}[t]
        print(f"building {t} simulator in {tree} ...", flush=True)
        with open(log, "a") as f:
            subprocess.run(["make", "-s", "-C", tree, "frtos-model", f"FRTOS_CPU={cpu}", "FRTOS_RAM_KB=32"] + bargs,
                           stdout=f, stderr=subprocess.STDOUT, check=True)
        sims[t] = os.path.join(bdir, "frtos-model", f"{cpu}-32k", "top")
    return sims


def assemble(src, d, tree):
    """src (.s) -> d/init.{elf,dis,bin,mem}; returns the loaded size in bytes."""
    os.makedirs(d, exist_ok=True)
    sh(f"{TC}gcc -march={MARCH} -mabi=ilp32 -nostdlib -nostartfiles -T {tree}/std/hades-v.ld "
       f"-o {d}/init.elf {src}")
    sh(f"{TC}objdump -d {d}/init.elf > {d}/init.dis")
    sh(f"{TC}objcopy -O binary {d}/init.elf {d}/init.bin")
    sh(f"{TC}objcopy -I binary -O verilog --verilog-data-width 4 --reverse-bytes=4 {d}/init.bin {d}/init.mem")
    return os.path.getsize(f"{d}/init.bin")


def fits(text, tmpdir, tree):
    """-> (fits in RAM?, assembler/linker message). A program that is too big fails to link
    (sections overlap) or exceeds MAX_TEXT."""
    os.makedirs(tmpdir, exist_ok=True)
    src = os.path.join(tmpdir, "_fit.s")
    open(src, "w").write(text)
    r = subprocess.run(f"{TC}gcc -march={MARCH} -mabi=ilp32 -nostdlib -nostartfiles -T {tree}/std/hades-v.ld "
                       f"-o {tmpdir}/_fit.elf {src} && {TC}size {tmpdir}/_fit.elf",
                       shell=True, capture_output=True, text=True)
    if r.returncode:
        return False, r.stderr[-800:]
    return int(r.stdout.split("\n")[1].split()[0]) < MAX_TEXT, "text too large"


def chunk_family(fam, src, tree, tmpdir, no_mtvec):
    """Split a family into programs that fit in RAM: [(name, [(pid, probe)])]."""
    allp = [(i + 1, p) for i, p in enumerate({**probes.FAMS, **probes.OPT_FAMS}[fam]())]
    if no_mtvec:
        allp = [(i, p) for i, p in allp if not probes.writes_mtvec(p)]
    out, i, n = [], 0, 0
    while i < len(allp):
        lo, hi = i, len(allp)
        while True:
            ok, msg = fits(probes.build(allp[lo:hi], src=src), tmpdir, tree)
            if ok:
                break
            if hi - lo == 1:
                raise SystemExit(f"probe {allp[lo][0]} of {fam} alone does not assemble/fit: {msg}")
            hi = lo + max(1, (hi - lo) * 2 // 3)
        out.append((f"{fam}_{src}_{n}", allp[lo:hi]))
        i, n = hi, n + 1
    return out


def run_status(log):
    if "TEST DONE" in log:
        return "done"
    return "TIMEOUT" if "Simulation timeout" in log else "CRASH"


# ------------------------------------------------------------------------------ one job
def job(d, target, sim, timeout, wall):
    """Run one program (d/init.mem) on one simulator, then check it with the ISS."""
    try:
        os.nice(5)
    except OSError:
        pass
    rd = os.path.join(d, target)
    os.makedirs(rd, exist_ok=True)
    shutil.copy(os.path.join(d, "init.mem"), rd)
    t0 = time.time()
    with open(os.path.join(rd, "sim.log"), "w") as f:
        try:
            subprocess.run([sim, "+trace", "+nodump", f"+timeout={timeout}"], cwd=rd, stdout=f,
                           stderr=subprocess.STDOUT, timeout=wall)
        except subprocess.TimeoutExpired:
            f.write("\nWALL-CLOCK TIMEOUT\n")
    log = open(os.path.join(rd, "sim.log"), errors="replace").read()
    r = iss.check(d, target)
    # iteration headers in RTL order: the ISS numbers iteration groups 1, 2, ... by them
    heads = [int(v, 16) for v in re.findall(r"^TRACE \d+ 000 ([0-9a-f]+)", log, re.M)]
    return dict(target=target, status=run_status(log), sim_s=round(time.time() - t0, 1),
                cycles=max([int(x) for x in re.findall(r"^TRACE (\d+) ", log, re.M)] or [0]),
                halted=r["halted"],
                violations=[(g, heads[g - 1] if 0 < g <= len(heads) else None, v) for g, v in r["violations"]],
                notes=[(g, n) for g, n in r["notes"]],
                bad=[((ga[0] if ga else None), ga[1] if ga else [], gb[1] if gb else [], why)
                     for _, ga, gb, why in r["bad"]],
                trace_mismatch=r["trace_mismatch"])


# ------------------------------------------------------------------------------ DUT vs golden
def groups(path):
    """per-iteration trace groups keyed by (probe, k); minstret values made relative to the
    iteration's snapshot (removes the golden CPU's constant +1)."""
    G, cur, snap = collections.OrderedDict(), ("pre", 0), 0
    for line in open(path, errors="replace"):
        if not line.startswith("TRACE "):
            continue
        _, _c, off, v = line.split()
        v = int(v, 16)
        if off == "000":
            cur = (v >> 16, v & 0xffff)
            G[cur] = []
            continue
        if off == "038":
            snap = v
            continue
        if off == "01c":
            v -= snap
        G.setdefault(cur, []).append((off, v))
    return G


def compare_golden(d):
    A, B = groups(os.path.join(d, "dut", "sim.log")), groups(os.path.join(d, "ref", "sim.log"))
    keys = list(A.keys()) + [k for k in B if k not in A]
    bad = collections.defaultdict(list)
    for k in keys:
        if A.get(k) != B.get(k):
            bad[k[0]].append(k[1])
    return len(keys), dict(bad)


# ------------------------------------------------------------------------------ reporting
def probe_of(header):
    return (header or 0) >> 16, (header or 0) & 0xffff


def describe(d, name, ids, fam, results, cmp_):
    """-> (one summary line, detail lines, dut_ok, ref_ok)"""
    st = " ".join(f"{r['target']}:{r['status']}" for r in results)
    parts, detail, dut_ok, ref_ok = [], [], True, True
    for r in results:
        nb, nv, nn = len(r["bad"]), len(r["violations"]), len(r["notes"])
        parts.append(f"ISS[{r['target']}] groups_bad={nb} violations={nv} notes={nn}")
        ok = r["status"] == "done" and r["halted"] and nb == 0 and nv == 0
        per = collections.defaultdict(list)
        for h, ra, rb, why in r["bad"]:
            per[probe_of(h)[0]].append((probe_of(h)[1], ra, rb))
        for g, h, v in r["violations"][:6]:
            where = f"iteration {g}"
            if h is not None:
                pid, k = probe_of(h)
                pname = ids.get(pid, f"segment {pid}" if fam == "fuzz" else "?")
                where += f", probe {pid} {pname[:50]}, k={k}"
                if r["target"] == "ref":
                    where += next((" [" + why + "]" for rx, why in GOLDEN_KNOWN if rx.search(pname)), "")
            detail.append(f"   {r['target']} VIOLATION ({where}): {v}")
        for pid, lst in sorted(per.items()):
            pname = ids.get(pid, f"segment {pid}" if fam == "fuzz" else "?")
            tag = ""
            if r["target"] == "ref":
                tag = next((" [" + why + "]" for rx, why in GOLDEN_KNOWN if rx.search(pname)), "")
            detail.append(f"   {r['target']} probe {pid:3d} {pname[:58]:58s} bad k={[x[0] for x in lst]}{tag}")
            for kk, ra, rb in lst[:2]:
                fa = " ".join(f"{o:03x}:{v:x}" for o, v, _c in ra if o not in (0, 0x38))
                fb = " ".join(f"{o:03x}:{v:x}{'*' if t else ''}" for o, v, t in rb if o not in (0, 0x38))
                detail.append(f"        k={kk} rtl: {fa[:260]}")
                detail.append(f"              iss: {fb[:260]}")
        if r["target"] == "dut":
            dut_ok = ok or (fam in EXPECTED and r["status"] == "done" and r["halted"])
        else:
            ref_ok = ok
    line = f"{name} | {st} | {' '.join(parts)}"
    if cmp_:
        n, bad = cmp_
        line += f" | DUT-vs-golden: {n} iterations, {sum(len(v) for v in bad.values())} differ"
    if fam in EXPECTED and any(r["bad"] or r["violations"] for r in results):
        detail.append(f"   (expected for family '{fam}': {EXPECTED[fam]})")
    return line, detail, dut_ok, ref_ok


def execute(programs, args, sims, out):
    """programs: [(name, family, src_text, ids{pid:name}, targets)] -> exit status"""
    os.makedirs(out, exist_ok=True)
    jobs = {}
    with cf.ProcessPoolExecutor(max_workers=args.jobs) as ex:
        for name, fam, text, ids, targets in programs:
            d = os.path.join(out, name)
            os.makedirs(d, exist_ok=True)
            open(os.path.join(d, "init.s"), "w").write(text)
            with open(os.path.join(d, "ids.txt"), "w") as f:
                for pid, pn in sorted(ids.items()):
                    f.write(f"{pid}\t{pn}\n")
            assemble(os.path.join(d, "init.s"), d, args.tree)
            for t in targets:
                jobs[ex.submit(job, d, t, sims[t], args.timeout, args.wall)] = (name, t)
        res = collections.defaultdict(list)
        for i, fut in enumerate(cf.as_completed(jobs), 1):
            name, t = jobs[fut]
            r = fut.result()
            res[name].append(r)
            print(f"  [{i}/{len(jobs)}] {name} {t}: {r['status']} ({r['sim_s']} s)", flush=True)
    lines, details, n_dut_bad, n_ref_bad, summary = [], [], 0, 0, []
    for name, fam, _text, ids, targets in programs:
        rs = sorted(res[name], key=lambda r: targets.index(r["target"]))
        d = os.path.join(out, name)
        cmp_ = compare_golden(d) if set(targets) == {"dut", "ref"} else None
        line, det, dok, rok = describe(d, name, ids, fam, rs, cmp_)
        lines.append(line)
        if det:
            details += [line] + det
        n_dut_bad += not dok
        n_ref_bad += not rok
        summary.append(dict(program=name, family=fam, targets=targets, dut_ok=dok, ref_ok=rok,
                            dut_vs_golden=(None if not cmp_ else dict(iterations=cmp_[0], differ={str(k): v for k, v in cmp_[1].items()})),
                            runs=[{k: r[k] for k in ("target", "status", "cycles", "halted", "sim_s")}
                                  | dict(groups_bad=len(r["bad"]), violations=[v for _, _, v in r["violations"]][:20])
                                  for r in rs]))
    ndut = sum("dut" in p[4] for p in programs)
    nref = sum("ref" in p[4] for p in programs)
    verdict = [f"DUT: {ndut - n_dut_bad}/{ndut} programs ISS-consistent"
               + ("" if not n_dut_bad else f"  <-- {n_dut_bad} FAILED")]
    if nref:
        verdict.append(f"golden: {nref - n_ref_bad}/{nref} programs ISS-consistent"
                       + ("" if not n_ref_bad else " (see the probe list: known golden deviations are tagged)"))
    text = "\n".join(lines) + "\n\n" + ("\n".join(details) + "\n\n" if details else "") + "\n".join(verdict) + "\n"
    open(os.path.join(out, "summary.txt"), "w").write(text)
    json.dump(summary, open(os.path.join(out, "results.json"), "w"), indent=1)
    print("\n" + text + f"(results in {out}/summary.txt, results.json)")
    return 0 if n_dut_bad == 0 else 1


# ------------------------------------------------------------------------------ main
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=["list", "run", "fuzz", "file"])
    ap.add_argument("files", nargs="*", help="file mode: assembly programs")
    ap.add_argument("--fam", default="all", help="comma-separated families (sweep.py list), or all")
    ap.add_argument("--src", default="ext,timer,both", help="interrupt sources: ext, timer, both")
    ap.add_argument("--targets", default="dut,ref", help="dut and/or ref (golden CPU)")
    ap.add_argument("--no-mtvec", action="store_true", help="drop the probes that write mtvec")
    ap.add_argument("--seeds", default="101-110", help="fuzz: seed range a-b or list a,b,c")
    ap.add_argument("--variant", default="i", choices=["i", "m", "mt", "bp", "b"],
                    help="fuzz: i=RV32I (DUT+golden), m=+M/Zba (DUT), mt=+mtvec writes (DUT+golden), "
                         "bp=+M/Zba, predictor on (DUT), b=+M/Zba/Zbb/Zbs/Zicond (DUT)")
    ap.add_argument("--nseg", type=int, default=40, help="fuzz: segments per program")
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--out", default=None)
    ap.add_argument("--tree", default=REPO, help="checkout whose simulators are tested")
    ap.add_argument("--timeout", type=int, default=20_000_000, help="simulation cycle limit per program")
    ap.add_argument("--wall", type=int, default=3600, help="wall-clock limit per simulation (s)")
    args = ap.parse_args()
    args.tree = os.path.abspath(args.tree)

    if args.mode == "list":
        for fam, fn in probes.FAMS.items():
            ps = fn()
            mark = "DUT only" if fam in probes.DUT_ONLY else "DUT + golden"
            nm = sum(probes.writes_mtvec(p) for p in ps)
            print(f"{fam:14s} {len(ps):4d} probes  ({mark}{', %d write mtvec' % nm if nm else ''})"
                  f"{'  [expected flags: ' + EXPECTED[fam][:40] + '...]' if fam in EXPECTED else ''}")
        return 0

    out = os.path.abspath(args.out or os.path.join(tree_build(REPO)[0], "trapsweep", args.mode))
    os.makedirs(out, exist_ok=True)
    want = [t for t in args.targets.split(",") if t]
    programs = []
    if args.mode == "run":
        fams = list(probes.FAMS) if args.fam == "all" else args.fam.split(",")
        for fam in fams:
            if fam not in probes.FAMS and fam not in probes.OPT_FAMS:
                raise SystemExit(f"unknown family {fam}; see: sweep.py list")
            tg = [t for t in (["dut"] if fam in probes.DUT_ONLY else want) if t in want]
            if not tg:
                continue
            for src in args.src.split(","):
                for name, chunk in chunk_family(fam, src, args.tree, os.path.join(out, "_tmp"), args.no_mtvec):
                    programs.append((name, fam, probes.build(chunk, src=src), {pid: p["name"] for pid, p in chunk}, tg))
    elif args.mode == "fuzz":
        if "-" in args.seeds:
            a, b = args.seeds.split("-")
            seeds = range(int(a, 0), int(b, 0) + 1)
        else:
            seeds = [int(x, 0) for x in args.seeds.split(",")]
        flags = {"i": "", "m": "--m", "mt": "--mtvec", "bp": "--m --bp", "b": "--b"}[args.variant]
        tg = [t for t in (["dut", "ref"] if args.variant in ("i", "mt") else ["dut"]) if t in want]
        for s in seeds:
            name = f"fz_{args.variant}_{s}"
            p = os.path.join(out, "_tmp", name + ".s")
            os.makedirs(os.path.dirname(p), exist_ok=True)
            sh(f"{sys.executable} {HERE}/fuzz.py {s} {p} {flags} --nseg {args.nseg}")
            programs.append((name, "fuzz", open(p).read(), {}, tg))
    else:
        if not args.files:
            raise SystemExit("file mode: give one or more .s files")
        for f in args.files:
            programs.append((os.path.splitext(os.path.basename(f))[0], "file", open(f).read(), {}, want))
    if not programs:
        raise SystemExit("nothing to run")
    targets = sorted({t for p in programs for t in p[4]})
    sims = build_sims(args.tree, targets, os.path.join(out, "build.log"))
    print(f"{len(programs)} programs, {sum(len(p[4]) for p in programs)} simulations, {args.jobs} jobs", flush=True)
    return execute(programs, args, sims, out)


if __name__ == "__main__":
    sys.exit(main())
