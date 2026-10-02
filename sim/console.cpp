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
//                             Two kinds of '#' lines are entries of the typed line before
//                             them: "#< <file>" sends the file when the program next asks
//                             for one (DC2, below), and "#: <text>" types the text (with the
//                             same escapes) and Enter, none after \c, when the program next
//                             waits for input or for a file (DC1 or DC2). They are delivered
//                             in order, each after the previous one has been typed
//                             completely; one not delivered when the prompt that answers the
//                             typed line appears is dropped, with a note. A "#<" file that
//                             cannot be read is an error at start-up.
//   +console_prompt=<text>    the program's prompt (default "hades> ").
//   +console_log=<file>       write a copy of everything the program sends to <file>. The
//                             copy is written unbuffered, so it is complete however the
//                             simulator ends (a signal included).
//   +console_upload=<file>    the file to send whenever the program asks for one (terminal
//                             and pseudo-terminal modes). It is read at every request, so a
//                             file rebuilt meanwhile is sent the next time.
//   +console_upload_dir=<dir> relative paths of +console_upload and of "#<" entries are
//                             relative to <dir> (default: the simulator's working directory).
//                             In the pseudo-terminal mode with a link, this option or
//                             +console_upload also enables send requests (below).
//   +console_app_dir=<dir>    the apps' HEX files, for requests that name a file (below):
//                             the name <name> is the file <dir>/<name>.hex. In the terminal
//                             and pseudo-terminal modes their names are listed at start-up.
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
// File transfers (the app loader, test/freertos/loader/SPEC.md, section 5). A program may send
// four control bytes, which are not text: DC1 (0x11) it waits for input, DC2 (0x12) it waits
// for a file, ACK (0x06) and NAK (0x15) it has accepted or rejected a line of that file. Each
// of them also ends the wait after an Enter, as the prompt does. From a DC2 to the program's
// next prompt the bridge serves a file request: it sends a file (an upload: +console_upload,
// the file of a send request, or the script's "#<" file), or else types the input waiting (a
// paste, or 'cat' into the pseudo-terminal), one line at a time: after the end of a line that
// is not empty it types nothing more until the program has answered that line with ACK or NAK
// (at most kPromptWait cycles), so the program's receive queue never holds more than one line
// of the file. The file ends, for the bridge, with the line ':00000001FF' (either case), after
// which the program reads no more of it: nothing after that line is typed into the request
// (the rest of an upload is dropped, with a note unless it is only blanks and line ends). A
// Ctrl-C ends the request in the same way: one typed during an upload is typed at once, ahead
// of the file, and nothing more of the file is sent; one inside the file ends the upload after
// it. The bridge then types nothing until the prompt. While an upload runs, characters typed
// wait for the prompt that ends the request (except Ctrl-C). After a request served by a paste,
// what is left of the file in the input waiting (lines starting with ':', empty lines, and the
// rest of a line cut by a Ctrl-C) is dropped, with a note, instead of being typed into the
// command line.
//
// Named requests ('load <name>'). Before its DC2 the program may name the file it wants: the
// name between two DC4 (0x14), which are not text either (the name itself is). The bridge then
// sends that file as an upload, in every mode and ahead of any other: a name ending in .hex is
// a file, <march>/<name> the file <march>/<name>.hex (both relative to +console_upload_dir),
// any other name <name>.hex in +console_app_dir, as UPLOAD= names them in
// test/freertos/sdk/sdk.mk. If there is no such file, it types the line "!<reason>" instead
// (for an unknown app the reason lists the apps), and the program ends the request with it.
//
// Send requests (make freertos-send). In the pseudo-terminal mode with a link and with
// +console_upload or +console_upload_dir, the bridge looks for the file <link>.upload every 16
// polls; it holds the path of a file. If the program shows its prompt and nothing has been
// typed since, the bridge types 'load' and Enter and sends that file at the program's DC2,
// as it sends +console_upload; while a 'load' typed by hand waits for a file, it sends the
// file at once; otherwise it refuses. It writes its answer, "ok", "ok waiting" or "refused:
// <reason>", to <link>.upload-answer. In this mode the bridge also keeps the device open to a
// second writer (it clears the exclusive mode that screen sets), so that a file can be written
// into it ('cat') while a terminal program is attached.
//
// Ctrl-C. In the terminal and pseudo-terminal modes a Ctrl-C among the characters waiting to
// be typed also ends the wait after an Enter (they are typed in order, the Ctrl-C last), so
// that Ctrl-C reaches a running program at once. This changes, for every program, only the
// pacing of typed-ahead input that contains a Ctrl-C; programs that never send these control
// bytes (or DC4) see the bridge as before otherwise.
//
// The program's output reaches this terminal through the UART echo of wishbone_uart.sv
// ($write to stdout); stdout is made unbuffered so that a prompt without a newline shows at
// once. In raw mode, output processing stays on, so "\n" still moves to a new line.
// ---------------------------------------------------------------------------------------------
#include <algorithm>
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

