// SPDX-License-Identifier: MIT
// ---------------------------------------------------------------------------------------------
// console.cpp -- host side of the simulation's console bridge (DPI-C, used by sim/top.sv when
// it is verilated with +define+HADES_CONSOLE; see docs/FREERTOS.md, "The interactive shell").
//
// The bridge types characters into the simulated UART and watches what the program writes to
// it. Where the characters come from depends on the run options of the simulator:
//
//   (default)                 this terminal. When stdin is a terminal it is put into raw
//                             mode: every key goes to the program as it is typed (Ctrl-C
//                             included), and Ctrl-] ends the simulation, whatever the
//                             program is doing (also when it has stopped reading the UART).
//                             The terminal settings are restored however the simulator
//                             ends: $finish (including the program's halt and the cycle
//                             limit), $fatal, Ctrl-], and every signal whose default action
//                             ends the process (SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGPIPE,
//                             SIGALRM, SIGUSR1, a crash: SIGSEGV, SIGABRT, ...). SIGTSTP (a
//                             stop from job control) restores them, and raw mode returns on
//                             SIGCONT. Only SIGKILL cannot be caught.
//                             When stdin is not a terminal (a pipe or a file), its bytes
//                             are typed as they come. After its end, the simulation ends
//                             once the program waits at its prompt and has been silent for
//                             a million cycles, i.e. has worked through everything.
//   +console_pty              a pseudo-terminal, printed at start-up: attach a terminal
//                             program to it (screen <device>, picocom <device>) as to a
//                             board's serial port. Ctrl-] typed there, the program's halt,
//                             or Ctrl-C in the simulator's own terminal end the run.
//   +console_pty_link=<path>  also create a symbolic link <path> to the pseudo-terminal
//                             (removed at the end).
//   +console_script=<file>    type the lines of <file>. Lines starting with '#' are not
//                             typed (comments, and the expectations read by
//                             test/freertos/shell/session.py); every other line is typed
//                             followed by CR (the Enter key), each one after the prompt
//                             that the previous one produced. Escapes: \r, \n, \t, \e (ESC),
//                             \xHH, a doubled backslash for one backslash, and \c at the end
//                             of a line, which suppresses the CR. Every typed line must
//                             produce exactly one new prompt (a line ending in Ctrl-C,
//                             \x03, therefore ends in \c). After the last line and its
//                             prompt, the simulation ends.
//   +console_prompt=<text>    the program's prompt (default "hades> ").
//   +console_log=<file>       write a copy of everything the program sends to <file>. The
//                             copy is written unbuffered, so it is complete however the
//                             simulator ends (a signal included).
//
// Input and pacing. sim/top.sv calls console_poll() every few dozen cycles, in every state of
// its UART injector: all input available from the terminal (or pseudo-terminal) is read into a
// queue here at once, and Ctrl-] is recognised as soon as it is read. Only the injection into
// the core is paced: sim/top.sv asks console_next_byte() for the next character only when the
// program has read the previous one from the UART and its output has paused. In addition, once
// the program has shown its prompt, the bridge treats Enter (CR, or LF not after CR) like a
// person does: the characters after it wait until the program has answered with its next
// prompt (at most kPromptWait cycles). A pasted block of commands therefore runs one command
// after the other, and never piles up in the program's small receive queue while a command is
// still being computed.
//
// The program's output reaches this terminal through the UART echo of wishbone_uart.sv
// ($write to stdout); stdout is made unbuffered so that a prompt without a newline shows at
// once. In raw mode, output processing stays on, so "\n" still moves to a new line.
// ---------------------------------------------------------------------------------------------
#include <cctype>
#include <cerrno>
#include <csignal>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <vector>

#include <fcntl.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

#include "svdpi.h"

