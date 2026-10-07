#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------------------------------
# screenshots.py -- records the terminal screenshots in docs/img/ from real sessions of the
# interactive FreeRTOS shell and renders them as SVG images.
#
#   python3 docs/tools/screenshots.py                     record both sessions, write the SVGs
#   python3 docs/tools/screenshots.py --session loader    record one session only
#   python3 docs/tools/screenshots.py --keep <dir>        also keep the raw recordings in <dir>
#   python3 docs/tools/screenshots.py --render <dir>      only render recordings kept earlier
#
# The script runs each session's command in a pseudo-terminal of its own, as in a terminal
# window of COLUMNS columns, types the session's commands (SESSIONS below) with pauses like a
# person, and records what the terminal shows. Two sessions make three images:
#
#   'make freertos-shell' (docs/SHELL.md):
#     shell-session.svg    from the start-up banner up to the prompt at which 'div' is typed
#                          (the screen at that moment): version, tasks, stats;
#     shell-hardware.svg   the rest of the session, from 'div' to the program's final verdict.
#   'make freertos-shell APP=loader' (docs/APPS.md):
#     shell-loader.svg     from 'version' up to the prompt at which 'halt' is typed: the CPU's
#                          nine extensions, an app loaded and run with an argument, the crash
#                          app loaded and run, its report, and the shell's task list after it.
#
# All images have the same terminal width (COLUMNS columns), theme and font size, and the
# command of their session as the window title.
#
# A recording is changed in exactly these ways before it is rendered:
#   * line endings, carriage returns and backspaces are resolved as a terminal shows them, the
#     control characters that a terminal does not show (the bytes with which the loader and
#     the console bridge pace a file transfer) are left out, and a line longer than COLUMNS
#     columns continues on the next line, as in a terminal of that width;
#   * only the parts named above are kept;
#   * in the console bridge's notes '[console] sending <file> (<n> bytes)', which name the file
#     sent to the shell, the build directory at the start of the file's path is shown as '...',
#     as in the guides;
#   * every other line that contains an absolute path or a name of this machine (the checkout,
#     the build directory, the home directory, the user and host names) is removed;
#   * a line that consists only of the progress dots that the shell's 'load' prints (one for
#     every KiB of the image it stores) is removed;
#   * the shell prompt and the typed commands are coloured, PASS is shown in green, the console
#     bridge's notes in grey and the report of an app stopped by the shell in yellow.
# Nothing else is added, removed or reworded. The numbers of a session (cycles, counters,
# shares of the CPU) differ from run to run, because the moment a key arrives decides the cycle
# at which the program sees it.
#
# Needs the tools of docs/FREERTOS.md (Verilator, the RISC-V GCC toolchain) and the Python
# package rich (python3 -m pip install rich). If the checkout is on a disk that cannot
# execute programs, set HADES_BUILD_DIR first (docs/FREERTOS.md, section 2.2). The first run
# builds the shell, the loader, the example apps and the console simulators (a few minutes);
# the two sessions then take about a minute.
# ---------------------------------------------------------------------------------------------
import argparse
import fcntl
import getpass
import inspect
import io
import os
import pty
import re
import select
import signal
import socket
import struct
import sys
import termios
import time
import xml.etree.ElementTree as ET

try:
    from rich.console import Console
    from rich.terminal_theme import TerminalTheme
    from rich.text import Text
except ImportError:
    sys.exit("screenshots.py needs the Python package rich: python3 -m pip install rich")

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
IMG_DIR = os.path.join(REPO, "docs", "img")
PROMPT = "hades> "
COLUMNS = 100                # the terminal width of every image (86 was too narrow once the
                              # loader's 'version' line grew to 9 extensions: at 86 it hard-wrapped
                              # 'yes' as 'ye'/'s', as a real 86-column terminal would)
PAUSE_BEFORE_COMMAND = 1.0   # seconds, like a person reading the previous output
PAUSE_PER_KEY = 0.04         # seconds between two keys