#include <dirent.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

#include "svdpi.h"
#include "verilated.h"

namespace {

enum class Mode { None, Stdio, Pty, Script };

const unsigned char kQuitKey = 0x1d;       // Ctrl-]
const unsigned char kCtrlC = 0x03;
const unsigned char kAck = 0x06;           // control bytes from the program (see above)
const unsigned char kDc1 = 0x11;
const unsigned char kDc2 = 0x12;
const unsigned char kDc4 = 0x14;           // before and after the name of the file wanted
const unsigned char kNak = 0x15;
const uint64_t kPollCycles = 512;           // read the input at most this often
const uint64_t kPromptWait = 10000000;      // after Enter, wait at most this long for the prompt
const uint64_t kSettledCycles = 1000000;    // end of piped input: silence at the prompt this long
const unsigned kExclusivePolls = 16;        // shared pseudo-terminal: clear exclusive mode this often
const size_t kNameMax = 255;                // characters of a requested name kept

Mode g_mode = Mode::None;
bool g_open = false;

// input
int g_in_fd = -1;                    // stdin, or the pseudo-terminal's master side
bool g_in_tty = false;               // stdin is a terminal (raw mode, Ctrl-] quits)
bool g_in_eof = false;               // the input has ended
bool g_quit = false;                 // Ctrl-] seen
std::deque<unsigned char> g_pending; // characters read, waiting to be typed into the UART
unsigned long g_pending_ctrl_c = 0;  // ... how many of them are Ctrl-C
bool g_polled = false;
uint64_t g_last_poll = 0;
unsigned char g_last_typed = 0;
bool g_wait_prompt = false;          // Enter typed: hold the rest until the next prompt
uint64_t g_wait_since = 0;
unsigned long g_wait_mark = 0;
unsigned long g_wait_controls = 0;   // control bytes seen when the wait began

// terminal state (stdin in raw mode)
struct termios g_saved_tio;
volatile sig_atomic_t g_raw = 0;     // raw mode is active; restore g_saved_tio

// pseudo-terminal
int g_pty_master = -1;
int g_pty_slave = -1;                // kept open: keeps the slave raw between clients
char g_pty_link[1024] = "";
volatile sig_atomic_t g_pty_link_made = 0;
unsigned long g_pty_dropped = 0;
bool g_pty_shared = false;           // keep the device free of exclusive mode (file transfers)
unsigned g_pty_polls = 0;

// the program's output
std::string g_prompt;
std::string g_tail;                  // the last characters sent, as long as the prompt
unsigned long g_prompts = 0;         // prompts seen so far
unsigned long g_controls = 0;        // control bytes seen so far
uint64_t g_last_tx_cycle = 0;
char g_last_tx = '\n';

// file requests: from the program's DC2 to its next prompt
std::string g_upload_dir;            // +console_upload_dir
std::string g_upload;                // +console_upload, resolved
std::string g_app_dir;               // +console_app_dir: the apps' HEX files, for named requests
bool g_name_open = false;            // DC4 seen: the name of the file wanted follows ...
std::string g_name;                  // ... its characters so far
std::string g_request_name;          // the name, complete (the second DC4): for the next DC2
bool g_request = false;              // a file request is being served
unsigned long g_lines_sent = 0;      // lines of the file typed that are not empty ...
unsigned long g_answers = 0;         // ... and the answers (ACK, NAK) received to them
size_t g_line_length = 0;            // characters typed of the current line
uint64_t g_line_end_cycle = 0;       // when the last line end was typed
bool g_cancelled = false;            // Ctrl-C typed during the request: wait for the prompt
uint64_t g_cancel_cycle = 0;
bool g_hold_input = false;           // served by an upload: the input waits for the prompt
bool g_sending = false;              // a file is being sent ...
std::string g_send_data;             // ... its contents, as read at the request
size_t g_send_pos = 0;
std::string g_line_text;             // the current line typed into the request, its first 12 characters
bool g_eof_typed = false;            // the end-of-file record has been typed: the file ends there
bool g_from_input = false;           // the request has typed input waiting (a paste)
bool g_drop_file = false;            // after a request served by a paste: drop the rest of the file
bool g_drop_in_line = false;         // ... dropping up to the end of the current line
uint64_t g_drop_since = 0;
unsigned long g_dropped_lines = 0;

// send requests (make freertos-send; pseudo-terminal mode)
std::string g_send_request;          // <link>.upload: the path of a file to send
std::string g_send_answer;           // <link>.upload-answer: "ok" or "refused: <reason>"
char g_send_request_c[1100] = "";    // (the same, for the clean-up at the end)
char g_send_answer_c[1100] = "";
std::string g_send_once;             // the file of an accepted request, sent at the next DC2
unsigned long g_send_prompts = 0;    // the prompts seen when it was accepted
bool g_typed_since_prompt = false;   // a character has been typed since the last prompt ...
bool g_enter_since_prompt = false;   // ... an Enter

// script
struct Entry {
    bool file;                       // "#< <file>" (true) or "#: <text>"
    std::string arg;                 // the file, resolved, or the characters to type
    unsigned lineno;                 // the line of the script
};
std::string g_script;
std::vector<std::string> g_lines;
std::vector<unsigned> g_line_numbers;        // the line of the script of each typed line
std::vector<std::vector<Entry>> g_entries;   // the entries of each typed line
size_t g_next_line = 0;
size_t g_next_entry = 0;             // the next entry of the line typed last
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
        if (g_send_request_c[0]) unlink(g_send_request_c);
        if (g_send_answer_c[0]) unlink(g_send_answer_c);
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

// ---- files ----
// The value of the run option +<name>=<value>, or "". (Read here rather than in sim/top.sv,
// so that the signature of console_init() stays as it is.)
std::string plusarg(const char* name) {
    const std::string prefix = std::string(name) + "=";
    const char* match = Verilated::commandArgsPlusMatch(prefix.c_str());
    if (!match || std::strlen(match) < prefix.size() + 1) return "";
    return std::string(match + 1 + prefix.size());
}

// A path of +console_upload or of a "#<" entry, relative to +console_upload_dir.
std::string resolve(const std::string& path) {
    if (path.empty() || path[0] == '/' || g_upload_dir.empty()) return path;
    return g_upload_dir + (g_upload_dir.back() == '/' ? "" : "/") + path;
}

bool read_file(const std::string& path, std::string& data, std::string& error) {
    const int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        error = std::strerror(errno);
        return false;
    }
    data.clear();
    char buf[65536];
    for (;;) {
        const ssize_t n = read(fd, buf, sizeof buf);
        if (n > 0) {
            data.append(buf, (size_t)n);
        } else if (n < 0 && errno == EINTR) {
            continue;
        } else if (n < 0) {
            error = std::strerror(errno);
            close(fd);
            return false;
        } else {
            break;
        }
    }
    close(fd);
    return true;
}

