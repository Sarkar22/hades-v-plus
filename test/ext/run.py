#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------------------------------
# run.py -- the check of the Zbb, Zbs and Zicond results: the RTL (instruction_decoder feeding
# execute_stage, driven by test/ext/harness.sv and harness.cpp) against the C reference model
# (test/ext/ref_exh.c), compared through the digest lines of the vector protocol
# (test/ext/README.md). Called by make ext-check and make ext-exhaustive (test/ext/ext.mk).
#
#   python3 test/ext/run.py [--quick | --exhaustive] [--jobs N] [--build DIR] [--form M]...
#
#   --quick       (default) every part except the unary forms' chunks, of which c000, c127,
#                 c128 and c255 run: 75 digest lines, under a minute
#   --exhaustive  every part, the unary forms over all 2^32 inputs: 2,091 digest lines,
#                 34,376,492,288 vectors, about 14 minutes with 4 jobs
#   --jobs N      processes at a time (default 4)
#   --build DIR   build directory (default $HADES_BUILD_DIR, else build/): the harness is built
#                 in DIR/test/ext/harness/, ref_exh in DIR/test/ext/
#   --form M      only these forms (repeatable)
#
# Each form runs in the harness and in ref_exh, as one job each; their lines must be identical,
# and the harness must report violations=0 (every result valid in Execute's own cycle, for
# rd = x10, without a stall). Prints a line per form and ends with "EXT CHECK: PASS" or
# "EXT CHECK: FAIL"; the exit status is 0 only for PASS.
# ---------------------------------------------------------------------------------------------
import argparse
import concurrent.futures
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
# The forms in the order of the ISA tables (the protocol's form numbers 0..27).
FORMS = ['andn', 'orn', 'xnor', 'clz', 'ctz', 'cpop', 'max', 'maxu', 'min', 'minu', 'sext.b', 'sext.h',
         'zext.h', 'rol', 'ror', 'rori', 'orc.b', 'rev8', 'bclr', 'bclri', 'bext', 'bexti', 'binv', 'binvi',
         'bset', 'bseti', 'czero.eqz', 'czero.nez']
UNARY = {'clz', 'ctz', 'cpop', 'sext.b', 'sext.h', 'zext.h', 'orc.b', 'rev8'}
# The harness's sources, in the order its header gives (the packages first).
HARNESS_SRC = ['defines/csr.sv', 'defines/op.sv', 'defines/instruction.sv', 'defines/pipeline_status.sv',
               'defines/constants.sv', 'defines/forwarding.sv', 'defines/clk_params.sv', 'defines/bpredict.sv',
               'rtl/instruction_decoder.sv', 'rtl/execute_stage.sv', 'test/ext/harness.sv', 'test/ext/harness.cpp']


def build(build_dir):
    """Builds the harness and ref_exh; returns (harness, ref_exh) or exits."""
    out = os.path.join(build_dir, 'test', 'ext')
    mdir = os.path.join(out, 'harness')
    os.makedirs(mdir, exist_ok=True)
    log = os.path.join(out, 'build.log')
    steps = [
        ['verilator', '--cc', '--exe', '--build', '-O3', '--x-assign', 'fast', '--x-initial', 'fast',
         '-Wno-fatal', '-CFLAGS', '-O2', '-Mdir', mdir, '--top-module', 'harness'] + HARNESS_SRC,
        ['cc', '-O2', '-o', os.path.join(out, 'ref_exh'), 'test/ext/ref_exh.c'],
    ]
    with open(log, 'w') as f:
        for cmd in steps:
            f.write('$ ' + ' '.join(cmd) + '\n')
            f.flush()
            if subprocess.run(cmd, cwd=REPO, stdin=subprocess.DEVNULL, stdout=f, stderr=subprocess.STDOUT).returncode:
                print('ext check: building failed: %s (log: %s)' % (cmd[0], log))
                print('EXT CHECK: FAIL')
                sys.exit(1)
    return os.path.join(mdir, 'Vharness'), os.path.join(out, 'ref_exh')


