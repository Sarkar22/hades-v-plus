#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------------------------------
# coremark.py -- checks and summary of a CoreMark run, called by make coremark
# (test/coremark/coremark.mk). It reads <dir>/run.log and prints the figures, the checks of
# CoreMark's own CRCs and ends in one line, "COREMARK <label>: PASS" or "COREMARK <label>: FAIL";
# the exit status is 0 only for PASS. Guide: test/coremark/README.md.
#
#   coremark.py <dir> --label <text> --iterations <n> --run performance|validation
#               --cpu dut|golden [--preset <A..I>] [--size-tool <path>]
#
# The run has to end normally (the program's halt, no timeout), CoreMark has to recognise its
# seeds and every CRC it prints has to equal the known one (CoreMark compares them itself and
# prints "ERROR! ... crc" lines when they differ). CoreMark's lines "ERROR! Must execute for at
# least 10 secs" and "Errors detected" are expected in a simulation (the time cannot reach
# 10 s) and are not failures; any other error line is.
# ---------------------------------------------------------------------------------------------
import argparse
import os
import re
import subprocess
import sys

ANSI = re.compile(r'\x1b\[[0-9;]*m')
HERE = os.path.dirname(os.path.abspath(__file__))
HPM_SV = os.path.join(HERE, '..', '..', 'defines', 'hpm.sv')

# The known CRCs for the total data size of 2000 bytes (666 per algorithm), the first CRC
# of each algorithm after the first iteration (third_party/coremark/core_list_join.c,
# core_main.c): the performance run (seedcrc 0xe9f5) and the validation run (0x18f2)
KNOWN = {
    'performance': dict(seedcrc=0xe9f5, crclist=0xe714, crcmatrix=0x1fd7, crcstate=0x8e3a),
    'validation':  dict(seedcrc=0x18f2, crclist=0xe3c1, crcmatrix=0x0747, crcstate=0x8d84),
}
CYCLE_CLASSES = ('FETCH_WAIT', 'FRONT_OK', 'HAZARD', 'MSTALL_ANY', 'MEMWAIT_ANY', 'REDIRECT_ANY')