// ---- input waiting to be typed ----
void pending_push(unsigned char c) {
    g_pending.push_back(c);
    if (c == kCtrlC) g_pending_ctrl_c++;
}

unsigned char pending_pop() {
    const unsigned char c = g_pending.front();
    g_pending.pop_front();
    if (c == kCtrlC) g_pending_ctrl_c--;
    return c;
}

// Takes the first Ctrl-C out of the waiting input (the characters around it stay).
void pending_take_ctrl_c() {
    const auto it = std::find(g_pending.begin(), g_pending.end(), kCtrlC);
    if (it != g_pending.end()) {
        g_pending.erase(it);
        g_pending_ctrl_c--;
    }
}

// ---- script ----
// Turns the escapes of a script line into characters; `enter` becomes false after a final \c.
bool unescape(const std::string& line, std::string& out, bool& enter, const char* path, unsigned lineno) {
    bool ok = true;
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
    return ok;
}

// "#< <file>" or "#: <text>": an entry of the typed line before it.
bool add_entry(const char* path, unsigned lineno, const std::string& line) {
    const char kind = line[1];
    if (g_lines.empty()) {
        note("%s:%u: \"#%c\" belongs to a typed line, but none comes before it", path, lineno, kind);
        return false;
    }
    std::string arg = line.substr(2);
    if (!arg.empty() && (arg[0] == ' ' || arg[0] == '\t')) arg.erase(0, 1);
    Entry e;
    e.file = kind == '<';
    e.lineno = lineno;
    if (e.file) {
        const size_t first = arg.find_first_not_of(" \t");
        const size_t last = arg.find_last_not_of(" \t");
        if (first == std::string::npos) {
            note("%s:%u: \"#<\" needs a file name", path, lineno);
            return false;
        }
        e.arg = resolve(arg.substr(first, last - first + 1));
        std::string data, error;
        if (!read_file(e.arg, data, error)) {
            note("%s:%u: cannot read %s: %s", path, lineno, e.arg.c_str(), error.c_str());
            return false;
        }
    } else {
        bool enter = true;
        if (!unescape(arg, e.arg, enter, path, lineno)) return false;
        if (enter) e.arg += '\r';
    }
    g_entries.back().push_back(e);
    return true;
}

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
        if (line.size() >= 2 && line[0] == '#' && (line[1] == '<' || line[1] == ':')) {
            ok = add_entry(path, lineno, line);
            continue;
        }
        if (!line.empty() && line[0] == '#') continue;
        std::string out;
        bool enter = true;
        ok = unescape(line, out, enter, path, lineno);
        if (enter) out += '\r';
        g_lines.push_back(out);
        g_line_numbers.push_back(lineno);
        g_entries.emplace_back();
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
            g_send_request = std::string(g_pty_link) + ".upload";
            g_send_answer = std::string(g_pty_link) + ".upload-answer";
            std::snprintf(g_send_request_c, sizeof g_send_request_c, "%s", g_send_request.c_str());
            std::snprintf(g_send_answer_c, sizeof g_send_answer_c, "%s", g_send_answer.c_str());
            unlink(g_send_request_c);   // left behind by a simulator that was killed
            unlink(g_send_answer_c);
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
                pending_push(buf[i]);
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

