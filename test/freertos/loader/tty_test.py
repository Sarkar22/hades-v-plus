# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------------------------------
# tty_test.py -- checks the file transfers of the console bridge (sim/console.cpp) with the
# app loader, the way a person uses them: `make freertos-shell-tty-test APP=loader`
# (test/freertos/loader/SPEC.md, section 10.3).
#
#   python3 tty_test.py --sim <console simulator> --dir <run dir> --upload-dir <SDK_OUT>
#                       [--only <name>[,<name>...]]
#
# Every case starts the simulator on a pseudo-terminal of its own, as in a terminal window
# (the harness of test/freertos/shell/tty_test.py), with +console_upload_dir=<SDK_OUT> as the
# console targets give it, types with pauses like a person, and checks what appears:
#   upload       +console_upload=<a scratch copy of hello.hex>: 'load', 'run' and 'app' typed
#                ahead at once give 'loaded hello', code 0 and the app's name (the input typed
#                ahead waits for the prompt that ends the upload); the copy is replaced by
#                tiny.hex, and the next 'load' gives 'loaded tiny' (the file is read at every
#                request); 'run' gives code 7
#   paste        no +console_upload: 'load', then all of hello.hex written to the terminal at
#                once, followed by an empty line, two records after its end-of-file record
#                and the command 'app': 'loaded hello'; the empty line and the records are
#                dropped (one prompt, no 'Command not recognised'), 'app' runs; 'uart' shows
#                nothing dropped and no overrun
#   pty-send     +console_pty: a client holds the device in exclusive mode, as screen does; a
#                send request (<link>.upload, as make freertos-send writes it) is answered
#                "ok" and the client sees 'loaded hello', types 'run', sees code 0; while
#                'run loop' of crash runs, a request is refused and nothing reaches the app;
#                Ctrl-C; 'load' typed by the client, then a request: "ok waiting", 'loaded
#                hello'; then 'halt'
#   pty-cat      +console_pty, a client in exclusive mode; a second writer writes 'load', CR
#                and compute.hex into the device, as 'cat' does; the client types Ctrl-C while
#                the file arrives: 'load cancelled', and the rest of the file does not reach
#                the command line; 'app' gives 'no app loaded'
#   input        'run' of upper: abc typed with pauses, Enter, xyz, Enter, Enter: ABC, XYZ, code
#                2; every answer within 10 seconds of its Enter, and every echo within 3 (the
#                DC1 rule: without it the keys after an Enter would wait 10 million cycles)
#   ctrl-c       'run loop' of crash; a second later Ctrl-C: 'stopped by Ctrl-C' within 10
#                seconds; 'tasks' shows 3 tasks (the app's task is gone)
#   ctrl-c-ahead 'run spin' of crash (an app that reads no input), with a Ctrl-C typed right
#                after its Enter, at once: 'stopped by Ctrl-C' within 10 seconds
#   ctrl-c-load  +console_upload=<compute.hex>: 'load', Ctrl-C while the file is being sent:
#                the bridge's note, 'load cancelled'; no 'Command not recognised' within the
#                next 3 seconds (the rest of the file was dropped); 'app' gives 'no app loaded'
# After every case the simulator has ended with exit status 0 (Ctrl-] or 'halt') and the
# terminal settings are those from before. Scratch files: <run dir>/tty-test-upload.hex and
# the link <run dir>/tty-test-pty (with its send request and answer files).
# Prints one line per case and "LOADER TTY TEST: PASS" or "LOADER TTY TEST: FAIL".
# ---------------------------------------------------------------------------------------------
import argparse
import fcntl
import importlib.util
import os
import re
import select
import sys
import termios
import time

# The harness of the shell's interactive test: Session (the simulator on a pseudo-terminal),
# boot(), open_device(), device_type().
sys.dont_write_bytecode = True
_SPEC = importlib.util.spec_from_file_location(
    'shell_tty_test', os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'shell', 'tty_test.py'))
T = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(T)

LOADED = rb'loaded %s: \d+ bytes at 0x00060000, entry 0x[0-9a-f]{8}, CRC32 0x[0-9a-f]{8}\n'
CONTROL = b'\x06\x11\x12\x15'   # ACK, DC1, DC2, NAK: for the bridge; a terminal does not show them


class Session(T.Session):
    """The session of the shell's test; its output is matched without the control bytes."""

    def text(self, start=0):
        return super().text(start).translate(None, CONTROL)


def device_until(s, fd, got, rx, timeout=120):
    """Reads the device until its output, without the control bytes, matches rx (as
    T.device_until() does); returns the output so far."""
    end = time.time() + timeout
    while not re.search(rx, got.translate(None, CONTROL)):
        assert time.time() < end, f'timed out on the device waiting for {rx!r}: {got[-200:]!r}'
        s.read(0.05)   # the simulator also prints everything to its own terminal: drain it
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                got += os.read(fd, 65536)
            except OSError:   # EIO: the simulator has ended and hung the device up
                break
    assert re.search(rx, got.translate(None, CONTROL)), \
        f'the device was hung up before {rx!r} arrived: {got[-200:]!r}'
    return got


def sdk_file(up, name):
    path = os.path.join(up, name)
    if not os.path.exists(path):
        raise AssertionError(f'{path} is missing (make freertos-apps builds it)')
    with open(path, 'rb') as f:
        return f.read()


def finish(s):
    """Ctrl-]: the simulator ends with status 0 and restores the terminal."""
    s.type(b'\x1d')
    rc = s.wait()
    assert rc == 0, f'exit status {rc}'
    assert s.restored(), 'terminal settings not restored'


def case_upload(sim, d, up):
    scratch = os.path.join(d, 'tty-test-upload.hex')
    with open(scratch, 'wb') as f:
        f.write(sdk_file(up, 'rv32i/hello.hex'))
    s = Session(sim, d, [f'+console_upload={scratch}', f'+console_upload_dir={up}'])
    try:
        T.boot(s)
        start = len(s.out)
        s.type(b'load\rrun\rapp\r')                                      # typed ahead
        s.expect(LOADED % b'hello' + rb'hades> run\n(.*\n)*app: hello exited with code 0 after \d+ cycles\n'
                 rb'hades> app\nname: +hello \(ABI 1\)\n(.*\n){3}hades> $', 120, start)
        tmp = scratch + '.new'
        with open(tmp, 'wb') as f:
            f.write(sdk_file(up, 'testfiles/tiny.hex'))
        os.replace(tmp, scratch)
        out = s.command(b'load')
        assert b'loaded tiny: 72 bytes at 0x00060000, entry 0x00060040, CRC32 0xa0537c91\n' in out, out
        out = s.command(b'run')
        assert re.search(rb'\napp: tiny exited with code 7 after \d+ cycles\n', out), out
        finish(s)
        return ('load, run, app typed ahead: loaded hello, code 0, app hello; then tiny from the same '
                'file name (read at every request): code 7')
    finally:
        s.close()


def case_paste(sim, d, up):
    s = Session(sim, d, [f'+console_upload_dir={up}'])
    try:
        T.boot(s)
        data = sdk_file(up, 'rv32i/hello.hex')
        lines = data.splitlines()
        extra = b'\r\n' + lines[1] + b'\r\n' + lines[2] + b'\r\n'      # after the end-of-file record
        start = len(s.out)
        s.type(b'load\r')
        s.expect(rb'load: waiting for an Intel HEX file \(Ctrl-C cancels\)\n', 60, start)
        s.expect(rb'\[console\] the program asks for a file: paste it', 30, start)
        os.write(s.master, data + extra + b'app\r')                    # all at once, as a paste
        s.expect(LOADED % b'hello' + rb'hades> \n(\[console\] .*\n)?app\nname: +hello \(ABI 1\)\n(.*\n){3}hades> $',
                 120, start)
        m = s.expect(rb'\[console\] dropped (\d+) line\(s\) of the file that the program did not read', 10, start)
        assert int(m.group(1)) == 2, m.group(0)
        assert s.text(start).count(b'hades> ') == 2, 'an empty line or a record reached the command line'
        out = s.command(b'uart')
        assert re.search(rb'\ndropped:\s+0 ', out) and re.search(rb'\noverruns:\s+0 ', out), out
        assert b'Command not recognised' not in s.text(start), 'part of the paste reached the command line'
        finish(s)
        return (f'{len(data)} bytes pasted at once, then an empty line, 2 records and app: loaded hello; '
                f'the records dropped, app ran; uart: dropped 0, overruns 0')
    finally:
        s.close()


