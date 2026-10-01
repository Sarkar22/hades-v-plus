# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------------------------------
# tty_test.py -- checks the interactive console of the simulator (sim/console.cpp) the way a
# person uses it: `make freertos-shell-tty-test` (docs/FREERTOS.md).
#
#   python3 tty_test.py --sim <console simulator> --dir <run dir> [--only <name>[,<name>...]]
#
# Every case starts the simulator on a pseudo-terminal of its own, as if in a terminal
# window, types into it with pauses like a person, and checks what appears. The cases:
#   keys       raw mode during the session; a command, echo, Delete, Ctrl-C (which must reach
#              the shell, not stop the simulator), Ctrl-U, the Up arrow; Ctrl-] ends the
#              simulation (exit status 0)
#   esc        a lone Esc key followed by Enter, by a letter and by Ctrl-C: none of them is
#              swallowed; after a pause, an Esc no longer combines with the next keys
#   paste      13 command lines written to the terminal at once: all run, nothing dropped
#   exit       the 'exit' command ends the simulation through the test register
#   timeout    the cycle limit ends it ($finish)
#   quit-pending
#              Ctrl-] ends the simulation while a typed character waits in the UART and
#              the program never reads it (a program that spins for ever, in a run
#              directory of its own: tty-hang/init.mem); further keys are typed meanwhile
#   log-sigint, log-sigterm
#              the signal ends it, and the copy of the UART output (+console_log) is
#              complete: it ends with the output of the last command and the prompt
#   sigint, sigterm, sighup, sigquit, sigpipe, sigabrt, sigalrm, sigusr1, sigsegv
#              the signal, sent with kill, ends it (the process dies of the signal)
#   sighup-ignored
#              started with SIGHUP ignored, as under nohup: the signal stays ignored, and
#              Ctrl-] ends the simulation
#   pipe       stdout is a pipe whose reader goes away (as with `make freertos-shell | head`):
#              the next output raises SIGPIPE, which ends it
#   sigtstp    stopped with SIGTSTP (the terminal is restored meanwhile), continued with
#              SIGCONT (raw mode again), then Ctrl-]
#   pty        +console_pty: the UART on a separate pseudo-terminal, used by a client that
#              opens the printed device; 'halt' ends the simulation, the symlink goes away
#   pty-ctrlc  +console_pty and +console_log: Ctrl-C typed in the simulator's own terminal
#              (SIGINT) ends it; the symlink goes away and the UART copy is complete
# After every case the terminal settings must be exactly those from before the start, both
# as termios attributes and as `stty -g` prints them.
# Prints one line per case and "TTY TEST: PASS" or "TTY TEST: FAIL" (exit status 0 / 1).
# ---------------------------------------------------------------------------------------------
import argparse
import os
import pty
import re
import select
import signal
import subprocess
import sys
import termios
import time
import tty

PROMPT = b'hades> '

# Starts the simulator the way an interactive shell in a terminal window does: in a session
# whose controlling terminal is the pseudo-terminal, as a job in a process group of its own
# in the foreground (so SIGTSTP stops it, as Ctrl-Z would in a real terminal), with every
# signal at its default action (an ignored signal would stay ignored across the exec: Python
# ignores SIGPIPE and SIGXFSZ, and a test started in the background or under nohup inherits
# ignored SIGINT, SIGQUIT or SIGHUP). argv[2] is the program, argv[3:] its arguments; with
# argv[2] = '--ignore=<n>' signal n stays ignored (and the program follows). Reports the
# program's pid on the pipe given as argv[1]; exits with its status (128 + n: killed by
# signal n).
LAUNCHER = r"""
import fcntl, os, signal, sys, termios
os.setsid()
fcntl.ioctl(0, termios.TIOCSCTTY, 0)
argv = sys.argv[2:]
keep = int(argv.pop(0).split('=')[1]) if argv[0].startswith('--ignore=') else None
pid = os.fork()
if pid == 0:
    os.setpgid(0, 0)
    signal.signal(signal.SIGTTOU, signal.SIG_IGN)
    os.tcsetpgrp(0, os.getpid())
    for s in signal.valid_signals():
        if s not in (signal.SIGKILL, signal.SIGSTOP):
            try:
                signal.signal(s, signal.SIG_IGN if s == keep else signal.SIG_DFL)
            except (OSError, ValueError):
                pass
    os.execv(argv[0], argv)
os.write(int(sys.argv[1]), str(pid).encode())
os.close(int(sys.argv[1]))
while True:
    _, st = os.waitpid(pid, os.WUNTRACED)
    if not os.WIFSTOPPED(st):
        break
sys.exit(128 + os.WTERMSIG(st) if os.WIFSIGNALED(st) else os.WEXITSTATUS(st))
"""