// ---- file requests ----
// Starts the upload of `data`, the contents of `path` as read at the request.
void upload(const std::string& path, std::string& data) {
    note("sending %s (%zu bytes)", path.c_str(), data.size());
    g_send_data.swap(data);
    g_send_pos = 0;
    g_sending = !g_send_data.empty();
}

void send_file(const std::string& path) {
    std::string data, error;
    if (!read_file(path, data, error)) {
        note("cannot read %s: %s (nothing is sent; Ctrl-C cancels the load)", path.c_str(), error.c_str());
        return;
    }
    upload(path, data);
}

// The apps of named requests: the names of the .hex files in +console_app_dir, sorted.
std::string app_names() {
    std::vector<std::string> names;
    if (DIR* dir = opendir(g_app_dir.c_str())) {
        while (const struct dirent* e = readdir(dir)) {
            const std::string f = e->d_name;
            if (f.size() > 4 && f.compare(f.size() - 4, 4, ".hex") == 0)
                names.push_back(f.substr(0, f.size() - 4));
        }
        closedir(dir);
    }
    std::sort(names.begin(), names.end());
    std::string list;
    for (const std::string& n : names) list += (list.empty() ? "" : " ") + n;
    return list.empty() ? "none in " + g_app_dir : list;
}

// A request that names its file ('load <name>'): the upload of that file, or, without one,
// the line "!<reason>", which ends the request (the program reports the reason).
void send_named(const std::string& name) {
    const bool is_file = name.size() > 4 && name.compare(name.size() - 4, 4, ".hex") == 0;
    std::string path;
    if (is_file || name.find('/') != std::string::npos) {
        path = resolve(is_file ? name : name + ".hex");
    } else if (!g_app_dir.empty()) {
        path = g_app_dir + (g_app_dir.back() == '/' ? "" : "/") + name + ".hex";
    }
    std::string data, error, reason;
    if (path.empty()) {
        reason = "no app '" + name + "' (the simulator has no +console_app_dir)";
    } else if (!read_file(path, data, error)) {
        reason = is_file ? "cannot read " + path + ": " + error
                         : "no app '" + name + "' (the apps: " + app_names() + ")";
    } else if (data.empty()) {
        reason = path + " is empty";
    } else {
        upload(path, data);
        return;
    }
    g_send_data = "!" + reason + "\r";
    g_send_pos = 0;
    g_sending = true;
}

