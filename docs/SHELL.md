[HaDes-V+](../README.md) · [Docs](README.md) · [Building](BUILDING.md) · [FreeRTOS](FREERTOS.md) · **Shell** · [Apps](APPS.md) · [Architecture](ARCHITECTURE.md) · [Extensions](EXTENSIONS.md) · [Verification](VERIFICATION.md)

# The Interactive Shell

`test/freertos/shell/` is a command shell for HaDes-V+: FreeRTOS with the official
FreeRTOS+CLI command interpreter, on the UART. In the simulator, the UART is connected to
your terminal, so you type commands into the running core as you would into a board's serial
console. The commands show the tasks, their CPU time and stacks, the heap, the cycle and
instruction counters, the branch predictor's counters, and exercise the M and Zba
instructions.

The tools, the one-time setup and the settings that all FreeRTOS targets share are described
in [FREERTOS.md](FREERTOS.md), and the shell's configuration that loads and runs programs
built on the host in [APPS.md](APPS.md). Every command below can be copied as it stands.
The outputs of the scripted sessions are those of this version of the repository and are
recorded under [results/](../results/README.md#freertos); the numbers of an interactive
session depend on the moment a key is typed.

**Contents**

1. [Start it](#start-it)
2. [The commands](#the-commands)
3. [Editing a command line](#editing-a-command-line)
4. [Attach a terminal program instead (PTY=1)](#attach-a-terminal-program-instead-pty1)
5. [Scripted sessions and the tests](#scripted-sessions-and-the-tests)
6. [Settings](#settings)
7. [How it works](#how-it-works)
8. [Add a command](#add-a-command)
9. [Troubleshooting](#troubleshooting)

## Start it

```bash
make freertos-shell
```

The first run builds the shell and a console variant of the simulator (up to a minute).
After the build lines, the shell starts like this; type `help` and press Enter:

```text
run: app=shell cpu=dut isa=rv32i opt=-Os tick=10000 bpred=0 seed=0  (UART copy: .../test/freertos/shell/console.log)
     (the first 'Test fail!' line is the program's deliberate 'initial test' marker)
[console] the UART is connected to this terminal; press Ctrl-] to end the simulation
(195860 ps) Test fail!

HaDes-V+ shell on FreeRTOS V11.1.0+ with FreeRTOS+CLI
  config: tick=10000cyc preempt=1 slice=1 heap_4 isa=rv32i opt=-Os ram=32K bpred=0
Type 'help' for the list of commands.
hades> help

help:
 Lists all the registered commands

version            Software, build and CPU extensions
tasks              Tasks: state, priority, free stack
stats              CPU cycles used by each task
mem                Heap and RAM use
uptime             Ticks, mtime, seconds since reset
counters           Cycles, instructions, IPC
bpred [0-3|reset]  Branch predictor mode and counters
mul <a> <b>        mul, mulh, mulhsu, mulhu
div <a> <b>        div, rem, divu, remu
zba <a> <b>        sh1add, sh2add, sh3add
uart               UART receive statistics
echo <text>        Print the text
halt               Stop (ends the simulation)
exit               The same as halt
hades>
```

(`help` is the built-in command of FreeRTOS+CLI; it lists itself first, in its own format.)

**To quit**, press **Ctrl-]** (Control and the right square bracket), or type `halt` or
`exit`. Ctrl-] is handled by the simulator itself, so it works whatever the program is
doing, also when it has hung and stopped reading the UART. The simulator switches the
terminal to raw mode while it runs, so that every key, Ctrl-C included, reaches the shell; it
restores the terminal settings however it ends: `halt`, Ctrl-], the cycle limit, a
`$fatal`, a crash, or any signal that ends a process by default, such as SIGINT, SIGTERM,
SIGHUP, SIGQUIT or SIGPIPE (the latter when the output goes to a pipe whose reader has
gone, as in `make freertos-shell | head`). A signal that was already ignored when the
simulator started (SIGHUP under `nohup`) stays ignored. Only `kill -9` cannot be caught; if
that leaves the terminal in raw mode, type `stty sane` and press Enter (the characters are
not echoed).
The copy of the UART output, `console.log`, is written as the characters arrive, so it is
complete however the simulation ends.

The simulation runs at about 1.6 to 1.9 million clock cycles per second on a current PC
(less when the machine is busy),
about 30 times slower than the 50 MHz board, and it has no cycle limit in this mode
(`TIMEOUT=` sets one). The RTOS tick is 10000 cycles by default, so `uptime` advances by
one RTOS second (1000 ticks) every 5 to 6 seconds of real time; `TICK=50000` gives the
board's real 1 kHz tick at 50 MHz.

## The commands

Numbers can be given in decimal (`-7`, `4294967295`) or hexadecimal (`0x80000000`). The
examples are from one session on HaDes-V+; the numbers depend on the moment.

| Command | What it shows or does |
|---|---|
| `help` | The list of commands. |
| `version` | FreeRTOS version, the instruction set and optimisation the program was compiled for, the build configuration, and which extensions the CPU actually executes (probed at start-up: M, Zba and Zicntr). |
| `tasks` | Every task with its state, priority and the least free stack space it has had so far (the high-water mark, in 32-bit words). |
| `stats` | CPU cycles each task has run since the scheduler started, and its share (FreeRTOS run-time statistics with the 64-bit `mcycle` counter as the clock). |
| `mem` | Free heap now and at the lowest point, the RAM layout, and the interrupt stack's peak use. |
| `uptime` | RTOS ticks, `mtime` (the cycle counter of the machine timer), and the time in seconds at the configured tick clock and at the board's 50 MHz. |
| `counters` | `mcycle`, `minstret` and the instructions per cycle, since reset and since the previous `counters`; the Zicntr counters `cycle`, `time`, `instret` where the CPU has them. |
| `bpred [0-3\|reset]` | The branch predictor's mode (`MHPMEVENT10`) and its four outcome counters (`MHPMCOUNTER10`-`13`: predicted/actual not taken/taken) with the prediction accuracy. `bpred <n>` sets mode n (0 off, 1 always taken, 2 backward taken, 3 bimodal) and clears the counters; `bpred reset` only clears them. |
| `mul <a> <b>` | `mul`, `mulh`, `mulhsu`, `mulhu`: the 64-bit product in two halves. |
| `div <a> <b>` | `div`, `rem`, `divu`, `remu`, including the cases that do not trap in RISC-V: division by zero and `-2^31 / -1`. |
| `zba <a> <b>` | `sh1add`, `sh2add`, `sh3add`. |
| `uart` | Characters received, dropped because the receive queue was full, and lost in the UART. |
| `echo <text>` | Prints the text. |
| `halt`, `exit` | End the program (`FRTOS-RESULT: PASS`) and with it the simulation. |

`mul`, `div` and `zba` run the CPU's own instructions when it has them, whatever `MARCH`
the program was built with, and compare every result with a software model compiled for
plain RV32I (`swmodel.c`). The last line says which: `the CPU's M instructions, equal to
the rv32i software model`, or on the golden CPU, which has neither M nor Zba,
`rv32i software model: the CPU has no M`.

```text
hades> tasks
task        state      priority  stack free (min)
console     running           2         185 words
blink       blocked           3          81 words
IDLE        ready             0         125 words
3 tasks
hades> stats
task            CPU cycles    share
console             315176    98.4%
blink                  459     0.1%
IDLE                  4607     1.4%
total               320242   since the scheduler started (clock: mcycle)
hades> mem
heap:      1152 of 4608 bytes free, 1152 at the lowest (heap_4)
RAM:       32768 bytes: program and data 31744 (with the heap), unused 512,
           interrupt stack 512 (168 used at most)
hades> counters
cycles:    563742 (mcycle)
instret:   304978 (minstret)
IPC:       0.541 since reset
cpu:       Zicntr: cycle 571965, time 571970, instret 310439
hades> bpred 3
counters cleared
mode:      3 (bimodal, 2-bit counters)
branches:  predicted not taken: 18 right (nn), 5 wrong (nt)
           predicted taken:     32 right (tt), 6 wrong (tn)
accuracy:  82.0% of 61
hades> div -7 2
a = -7 (0xfffffff9), b = 2 (0x00000002)
  div             -3  0xfffffffd  quotient, signed
  rem             -1  0xffffffff  remainder, signed
  divu    2147483644  0x7ffffffc  quotient, unsigned
  remu             1  0x00000001  remainder, unsigned
source:    the CPU's M instructions, equal to the rv32i software model
hades> div 1 0
a = 1 (0x00000001), b = 0 (0x00000000)
  div             -1  0xffffffff  quotient, signed
  rem              1  0x00000001  remainder, signed
  divu    4294967295  0xffffffff  quotient, unsigned
  remu             1  0x00000001  remainder, unsigned
note:      x / 0 does not trap: quotient all ones, remainder x
source:    the CPU's M instructions, equal to the rv32i software model
hades> halt
halted

FRTOS-RESULT: PASS mtime=0000000000117484
```

In this session the console task has most of the CPU because the commands were typed
without pauses; in a session typed by hand, `IDLE` has nearly all of it.

## Editing a command line

| Key | Effect |
|---|---|
| Enter (CR, LF or CR LF) | Run the command. |
| Backspace, Delete | Delete the last character. |
| Ctrl-C | Cancel the line (the simulator keeps running). |
| Ctrl-U | Erase the line. |
| Up arrow / Down arrow | Recall the previous command / erase the line. |
| Esc | Ignored. The key after it counts as usual (Enter, Ctrl-C or a letter); only `[` or `O` right after it starts an arrow-key sequence, and a pause of 100 RTOS ticks ends one. |
| Ctrl-] | End the simulation (handled by the simulator, never sent to the shell). |

A line has at most 80 characters. A longer one is rejected with
`error: line too long (at most 80 characters); it is discarded up to its end`, and the rest
of it is ignored up to the Enter, so that a long paste never runs half a command. Pasting
several lines at once is fine: the simulator reads them at once and types them one after the
other, each after the shell has answered the previous one.

## Attach a terminal program instead (PTY=1)

With `PTY=1` the UART is connected to a pseudo-terminal, which a terminal program can open
like a board's serial port:

```bash
make freertos-shell PTY=1
```

```text
[console] the UART is connected to the pseudo-terminal /dev/pts/5
[console] symbolic link: .../test/freertos/shell/pty
[console] attach a terminal program, e.g.  screen .../test/freertos/shell/pty   or   picocom .../test/freertos/shell/pty  (then press Enter)
[console] Ctrl-] typed there, or 'halt', ends the simulation; so does Ctrl-C here
```

In a second terminal, in the repository directory, attach to the link it printed and press
Enter to get a prompt:

```bash
screen ${HADES_BUILD_DIR:-build}/test/freertos/shell/pty
```

The first terminal keeps showing everything the shell prints. `halt`, or Ctrl-] typed in
`screen`, ends the simulation (and `screen` with it); Ctrl-C in the first terminal does too.
To leave `screen` without ending the simulation, detach it with Ctrl-A and then `d`;
`screen -r` attaches again. (Closing `screen` with Ctrl-A `k` instead leaves the device in
`screen`'s exclusive mode, so that no terminal program can open it again until the
simulation ends.) The link `pty` is removed when the simulation ends.

**Ending a PTY-mode session.** A detached session keeps running, as a board stays powered
when its serial cable is unplugged, and in this mode the simulation has no cycle limit
(`TIMEOUT=` sets one). End it in one of these ways:

* attach again (`screen -r`, or `screen` on the link as above), then type `halt` and press
  Enter, or press Ctrl-];
* press Ctrl-C in the first terminal, or close that terminal window;
* from any terminal, end the simulator itself:

  ```bash
  pgrep -af console_pty_link     # list the PTY-mode simulators that are running
  pkill -f console_pty_link      # end them
  ```

Each of these ends the simulation and removes the link `pty` (after `pkill`, `make` reports
`Terminated`). A session started under `nohup`, or by a program that runs `make` in a
pseudo-terminal of its own, as a test harness does, keeps running when that terminal
closes; end it with `halt` or `pkill` as above.

## Scripted sessions and the tests

`make freertos-shell-test` types the command script `test/freertos/shell/session.txt` into
the shell and checks the transcript. The script runs 39 command lines: every command, the
M-extension corner cases, the line-editing keys (a lone Esc included), an unknown command, a
wrong parameter count and an over-long line, and finally `uart` (nothing may have been
dropped) and `halt`. It ends with a verdict line, and `make` exits with status 0 only for
`PASS`:

```text
==============================================================================
FREERTOS SHELL RESULT: PASS  app=shell cpu=dut isa=rv32i opt=-Os tick=10000 bpred=0 seed=0 cycles=2278845
  typed lines: 39, prompts: 39, expectations met: 120/120
  log: .../test/freertos/shell/session-dut.log
  UART transcript: .../test/freertos/shell/session-dut.uart
==============================================================================
```

The same program on the golden CPU, and both compared line by line:

```bash
make freertos-shell-test CPU=golden
make freertos-shell-compare
```

```text
SHELL COMPARE: SAME  40 blocks, 158 lines equal after normalising numbers;
  lines labelled source:/cpu:/mode:/accuracy: (M, Zba, Zicntr, branch predictor) excluded
```

The comparison replaces every number by `#` (cycle counts and counters legitimately differ,
because the golden CPU takes interrupts one cycle later) and leaves out the lines that report
what the CPU implements; everything else, 158 lines, must be identical.

Write your own script and run it with `SCRIPT=`:

```bash
make freertos-shell-test SCRIPT=my-session.txt
```

Every line of a script is typed followed by Enter, each after the shell has answered the
previous line with its prompt. Lines starting with `#` are not typed. `#? <regular
expression>` requires a line of the preceding command's output to match (in the given
order), `#! <regular expression>` requires that none does. The output is what the shell
prints after the command line; the command line itself, as the shell echoes it after the
prompt, never counts, so `echo hello` followed by `#? hello` passes only if the shell really
prints `hello`. `#> <regular expression>` checks that echoed command line instead (for
example `#> \^C$` after a line cancelled with Ctrl-C). `#?dut`, `#?golden`, `#!dut`,
`#!golden`, `#>dut` and `#>golden` apply to one CPU only. Escapes: `\r`, `\n`, `\t`, `\e`
(Escape), `\\`, `\xHH`, and `\c` at the end of a line suppresses the Enter. For example:

```text
div 7 -2
#? ^\s+div\s+-3\s
#? ^\s+rem\s+1\s
echo abX\x08c
#? ^abc$
halt
```

The verdict is `PASS` only if every expectation is met, every typed line produced one
prompt, the program ended with `FRTOS-RESULT: PASS` and the simulator exited with status 0;
a simulator that exits with another status or is killed by a signal gives `CRASH`, whatever
the transcript says.

`make freertos-shell-tty-test` checks the interactive console itself: it runs the simulator
on a pseudo-terminal, as in a terminal window, types keys with pauses like a person (a lone
Esc among them), pastes 13 lines at once, and ends the simulation in every supported way:
Ctrl-] (also while a typed character waits unread in the UART of a program that has hung),
`exit`, the cycle limit, SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGPIPE (sent, and raised by a
closed output pipe), SIGABRT, SIGALRM, SIGUSR1, SIGSEGV, and a SIGTSTP stop followed by
SIGCONT; a SIGHUP that was ignored at the start (as under `nohup`) must stay ignored. Each
time it checks that the terminal settings are exactly those from before (as
`stty -g` prints them), and after SIGINT and SIGTERM that the copy of the UART output is
complete. It also runs sessions through `PTY=1`, ended by `halt` and by Ctrl-C in the
simulator's terminal. It ends with `TTY TEST: PASS`.

## Settings

`make freertos-shell`, `freertos-shell-test`, `freertos-shell-compare` and
`freertos-shell-tty-test` take the settings of section 11 of
[FREERTOS.md](FREERTOS.md#11-settings-reference), with these differences:

* `APP` defaults to `shell`. Another program that reads the UART (`APP_CONSOLE := 1` in its
  `app.mk`) can use the same targets, as the loader configuration ([APPS.md](APPS.md)) does.
* `OPT` defaults to `-Os`, which fits the board's 32 KiB. With any other level the program
  needs a 64 KiB simulation (chosen automatically).
* `CPU=golden` needs `MARCH=rv32i` (the default), as everywhere.
* `TIMEOUT`: no limit in an interactive session; 50 million cycles for a scripted one.
* `PTY=1` (interactive only) and `SCRIPT=<file>` (scripted only).

`make freertos APP=shell` refuses to run the shell, because nothing would ever arrive on its
receive line; the message names the targets above.

## How it works

**The program** (`test/freertos/shell/`, 32 KiB):

* The UART raises the machine external interrupt while its one-byte receive buffer is full.
  The handler `app_external_irq()` (`console.c`) reads the byte with one word load (byte and
  status together; the load empties the buffer), sends it to a FreeRTOS queue of 64
  characters and wakes the console task. It never prints.
* The console task (priority 2) edits the line and hands complete lines to
  `FreeRTOS_CLIProcessCommand()`. The commands (`commands.c`) write their output into the
  CLI's buffer; a command with a lot to say (the task list) is called again for each line.
* Output: `shell_write()` sends each line of text with the scheduler suspended (the technique
  of `hal_puts_atomic()`), so the complete lines of different tasks never interleave, and
  interrupts, and with them input, keep working. A lone `\n` goes out as `\r\n`.
* `blink` (priority 3) toggles LED 0 every 500 ticks, a periodic task to look at with
  `tasks` and `stats`.
* `version` probes the CPU at start-up by executing one `mul`, one `sh1add` and one read of
  `cycle`, catching the illegal-instruction trap; the run-time statistics use `mcycle`,
  which both CPUs implement.
* The shell is built with `-Os` and uses no mutexes, no stream buffers and no 64-bit
  division from libgcc; that is what makes it fit. The program, its data and the heap
  (which holds the task stacks) take 31744 of the 32768 bytes, the interrupt stack 512, and
  512 are unused (`mem`).

**The simulator.** The console targets use a variant of the simulator,
`frtos-model/<cpu>-<n>k-console/top`, verilated with `+define+HADES_CONSOLE` and the DPI-C
bridge `sim/console.cpp`. The plain simulators, and with them every other test, do not
contain it. Every 64 clock cycles the bridge reads whatever has been typed into a queue of
its own and looks for Ctrl-], whatever the UART is doing. From that queue it types each
character into the UART's RX pin as a real 8N1 frame of 16 clock cycles per bit, which is
exactly the receiver's sampling interval at the simulation's baud rate (`sys_clk/15`). At
that rate a character arrives faster than a program can take it from its interrupt handler,
echo it and wait for the next, so only this injection is paced, like a careful typist: the
next character follows only after the program has read the previous one from the UART, at
least 512 cycles later, once its output has paused for 512 cycles, and, after Enter, once
the program has printed its next prompt. Typed-ahead and pasted input waits in the
simulator, so no character is lost (`uart` shows `dropped: 0`). What the program sends
reaches the terminal through the UART echo of `wishbone_uart.sv`, and `console.log`
through an unbuffered write.

**On a board** the same program talks to a terminal program on the other end of the UART
at 115200 baud; `halt` then only stops the shell. (The shell has been run in simulation
only.)

## Add a command

Make a shell of your own, so that the shipped one (and its test session) stays as it is:

```bash
make freertos-new NAME=myshell FROM=shell
```

This copies the shell's sources, `app.mk`, `app_config.h` and `session.txt` to
`test/freertos/myshell/`. Add a function and a table entry to
`test/freertos/myshell/commands.c`. A command that adds two numbers:

```c
/* add <a> <b> */
static BaseType_t prvAdd( char * pcOut, size_t xOutLen, const char * pcCommand )
{
    uint32_t a, b;

    if( !prvOperands( pcCommand, 1, 2, &a, &b, pcOut, xOutLen ) )   /* parses the parameters */
    {
        return pdFALSE;
    }

    shell_snprintf( pcOut, xOutLen, "%ld + %ld = %ld\n", ( int32_t ) a, ( int32_t ) b, ( int32_t ) ( a + b ) );
    return pdFALSE;   /* pdTRUE: call me again for more output */
}
```

Put it before the line `/* --- registration -- */`, and add to `axCommands[]` (after the
`exit` entry) the command word, its help line (ending in `\r\n`), the function and the
number of parameters (`-1` for any number):

```c
    { "add",      "add <a> <b>        Add two numbers\r\n", prvAdd, 2 },
```

Then run your shell, or check the new command with a script:

```bash
make freertos-shell APP=myshell
printf 'add 40 2\n#? ^40 \\+ 2 = 42$\nadd -5 0x10\n#? ^-5 \\+ 16 = 11$\nhalt\n' > add-test.txt
make freertos-shell-test APP=myshell SCRIPT=add-test.txt
```

`FreeRTOS_CLIGetParameter( pcCommand, n, &xLen )` returns the n-th parameter (not
terminated: use `xLen`). `shell_snprintf()` formats like `snprintf()` (`%d %u %x %s %c`,
widths, `l` and `ll`), and `shell_printf()` prints directly. Other tasks may print with
`shell_printf()` too: their complete lines never interleave with the shell's, but such a
line can appear in the middle of a command line that is being typed.

The 32 KiB image has about 1.6 KiB to spare (`mem`: 512 bytes unused, 1152 bytes of free
heap). For a larger addition, give the simulation more RAM with `RAM_KB=64`.

## Troubleshooting

**The terminal no longer echoes after the shell.** The simulator restores the terminal
settings on every way it can end except `kill -9`. Type `stty sane` and press Enter (the
characters are not shown while you type).

**`FREERTOS SHELL RESULT: FAIL`.** The reasons name the script line and the expectation
that was not met; the rendered transcript is in `session-dut.uart`
(`python3 test/freertos/shell/session.py check --script <script> <log> <uart>` checks it
again). `CRASH` means that the simulator ended without a result, or with an exit status
other than 0 (the reason gives it).

Problems that all FreeRTOS programs share, such as a build directory on a disk that cannot
execute programs, are covered in [FREERTOS.md](FREERTOS.md#13-troubleshooting).
