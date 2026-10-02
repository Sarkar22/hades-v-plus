# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------------------------------
# session.py -- scripted sessions with the HaDes-V+ FreeRTOS shell (test/freertos/shell).
# Called by `make freertos-shell-test` and `make freertos-shell-compare`; see docs/FREERTOS.md.
#
#   python3 session.py run --sim <console simulator> --dir <run dir> --script <session.txt>
#                          [--cpu dut|golden] [--timeout <cycles>] [--seed <hex>] [--label <text>]
#                          [--prompt <text>] [--waves] [--sim-arg <argument>]... [--name <name>]
#       Runs the simulator with +console_script=<script>: the console bridge (sim/console.cpp)
#       types the script's lines into the UART, one per prompt. Every --sim-arg is passed on
#       to the simulator (for example +console_upload_dir=<dir>). The output is streamed and
#       kept in <dir>/session-<cpu>.log, the UART transcript in <dir>/session-<cpu>.uart
#       (<dir>/<name>-<cpu>.log and .uart with --name).
#       Then checks the transcript against the script's expectations and prints one line
#       "FREERTOS SHELL RESULT: PASS|FAIL|HANG|CRASH ..." (exit status 0 only for PASS). A
#       simulator that exits with a status other than 0, or is killed by a signal, is a CRASH,
#       whatever the transcript says.
#
#   python3 session.py check --script <session.txt> [--cpu dut|golden] <log> <uart transcript>
#       Only the check, for a run made earlier.
#
#   python3 session.py compare --script <session.txt> <dut log> <golden log>
#       Compares the transcripts of two runs of the same script (normally the DUT and the
#       golden CPU running the same rv32i program), line by line, after normalising what
#       legitimately differs: every number (cycle counts, stack and heap figures, counters)
#       and the lines that report what the CPU implements -- those whose label is
#       "source:", "cpu:", "mode:" or "accuracy:" (M, Zba, Zbb, Zbs, Zicntr, Zicond and the
#       branch predictor, which the golden CPU does not have). Everything else must be
#       identical.
#
# Script format (see session.txt): lines starting with '#' are not typed; "#? <regex>" must
# match a line of the output of the preceding typed line (in order), "#! <regex>" must match
# none of them; "#?dut", "#!dut", "#?golden", "#!golden" apply to one CPU only. The output
# of a typed line is what the program prints after it; the line itself, as the shell echoes
# it after the prompt, is never part of it, so an expectation cannot be met by the echo of
# the command. "#> <regex>" (and "#>dut", "#>golden") is the exception: it must match that
# echoed line (for example "^C" when Ctrl-C cancels the line). Expectations before the first
# typed line apply to the start-up banner. The transcript is rendered as a terminal would
# show it (backspaces, cursor movement and line erasure applied), so an expectation sees the
# edited line, not the keystrokes; control characters it does not interpret, such as the
# bridge's DC1, DC2, ACK and NAK, are left out. "#< <file>" and "#: <text>" lines are read by
# the bridge only (a file and a text it sends when the program asks for them; see
# sim/console.cpp): here they are comments, and the expectations after them still belong to
# the typed line before them.
# ---------------------------------------------------------------------------------------------
import argparse
import os
import re
import signal
import subprocess
import sys

RULE = '=' * 78
ANSI_COLOR = re.compile(r'\x1b\[[0-9;]*m')
CPU_LINE = re.compile(r'^\s*(source|cpu|mode|accuracy):')


# ------------------------------------------------------------------------------ script --

class Step:
    def __init__(self, lineno, text):
        self.lineno = lineno      # line number in the script (0: the banner)
        self.text = text          # the typed line, as written in the script
        self.expect = []          # (cpu or None, regex source): output lines, in order
        self.forbid = []          # (cpu or None, regex source): no output line
        self.echo = []            # (cpu or None, regex source): the echoed command line