namespace {

enum class Mode { None, Stdio, Pty, Script };

const unsigned char kQuitKey = 0x1d;       // Ctrl-]
const uint64_t kPollCycles = 512;           // read the input at most this often
const uint64_t kPromptWait = 10000000;      // after Enter, wait at most this long for the prompt
const uint64_t kSettledCycles = 1000000;    // end of piped input: silence at the prompt this long

Mode g_mode = Mode::None;
bool g_open = false;

// input
int g_in_fd = -1;                    // stdin, or the pseudo-terminal's master side
bool g_in_tty = false;               // stdin is a terminal (raw mode, Ctrl-] quits)
bool g_in_eof = false;               // the input has ended
bool g_quit = false;                 // Ctrl-] seen
std::deque<unsigned char> g_pending; // characters read, waiting to be typed into the UART
bool g_polled = false;
uint64_t g_last_poll = 0;
unsigned char g_last_typed = 0;
bool g_wait_prompt = false;          // Enter typed: hold the rest until the next prompt
uint64_t g_wait_since = 0;
unsigned long g_wait_mark = 0;

// terminal state (stdin in raw mode)
struct termios g_saved_tio;
volatile sig_atomic_t g_raw = 0;     // raw mode is active; restore g_saved_tio

// pseudo-terminal
int g_pty_master = -1;
int g_pty_slave = -1;                // kept open: keeps the slave raw between clients
char g_pty_link[1024] = "";
volatile sig_atomic_t g_pty_link_made = 0;
unsigned long g_pty_dropped = 0;

// the program's output
std::string g_prompt;
std::string g_tail;                  // the last characters sent, as long as the prompt
unsigned long g_prompts = 0;         // prompts seen so far
uint64_t g_last_tx_cycle = 0;
char g_last_tx = '\n';

// script
std::vector<std::string> g_lines;
size_t g_next_line = 0;
unsigned long g_prompts_used = 0;    // prompts already answered with a line

// copy of the UART output (+console_log): a plain file descriptor, written without
// buffering, so that nothing is lost when a signal ends the process
int g_log_fd = -1;

// Messages of the bridge go to stderr, on a line of their own.
void note(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
void note(const char* fmt, ...) {
    char buf[1400];
    va_list ap;
    va_start(ap, fmt);
    std::vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    std::fprintf(stderr, "%s[console] %s\n", g_last_tx == '\n' ? "" : "\n", buf);
    g_last_tx = '\n';
}

// ---- terminal restore (async-signal-safe: called from signal handlers and atexit) ----
void restore_terminal() {
    if (g_raw) {
        // SIGTTOU blocked: a process that was moved to the background may restore too.
        sigset_t block, old;
        sigemptyset(&block);
        sigaddset(&block, SIGTTOU);
        sigprocmask(SIG_BLOCK, &block, &old);
        tcsetattr(STDIN_FILENO, TCSANOW, &g_saved_tio);
        sigprocmask(SIG_SETMASK, &old, nullptr);
        g_raw = 0;
    }
    if (g_pty_link_made) {
        unlink(g_pty_link);
        g_pty_link_made = 0;
    }
}

void enter_raw_mode() {
    struct termios raw = g_saved_tio;
    raw.c_iflag &= ~(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL | IXON | IXOFF);
    raw.c_lflag &= ~(ECHO | ECHONL | ICANON | ISIG | IEXTEN);
    raw.c_cflag |= CS8;
    raw.c_cc[VMIN] = 1;
    raw.c_cc[VTIME] = 0;
    // c_oflag is left alone: OPOST/ONLCR keep "\n" from the simulator a proper new line.
    if (tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0) g_raw = 1;
}

// Signals that end the process: restore, then die of the same signal (the handler is
// installed with SA_RESETHAND | SA_NODEFER, so raise() takes the default action). The copy
// of the UART output needs nothing: it is written unbuffered.
void on_fatal_signal(int sig) {
    restore_terminal();
    raise(sig);
}

void install_stop_handler();

// SIGTSTP: leave raw mode and stop; on SIGCONT continue here and go raw again.
void on_stop_signal(int) {
    const bool was_raw = g_raw;
    if (was_raw) tcsetattr(STDIN_FILENO, TCSANOW, &g_saved_tio);
    g_raw = 0;
    std::signal(SIGTSTP, SIG_DFL);
    sigset_t set;
    sigemptyset(&set);
    sigaddset(&set, SIGTSTP);
    sigprocmask(SIG_UNBLOCK, &set, nullptr);
    raise(SIGTSTP);
    install_stop_handler();   // continued
    if (was_raw) enter_raw_mode();
}

void install_stop_handler() {
    struct sigaction sa;
    std::memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_stop_signal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTSTP, &sa, nullptr);
}

// Every signal whose default action ends the process gets the restoring handler, unless it
// is ignored (as `nohup` does with SIGHUP): an ignored signal stays ignored. The handler runs
// on a stack of its own, so that it also works after a stack overflow.
void install_signal_handlers() {
    static char alt_stack[64 * 1024];
    stack_t ss;
    std::memset(&ss, 0, sizeof ss);
    ss.ss_sp = alt_stack;
    ss.ss_size = sizeof alt_stack;
    sigaltstack(&ss, nullptr);

    std::vector<int> fatal = {SIGHUP,  SIGINT,  SIGQUIT, SIGILL,    SIGTRAP, SIGABRT, SIGBUS,
                              SIGFPE,  SIGUSR1, SIGSEGV, SIGUSR2,   SIGPIPE, SIGALRM, SIGTERM,
                              SIGXCPU, SIGXFSZ, SIGVTALRM, SIGPROF, SIGIO,   SIGSYS};
#ifdef SIGSTKFLT
    fatal.push_back(SIGSTKFLT);
#endif
#ifdef SIGPWR
    fatal.push_back(SIGPWR);
#endif
#ifdef SIGRTMIN
    for (int sig = SIGRTMIN; sig <= SIGRTMAX; sig++) fatal.push_back(sig);
#endif
    for (int sig : fatal) {
        struct sigaction old;
        if (sigaction(sig, nullptr, &old) != 0 || old.sa_handler == SIG_IGN) continue;
        struct sigaction sa;
        std::memset(&sa, 0, sizeof sa);
        sa.sa_handler = on_fatal_signal;
        sa.sa_flags = SA_RESETHAND | SA_NODEFER | SA_ONSTACK;
        sigemptyset(&sa.sa_mask);
        sigaction(sig, &sa, nullptr);
    }
    install_stop_handler();
    std::atexit(restore_terminal);   // $finish, and $fatal (Verilator ends it with exit(1))
}

// ---- script ----
bool load_script(const char* path) {
    FILE* f = std::fopen(path, "r");
    if (!f) {
        note("cannot open the script %s: %s", path, std::strerror(errno));
        return false;
    }
    char* buf = nullptr;
    size_t cap = 0;
    unsigned lineno = 0;
    bool ok = true;
    while (ok && getline(&buf, &cap, f) >= 0) {   // lines of any length
        lineno++;
        std::string line(buf);
        while (!line.empty() && (line.back() == '\n' || line.back() == '\r')) line.pop_back();
        if (!line.empty() && line[0] == '#') continue;
        std::string out;
        bool enter = true;
        for (size_t i = 0; ok && i < line.size(); i++) {
            const char c = line[i];
            if (c != '\\' || i + 1 >= line.size()) {
                out += c;
                continue;
            }
            const char e = line[++i];
            switch (e) {
            case 'r': out += '\r'; break;
            case 'n': out += '\n'; break;
            case 't': out += '\t'; break;
            case 'e': out += '\x1b'; break;
            case '\\': out += '\\'; break;
            case 'c':
                if (i + 1 == line.size()) {
                    enter = false;
                } else {
                    note("%s:%u: \\c is only allowed at the end of a line", path, lineno);
                    ok = false;
                }
                break;
            case 'x': {
                unsigned v = 0;
                int n = 0;
                while (n < 2 && i + 1 < line.size() && std::isxdigit((unsigned char)line[i + 1])) {
                    const char h = line[++i];
                    v = v * 16 + (unsigned)(std::isdigit((unsigned char)h) ? h - '0' : std::tolower(h) - 'a' + 10);
                    n++;
                }
                if (n == 0) {
                    note("%s:%u: \\x needs one or two hexadecimal digits", path, lineno);
                    ok = false;
                }
                out += (char)v;
                break;
            }
            default:
                note("%s:%u: unknown escape \\%c", path, lineno, e);
                ok = false;
            }
        }
        if (enter) out += '\r';
        g_lines.push_back(out);
    }
    std::free(buf);
    std::fclose(f);
    return ok;
}

// ---- pseudo-terminal ----
bool open_pty(const char* link) {
    g_pty_master = posix_openpt(O_RDWR | O_NOCTTY);
    if (g_pty_master < 0 || grantpt(g_pty_master) != 0 || unlockpt(g_pty_master) != 0) {
        note("cannot create a pseudo-terminal: %s", std::strerror(errno));
        return false;
    }
    const char* name = ptsname(g_pty_master);
    if (!name) {
        note("ptsname failed: %s", std::strerror(errno));
        return false;
    }
    // Keep the slave side open and raw: no echo and no line editing by the kernel before a
    // terminal program attaches (an echo would type the program's output back into it),
    // and no hang-up on the master when the terminal program exits.
    g_pty_slave = open(name, O_RDWR | O_NOCTTY);
    if (g_pty_slave >= 0) {
        struct termios tio;
        if (tcgetattr(g_pty_slave, &tio) == 0) {
            cfmakeraw(&tio);
            tcsetattr(g_pty_slave, TCSANOW, &tio);
        }
    }
    fcntl(g_pty_master, F_SETFL, fcntl(g_pty_master, F_GETFL) | O_NONBLOCK);
    g_in_fd = g_pty_master;
    note("the UART is connected to the pseudo-terminal %s", name);
    if (link && link[0]) {
        std::snprintf(g_pty_link, sizeof g_pty_link, "%s", link);
        unlink(g_pty_link);
        if (symlink(name, g_pty_link) == 0) {
            g_pty_link_made = 1;
            note("symbolic link: %s", g_pty_link);
        } else {
            note("cannot create the link %s: %s", g_pty_link, std::strerror(errno));
        }
    }
    const char* shown = g_pty_link_made ? g_pty_link : name;
    note("attach a terminal program, e.g.  screen %s   or   picocom %s  (then press Enter)", shown, shown);
    note("Ctrl-] typed there, or 'halt', ends the simulation; so does Ctrl-C here");
    return true;
}

// Reads everything available from the input without blocking into g_pending. Ctrl-] (from a
// terminal or the pseudo-terminal) ends the run at once, even when earlier input is still
// waiting to be typed.
void poll_input() {
    while (g_in_fd >= 0 && !g_in_eof && !g_quit) {
        struct pollfd p = {g_in_fd, POLLIN, 0};
        if (poll(&p, 1, 0) <= 0) return;
        if (g_mode == Mode::Pty && (p.revents & POLLIN) == 0) return;   // POLLHUP: no client yet
        unsigned char buf[256];
        const ssize_t n = read(g_in_fd, buf, sizeof buf);
        if (n > 0) {
            for (ssize_t i = 0; i < n; i++) {
                if (buf[i] == kQuitKey && (g_in_tty || g_mode == Mode::Pty)) {
                    g_quit = true;
                    break;
                }
                g_pending.push_back(buf[i]);
            }
            if (n < (ssize_t)sizeof buf) return;
        } else if (n < 0 && (errno == EAGAIN || errno == EINTR || errno == EIO)) {
            return;
        } else {
            if (g_mode != Mode::Pty) g_in_eof = true;
            return;
        }
    }
}

int next_script_byte() {
    if (!g_pending.empty()) {
        const int c = g_pending.front();
        g_pending.pop_front();
        return c;
    }
    if (g_prompts <= g_prompts_used) return -1;   // the previous line has not been answered yet
    g_prompts_used = g_prompts;
    if (g_next_line >= g_lines.size()) {
        note("end of the script (%zu line(s) typed)", g_lines.size());
        return -2;
    }
    const std::string& l = g_lines[g_next_line++];
    g_pending.assign(l.begin(), l.end());
    if (g_pending.empty()) return -1;
    const int c = g_pending.front();
    g_pending.pop_front();
    return c;
}

}  // namespace