// True if what is left of the upload holds more than blanks and line ends.
bool upload_rest_matters() {
    return g_send_data.find_first_not_of(" \t\r\n", g_send_pos) != std::string::npos;
}

// The upload stops before the end of its file: the rest is not sent.
void stop_upload(const char* why) {
    if (g_sending && upload_rest_matters())
        note("%s: the upload stops after %zu of %zu bytes; the rest of the file is not sent", why, g_send_pos,
             g_send_data.size());
    g_sending = false;
}

// The request ends: at the prompt, or when a Ctrl-C has not been answered with one. What is
// left of an upload is dropped; what is left of a paste is dropped from the input waiting
// (drop_file_rest()).
void end_request(uint64_t now) {
    if (g_sending && upload_rest_matters())
        note("the program ended the transfer after %zu of %zu bytes", g_send_pos, g_send_data.size());
    if (g_from_input && g_mode != Mode::Script) {
        g_drop_file = true;
        g_drop_in_line = g_line_length > 0;   // a line cut by a Ctrl-C
        g_dropped_lines = g_drop_in_line ? 1 : 0;
        g_drop_since = now;
    }
    g_sending = false;
    g_hold_input = false;
    g_request = false;
    g_cancelled = false;
    g_eof_typed = false;
    g_from_input = false;
    g_line_text.clear();
    g_line_length = 0;
}

// After a request served by a paste: what is left of the file in the input waiting is not
// typed into the command line. Lines starting with ':', empty lines and the rest of a line cut
// by a Ctrl-C are dropped, up to the first character of anything else, or until no input has
// arrived for kPromptWait cycles. Returns true when the input waiting may be typed as usual.
bool drop_file_rest(uint64_t now) {
    while (!g_pending.empty()) {
        const unsigned char c = g_pending.front();
        const bool line_end = c == '\r' || c == '\n';
        if (g_drop_in_line) {
            g_drop_in_line = !line_end;
        } else if (c == ':') {
            g_dropped_lines++;
            g_drop_in_line = true;
        } else if (!line_end) {
            break;
        }
        pending_pop();
        g_drop_since = now;
    }
    if (g_pending.empty() && now - g_drop_since <= kPromptWait) return false;
    if (g_dropped_lines)
        note("dropped %lu line(s) of the file that the program did not read", g_dropped_lines);
    g_drop_file = false;
    g_drop_in_line = false;
    return true;
}

// The line ':00000001FF' (either case): the program reads no more of the file after it.
bool is_eof_record(const std::string& line) {
    static const char kEof[] = ":00000001ff";
    if (line.size() != sizeof kEof - 1) return false;
    for (size_t i = 0; i < line.size(); i++)
        if (std::tolower((unsigned char)line[i]) != kEof[i]) return false;
    return true;
}