def event_names():
    """code -> name of defines/hpm.sv, and the presets' seven codes."""
    names, presets = {}, {}
    try:
        text = open(HPM_SV).read()
    except OSError:
        return names, presets
    for m in re.finditer(r"localparam bit \[7:0\] EV_(\w+)\s*=\s*8'd(\d+);", text):
        names[int(m.group(2))] = m.group(1)
    for m in re.finditer(r"^\s*([A-I]):\s+return codes7\(([^)]*)\)", text, re.M):
        presets[m.group(1)] = [int(x.strip().replace("8'd", '')) for x in m.group(2).split(',')]
    return names, presets


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('dir')
    ap.add_argument('--label', required=True)
    ap.add_argument('--iterations', type=int, required=True)
    ap.add_argument('--run', choices=sorted(KNOWN), default='performance')
    ap.add_argument('--cpu', choices=('dut', 'golden'), default='dut')
    ap.add_argument('--preset')
    ap.add_argument('--size-tool')
    a = ap.parse_args()

    try:
        with open(os.path.join(a.dir, 'run.log'), 'rb') as f:
            log = ANSI.sub('', f.read().decode('utf-8', 'replace'))
    except OSError:
        log = ''
    problems = []

    if not log:
        problems.append('no run log')
    if 'Simulation timeout!' in log:
        problems.append('simulation timeout')
    if 'SIMULATOR EXIT STATUS' in log:
        problems.append('the simulator failed')
    if log and 'TEST DONE' not in log:
        problems.append('the program did not halt')
    for bad in ('SCOREBOARD: FAIL', 'HPM_CHECK FAIL', 'interconnect timeout at cycle'):
        if bad in log:
            problems.append(bad)

    def val(pattern, conv=int, base=10):
        m = re.search(pattern, log, re.M)
        return conv(m.group(1), base) if m else None

    ticks = val(r'^Total ticks\s*:\s*(\d+)')
    iterations = val(r'^Iterations\s*:\s*(\d+)')
    seedcrc = val(r'^seedcrc\s*:\s*0x([0-9a-f]+)', int, 16)
    crcs = {k: val(r'^\[0\]%s\s*:\s*0x([0-9a-f]+)' % k, int, 16) for k in ('crclist', 'crcmatrix', 'crcstate', 'crcfinal')}
    port_cycles = val(r'^HADES port: .*cycles=(\d+)')
    clock_hz = val(r'^HADES port: .*clock_hz=(\d+)') or 50000000
    iw = re.search(r'^HADES instret: window=(\d+) start=(\d+) stop=(\d+)', log, re.M)
    instret = int(iw.group(1)) if iw else None
    ret = re.search(r'^RETIRED cycles=(\d+) instructions=(\d+) cpi=(\S+)', log, re.M)

    # CoreMark's own checks
    known = KNOWN[a.run]
    if seedcrc != known['seedcrc']:
        problems.append('seedcrc %s, expected 0x%04x for the %s run' % (
            '0x%04x' % seedcrc if seedcrc is not None else 'missing', known['seedcrc'], a.run))
    for k in ('crclist', 'crcmatrix', 'crcstate'):
        if crcs[k] != known[k]:
            problems.append('%s %s, expected 0x%04x' % (k, '0x%04x' % crcs[k] if crcs[k] is not None else 'missing', known[k]))
    for line in log.splitlines():
        if line.startswith('[') and 'ERROR!' in line:
            problems.append('CoreMark: ' + line.strip())
        elif line.startswith('ERROR!') and 'at least 10 secs' not in line:
            problems.append('CoreMark: ' + line.strip())
    if iterations != a.iterations:
        problems.append('iterations %s, expected %d' % (iterations, a.iterations))
    if ticks is None or port_cycles is None or ticks != port_cycles:
        problems.append('Total ticks %s and the port\'s cycles %s differ' % (ticks, port_cycles))

    print('CoreMark on HaDes-V+ (%s), %s' % (a.cpu, a.label))
    for line in log.splitlines():
        if line.startswith(('CACHE ', 'SLOW MEMORY ', 'Compiler flags')):
            print('  ' + line.strip()[:200])
    if a.size_tool:
        elf = os.path.join(a.dir, 'out.elf')
        try:
            out = subprocess.run([a.size_tool, '-A', elf], capture_output=True, text=True).stdout
            sec = {m.group(1): int(m.group(2)) for m in re.finditer(r'^\.(\w+)\s+(\d+)', out, re.M)}
            print('  image: text %d, rodata %d, data %d, bss %d bytes (RAM 32768, the top 4096 are the stack)' % (
                sec.get('text', 0) + sec.get('reset', 0), sec.get('rodata', 0),
                sec.get('data', 0) + sec.get('sdata', 0), sec.get('bss', 0) + sec.get('sbss', 0)))
        except OSError:
            pass

    if ticks:
        n = a.iterations
        print()
        print('  timed window (CoreMark\'s start_time to stop_time, %d iterations):' % n)
        print('    cycles                 %d' % ticks)
        if instret:
            print('    instructions           %d' % instret)
            print('    CPI                    %.3f' % (ticks / instret))
        print('    cycles per iteration   %.0f' % (ticks / n))
        print('    CoreMark/MHz estimate  %.3f   (= iterations * 1000000 / cycles)' % (n * 1e6 / ticks))
        print('    at %d MHz              %.1f iterations/s   (an estimate of the CoreMark score; not valid for reporting)' % (
            clock_hz // 1000000, n * clock_hz / ticks))
        if ret:
            print('  whole run (reset to halt, also the start code, the report on the UART and the halt):')
            print('    cycles %s  instructions %s  CPI %s' % (ret.group(1), ret.group(2), ret.group(3)))
        print()
        print('  CoreMark\'s own validation (CRCs after the first iteration, seedcrc 0x%04x):' % known['seedcrc'])
        for k in ('crclist', 'crcmatrix', 'crcstate'):
            print('    %-10s 0x%04x  expected 0x%04x  %s' % (k, crcs[k] or 0, known[k], 'ok' if crcs[k] == known[k] else 'WRONG'))
        print('    crcfinal   0x%04x  (depends on the iterations)' % (crcs['crcfinal'] or 0))

    # The counters of the timed window (a simulator built with HPM_PRESET)
    hpm = {int(m.group(1)): int(m.group(2)) for m in re.finditer(r'^HADES hpm(\d+): (\d+)', log, re.M)}
    if hpm and ticks:
        names, presets = event_names()
        codes = presets.get(a.preset or '', [])
        print()
        print('  counters of the timed window, preset %s (mhpmcounter3-9, read around the window):' % (a.preset or '?'))
        total = 0
        classes = 0
        for k in range(3, 10):
            code = codes[k - 3] if k - 3 < len(codes) else None
            name = names.get(code, '?') if code is not None else '?'
            share = 100.0 * hpm.get(k, 0) / ticks
            print('    mhpmcounter%d  %-18s %10d  %6.2f %% of the window\'s cycles' % (k, '%s (%s)' % (name, code), hpm.get(k, 0), share))
            if name in CYCLE_CLASSES:
                classes += hpm.get(k, 0)
        if classes:
            print('    the six cycle classes add up to %d of %d cycles (%+d; the counters are read a few instructions away from mcycle)'
                  % (classes, ticks, classes - ticks))

    # The caches' counts of the whole run
    cs = re.search(r'^CACHE_STATS (.*)$', log, re.M)
    if cs:
        d = {k: int(v) for k, v in re.findall(r'(\w+)=(\d+)', cs.group(1))}
        c = d.get('cycles') or 1
        print()
        print('  caches, whole run (CACHE_STATS): instruction refills %d, load misses %s, stores %s (hits %s, misses %s)' % (
            d.get('i_done', 0), d.get('dc_load_misses', 'n/a'), d.get('d_stores', 0), d.get('dc_store_hits', 'n/a'),
            d.get('dc_store_misses', 'n/a')))
        if 'dc_store_wait' in d:
            print('    store wait %d cycles = %.2f %% of the run; waiting for the port: instruction side %d, data side %d' % (
                d['dc_store_wait'], 100.0 * d['dc_store_wait'] / c, d.get('wait_i_for_port', 0), d.get('wait_d_for_port', 0)))

    # one machine-readable line for tables
    if ticks and instret:
        print()
        print('RESULT %s cycles=%d instructions=%d cpi=%.3f cycles_per_iteration=%.0f coremark_per_mhz=%.3f' % (
            a.label, ticks, instret, ticks / instret, ticks / a.iterations, a.iterations * 1e6 / ticks))
    elif ticks:
        print()
        print('RESULT %s cycles=%d instructions=n/a cycles_per_iteration=%.0f coremark_per_mhz=%.3f' % (
            a.label, ticks, ticks / a.iterations, a.iterations * 1e6 / ticks))

    print()
    for p in problems:
        print('  problem: ' + p)
    print('COREMARK %s: %s' % (a.label, 'FAIL' if problems else 'PASS'))
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