def send_request(link, path, timeout=30):
    """What make freertos-send does: the request <link>.upload, written in one step, and the
    bridge's answer, <link>.upload-answer."""
    answer = link + '.upload-answer'
    if os.path.exists(answer):
        os.remove(answer)
    with open(link + '.upload.tmp', 'w') as f:
        f.write(path + '\n')
    os.replace(link + '.upload.tmp', link + '.upload')
    end = time.time() + timeout
    while not os.path.exists(answer):
        assert time.time() < end, 'the simulator did not answer the send request'
        time.sleep(0.1)
    with open(answer) as f:
        text = f.read().strip()
    os.remove(answer)
    return text


def pty_end(s, fd, got, link):
    """'halt' typed by the client: the simulator ends with status 0 and removes its files."""
    T.device_type(fd, b'halt\r')
    got = device_until(s, fd, got, rb'FRTOS-RESULT: PASS')
    rc = s.wait()
    os.close(fd)
    assert rc == 0, f'exit status {rc}'
    assert not os.path.lexists(link), 'the symbolic link was not removed'
    assert not os.path.lexists(link + '.upload'), 'the send request was not removed'
    assert s.restored(), 'terminal settings changed'


def case_pty_send(sim, d, up):
    link = os.path.join(d, 'tty-test-pty')
    s = Session(sim, d, ['+console_pty', f'+console_pty_link={link}', f'+console_upload_dir={up}'])
    try:
        fd, dev = T.open_device(s, link)
        fcntl.ioctl(fd, termios.TIOCEXCL)                                # as screen does
        got = device_until(s, fd, b'', rb'hades> ')
        time.sleep(0.5)
        sdk_file(up, 'rv32i/hello.hex')
        answer = send_request(link, os.path.join(up, 'rv32i/hello.hex'))
        assert answer == 'ok', answer
        got = device_until(s, fd, got, (LOADED % b'hello').replace(rb'\n', rb'\r\n') + rb'hades> ')
        T.device_type(fd, b'run\r')
        got = device_until(s, fd, got, rb'app: hello exited with code 0 after \d+ cycles\r\nhades> ')
        answer = send_request(link, os.path.join(up, 'rv32i/crash.hex'))
        assert answer == 'ok', answer
        got = device_until(s, fd, got, (LOADED % b'crash').replace(rb'\n', rb'\r\n') + rb'hades> ')
        T.device_type(fd, b'run loop\r')
        got = device_until(s, fd, got, rb'crash: loop\r\n')
        mark = len(got)
        refused = send_request(link, os.path.join(up, 'rv32i/hello.hex'))
        assert refused.startswith('refused: the shell is not at its prompt'), refused
        T.device_type(fd, b'\x03')
        got = device_until(s, fd, got, rb'app: crash stopped by Ctrl-C after \d+ cycles\r\nhades> ')
        assert b'load' not in got[mark:], 'the refused request typed into the app'
        mark = len(got)
        T.device_type(fd, b'load\r')                                    # typed by hand
        end = time.time() + 30
        while b'\x12' not in got[mark:]:                                # the DC2 of 'load'
            assert time.time() < end, f'no DC2 after load: {got[-80:]!r}'
            s.read(0.05)
            r, _, _ = select.select([fd], [], [], 0.2)
            if r:
                got += os.read(fd, 65536)
        answer = send_request(link, os.path.join(up, 'rv32i/hello.hex'))
        assert answer == 'ok waiting', answer
        got = device_until(s, fd, got, rb'crash stopped by Ctrl-C(.|\r|\n)*' +
                           (LOADED % b'hello').replace(rb'\n', rb'\r\n') + rb'hades> ')
        pty_end(s, fd, got, link)
        return (f'{dev} held in exclusive mode by the client; send requests: hello ok, loaded, code 0; '
                f'while an app ran: "{refused}"; to a load typed by hand: ok waiting, loaded')
    finally:
        s.close()