void write_answer(const std::string& text) {
    const std::string tmp = g_send_answer + ".tmp";
    const int fd = open(tmp.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) {
        note("cannot write %s: %s", tmp.c_str(), std::strerror(errno));
        return;
    }
    const std::string line = text + "\n";
    const bool ok = write(fd, line.data(), line.size()) == (ssize_t)line.size();
    close(fd);
    if (!ok || rename(tmp.c_str(), g_send_answer.c_str()) != 0) {
        note("cannot write %s: %s", g_send_answer.c_str(), std::strerror(errno));
        unlink(tmp.c_str());
    }
}

// A send request of make freertos-send (<link>.upload), if there is one: accepted only at the
// program's prompt with nothing typed since, so that 'load' reaches the command line and not
// a running app or a half-typed command; or while a 'load' typed by hand waits for a file
// that has not begun to arrive (answer "ok waiting": the file is sent at once).
void check_send_request() {
    std::string data, error;
    if (!read_file(g_send_request, data, error)) return;   // none
    unlink(g_send_request.c_str());
    while (!data.empty() && std::isspace((unsigned char)data.back())) data.pop_back();
    std::string answer = "ok";
    if (data.empty()) {
        answer = "refused: the request names no file";
    } else if (g_request && !g_sending && !g_from_input && !g_cancelled && !g_eof_typed && g_line_length == 0 &&
               g_lines_sent == 0 && g_pending.empty()) {
        g_hold_input = true;
        send_file(resolve(data));
        answer = "ok waiting";
    } else if (g_request || !g_send_once.empty()) {
        answer = "refused: a file is being sent";
    } else if (g_prompts == 0 || g_enter_since_prompt) {
        answer = "refused: the shell is not at its prompt (a command or an app is running)";
    } else if (!g_pending.empty() || g_typed_since_prompt || g_tail != g_prompt) {
        answer = "refused: the command line is not empty (press Enter for a fresh prompt)";
    } else {
        g_send_once = resolve(data);
        g_send_prompts = g_prompts;
        for (const char c : std::string("load\r")) pending_push((unsigned char)c);
    }
    write_answer(answer);
}

// Script: the next entry of the line typed last, when the program sends DC1 or DC2; each one
// only after the previous one has been typed completely. Returns false if none is left.
bool deliver_entry(unsigned char control) {
    if (g_next_line == 0) return false;
    const std::vector<Entry>& entries = g_entries[g_next_line - 1];
    if (g_next_entry >= entries.size()) return false;
    if (!g_pending.empty() || g_sending) return true;
    const Entry& e = entries[g_next_entry];
    if (e.file && control != kDc2) return true;
    g_next_entry++;
    if (e.file) {
        send_file(e.arg);
    } else {
        for (char c : e.arg) pending_push((unsigned char)c);
    }
    return true;
}

void on_control(unsigned char c) {
    g_controls++;
    if (c == kAck || c == kNak) {
        if (g_request) g_answers++;
    } else if (c == kDc2 && !g_request) {   // (a DC2 while a request is served is ignored)
        g_request = true;
        g_wait_prompt = false;
        g_lines_sent = g_answers = 0;
        g_line_length = 0;
        if (!g_request_name.empty()) {   // 'load <name>': that file, in every mode
            g_hold_input = true;
            send_named(g_request_name);
            g_request_name.clear();
        } else if (g_mode == Mode::Script) {
            if (!deliver_entry(c) && g_next_line > 0)
                note("%s:%u: the program asks for a file, but no \"#<\" line of this typed line is left",
                     g_script.c_str(), g_line_numbers[g_next_line - 1]);
        } else if (!g_send_once.empty()) {   // a send request (make freertos-send)
            g_hold_input = true;
            send_file(g_send_once);
            g_send_once.clear();
        } else if (!g_upload.empty()) {
            g_hold_input = true;   // (also when the file cannot be read: Ctrl-C cancels)
            send_file(g_upload);
        } else if (g_mode == Mode::Stdio && g_in_tty && g_pending.empty()) {
            if (g_app_dir.empty())
                note("the program asks for a file: paste it, or start the simulation with UPLOAD=<app>; "
                     "Ctrl-C cancels");
            else
                note("the program asks for a file: paste it, or press Ctrl-C and type 'load <name>'");
        }
    } else if (c == kDc1 && g_mode == Mode::Script) {
        deliver_entry(c);
    }
}