# The sessions: the command, the shell commands typed into it in this order ('halt' ends the
# session), and its images. An image has the first line to show (a regular expression), and
# either the last line to show or the line before which to stop; 'then_prompt' ends the image
# with the shell's prompt alone, which is what the screen showed before the next command was
# typed. (The full 'help' listing is shown in docs/SHELL.md.)
SESSIONS = [
    dict(name="shell", argv=["make", "freertos-shell"],
         commands=["version", "tasks", "stats",
                   "div -2147483648 -1", "bpred 3", "counters", "bpred", "halt"],
         images=[
             dict(file="shell-session.svg", uid="hades-shell",
                  first=r"^HaDes-V\+ shell on FreeRTOS", before=r"^hades> div\b", then_prompt=True),
             dict(file="shell-hardware.svg", uid="hades-hardware",
                  first=r"^hades> div\b", last=r"^FRTOS-RESULT:"),
         ]),
    dict(name="loader", argv=["make", "freertos-shell", "APP=loader"],
         commands=["version", "load hello", "run Ada", "load crash", "run", "tasks", "halt"],
         images=[
             dict(file="shell-loader.svg", uid="hades-loader",
                  first=r"^hades> version\b", before=r"^hades> halt\b", then_prompt=True),
         ]),
]

# A dark terminal (the colours of GitHub's dark theme).
THEME = TerminalTheme(
    (13, 17, 23), (201, 209, 217),
    [(72, 79, 88), (255, 123, 114), (63, 185, 80), (210, 153, 34),
     (88, 166, 255), (188, 140, 255), (57, 197, 207), (177, 186, 196)],
    [(110, 118, 129), (255, 161, 152), (86, 211, 100), (227, 179, 65),
     (121, 192, 255), (210, 168, 255), (86, 212, 221), (240, 246, 252)],
)
MONO = ("'Fira Code', 'JetBrains Mono', 'Cascadia Mono', 'DejaVu Sans Mono', Menlo, Consolas, "
        "'Liberation Mono', monospace")
SANS = "-apple-system, 'Segoe UI', Helvetica, Arial, sans-serif"


# --------------------------------------------------------------------------- recording
class Session:
    """A command running in a pseudo-terminal of its own, as in a terminal window."""

    def __init__(self, argv, env):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:                                   # the child becomes the command
            try:
                os.chdir(REPO)
                os.execvpe(argv[0], argv, env)
            finally:
                os._exit(127)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 50, COLUMNS, 0, 0))
        self.data = bytearray()
        self.status = None

    def text(self):
        return self.data.decode("utf-8", "replace")

    def _read(self, timeout):
        """Reads what arrives within `timeout` seconds; False once the terminal is closed."""
        ready, _, _ = select.select([self.fd], [], [], timeout)
        if not ready:
            return True
        try:
            chunk = os.read(self.fd, 65536)
        except OSError:                                     # EIO: no process holds it any more
            chunk = b""
        self.data += chunk
        return bool(chunk)

    def wait_for(self, condition, timeout, what):
        deadline = time.monotonic() + timeout
        while not condition(self.text()):
            left = deadline - time.monotonic()
            if left <= 0:
                raise RuntimeError(f"no {what} within {timeout} s")
            if not self._read(min(left, 0.5)) and not condition(self.text()):
                raise RuntimeError(f"the session ended before the {what}")

    def type(self, keys):
        for key in keys:
            os.write(self.fd, key.encode())
            time.sleep(PAUSE_PER_KEY)

    def _reap(self, timeout):
        deadline = time.monotonic() + timeout
        while self.status is None and time.monotonic() < deadline:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.status = status
            else:
                time.sleep(0.1)

    def wait_exit(self, timeout):
        """Waits until the command has ended; returns its exit status."""
        deadline = time.monotonic() + timeout
        while self._read(min(max(deadline - time.monotonic(), 0.01), 0.5)):
            if time.monotonic() > deadline:
                raise RuntimeError(f"the session did not end within {timeout} s")
        self._reap(30)
        if self.status is None:
            raise RuntimeError("the session closed its terminal but did not end")
        if os.WIFEXITED(self.status):
            return os.WEXITSTATUS(self.status)
        return -os.WTERMSIG(self.status)

    def close(self):
        """Ends whatever still runs in the session (make and the simulator it started)."""
        for sig in (signal.SIGTERM, signal.SIGKILL):
            if self.status is not None:
                break
            try:
                os.killpg(self.pid, sig)
            except ProcessLookupError:
                pass
            self._reap(5)
        os.close(self.fd)