def stty_g(fd):
    """The terminal settings of fd as `stty -g` prints them."""
    r = subprocess.run(['stty', '-g'], stdin=fd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    return r.stdout.strip()


class Session:
    """The simulator on a pseudo-terminal: its stdin, stdout and stderr are the slave side
    (stdout is a pipe instead with stdout_pipe=True)."""

    def __init__(self, sim, cwd, extra=(), timeout='9000000000000000000', stdout_pipe=False, ignore=None):
        self.master, self.slave = pty.openpty()
        # A terminal in its usual "cooked" state, as a shell leaves it.
        attrs = termios.tcgetattr(self.slave)
        attrs[3] |= termios.ICANON | termios.ECHO | termios.ISIG
        termios.tcsetattr(self.slave, termios.TCSANOW, attrs)
        self.before = termios.tcgetattr(self.slave)
        self.before_stty = stty_g(self.slave)
        self.out = b''
        self.pipe_rd = None
        self.pipe_out = b''
        stdout = self.slave
        if stdout_pipe:
            self.pipe_rd, stdout = os.pipe()
        rd, wr = os.pipe()
        self.proc = subprocess.Popen([sys.executable, '-c', LAUNCHER, str(wr)]
                                     + ([f'--ignore={int(ignore)}'] if ignore else [])
                                     + [sim, '+nodump', f'+timeout={timeout}'] + list(extra),
                                     cwd=cwd, stdin=self.slave, stdout=stdout,
                                     stderr=self.slave, pass_fds=(wr,))
        os.close(wr)
        if stdout_pipe:
            os.close(stdout)
        self.pid = int(os.read(rd, 32) or b'0')
        os.close(rd)

    def read(self, timeout=0.2):
        end = time.time() + timeout
        while True:
            left = end - time.time()
            if left <= 0:
                return
            fds = [self.master] + ([self.pipe_rd] if self.pipe_rd is not None else [])
            r, _, _ = select.select(fds, [], [], left)
            if not r:
                return
            for fd in r:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    data = b''
                if fd == self.master:
                    if not data:
                        return
                    self.out += data
                elif data:
                    self.pipe_out += data
                else:   # the simulator closed its stdout
                    os.close(self.pipe_rd)
                    self.pipe_rd = None

    def close_pipe(self):
        """The reader of the simulator's stdout goes away."""
        if self.pipe_rd is not None:
            os.close(self.pipe_rd)
            self.pipe_rd = None

    def text(self, start=0):
        """The output since byte `start`, without CRs (the terminal adds some of its own)."""
        return self.out[start:].replace(b'\r', b'')

    def expect(self, pattern, timeout=60.0, start=0):
        """Waits until the output (without CRs) matches the regex; returns the match."""
        rx = re.compile(pattern)
        end = time.time() + timeout
        while time.time() < end:
            m = rx.search(self.text(start))
            if m:
                return m
            self.read(0.2)
        raise AssertionError(f'timed out waiting for {pattern!r}; last output: {self.out[-300:]!r}')

    def type(self, text, delay=0.02):
        for ch in text:
            os.write(self.master, bytes([ch]))
            time.sleep(delay)

    def command(self, line, timeout=60.0):
        """Types a line and Enter, waits for the next prompt; returns the output of the line."""
        start = len(self.out)
        self.type(line + b'\r')
        self.expect(re.escape(PROMPT), timeout, start)
        return self.text(start)

    def signal(self, sig):
        os.kill(self.pid, sig)

    def lflag(self):
        return termios.tcgetattr(self.slave)[3]

    def wait(self, timeout=60.0):
        """Waits for the simulator to end; returns its exit status (-n: killed by signal n)."""
        end = time.time() + timeout
        while self.proc.poll() is None and time.time() < end:
            self.read(0.2)
        if self.proc.poll() is None:
            raise AssertionError(f'the simulator did not end within {timeout:.0f} s; '
                                 f'raw mode still on: {self.lflag() & RAW_OFF == 0}')
        self.read(0.3)
        rc = self.proc.returncode
        return -(rc - 128) if rc > 128 else rc

    def restored(self):
        """The terminal settings are those from before: termios attributes and `stty -g`."""
        return termios.tcgetattr(self.slave) == self.before and stty_g(self.slave) == self.before_stty

    def close(self):
        if self.proc.poll() is None:
            try:
                os.kill(self.pid, signal.SIGKILL)
            except OSError:
                pass
            self.proc.wait()
        self.close_pipe()
        for fd in (self.master, self.slave):
            try:
                os.close(fd)
            except OSError:
                pass


RAW_OFF = termios.ICANON | termios.ECHO | termios.ISIG


def boot(s):
    s.expect(rb'hades> ', 30)
    assert s.lflag() & RAW_OFF == 0, 'the terminal is not in raw mode during the session'


def case_keys(sim, d):
    s = Session(sim, d)
    try:
        boot(s)
        out = s.command(b'div -7 2')
        assert re.search(rb'div\s+-3\s+0xfffffffd', out), out
        out = s.command(b'echo abX\x7fc')                                  # DEL
        assert b'\nabc\n' in out, out
        start = len(s.out)
        s.type(b'echo gone\x03')                                         # Ctrl-C: no SIGINT in raw mode
        s.expect(rb'echo gone\^C\nhades> ', start=start)
        assert s.proc.poll() is None, 'Ctrl-C stopped the simulator instead of reaching the program'
        out = s.command(b'echo old\x15echo new')                           # Ctrl-U
        assert b'\nnew\n' in out and b'\nold\n' not in out, out
        out = s.command(b'\x1b[A')                                          # Up arrow: 'echo new' again
        assert b'echo new' in out and b'\nnew\n' in out, out
        s.type(b'\x1d')                                                   # Ctrl-]
        rc = s.wait()
        s.expect(rb'\[console\] Ctrl-\] pressed')
        assert rc == 0, f'exit status {rc}'
        assert s.restored(), 'terminal settings not restored'
        return 'raw mode; div, DEL, Ctrl-C, Ctrl-U, Up arrow; Ctrl-] ended it (status 0)'
    finally:
        s.close()


def case_esc(sim, d):
    s = Session(sim, d)
    try:
        boot(s)
        start = len(s.out)                                                # Esc, then Enter
        s.type(b'echo esc-one\x1b')
        time.sleep(0.2)
        s.type(b'\r')
        s.expect(rb'\nesc-one\nhades> ', 60, start)
        out = s.command(b'\x1becho esc-two')                               # Esc, then a letter
        assert b'\nesc-two\n' in out, out
        start = len(s.out)                                                # Esc, then Ctrl-C
        s.type(b'echo esc-three\x1b\x03')
        s.expect(rb'echo esc-three\^C\nhades> ', 60, start)
        assert b'\nesc-three\n' not in s.text(start), s.text(start)
        start = len(s.out)                                                # Esc, a pause, then O x
        s.type(b'\x1b')
        time.sleep(3.0)
        s.type(b'Ox\r')
        s.expect(rb'^Ox\nCommand not recognised[^\n]*\n+hades> ', 60, start)
        s.type(b'\x1d')
        rc = s.wait()
        assert rc == 0, f'exit status {rc}'
        assert s.restored(), 'terminal settings not restored'
        return 'a lone Esc swallowed neither Enter, a letter nor Ctrl-C; after a pause it ended by itself'
    finally:
        s.close()


def case_paste(sim, d):
    s = Session(sim, d)
    try:
        boot(s)
        start = len(s.out)
        block = b''.join(b'mul %d 3\r' % i for i in range(1, 13)) + b'uart\r'
        os.write(s.master, block)                                         # all at once, as a paste
        s.expect(rb'dropped:\s+0 .*\noverruns:\s+0 .*\nhades> $', 120, start)
        out = s.text(start)
        for i in range(1, 13):
            assert re.search(rb'\n  mul\s+%d\s' % (3 * i), out), f'mul {i} 3 missing or wrong'
        assert b'Command not recognised' not in out, 'a pasted line arrived damaged'
        s.type(b'\x1d')
        rc = s.wait()
        assert rc == 0 and s.restored(), f'exit status {rc}, restored {s.restored()}'
        return f'13 lines pasted at once ({len(block)} characters): all ran, none dropped'
    finally:
        s.close()


def case_exit(sim, d):
    s = Session(sim, d)
    try:
        boot(s)
        s.type(b'exit\r')
        rc = s.wait()
        s.expect(rb'FRTOS-RESULT: PASS')
        s.expect(rb'All tests passed')
        assert rc == 0, f'exit status {rc}'
        assert s.restored(), 'terminal settings not restored'
        return "'exit' ended it through the test register (status 0)"
    finally:
        s.close()


def case_timeout(sim, d):
    s = Session(sim, d, timeout='400000')
    try:
        rc = s.wait(120)
        s.expect(rb'Simulation timeout!')
        assert s.restored(), 'terminal settings not restored'
        return f'the cycle limit ended it ($finish, status {rc})'
    finally:
        s.close()


def case_quit_pending(sim, d):
    # A program that never reads the UART: one instruction, `j .` (0x0000006f), at the reset
    # address. The first typed character is shifted into the UART and stays in its receive
    # buffer; the bridge's injector then waits for the program to read it, for ever.
    run = os.path.join(d, 'tty-hang')
    os.makedirs(run, exist_ok=True)
    with open(os.path.join(run, 'init.mem'), 'w') as f:
        f.write('@00000000\n0000006F\n')
    s = Session(sim, run)
    try:
        s.expect(rb'\[console\] the UART is connected to this terminal', 30)
        assert s.lflag() & RAW_OFF == 0, 'the terminal is not in raw mode during the session'
        s.type(b'x')                                     # into the UART, never read
        time.sleep(2.0)
        s.type(b'more keys\r')                           # wait in the bridge's queue
        time.sleep(1.0)
        assert s.proc.poll() is None, 'the simulator ended before Ctrl-]'
        s.type(b'\x1d')                                  # Ctrl-]
        rc = s.wait(30)
        s.expect(rb'\[console\] Ctrl-\] pressed')
        assert rc == 0, f'exit status {rc}'
        assert s.restored(), 'terminal settings not restored'
        return 'Ctrl-] ended it (status 0) while a typed character waited unread in the UART'
    finally:
        s.close()


def case_log_signal(sig):
    def run(sim, d):
        log = os.path.join(d, f'tty-test-{signal.Signals(sig).name.lower()}.log')
        if os.path.exists(log):
            os.remove(log)
        s = Session(sim, d, [f'+console_log={log}'])
        try:
            boot(s)
            out = s.command(b'echo log-marker')
            assert b'\nlog-marker\n' in out, out
            time.sleep(0.5)
            s.signal(sig)
            rc = s.wait()
            assert rc == -sig, f'exit status {rc}, expected death by signal {sig}'
            assert s.restored(), 'terminal settings not restored'
            with open(log, 'rb') as f:
                data = f.read()
            assert data.startswith(b'\r\nHaDes-V+ shell on FreeRTOS'), f'the copy does not start with the banner: {data[:60]!r}'
            assert data.endswith(b'hades> echo log-marker\r\nlog-marker\r\nhades> '), \
                f'the copy is not complete ({len(data)} bytes), it ends with {data[-60:]!r}'
            return f'{signal.Signals(sig).name} ended it; the UART copy is complete ({len(data)} bytes, up to the last prompt)'
        finally:
            s.close()
    return run


def case_signal(sig):
    def run(sim, d):
        s = Session(sim, d)
        try:
            boot(s)
            s.signal(sig)
            rc = s.wait()
            assert rc == -sig, f'exit status {rc}, expected death by signal {sig}'
            assert s.restored(), 'terminal settings not restored'
            return f'{signal.Signals(sig).name} ended it (the process died of the signal)'
        finally:
            s.close()
    return run


def case_sighup_ignored(sim, d):
    s = Session(sim, d, ignore=signal.SIGHUP)        # as under nohup
    try:
        boot(s)
        s.signal(signal.SIGHUP)
        time.sleep(1.0)
        assert s.proc.poll() is None, 'an ignored SIGHUP ended the simulator'
        out = s.command(b'echo still here')
        assert b'\nstill here\n' in out, out
        s.type(b'\x1d')
        rc = s.wait()
        assert rc == 0, f'exit status {rc}'
        assert s.restored(), 'terminal settings not restored'
        return 'started with SIGHUP ignored (nohup): SIGHUP stayed ignored; Ctrl-] ended it'
    finally:
        s.close()


def case_pipe(sim, d):
    s = Session(sim, d, stdout_pipe=True)
    try:
        end = time.time() + 30
        while PROMPT not in s.pipe_out:                  # the UART echo goes to the pipe
            assert time.time() < end, f'no prompt on stdout: {s.pipe_out[-200:]!r}'
            s.read(0.2)
        assert s.lflag() & RAW_OFF == 0, 'the terminal is not in raw mode during the session'
        s.close_pipe()                                   # the reader goes away
        s.type(b'uptime\r')                              # the echo and the output raise SIGPIPE
        rc = s.wait()
        assert rc == -signal.SIGPIPE, f'exit status {rc}, expected death by SIGPIPE'
        assert s.restored(), 'terminal settings not restored'
        return 'the reader of stdout went away; the next output raised SIGPIPE, which ended it'
    finally:
        s.close()


def case_sigtstp(sim, d):
    s = Session(sim, d)
    try:
        boot(s)
        s.signal(signal.SIGTSTP)
        time.sleep(1.0)
        with open(f'/proc/{s.pid}/stat') as f:
            state = f.read().split(')')[-1].split()[0]
        assert state == 'T', f'process state {state!r}, expected stopped (T)'
        assert s.restored(), 'terminal settings not restored while stopped'
        s.signal(signal.SIGCONT)
        time.sleep(1.0)
        assert s.lflag() & RAW_OFF == 0, 'raw mode not re-entered after SIGCONT'
        out = s.command(b'echo back')
        assert b'\nback\n' in out, out
        s.type(b'\x1d')
        rc = s.wait()
        assert rc == 0, f'exit status {rc}'
        assert s.restored(), 'terminal settings not restored'
        return 'SIGTSTP stopped it with the terminal restored, SIGCONT raw again; Ctrl-] ended it'
    finally:
        s.close()


def open_device(s, link):
    """Opens the pseudo-terminal of a +console_pty run as a terminal program does."""
    m = s.expect(rb'pseudo-terminal (/dev/pts/\d+)', 60)
    dev = m.group(1).decode()
    assert os.path.realpath(link) == dev, f'{link} does not point to {dev}'
    assert s.restored(), 'PTY mode changed the settings of its own terminal'
    fd = os.open(link, os.O_RDWR | os.O_NOCTTY)
    tty.setraw(fd, termios.TCSANOW)   # TCSANOW: keep what the shell printed before we attached
    return fd, dev


def device_until(s, fd, got, rx, timeout=120):
    """Reads the device until its output matches rx; returns the output so far."""
    end = time.time() + timeout
    while not re.search(rx, got):
        assert time.time() < end, f'timed out on the device waiting for {rx!r}: {got[-200:]!r}'
        s.read(0.05)   # the simulator also prints everything to its own terminal: drain it
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                got += os.read(fd, 65536)
            except OSError:   # EIO: the simulator has ended and hung the device up
                break
    assert re.search(rx, got), f'the device was hung up before {rx!r} arrived: {got[-200:]!r}'
    return got


def device_type(fd, text):
    for ch in text:
        os.write(fd, bytes([ch]))
        time.sleep(0.02)


def case_pty(sim, d):
    link = os.path.join(d, 'tty-test-pty')
    s = Session(sim, d, ['+console_pty', f'+console_pty_link={link}'])
    try:
        fd, dev = open_device(s, link)
        got = device_until(s, fd, b'', rb'hades> ')
        device_type(fd, b'version\r')
        got = device_until(s, fd, got, rb'cpu:\s+M \w+.*\r\nhades> ')
        device_type(fd, b'halt\r')
        got = device_until(s, fd, got, rb'FRTOS-RESULT: PASS')
        rc = s.wait()
        os.close(fd)
        assert rc == 0, f'exit status {rc}'
        assert not os.path.lexists(link), 'the symbolic link was not removed'
        assert s.restored(), 'terminal settings changed'
        return f'UART on {dev} (link {os.path.basename(link)}): a client ran version and halt; link removed'
    finally:
        s.close()


def case_pty_ctrlc(sim, d):
    link = os.path.join(d, 'tty-test-pty')
    log = os.path.join(d, 'tty-test-pty.log')
    if os.path.exists(log):
        os.remove(log)
    s = Session(sim, d, ['+console_pty', f'+console_pty_link={link}', f'+console_log={log}'])
    try:
        fd, dev = open_device(s, link)
        got = device_until(s, fd, b'', rb'hades> ')
        device_type(fd, b'echo pty-marker\r')
        got = device_until(s, fd, got, rb'pty-marker\r\nhades> ')
        time.sleep(0.5)
        os.write(s.master, b'\x03')                       # Ctrl-C in the simulator's terminal
        rc = s.wait()
        os.close(fd)
        assert rc == -signal.SIGINT, f'exit status {rc}, expected death by SIGINT'
        assert not os.path.lexists(link), 'the symbolic link was not removed'
        assert s.restored(), 'terminal settings changed'
        with open(log, 'rb') as f:
            data = f.read()
        assert data.endswith(b'hades> echo pty-marker\r\npty-marker\r\nhades> '), \
            f'the copy is not complete ({len(data)} bytes), it ends with {data[-60:]!r}'
        return f'Ctrl-C in the simulator\'s terminal ended a PTY session; link removed, UART copy complete ({len(data)} bytes)'
    finally:
        s.close()


CASES = [('keys', case_keys), ('esc', case_esc), ('paste', case_paste), ('exit', case_exit),
         ('timeout', case_timeout), ('quit-pending', case_quit_pending),
         ('log-sigint', case_log_signal(signal.SIGINT)), ('log-sigterm', case_log_signal(signal.SIGTERM)),
         ('sigint', case_signal(signal.SIGINT)), ('sigterm', case_signal(signal.SIGTERM)),
         ('sighup', case_signal(signal.SIGHUP)), ('sigquit', case_signal(signal.SIGQUIT)),
         ('sigpipe', case_signal(signal.SIGPIPE)), ('sigabrt', case_signal(signal.SIGABRT)),
         ('sigalrm', case_signal(signal.SIGALRM)), ('sigusr1', case_signal(signal.SIGUSR1)),
         ('sigsegv', case_signal(signal.SIGSEGV)), ('sighup-ignored', case_sighup_ignored),
         ('pipe', case_pipe), ('sigtstp', case_sigtstp),
         ('pty', case_pty), ('pty-ctrlc', case_pty_ctrlc)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--sim', required=True)
    ap.add_argument('--dir', required=True)
    ap.add_argument('--only', default='')
    a = ap.parse_args()
    failed = ran = 0
    print('=' * 78)
    for name, fn in CASES:
        if a.only and name not in a.only.split(','):
            continue
        ran += 1
        try:
            what = fn(a.sim, a.dir)
            print(f'  PASS  {name:14s} {what}', flush=True)
        except AssertionError as e:
            failed += 1
            print(f'  FAIL  {name:14s} {e}', flush=True)
    print(f'TTY TEST: {"PASS" if not failed and ran else "FAIL"}  ({ran - failed} of {ran} cases passed)')
    print('=' * 78)
    return 1 if failed or not ran else 0


if __name__ == '__main__':
    sys.exit(main())