def parse_script(path):
    """The typed lines of a script, each with its expectations; step 0 is the banner."""
    steps = [Step(0, '(start-up banner)')]
    with open(path, encoding='utf-8') as f:
        for n, raw in enumerate(f, 1):
            line = raw.rstrip('\r\n')
            m = re.match(r'#([?!>])(dut|golden)?\s?(.*)$', line)
            if m:
                kind, cpu, rx = m.group(1), m.group(2), m.group(3)
                try:
                    re.compile(rx)
                except re.error as e:
                    raise SystemExit(f'{path}:{n}: bad regular expression {rx!r}: {e}')
                if kind == '>' and len(steps) == 1:
                    raise SystemExit(f'{path}:{n}: "#>" needs a typed line before it')
                {'?': steps[-1].expect, '!': steps[-1].forbid, '>': steps[-1].echo}[kind].append((cpu, rx))
            elif line.startswith('#'):
                continue
            else:
                steps.append(Step(n, line))
    return steps


# ------------------------------------------------------------------------- transcript --

def render(data):
    """Renders UART output as a terminal shows it: a list of text lines."""
    lines, cur, col = [], [], 0
    i, n = 0, len(data)
    while i < n:
        c = data[i]
        if c == '\n':
            lines.append(''.join(cur).rstrip())
            cur, col = [], 0
        elif c == '\r':
            col = 0
        elif c == '\b':
            col = max(0, col - 1)
        elif c == '\x1b':
            m = re.match(r'\x1b\[([0-9;]*)([A-Za-z])', data[i:])
            if m:
                arg, op = m.group(1), m.group(2)
                if op == 'D':
                    col = max(0, col - int(arg or '1'))
                elif op == 'C':
                    col += int(arg or '1')
                elif op == 'K':
                    del cur[col:]
                i += len(m.group(0))
                continue
        elif c >= ' ' or c == '\t':
            while len(cur) < col:
                cur.append(' ')
            if col < len(cur):
                cur[col] = c
            else:
                cur.append(c)
            col += 1
        i += 1
    if cur:
        lines.append(''.join(cur).rstrip())
    return lines


def blocks(lines, prompt):
    """Splits the rendered transcript at the prompts: [banner, output of line 1, ...].
    A block starts with the typed line (the prompt removed) and holds its output."""
    out = [[]]
    for line in lines:
        if line.startswith(prompt.rstrip()):
            out.append([line[len(prompt):] if line.startswith(prompt) else ''])
        else:
            out[-1].append(line)
    return out


def read_text(path):
    with open(path, 'rb') as f:
        return f.read().decode('latin-1')


# ------------------------------------------------------------------------------ check --

def exit_reason(rc):
    """The simulator's exit status in words, or None for a normal end (status 0)."""
    if rc is None or rc == 0:
        return None
    if rc < 0:
        try:
            name = signal.Signals(-rc).name
        except ValueError:
            name = f'signal {-rc}'
        return f'the simulator was killed by {name}'
    return f'the simulator exited with status {rc}'