// ------------------------------------------------------------------------ DPI functions --

extern "C" void console_init(const char* mode, const char* script_file, const char* pty_link,
                             const char* log_file, const char* prompt) {
    if (g_open) return;
    g_open = true;
    g_prompt = prompt ? prompt : "";

    // Unbuffered stdout: the UART echo ($write) shows every character at once.
    std::fflush(stdout);
    std::setvbuf(stdout, nullptr, _IONBF, 0);

    install_signal_handlers();

    if (log_file && log_file[0]) {
        g_log_fd = open(log_file, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
        if (g_log_fd < 0) note("cannot write %s: %s", log_file, std::strerror(errno));
    }

    const std::string m = mode ? mode : "stdio";
    if (m == "script") {
        g_mode = Mode::Script;
        if (!load_script(script_file)) std::exit(2);
        note("typing %zu line(s) from %s, each after the prompt \"%s\"", g_lines.size(), script_file,
             g_prompt.c_str());
    } else if (m == "pty") {
        g_mode = Mode::Pty;
        if (!open_pty(pty_link)) std::exit(2);
    } else {
        g_mode = Mode::Stdio;
        g_in_fd = STDIN_FILENO;
        if (isatty(STDIN_FILENO) && tcgetattr(STDIN_FILENO, &g_saved_tio) == 0) {
            g_in_tty = true;
            enter_raw_mode();
            note("the UART is connected to this terminal; press Ctrl-] to end the simulation");
        } else {
            note("typing the input from stdin; after its end, the simulation ends when the program "
                 "waits at its prompt");
        }
    }
}

// Called by sim/top.sv every few dozen cycles, whatever its UART injector is doing; `cycle` is
// the current clock cycle. Reads the input that has arrived (at most every kPollCycles) into
// the queue of characters to type. Returns -2 to end the simulation (Ctrl-]), else 0.
extern "C" int console_poll(long long cycle) {
    if (!g_open || g_mode == Mode::Script) return 0;
    const uint64_t now = (uint64_t)cycle;
    if (!g_polled || now - g_last_poll >= kPollCycles) {
        g_polled = true;
        g_last_poll = now;
        poll_input();
    }
    if (g_quit) {
        note("Ctrl-] pressed: the simulation ends");
        return -2;
    }
    return 0;
}

// Called by sim/top.sv whenever the program has read the previous character and its output
// has paused. Returns the next character to type (0..255), -1 when there is none now, or -2
// to end the simulation (the end of a script, or of piped input).
extern "C" int console_next_byte(long long cycle) {
    if (!g_open) return -1;
    const uint64_t now = (uint64_t)cycle;

    if (g_mode == Mode::Script) return next_script_byte();

    if (g_wait_prompt) {   // Enter typed: the program answers with a prompt first
        if (g_prompts > g_wait_mark || now - g_wait_since > kPromptWait) {
            g_wait_prompt = false;
        } else {
            return -1;
        }
    }

    if (!g_pending.empty()) {
        const unsigned char c = g_pending.front();
        g_pending.pop_front();
        const bool enter = c == '\r' || (c == '\n' && g_last_typed != '\r');
        if (enter && g_prompts > 0) {   // only for a program that shows this prompt
            g_wait_prompt = true;
            g_wait_since = now;
            g_wait_mark = g_prompts;
        }
        g_last_typed = c;
        return c;
    }

    // Piped input has ended: stop once the program waits at its prompt and stays silent.
    if (g_in_eof && now - g_last_tx_cycle >= kSettledCycles && g_tail == g_prompt) {
        note("end of the input, and the program waits at its prompt: the simulation ends");
        return -2;
    }
    return -1;
}

// Every byte the program writes to the UART's transmit buffer, at clock cycle `cycle`.
extern "C" void console_tx(int c, long long cycle) {
    if (!g_open) return;
    const char ch = (char)c;
    g_last_tx = ch;
    g_last_tx_cycle = (uint64_t)cycle;
    if (g_log_fd >= 0) {
        while (write(g_log_fd, &ch, 1) < 0 && errno == EINTR) {
        }
    }
    if (g_mode == Mode::Pty && g_pty_master >= 0) {
        if (write(g_pty_master, &ch, 1) != 1) g_pty_dropped++;
    }
    if (!g_prompt.empty()) {
        g_tail.push_back(ch);
        if (g_tail.size() > g_prompt.size()) g_tail.erase(0, g_tail.size() - g_prompt.size());
        if (g_tail == g_prompt) g_prompts++;
    }
}

extern "C" void console_close() {
    if (!g_open) return;
    if (g_log_fd >= 0) {
        close(g_log_fd);
        g_log_fd = -1;
    }
    if (g_pty_dropped) note("%lu character(s) could not be written to the pseudo-terminal", g_pty_dropped);
    // Closing the master side hangs the pseudo-terminal up, and the kernel then discards
    // what the terminal program has not read yet (the program's last words, e.g. after
    // 'halt'): give it up to two seconds to read them.
    for (int i = 0; i < 200 && g_pty_slave >= 0; i++) {
        int pending = 0;
        if (ioctl(g_pty_slave, FIONREAD, &pending) != 0 || pending == 0) break;
        usleep(10000);
    }
    restore_terminal();
    if (g_pty_master >= 0) close(g_pty_master);
    if (g_pty_slave >= 0) close(g_pty_slave);
    g_pty_master = g_pty_slave = -1;
    g_open = false;
}