void on_prompt(uint64_t now) {
    if (g_request) end_request(now);
    g_name_open = false;             // a name not followed by DC2 lapses
    g_request_name.clear();
    g_typed_since_prompt = false;
    g_enter_since_prompt = false;
    if (!g_send_once.empty() && g_prompts > g_send_prompts) {
        note("the program did not ask for %s after 'load'", g_send_once.c_str());
        g_send_once.clear();
    }
    if (g_mode == Mode::Script && g_next_line > 0) {
        const std::vector<Entry>& entries = g_entries[g_next_line - 1];
        for (; g_next_entry < entries.size(); g_next_entry++)
            note("%s:%u: not delivered: the program showed its prompt first", g_script.c_str(),
                 entries[g_next_entry].lineno);
    }
}

// During a file request: the next character of the file, or else of the input waiting, one
// line per answer: after the end of a line that is not empty, nothing until it is answered.
// The input waiting is not typed into a request served by an upload: it waits for the prompt
// that ends the request, even after the last byte of the file. Nothing is typed after the
// end-of-file record, nor after a Ctrl-C of the file.
int next_file_byte(uint64_t now) {
    if (g_answers < g_lines_sent) {
        if (now - g_line_end_cycle <= kPromptWait) return -1;
        g_answers = g_lines_sent;   // no answer: carry on
    }
    if (g_eof_typed) {
        stop_upload("the file goes on after its end-of-file record");
        return -1;
    }
    unsigned char c;
    bool from_file = false;
    if (g_sending) {
        c = (unsigned char)g_send_data[g_send_pos++];
        from_file = true;
        if (g_send_pos >= g_send_data.size()) g_sending = false;   // sent completely
    } else if (!g_pending.empty() && !g_hold_input) {
        c = pending_pop();
        g_from_input = true;
    } else {
        return -1;
    }
    if (c == '\r' || (c == '\n' && g_last_typed != '\r')) {   // a line end
        if (g_line_length > 0) {
            g_lines_sent++;
            g_line_end_cycle = now;
            g_eof_typed = is_eof_record(g_line_text);
        }
        g_line_length = 0;
        g_line_text.clear();
    } else if (c == kCtrlC && from_file) {   // cancels the load, as a Ctrl-C typed does
        stop_upload("the file holds a Ctrl-C (0x03)");
        g_cancelled = true;
        g_cancel_cycle = now;
    } else if (c != '\n') {
        g_line_length++;
        if (g_line_text.size() < 12) g_line_text += (char)c;
    }
    g_last_typed = c;
    return c;
}

