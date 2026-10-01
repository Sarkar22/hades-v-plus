#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------------------------------
# bench.py -- checks and summaries for the measurement programs in test/bench/, called by
# make bench-zba, bench-mcost and bench-fencei-window (test/bench/bench.mk). It reads what the
# make rules leave in the build directory (run.log, out.bin, out.dis) and prints a summary
# that ends in one line, "BENCH <NAME>: PASS" or "BENCH <NAME>: FAIL"; the exit status is 0
# only for PASS. Guide: test/bench/README.md.
#
#   bench.py zba <dir> <opt>       one subdirectory of <dir> per Zba variant
#   bench.py mcost <dir>           <dir>/loop_*/ and <dir>/mcost/
#   bench.py fencei-window <dir>   <dir>/fencei_stale/
# ---------------------------------------------------------------------------------------------
import os
import re
import sys

ANSI = re.compile(r'\x1b\[[0-9;]*m')
TIME_UNITS_PER_CYCLE = 20          # SIM_CYCLES_PER_SYS_CLK in defines/clk_params.sv


def read_log(d):
    """The run log of directory d, without colour codes ('' if it is missing)."""
    try:
        with open(os.path.join(d, 'run.log'), 'rb') as f:
            return ANSI.sub('', f.read().decode('utf-8', 'replace'))
    except OSError:
        return ''


def run_problems(log):
    """Reasons why a run did not end normally (an empty list if it did)."""
    problems = []
    if not log:
        problems.append('no run log')
    if 'Simulation timeout!' in log:
        problems.append('simulation timeout')
    if 'SIMULATOR EXIT STATUS' in log:
        problems.append('the simulator failed')
    if log and 'TEST DONE' not in log:
        problems.append('the program did not halt')
    return problems


def fields(log):
    """'KEY value' lines of a program's output, as a dict (the first of each key)."""
    out = {}
    for line in log.splitlines():
        m = re.match(r'^([A-Z][A-Z0-9]*) ([0-9a-f]{8})$', line.strip())
        if m and m.group(1) not in out:
            out[m.group(1)] = m.group(2)
    return out


def is_zba(word):
    """sh1add, sh2add or sh3add: opcode OP, funct7 0010000, funct3 010/100/110."""
    return (word & 0x7f) == 0x33 and (word >> 25) == 0x10 and ((word >> 12) & 7) in (2, 4, 6)