def case_pty_cat(sim, d, up):
    link = os.path.join(d, 'tty-test-pty')
    s = Session(sim, d, ['+console_pty', f'+console_pty_link={link}', f'+console_upload_dir={up}'])
    try:
        fd, dev = T.open_device(s, link)
        fcntl.ioctl(fd, termios.TIOCEXCL)                                # as screen does
        got = device_until(s, fd, b'', rb'hades> ')
        time.sleep(0.5)
        data = sdk_file(up, 'rv32i/compute.hex')
        w = os.open(link, os.O_WRONLY | os.O_NOCTTY)                     # as cat does
        os.write(w, b'load\r' + data)
        os.close(w)
        got = device_until(s, fd, got, rb'load: waiting for an Intel HEX file')
        time.sleep(1.0)
        T.device_type(fd, b'\x03')
        got = device_until(s, fd, got, rb'\r\nload cancelled\r\nhades> ')
        mark = len(got)
        m = s.expect(rb'\[console\] dropped (\d+) line\(s\) of the file that the program did not read', 30)
        end = time.time() + 3.0                                          # whatever follows
        while time.time() < end:
            s.read(0.05)
            r, _, _ = select.select([fd], [], [], 0.2)
            if r:
                got += os.read(fd, 65536)
        assert b'Command not recognised' not in got, 'the rest of the file reached the command line'
        assert got[mark:].translate(None, CONTROL) == b'', f'output after the cancel: {got[mark:][:200]!r}'
        T.device_type(fd, b'app\r')
        got = device_until(s, fd, got, rb'no app loaded\r\nhades> ')
        pty_end(s, fd, got, link)
        return (f'{dev} in exclusive mode; load and compute.hex written by a second writer, Ctrl-C: '
                f'load cancelled, {int(m.group(1))} lines of the file dropped, none reached the command line')
    finally:
        s.close()


def case_input(sim, d, up):
    s = Session(sim, d, ['+console_upload=rv32i/upper.hex', f'+console_upload_dir={up}'])
    try:
        T.boot(s)
        out = s.command(b'load')
        assert re.search(LOADED % b'upper', out), out
        start = len(s.out)
        s.type(b'run\r')
        s.expect(rb'upper: type lines; an empty line ends\n> $', 60, start)
        answers, echoes = [], []

        def key(ch, answer):
            mark = len(s.out)
            t0 = time.time()
            s.type(ch)
            s.expect(answer, 10, mark)
            return time.time() - t0

        for word, upper in ((b'abc', b'ABC'), (b'xyz', b'XYZ')):
            for ch in word:
                echoes.append(key(bytes([ch]), re.escape(bytes([ch]))))
                time.sleep(0.3)
            answers.append(key(b'\r', rb'\n' + upper + rb'\n> '))
        answers.append(key(b'\r', rb'\napp: upper exited with code 2 after \d+ cycles\nhades> '))
        assert max(echoes) < 3.0, f'an echo took {max(echoes):.1f} s (the keys after an Enter waited)'
        finish(s)
        return (f'ABC, XYZ, code 2; answers after {", ".join(f"{t:.2f}" for t in answers)} s, '
                f'echoes after at most {max(echoes):.2f} s')
    finally:
        s.close()