int next_script_byte(uint64_t now) {
    if (g_request && (g_sending || !g_pending.empty())) return next_file_byte(now);
    if (!g_pending.empty()) {
        g_last_typed = pending_pop();
        return g_last_typed;
    }
    if (g_prompts <= g_prompts_used) return -1;   // the previous line has not been answered yet
    g_prompts_used = g_prompts;
    if (g_next_line >= g_lines.size()) {
        note("end of the script (%zu line(s) typed)", g_lines.size());
        return -2;
    }
    const std::string& l = g_lines[g_next_line++];
    g_next_entry = 0;
    for (char c : l) pending_push((unsigned char)c);
    if (g_pending.empty()) return -1;
    g_last_typed = pending_pop();
    return g_last_typed;
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

    g_upload_dir = plusarg("console_upload_dir");
    g_upload = resolve(plusarg("console_upload"));
    g_app_dir = plusarg("console_app_dir");

    const std::string m = mode ? mode : "stdio";
    if (m == "script") {
        g_mode = Mode::Script;
        g_script = script_file ? script_file : "";
        if (!load_script(script_file)) std::exit(2);
        note("typing %zu line(s) from %s, each after the prompt \"%s\"", g_lines.size(), script_file,
             g_prompt.c_str());
        if (!g_upload.empty()) {
            note("+console_upload is not used by a script (its \"#<\" lines send files)");
            g_upload.clear();
        }
    } else if (m == "pty") {
        g_mode = Mode::Pty;
        if (!open_pty(pty_link)) std::exit(2);
        g_pty_shared = !g_upload.empty() || !g_upload_dir.empty();
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
    if (!g_app_dir.empty() && g_mode != Mode::Script)
        note("the apps for 'load <name>': %s", app_names().c_str());
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
        // A terminal program such as screen opens the device in exclusive mode, in which no
        // other program can open it: clear that, so that a file can be written into it.
        if (g_pty_shared && g_pty_slave >= 0 && ++g_pty_polls >= kExclusivePolls) {
            g_pty_polls = 0;
            ioctl(g_pty_slave, TIOCNXCL);
            if (g_pty_link_made) check_send_request();
        }
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

    if (g_mode == Mode::Script) return next_script_byte(now);

    if (g_request) {   // the program receives a file
        if (g_cancelled && now - g_cancel_cycle > kPromptWait) {
            end_request(now);   // the Ctrl-C was not answered with a prompt
        } else if (g_cancelled) {
            return -1;
        } else if (g_pending_ctrl_c > 0) {   // Ctrl-C at once, ahead of the file and the input
            pending_take_ctrl_c();
            stop_upload("Ctrl-C");
            g_cancelled = true;
            g_cancel_cycle = now;
            g_last_typed = kCtrlC;
            return kCtrlC;
        } else {
            return next_file_byte(now);
        }
    }

    if (g_drop_file && !drop_file_rest(now)) return -1;   // what is left of a pasted file

    if (g_wait_prompt) {   // Enter typed: the program answers with a prompt first
        if (g_prompts > g_wait_mark || g_controls > g_wait_controls || g_pending_ctrl_c > 0 ||
            now - g_wait_since > kPromptWait) {
            g_wait_prompt = false;
        } else {
            return -1;
        }
    }

    if (!g_pending.empty()) {
        const unsigned char c = pending_pop();
        const bool enter = c == '\r' || (c == '\n' && g_last_typed != '\r');
        if (enter && g_prompts > 0) {   // only for a program that shows this prompt
            g_wait_prompt = true;
            g_wait_since = now;
            g_wait_mark = g_prompts;
            g_wait_controls = g_controls;
        }
        g_last_typed = c;
        g_typed_since_prompt = true;
        g_enter_since_prompt = g_enter_since_prompt || enter;
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
    const unsigned char uc = (unsigned char)c;
    g_last_tx_cycle = (uint64_t)cycle;
    if (g_log_fd >= 0) {
        while (write(g_log_fd, &ch, 1) < 0 && errno == EINTR) {
        }
    }
    if (g_mode == Mode::Pty && g_pty_master >= 0) {
        if (write(g_pty_master, &ch, 1) != 1) g_pty_dropped++;
    }
    if (uc == kAck || uc == kDc1 || uc == kDc2 || uc == kNak) {   // for the bridge, not text
        on_control(uc);
        return;
    }
    if (uc == kDc4) {   // the name of the file wanted follows, or is complete; not text
        g_name_open = !g_name_open;
        if (g_name_open) g_name.clear();
        else g_request_name = g_name;
        return;
    }
    if (g_name_open && g_name.size() < kNameMax) g_name += ch;
    g_last_tx = ch;
    if (!g_prompt.empty()) {
        g_tail.push_back(ch);
        if (g_tail.size() > g_prompt.size()) g_tail.erase(0, g_tail.size() - g_prompt.size());
        if (g_tail == g_prompt) {
            g_prompts++;
            on_prompt((uint64_t)cycle);
        }
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