def record(spec, env):
    command = " ".join(spec["argv"])
    session, status = Session(spec["argv"], env), None
    try:
        session.wait_for(lambda t: PROMPT in t, 900, "first prompt (the first run builds the shell)")
        for typed in spec["commands"]:
            time.sleep(PAUSE_BEFORE_COMMAND)
            prompts = session.text().count(PROMPT)
            session.type(typed + "\r")
            if typed in ("halt", "exit"):
                status = session.wait_exit(120)
            else:
                session.wait_for(lambda t, n=prompts: t.count(PROMPT) > n, 300,
                                 f"prompt after '{typed}'")
    finally:
        session.close()
    if status != 0:
        raise RuntimeError(f"{command} ended with exit status {status}")
    return bytes(session.data)


# --------------------------------------------------------------------------- the screen
CSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
# Control characters that a terminal does not show, such as the bytes of the loader's file
# transfer (DC2, DC4, ACK): everything below a space except BS, TAB, LF, CR and ESC, and DEL.
INVISIBLE = re.compile(r"[\x00-\x07\x0b\x0c\x0e-\x1a\x1c-\x1f\x7f]")


def overstrike(line):
    """A line with carriage returns or backspaces, as the terminal finally shows it."""
    cells, col = [], 0
    for ch in CSI.sub("", line):
        if ch == "\r":
            col = 0
        elif ch == "\b":
            col = max(col - 1, 0)
        elif ch >= " " or ch == "\t":
            cells.extend(" " * (col - len(cells)))
            if col < len(cells):
                cells[col] = ch
            else:
                cells.append(ch)
            col += 1
    return "".join(cells).rstrip()


def screen_lines(raw):
    """The recording as a list of rich Text lines; colour (SGR) codes become styles."""
    text = raw.decode("utf-8", "replace").expandtabs(8)
    text = INVISIBLE.sub("", text)
    lines = []
    for line in re.split(r"\r*\n", text):
        if "\r" in line or "\b" in line:
            line = overstrike(line)
        # keep colour codes, drop every other control sequence
        line = CSI.sub(lambda m: m.group(0) if m.group(0).endswith("m") else "", line)
        lines.append(line)
    return list(Text.from_ansi("\n".join(lines)).split("\n", allow_blank=True))


ABS_PATH = re.compile(r"(?<![\w.~-])/[\w.+-]+/")      # an absolute path: /dir/...
SENDING = re.compile(r"^\[console\] sending (/\S+) \(\d+ bytes\)$")
PROGRESS = re.compile(r"^\.+\s*$")                  # the progress dots of 'load'


def build_dirs(env):
    """The build directory, as given and as resolved (the Makefile's rule)."""
    given = env.get("BUILD_DIR") or env.get("HADES_BUILD_DIR") or os.path.join(REPO, "build")
    given = os.path.abspath(os.path.join(REPO, given))
    return sorted({given, os.path.realpath(given)}, key=len, reverse=True)


def private_markers(env):
    """Strings that identify this machine; a line that contains one is not shown."""
    marks = {REPO, os.path.realpath(REPO), os.path.expanduser("~")}
    marks |= set(build_dirs(env))
    for name in (getpass.getuser(), socket.gethostname(), socket.getfqdn()):
        if name and len(name) >= 3 and name not in ("localhost", "root"):
            marks.add(name)
    return {m for m in marks if m and m != "/"}


def neutral_sending(line, builds):
    """'[console] sending <build dir>/x/y.hex (n bytes)' -> '[console] sending .../x/y.hex ...'."""
    m = SENDING.match(line.plain)
    if not m:
        return line
    for build in builds:
        if m.group(1).startswith(build + "/"):
            start = m.start(1)
            return Text("...").join([line[:start], line[start + len(build):]])
    return line