def zba_count(d):
    """Zba instruction words in the disassembled code of directory d: [sh1add, sh2add, sh3add]."""
    n = [0, 0, 0]
    try:
        with open(os.path.join(d, 'out.dis')) as f:
            for line in f:
                m = re.match(r'^\s*[0-9a-f]+:\s+([0-9a-f]{8})\s', line)
                if m and is_zba(int(m.group(1), 16)):
                    n[((int(m.group(1), 16) >> 12) & 7) // 2 - 1] += 1
    except OSError:
        return None
    return n


def size(d, name='out.bin'):
    try:
        return os.path.getsize(os.path.join(d, name))
    except OSError:
        return None


def pct(old, new):
    return 100.0 * (new - old) / old


def verdict(name, failures):
    print()
    for f in failures:
        print('  problem: ' + f)
    print('BENCH %s: %s' % (name, 'FAIL' if failures else 'PASS'))
    return 1 if failures else 0


# ---- bench-zba -------------------------------------------------------------------------------

# zba_diff with its defaults (32 x 32 special values and 128 random pairs from seed 0xACE1),
# and with 1400 random pairs only from three other seeds
ZBA_DIFF_RUNS = ['zba_diff', 'zba_diff-B5297A4D', 'zba_diff-1F123BB5', 'zba_diff-9E3779B9']


def bench_zba(top, opt):
    failures = []
    runs = {}
    for v in ['zba_bench-rv32i', 'zba_bench-rv32i_zba', 'zba_arr-rv32i', 'zba_arr-rv32i_zba'] + \
             ZBA_DIFF_RUNS:
        d = os.path.join(top, v)
        log = read_log(d)
        runs[v] = {'log': log, 'f': fields(log), 'size': size(d), 'zba': zba_count(d)}
        for p in run_problems(log):
            failures.append('%s: %s' % (v, p))

    print('Zba benchmark (test/bench/zba), %s: each program built for -march=rv32i and for '
          '-march=rv32i_zba' % opt)
    print()
    print('  %-21s %11s %11s %13s  %s' % ('variant', 'image bytes', 'Zba instrs', 'timed cycles',
                                          'result'))

    def row(v, result):
        r = runs[v]
        cyc = r['f'].get('CYC') or r['f'].get('CYCLES')
        print('  %-21s %11s %11s %13s  %s' % (v, r['size'], sum(r['zba']) if r['zba'] else r['zba'],
                                              int(cyc, 16) if cyc else '-', result))

    for v in ['zba_bench-rv32i', 'zba_bench-rv32i_zba']:
        row(v, 'CHK %s' % runs[v]['f'].get('CHK', '-'))
    for v in ['zba_arr-rv32i', 'zba_arr-rv32i_zba']:
        row(v, 'SUM %s' % runs[v]['f'].get('SUM', '-'))
    for v in ZBA_DIFF_RUNS:
        f = runs[v]['f']
        ok = 'ZBA DIFF OK' in runs[v]['log']
        row(v, 'CASES %s BAD %s EXTRA %s%s' % (
            int(f['CASES'], 16) if 'CASES' in f else '-', int(f['BAD'], 16) if 'BAD' in f else '-',
            int(f['EXTRA'], 16) if 'EXTRA' in f else '-', ', ZBA DIFF OK' if ok else ''))
    print()

    # zba_bench: equal checksum; the cycles and the image size are the result
    off, on = runs['zba_bench-rv32i']['f'], runs['zba_bench-rv32i_zba']['f']
    if 'CHK' not in off or 'CHK' not in on or off['CHK'] != on['CHK']:
        failures.append('zba_bench: CHK differs or is missing (%s / %s)' % (off.get('CHK'), on.get('CHK')))
    if 'CYC' in off and 'CYC' in on:
        c0, c1 = int(off['CYC'], 16), int(on['CYC'], 16)
        s0, s1 = runs['zba_bench-rv32i']['size'], runs['zba_bench-rv32i_zba']['size']
        print('  zba_bench: %d -> %d cycles (%+.1f %%, %.4fx), %s -> %s bytes (%+.1f %%), CHK equal: %s'
              % (c0, c1, pct(c0, c1), c0 / c1, s0, s1, pct(s0, s1), 'yes' if off.get('CHK') == on.get('CHK') else 'NO'))
        z = runs['zba_bench-rv32i_zba']['zba']
        if z:
            print('             Zba instructions in the rv32i_zba build: %d sh1add, %d sh2add, %d sh3add'
                  % tuple(z))
    else:
        failures.append('zba_bench: CYC missing')

    # zba_arr: every line before CYCLES must be equal
    keys = ['P1', 'P2', 'P3', 'P4', 'P5', 'P6', 'P7', 'P8', 'SUM']
    a0, a1 = runs['zba_arr-rv32i']['f'], runs['zba_arr-rv32i_zba']['f']
    differ = [k for k in keys if k not in a0 or k not in a1 or a0[k] != a1[k]]
    if differ:
        failures.append('zba_arr: %s differ or are missing' % ', '.join(differ))
    s0, s1 = runs['zba_arr-rv32i']['size'], runs['zba_arr-rv32i_zba']['size']
    if s0 and s1:
        cyc = ''
        if 'CYCLES' in a0 and 'CYCLES' in a1:
            cyc = '; CYCLES %d -> %d (the window includes waiting for the UART)' % (
                int(a0['CYCLES'], 16), int(a1['CYCLES'], 16))
        print('  zba_arr:   %d -> %d bytes (%+.1f %%), P1-P8 and SUM equal: %s%s'
              % (s0, s1, pct(s0, s1), 'no' if differ else 'yes', cyc))

    # zba_diff: every run reports ZBA DIFF OK with BAD = EXTRA = 0
    per_run, bad, ok = [], 0, 0
    for v in ZBA_DIFF_RUNS:
        log, f = runs[v]['log'], runs[v]['f']
        per_run.append(int(f['CASES'], 16) if 'CASES' in f else 0)
        bad += int(f['BAD'], 16) if 'BAD' in f else 0
        if 'ZBA DIFF OK' not in log or 'MISMATCH' in log or f.get('BAD') != '00000000' \
                or f.get('EXTRA') != '00000000' or 'CASES' not in f:
            failures.append('%s: no clean ZBA DIFF OK' % v)
        else:
            ok += 1
    print('  zba_diff:  %d checks in %d runs (%s), %d mismatches, ZBA DIFF OK in %d of %d'
          % (sum(per_run), len(per_run), ' + '.join(str(c) for c in per_run), bad, ok,
             len(ZBA_DIFF_RUNS)))

    # the rv32i builds must not contain Zba (zba_diff issues its own as .insn words)
    for v in ['zba_bench-rv32i', 'zba_arr-rv32i']:
        if runs[v]['zba'] is None or sum(runs[v]['zba']):
            failures.append('%s: no disassembly, or it contains Zba instructions' % v)
    return verdict('ZBA', failures)


# ---- bench-mcost -----------------------------------------------------------------------------

LOOPS = [('loop_empty', '(empty body)'), ('loop_addi', 'addi s1, t5, 0'),
         ('loop_mul', 'mul  s1, t5, t6'), ('loop_div', 'div  s1, t5, t6'),
         ('loop_div0', 'div  s1, t5, zero')]
MCOST = ['base-add', 'mul', 'mulh', 'mulhsu', 'mulhu', 'div', 'divu', 'rem', 'remu',
         'div-by-0', 'remu-by-0', 'div-ovf']
# the rows of the table in docs/EXTENSIONS.md: label, documented cost, loop program, mcost.c lines
DOCS_ROWS = [('any RV32I ALU op', 1, 'loop_addi', []),
             ('mul / mulh / mulhsu / mulhu', 2, 'loop_mul', ['mul', 'mulh', 'mulhsu', 'mulhu']),
             ('div / divu / rem / remu', 34, 'loop_div', ['div', 'divu', 'rem', 'remu']),
             ('div / rem by zero, or -2^31 / -1', 1, 'loop_div0', ['div-by-0', 'remu-by-0', 'div-ovf'])]


def bench_mcost(top):
    failures = []
    cycles = {}
    print('M-unit cycle costs (test/bench/mcost)')
    print()
    print('  800-op loops: 100 iterations of 8 back-to-back instructions, timed between two')
    print('  test-peripheral markers (%d time units per cycle)' % TIME_UNITS_PER_CYCLE)
    print('  %-11s %-18s %7s %8s  %s' % ('program', 'loop body', 'cycles', 'per op',
                                         'per op, loop overhead subtracted'))
    for name, body in LOOPS:
        log = read_log(os.path.join(top, name))
        for p in run_problems(log):
            failures.append('%s: %s' % (name, p))
        t = [int(x) for x in re.findall(r'\(\s*(\d+) ps\) Test pass!', log)]
        if len(t) != 2 or (t[1] - t[0]) % TIME_UNITS_PER_CYCLE:
            failures.append('%s: expected two markers a whole number of cycles apart, got %s' % (name, t))
            continue
        cycles[name] = (t[1] - t[0]) // TIME_UNITS_PER_CYCLE
    loop_cost = {}
    for name, body in LOOPS:
        if name not in cycles:
            continue
        c = cycles[name]
        net = '-'
        if name != 'loop_empty' and 'loop_empty' in cycles:
            loop_cost[name] = (c - cycles['loop_empty']) / 800
            net = '%.2f' % loop_cost[name]
        print('  %-11s %-18s %7d %8.3f  %s' % (name, body, c, c / 800, net))
    if 'loop_empty' in cycles:
        print('  loop overhead (loop_empty): %d cycles, %.3f per op' % (cycles['loop_empty'],
                                                                         cycles['loop_empty'] / 800))
    print()

    # mcost.c: 64 iterations x 8 identical instructions, mcycle around the loop
    log = read_log(os.path.join(top, 'mcost'))
    for p in run_problems(log):
        failures.append('mcost: %s' % p)
    values = {}
    for line in log.splitlines():
        m = re.match(r'^(\S+)\s+([0-9a-f]{8})$', line.strip())
        if m and m.group(1) not in values:
            values[m.group(1)] = int(m.group(2), 16)
    print('  mcost.c (rv32im -O2): 64 iterations of 8 identical instructions (512), mcycle;')
    print('  per op = (cycles - cycles of base-add) / 512 + 1, the 1 being the ADD measured above')
    mc_cost = {}
    for name in MCOST:
        if name not in values:
            failures.append('mcost: no %s line' % name)
            continue
        if 'base-add' in values:
            mc_cost[name] = (values[name] - values['base-add']) / 512 + 1
        print('  %-11s %7d %8.2f' % (name, values[name], mc_cost.get(name, float('nan'))))
    print()

    print('  docs/EXTENSIONS.md "Measured" column   documented  800-op loops  mcost.c')
    for label, doc, loop, mc in DOCS_ROWS:
        got = loop_cost.get(loop)
        mcs = ' '.join('%.2f' % mc_cost[n] for n in mc if n in mc_cost) or '(reference)'
        print('  %-38s %10.2f  %12s  %s' % (label, doc, '%.2f' % got if got is not None else '-', mcs))
        if got is None or abs(got - doc) > 1e-9:
            failures.append('%s: %s cycles measured with %s, %.2f documented' % (label, got, loop, doc))
        for n in mc:
            if n in mc_cost and abs(mc_cost[n] - doc) > 1e-9:
                failures.append('%s: mcost.c %s gives %.2f, %.2f documented' % (label, n, mc_cost[n], doc))
    return verdict('MCOST', failures)


# ---- bench-fencei-window ---------------------------------------------------------------------

FENCEI_EXPECTED = [('sw+4  (0 nops in gap)', 'OLD (STALE)'),
                   ('sw+8  (1 nop  in gap)', 'OLD (STALE)'),
                   ('sw+12 (2 nops in gap)', 'OLD (STALE)'),
                   ('sw+16 (3 nops in gap)', 'NEW (fresh)'),
                   ('sw+20 (4 nops in gap)', 'NEW (fresh)'),
                   ('sw+8  (fence.i in gap)', 'NEW (fresh)'),
                   ('sw+12 (2 stalling lw )', 'OLD (STALE)')]


def bench_fencei(top):
    failures = []
    log = read_log(os.path.join(top, 'fencei_stale'))
    failures += ['fencei_stale: %s' % p for p in run_problems(log)]
    seen = {}
    for line in log.splitlines():
        m = re.match(r'^\s+(sw\+\d+\s+\(.*?\))\s*:\s*(.*?)\s*$', line)
        if m:
            seen[m.group(1)] = m.group(2)
    print('FENCE.I staleness window (test/bench/fencei-window/fencei_stale.s)')
    print('A store patches the instruction D bytes after it, which then runs; the gap holds nops')
    print('(or the instruction named); OLD = the word before the store executed, NEW = the patched one.')
    print()
    for key, want in FENCEI_EXPECTED:
        got = seen.get(key, '(missing)')
        print('  %-24s: %s' % (key, got))
        if got != want:
            failures.append('%s: %s, expected %s' % (key, got, want))
    own = 'All tests passed! (# Errors: 1 = initial test)' in log
    print()
    print("  the program's own checks: %s" % ('All tests passed! (# Errors: 1 = initial test)'
                                              if own else 'NOT passed'))
    if not own:
        failures.append("the program's own checks did not pass")

    # stall_probe.s: cycles between two mcycle reads around two nops, around the two stalling
    # loads of the "2 stalling lw" case, and around two loads that do not stall
    plog = read_log(os.path.join(top, 'stall_probe'))
    failures += ['stall_probe: %s' % p for p in run_problems(plog)]
    m = re.search(r'^([0-9a-f]) ([0-9a-f]) ([0-9a-f]) ?$', plog, re.M)
    stall = None
    if m:
        nops, loads, plain = (int(x, 16) for x in m.groups())
        stall = loads - nops
        print('  stall_probe.s, cycles between two mcycle reads: two nops %d, the two loads of the'
              % nops)
        print('  "2 stalling lw" case %d, two loads that do not stall %d' % (loads, plain))
        if stall <= 0:
            failures.append('stall_probe: the loads of the "2 stalling lw" case do not stall')
    else:
        failures.append('stall_probe: no result line')

    if not failures:
        print()
        print('  window: the 3 instruction slots after the store (sw+4, sw+8, sw+12) run the old')
        print('  word, sw+16 and later the new one; FENCE.I at sw+8 gives the new word; %d stall'
              % stall)
        print('  cycles in the gap leave sw+12 old.')
        print('  caveat: at sw+12 the fetch reads the word in the same cycle as the store writes it,')
        print('  through the other port of the block RAM. Verilator returns the old word; on a Xilinx')
        print('  block RAM the data read in that case is undefined, so sw+12 is "not reliably fresh".')
    return verdict('FENCEI-WINDOW', failures)


def main(argv):
    if len(argv) >= 3 and argv[1] == 'zba':
        return bench_zba(argv[2], argv[3] if len(argv) > 3 else '-O2')
    if len(argv) == 3 and argv[1] == 'mcost':
        return bench_mcost(argv[2])
    if len(argv) == 3 and argv[1] == 'fencei-window':
        return bench_fencei(argv[2])
    sys.stderr.write('usage: bench.py zba <dir> <opt> | mcost <dir> | fencei-window <dir>\n')
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