def run_one(cmd):
    p = subprocess.run(cmd, cwd=REPO, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, universal_newlines=True)
    return p.returncode, p.stdout


def main():
    ap = argparse.ArgumentParser(description='The Zbb, Zbs and Zicond results of the RTL against the C '
                                             'reference model (test/ext/README.md).')
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument('--quick', action='store_true', help='the quick vector set (default)')
    mode.add_argument('--exhaustive', action='store_true', help='every part, the unary forms over all inputs')
    ap.add_argument('--jobs', type=int, default=4)
    ap.add_argument('--build', default=os.environ.get('HADES_BUILD_DIR') or os.path.join(REPO, 'build'))
    ap.add_argument('--form', action='append', choices=FORMS, metavar='M')
    a = ap.parse_args()
    if a.jobs < 1:
        ap.error('--jobs must be at least 1')
    quick = ['--quick'] if not a.exhaustive else []
    forms = [f for f in FORMS if not a.form or f in a.form]

    t0 = time.time()
    harness, ref_exh = build(os.path.abspath(a.build))
    print('ext check (%s): the RTL (instruction_decoder -> execute_stage) against the C reference model, '
          '%d forms, %d jobs' % ('exhaustive' if a.exhaustive else 'quick', len(forms), a.jobs))
    # the long jobs first: the unary forms' harness runs
    jobs = [(f, 'rtl', [harness] + quick + ['--form', f]) for f in forms] + \
           [(f, 'model', [ref_exh] + quick + ['--form', f]) for f in forms]
    jobs.sort(key=lambda j: (j[0] not in UNARY, j[1] != 'rtl'))
    results = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=a.jobs) as pool:
        futures = {pool.submit(run_one, cmd): (f, side) for f, side, cmd in jobs}
        for fut in concurrent.futures.as_completed(futures):
            results[futures[fut]] = fut.result()

    failed, lines_total, vectors_total, violations_total = [], 0, 0, 0
    for f in forms:
        rc_h, out_h = results[(f, 'rtl')]
        rc_m, out_m = results[(f, 'model')]
        h = [l for l in out_h.splitlines() if l.startswith(f + ' ')]
        m = [l for l in out_m.splitlines() if l.startswith(f + ' ')]
        viol = [l for l in out_h.splitlines() if l.startswith('violations=')]
        nviol = int(viol[-1].split('=')[1]) if viol else -1
        same = sum(1 for x, y in zip(h, m) if x == y)
        vectors = sum(int(l.split()[2]) for l in m if len(l.split()) == 4)
        ok = rc_m == 0 and h == m and len(m) > 0 and nviol == 0 and rc_h == 0
        lines_total += len(m)
        vectors_total += vectors
        violations_total += max(nviol, 0)
        print('  %-10s %4d of %4d digest lines identical, %14s vectors, violations=%s  %s'
              % (f, same, len(m), format(vectors, ','), nviol if nviol >= 0 else '?', 'ok' if ok else 'DIFFERS'))
        if not ok:
            failed.append(f)
            for x, y in [(x, y) for x, y in zip(h, m) if x != y][:4]:
                print('             rtl:   ' + x)
                print('             model: ' + y)
            if len(h) != len(m):
                print('             rtl %d lines, model %d lines (exit status %d / %d)' % (len(h), len(m), rc_h, rc_m))
    print('  %d digest lines, %s vectors, violations=%d' % (lines_total, format(vectors_total, ','), violations_total))
    print('  wall time %.0f s' % (time.time() - t0))
    if failed:
        print('EXT CHECK: FAIL (%d of %d forms differ: %s)' % (len(failed), len(forms), ' '.join(failed)))
        return 1
    print('EXT CHECK: PASS (%d of %d forms identical)' % (len(forms), len(forms)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