def select_lines(lines, spec, marks, builds):
    lines = [neutral_sending(l, builds) for l in lines]
    lines = [l for l in lines
             if not ABS_PATH.search(l.plain) and not any(m in l.plain for m in marks)
             and not PROGRESS.match(l.plain)]
    plain = [l.plain for l in lines]
    start = next((i for i, l in enumerate(plain) if re.search(spec["first"], l)), None)
    if start is None:
        raise RuntimeError(f"{spec['file']}: no line matches {spec['first']!r}")
    stop_re = spec.get("before") or spec["last"]
    stop = next((i for i in range(start + 1, len(plain)) if re.search(stop_re, plain[i])), None)
    if stop is None:
        raise RuntimeError(f"{spec['file']}: no line after the first matches {stop_re!r}")
    chosen = lines[start:stop] if spec.get("before") else lines[start:stop + 1]
    while chosen and not chosen[-1].plain.strip():
        chosen.pop()
    if spec.get("then_prompt"):
        chosen.append(Text(PROMPT))
    return chosen


def colour(line):
    plain = line.plain
    if plain.startswith(PROMPT):
        line.stylize("bold green", 0, len(PROMPT) - 1)
        line.stylize("bold bright_white", len(PROMPT), len(plain))
    elif plain.startswith("[console] "):
        line.stylize("bright_black")
    elif re.match(r"app: \S+ stopped by ", plain):
        line.stylize("bold yellow")
    line.highlight_regex(r"\bPASS\b", "bold green")
    return line


def terminal_rows(line):
    """A line as a terminal of COLUMNS columns shows it: longer lines continue on the next row."""
    if len(line.plain) <= COLUMNS:
        return [line]
    return list(line.divide(range(COLUMNS, len(line.plain), COLUMNS)))


def svg_format():
    """rich's SVG template, without the web fonts it would fetch: local fonts only."""
    fmt = inspect.signature(Console.export_svg).parameters["code_format"].default
    fmt = re.sub(r"\s*@font-face \{\{.*?\}\}", "", fmt, flags=re.S)
    fmt = fmt.replace("font-family: Fira Code, monospace;", f"font-family: {MONO};")
    fmt = fmt.replace("font-family: arial;", f"font-family: {SANS};")
    return fmt


def render(lines, spec, title, out_dir):
    console = Console(record=True, width=COLUMNS, file=io.StringIO(), force_terminal=True,
                      color_system="truecolor", highlight=False, markup=False, emoji=False,
                      soft_wrap=False, legacy_windows=False)
    rows = [row for line in lines for row in terminal_rows(colour(line))]
    for row in rows:
        console.print(row, no_wrap=True, overflow="ignore", crop=False)
    svg = console.export_svg(title=title, theme=THEME, code_format=svg_format(),
                             unique_id=spec["uid"])
    ET.fromstring(svg)                                      # well-formed XML, or an exception
    path = os.path.join(out_dir, spec["file"])
    with open(path, "w", encoding="utf-8") as f:
        f.write(svg)
    print(f"{os.path.relpath(path, REPO)}: {len(rows)} rows, {COLUMNS} columns, "
          f"{len(svg.encode()) / 1024:.1f} KiB")


# --------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description="Record the terminal screenshots in docs/img/.")
    ap.add_argument("--session", choices=[s["name"] for s in SESSIONS], action="append",
                    help="record (or render) only this session; may be given twice")
    ap.add_argument("--keep", metavar="DIR", help="also keep the raw recordings in DIR")
    ap.add_argument("--render", metavar="DIR", help="render the recordings kept earlier in DIR")
    ap.add_argument("--out", metavar="DIR", default=IMG_DIR, help="where the SVGs go (docs/img)")
    args = ap.parse_args()

    env = dict(os.environ)
    marks, builds = private_markers(env), build_dirs(env)
    os.makedirs(args.out, exist_ok=True)
    for spec in SESSIONS:
        if args.session and spec["name"] not in args.session:
            continue
        title = " ".join(spec["argv"])
        if args.render:
            with open(os.path.join(args.render, spec["name"] + ".rec"), "rb") as f:
                raw = f.read()
        else:
            print(f"recording '{title}' ...", flush=True)
            raw = record(spec, env)
            if args.keep:
                os.makedirs(args.keep, exist_ok=True)
                with open(os.path.join(args.keep, spec["name"] + ".rec"), "wb") as f:
                    f.write(raw)
        lines = screen_lines(raw)
        for image in spec["images"]:
            render(select_lines(lines, image, marks, builds), image, title, args.out)


if __name__ == "__main__":
    main()