def check(script, log_path, uart_path, cpu, prompt, rc=None):
    """Returns (status, reasons, info) for one run; rc is the simulator's exit status
    (as subprocess reports it: -n for signal n), None when it is not known."""
    steps = parse_script(script)
    log = ANSI_COLOR.sub('', read_text(log_path)) if os.path.exists(log_path) else ''
    uart = read_text(uart_path) if os.path.exists(uart_path) else ''
    blks = blocks(render(uart), prompt)
    typed = len(steps) - 1
    reasons = []
    checks = passed = 0

    m = re.search(r'FRTOS-RESULT: (PASS|FAIL)(.*?) mtime=([0-9a-fA-F]{16})', uart)
    cycles = int(m.group(3), 16) if m else None
    if 'Simulation timeout!' in log and rc in (None, 0):
        return 'HANG', ['no end of the session within the cycle limit (the shell hung, or TIMEOUT= is too small)'], \
            {'checks': 0, 'passed': 0, 'typed': typed, 'prompts': len(blks) - 1, 'cycles': None}
    if exit_reason(rc):
        return 'CRASH', [exit_reason(rc)], \
            {'checks': 0, 'passed': 0, 'typed': typed, 'prompts': len(blks) - 1, 'cycles': cycles}
    if m and m.group(1) == 'FAIL':
        reasons.append('the program failed: FRTOS-RESULT: FAIL' + m.group(2))
    if m and m.group(1) == 'PASS' and 'All tests passed! (# Errors: 1 = initial test)' not in log:
        reasons.append('FRTOS-RESULT: PASS, but the test-register protocol is broken')
    if not m and '[console] end of the script' not in log:
        return 'CRASH', ['the simulator stopped without a result'], \
            {'checks': 0, 'passed': 0, 'typed': typed, 'prompts': len(blks) - 1, 'cycles': None}

    prompts = len(blks) - 1
    if prompts not in (typed, typed + 1) or (prompts == typed + 1 and any(blks[-1][1:])):
        reasons.append(f'{typed} lines typed but {prompts} prompts seen (every typed line must produce one prompt)')

    for k, step in enumerate(steps):
        blk = blks[k] if k < len(blks) else []
        where = f'script line {step.lineno} "{step.text}"' if k else 'start-up banner'
        # A block starts with the echoed command line (except the banner's): the output
        # proper comes after it.
        echoed = blk[0] if (k and blk) else None
        out = blk[1:] if k else blk
        pos = 0
        for want_cpu, rx in step.expect:
            if want_cpu not in (None, cpu):
                continue
            checks += 1
            hit = next((i for i in range(pos, len(out)) if re.search(rx, out[i])), None)
            if hit is None:
                reasons.append(f'{where}: no output line matches  {rx}')
            else:
                passed += 1
                pos = hit + 1
        for want_cpu, rx in step.forbid:
            if want_cpu not in (None, cpu):
                continue
            checks += 1
            bad = [l for l in out if re.search(rx, l)]
            if bad:
                reasons.append(f'{where}: output line matches the forbidden  {rx}:  {bad[0]!r}')
            else:
                passed += 1
        for want_cpu, rx in step.echo:
            if want_cpu not in (None, cpu):
                continue
            checks += 1
            if echoed is not None and re.search(rx, echoed):
                passed += 1
            else:
                reasons.append(f'{where}: the command line as shown ({echoed!r}) does not match  {rx}')

    info = {'checks': checks, 'passed': passed, 'typed': typed, 'prompts': prompts, 'cycles': cycles}
    return ('PASS' if not reasons else 'FAIL'), reasons, info


def report(status, reasons, info, label, log_path, uart_path):
    line = f'FREERTOS SHELL RESULT: {status}  {label} cycles={info["cycles"] if info["cycles"] is not None else "?"}'
    print(RULE)
    print(line)
    for r in reasons[:20]:
        print(f'  reason: {r}')
    if len(reasons) > 20:
        print(f'  ... and {len(reasons) - 20} more')
    print(f'  typed lines: {info["typed"]}, prompts: {info["prompts"]}, '
          f'expectations met: {info["passed"]}/{info["checks"]}')
    print(f'  log: {log_path}')
    print(f'  UART transcript: {uart_path}')
    print(RULE)
    with open(log_path, 'a') as f:
        f.write(line + '\n')
    return 0 if status == 'PASS' else 1


# -------------------------------------------------------------------------------- run --

def run(a):
    log_path = os.path.join(a.dir, f'{a.name}-{a.cpu}.log')
    uart_path = os.path.join(a.dir, f'{a.name}-{a.cpu}.uart')
    if not os.access(a.sim, os.X_OK):
        print(f'session.py: simulator {a.sim} is missing or not executable', file=sys.stderr)
        return 2
    cmd = [a.sim] + ([] if a.waves else ['+nodump']) + [
        f'+timeout={a.timeout}', f'+switches={a.seed}', f'+console_script={os.path.abspath(a.script)}',
        f'+console_log={uart_path}', f'+console_prompt={a.prompt}'] + a.sim_arg
    print(RULE)
    print(f'SHELL SESSION  {a.label}  script={a.script}  timeout={a.timeout} cycles')
    print("     (the first 'Test fail!' line is the program's deliberate 'initial test' marker)")
    print(RULE, flush=True)
    for p in (log_path, uart_path):
        if os.path.exists(p):
            os.remove(p)
    with open(log_path, 'wb') as log:
        proc = subprocess.Popen(cmd, cwd=a.dir, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT)
        for chunk in iter(lambda: proc.stdout.read1(4096), b''):
            log.write(chunk)
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
        rc = proc.wait()
    status, reasons, info = check(a.script, log_path, uart_path, a.cpu, a.prompt, rc)
    return report(status, reasons, info, a.label, log_path, uart_path)