def case_ctrl_c(sim, d, up):
    s = Session(sim, d, ['+console_upload=rv32i/crash.hex', f'+console_upload_dir={up}'])
    try:
        T.boot(s)
        out = s.command(b'load')
        assert re.search(LOADED % b'crash', out), out
        start = len(s.out)
        s.type(b'run loop\r')
        s.expect(rb'crash: loop\n', 60, start)
        time.sleep(1.0)
        t0 = time.time()
        s.type(b'\x03')
        s.expect(rb'\napp: crash stopped by Ctrl-C after \d+ cycles\nhades> ', 10, start)
        dt = time.time() - t0
        out = s.command(b'tasks')
        assert re.search(rb'\n3 tasks\n', out), out
        finish(s)
        return f'stopped by Ctrl-C {dt:.2f} s after the key; tasks: 3 tasks'
    finally:
        s.close()


def case_ctrl_c_ahead(sim, d, up):
    s = Session(sim, d, ['+console_upload=rv32i/crash.hex', f'+console_upload_dir={up}'])
    try:
        T.boot(s)
        out = s.command(b'load')
        assert re.search(LOADED % b'crash', out), out
        start = len(s.out)
        t0 = time.time()
        os.write(s.master, b'run spin\r\x03')                         # at once
        s.expect(rb'\napp: crash stopped by Ctrl-C after \d+ cycles\nhades> ', 10, start)
        dt = time.time() - t0
        finish(s)
        return f"'run spin', Enter and Ctrl-C typed at once: stopped by Ctrl-C after {dt:.2f} s"
    finally:
        s.close()


def case_ctrl_c_load(sim, d, up):
    size = len(sdk_file(up, 'rv32i/compute.hex'))
    s = Session(sim, d, ['+console_upload=rv32i/compute.hex', f'+console_upload_dir={up}'])
    try:
        T.boot(s)
        start = len(s.out)
        s.type(b'load\r')
        s.expect(rb'\[console\] sending .*compute\.hex \(%d bytes\)' % size, 60, start)
        time.sleep(0.5)
        s.type(b'\x03')
        m = s.expect(rb'\[console\] Ctrl-C: the upload stops after (\d+) of %d bytes; the rest of the file is not '
                     rb'sent\nload cancelled\nhades> ' % size, 10, start)
        time.sleep(3.0)
        s.read(0.5)
        assert b'Command not recognised' not in s.text(start), 'the rest of the file reached the command line'
        out = s.command(b'app')
        assert b'\nno app loaded\n' in out, out
        finish(s)
        return f'load cancelled after {int(m.group(1))} of {size} bytes; nothing reached the command line; no app loaded'
    finally:
        s.close()


CASES = [('upload', case_upload), ('paste', case_paste), ('pty-send', case_pty_send),
         ('pty-cat', case_pty_cat), ('input', case_input), ('ctrl-c', case_ctrl_c),
         ('ctrl-c-ahead', case_ctrl_c_ahead), ('ctrl-c-load', case_ctrl_c_load)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--sim', required=True)
    ap.add_argument('--dir', required=True)
    ap.add_argument('--upload-dir', required=True)
    ap.add_argument('--only', default='')
    a = ap.parse_args()
    up = os.path.abspath(a.upload_dir)
    failed = ran = 0
    print('=' * 78)
    for name, fn in CASES:
        if a.only and name not in a.only.split(','):
            continue
        ran += 1
        try:
            what = fn(a.sim, a.dir, up)
            print(f'  PASS  {name:12s} {what}', flush=True)
        except AssertionError as e:
            failed += 1
            print(f'  FAIL  {name:12s} {e}', flush=True)
    print(f'LOADER TTY TEST: {"PASS" if not failed and ran else "FAIL"}  ({ran - failed} of {ran} cases passed)')
    print('=' * 78)
    return 1 if failed or not ran else 0


if __name__ == '__main__':
    sys.exit(main())