# ---------------------------------------------------------------------------- compare --

def normalise(line):
    line = re.sub(r'mtime=[0-9a-fA-F]+', 'mtime=#', line)
    line = re.sub(r'0x[0-9a-fA-F]+', '#', line)
    line = re.sub(r'\d+(\.\d+)?', '#', line)
    return ' '.join(line.split())


def compare(a):
    uart = [p[:-4] + '.uart' if p.endswith('.log') else p for p in (a.dut, a.golden)]
    steps = parse_script(a.script)
    views = []
    for p in uart:
        if not os.path.exists(p):
            print(RULE)
            print(f'SHELL COMPARE: FAIL  missing transcript {p}')
            print(RULE)
            return 1
        b = blocks(render(read_text(p)), a.prompt)
        views.append([[normalise(l) for l in blk if not CPU_LINE.match(l)] for blk in b])
    diffs = []
    for k in range(max(len(views[0]), len(views[1]))):
        d = views[0][k] if k < len(views[0]) else ['(missing)']
        g = views[1][k] if k < len(views[1]) else ['(missing)']
        if d != g:
            what = steps[k].text if k < len(steps) else '(after the script)'
            for i in range(max(len(d), len(g))):
                dl = d[i] if i < len(d) else '(none)'
                gl = g[i] if i < len(g) else '(none)'
                if dl != gl:
                    diffs.append(f'"{what}": dut {dl!r} / golden {gl!r}')
                    break
    lines = sum(len(v) for v in views[0])
    print(RULE)
    if diffs:
        print(f'SHELL COMPARE: DIFFERENT  {len(diffs)} of {len(views[0])} blocks differ')
        for d in diffs[:20]:
            print(f'  {d}')
        rc = 1
    else:
        print(f'SHELL COMPARE: SAME  {len(views[0])} blocks, {lines} lines equal after normalising numbers;')
        print('  lines labelled source:/cpu:/mode:/accuracy: (M, Zba, Zbb, Zbs, Zicntr, Zicond, branch predictor) excluded')
        rc = 0
    print(f'  dut:    {uart[0]}')
    print(f'  golden: {uart[1]}')
    print(RULE)
    return rc


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    r = sub.add_parser('run')
    r.add_argument('--sim', required=True)
    r.add_argument('--dir', required=True)
    r.add_argument('--script', required=True)
    r.add_argument('--cpu', default='dut', choices=['dut', 'golden'])
    r.add_argument('--timeout', default='200000000')
    r.add_argument('--seed', default='0')
    r.add_argument('--label', default='')
    r.add_argument('--prompt', default='hades> ')
    r.add_argument('--waves', action='store_true')
    r.add_argument('--sim-arg', action='append', default=[], metavar='ARGUMENT')
    r.add_argument('--name', default='session')
    c = sub.add_parser('check')
    c.add_argument('--script', required=True)
    c.add_argument('--cpu', default='dut', choices=['dut', 'golden'])
    c.add_argument('--prompt', default='hades> ')
    c.add_argument('log')
    c.add_argument('uart')
    p = sub.add_parser('compare')
    p.add_argument('--script', required=True)
    p.add_argument('--prompt', default='hades> ')
    p.add_argument('dut')
    p.add_argument('golden')
    a = ap.parse_args()
    if a.cmd == 'run':
        return run(a)
    if a.cmd == 'check':
        status, reasons, info = check(a.script, a.log, a.uart, a.cpu, a.prompt)
        return report(status, reasons, info, f'cpu={a.cpu}', a.log, a.uart)
    return compare(a)


if __name__ == '__main__':
    sys.exit(main())
